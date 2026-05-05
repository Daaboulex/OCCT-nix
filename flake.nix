{
  description = "OCCT benchmark tool for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      git-hooks,
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      overlays.default = final: _prev: {
        occt = final.callPackage ./package.nix { };
        occt-testing = final.callPackage ./package.nix { branch = "Testing"; };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            localSystem.system = system;
            config.allowUnfree = true;
          };
        in
        {
          occt = pkgs.callPackage ./package.nix { };
          occt-testing = pkgs.callPackage ./package.nix { branch = "Testing"; };
          default = self.packages.${system}.occt;
        }
      );

      apps = forAllSystems (system: {
        occt = {
          type = "app";
          program = "${self.packages.${system}.occt}/bin/occt";
        };
        occt-testing = {
          type = "app";
          program = "${self.packages.${system}.occt-testing}/bin/occt";
        };
        default = self.apps.${system}.occt;
      });

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { localSystem.system = system; };
        in
        pkgs.nixfmt
      );

      checks = forAllSystems (system: {
        pre-commit-check = git-hooks.lib.${system}.run {
          src = self;
          hooks.nixfmt-rfc-style.enable = true;
          hooks.typos.enable = true;
          hooks.rumdl.enable = true;
          hooks.check-readme-sections = {
            enable = true;
            name = "check-readme-sections";
            entry = "bash scripts/check-readme-sections.sh";
            files = "README\.md$";
            language = "system";
          };
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { localSystem.system = system; };
        in
        {
          default = pkgs.mkShell {
            inherit (self.checks.${system}.pre-commit-check) shellHook;
            buildInputs = self.checks.${system}.pre-commit-check.enabledPackages;
            packages = with pkgs; [ nil ];
          };
        }
      );
    };
}
