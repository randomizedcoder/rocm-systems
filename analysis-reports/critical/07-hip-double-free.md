# Issue 7: HIP Double-Free on GPU Memory

> **Triage status (2026-04-13):** All 24 raw findings (14 after dedup) recorded in [`.analysis/anomalies.toml`](../../.analysis/anomalies.toml) — **0 real bugs**. All findings are in `projects/hip-tests/` (no runtime hits) and fall into 4 rule-precision failure modes (intentional double-free test, `hipFree(nullptr)` init idiom, free→realloc→free, Catch2 SECTION expansion, per-test-case scope). See [`CRITICAL-ISSUES.md` §7](../../CRITICAL-ISSUES.md#issue-7-hip-double-free-on-gpu-memory--full-analysis) for the outcome table.

**Date:** 2026-04-11
**Severity:** HIGH (if real), LOW (if false positive)
**Tools:** semgrep (hip-double-free rule)
**Total findings:** 11

---

## Summary

The hip-check semgrep analysis reported 11 instances of potential `hipFree` double-free. This
report examines each instance to determine whether it represents a genuine double-free bug or a
false positive from semgrep's inability to understand control flow.

**Bottom line:** All 11 findings are false positives. The semgrep rule pattern-matches
`hipFree($PTR); ... hipFree($PTR);` where `...` can span arbitrary code, including
re-allocations, loop iterations, conditional branches, and even separate functions in the same
file. None of the findings represent a case where the same pointer value is freed twice without
an intervening re-allocation.

---

## The Semgrep Rule

```yaml
# nix/analysis/rules/semgrep-hip.yaml:48-55
- id: hip-double-free
  pattern: |
    hipFree($PTR);
    ...
    hipFree($PTR);
  message: Potential double hipFree on same pointer
  languages: [cpp, c]
  severity: ERROR
```

The `...` operator in semgrep matches "any code between" the two statements. Critically, semgrep:

- Does NOT track whether the pointer was re-assigned between the two frees
- Does NOT understand that loop bodies re-allocate the pointer each iteration
- Does NOT distinguish between if/else branches (both branches match)
- May match across function boundaries within the same file

---

## Instance-by-Instance Analysis

### Instance 1-6: `hipMallocManagedStress.cc` -- Allocate/Free in Conditional Branches

**File:** `projects/hip-tests/catch/stress/memory/hipMallocManagedStress.cc`
**Lines:** 247, 257, 266, 276, 285, 294

The `Stress_hipMallocManaged_ExtremeSizes` test function contains a loop that tests various
allocation sizes. For each size, it allocates with `hipMallocManaged`, and frees only if the
allocation succeeded:

```cpp
// projects/hip-tests/catch/stress/memory/hipMallocManagedStress.cc:245-258
err = hipMallocManaged(&Hmm, 1, hipMemAttachGlobal);
if (hipSuccess == err) {
  HIP_CHECK(hipFree(Hmm));          // <-- semgrep match 1
} else {
  // ... error warning ...
}
err = hipMallocManaged(&Hmm, freeDevMem, hipMemAttachGlobal);
if (hipSuccess == err) {
  HIP_CHECK(hipFree(Hmm));          // <-- semgrep match 2
} else {
  // ... error warning ...
}
err = hipMallocManaged(&Hmm, (freeDevMem - 1), hipMemAttachGlobal);
if (hipSuccess == err) {
  HIP_CHECK(hipFree(Hmm));          // <-- semgrep match 3
}
// ... pattern repeats 3 more times for hipMemAttachHost flag ...
```

This pattern repeats 6 times in the function. The pointer `Hmm` is re-allocated via
`hipMallocManaged(&Hmm, ...)` between each `hipFree(Hmm)`.

**Verdict: ALL 6 ARE FALSE POSITIVES.**

Each `hipFree(Hmm)` frees a *different* allocation. The pointer is overwritten by
`hipMallocManaged` before the next free. Semgrep sees `hipFree(Hmm); ... hipFree(Hmm);`
and flags it, but it cannot see that `Hmm` was reassigned between the frees.

---

### Instance 7: `hipMallocConcurrency.cc` -- Free Inside Loop Body

**File:** `projects/hip-tests/catch/stress/memory/hipMallocConcurrency.cc`
**Lines:** 109, 117 (and 174, 181 for a duplicate function)

```cpp
// projects/hip-tests/catch/stress/memory/hipMallocConcurrency.cc:107-118
// Exercise allocation in loop with bigger chunks
for (i = 0; i < MaxAllocFree_BigChunks; i++) {
  HIP_CHECK(hipMalloc(&ptr, numBytes));
  HIP_CHECK(hipFree(ptr));             // <-- iteration N
}

// Exercise allocation in loop with smaller chunks
numBytes = BuffSizeSC;
for (i = 0; i < MaxAllocFree_SmallChunks; i++) {
  HIP_CHECK(hipMalloc(&ptr, numBytes));
  HIP_CHECK(hipFree(ptr));             // <-- iteration N+1
}
```

Semgrep sees `hipFree(ptr)` at line 109 and `hipFree(ptr)` at line 117 as a double-free.
But `ptr` is re-allocated by `hipMalloc(&ptr, numBytes)` at the start of the second loop.

**Verdict: FALSE POSITIVE.** The pointer is re-allocated between frees.

---

### Instance 8: `memcpy.cc` -- SECTION Macros (Catch2 Test Framework)

**File:** `projects/hip-tests/catch/stress/memory/memcpy.cc`
**Lines:** 14, 20, 26, 32

```cpp
// projects/hip-tests/catch/stress/memory/memcpy.cc (reconstructed from grep)
SECTION("...") {
  // ... hipMalloc ...
  HIP_CHECK(hipFree(d_a));    // line 14
}
SECTION("...") {
  // ... hipMalloc ...
  HIP_CHECK(hipFree(d_a));    // line 20
}
SECTION("...") {
  // ... hipMalloc ...
  HIP_CHECK(hipFree(d_a));    // line 26
}
SECTION("...") {
  // ... hipMalloc ...
  HIP_CHECK(hipFree(d_a));    // line 32
}
```

Catch2 `SECTION` macros create mutually exclusive test paths. Only ONE section executes per
test iteration. The `d_a` variable is allocated fresh in each section. Semgrep sees multiple
`hipFree(d_a)` in the same function scope and flags them, but they are in mutually exclusive
code paths.

**Verdict: FALSE POSITIVE.** Mutually exclusive branches (Catch2 SECTION).

---

### Instance 9-10: `Stress_printf_ComplexKernels.cc` -- Separate Functions

**File:** `projects/hip-tests/catch/stress/printf/Stress_printf_ComplexKernels.cc`
**Lines:** 268-269, 322-323

```cpp
// Function 1 -- ends around line 276
bool test_printf_stress(...) {
  // ...
  HIP_CHECK(hipMalloc(&Ad, buffsize * sizeof(uint32_t)));
  HIP_CHECK(hipMalloc(&Bd, buffsize * sizeof(uint32_t)));
  // ... kernel launches ...
  HIP_CHECK(hipFree(Bd));       // line 268
  HIP_CHECK(hipFree(Ad));       // line 269
  // ...
}

// Function 2 -- starts around line 278
bool test_printf_multigpu(...) {
  // ...
  HIP_CHECK(hipMalloc(&Ad, buffsize * sizeof(uint32_t)));
  HIP_CHECK(hipMalloc(&Bd, buffsize * sizeof(uint32_t)));
  // ... kernel launches ...
  HIP_CHECK(hipFree(Bd));       // line 322
  HIP_CHECK(hipFree(Ad));       // line 323
  // ...
}
```

These are completely separate functions with their own local variables `Ad` and `Bd`. Semgrep
matches across function boundaries because the `...` pattern does not respect scope.

**Verdict: FALSE POSITIVE.** Different functions, different variables.

---

### Instance 11: `hipTestDevice.cc` -- Separate Functions with Same Variable Names

**File:** `projects/hip-tests/catch/unit/deviceLib/hipTestDevice.cc`
**Lines:** 125-127, 167-169, 204-205, 238-239, 271 (multiple functions)

```cpp
// Function: run_sincos() -- lines ~100-134
bool run_sincos() {
  float *Ad, *Bd, *Cd;
  HIP_CHECK(hipMalloc(reinterpret_cast<void**>(&Ad), SIZE));
  // ...
  HIP_CHECK(hipFree(Ad));      // line 125
  HIP_CHECK(hipFree(Bd));      // line 126
  HIP_CHECK(hipFree(Cd));      // line 127
}

// Function: run_sincospif() -- lines ~136-170
bool run_sincospif() {
  float *Ad, *Bd, *Cd;
  HIP_CHECK(hipMalloc(reinterpret_cast<void**>(&Ad), SIZE));
  // ...
  HIP_CHECK(hipFree(Ad));      // line 167
  HIP_CHECK(hipFree(Bd));      // line 168
  HIP_CHECK(hipFree(Cd));      // line 169
}

// Pattern repeats for run_sincospi(), run_llround(), etc.
```

Five functions in the same file each declare local `Ad`, `Bd`, `Cd` variables, allocate them,
and free them. Semgrep sees `hipFree(Ad)` appearing 5+ times in the file and matches pairs.

**Verdict: FALSE POSITIVE.** Different functions with same-named local variables.

---

## Summary Table

| # | File | Pattern | Real Bug? | Reason |
|---|---|---|---|---|
| 1-6 | hipMallocManagedStress.cc | `hipFree(Hmm)` x6 | No | Pointer re-allocated via `hipMallocManaged(&Hmm,...)` between each free |
| 7 | hipMallocConcurrency.cc | `hipFree(ptr)` in two loops | No | Pointer re-allocated via `hipMalloc(&ptr,...)` between frees |
| 8 | memcpy.cc | `hipFree(d_a)` in SECTION blocks | No | Catch2 SECTIONs are mutually exclusive code paths |
| 9-10 | Stress_printf_ComplexKernels.cc | `hipFree(Ad/Bd)` in two functions | No | Separate functions with local variables |
| 11 | hipTestDevice.cc | `hipFree(Ad)` across 5 functions | No | Separate functions with same-named locals |

**Real double-frees found: 0 out of 11**
**False positive rate: 100%**

---

## Why Semgrep Gets This Wrong

The semgrep `hip-double-free` rule uses this pattern:

```yaml
pattern: |
  hipFree($PTR);
  ...
  hipFree($PTR);
```

The `...` (ellipsis) operator in semgrep is a **syntactic** matcher, not a **semantic** one:

1. **No data-flow analysis.** Semgrep does not track whether `$PTR` was re-assigned between the
   two `hipFree` calls. If the pointer is overwritten by `hipMalloc(&ptr, ...)` between the
   frees, semgrep still matches.

2. **No control-flow analysis.** Semgrep does not understand that two `hipFree` calls in
   different `if` branches, `SECTION` blocks, or separate functions cannot both execute on the
   same pointer value.

3. **Cross-function matching.** The `...` operator can span across function boundaries within
   the same file. Two functions that each free a local variable named `ptr` will match.

4. **Loop iteration blindness.** An alloc/free cycle inside a loop body (`hipMalloc(&p,...);
   hipFree(p);`) repeated in two separate loops matches as a "double free" because semgrep
   sees two `hipFree(p)` statements in the same scope.

---

## Could There Be Real Double-Frees Elsewhere?

The semgrep rule has a fundamental limitation that makes it nearly useless for finding real
double-frees. A real double-free would look like:

```cpp
hipFree(ptr);
// ... no re-allocation of ptr ...
hipFree(ptr);  // BUG: ptr already freed
```

This pattern is rare in practice because:

1. Most code that frees a pointer does so at the end of a scope or in a cleanup block
2. Developers who re-use pointer variables typically re-allocate them first
3. The cases semgrep catches (re-allocation between frees, different functions) are the
   common patterns, not the rare bug pattern

To find real double-frees, a tool would need:

- **Dataflow analysis** to track pointer values through assignments
- **Path-sensitive analysis** to distinguish mutually exclusive branches
- **Interprocedural analysis** to track pointers across function calls
- **Alias analysis** to detect when two different variable names point to the same allocation

Tools like Clang Static Analyzer, Coverity, or CodeQL have these capabilities. Semgrep's
pattern-matching approach is not suited for this class of bug.

---

## Recommendations

1. **Disable or demote the `hip-double-free` rule.** With a 100% false positive rate on 11
   findings, this rule generates only noise. It should be removed from the active ruleset or
   downgraded to informational.

2. **Use Clang Static Analyzer instead.** The `-analyzer-checker=unix.Malloc` checker (and its
   GPU memory equivalents) performs actual dataflow analysis and can detect real double-frees
   with much lower false positive rates.

3. **If keeping the semgrep rule, add `metavariable-pattern` constraints.** Semgrep supports
   negative lookahead patterns that could filter out cases where the pointer is re-assigned:
   ```yaml
   pattern: |
     hipFree($PTR);
     ...
     hipFree($PTR);
   pattern-not: |
     hipFree($PTR);
     ...
     hipMalloc(&$PTR, ...);
     ...
     hipFree($PTR);
   ```
   This would eliminate the re-allocation false positives, though it still cannot handle
   cross-function or branch-exclusive cases.

4. **Adopt the `ptr = nullptr` idiom.** As a defensive coding practice, setting pointers to
   `nullptr` after free prevents double-free bugs and makes them detectable (freeing nullptr
   is a no-op in both HIP and CUDA). This was already mentioned in `CRITICAL-ISSUES.md`:
   ```cpp
   hipFree(dev_ptr);
   dev_ptr = nullptr;  // safe: subsequent hipFree(nullptr) is a no-op
   ```

5. **Focus double-free detection effort on production code.** All 11 findings are in
   `hip-tests`. The production runtime projects (clr, rccl, rocshmem) have no double-free
   findings. If a tool with real dataflow analysis (Coverity, CodeQL) also reports zero
   findings in production code, this class of bug can be considered adequately controlled.

---

## Non-Test Code Assessment

No double-free findings were reported in any production runtime code:

| Project | Double-Free Findings |
|---|---|
| projects/clr | 0 |
| projects/rccl | 0 |
| projects/rocshmem | 0 |
| projects/rocr-runtime | 0 |
| projects/hip-tests | 11 (all false positives) |

The production code's consistent use of error-checking macros and RAII patterns makes double-free
unlikely. RCCL uses `ncclCommPushCudaFree` for deferred cleanup, rocshmem uses `CHECK_HIP`
consistently, and CLR uses internal allocation functions with proper lifecycle management.
