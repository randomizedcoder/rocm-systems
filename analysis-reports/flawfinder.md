# Flawfinder Static Analysis Report — ROCm Systems Repository

**Tool:** flawfinder  
**Date:** 2026-04-11  
**Branch:** basic-static-analysis  
**Scope:** All C/C++ source files across projects/ subdirectories

---

## 1. Executive Summary

Flawfinder produced **3,359 findings** across the ROCm systems monorepo. The distribution skews heavily toward lower severity levels, which is typical for a large, mature C/C++ codebase where most findings are stylistic or context-dependent. However, a meaningful number of high-severity findings warrant focused review, particularly in privileged components (amdsmi, cuid).

### Severity Distribution

| Level | Count | % of Total | Characterization |
|-------|-------|------------|-----------------|
| 5     | 33    | 1.0%       | Highest concern — TOCTOU, unsafe exec |
| 4     | 421   | 12.5%      | High concern — TOCTOU, format strings, injection |
| 3     | 343   | 10.2%      | Medium concern — unbounded functions, race conditions |
| 2     | 1,862 | 55.4%      | Low-medium — common unsafe APIs, mostly context-dependent |
| 1     | 700   | 20.8%      | Informational — style, minor pattern matches |
| **Total** | **3,359** | **100%** | |

### Key Risk Signals

- **amdsmi** (system management interface, runs with elevated privileges): highest density of critical findings including popen, execvp, sscanf, sprintf, access() TOCTOU, chmod TOCTOU, and readlink TOCTOU.
- **cuid** (crypto key daemon): 3 chmod TOCTOU + 3 readlink TOCTOU findings — concerning in a security-sensitive daemon.
- **rocshmem**: 157 level-3+ findings, the second largest concentration — warrants review given network communication attack surface.
- **rocprofiler-systems**: 174 level-3+ findings — largest raw count but is an observability/tracing tool with broad file access.
- **Test suites** (hip-tests): several level-4+ findings including strncat overflow and execvp — test code has lower risk but still worth fixing as it sets patterns.

### Aggregate False Positive Estimate

Based on function-by-function analysis below:

| Category | Estimated False Positive Rate |
|----------|-------------------------------|
| Level 5 (readlink on /proc/self/exe) | ~70% FP (kernel-managed path) |
| Level 5 (chmod, strncat, execvp) | ~20% FP — needs review |
| Level 4 (access() TOCTOU) | ~40% FP (sysfs read-only probes) |
| Level 4 (format strings) | ~60% FP (literal format strings) |
| Level 3 (strlen, strncpy, snprintf) | ~65% FP |
| Level 2 (char buffer, memcpy, open) | ~80% FP |
| Level 1 (getenv, atoi, equal) | ~85% FP |

**Overall estimated real-bug or needs-review rate: ~15-20% of total findings (~500-670 items).**  
**Estimated items requiring immediate action: ~30-50 (concentrated in Level 5 and high-confidence Level 4).**

---

## 2. Per-Severity-Level Deep Analysis

---

### Level 5 Findings (33 total) — Critical

Level 5 is flawfinder's highest severity. Every finding at this level must be reviewed. The 33 findings break into four vulnerability classes.

---

#### 2.1.1 `readlink` TOCTOU — 24 findings

**Projects:** amdsmi (9), rocprofiler-systems (5), cuid (3), hipfile (3), rdc (1), rocshmem (1), hip-tests (1)

**Vulnerability Class:**  
`readlink()` is flagged for time-of-check/time-of-use (TOCTOU) races and for returning non-null-terminated buffers. The canonical flawfinder concern is: the symlink target could change between the `readlink` call and subsequent use of the resolved path.

**Context-Specific Analysis:**

The dominant use pattern in systems code of this type is reading `/proc/self/exe` to discover the running executable's path for locating sibling resources (libraries, config files, assets). This pattern is:

