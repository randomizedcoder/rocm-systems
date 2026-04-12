# Static Analysis Infrastructure

Comprehensive, modular static analysis for the rocm-systems repository, built
with Nix for reproducible, sandboxed execution across 23 tools and 10+
programming languages.

## Quick Start

```bash
# Enter dev shell with all analysis tools on PATH
nix develop

# Run fast checks (~2-5 minutes, no compilation needed)
nix build .#analysis-quick

# Run standard checks (~10-20 minutes, includes clang-tidy + cppcheck)
nix build .#analysis-standard

# Run full deep analysis (~30-60 minutes, all 23 tools)
nix build .#analysis-deep

# View results
cat result/summary.txt
ls result/          # Each tool has its own subdirectory
cat result/flawfinder/report.txt
```

## Analysis Tiers

| Tier | Tools | Time | Use Case |
|------|-------|------|----------|
| **quick** | flawfinder, cpplint, ruff, shellcheck, yamllint, cmake-lint, fortran-lint | ~2-5 min | Pre-commit, fast feedback |
| **standard** | quick + clang-tidy, cppcheck, bandit, pylint, clippy | ~10-20 min | PR review |
| **deep** | standard + gcc-warnings, gcc-analyzer, semgrep (C++ & Python), iwyu, clang-analyzer, coccinelle, mypy, hip-check | ~30-60 min | Release gating, weekly CI |

## Individual Tool Targets

Run any tool individually:

```bash
# C/C++ tools
nix build .#analysis-flawfinder       # CWE security scanning
nix build .#analysis-cppcheck         # Deep static analysis (XML + text)
nix build .#analysis-clang-tidy       # Linting with compilation database
nix build .#analysis-cpplint          # Google style checking
nix build .#analysis-semgrep-cpp      # Pattern-based analysis (47 vendored rules)
nix build .#analysis-coccinelle       # Semantic pattern matching
nix build .#analysis-iwyu             # Include-what-you-use header hygiene
nix build .#analysis-clang-analyzer   # Path-sensitive interprocedural analysis
nix build .#analysis-gcc-warnings     # Extended compiler warning flags
nix build .#analysis-gcc-analyzer     # GCC -fanalyzer interprocedural analysis

# GPU-specific
nix build .#analysis-hip-check        # HIP API misuse, missing sync, memory leaks

# Python tools
nix build .#analysis-ruff             # Fast linting + formatting
nix build .#analysis-mypy             # Type checking
nix build .#analysis-bandit           # Security scanning
nix build .#analysis-pylint           # Comprehensive linting
nix build .#analysis-semgrep-python   # Pattern-based security rules

# Language-specific
nix build .#analysis-fortran-lint     # gfortran extended warnings
nix build .#analysis-clippy           # Rust linting

# General
nix build .#analysis-shellcheck       # Shell script linting
nix build .#analysis-yamllint         # YAML linting
nix build .#analysis-cmake-lint       # CMake formatting (gersemi)

# Utilities
nix build .#analysis-compile-db       # Just the merged compile_commands.json
```

## Per-Project Analysis

Run tools against a specific project instead of the whole repo:

```bash
nix build .#analysis-amdsmi-clang-tidy
nix build .#analysis-amdsmi-cppcheck
nix build .#analysis-rocm-core-clang-tidy
nix build .#analysis-perf-dkms-cppcheck
```

Per-project targets are auto-generated for every directory under `projects/`,
`experimental/`, and `shared/`. Currently available for clang-tidy and cppcheck
(the two compile-database tools where per-project isolation matters most).

## Language Coverage

| Language | Files | Tools |
|----------|-------|-------|
| C/C++ | ~6,577 | clang-tidy, cppcheck, flawfinder, cpplint, semgrep, coccinelle, iwyu, clang-analyzer, gcc-warnings, gcc-analyzer |
| HIP | ~98 | clang-tidy (via -x hip), hip-check (semgrep), flawfinder, cppcheck |
| CUDA | ~28 | clang-tidy (via -x cuda), hip-check (semgrep), flawfinder, cppcheck |
| OpenCL | ~28 | flawfinder, semgrep-cpp |
| Python | ~686 | ruff, mypy, bandit, pylint, semgrep-python |
| Shell | ~120 | shellcheck |
| CMake | ~925 | cmake-lint (gersemi) |
| Fortran | ~19 | fortran-lint (gfortran) |
| Rust | ~12 | clippy |
| YAML | ~502 | yamllint |

## Triage System

