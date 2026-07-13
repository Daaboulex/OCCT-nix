{
  description = "OCCT benchmark tool for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    std = {
      url = "github:Daaboulex/nix-packaging-standard?ref=v2.9.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.git-hooks.follows = "git-hooks";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [ inputs.std.flakeModules.base ];

      flake.overlays.default = final: _prev: {
        occt = final.callPackage ./package.nix { };
        occt-testing = final.callPackage ./package.nix { branch = "Testing"; };
      };

      perSystem =
        { system, self', ... }:
        let
          # OCCT is a proprietary prebuilt binary (unfree).
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          packages.occt = pkgs.callPackage ./package.nix { };
          packages.occt-testing = pkgs.callPackage ./package.nix { branch = "Testing"; };
          packages.default = self'.packages.occt;

          apps.occt = {
            type = "app";
            program = "${self'.packages.occt}/bin/occt";
          };
          apps.occt-testing = {
            type = "app";
            program = "${self'.packages.occt-testing}/bin/occt";
          };
          apps.default = self'.apps.occt;
        };
    };
}
