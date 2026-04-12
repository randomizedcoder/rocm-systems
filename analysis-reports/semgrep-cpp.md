# Semgrep C/C++ Static Analysis Report

**Date:** 2026-04-11
**Branch:** basic-static-analysis
**Tool:** Semgrep (C/C++ rules)

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total findings | 34,525 |
| Rules triggered | 51 |
| Files analyzed | 5,131 |
| Unique rule hits (text output) | 10,745 |
| Parse errors | 1 (goto-usage — semgrep cannot parse C++ goto patterns) |
| Timeout events | rocjitsu/vop3.cpp (large generated file) |

The scan surfaces a broad range of issues spanning safety-critical GPU memory management, concurrency hazards, and C-style code patterns. Priority should be given to findings in core runtime projects (clr, rocr-runtime, rccl) over test code (hip-tests).

---

## Priority Classification Matrix

| Priority | Projects |
|----------|----------|
| HIGHEST | projects/clr, projects/rocr-runtime, projects/rccl |
| HIGH | projects/rocprofiler-sdk, projects/rocprofiler, projects/rocprofiler-systems, projects/rocshmem |
| MEDIUM | projects/amdsmi, projects/rocdecode, projects/rdc, experimental/rocjitsu |
| LOWER | projects/hip-tests (test code) |

---

## Findings by Project

| Project | Findings |
|---------|----------|
| projects/hip-tests | 794 |
| projects/rocr-runtime | 181 |
| projects/clr | 150 |
| projects/rccl | 128 |
| projects/rocprofiler-systems | 97 |
| projects/rocprofiler | 96 |
| projects/rocprofiler-sdk | 93 |
| projects/rocshmem | 74 |
| experimental/rocjitsu | 47 |
| projects/amdsmi | 28 |
| projects/rocdecode | 26 |
| projects/rdc | 19 |

---

## Rule-by-Rule Analysis

Rules are grouped by risk level, highest first. Count and classification are listed for each.

---

### CRITICAL

---

#### `memcpy-sizeof-pointer` — 100 findings

**Description:** A `memcpy` call passes `sizeof(ptr)` (typically 8 bytes on 64-bit systems) instead of `sizeof(*ptr)` or the actual buffer size. This copies only the pointer-width number of bytes regardless of the pointee type, silently truncating the copy.

**Risk:** CRITICAL

**Classification:** REAL BUG

**False positive estimate:** ~5%

**Context:** This pattern almost always indicates a genuine defect. The sizeof operator applied to a pointer variable yields the pointer size (8 bytes on x86-64/aarch64), not the size of the data it points to. In GPU/HPC code, this means device-to-host or host-to-device copies silently transfer 8 bytes when far more data was intended, causing data corruption that is difficult to detect at runtime.

**Recommended action:**
- **Treat every instance as a confirmed bug until proven otherwise.**
- Replace `sizeof(ptr)` with `sizeof(*ptr)` or the correct byte count.
- Add a targeted code review pass across all projects, prioritizing rocr-runtime, clr, and rccl.
- Consider adding a sanitizer or custom semgrep rule to CI to prevent regressions.

---

#### `dangling-c-str` — 59 findings

**Description:** `.c_str()` is called on a temporary `std::string` object. The returned pointer becomes dangling as soon as the temporary is destroyed at the end of the full expression, resulting in a use-after-free.

**Risk:** CRITICAL

**Classification:** REAL BUG

**False positive estimate:** ~10%

**Context:** This is a classic C++ lifetime pitfall. Common patterns include passing `.c_str()` on a `std::string` returned from a function directly to a C API, or storing the pointer without keeping the owning string alive. In multithreaded GPU runtimes, the resulting dangling pointer can cause hard-to-reproduce crashes or silent memory corruption.