- **Not vulnerable to TOCTOU**: `/proc/self/exe` is a kernel-maintained virtual symlink. No unprivileged process can redirect it to a different target between `readlink` and subsequent use. The kernel guarantees the mapping reflects the actual executable for the lifetime of the process.
- **Not vulnerable to symlink injection**: The attacker would need to control `/proc/<pid>/exe`, which requires kernel-level access.

The **real concern** with `readlink` is the missing null terminator — `readlink` does not null-terminate. If the call site does not manually null-terminate the buffer (`buf[ret] = '\0'`), downstream string operations will read past the buffer. This is a genuine bug where it occurs.

**Classification by sub-case:**

| Sub-case | Classification | Reasoning |
|----------|---------------|-----------|
| `readlink("/proc/self/exe", ...)` with manual null-term | LIKELY FALSE-POSITIVE | Kernel path, null-term handled |
| `readlink("/proc/self/exe", ...)` without null-term check | NEEDS-REVIEW | Real buffer overread risk |
| `readlink` on user-supplied or env-derived paths | REAL BUG | TOCTOU is genuine |
| `readlink` in privileged daemon (cuid) on arbitrary path | NEEDS-REVIEW | Daemon context elevates risk |

**Recommended Action:**
- Audit all 24 call sites for: (a) whether the path argument is `/proc/self/exe` or similar kernel-safe path, and (b) whether the return value is used to null-terminate the buffer.
- For any non-`/proc` path in a privileged context, convert to `open(O_PATH | O_NOFOLLOW)` + `fstat` pattern or use `realpath(3)` carefully.
- In cuid specifically, treat all 3 findings as NEEDS-REVIEW regardless of path.

---

#### 2.1.2 `chmod` TOCTOU — 5 findings

**Projects:** amdsmi (2), cuid (3)

**Vulnerability Class:**  
TOCTOU between checking a file's existence/type and calling `chmod` on it. If an attacker can replace the target file (or a directory component of its path) with a symlink between the check and the `chmod`, they can cause `chmod` to modify permissions on an unintended file. In a setuid or daemon context, this can escalate privileges or corrupt security boundaries.

**Context-Specific Analysis:**

- **cuid** is a crypto key daemon. It almost certainly manages key files and certificate paths. `chmod` on key material in a TOCTOU-vulnerable way is a genuine security concern — an attacker with local filesystem access could redirect a `chmod 600` call to a world-readable file or vice versa, enabling privilege escalation or secret disclosure.
- **amdsmi** runs with elevated privileges for hardware management. TOCTOU on device-related file permissions could affect GPU access controls.

**Classification:**

| Location | Classification | Reasoning |
|----------|---------------|-----------|
| cuid — all 3 | NEEDS-REVIEW (likely REAL BUG) | Crypto daemon + file permission changes = high-value TOCTOU target |
| amdsmi — both 2 | NEEDS-REVIEW | Elevated privilege context makes TOCTOU exploitable |

**Recommended Action:**
- Replace `chmod(path, ...)` with `open(path, O_NOFOLLOW) + fchmod(fd, ...)` pattern. Using the file descriptor eliminates the TOCTOU window.
- In cuid, audit that key files are always created in directories with restricted permissions (chmod 700 on parent directory) to shrink the attack window even before the fix.

---

#### 2.1.3 `strncat` buffer overflow — 3 findings

**Projects:** hip-tests (3)

**Vulnerability Class:**  
`strncat(dst, src, n)` is frequently misused: the `n` parameter limits bytes copied from `src`, but it does NOT account for the existing content of `dst`. If `n` is set to `sizeof(dst)` instead of `sizeof(dst) - strlen(dst) - 1`, a buffer overflow occurs when `dst` already contains data.

**Context-Specific Analysis:**

These are in hip-tests, which are test binaries, not production code. However:
- Test binaries are compiled and executed on CI infrastructure and developer machines.
- Buffer overflows in test harness code can corrupt test results, produce misleading output, or in rare cases be exploited if test infrastructure is shared.
- The pattern is often introduced by copy-paste of incorrect strncat usage.

**Classification:** NEEDS-REVIEW (borderline REAL BUG)

