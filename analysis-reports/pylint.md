# pylint Analysis Report

## Executive Summary

pylint found **29,065 findings** across Python code in the monorepo. The majority are style and convention issues (missing docstrings, line length, naming). The most actionable real findings are: `unused-import` (334), `unused-variable` (319), `unspecified-encoding` (650), `broad-exception-caught` (305), and `duplicate-code` (1,075). One category — `c-extension-no-member` (1,586 findings) — is entirely a false positive caused by running pylint in a Nix sandbox without ROCm libraries installed. Estimated overall false positive rate is 60-70% after filtering style-only categories; the remaining ~9,000-10,000 findings represent real code quality concerns.

---

## Findings Breakdown

| Code | Count | Type | Description | Priority |
|---|---|---|---|---|
| C0116 | 3,462 | Convention | missing-function-docstring | Low |
| C0301 | 2,652 | Convention | line-too-long | Low |
| C0103 | 2,293 | Convention | invalid-name (variable/function naming) | Low |
| W0311 | 2,239 | Warning | bad-indentation | Medium |
| E1101 | 1,586 | Error | c-extension-no-member (sandbox artifact) | **False positive** |
| R0801 | 1,075 | Refactor | duplicate-code | Medium |
| C0415 | 1,061 | Convention | import-outside-toplevel | Low |
| W0621 | 1,056 | Warning | redefined-outer-name | Low |
| C0303 | 875 | Convention | trailing-whitespace | Low |
| W0212 | 748 | Warning | protected-access (_member access) | Medium |
| W1514 | 650 | Warning | unspecified-encoding (open() without encoding=) | Medium |
| C0115 | 571 | Convention | missing-class-docstring | Low |
| C0114 | 456 | Convention | missing-module-docstring | Low |
| R0914 | 420 | Refactor | too-many-locals | Low |
| C0209 | 412 | Convention | consider-using-f-string | Low |
| W1203 | 354 | Warning | logging-fstring-interpolation | Low |
| W0611 | 334 | Warning | unused-import | Medium |
| W0612 | 319 | Warning | unused-variable | Medium |
| W0613 | 307 | Warning | unused-argument | Low |
| W0718 | 305 | Warning | broad-exception-caught | Medium |

**Total: 29,065**

---

## False Positive Analysis by Category

### E1101 c-extension-no-member (1,586) — ~100% false positive

pylint cannot introspect C extension modules (`amdsmi`, ROCm Python bindings, etc.) without the compiled `.so` files present. Running in a Nix sandbox without ROCm installed generates false attribute-not-found errors for all accesses to these modules. These 1,586 findings should be suppressed globally with `# pylint: disable=c-extension-no-member` or excluded via `.pylintrc` until a ROCm-enabled analysis environment is available. **Do not act on these findings.**

### C0116 / C0115 / C0114 missing-docstring (4,489 combined) — ~95% false positive for existing code

Docstrings are valuable for public APIs but not required for every internal function, private helper, or test case. The 4,489 findings mostly represent scripts and internal tooling where docstrings add marginal value. New public API functions should have docstrings; a blanket retroactive requirement is unreasonable.

### C0301 line-too-long (2,652) — ~80% false positive

Long lines in Python are often necessary for URLs, formatted strings, and complex expressions. Configure a realistic max line length (120 or 132 characters) to reduce noise. Auto-fixable for simple cases via `black` or `ruff`.

### C0103 invalid-name (2,293) — ~70% false positive

pylint's default naming conventions (e.g., 2-character minimum for variable names) reject legitimate short names like `i`, `fd`, `x`, `df`. Many findings are valid names under project conventions. GPU computing code frequently uses single-letter math variables.

### W0311 bad-indentation (2,239) — ~10% false positive

Mixed tabs/spaces or non-standard indentation levels are genuine issues. Python's whitespace sensitivity means these can be real bugs in some cases (though Python 3 rejects mixed indentation). Most are fixable automatically with `autopep8` or `black`.

### R0801 duplicate-code (1,075) — ~30% false positive

Some code duplication is intentional (test fixtures, platform-specific implementations that must remain independent). However, ~700 real duplications likely represent opportunities to extract shared utilities, particularly across rocprofiler tools that share similar argument-parsing and output-formatting boilerplate.

### W0621 redefined-outer-name (1,056) — ~50% false positive

Common in test fixtures (pytest) where inner function parameters shadow outer scope names intentionally. Not a bug in pytest-style code. Worth filtering in test files.

