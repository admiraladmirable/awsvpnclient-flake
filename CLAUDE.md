# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Nix flake that packages AWS Client VPN (awsvpnclient) for NixOS by repackaging the upstream .deb distribution. The flake provides both a package and a NixOS module for system-wide installation.

## Reference Documentation

The AWS Client VPN for Linux official documentation is located here
- https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux.html
- https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-install.html
- https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-connecting.html
- https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html

Fetch this documentation from the internet to get more information on how to create the NixOS package and module.

## Architecture

**Current Status:** ✅ Fully functional! Package builds, installs, and successfully connects to AWS VPN with SSO authentication and DNS configuration.

**Branch:** `main` (using buildFHSEnv approach with runtime binary patching)

The project consists of four main components:

1. **flake.nix** - Main entry point that:
   - Exports packages for x86_64-linux
   - Provides an overlay for integrating into nixpkgs
   - Exports a NixOS module

2. **pkgs/awsvpnclient-unwrapped.nix** - Unwrapped package that:
   - Fetches the official .deb from AWS CloudFront
   - Extracts the .deb contents
   - Disables autoPatchelfHook to manually control patching
   - **Critical:** Preserves OpenVPN resources unmodified to pass checksum validation
   - In postFixup: moves OpenVPN directory away, patches everything else with autoPatchelf, then restores OpenVPN directory from original .deb source
   - Includes .NET runtime dependencies (ICU, lttng-ust)

3. **pkgs/awsvpnclient.nix** - FHS environment wrapper that:
   - Uses buildFHSEnv to create standard filesystem layout
   - Bind mounts unwrapped package at /opt/awsvpnclient (required for path validation)
   - Creates tmpfs overlays for /opt/awsvpnclient/Resources and /opt/awsvpnclient/Service (enables runtime patching)
   - **Runtime binary patching:** Patches configure-dns to use absolute paths and updates checksums in the .NET DLL
   - Includes all runtime dependencies in targetPkgs (GTK3, glibc, musl, OpenSSL, SQLite, systemd, python3, etc.)
   - Exports three entry points via passthru:
     - Main GUI client (awsvpnclient)
     - Systemd service wrapper (awsvpnclient-service)
     - FIPS installer wrapper (awsvpnclient-fips-install)
   - Desktop integration via extraInstallCommands

4. **nixos-module.nix** - NixOS integration that:
   - Adds the package to systemPackages
   - Registers D-Bus configuration with services.dbus.packages
   - Creates system-wide symlink for musl loader at /lib/ld-musl-x86_64.so.1 (for OpenVPN binaries)
   - Configures and enables the awsvpnclient systemd service (ACVC.GTK.Service)
   - Generates OpenSSL FIPS module configuration in preStart
   - Optionally enables systemd-resolved (VPN DNS resolution)

## Common Commands

### Building the package
```bash
# Package has unfree license, requires --impure flag
NIXPKGS_ALLOW_UNFREE=1 nix build .#awsvpnclient --impure
```

### Running the application directly
```bash
NIXPKGS_ALLOW_UNFREE=1 nix run .#awsvpnclient --impure
```

### Testing the NixOS module
```bash
# Apply changes to running system
sudo nixos-rebuild switch --flake .# --impure

# Test without making permanent changes
sudo nixos-rebuild test --flake .# --impure
```

### Checking service status
```bash
# View service status
sudo systemctl status awsvpnclient.service

# View service logs
sudo journalctl -u awsvpnclient.service -f

# View application logs
tail -f ~/.config/AWSVPNClient/logs/aws_vpn_client_$(date +%Y%m%d).log
```

### Updating to a new AWS VPN Client version

**Step 1: Update unwrapped package**
Update three values in `pkgs/awsvpnclient-unwrapped.nix`:
1. `version` variable (line ~40)
2. `url` in fetchurl (update version number in CloudFront path)
3. `sha256` hash from AWS release notes

To get the new hash, you can temporarily set `sha256 = lib.fakeHash;` and run `nix build`, which will report the actual hash.

**Step 2: Update configure-dns checksum**
The runtime patching in `pkgs/awsvpnclient.nix` includes a hardcoded checksum for the original `configure-dns` script:
1. Extract the new version's configure-dns: `ar p awsvpnclient_amd64.deb data.tar.gz | tar xz ./opt/awsvpnclient/Service/Resources/openvpn/configure-dns`
2. Calculate its SHA256: `sha256sum configure-dns`
3. Update `OLD_CHECKSUM` in `pkgs/awsvpnclient.nix` (line ~180) with the new hash
4. Note: If AWS changes the configure-dns script content, you may need to update the sed pattern as well

**Step 3: Test the connection**
After updating, rebuild and test the VPN connection to ensure:
- Service starts successfully
- SSO authentication works
- VPN connection completes
- DNS configuration succeeds (check `/var/log/aws-vpn-client/configure-dns-up.log`)

## Key Implementation Details

### Service Architecture
AWS VPN Client uses a client-server architecture:
- **Backend Service** (`ACVC.GTK.Service`): Runs as a systemd service with root privileges to manage VPN connections and network configuration
- **GUI Client** (`AWS VPN Client`): User-facing GTK application that communicates with the backend service

The GUI will not work without the service running. The NixOS module automatically configures and starts the systemd service.

### Binary Discovery Logic
The install phase checks for two possible executable names in /opt/awsvpnclient/:
- "AWS VPN Client" (with spaces)
- "awsvpnclient" (no spaces)

This handles variations across AWS upstream releases (see pkgs/awsvpnclient.nix:109-124).

### Permission Fixes
After extracting the .deb, permissions are normalized to prevent Nix sandbox errors:
- All directories are set to 755
- Files preserve their execute bit (755 for executables, 644 for non-executables)
- This prevents "suspicious ownership or permission" errors during build (see pkgs/awsvpnclient.nix:98-103)

