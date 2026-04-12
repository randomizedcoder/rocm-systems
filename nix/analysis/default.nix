# Top-level analysis module.
#
# Imports all tool modules, compile-db generation, project discovery,
# and composite targets. Exports a flat attrset of all analysis derivations.
#
{ pkgs, lib, src }:

let
  # Shared helpers
  analysisLib = import ./lib.nix { inherit pkgs lib src; };

  # Project discovery
  projects = import ./projects.nix { inherit lib src; };

  # Compile database generation
  compileDbModule = import ./compile-db.nix { inherit pkgs lib src projects; };
  compileDb = compileDbModule.mergedDb;

  # ── Individual tool targets ────────────────────────────────────

  # C/C++ source-only tools
  flawfinder = import ./tools/flawfinder.nix { inherit pkgs lib src analysisLib; };
  cpplint = import ./tools/cpplint.nix { inherit pkgs lib src analysisLib; };
  semgrep-cpp = import ./tools/semgrep-cpp.nix { inherit pkgs lib src analysisLib; };
  coccinelle = import ./tools/coccinelle.nix { inherit pkgs lib src analysisLib; };

  # C/C++ compile-db tools
  clang-tidy = import ./tools/clang-tidy.nix { inherit pkgs lib src analysisLib compileDb; };
  cppcheck = import ./tools/cppcheck.nix { inherit pkgs lib src analysisLib compileDb; };
  iwyu = import ./tools/iwyu.nix { inherit pkgs lib src analysisLib compileDb; };
  clang-analyzer = import ./tools/clang-analyzer.nix { inherit pkgs lib src analysisLib compileDb; };

  # C/C++ full-build tools
  gcc-warnings = import ./tools/gcc-warnings.nix { inherit pkgs lib src analysisLib; };
  gcc-analyzer = import ./tools/gcc-analyzer.nix { inherit pkgs lib src analysisLib; };

  # GPU-specific
  hip-check = import ./tools/hip-check.nix { inherit pkgs lib src analysisLib; };

  # Python tools
  ruff = import ./tools/ruff.nix { inherit pkgs lib src analysisLib; };
  mypy = import ./tools/mypy.nix { inherit pkgs lib src analysisLib; };
  bandit = import ./tools/bandit.nix { inherit pkgs lib src analysisLib; };
  pylint = import ./tools/pylint.nix { inherit pkgs lib src analysisLib; };
  semgrep-python = import ./tools/semgrep-python.nix { inherit pkgs lib src analysisLib; };

  # Language-specific
  fortran-lint = import ./tools/fortran-lint.nix { inherit pkgs lib src analysisLib; };
  clippy = import ./tools/clippy.nix { inherit pkgs lib src analysisLib; };

  # General tools
  shellcheck = import ./tools/shellcheck.nix { inherit pkgs lib src analysisLib; };
  yamllint = import ./tools/yamllint.nix { inherit pkgs lib src analysisLib; };
  cmake-lint = import ./tools/cmake-lint.nix { inherit pkgs lib src analysisLib; };

  # All individual tools as an attrset
  tools = {
    inherit
      flawfinder cpplint semgrep-cpp coccinelle
      clang-tidy cppcheck iwyu clang-analyzer
      gcc-warnings gcc-analyzer
      hip-check
      ruff mypy bandit pylint semgrep-python
      fortran-lint clippy
      shellcheck yamllint cmake-lint;
  };

  # ── Composite targets ──────────────────────────────────────────

  composites = import ./composites.nix { inherit pkgs lib tools; };

  # ── Per-project targets ────────────────────────────────────────
  #
  # Generate analysis-<project>-<tool> for each project/tool combination.
  # Only for compile-db tools (source-only tools run on whole repo).

  perProjectTargets = lib.foldl' (acc: project:
    let
      projectDb = compileDbModule.projectDbs.${project.name};
      prefix = "analysis-${project.name}";
    in
    acc // {
      "${prefix}-clang-tidy" = import ./tools/clang-tidy.nix {
        inherit pkgs lib analysisLib;
        src = project.path;
        compileDb = projectDb;
      };
      "${prefix}-cppcheck" = import ./tools/cppcheck.nix {
        inherit pkgs lib analysisLib;
        src = project.path;
        compileDb = projectDb;
      };
    }
  ) {} projects.all;

in

# Export all targets with analysis- prefix
lib.mapAttrs' (name: value: {
  name = "analysis-${name}";
  inherit value;
}) tools

# Composite targets (already prefixed)
// {
  "analysis-quick" = composites.quick;
  "analysis-standard" = composites.standard;
  "analysis-deep" = composites.deep;
  "analysis-all" = composites.all;
}

# Per-project targets (already prefixed)
// perProjectTargets

# Compile database (useful for debugging)
// {
  "analysis-compile-db" = compileDb;
}