**Reasoning:** strncat misuse is a genuine code defect. Even in test code, the overflow can cause undefined behavior. The fix is mechanical and low-risk.

**Recommended Action:**
- Review all 3 call sites for the `n` argument. If `n = sizeof(dst)` or `n = BUFSIZE` without subtracting existing length, fix to `n = sizeof(dst) - strlen(dst) - 1`.
- Better yet, replace with `snprintf(dst + strlen(dst), sizeof(dst) - strlen(dst), "%s", src)` or use `std::string` in C++ test code.

---

#### 2.1.4 `execv`/`execvp` — 1 finding

**Projects:** amdsmi (1)

**Vulnerability Class:**  
`execvp` searches `PATH` to resolve the executable. If `PATH` is attacker-controlled or the calling process inherits a manipulated environment, `execvp("tool", ...)` can be hijacked to execute a malicious binary.

**Context-Specific Analysis:**

amdsmi is a system management interface. If it calls `execvp` with a non-absolute path, and if the `PATH` environment variable can be influenced by the invoking user (e.g., via a setuid wrapper, a D-Bus service, or a privileged helper), this is a real privilege escalation vector.

**Classification:** NEEDS-REVIEW (likely REAL BUG in privileged context)

**Reasoning:** Even if amdsmi is not strictly setuid, it likely runs as root or with CAP_SYS_ADMIN. `execvp` with a relative binary name in a privileged process is a well-known exploitation primitive.

**Recommended Action:**
- Replace `execvp("tool", ...)` with `execv("/absolute/path/to/tool", ...)`.
- If the absolute path must be discovered at runtime, resolve it once at startup via `realpath` on a known safe base path and store it.
- Sanitize the environment before `exec` (at minimum, reset `PATH` to `/usr/bin:/bin`).

---

### Level 4 Findings (421 total) — High

Level 4 findings represent significant security concerns that require contextual review but are not automatically critical.

---

#### 2.2.1 `access()` TOCTOU — ~60+ findings

**Projects:** amdsmi, rdc, hip-tests, rocprofiler-systems, rocshmem

**Vulnerability Class:**  
`access(path, mode)` checks file permissions using the real UID/GID, not the effective UID/GID. The classic TOCTOU: a file that passes `access()` at check time may be replaced by a symlink before the subsequent `open()`. In setuid/privileged processes, an attacker can exploit this window to access files they shouldn't.

**Context-Specific Analysis:**

The ROCm codebase makes heavy use of `access()` for probing sysfs paths (e.g., `/sys/bus/pci/devices/...`) and device nodes. Most of these are probing for existence/readability of hardware paths:

- **Sysfs probes (read-only, existence check):** An attacker cannot meaningfully exploit TOCTOU on sysfs paths — the kernel owns those paths, and symlink attacks in `/sys` are not user-controllable. These are **likely false positives**.
- **User-supplied or writable directory paths in a privileged context:** These ARE exploitable. amdsmi probing user-provided device paths with `access()` before `open()` is a real concern.
- **rdc (ROCm Data Center tool):** Runs as a system daemon with broad hardware access. `access()` TOCTOU in rdc on non-sysfs paths is NEEDS-REVIEW.

**Classification by sub-case:**

| Sub-case | Classification | Reasoning |
|----------|---------------|-----------|
| `access()` on `/sys/...` or `/dev/...` kernel paths | LIKELY FALSE-POSITIVE | Kernel controls these paths |
| `access()` on user-supplied paths in amdsmi/rdc | NEEDS-REVIEW | Privileged process + user input = exploitable |
| `access()` in test code | LIKELY FALSE-POSITIVE | No privilege escalation vector |
| `access()` in rocprofiler-systems on trace output paths | NEEDS-REVIEW | Depends on whether output path is attacker-controllable |

**Recommended Action:**
- Audit amdsmi and rdc specifically. Replace `access()+open()` patterns on user-controllable paths with `open(O_NOFOLLOW)` + error handling on ENOENT/EACCES.
- Document sysfs probes as intentional so future reviews can skip them.

---

