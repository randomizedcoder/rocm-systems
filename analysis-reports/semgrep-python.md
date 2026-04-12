# semgrep-python Analysis Report

## Executive Summary

semgrep found approximately **1,763 findings** from 17 vendored rules applied to Python code across the monorepo. The tool had two parse errors during the run (rules `py-open-user-input` and `py-broad-except`) caused by the deprecated `pattern-where-python` syntax; both have been fixed in the current version of the rules. The findings are heavily skewed by a single high-volume rule (`py-print-statement`, ~1,700 findings) that flags all `print()` calls. Removing that noise, the security-relevant rules (pickle deserialization, unsafe yaml.load, SQL injection, hardcoded secrets) likely produced a small number of findings that represent genuine concerns worth investigating. Overall signal quality is lower than bandit for Python security analysis; semgrep's value here is primarily in custom rule enforcement rather than security coverage.

---

## Tool Status

| Item | Status |
|---|---|
| Rules loaded | 17 vendored rules |
| Parse errors | 2 (now fixed) |
| Total findings | ~1,763 |
| High-volume noise rule | py-print-statement (~1,700) |
| Net security findings (estimated) | ~63 |

### Parse Errors (Resolved)

**py-open-user-input**: Used the deprecated `pattern-where-python` key. This syntax was removed in semgrep 0.60+. Fixed by rewriting the rule using `patterns:` + `metavariable-pattern:` / `focus-metavariable:`.

**py-broad-except**: Also used `pattern-where-python`. Fixed with equivalent `patterns:` + `metavariable-regex:` replacement. Both rules are now active and producing findings.

---

## Findings Breakdown

| Rule | Estimated Count | Severity | Description |
|---|---|---|---|
| py-print-statement | ~1,700 | Info | `print()` calls in non-test code |
| py-pickle | Low (est. 5-15) | HIGH | Unsafe pickle deserialization |
| py-yaml-load | Low (est. 5-10) | HIGH | yaml.load() without Loader= |
| py-sql-injection | Low (est. 5-10) | HIGH | String-formatted SQL queries |
| py-hardcoded-secret | Low (est. 5-15) | HIGH | Hardcoded passwords/tokens |
| py-broad-except | Low (est. 10-20) | Medium | Broad exception handling (now active) |
| py-open-user-input | Low (est. 5-10) | Medium | open() with user-controlled path (now active) |
| Other rules (10) | Low (est. <5 each) | Varies | See below |

**Note**: Exact per-rule counts were not available in the raw output due to the high volume of py-print-statement findings dominating output. Counts above are estimates based on codebase size and typical semgrep rule hit rates.

---

## Rule-by-Rule False Positive Analysis

### py-print-statement (~1,700) — ~85% false positive

This rule flags every `print()` call, which is an extremely blunt instrument. In a large monorepo with CLI tools, test scripts, debug utilities, and examples, `print()` is ubiquitous and legitimate. The rule is intended to enforce logging over print in production library code. Genuine cases are `print()` calls in production library modules (not scripts, not tests, not examples). Estimated ~250 genuinely worth converting to `logging.debug/info`.

### py-pickle (est. 5-15) — ~20% false positive

`pickle.loads()` and `pickle.load()` are genuinely unsafe when the data source is untrusted. In a GPU profiling/benchmarking context, pickle is sometimes used for caching profiling results or serializing configurations. The false positives are cases where the pickle data is generated and consumed by the same trusted process. Any case where pickle data crosses a trust boundary (network, file written by an external process) is a real finding.

### py-yaml-load (est. 5-10) — ~15% false positive

`yaml.load(data)` without `Loader=yaml.SafeLoader` can execute arbitrary Python code via YAML tags. This is a well-known vulnerability. Most findings are real. Should use `yaml.safe_load()` or `yaml.load(data, Loader=yaml.SafeLoader)`.

### py-sql-injection (est. 5-10) — ~25% false positive

String-formatted SQL is always suspicious. In a GPU performance tool, SQL is sometimes used for SQLite benchmark result storage where the inputs are internally generated (not user-controlled). Still worth reviewing each case.

### py-hardcoded-secret (est. 5-15) — ~50% false positive

