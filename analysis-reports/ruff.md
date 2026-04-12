# Ruff Python Linting Analysis Report

**Date:** 2026-04-11
**Tool:** ruff (static analysis)
**Total Findings:** 51,967 across ~686 Python files

---

## Executive Summary

Ruff identified 51,967 issues across approximately 686 Python files in the rocm-systems monorepo. The majority of findings are style and annotation issues that are auto-fixable with `ruff --fix`. A meaningful subset involves security-relevant patterns (6,853 findings) and correctness issues (2,570 findings) that warrant human review.

The projects with the most findings are `rocprofiler-sdk` (7,301), `amdsmi` (6,827), `rccl` (6,238), `rocprofiler-compute` (5,639), and the experimental areas `rocjitsu` (4,857) and `python` (4,666).

---

## Findings by Group

### 1. Security (S* rules) — Needs Review

**Total: 6,853 findings**

| Rule | Count | What It Detects | Priority | Auto-fixable | False Positive Estimate |
|------|-------|-----------------|----------|--------------|-------------------------|
| S101 | 6,358 | `assert` used in production code | HIGH | No | Medium — asserts are valid in test code; many of these are in test files |
| S603 | 216 | `subprocess` call without `shell=False` check | HIGH | No | Low — most subprocess calls in build/tool scripts are intentional but should be audited |
| S108 | 92 | Hardcoded `/tmp` or temporary directory path | MEDIUM | No | Low — hardcoded temp paths can cause privilege escalation or race conditions |
| S608 | 75 | Possible SQL injection via string formatting | HIGH | No | Medium — depends on whether the string is user-controlled |
| S110 | 57 | `try/except/pass` silently swallows exceptions | MEDIUM | No | Low — almost always a real issue; silent failures are hard to debug |
| S607 | 55 | Partial executable path in `subprocess` (e.g. `"python"` not `"/usr/bin/python"`) | MEDIUM | No | Low — real risk in environments where PATH is not trusted |

**Notes:**

- **S101**: The 6,358 `assert` findings are the largest security-relevant group. In test files, `assert` is expected and correct. In production/library code, `assert` statements are stripped when Python runs with `-O` (optimize) flag, meaning runtime checks silently disappear. Audit non-test files for S101 and replace with explicit `if/raise` guards.
- **S603/S607**: Subprocess usage should be reviewed for shell injection risk and PATH manipulation. Prefer explicit absolute paths and `shell=False`.
- **S608**: SQL injection findings should be reviewed carefully. Any query constructed via f-strings or `%` formatting from externally supplied values is a real vulnerability.
- **S110**: Silent exception swallowing hides failures. Each instance should be replaced with at minimum a log statement.

**Recommended action:** Run `ruff check --select S` and review all non-test-file S101 hits. Audit S603, S608, and S607 findings manually.

---

### 2. Correctness (F* rules) — Medium Priority, Real Issues

**Total: ~1,962 findings**

| Rule | Count | What It Detects | Priority | Auto-fixable | False Positive Estimate |
|------|-------|-----------------|----------|--------------|-------------------------|
| F405 | 1,386 | Name may be from a wildcard (`*`) import — provenance unclear | MEDIUM | No | Medium — in legacy or generated code, wildcard imports are common; most names are valid but traceability is lost |
| F401 | 576 | Unused import | MEDIUM | Yes (with `--fix`) | Low — occasionally an import has side effects; check before removing |

**Notes:**

- **F405**: Wildcard imports (`from foo import *`) make it impossible for static tools (and humans) to know where a name came from. This inflates analysis uncertainty across the codebase. Replacing wildcard imports with explicit imports is the correct fix, but it requires understanding which names are actually used.
- **F401**: Unused imports are almost always real issues — dead code, copy-paste residue, or refactoring leftovers. `ruff --fix` can remove them automatically. Review the diff before committing since some imports are present for side effects.

**Recommended action:** Fix F401 with `ruff --fix --select F401`. Address F405 by replacing wildcard imports with explicit imports in high-traffic modules first.

---

### 3. Style (Q*, W*, I*, ANN* rules) — Low Priority, Auto-fixable

**Total: ~20,693 findings**