#### 2.2.2 `sscanf`/`fscanf` without width limits — ~22 findings

**Projects:** amdsmi (dominant)

**Vulnerability Class:**  
`sscanf(buf, "%s", dest)` without a width specifier reads until whitespace with no bound on `dest`. If `buf` comes from external input and `dest` is a fixed-size buffer, this is a classic stack buffer overflow.

**Context-Specific Analysis:**

amdsmi parses hardware attributes, sensor data, and system files. If any of these `sscanf` calls parse data from:
- `/sys/class/drm/...` attributes (kernel-provided): **LIKELY FALSE-POSITIVE** — kernel output is bounded and well-formed.
- Network-received data or user-provided strings: **REAL BUG**.
- Parsed config files or CLI arguments: **NEEDS-REVIEW**.

In practice, most amdsmi `sscanf` calls likely parse sysfs attributes, making many of these false positives. However, the pattern is bad practice regardless.

**Classification:** NEEDS-REVIEW (some likely REAL BUG if parsing user data)

**Recommended Action:**
- Add width specifiers to all `%s` in `sscanf`: e.g., `sscanf(buf, "%255s", dest)` for a 256-byte buffer.
- This is a low-effort, high-safety-margin fix. Apply globally.

---

#### 2.2.3 `sprintf` without bounds — ~10 findings

**Projects:** amdsmi (dominant)

**Vulnerability Class:**  
`sprintf(buf, fmt, ...)` has no bounds checking. If the formatted output exceeds `buf`'s size, the stack or heap is overwritten.

**Context-Specific Analysis:**

In amdsmi, these likely build sysfs paths or format strings for hardware queries. Path construction with fixed prefixes and bounded hardware identifiers (e.g., PCI bus IDs) may not overflow in practice, but the code is fragile.

**Classification:** NEEDS-REVIEW

**Reasoning:** Even if values are currently bounded, code evolution can introduce longer strings. The fix is mechanical.

**Recommended Action:**
- Replace all `sprintf` with `snprintf(buf, sizeof(buf), ...)`.
- In C++ code, prefer `std::string` + `std::format` or `fmt::format`.

---

#### 2.2.4 `snprintf` format string — ~20 findings across projects

**Vulnerability Class:**  
flawfinder flags `snprintf` for potential format string vulnerabilities when the format argument is not a string literal. `snprintf(buf, n, user_input)` where `user_input` is attacker-controlled allows arbitrary read/write via `%n`, `%x`, etc.

**Context-Specific Analysis:**

In systems code, `snprintf` with a non-literal format is rarely intentional. Most flagged cases are likely:
- `snprintf(buf, n, "%s", var)` — safe, the format is a literal.
- `snprintf(buf, n, var)` — only if `var` is a non-literal; this is a real bug.

flawfinder flags both patterns, making false positive rate high here.

**Classification:** LIKELY FALSE-POSITIVE (for literal formats) / REAL BUG (for non-literal format argument)

**Recommended Action:**
- Scan for `snprintf(buf, n, var)` where the third argument is not a string literal. Fix those specifically with `snprintf(buf, n, "%s", var)`.

---

#### 2.2.5 `printf`/`fprintf` format string — ~15 findings across projects

**Classification:** Same analysis as snprintf above.

- `printf(var)` with non-literal: REAL BUG — fix to `printf("%s", var)`.
- `printf("%s", var)`: LIKELY FALSE-POSITIVE for the format string concern.

**Recommended Action:**
- Grep specifically for `printf(var)` and `fprintf(fd, var)` patterns where the second argument of `fprintf` or the first of `printf` is not a string literal. These are the actionable items.

---

#### 2.2.6 `popen` shell injection — 2 findings

**Projects:** amdsmi (2)

**Vulnerability Class:**  
`popen(cmd, "r")` passes `cmd` to `/bin/sh -c`. If any component of `cmd` includes attacker-controlled data, shell metacharacters enable command injection.

**Context-Specific Analysis:**

