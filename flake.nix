{
  description = "Static analysis infrastructure for rocm-systems";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # Allow unfree for some analysis tools if needed
          config.allowUnfree = true;
        };

        analysisTargets = import ./nix/analysis {
          inherit pkgs;
          inherit (pkgs) lib;
          src = self;
        };
      in
      {
        # All analysis targets: nix build .#analysis-<tool>
        # Individual tools, per-project, and composites
        packages = analysisTargets;

        # Dev shell with all analysis tools on PATH
        devShells.default = import ./nix/dev-shell.nix {
          inherit pkgs;
        };
      }
    );
}