The triage system tracks known findings across runs so that false positives are
suppressed and only new issues appear. This is the key to making static analysis
practical on a large codebase.

### How It Works

1. **Run analysis** and review findings
2. **Triage each finding** by adding an entry to `.analysis/anomalies.toml`
3. **Re-run analysis** — triaged findings are suppressed, new findings stand out

### anomalies.toml Format

```toml
[[anomaly]]
id = "cppcheck-unused-rocm-core"          # Unique identifier
tool = "cppcheck"                          # Tool that reported it
check_id = "unusedFunction"                # Tool-specific check ID
file = "projects/rocm-core/*"             # Exact path or glob pattern
code_anchor = "void initAPI()"            # Literal text near the finding
status = "false-positive"                  # See status values below
anchor_window = 5                          # Lines to search for anchor (default: 5)
reason = "Public API — usage is external"  # Why this classification
reviewer = "das"                           # Who triaged it
date = "2026-04-11"                        # When triaged
remediations = [                           # Optional fix suggestions
    "Add // cppcheck-suppress unusedFunction",
]
```

### Status Values

| Status | Meaning | In Reports |
|--------|---------|------------|
| `false-positive` | Reviewed, not a real issue | **Suppressed** (hidden) |
| `wont-fix` | Real issue but accepted risk | **Suppressed** (hidden) |
| `needs-review` | Potentially real, needs maintainer attention | **Flagged** (highlighted) |
| `confirmed-bug` | Verified real bug, tracked until fixed | **Flagged** (highlighted) |

Findings not in anomalies.toml appear as **Unknown** (new/un-triaged).

### Code Anchors

The `code_anchor` field makes matching resilient to refactoring. Instead of
matching on exact line numbers (which drift when code changes), the triage
engine searches for the anchor text within `+/-anchor_window` lines of the
reported finding. The anchor moves with the code.

### Running the Triage Engine

After building analysis results:

```bash
# Build deep analysis
nix build .#analysis-deep

# Summary: per-tool counts with suppressed/flagged/unknown breakdown
python3 -m nix.analysis.triage result/ --summary --source-root .

# High-confidence: findings confirmed by 2+ tools or high severity
python3 -m nix.analysis.triage result/ --high-confidence --source-root .

# Cross-tool correlations: same file+line flagged by different tools
python3 -m nix.analysis.triage result/ --cross-ref --source-root .

# New findings only (for CI gating — exits non-zero if any new findings)
python3 -m nix.analysis.triage result/ --new-only --source-root .

# Drill into a specific category
python3 -m nix.analysis.triage result/ --category uninitMemberVar --source-root .

# Write all reports to a directory
python3 -m nix.analysis.triage result/ --output-dir triage-reports/ --source-root .
```

### Scoring and Prioritization

The triage engine scores findings to surface the most likely real bugs:

- **Cross-tool correlation**: findings flagged by multiple tools score higher
- **Bug-class boost**: correctness issues (null deref, use-after-free, uninitialized vars) weighted over style
- **Small-category anomaly**: check IDs with 3 or fewer hits are more likely real bugs
- **Security-sensitive paths**: findings in auth/crypto/daemon code get higher weight
- **Test-code exclusion**: findings in test files deprioritized in high-confidence mode

## Compile Database

Most C/C++ tools need a `compile_commands.json` to understand include paths and
compiler flags. The infrastructure generates this automatically:

1. **CMake generation**: each project is configured with
   `cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON`
2. **Synthetic fallback**: projects that fail cmake configure (due to missing
   ROCm/GPU libraries) get a synthetic database with minimal entries — sufficient
   for clang-tidy and cppcheck to analyze ~80% of checks
3. **Merged database**: all per-project databases are merged for whole-repo tools

To inspect the compile database:

```bash
nix build .#analysis-compile-db
cat result/compile_commands.json | python3 -m json.tool | head -50
```

## Vendored Rules

All semgrep and coccinelle rules are vendored in the repository so analysis
works offline inside the Nix sandbox (no network access).

### Semgrep Rules

| File | Rules | Coverage |
|------|-------|----------|
| `nix/analysis/rules/semgrep-cpp.yaml` | 47 | Unsafe functions, memory management, race conditions, type safety, error handling, resource management, concurrency, code quality |
| `nix/analysis/rules/semgrep-hip.yaml` | 14 | HIP/CUDA API error checking, memory lifecycle, synchronization, stream/event management |
| `nix/analysis/rules/semgrep-python.yaml` | 17 | Command injection, path traversal, insecure deserialization, hardcoded secrets, SQL injection, insecure hashing |

