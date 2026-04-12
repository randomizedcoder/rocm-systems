# cpplint Analysis Report

## Executive Summary

cpplint found **38,259 findings** across the ROCm Systems monorepo. The vast majority (~90%) are style and formatting issues with no functional impact. The single HIGH priority category is `runtime/threadsafe_fn` (121 findings), where thread-unsafe C functions such as `strtok` and `strerror` are used in a multi-threaded GPU runtime context. A further ~10,000 findings across `runtime/int`, `readability/casting`, and related categories represent genuine portability and type-safety concerns worth addressing systematically, though they require triage before fixing.

---

## Findings Breakdown

| Category | Count | Severity | Description |
|---|---|---|---|
| build/include_order | 8,223 | Low | Header include ordering (style) |
| readability/casting | 7,679 | Medium | C-style casts; use static_cast etc. |
| runtime/int | 5,288 | Medium | Use fixed-width types (int64_t etc.) instead of `long`, `short` |
| build/include_what_you_use | 3,824 | Medium | Missing direct header includes |
| runtime/explicit | 3,562 | Medium | Single-arg constructors missing `explicit` keyword |
| readability/braces | 2,093 | Low | Brace style (style) |
| build/namespaces | 652 | Low | Namespace usage style |
| readability/multiline_comment | 432 | Low | Multiline comment style |
| readability/inheritance | 385 | Low | Virtual/override usage style |
| build/include | 344 | Medium | Incorrect include paths or missing guards |
| readability/namespace | 295 | Low | Namespace closing comment style |
| runtime/printf | 285 | Medium | Format string issues |
| build/storage_class | 204 | Low | Storage class ordering |
| runtime/threadsafe_fn | 121 | **HIGH** | Thread-unsafe C functions (strtok, strerror, etc.) |
| readability/alt_tokens | 114 | Low | Use `&&` instead of `and`, etc. |
| runtime/arrays | 89 | Medium | Variable-length array (VLA) usage |
| runtime/string | 68 | Medium | Unsafe string operations |
| readability/multiline_string | 65 | Low | Multiline string literals |
| readability/check | 25 | Low | Use CHECK_EQ etc. instead of CHECK(a == b) |
| runtime/casting | 19 | Medium | Pointer/int casting issues |

**Total: 38,259**

---

## False Positive Analysis by Category

### build/include_order (8,223) — ~95% false positive
Include ordering rules are project-specific. Many projects deliberately use non-standard ordering for HIP/CUDA compatibility or build system reasons. Only meaningful if the project adopts a strict clang-format include-sort policy.

### readability/casting (7,679) — ~50% false positive
Many C-style casts are intentional interop with C APIs (HIP, ROCr, MPI). However, a significant fraction in C++ code should use `static_cast`/`reinterpret_cast` for clarity. Overlaps with semgrep cast findings. Worth a pass through C++-only files.

### runtime/int (5,288) — ~40% false positive
`int` vs `long` size differences between LP64 (Linux) and LLP64 (Windows) are real portability concerns for a GPU compute platform. However, many uses of `int` in loop counters, flags, and small counts are fine. The real concern is sizes of memory buffers, offsets, and counts passed to GPU kernels where 64-bit types matter.

### build/include_what_you_use (3,824) — ~60% false positive
IWYU violations are frequently false positives in monorepos because transitive includes are provided by umbrella headers. Still worth tracking over time to avoid hidden dependency chains.

### runtime/explicit (3,562) — ~70% false positive
Many single-argument constructors are intentional implicit conversion points (e.g., handle wrappers, string-like types). Should be reviewed case-by-case rather than blindly adding `explicit`.

### readability/braces (2,093) — ~99% false positive
Pure style. Autofix with clang-format if project adopts that standard.

### runtime/threadsafe_fn (121) — ~10% false positive
This is the highest-signal category. Functions like `strtok`, `strerror`, `rand`, `localtime`, and `gmtime` have thread-safe alternatives (`strtok_r`, `strerror_r`, `rand_r`, etc.). In a multi-threaded GPU runtime that launches concurrent host threads, these are real bugs waiting to happen. Expect ~10% to be in single-threaded init paths where they are safe.