**Recommended action:**
- Assign the `std::string` to a named local variable before calling `.c_str()`, ensuring the variable outlives the pointer's use.
- Review every instance manually; the false positive rate is low.
- Prioritize findings in rocr-runtime and rccl where the risk of runtime crashes is highest.

---

### HIGH

---

#### `hip-unchecked-malloc` — 1,267 findings

**Description:** `hipMalloc` return value is not checked. `hipMalloc` returns a `hipError_t`; ignoring it means allocation failures are silently swallowed, and subsequent operations on the uninitialized pointer produce undefined behavior or data corruption.

**Risk:** HIGH (CRITICAL in library/runtime code)

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~15% (some wrappers handle errors internally)

**Context:** In hip-tests (test code), unchecked mallocs are lower priority — test failures are acceptable. In library and runtime code (clr, rocr-runtime, rccl, rocprofiler-sdk), an unchecked allocation failure leads to null or garbage pointer dereferences and silent data corruption. This is the highest-volume finding in the scan.

**Recommended action:**
- In core runtime projects: treat as HIGH priority, add error checking or use a wrapper that asserts/throws on failure.
- In test projects: acceptable to defer, but consider adding a test helper macro (e.g., `HIP_CHECK`) to improve failure diagnostics.
- Filter hip-tests findings from blocking CI gates; enforce checks in library code.

---

#### `hip-unchecked-memcpy` — 979 findings

**Description:** `hipMemcpy` (or variants) return value is not checked. Failed copies proceed silently, leaving destination buffers uninitialized or stale.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~15%

**Context:** Similar to hip-unchecked-malloc. Silent memcpy failures in GPU workloads produce wrong numerical results with no error indication, which is particularly dangerous in correctness-critical code paths. Runtime code should always check the return value.

**Recommended action:**
- Add `HIP_CHECK` or equivalent error checking around all `hipMemcpy` calls in non-test code.
- In test code, at minimum assert on failure to produce useful test output.
- Prioritize clr, rocr-runtime, rccl, rocprofiler-sdk.

---

#### `hip-set-device-unchecked` — 604 findings

**Description:** `hipSetDevice` return value is not checked. If the device index is invalid or the device is unavailable, subsequent HIP operations silently run on the wrong device or fail.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~20%

**Context:** In multi-GPU systems, silently using the wrong device leads to incorrect results, resource leaks on the intended device, and cross-device memory access violations. The volume (604) is significant; many may be in test scaffolding.

**Recommended action:**
- Add return value checks in all non-test code.
- In tests, use a checked wrapper to improve diagnostics.
- Bulk fix is tractable via scripted insertion of `HIP_CHECK(...)` wrapping.

---

#### `hip-unchecked-launch` — 325 findings

**Description:** A HIP kernel launch is not followed by an error check (e.g., `hipGetLastError()` or `hipPeekAtLastError()`). Launch configuration errors (invalid grid/block dimensions, insufficient resources) are silently ignored.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~20%

**Context:** Kernel launch errors are asynchronous in HIP. Without an explicit error check after the launch (and optionally after a sync), launch failures produce no diagnostic output and subsequent results are meaningless. This is especially risky in library code where callers have no visibility into the launch.

**Recommended action:**
- Add `HIP_CHECK(hipGetLastError())` after every kernel launch in library/runtime code.
- Consider a launch wrapper macro that includes the error check.
- Lower priority in pure test code but still recommended for test quality.

---

#### `hip-missing-free` — 217 findings

**Description:** A `hipMalloc`-allocated buffer does not have a corresponding `hipFree` on all code paths, indicating a GPU memory leak.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~30% (ownership may be transferred; RAII wrappers may handle cleanup)

**Context:** GPU memory is a scarce resource. Leaks in long-running or repeatedly-invoked library code (e.g., rocprofiler, rccl collectives) accumulate and eventually cause allocation failures. The 30% false positive estimate reflects common legitimate patterns: buffer ownership transfer to callers, RAII wrappers not visible to semgrep, and early-exit paths that are unreachable in practice.

