{
  description = "OCCT benchmark tool for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    overlays.default = final: prev: {
      occt = final.callPackage ./package.nix { };
    };

    packages = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      occt = pkgs.callPackage ./package.nix { };
      default = self.packages.${system}.occt;
    });

    apps = forAllSystems (system: {
      occt = {
        type = "app";
        program = "${self.packages.${system}.occt}/bin/occt";
      };
      default = self.apps.${system}.occt;
    });
  };
}