### runtime/arrays (89) — ~30% false positive
VLAs are not valid ISO C++, and stack allocation of variable-size arrays is a security concern. GCC/Clang allow them as extensions. Should be replaced with `std::vector` or fixed-size arrays.

### runtime/printf (285) — ~40% false positive
Format string mismatches (e.g., `%d` for `size_t`) are real bugs. Many may be in debug/test code. Worth reviewing systematically.

---

## Per-Project Breakdown

| Project | Findings | Notes |
|---|---|---|
| clr | 6,067 | Largest single contributor; legacy C codebase |
| rocprofiler-sdk | 4,107 | Mixed C/C++; profiling API surface |
| hip-tests | 4,003 | Test code; style issues less critical |
| rocjitsu | 3,569 | JIT compiler; casting findings likely relevant |
| rocprofiler-systems | 3,051 | Tracing/instrumentation; threading concerns apply |
| rccl | 2,838 | Collective comms; threading safety critical |
| rocr-runtime | 2,587 | Core runtime; all findings warrant review |
| rocshmem | 2,317 | SHMEM library; portability types matter |

---

## Priority Remediation List

### P1 — HIGH: Fix thread-unsafe functions (121 findings)

All `runtime/threadsafe_fn` findings in multi-threaded code paths must be fixed. Primary targets:

- `strtok` → `strtok_r`
- `strerror` → `strerror_r`
- `rand` → `rand_r` or `<random>` C++11 generators
- `localtime` / `gmtime` → `localtime_r` / `gmtime_r`

Focus projects: rocprofiler-systems (tracing threads), rccl (parallel comms), rocr-runtime (runtime dispatch).

### P2 — MEDIUM: Fix runtime/int portability (5,288 findings, estimated ~3,000 real)

Audit all uses of `int`, `long`, and `unsigned` in:
- Memory sizes, offsets, and buffer lengths
- Kernel launch parameters
- Inter-process/inter-node communication (rocshmem, rccl)

Replace with `int32_t`, `int64_t`, `size_t`, or `ptrdiff_t` as appropriate. Use `static_assert(sizeof(long) == 8)` guards where platform size assumptions are made deliberately.

### P3 — MEDIUM: Audit C-style casts (7,679 findings, estimated ~4,000 real)

Run a targeted pass on non-test C++ source files only. Replace:
- `(int)x` → `static_cast<int>(x)` for arithmetic conversions
- `(MyType*)ptr` → `reinterpret_cast<MyType*>(ptr)` for pointer punning
- `(void*)ptr` → `static_cast<void*>(ptr)` where valid

Skip `.hip`, `.cu`, and C files — C-style casts are idiomatic there.

### P4 — MEDIUM: Fix VLA usage (89 findings)

Replace variable-length arrays with `std::vector<T>` or `absl::FixedArray`. Prevents stack overflows and is required for strict C++ conformance.

### P5 — MEDIUM: Fix format strings (285 findings)

Audit `runtime/printf` findings, particularly any using `%d`/`%i` for `size_t`/`ptrdiff_t` or `%lu` for 32-bit types. Enable `-Wformat` compiler warnings to catch these at build time.

### P6 — LOW: Style cleanup (bulk of remaining findings)

Address `build/include_order`, `readability/braces`, `build/namespaces`, etc. via clang-format and clang-tidy automation. These should not be hand-fixed individually — set up pre-commit hooks.

---

## Recommended Next Steps

1. Run cpplint with `--filter=+runtime/threadsafe_fn` to extract the 121 HIGH findings for immediate review.
2. Add `-Wthread-safety` Clang annotations to critical runtime classes.
3. Consider adopting clang-tidy's `modernize-use-*` and `cppcoreguidelines-*` checks as a higher-signal complement to cpplint.
4. Suppress known false-positive categories project-by-project using `.cpplint` config files to reduce noise in CI.

---

## Configuration Updates

The overall static analysis infrastructure now includes clang-tidy with `-Wswitch-enum` enabled for the same codebase. This complements cpplint's coverage by detecting missing cases in switch statements over enum types, which cpplint does not check. The combination of cpplint (style and runtime safety) and clang-tidy (semantic switch completeness) provides broader coverage for type-safety concerns across the C/C++ code.