### Checksum Validation and Runtime Patching (Critical!)
The application validates SHA256 checksums of all files in `/opt/awsvpnclient/Service/Resources/openvpn/` before starting VPN connections.

**The Challenge:**
- OpenVPN resources in the Nix store must remain unmodified to pass initial validation
- However, `configure-dns` script needs patching to use absolute paths (e.g., `/usr/bin/resolvectl`)
- OpenVPN sanitizes environment variables, so scripts cannot rely on PATH

**The Solution - Runtime Binary Patching:**
1. **Unwrapped package** preserves all OpenVPN resources unmodified in the Nix store
2. **FHS wrapper** creates tmpfs overlays for `/opt/awsvpnclient/Service`
3. **Profile script** (runs at service startup):
   - Copies Service directory from Nix store to writable tmpfs
   - Patches `configure-dns` to use absolute paths (e.g., `resolvectl` → `/usr/bin/resolvectl`, `ip link` → `/sbin/ip link`)
   - Calculates new SHA256 checksum of patched script
   - Binary patches `ACVC.GTK.Service.dll` using Python to update the checksum (stored as UTF-16LE)
4. **Validation passes** because DLL now expects the patched file's checksum

**Why This Works:**
- Checksums are stored in the .NET DLL itself (not in a separate file)
- The DLL is NOT checksummed, allowing us to modify it
- OpenVPN resources remain pristine in Nix store but are patched at runtime

Files initially preserved, then patched at runtime:
- `configure-dns` - bash script (patched to use absolute paths)
- `acvc-openvpn` - musl-based OpenVPN binary (unmodified)
- `openssl` - musl-based OpenSSL binary (unmodified)
- `fips.so` - FIPS cryptographic module (unmodified)
- `libc.so` - musl libc (unmodified)
- `ld-musl-x86_64.so.1` - musl dynamic linker (unmodified)
- `openssl.cnf` - OpenSSL configuration (unmodified)

### Dependency Management
- autoPatchelfHook is disabled globally (`dontAutoPatchelf = true`)
- In postFixup, manually run `autoPatchelf` on everything except the openvpn directory
- All GUI runtime dependencies must be listed in buildInputs
- The application is built on .NET and requires ICU (icu package) for globalization support
- Musl package is included in FHS targetPkgs to provide `/lib/ld-musl-x86_64.so.1`

### FHS Environment Approach
buildFHSEnv creates a chroot-like environment with standard FHS layout:
- Read-only bind mount of unwrapped package at `/opt/awsvpnclient` (base layer)
- Tmpfs overlays at `/opt/awsvpnclient/Resources` and `/opt/awsvpnclient/Service` (writable layers)
- Profile script populates tmpfs and performs runtime patching before service starts
- Provides `/lib/ld-musl-x86_64.so.1` via musl package in targetPkgs
- Provides `/usr/bin/resolvectl` via systemd package in targetPkgs (used by patched configure-dns)
- System-wide symlink created by NixOS module to make musl loader available outside FHS environment

### NixOS Module Options
- `programs.awsvpnclient.enable` - Install and enable the package
- `programs.awsvpnclient.package` - Override package version
- `programs.awsvpnclient.enableResolved` - Control systemd-resolved integration

## Troubleshooting

### VPN Connection Fails
1. **Check service status:** `sudo systemctl status awsvpnclient.service`
2. **View service logs:** `sudo journalctl -u awsvpnclient.service -f`
3. **Check application logs:** `~/.config/AWSVPNClient/logs/aws_vpn_client_YYYYMMDD.log`
4. **Check DNS configuration logs:** `/var/log/aws-vpn-client/configure-dns-up.log`

### Checksum Validation Failed
If you see `OvpnResourcesChecksumValidationFailed` errors:
- The runtime patching may have failed
- Check that Python script in profile runs successfully
- Verify `OLD_CHECKSUM` matches the original configure-dns from the .deb
- Check service logs for "Checksum patched successfully" message

### DNS Resolution Not Working
- Ensure `programs.awsvpnclient.enableResolved = true` in your NixOS configuration
- Check that systemd-resolved is running: `systemctl status systemd-resolved`
- Verify `/usr/bin/resolvectl` exists in the FHS environment
- Check configure-dns logs: `cat /var/log/aws-vpn-client/configure-dns-up.log`

### OpenVPN Process Won't Start
- Verify musl loader symlink exists: `ls -l /lib/ld-musl-x86_64.so.1`
- Check FIPS module configuration: `ls -l /var/lib/awsvpnclient/openvpn/fipsmodule.cnf`
- Ensure OpenVPN resources have correct permissions (should be 755 for executables)

### Binary Patching Failed
If the Python script fails to patch the DLL:
- Check that the DLL is writable: `ls -l /opt/awsvpnclient/Service/ACVC.GTK.Service.dll`
- Verify Python3 is available in the FHS environment
- Check that `OLD_CHECKSUM` is found in the DLL (stored as UTF-16LE)
- Service logs should show either "Checksum patched successfully" or "Warning: Old checksum not found in DLL"

### Docker Compose Networks Break After VPN Connection
If Docker bridge networks stop working after connecting to VPN (requires reboot to fix):
- **Root Cause:** The `configure-dns` down script fails to run `ip link show` command (exit code 127: command not found)
- **Symptom:** Check `/var/log/aws-vpn-client/configure-dns-down.log` for `'ip link show dev tun0' exit code: 127`
- **Fix:** The `ip` command is now patched to use absolute path `/sbin/ip` (similar to resolvectl fix)
- **Verification:** After disconnecting VPN, check configure-dns-down.log shows successful cleanup with exit code 0