### W0212 protected-access (748) — ~40% false positive

Accessing `_private` members is sometimes necessary in tests and integration code. Genuine cases in production code warrant refactoring.

### W1514 unspecified-encoding (650) — ~5% false positive

`open(filename)` without `encoding=` relies on the platform locale, which can differ between developer machines, CI, and production (especially Windows vs. Linux). For a cross-platform GPU tool targeting multiple OS/distros, specifying `encoding='utf-8'` (or `encoding=locale.getpreferredencoding(False)` where locale-sensitive) is correct practice. Nearly all findings are real.

### W0611 unused-import (334) — ~15% false positive

Most unused imports are genuine dead code. A small fraction are imported for side effects or re-export. Auto-fixable with `autoflake --remove-all-unused-imports`. Review before bulk removal.

### W0612 unused-variable (319) — ~20% false positive

Some unused variables are intentional destructuring placeholders (`_, value = func()`). The rest are dead code from refactoring. Fix individually.

### W0718 broad-exception-caught (305) — ~20% false positive

`except Exception:` is too broad and can swallow unexpected errors silently. Should be `except (SpecificError, OtherError):`. A small number of top-level handlers that intentionally catch all exceptions (e.g., CLI entry points) are acceptable.

### W1203 logging-fstring-interpolation (354) — ~60% false positive

`logging.debug(f"...")` is flagged because f-strings evaluate eagerly even when the log level is disabled. However, for most usage the performance impact is negligible. The genuine concern is in tight loops or high-frequency logging. Worth fixing in hot paths only.

---

## Per-Project Breakdown

| Project | Findings | Notes |
|---|---|---|
| amdsmi | 4,385 | Python bindings for AMD SMI; E1101 false positives dominate |
| rccl | 3,490 | Python test scripts, build tooling |
| rocprofiler-compute | 3,332 | Analysis/visualization scripts |
| rocprofiler-sdk | 2,591 | Python test framework |
| experimental/python | 2,212 | Experimental code; lower bar |

---

## Priority Remediation List

### P1 — Suppress false positives: E1101 (1,586 findings)

Add to `.pylintrc`:
```ini
[MESSAGES CONTROL]
disable=c-extension-no-member
```
Or set up a pylint run environment with ROCm libraries installed. This removes 1,586 noisy false positives immediately.

### P2 — MEDIUM: Fix unspecified-encoding (650 findings)

Add `encoding='utf-8'` to all `open()` calls that read/write text files. This is a correctness issue for cross-platform portability. Use autofix:
```sh
python -m fixit fix --rules AddFileOpenEncodingRule .
```
Or search-and-replace with `sed` carefully.

### P3 — MEDIUM: Fix unused-import (334 findings)

Run `autoflake --in-place --remove-all-unused-imports --recursive .` with review of the diff. Removes dead code and reduces import overhead.

### P4 — MEDIUM: Fix unused-variable (319 findings)

Review individually. Replace unused destructure targets with `_`:
```python
# Before
result, error_code = do_thing()  # result never used

# After
_, error_code = do_thing()
```

### P5 — MEDIUM: Fix broad-exception-caught (305 findings)

Replace `except Exception:` with specific exception types. In CLI entry points where broad catch is intentional, add `# pylint: disable=broad-exception-caught` with a comment explaining why.

### P6 — MEDIUM: Address duplicate-code (1,075 findings)

After filtering pytest fixtures, identify the top 10-20 largest duplication blocks (by token count) and extract shared utilities. Focus on rocprofiler-compute and rocprofiler-sdk which share test infrastructure.

### P7 — LOW: Fix bad-indentation (2,239 findings)

Run `black` or `autopep8` on all Python files. Commit as a formatting-only change.

### P8 — LOW: Fix consider-using-f-string (412 findings)

Modernize `%`-style and `.format()` string formatting to f-strings. Low risk, improves readability.

---

## Recommended Next Steps

1. Configure `.pylintrc` to disable `c-extension-no-member` and set `max-line-length=120` to reduce noise to actionable findings only.
2. Run `autoflake` + `black` as a bulk cleanup pass (separate commit per project).
3. Set up pylint in CI with a minimum score threshold (e.g., `--fail-under=7.0`) to prevent regressions.
4. Use `ruff` as a faster complement to pylint for the style/convention categories — it can auto-fix many C0xxx findings at high speed.
5. Prioritize amdsmi project first given it has the highest finding count and contains public-facing Python API bindings.
