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

The project consists of three main components:

1. **flake.nix** - Main entry point that:
   - Exports packages for x86_64-linux
   - Provides an overlay for integrating into nixpkgs
   - Exports a NixOS module

2. **pkgs/awsvpnclient.nix** - Package derivation that:
   - Fetches the official .deb from AWS CloudFront
   - Extracts and patches the binary with autoPatchelfHook
   - Handles binary name variations (space-separated vs hyphenated)
   - Creates a wrapper in /bin for the executable located in /opt
   - Includes desktop integration via makeDesktopItem
   - Bundles GUI dependencies (GTK3, Electron-related libs)
   - Includes .NET runtime dependencies (ICU for globalization)

3. **nixos-module.nix** - NixOS integration that:
   - Adds the package to systemPackages
   - Optionally enables systemd-resolved (VPN DNS resolution)

## Common Commands

### Building the package
```bash
nix build
```

### Testing in a development shell
```bash
nix develop
```

### Running the application directly
```bash
nix run
```

### Testing the NixOS module
```bash
nixos-rebuild test --flake .#
```

### Updating to a new AWS VPN Client version
Update three values in `pkgs/awsvpnclient.nix`:
1. `version` variable
2. `url` in fetchurl (update version number in CloudFront path)
3. `sha256` hash from AWS release notes

To get the new hash, you can temporarily set `sha256 = lib.fakeHash;` and run `nix build`, which will report the actual hash.

## Key Implementation Details

### Binary Discovery Logic
The install phase checks for two possible executable names in /opt/awsvpnclient/:
- "AWS VPN Client" (with spaces)
- "awsvpnclient" (no spaces)

This handles variations across AWS upstream releases (see pkgs/awsvpnclient.nix:100-111).

### Dependency Management
- autoPatchelfHook automatically patches ELF binaries with correct library paths
- `autoPatchelfIgnoreMissingDeps = true` prevents build failures from missing optional dependencies
- All GUI runtime dependencies must be listed in buildInputs for the wrapper to work
- The application is built on .NET and requires ICU (icu package) for globalization support

### NixOS Module Options
- `programs.awsvpnclient.enable` - Install and enable the package
- `programs.awsvpnclient.package` - Override package version
- `programs.awsvpnclient.enableResolved` - Control systemd-resolved integration