| Rule | Count | What It Detects | Priority | Auto-fixable | False Positive Estimate |
|------|-------|-----------------|----------|--------------|-------------------------|
| Q000 | 7,507 | Inconsistent quoting style (single vs. double quotes) | LOW | Yes | Very low — purely cosmetic |
| ANN001 | 5,242 | Missing type annotation for function argument | LOW | No | Very low — missing annotations are real gaps |
| ANN201 | 3,918 | Missing return type annotation for public function | LOW | No | Very low |
| W293 | 854 | Whitespace before colon / trailing whitespace in blank lines | LOW | Yes | Very low — purely cosmetic |
| W191 | 659 | Indentation contains tabs instead of spaces | LOW | Yes | Very low |
| ANN202 | 535 | Missing return type annotation for private function | LOW | No | Very low |
| I001 | 534 | Import block not sorted (isort-style) | LOW | Yes | Very low |

**Notes:**

- **Q000, W293, W191, I001**: These are fully mechanical style issues. They should be fixed project-wide with `ruff --fix` in a single formatting pass and then enforced in CI. No human review required.
- **ANN001, ANN201, ANN202**: Type annotations cannot be auto-inserted because ruff does not know the correct types. These require developer effort. Given 9,695 annotation gaps, a pragmatic approach is to enforce annotations only on new code via a `ruff` pre-commit hook (using `--select ANN` with `per-file-ignores` to exclude existing files) while incrementally annotating high-impact modules.

**Recommended action:** Apply `ruff --fix --select Q000,W293,W191,I001` across the codebase in a single batch commit. Treat ANN* as a longer-term typing initiative.

---

### 4. Modernization (UP*, PTH* rules) — Low Priority

**Total: ~1,814 findings**

| Rule | Count | What It Detects | Priority | Auto-fixable | False Positive Estimate |
|------|-------|-----------------|----------|--------------|-------------------------|
| PTH123 | 668 | Use `pathlib.Path.open()` instead of built-in `open()` | LOW | Yes | Very low |
| UP006 | 603 | Use `type` instead of `typing.Type` (Python 3.9+) | LOW | Yes | Very low — only valid if the project targets Python 3.9+ |
| PTH118 | 543 | Use `pathlib` instead of `os.path` | LOW | Yes | Very low |

**Notes:**

- **PTH123/PTH118**: These promote `pathlib` over the older `os.path` API. `pathlib` is more readable and less error-prone. Both are auto-fixable.
- **UP006**: Upgrading from `typing.Type[X]` to the built-in `type[X]` requires Python 3.9+. Confirm the minimum Python version for each project before applying. If the project supports Python 3.8, suppress this rule per project in `pyproject.toml`.

**Recommended action:** Apply PTH fixes with `ruff --fix --select PTH`. Apply UP006 only after confirming Python version requirements per project.

---

### 5. Code Quality (PLR*, TRY*, SLF*, T*, PLC*, N*, LOG* rules) — Medium Priority

**Total: ~8,645 findings**

| Rule | Count | What It Detects | Priority | Auto-fixable | False Positive Estimate |
|------|-------|-----------------|----------|--------------|-------------------------|
| T201 | 2,492 | `print()` statement in non-script code | MEDIUM | No | Medium — acceptable in CLI scripts and debug utilities; noise in library code |
| PLR2004 | 1,265 | Magic value used in comparison (e.g. `if x == 42`) | MEDIUM | No | Medium — some magic values are self-evident (0, 1, -1), others need named constants |
| PLC0415 | 1,057 | Import not at top of file (conditional/deferred import) | MEDIUM | No | Medium — lazy imports are sometimes intentional for performance or circular import avoidance |
| N806 | 737 | Variable name is not lowercase (PEP 8) | LOW | No | Medium — common in GPU/ML code where uppercase names mirror mathematical notation |
| TRY003 | 633 | Long exception message string passed directly to exception constructor | LOW | No | Low — messages should live in exception classes, not inline strings |
| LOG015 | 529 | Logging call issues (e.g. `logging.warning` at root logger level) | MEDIUM | No | Low — root logger usage in library code is a real anti-pattern |
| SLF001 | 521 | Private member access (`_name`) from outside the class | MEDIUM | No | Medium — in tests and friend modules this is intentional; in application code it signals fragile coupling |

**Notes:**

- **T201**: `print()` in library/SDK code is a code smell — it cannot be suppressed by the caller and pollutes stdout. Replace with `logging`. In CLI entry points and standalone scripts, `print()` is acceptable. Use `# noqa: T201` sparingly where print is intentional.
- **PLR2004**: Magic values make code harder to read and maintain. Introducing named constants (`MAX_RETRIES = 3`) is the correct fix. Low-value constants (0, 1, True, False, -1) can be suppressed with `per-file-ignores` or by configuring `allowed-magic-values` in `pyproject.toml`.
- **PLC0415**: Non-top-level imports are sometimes necessary (circular imports, optional heavy dependencies). Each instance should be evaluated: if the import is for performance, document it; if it is to work around a circular dependency, consider restructuring.
- **LOG015**: Using the root logger (`logging.warning(...)` instead of `logger = logging.getLogger(__name__)`) is an anti-pattern in library code. It hijacks the calling application's logging configuration.
- **SLF001**: Private member access in test files is expected. In production code it indicates a design smell — the accessed member should be made internal API or the accessing code refactored.