amdsmi running with elevated privileges calling `popen` is a serious concern. Even if the command string is currently hardcoded, this pattern is dangerous because:
1. Future code changes may introduce user-supplied arguments.
2. Environment variable injection (e.g., `IFS`, `PATH`) can affect shell execution.

**Classification:** NEEDS-REVIEW (likely REAL BUG in privileged context)

**Recommended Action:**
- Replace `popen` with `fork()+exec()+pipe()` to avoid shell invocation entirely.
- If popen is kept, ensure the command string is fully hardcoded with no variable components, and reset the environment before the call.

---

#### 2.2.7 `strcpy` — 1 finding

**Projects:** amdsmi (1)

**Classification:** NEEDS-REVIEW

**Recommended Action:** Replace with `strncpy` + explicit null-termination, or `strlcpy` if available, or use `std::string` in C++ contexts.

---

#### 2.2.8 `execvp` in test code — 1 finding

**Projects:** hip-tests (1)

**Classification:** LIKELY FALSE-POSITIVE

**Reasoning:** Test code running under a test harness with a controlled environment is at much lower risk. Still worth converting to `execv` with an absolute path for correctness.

---

### Level 3 Findings (343 total) — Medium

Level 3 findings are significant but typically require specific conditions to be exploitable. The 343 findings span a range of function categories.

---

#### 2.3.1 `strlen` — ~155 findings

**Vulnerability Class:**  
`strlen` on a buffer that may not be null-terminated, or use of the returned length without bounds checking in subsequent operations.

**Classification:** LIKELY FALSE-POSITIVE (majority)

**Reasoning:** flawfinder flags `strlen` generically. The actual risk depends on whether the input is guaranteed null-terminated. In C++ code using `std::string::c_str()`, this is completely safe. In C code with char arrays, only risky if the null-terminator guarantee is broken upstream.

**Recommended Action:** No bulk action needed. Review only `strlen` calls on buffers received directly from external input (network, file, environment) without prior null-terminator validation.

---

#### 2.3.2 `strncpy` — ~154 findings (estimated)

**Vulnerability Class:**  
`strncpy(dst, src, n)` does not guarantee null-termination if `src` is longer than `n`. The destination buffer may not be null-terminated, causing subsequent string operations to overread.

**Classification:** NEEDS-REVIEW (style-adjacent but has real failure modes)

**Reasoning:** `strncpy` is widely considered a poorly-designed API. While most call sites in mature codebases are correct, the pattern of forgetting `dst[n-1] = '\0'` is common enough to warrant spot-checks.

**Recommended Action:**
- Audit call sites where `n == strlen(src)` or `n == sizeof(dst)` without a subsequent explicit null-termination.
- In C++ code, prefer `std::string` or `std::string_view`.

---

#### 2.3.3 `snprintf` (level 3 variants) — ~79 findings

These overlap with Level 4 snprintf analysis. At Level 3, these are typically `snprintf` calls where the buffer size argument is suspicious (e.g., could be zero, or comes from an untrusted source).

**Classification:** NEEDS-REVIEW

---

#### 2.3.4 Projects with highest Level-3+ density

| Project | Count | Risk Context |
|---------|-------|--------------|
| rocprofiler-systems | 174 | Tracing/observability, broad file access, moderate risk |
| rocshmem | 157 | Network/shared memory communication, higher attack surface |
| clr | 93 | OpenCL runtime, processes GPU program input |
| hip-tests | 85 | Test suite, lower production risk |
| rocprofiler-sdk | 84 | Profiling SDK, handles user program input |
| amdsmi | 55 | System management, elevated privileges — highest per-finding risk |

---

### Level 2 Findings (1,862 total) — Low-Medium

Level 2 represents the bulk of findings (55.4%). These are primarily pattern matches on commonly-misused functions.

---

#### 2.4.1 `char` buffer declarations — 817 findings

**Vulnerability Class:**  
Fixed-size `char` arrays flagged for potential overflow if used with unsafe string functions.

**Classification:** STYLE-ONLY (in isolation)

**Reasoning:** flawfinder flags `char buf[N]` declarations as a generic indicator of potential buffer operations. The declaration itself is not a vulnerability. The actual risk depends entirely on what operations are performed on the buffer.

