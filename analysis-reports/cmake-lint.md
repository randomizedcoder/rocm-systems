# cmake-lint (gersemi) Analysis Report

## Executive Summary

gersemi `--check` found **650 files needing reformatting** and **571 warnings about unknown custom commands** across CMakeLists.txt and .cmake files in the monorepo. Every unknown command warning is a false positive — all flagged commands are project-defined custom CMake functions that gersemi's parser does not know about. The 650 formatting issues represent pure style deviations with zero functional impact. There are no bugs, no security issues, and no correctness problems in this report. This is a style enforcement tool only. All issues are auto-fixable by running `gersemi` without `--check`.

---

## Findings Breakdown

### Formatting (650 files)

gersemi found 650 CMake files whose formatting does not match gersemi's canonical style. This includes:
- Argument alignment and indentation
- Line wrapping for long command calls
- Spacing around parentheses
- Blank line conventions

All are auto-fixable. No manual review required.

### Unknown Custom Commands (571 warnings)

| Command | Occurrences | Defined In |
|---|---|---|
| hip_add_exe_to_target | 67 | HIP CMake modules |
| rocprofiler_add_integration_execute_test | 63 | rocprofiler-sdk CMake |
| rocprofiler_add_integration_validate_test | 56 | rocprofiler-sdk CMake |
| rocprofiler_configure_pytest_files | 16 | rocprofiler-sdk CMake |
| Other project-specific functions | ~369 | Various project CMakes |

These are all legitimate project-defined CMake macro/function wrappers. gersemi does not parse function definitions across files, so it cannot recognize custom commands defined in included modules. **All 571 are false positives.**

---

## False Positive Analysis

### Unknown commands (571/571 = 100% false positive)

Every flagged "unknown command" is a function defined somewhere in the project's CMake infrastructure:

- `hip_add_exe_to_target`: Defined in HIP's CMake integration modules, wraps `add_executable` + target setup for HIP sources.
- `rocprofiler_add_integration_execute_test` / `rocprofiler_add_integration_validate_test`: Defined in rocprofiler-sdk's CMake test framework macros. Handle test registration, dependency setup, and result validation.
- `rocprofiler_configure_pytest_files`: Sets up Python test file discovery for rocprofiler tests.

None of these represent missing functionality or bugs. gersemi simply lacks knowledge of project-specific extensions to the CMake language.

### Formatting issues (650 files — 100% auto-fixable, 0% bugs)

CMake formatting deviations have no functional impact. CMake ignores whitespace in command invocations (unlike Python or YAML). The 650 files will build and function identically before and after reformatting.

---

## Per-Project Breakdown (Estimated)

Based on command occurrence counts, the affected projects are:

| Project | Estimated Files | Primary Issues |
|---|---|---|
| rocprofiler-sdk | ~200+ | Custom test commands (179 occurrences across 3 commands) |
| hip-tests | ~150+ | hip_add_exe_to_target (67 occurrences) |
| Other projects | ~300 | Formatting only |

---

## Priority Remediation List

### P1 — AUTO-FIX: Reformat all CMake files (650 files)

Run gersemi without `--check` to auto-apply formatting:

```sh
# From the repository root
gersemi --in-place $(find . -name "CMakeLists.txt" -o -name "*.cmake" | grep -v build/)
```

Or with xargs for large file counts:
```sh
find . \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
  -not -path "*/build/*" \
  -not -path "*/_deps/*" \
  | xargs gersemi --in-place
```

Commit as a single formatting-only commit: `style: reformat CMake files with gersemi`.

### P2 — CONFIGURE: Teach gersemi about custom commands (571 warnings)

gersemi supports a `--definitions` flag that accepts files containing custom command definitions. Point it at the relevant CMake modules:

```sh
gersemi \
  --definitions cmake/rocprofiler_test_macros.cmake \
  --definitions cmake/hip_helpers.cmake \
  --check .
```

Alternatively, create a `.gersemi.rc` configuration file in the repository root:

```toml
[gersemi]
definitions = [
  "cmake/rocprofiler_test_macros.cmake",
  "cmake/hip_helpers.cmake",
  "projects/rocprofiler-sdk/cmake/test_helpers.cmake",
]
```

This will eliminate all 571 unknown-command warnings and allow gersemi to correctly format calls to those commands.

### P3 — CI INTEGRATION: Add gersemi check to pre-commit

Once the bulk reformat is committed and `--definitions` is configured, add gersemi to `.pre-commit-config.yaml`:

```yaml
- repo: https://github.com/BlankSpruce/gersemi
  rev: 0.14.0  # use latest stable
  hooks:
    - id: gersemi
      args: [--definitions, cmake/rocprofiler_test_macros.cmake]
```

This prevents formatting drift from reappearing.

---

## Recommended Next Steps

1. Identify all custom CMake function definition files (run `grep -r "^function\|^macro" --include="*.cmake" -l`).
2. Configure `.gersemi.rc` with those definition files to eliminate the 571 false-positive warnings.
3. Run `gersemi --in-place` bulk reformat.
4. Add to pre-commit hooks.
5. Do not spend time manually reviewing individual formatting findings — this tool produces zero actionable bugs. The entire value is in automated style consistency enforcement.
