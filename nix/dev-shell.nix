# Development shell with all static analysis tools on PATH.
#
# Enter with: nix develop
#
{ pkgs }:

pkgs.mkShell {
  name = "rocm-systems-analysis";

  packages = with pkgs; [
    # C/C++ analysis
    clang-tools       # clang-tidy, clang-format, clang --analyze
    cppcheck
    flawfinder
    cpplint
    include-what-you-use
    coccinelle

    # Semgrep
    semgrep

    # Python analysis
    ruff
    mypy
    bandit
    pylint

    # Rust
    rustc
    cargo
    clippy

    # Fortran
    gfortran

    # General
    shellcheck
    yamllint
    gersemi           # CMake formatting/linting

    # Build tools (for compile_commands.json generation)
    cmake
    gcc
    gnumake

    # Utilities
    python3
    jq                # JSON processing
    parallel          # Parallel execution
  ];

  shellHook = ''
    echo ""
    echo "=== rocm-systems Static Analysis Shell ==="
    echo ""
    echo "Available analysis commands:"
    echo "  nix build .#analysis-quick       Quick checks (~2-5 min)"
    echo "  nix build .#analysis-standard    Standard checks (~10-20 min)"
    echo "  nix build .#analysis-deep        Full analysis (~30-60 min)"
    echo ""
    echo "Individual tools:"
    echo "  nix build .#analysis-flawfinder"
    echo "  nix build .#analysis-cppcheck"
    echo "  nix build .#analysis-clang-tidy"
    echo "  nix build .#analysis-ruff"
    echo "  ... (see flake.nix for all targets)"
    echo ""
    echo "Per-project analysis:"
    echo "  nix build .#analysis-amdsmi-clang-tidy"
    echo "  nix build .#analysis-rocm-core-cppcheck"
    echo ""
    echo "Triage system:"
    echo "  python3 -m nix.analysis.triage <result-dir> --summary"
    echo "  python3 -m nix.analysis.triage <result-dir> --high-confidence"
    echo "  python3 -m nix.analysis.triage <result-dir> --new-only"
    echo ""
    echo "Configuration: .analysis/anomalies.toml, .analysis/config.toml"
    echo ""

    # Disable semgrep telemetry
    export SEMGREP_ENABLE_VERSION_CHECK=0
    export SEMGREP_SEND_METRICS=off
  '';
}
