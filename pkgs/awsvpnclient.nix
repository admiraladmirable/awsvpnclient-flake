{
  lib,
  buildFHSEnv,
  callPackage,
  runCommand,
  writeShellScript,
  gtk3,
  glib,
  nss,
  nspr,
  atk,
  at-spi2-atk,
  pango,
  cairo,
  gdk-pixbuf,
  libdrm,
  mesa,
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxcb,
  libxshmfence,
  libxkbcommon,
  dbus,
  alsa-lib,
  icu,
  libz,
  lttng-ust_2_12,
  xdg-utils,
  lsof,
  coreutils,
  iproute2,
  iptables,
  util-linux,
  sqlite,
  openssl,
  musl,
  procps,
  systemd,
  python3,
}:

let
  unwrapped = callPackage ./awsvpnclient-unwrapped.nix { };

  sysctlWrapper = writeShellScript "awsvpnclient-sysctl" ''
    if [ "$#" -eq 2 ] && [ "$1" = "-w" ] && [ "$2" = "net.ipv4.ip_forward=0" ]; then
      state_dir="/var/lib/awsvpnclient"
      state_file="$state_dir/ip_forward.before"

      ${coreutils}/bin/mkdir -p "$state_dir"
      if [ ! -e "$state_file" ]; then
        tmp_file="$state_file.$$"
        if ${procps}/bin/sysctl -n net.ipv4.ip_forward > "$tmp_file"; then
          ${coreutils}/bin/mv -f "$tmp_file" "$state_file"
        else
          ${coreutils}/bin/rm -f "$tmp_file"
        fi
      fi
    fi

    exec ${procps}/bin/sysctl "$@"
  '';

  sysctlWrapperPackage = runCommand "awsvpnclient-sysctl" { } ''
    install -Dm755 ${sysctlWrapper} $out/bin/sysctl
    mkdir -p $out/sbin
    ln -s ../bin/sysctl $out/sbin/sysctl
  '';

  # Common target packages for all FHS environments
  commonTargetPkgs = pkgs: [
    # The unwrapped application
    unwrapped

    # GUI dependencies
    gtk3
    glib
    nss
    nspr
    atk
    at-spi2-atk
    pango
    cairo
    gdk-pixbuf
    libdrm
    mesa
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
    libxshmfence
    libxkbcommon
    dbus
    alsa-lib

    # .NET runtime dependencies
    icu
    libz
    lttng-ust_2_12

    # System utilities
    xdg-utils
    lsof
    coreutils
    iproute2
    iptables
    util-linux
    sqlite
    procps # provides ps and other process utilities used by the service
    (lib.hiPrio sysctlWrapperPackage)
    systemd # provides resolvectl for DNS configuration

    # OpenSSL for .NET runtime (separate from bundled musl OpenSSL for FIPS)
    openssl

    # Musl for OpenVPN binaries with relative interpreter paths
    musl
  ];

