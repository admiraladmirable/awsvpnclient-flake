{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.awsvpnclient;
in
{
  options.programs.awsvpnclient = {
    enable = lib.mkEnableOption "AWS VPN Client";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.awsvpnclient;
      defaultText = lib.literalExpression "pkgs.awsvpnclient";
      description = "The awsvpnclient package to use.";
    };

    enableResolved = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable systemd-resolved.
        AWS VPN Client relies on systemd-resolved for DNS resolution.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Add package to system packages
    environment.systemPackages = [ cfg.package ];

    # Practical default (can disable if you already manage DNS another way)
    services.resolved.enable = lib.mkIf cfg.enableResolved true;

    # Register D-Bus configuration
    services.dbus.packages = [ cfg.package ];

    # Ensure icon theme directories are linked for proper icon display
    environment.pathsToLink = [ "/share/icons" ];

    # Make musl loader available system-wide for OpenVPN binaries
    # The bundled OpenVPN binary has a relative interpreter path (ld-musl-x86_64.so.1)
    systemd.tmpfiles.rules = [
      "L+ /lib/ld-musl-x86_64.so.1 - - - - ${pkgs.musl}/lib/ld-musl-x86_64.so.1"
    ];

    # AWS VPN Client requires a backend service running as root
    systemd.services.awsvpnclient = {
      description = "AWS VPN Client Service";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "dbus.service"
      ];
      requires = [ "dbus.service" ];

      # Generate OpenSSL FIPS module configuration before starting
      preStart = ''
        # Create state directory for writable FIPS configuration
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/awsvpnclient/openvpn

        # Generate FIPS module config if missing using the FIPS installer wrapper
        FIPS_CONF="/var/lib/awsvpnclient/openvpn/fipsmodule.cnf"
        if [ ! -f "$FIPS_CONF" ]; then
          ${pkgs.coreutils}/bin/echo "Generating OpenSSL FIPS module configuration..."
          ${cfg.package.fipsInstall}/bin/awsvpnclient-fips-install \
            -out /var/lib/awsvpnclient/openvpn/fipsmodule.cnf \
            -module /opt/awsvpnclient/Service/Resources/openvpn/fips.so || true
        fi
      '';

      serviceConfig = {
        Type = "simple";
        # Run the service inside the FHS environment
        ExecStart = "${cfg.package.service}/bin/awsvpnclient-service";
        Restart = "always";
        RestartSec = "1s";
        StandardOutput = "journal";
        StandardError = "journal";

        # Service must run as root to manage VPN connections
        User = "root";
        StateDirectory = "awsvpnclient";

        # .NET requires ICU for globalization support
        Environment = [
          "LD_LIBRARY_PATH=${lib.makeLibraryPath [ pkgs.icu ]}"
        ];
      };
    };
  };
}