**Recommended Action:** No direct action on these findings. They are useful as a density map — areas with many char buffer declarations combined with higher-severity findings in the same file warrant closer review.

---

#### 2.4.2 `open` — 526 findings

**Vulnerability Class:**  
`open()` without `O_NOFOLLOW` can follow symlinks; `open()` on paths constructed from untrusted input can open unintended files.

**Classification:** LIKELY FALSE-POSITIVE (majority)

**Reasoning:** `open()` on hardcoded kernel paths (`/sys/...`, `/dev/...`, `/proc/...`) is standard systems programming. The symlink risk is only meaningful when: (a) the path includes a directory component writable by untrusted users, and (b) the calling process has privileges the attacker wants to leverage.

**Recommended Action:**
- In amdsmi and rdc (privileged daemons), audit `open()` calls on paths with user-controlled components. Add `O_NOFOLLOW` where symlink following is not required.
- In test code and non-privileged libraries, these are overwhelmingly false positives.

---

#### 2.4.3 `read` — 328 findings

**Vulnerability Class:**  
`read()` return value not checked; reading into a fixed-size buffer without bounds; reading more bytes than buffer can hold.

**Classification:** NEEDS-REVIEW (for unchecked return values) / LIKELY FALSE-POSITIVE (for general flagging)

**Reasoning:** Unchecked `read()` return values are a real correctness bug (short reads, errors treated as success). Buffer size mismatches are context-dependent.

**Recommended Action:**
- Focus review on `read()` calls where the return value is not checked or not used to bound subsequent operations.

---

#### 2.4.4 `memcpy` — 267 findings

**Vulnerability Class:**  
`memcpy` with incorrect size argument can overflow destination buffer.

**Classification:** LIKELY FALSE-POSITIVE (majority)

**Reasoning:** `memcpy` in systems/GPU code is pervasive and usually correct. The vulnerability requires the size argument to be wrong. flawfinder cannot determine this statically without data flow analysis.

**Recommended Action:** No bulk action. These findings are useful context when investigating a specific buffer overflow.

---

#### 2.4.5 `getenv` — 218 findings

**Vulnerability Class:**  
`getenv` returns a pointer to the environment that can be modified by child processes in some threading models; environment variables are attacker-controllable in many invocation contexts; the returned pointer can be invalidated by subsequent `putenv`/`setenv` calls.

**Classification:** NEEDS-REVIEW in privileged code / LIKELY FALSE-POSITIVE in user-space tools

**Reasoning:**
- In amdsmi and cuid (privileged), `getenv` of security-sensitive variables (e.g., `LD_PRELOAD`, `PATH`, `HOME`, config paths) is a real concern. Privileged processes should sanitize the environment at startup.
- In GPU runtime libraries (HIP, ROCm), `getenv` for configuration knobs (e.g., `HIP_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES`) is the intended design. These are not vulnerabilities.
- The 218 findings are overwhelmingly the latter category.

**Recommended Action:**
- For amdsmi and cuid specifically, audit `getenv` calls for security-sensitive variable names. Consider calling `clearenv()` + repopulating known-safe variables at startup.
- For GPU runtime libraries: document these as intentional design.

---

### Level 1 Findings (700 total) — Informational

Level 1 findings are largely informational pattern matches. They are useful for code quality tracking but rarely indicate security vulnerabilities.

---

#### 2.5.1 `atoi` — 131 findings

**Vulnerability Class:**  
`atoi` does not detect overflow and returns 0 on parse failure with no error indication.

**Classification:** STYLE-ONLY

**Reasoning:** `atoi` overflow is not a security vulnerability in the traditional sense — it produces a wrong numeric value, not a memory corruption. It can cause incorrect behavior (e.g., wrong GPU device index selected) but is not directly exploitable for code execution.

**Recommended Action:**
- In user-facing CLI tools, prefer `strtol` with error checking for better diagnostics.
- In internal/config parsing, `atoi` is acceptable if inputs are bounded by design.

