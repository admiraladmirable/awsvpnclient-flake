{
  description = "AWS Client VPN (awsvpnclient) packaged from upstream .deb for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          awsvpnclient = pkgs.callPackage ./pkgs/awsvpnclient.nix { };
          default = self.packages.${system}.awsvpnclient;
        }
      );

      overlays.default = final: prev: {
        awsvpnclient = final.callPackage ./pkgs/awsvpnclient.nix { };
      };

      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ ./nixos-module.nix ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
    };
}
