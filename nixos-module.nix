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
    enable = lib.mkEnableOption "AWS VPN Client (awsvpnclient)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.awsvpnclient;
      description = "The awsvpnclient package to install.";
    };

    enableResolved = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable systemd-resolved (often needed for VPN-provided DNS to work smoothly).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Practical default (can disable if you already manage DNS another way)
    services.resolved.enable = lib.mkIf cfg.enableResolved true;
  };
}