**Recommended action:**
- Manual review of each finding, focusing on code paths where buffers are allocated inside functions without returning the pointer to callers.
- Prefer RAII wrappers (`std::unique_ptr` with custom deleters calling `hipFree`) to eliminate the class of leaks.
- Prioritize rocprofiler-systems and rocshmem which show volume in the project breakdown.

---

#### `hip-missing-sync` — 197 findings

**Description:** A GPU kernel launch or async operation is not followed by a `hipDeviceSynchronize` or stream synchronization before results are consumed on the host.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~35% (intentional async patterns are common; sync may occur elsewhere)

**Context:** Consuming GPU results before the kernel completes produces stale or uninitialized data. The false positive rate is elevated because many legitimate designs use stream-based synchronization (`hipStreamSynchronize`) or event-based synchronization that semgrep cannot track interprocedurally. However, missing syncs in initialization or teardown paths are genuine hazards.

**Recommended action:**
- Review findings in initialization, teardown, and data-retrieval code paths.
- Ignore findings where the calling code is known to synchronize via other mechanisms.
- Document intentional async patterns with a comment to suppress future false positives.

---

#### `hip-device-sync-in-loop` — 111 findings

**Description:** `hipDeviceSynchronize` is called inside a loop body, forcing a full GPU-CPU round-trip on every iteration.

**Risk:** HIGH (performance) / MEDIUM (correctness)

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~25%

**Context:** `hipDeviceSynchronize` in a tight loop is a severe performance anti-pattern in GPU programming. It serializes the GPU pipeline, negating the benefits of asynchronous execution. In some cases it may be intentional (e.g., benchmarking loops measuring per-iteration latency), but in production library code it is almost always a bug or oversight.

**Recommended action:**
- Review each loop to determine if per-iteration synchronization is architecturally required.
- Replace full-device syncs with stream-level synchronization or event-based synchronization where possible.
- Annotate intentional cases with a comment.

---

#### `relaxed-memory-order` — 64 findings

**Description:** `std::memory_order_relaxed` is used in an atomic operation. Relaxed ordering provides no synchronization guarantees beyond atomicity of the individual operation, allowing reordering that can lead to subtle concurrency bugs.

**Risk:** HIGH

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~30%

**Context:** Relaxed memory order is correct in a narrow set of use cases (e.g., counters where only the final value matters and no other memory is being synchronized). In all other cases — especially flag-based synchronization, producer-consumer patterns, or reference counting with side effects — relaxed order is insufficient and leads to data races that are not detected by TSan in all configurations. ROCm runtime code, being multithreaded and concurrent, is a high-risk environment for this pattern.

**Recommended action:**
- Review each use site for whether relaxed ordering is provably sufficient.
- Replace with `std::memory_order_acquire`/`release` or `seq_cst` for synchronization use cases.
- The 30% false positive rate reflects legitimate counter/stat use cases; document those with a comment.
- Prioritize rocr-runtime, rccl, rocshmem where concurrency correctness is critical.

---

#### `strerror-thread-unsafe` — 86 findings

**Description:** `strerror()` is called in code that may be multithreaded. `strerror` returns a pointer to a static buffer that is overwritten by subsequent calls from any thread, creating a data race.

**Risk:** HIGH (in multithreaded code) / LOW (in single-threaded code)

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~20%

**Context:** In a multithreaded GPU runtime, virtually all error-reporting code paths can be called concurrently. Using `strerror` in this context produces garbled or incorrect error messages and constitutes a data race under the C11/C++11 memory model. The POSIX-specified thread-safe alternative is `strerror_r`; Windows provides `strerror_s`.

**Recommended action:**
- Replace `strerror(errno)` with `strerror_r(errno, buf, sizeof(buf))` (POSIX) or use a thread-local error string helper.
- Applies especially in rocr-runtime, clr, and rccl where multithreaded error handling is common.
- 20% false positive estimate accounts for genuinely single-threaded initialization paths.