### Coccinelle Rules

| File | Pattern |
|------|---------|
| `null-deref.cocci` | Null pointer dereference after malloc/calloc/realloc |
| `use-after-free.cocci` | Use of pointer after free() |
| `double-free.cocci` | Double free() on same pointer |
| `resource-leak.cocci` | fopen() without fclose() on return paths |
| `bitfield-coverage.cocci` | Struct bitfield definitions (flags for test coverage review) |

## Directory Structure

```
flake.nix                              # Minimal entry point (~35 lines)
nix/
  dev-shell.nix                        # Interactive shell with all tools
  analysis/
    default.nix                        # Top-level orchestrator
    lib.nix                            # Shared helpers
    compile-db.nix                     # CMake compile_commands.json generation
    projects.nix                       # Auto-discovers projects/experimental/shared
    composites.nix                     # quick/standard/deep tiers

    tools/                             # One .nix file per tool (23 tools)
      clang-tidy.nix
      cppcheck.nix
      flawfinder.nix
      ...

    triage/                            # Python triage engine
      __main__.py                      # CLI entry point
      finding.py                       # Finding dataclass
      anomalies.py                     # Anomaly loading and matching
      filters.py                       # Noise filtering and dedup
      scoring.py                       # Cross-tool correlation and scoring
      reporter.py                      # Report formatting
      triage.nix                       # Nix derivation wrapper
      parsers/                         # Per-tool output parsers
        clang.py                       #   clang-tidy, gcc-warnings, etc.
        cppcheck.py                    #   cppcheck XML
        flawfinder.py                  #   flawfinder text
        semgrep.py                     #   semgrep JSON
        generic.py                     #   Line-based fallback

    rules/                             # Vendored analysis rules
      semgrep-cpp.yaml                 #   47 C/C++ rules
      semgrep-hip.yaml                 #   14 HIP/CUDA rules
      semgrep-python.yaml              #   17 Python rules
      coccinelle/                      #   5 semantic patches
        null-deref.cocci
        use-after-free.cocci
        double-free.cocci
        resource-leak.cocci
        bitfield-coverage.cocci

    configs/
      clang-tidy-base.yaml            # For projects without .clang-tidy

.analysis/
  anomalies.toml                       # Known findings database
  anomalies/                           # Per-anomaly documentation
  config.toml                          # Per-project overrides
```

## Per-Project Configuration

`.analysis/config.toml` controls per-project behavior:

```toml
[defaults]
cpp_standard = "c++17"
exclude_patterns = ["third_party/", "build/"]

[projects.amdsmi]
clang_tidy_config = "projects/amdsmi/.clang-tidy"   # Use project's own config

[projects.perf-dkms]
cpp_standard = "c11"     # Pure C project
languages = ["c"]

[projects.amdgpu-windows-interop]
exclude = true           # Skip entirely
```

Six projects already have their own `.clang-tidy` configs and are honored as-is:
amdsmi, rocm-smi-lib, rocprofiler, rocprofiler-register, rocprofiler-sdk,
rocprofiler-systems. All other projects use `nix/analysis/configs/clang-tidy-base.yaml`.

## Adding a New Tool

1. Create `nix/analysis/tools/my-tool.nix`:
   ```nix
   { pkgs, lib, src, analysisLib }:
   let
     runner = pkgs.writeShellApplication {
       name = "run-my-tool";
       runtimeInputs = with pkgs; [ my-tool coreutils gnugrep ];
       text = ''
         source_dir="$1"
         output_dir="$2"
         # ... run tool, write report.txt and count.txt ...
       '';
     };
   in
   analysisLib.mkSourceReport "my-tool" runner
   ```

2. Import it in `nix/analysis/default.nix` and add to the `tools` attrset

3. Add it to the appropriate tier in `nix/analysis/composites.nix`

4. Add a parser in `nix/analysis/triage/parsers/` if the output format is unique,
   or use the `generic.py` parser for line-based formats

5. Register the parser in `nix/analysis/triage/parsers/__init__.py`

## CI Integration

For CI, use `--new-only` mode which exits non-zero if any un-triaged findings
exist:

```yaml
# .github/workflows/static-analysis.yml
jobs:
  analysis:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix build .#analysis-standard
      - run: |
          python3 -m nix.analysis.triage result/ \
            --new-only --source-root . \
            || echo "::warning::New static analysis findings detected"
```

This ensures the triage database stays current: any new code change that
introduces a finding must either fix it or add a triaged entry before the
check passes.