in
buildFHSEnv {
  name = "awsvpnclient";

  # Target packages that will be available in the FHS environment
  targetPkgs = commonTargetPkgs;

  # Use bind mount to make /opt/awsvpnclient appear at the expected location
  # This is critical - /proc/{pid}/exe must resolve to /opt/awsvpnclient/...
  # The Resources directory needs to be writable for temporary OpenVPN config files
  # but we need to copy the original files into the tmpfs first
  extraBwrapArgs = [
    "--ro-bind ${unwrapped}/opt/awsvpnclient /opt/awsvpnclient"
    "--tmpfs /opt/awsvpnclient/Resources"
  ];

  # Copy Resources files into tmpfs after it's mounted
  profile = ''
    # Populate tmpfs with original Resources files
    if [ -d "${unwrapped}/opt/awsvpnclient/Resources" ]; then
      cp -r ${unwrapped}/opt/awsvpnclient/Resources/* /opt/awsvpnclient/Resources/ 2>/dev/null || true
    fi
  '';

  # Setup the FHS environment
  extraInstallCommands = ''
    # D-Bus configuration
    mkdir -p $out/share/dbus-1/system.d
    ln -s ${unwrapped}/share/dbus-1/system.d/* $out/share/dbus-1/system.d/ || true

    # Desktop entry from upstream .deb
    mkdir -p $out/share/applications
    cp ${unwrapped}/share/applications/awsvpnclient.desktop $out/share/applications/
    # Update Exec path to point to our wrapper and remove Path directive
    # (Path=/opt/awsvpnclient doesn't exist outside FHS env and causes silent failures)
    sed -i "s|Exec=.*|Exec=$out/bin/awsvpnclient %u|" $out/share/applications/awsvpnclient.desktop
    sed -i "/^Path=/d" $out/share/applications/awsvpnclient.desktop

    # Icon from upstream .deb
    # Install to both pixmaps (for desktop file) and icon theme (for window icon)
    mkdir -p $out/share/pixmaps
    mkdir -p $out/share/icons/hicolor/64x64/apps
    ln -s ${unwrapped}/share/pixmaps/acvc-64.png $out/share/pixmaps/acvc-64.png
    ln -s ${unwrapped}/share/pixmaps/acvc-64.png $out/share/icons/hicolor/64x64/apps/acvc-64.png
  '';

  # Run the GUI client by default
  runScript = writeShellScript "awsvpnclient-gui" ''
    cd /opt/awsvpnclient
    export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:abstract=awsvpnclient}"
    exec "/opt/awsvpnclient/AWS VPN Client" "$@"
  '';

  # Expose additional entry points as separate derivations for the module to use
  passthru = {
    # Service wrapper for systemd
    service = buildFHSEnv {
      name = "awsvpnclient-service";
      targetPkgs = commonTargetPkgs;
      multiPkgs = pkgs: [
        pkgs.coreutils
        pkgs.bash
        pkgs.systemd
      ];
      extraBwrapArgs = [
        "--ro-bind ${unwrapped}/opt/awsvpnclient /opt/awsvpnclient"
        "--tmpfs /opt/awsvpnclient/Resources"
        "--tmpfs /opt/awsvpnclient/Service"
        "--bind /var/lib/awsvpnclient /var/lib/awsvpnclient"
      ];
      profile = ''
                # Populate tmpfs with original Resources files
                if [ -d "${unwrapped}/opt/awsvpnclient/Resources" ]; then
                  ${coreutils}/bin/cp -r ${unwrapped}/opt/awsvpnclient/Resources/* /opt/awsvpnclient/Resources/ 2>/dev/null || true
                fi

                # Copy entire Service directory to tmpfs for patching
                if [ -d "${unwrapped}/opt/awsvpnclient/Service" ]; then
                  ${coreutils}/bin/cp -rp ${unwrapped}/opt/awsvpnclient/Service/* /opt/awsvpnclient/Service/ 2>/dev/null || true
                  # Make DLL writable for patching (cp -p preserves read-only permissions from Nix store)
                  ${coreutils}/bin/chmod 644 /opt/awsvpnclient/Service/ACVC.GTK.Service.dll
                fi

                # Patch configure-dns to use absolute paths for system utilities
                # OpenVPN sanitizes the environment and doesn't pass PATH to child processes,
                # so configure-dns must use absolute paths like /usr/bin/resolvectl
                if [ -f /opt/awsvpnclient/Service/Resources/openvpn/configure-dns ]; then
                  OLD_CHECKSUM=$(${coreutils}/bin/sha256sum /opt/awsvpnclient/Service/Resources/openvpn/configure-dns | ${coreutils}/bin/cut -d' ' -f1)

                  # Restore the host's previous IPv4 forwarding state when the UI disconnects.
                  # The vendor service disables forwarding on connect; Docker bridge networking
                  # expects NixOS/Docker to restore it after the VPN session ends.
                  ${python3}/bin/python3 << 'EOF'
        from pathlib import Path
        import sys

        path = Path('/opt/awsvpnclient/Service/Resources/openvpn/configure-dns')
        text = path.read_text()

        replacements = {
            'output=$(resolvectl status 2>&1)': 'output=$(/usr/bin/resolvectl status 2>&1)',
            'output=$(resolvectl "$@" 2>&1)': 'output=$(/usr/bin/resolvectl "$@" 2>&1)',
            'device_info="$(ip link show dev "$dev")"': 'device_info="$(/sbin/ip link show dev "$dev")"',
        }
        for before, after in replacements.items():
            if before not in text and after not in text:
                print(f'configure-dns command pattern not found: {before}', file=sys.stderr)
                sys.exit(1)
            text = text.replace(before, after, 1)

        restore_function = """restore_ip_forwarding() {
          local state_file="/var/lib/awsvpnclient/ip_forward.before"
          local value output exit_code

          if [[ ! -f "$state_file" ]]; then
            return 0
          fi

          read -r value < "$state_file" || value=""
          if [[ "$value" == "0" || "$value" == "1" ]]; then
            log "Restoring net.ipv4.ip_forward=$value"
            output=$(${procps}/bin/sysctl -w "net.ipv4.ip_forward=$value" 2>&1)
            exit_code=$?
            log "sysctl restore exit code: $exit_code, output: $output"
          else
            log "Skipping invalid saved net.ipv4.ip_forward value: $value"
          fi

          ${coreutils}/bin/rm -f "$state_file"
        }
        """

        if 'restore_ip_forwarding() {' not in text:
            target = 'reset_dns() {\n'
            if target not in text:
                print('reset_dns function not found in configure-dns', file=sys.stderr)
                sys.exit(1)
            text = text.replace(target, restore_function + '\n' + target, 1)

        if '\n  restore_ip_forwarding\n' not in text:
            lines = text.splitlines(keepends=True)
            for idx, line in enumerate(lines):
                if line.strip() == 'call_resolvectl "revert" "$dev"':
                    lines.insert(idx + 1, '  restore_ip_forwarding\n')
                    text = "".join(lines)
                    break
            else:
                print('reset_dns restore insertion point not found in configure-dns', file=sys.stderr)
                sys.exit(1)

        path.write_text(text)
        EOF

                  # Update the checksum in the DLL to match the patched configure-dns
                  # The Service validates SHA256 checksums of OpenVPN resources before use
                  NEW_CHECKSUM=$(${coreutils}/bin/sha256sum /opt/awsvpnclient/Service/Resources/openvpn/configure-dns | ${coreutils}/bin/cut -d' ' -f1)

                  # Checksums are stored as UTF-16LE in the .NET assembly
                  # Use Python for reliable binary patching
                  ${python3}/bin/python3 << EOF
        import sys

        # Read the DLL file
        with open('/opt/awsvpnclient/Service/ACVC.GTK.Service.dll', 'rb') as f:
            data = f.read()

        # Convert checksums to UTF-16LE (null byte after each character)
        old_checksum = "$OLD_CHECKSUM"
        new_checksum = "$NEW_CHECKSUM"
        old_utf16 = old_checksum.encode('utf-16-le')
        new_utf16 = new_checksum.encode('utf-16-le')

        # Replace the checksum in the binary data
        if old_utf16 in data:
            data = data.replace(old_utf16, new_utf16)
            # Write back
            with open('/opt/awsvpnclient/Service/ACVC.GTK.Service.dll', 'wb') as f:
                f.write(data)
            print("Checksum patched successfully", file=sys.stderr)
        else:
            print("Warning: Old checksum not found in DLL", file=sys.stderr)
            sys.exit(1)
        EOF
                fi

                # Copy FIPS config from /var/lib into Service/Resources/openvpn where OpenSSL expects it
                if [ -f /var/lib/awsvpnclient/openvpn/fipsmodule.cnf ]; then
                  ${coreutils}/bin/cp /var/lib/awsvpnclient/openvpn/fipsmodule.cnf /opt/awsvpnclient/Service/Resources/openvpn/fipsmodule.cnf
                fi
      '';
      runScript = writeShellScript "service" ''
        cd /opt/awsvpnclient
        exec /opt/awsvpnclient/Service/ACVC.GTK.Service "$@"
      '';
    };

    # FIPS installer wrapper
    fipsInstall = buildFHSEnv {
      name = "awsvpnclient-fips-install";
      targetPkgs = commonTargetPkgs;
      extraBwrapArgs = [
        "--ro-bind ${unwrapped}/opt/awsvpnclient /opt/awsvpnclient"
        "--tmpfs /opt/awsvpnclient/Resources"
        "--bind /var/lib/awsvpnclient /var/lib/awsvpnclient"
      ];
      runScript = writeShellScript "fips-install" ''
        cd /opt/awsvpnclient/Service/Resources/openvpn
        exec ./openssl fipsinstall "$@"
      '';
    };
  };

  meta = {
    description = "AWS provided Client VPN for Linux (packaged from upstream .deb)";
    homepage = "https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux.html";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
    mainProgram = "awsvpnclient";
  };
}