**Recommended action:** Address T201 (print statements) in library modules as part of a logging hygiene pass. Review PLC0415 and SLF001 findings in non-test code manually.

---

## Findings by Project

| Project | Findings | Notes |
|---------|----------|-------|
| projects/rocprofiler-sdk | 7,301 | Largest single project; likely needs annotation and style pass |
| projects/amdsmi | 6,827 | High finding count for a user-facing SDK; style + security audit recommended |
| projects/rccl | 6,238 | Communications library; S101 and T201 findings of particular concern |
| projects/rocprofiler-compute | 5,639 | Analysis tooling; acceptable higher print usage but should be reviewed |
| experimental/rocjitsu | 4,857 | Experimental; lower priority but style fixes still worthwhile |
| experimental/python | 4,666 | Experimental; lowest remediation priority |
| shared/kpack | 3,594 | Shared infrastructure; security and correctness fixes are higher priority here |
| projects/rocprofiler-systems | 2,458 | Moderate finding count |
| projects/rocm-smi-lib | 2,118 | System management library; S* and T201 worth reviewing |
| projects/rocprofiler | 1,945 | — |
| projects/roctracer | 899 | — |
| projects/clr | 555 | — |
| projects/rocm-core | 553 | — |
| nix/analysis | 511 | Build/analysis scripts; lower priority |
| projects/rocshmem | 497 | — |

---

## Recommended Remediation Plan

### Phase 1 — Automated fixes (low risk, high volume reduction)

Run the following in a single batch commit per project or across the whole repo:

```bash
ruff check --fix --select Q000,W293,W191,I001,F401,PTH123,PTH118,UP006 .
```

Expected reduction: approximately 11,000–13,000 findings (Q000, W293, W191, I001, F401, PTH*, UP006).

### Phase 2 — Security review (manual, high priority)

```bash
ruff check --select S .
```

- Triage all S101 findings: suppress in test files with `per-file-ignores`, replace with `if/raise` in production code.
- Manually review every S603, S607, S608 finding for actual exploitability.
- Fix S108 by using `tempfile` module functions instead of hardcoded paths.
- Fix S110 by adding at minimum a log statement in each bare `except: pass` block.

### Phase 3 — Code quality pass (manual, medium priority)

- Replace `print()` (T201) with `logging` calls in all library modules.
- Address PLR2004 by introducing named constants for non-obvious magic values.
- Review PLC0415 (non-top-level imports) and document or restructure.
- Review SLF001 (private member access) in non-test code.

### Phase 4 — Type annotation initiative (long-term)

- Enforce ANN* rules on new code via pre-commit hook.
- Incrementally annotate high-traffic public APIs (start with `amdsmi`, `rocprofiler-sdk`).
- Use `pyright` or `mypy` for deeper type checking once annotations reach sufficient coverage.

### CI Integration

Add to the project's CI pipeline:

```yaml
- name: Ruff lint
  run: ruff check --output-format=github .
```

Configure `ruff.toml` or `pyproject.toml` `[tool.ruff]` sections per project to:
- Set `target-version` to the correct minimum Python version (required for UP* rules).
- Use `per-file-ignores` to suppress S101 in `**/test_*.py` and `**/tests/**`.
- Set `allowed-magic-values` for PLR2004 to exclude `[0, 1, -1, 2]`.

---

## Summary Table

| Group | Findings | Priority | Auto-fixable | Action |
|-------|----------|----------|--------------|--------|
| Security (S*) | 6,853 | HIGH | No | Manual review required |
| Correctness (F*) | ~1,962 | MEDIUM | Partial (F401 yes) | Fix F401 automatically; review F405 |
| Style (Q*, W*, I*, ANN*) | ~20,693 | LOW | Partial (Q/W/I yes; ANN no) | Batch auto-fix style; plan annotation effort |
| Modernization (UP*, PTH*) | ~1,814 | LOW | Yes | Batch auto-fix after version check |
| Code Quality (PLR*, TRY*, SLF*, T*, PLC*, N*, LOG*) | ~8,645 | MEDIUM | No | Targeted manual fixes by module |
| **Total** | **~51,967** | — | ~13,000–15,000 auto-fixable | Phased remediation |
