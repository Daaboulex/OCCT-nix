{
  description = "OCCT benchmark tool for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
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