---

### MEDIUM

---

#### `reinterpret-cast` — 2,604 findings

**Description:** Use of `reinterpret_cast` to convert between unrelated pointer types or between pointers and integers.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~50%

**Context:** This is the highest-volume finding. `reinterpret_cast` is frequently legitimate in systems/GPU code: casting opaque handles, converting between function pointer types for dispatch tables, and interfacing with C APIs all require it. However, unsafe uses (violating strict aliasing, casting unrelated object types, truncating pointers to 32-bit integers) are real bugs. The 50% false positive estimate reflects the prevalence of legitimate uses in this codebase.

**Recommended action:**
- Do not attempt a bulk fix. Triage by context: flag any cast to/from `void*` involving arithmetic, any cast between unrelated concrete struct types, and any cast that narrows pointer width.
- In new code, prefer `static_cast` for well-defined conversions and `std::bit_cast` (C++20) for type-punning.
- This rule should be reviewed but not blocking in CI given the false positive rate.

---

#### `c-style-pointer-cast` — 1,229 findings

**Description:** C-style casts (`(type*)expr`) used in C++ code instead of named casts (`static_cast`, `reinterpret_cast`, etc.).

**Risk:** MEDIUM

**Classification:** STYLE-ONLY (with some NEEDS-REVIEW)

**False positive estimate:** ~60%

**Context:** C-style casts are legal C++ but obscure intent and can silently perform `reinterpret_cast` when the programmer intended `static_cast`, or can cast away `const` unexpectedly. In a large codebase with C legacy code, these are pervasive. The correctness risk is low for most instances; the main concern is the small subset that silently performs unsafe conversions.

**Recommended action:**
- Enforce named casts in new code via coding standards and CI linting.
- Do not attempt bulk remediation of existing code; address opportunistically during code review.
- Focus manual review on cases where the C-style cast performs a `const`-stripping conversion.

---

#### `raw-malloc` — 1,059 findings

**Description:** Use of `malloc`/`calloc`/`realloc` in C++ code instead of `new`/`new[]` or smart pointers.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~40%

**Context:** In C++ code, `malloc` does not call constructors and its result must be paired with `free` rather than `delete`. Mixed use of `malloc`/`delete` or `new`/`free` is undefined behavior. However, many findings will be in C-compatible headers or C-interop code where `malloc` is correct. The 40% false positive estimate accounts for legitimate C API interop.

**Recommended action:**
- Review any instance where malloc'd memory is later passed to code that may call `delete`.
- Prefer `std::vector`, `std::unique_ptr`, or `std::make_unique` for new C++ code.
- C-interop code that must be `free()`d by callers is a legitimate use; annotate accordingly.

---

#### `raw-free-in-cpp` — 828 findings

**Description:** Use of `free()` in C++ code. Symmetric with raw-malloc; `free` must not be used on memory allocated with `new`.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~40%

**Context:** Same considerations as raw-malloc. The primary risk is mismatched allocator/deallocator pairs. Findings that are paired with `malloc` in the same allocation strategy are lower risk; findings where the allocation origin is unclear are higher risk.

**Recommended action:**
- Ensure every `free()` call is paired with a `malloc`/`calloc`/`realloc` allocation, not `new` or `new[]`.
- Migrate to RAII-based memory management in new and refactored code.

---

#### `const-cast` — 312 findings

**Description:** Use of `const_cast` to remove `const` or `volatile` qualifiers from a pointer or reference.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~35%

**Context:** `const_cast` is defined behavior only if the original object was not `const`-qualified; writing through a `const_cast`-ed pointer to a genuinely const object is undefined behavior. In GPU runtime code, this can cause incorrect compiler optimizations and hard-to-diagnose bugs. Some uses are legitimate (e.g., passing to legacy C APIs that are not `const`-correct but do not mutate).