---

#### 2.5.2 `equal` — 43 findings (std::equal or similar)

**Vulnerability Class:**  
`std::equal` without explicit end iterator (two-range version) can overrun the second range if it is shorter than the first.

**Classification:** NEEDS-REVIEW (C++14 and earlier) / LIKELY FALSE-POSITIVE (C++17 and later)

**Reasoning:** The three-argument `std::equal(first1, last1, first2)` assumes the second range is at least as long as the first. C++17 added the four-argument version. If the codebase uses C++17+, most of these are false positives. If C++14 or earlier is used anywhere, these warrant review.

**Recommended Action:**
- Determine the C++ standard version used per project.
- For C++14 or earlier targets, audit `std::equal` call sites for range length assumptions.

---

#### 2.5.3 `srand` / `rand` — 31 findings

**Vulnerability Class:**  
`srand`/`rand` produce predictable sequences. If used for security purposes (key generation, nonces, session tokens), this is a real vulnerability.

**Classification:** LIKELY FALSE-POSITIVE (in GPU/HIP context) / REAL BUG (in cuid)

**Reasoning:**
- GPU test code uses `rand()` for test data generation — this is fine.
- cuid handles cryptographic keys. Any use of `srand`/`rand` in cuid for anything security-relevant is a critical vulnerability. However, cuid likely uses proper crypto APIs for keys.

**Recommended Action:**
- Audit `srand`/`rand` usage specifically in cuid. Replace with `getrandom(2)` or `/dev/urandom` reads for any security-relevant randomness.

---

#### 2.5.4 `usleep` — 35 findings

**Classification:** STYLE-ONLY

**Reasoning:** `usleep` is deprecated in POSIX in favor of `nanosleep`. Not a security concern.

**Recommended Action:** Low priority. Replace with `nanosleep` or `std::this_thread::sleep_for` on an as-touched basis.

---

#### 2.5.5 `realpath` — 62 findings (mixed Level 4/3/2)

**Vulnerability Class:**  
`realpath` has TOCTOU issues similar to `readlink`. The resolved path may no longer be valid by the time it is used. Additionally, older implementations had buffer overflow issues (pre-POSIX.1-2008 `realpath` with NULL second argument is safer; fixed-size buffer versions are not).

**Classification:** NEEDS-REVIEW in privileged code / LIKELY FALSE-POSITIVE elsewhere

**Recommended Action:**
- Use `realpath(path, NULL)` (POSIX.1-2008) which allocates a buffer of the correct size.
- In privileged code, use the resolved path only for logging/display; use `open(O_PATH | O_NOFOLLOW)` for actual file operations to close the TOCTOU window.

---

#### 2.5.6 `readlink` — 24 findings (see Level 5 analysis above)

These were addressed in Section 2.1.1.

---

## 3. Per-Project Risk Summary

| Project | Level 3+ Count | Privilege Level | Key Concerns | Overall Risk |
|---------|---------------|-----------------|--------------|--------------|
| **amdsmi** | 55 (+ many L4/L5) | Elevated (system mgmt) | popen, execvp, sscanf, sprintf, access() TOCTOU, chmod TOCTOU, readlink TOCTOU | **HIGH** |
| **cuid** | 18 | High (crypto daemon) | chmod TOCTOU (3), readlink TOCTOU (3), srand/rand risk | **HIGH** |
| **rocshmem** | 157 | User-space w/ network | Buffer ops, readlink, access() — large count warrants audit | **MEDIUM-HIGH** |
| **rocprofiler-systems** | 174 | User-space tracing | Large surface area, file access patterns, mostly false positives | **MEDIUM** |
| **clr** | 93 | User-space OpenCL runtime | Processes user program input (kernels), buffer ops | **MEDIUM** |
| **rocprofiler-sdk** | 84 | User-space profiling | Handles user program instrumentation | **MEDIUM** |
| **hip-tests** | 85 | Test binaries | strncat overflow (real), execvp (low risk in test), CI infrastructure | **LOW-MEDIUM** |
| **hipfile** | 37 | User-space | readlink TOCTOU (3), file ops | **LOW-MEDIUM** |
| **rdc** | 36 | System daemon | access() TOCTOU, readlink | **MEDIUM** |
| **aqlprofile** | 21 | GPU runtime | Buffer ops | **LOW** |
| **rocprofiler-compute** | 9 | User-space | Minor findings | **LOW** |
| **rocr-debug-agent** | 9 | Debug tool | Minor findings | **LOW** |