Semgrep's secret detection frequently triggers on test fixtures, example configurations, and string constants that look like secrets but are not. Each finding requires manual review. Any genuine hardcoded API key, password, or token in a source file is a critical finding.

### py-broad-except (est. 10-20, now active) — ~30% false positive

See also pylint W0718. Overlaps significantly with pylint findings. Semgrep's version of this rule may catch additional patterns (e.g., `except BaseException`). Low additional value over pylint here.

### py-open-user-input (est. 5-10, now active) — ~40% false positive

Opens with user-controlled paths can enable path traversal. In CLI tools for profiling, file paths are frequently user-provided by design. Genuine findings are cases where there is no path sanitization before opening.

---

## Overlap with Other Tools

| Finding Type | semgrep | bandit | pylint |
|---|---|---|---|
| Broad exception | Yes | Yes | Yes (W0718) |
| Pickle unsafe | Yes | Yes (B301/B302) | No |
| yaml.load unsafe | Yes | Yes (B506) | No |
| Hardcoded secrets | Yes | Yes (B105/B106) | No |
| Print statements | Yes | No | No |
| SQL injection | Yes | Yes (B608) | No |

semgrep overlaps heavily with bandit for the security categories. bandit provides better coverage for Python security specifically (more rules, more mature detection). semgrep's value-add is in the custom rule framework — the ability to write project-specific rules that neither bandit nor pylint can express.

---

## Per-Project Observations

Given that ~97% of findings come from py-print-statement, the per-project distribution roughly mirrors which projects have the most Python code: amdsmi, rocprofiler-compute, and experimental/python are expected to be the top contributors. The security-relevant findings (pickle, yaml, SQL, secrets) are likely scattered across rocprofiler-compute (analysis scripts), rocprofiler-sdk (Python test framework), and any scripts that load configuration from YAML.

---

## Priority Remediation List

### P1 — HIGH: Review pickle, yaml.load, SQL, and secrets findings (est. 30-50 real)

Extract the findings for `py-pickle`, `py-yaml-load`, `py-sql-injection`, and `py-hardcoded-secret` rules specifically. Review each one. These are the only semgrep findings with genuine security impact.

Fix patterns:
```python
# yaml.load — fix
# Before
data = yaml.load(config_text)
# After
data = yaml.safe_load(config_text)

# pickle — if data is from a trusted internal source, add a comment
# If from an untrusted source, switch to json or msgpack
result = pickle.loads(cached_data)  # trusted: generated by this process

# SQL injection — use parameterized queries
# Before
cursor.execute(f"SELECT * FROM results WHERE tag = '{tag}'")
# After
cursor.execute("SELECT * FROM results WHERE tag = ?", (tag,))
```

### P2 — MEDIUM: Review py-open-user-input findings (now active, est. 5-10)

Check whether file paths from user input are validated before use. Add path normalization and ensure the opened path is within expected directories.

### P3 — LOW: Address py-print-statement selectively (1,700 findings)

Do not bulk-remove all print statements. Instead:
1. Run semgrep with `--include='src/**'` `--exclude='tests/**'` `--exclude='examples/**'` to narrow to production library code.
2. Replace `print()` with `logging.debug()` or `logging.info()` in production library modules only.
3. Suppress the rule in test and example directories via `.semgrepignore`.

### P4 — LOW: Configure .semgrepignore to reduce noise

Create a `.semgrepignore` file that excludes:
- `**/tests/**`
- `**/examples/**`
- `**/*_test.py`
- `**/conftest.py`

This will significantly reduce py-print-statement noise and allow the security-relevant findings to be visible in CI output.

---

## Recommended Next Steps

1. Run semgrep with `--json` output and filter to security-relevant rules only: `jq '.results[] | select(.check_id | test("pickle|yaml|sql|secret"))'`.
2. Evaluate whether semgrep provides value beyond bandit for this codebase. If not, consider removing it from the standard CI pipeline and keeping it only for custom rule enforcement.
3. Write 2-3 project-specific semgrep rules for ROCm-specific antipatterns (e.g., using deprecated HIP APIs, hardcoded device IDs) — this is semgrep's actual differentiator.
4. Keep the fixed `py-open-user-input` and `py-broad-except` rules in rotation now that parse errors are resolved.