**Recommended action:**
- Review each instance: if the original object is `const`-qualified and the cast is used to write, it is a bug.
- Prefer fixing the API to be `const`-correct rather than casting.
- Annotate legitimate cases (legacy C API interop) with a comment.

---

#### `atoi-atol-usage` — 115 findings

**Description:** Use of `atoi` or `atol` for string-to-integer conversion. These functions return 0 on error with no error indication, making it impossible to distinguish "0" from an invalid input.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~25%

**Context:** In a GPU runtime/profiler context, incorrect parsing of device indices, buffer sizes, or environment variable overrides from `atoi` returning 0 on invalid input can cause silent misconfiguration. `strtol`/`strtoll` or C++ `std::stoi` (with exception handling) are the correct replacements.

**Recommended action:**
- Replace `atoi`/`atol` with `strtol`/`strtoll` and check `errno` + `endptr`, or use `std::stoi`/`std::stol` with try/catch.
- Prioritize uses that parse user-supplied input or environment variables.

---

#### `fopen-raw-file-pointer` — 63 findings

**Description:** Use of `fopen` returning a raw `FILE*` without RAII management. If the code path exits early (exception, early return), the file descriptor leaks.

**Risk:** MEDIUM

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~30%

**Context:** Raw `FILE*` handles are safe when the code consistently closes them on all exit paths. The risk is elevated in C++ code with exceptions or complex control flow where early returns may skip the `fclose`. File descriptor leaks in long-running profiler/runtime code accumulate and can exhaust OS limits.

**Recommended action:**
- Wrap `FILE*` in a RAII struct or use C++ streams.
- At minimum, audit each `fopen` call to confirm `fclose` is called on all exit paths including error paths.

---

### LOW

---

#### `using-namespace-std` — 114 findings

**Description:** `using namespace std;` in source or (worse) header files, importing the entire standard namespace.

**Risk:** LOW

**Classification:** STYLE-ONLY

**False positive estimate:** ~10%

**Context:** In header files, `using namespace std` pollutes the namespace of every translation unit that includes the header, causing name collision hazards. In source files, the risk is lower but still considered poor practice in large codebases. The 10% false positive estimate accounts for local scopes inside functions.

**Recommended action:**
- Ban `using namespace std` in header files (enforce via CI lint).
- In source files, prefer explicit `std::` qualification or targeted `using std::vector;` declarations.
- This is a style issue but should be addressed in headers as a correctness concern.

---

#### `thread-creation` — 79 findings

**Description:** Raw `pthread_create` or `std::thread` creation flagged for review, typically to ensure thread lifecycle management (join/detach) is correct.

**Risk:** LOW (lifecycle) / MEDIUM (if join is missing)

**Classification:** NEEDS-REVIEW

**False positive estimate:** ~40%

**Context:** Detached threads that outlive their parent scope or access destroyed state cause undefined behavior. Threads that are neither joined nor detached produce resource leaks. In a GPU runtime, stray threads interacting with device state can cause non-deterministic failures.

**Recommended action:**
- Verify that every created thread is either joined or explicitly detached.
- Prefer `std::jthread` (C++20) or RAII thread wrappers that join on destruction.
- Review findings in rocr-runtime and rocshmem where thread management interacts with GPU state.

---

## Scan Limitations and Notes

### Parse Error: `goto-usage`
Semgrep is unable to parse C++ `goto` patterns with the current rule. This rule produced a parse error and zero findings. If goto usage is a concern, use clang-tidy or a custom cppcheck rule instead.

### Timeouts: `experimental/rocjitsu`
The file `experimental/rocjitsu/vop3.cpp` is a large machine-generated file that caused semgrep analysis timeouts. Findings in this file are incomplete. Consider excluding generated files from static analysis or splitting them during the build process.