---

## 4. Priority Remediation List

Ordered by: (severity × privilege level × exploitability).

### P0 — Fix Immediately (amdsmi, cuid — privileged code)

1. **amdsmi: `execvp` with relative path** — Replace with `execv("/absolute/path", ...)` + environment sanitization.
2. **amdsmi: `popen` calls (2)** — Replace with `fork()+exec()+pipe()` to eliminate shell injection surface.
3. **cuid: `chmod` TOCTOU (3)** — Replace `chmod(path, mode)` with `open(O_NOFOLLOW)+fchmod(fd, mode)` pattern.
4. **amdsmi: `chmod` TOCTOU (2)** — Same fix as above.
5. **cuid: `readlink` TOCTOU (3)** — Audit for non-`/proc` paths; add null-termination checks; use `O_PATH` pattern where feasible.
6. **amdsmi: `sscanf` without width limits (~22)** — Add `%Ns` width specifiers matching destination buffer sizes.
7. **amdsmi: `sprintf` without bounds (~10)** — Replace with `snprintf(buf, sizeof(buf), ...)`.

### P1 — Fix Before Next Release

8. **hip-tests: `strncat` buffer overflow (3)** — Audit `n` argument against existing buffer contents; fix or replace with `snprintf`.
9. **amdsmi/rdc: `access()+open()` on user-controllable paths** — Replace with `open(O_NOFOLLOW)` + error handling.
10. **All projects: `printf(var)` / `fprintf(fd, var)` non-literal format strings** — Grep and fix to `printf("%s", var)`.
11. **cuid: `srand`/`rand` audit** — Ensure no security-relevant randomness uses these functions.

### P2 — Fix in Ongoing Refactoring

12. **amdsmi/rdc: `readlink` on non-`/proc` paths** — Convert to `O_PATH` + `fstat` pattern.
13. **`getenv` in privileged code (amdsmi, cuid)** — Sanitize environment at startup; document intended env vars.
14. **All projects: `strncpy` without explicit null-termination** — Add `dst[n-1] = '\0'` or replace with safer alternatives.
15. **`realpath` in privileged code** — Switch to `realpath(path, NULL)` form and use `fds` for subsequent file operations.
16. **`std::equal` three-argument form** — Review against C++ standard version; update if targeting C++14 or earlier.

### P3 — Technical Debt / Code Quality

17. Replace `atoi` with `strtol`+error checking in user-facing CLI code.
18. Replace `usleep` with `nanosleep`/`std::this_thread::sleep_for` on an as-touched basis.
19. Replace all `sprintf` with `snprintf` (mechanical, low-risk change).
20. Replace `char` buffers + `strcpy`/`strcat` patterns with `std::string` where appropriate in C++ code.

---

## 5. Recommended Process Improvements

1. **Add flawfinder to CI with a severity threshold.** Block merges on any new Level 5 findings; warn on new Level 4 findings in amdsmi and cuid.
2. **Create a per-project allowlist** for known false positives (e.g., `/proc/self/exe` readlink, sysfs `access()` probes) to reduce noise and focus reviewer attention on genuinely new findings.
3. **Adopt static analysis suppression annotations** (e.g., `/* flawfinder: ignore */` with required justification comment) for intentional patterns, creating an audit trail.
4. **Priority audit order for manual review:** amdsmi → cuid → rdc → rocshmem → clr → rocprofiler-systems.

---

*Report generated by Claude Code static analysis agent. All classifications are heuristic and based on code context, privilege model, and common vulnerability patterns. Manual review is required before taking remediation action.*
