{
  description = "Always up-to-date Nix package for Pi, the terminal coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      overlay = final: prev: {
        pi-coding-agent = final.callPackage ./package.nix { };
        pi = final.pi-coding-agent;
      };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      {
        packages = {
          default = pkgs.pi-coding-agent;
          pi-coding-agent = pkgs.pi-coding-agent;
          pi = pkgs.pi-coding-agent;
        };

        apps = {
          default = {
            type = "app";
            program = "${pkgs.pi-coding-agent}/bin/pi";
          };
          pi = {
            type = "app";
            program = "${pkgs.pi-coding-agent}/bin/pi";
          };
        };

        checks.default = pkgs.pi-coding-agent;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            gh
            jq
            nixfmt-rfc-style
            nodejs_22
          ];
        };
      }
    )
    // {
      overlays.default = overlay;
    };
}