### Interprocedural Limits
Semgrep performs intrafile pattern matching only. Cross-function and cross-file data flow (e.g., a pointer allocated in one function and freed in another) is not tracked. This means:
- `hip-missing-free` has a higher false positive rate for ownership-transfer patterns.
- `hip-missing-sync` cannot track stream synchronization through call graphs.
- `dangling-c-str` may miss some cases where the string lifetime is controlled elsewhere.

---

## Prioritized Remediation Roadmap

### Phase 1 — Immediate (CRITICAL, low volume, high confidence)

| Rule | Count | Action |
|------|-------|--------|
| memcpy-sizeof-pointer | 100 | Fix all confirmed instances; review all 100 manually |
| dangling-c-str | 59 | Fix all; assign named locals before `.c_str()` |

### Phase 2 — Short-term (HIGH, core runtime projects)

| Rule | Focus Projects | Action |
|------|---------------|--------|
| hip-unchecked-malloc | clr, rocr-runtime, rccl, rocprofiler-sdk | Add HIP_CHECK wrappers |
| hip-unchecked-memcpy | clr, rocr-runtime, rccl | Add error checks |
| hip-set-device-unchecked | all non-test | Add error checks |
| hip-unchecked-launch | all non-test | Add hipGetLastError checks |
| relaxed-memory-order | rocr-runtime, rccl, rocshmem | Manual review, upgrade ordering |
| strerror-thread-unsafe | rocr-runtime, clr | Replace with strerror_r |
| hip-missing-free | rocprofiler-systems, rocshmem | Introduce RAII hipFree wrappers |

### Phase 3 — Medium-term (MEDIUM, all projects)

| Rule | Action |
|------|--------|
| hip-device-sync-in-loop | Profile-guided review; replace with stream sync |
| hip-missing-sync | Review init/teardown paths; document async patterns |
| const-cast | Audit for writes-through-const; fix API const-correctness |
| atoi-atol-usage | Replace with strtol/std::stoi |
| fopen-raw-file-pointer | Introduce RAII file wrappers |
| raw-malloc / raw-free-in-cpp | Migrate to RAII in new/refactored code |
| reinterpret-cast | Triage for unsafe narrowing and aliasing violations |
| thread-creation | Verify join/detach correctness |

### Phase 4 — Long-term / Style (LOW)

| Rule | Action |
|------|--------|
| using-namespace-std | Enforce ban in headers via CI |
| c-style-pointer-cast | Enforce named casts in new code reviews |
| reinterpret-cast (remaining) | Address during routine refactoring |

---

## CI Integration Recommendations

1. **Gate on CRITICAL rules immediately:** Add `memcpy-sizeof-pointer` and `dangling-c-str` as CI blocking rules with zero-tolerance for new findings.
2. **Exclude test code from HIGH-priority HIP checks:** Hip-tests findings should be informational only in CI, not blocking.
3. **Exclude generated files:** Add `experimental/rocjitsu/vop3.cpp` and similar generated files to `.semgrepignore` to eliminate timeouts.
4. **Fix goto-usage rule:** File an upstream issue or replace with a clang-tidy equivalent; the current rule is broken for C++.
5. **Baseline suppression:** Suppress existing findings for MEDIUM/LOW rules to avoid noise; enforce only on new code (semgrep `--baseline-commit` or equivalent).

---

---

## Configuration Updates

A new companion tool, `semgrep-case-coverage`, now exists alongside this general C/C++ semgrep scan. The case-coverage tool specifically targets dispatch pattern detection: incomplete switch statements over HIP/ROCm enum types, missing default cases in API dispatch code, and unhandled enum values in state machines. Its findings are reported separately from this general C++ rule set to keep the signal distinct. Cross-reference `semgrep-case-coverage` results when reviewing dispatch and error-handling code in clr, rocr-runtime, and rccl.

---

*Generated by: basic-static-analysis branch — semgrep C/C++ scan*
*Report date: 2026-04-11*
