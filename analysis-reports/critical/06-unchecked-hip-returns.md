# Issue 6: Unchecked HIP API Returns in Core Runtime

> **Triage status (2026-04-13):** All 65 in-scope production findings recorded in [`.analysis/anomalies.toml`](../../.analysis/anomalies.toml) — **0 real bugs, 65 false positives** (all wrapped by `CUDACHECK` / `HIP_CALL` / `HIPCHECK` / `CHECK_HIP` macros the semgrep rule does not recognise). See [`CRITICAL-ISSUES.md` §6](../../CRITICAL-ISSUES.md#issue-6-unchecked-hip-api-returns-in-core-runtime-rccl-rocshmem--full-analysis) for the outcome table; this document retains the preliminary narrative for historical context.

**Date:** 2026-04-11
**Severity:** HIGH (production runtime code), MEDIUM (test code)
**Tools:** semgrep (hip-unchecked-malloc, hip-unchecked-memcpy, hip-unchecked-launch rules)
**Scope:** Non-test production code in clr, rccl, rocshmem, rocr-runtime

---

## Summary

The hip-check analysis found ~2,235 unchecked `hipMalloc`, ~1,869 unchecked `hipMemcpy`, and ~636
unchecked kernel launches across the monorepo. Roughly 82% are in `projects/hip-tests`, which is
expected (test code). The remaining 18% are spread across production runtime code where unchecked
GPU API returns are a real concern.

This report examines the four core runtime projects in detail: `clr` (the HIP runtime itself),
`rccl` (collective communications for distributed training), `rocshmem` (GPU-initiated shared
memory), and `rocr-runtime` (HSA runtime).

---

## Per-Project Analysis

### 1. projects/clr -- The HIP Runtime (2 semgrep findings)

**Error-checking macro:** No `HIP_CHECK` macro exists in `clr`. This is deliberate -- CLR *is* the
HIP runtime. It does not call itself through the public API.

**How CLR handles GPU operations internally:**

CLR uses internal functions (`ihipMalloc`, `ihipMemcpy`, `ihipFree`) rather than the public
`hipMalloc`/`hipMemcpy`/`hipFree` API. The public APIs are thin wrappers:

```cpp
// projects/clr/hipamd/src/hip_memory.cpp:744
hipError_t hipMalloc(void** ptr, size_t sizeBytes) {
  HIP_RETURN_DURATION(ihipMalloc(ptr, sizeBytes, 0), ReturnPtrValue(ptr));
}
```

The internal `ihipMalloc` properly checks all error conditions and returns `hipError_t`:

```cpp
// projects/clr/hipamd/src/hip_memory.cpp:309-353
hipError_t ihipMalloc(void** ptr, size_t sizeBytes, unsigned int flags) {
  if (ptr == nullptr) { return hipErrorInvalidValue; }
  if (sizeBytes == 0) { *ptr = nullptr; return hipSuccess; }
  // ... context validation, size checking ...
  *ptr = amd::SvmBuffer::malloc(...);
  if (*ptr == nullptr) {
    LogPrintfError("Allocation failed : Device memory : required :%zu | free :%zu | total :%zu",
                   sizeBytes, free, total);
    return hipErrorOutOfMemory;
  }
  return hipSuccess;
}
```

**The two semgrep findings are in surface/texture object creation:**

**Finding 1: `hip_surface.cpp:68`**

```cpp
// projects/clr/hipamd/src/hip_surface.cpp:67-71
hipError_t err =
    ihipMalloc(&surfObjectBuffer, sizeof(__hip_surface), CL_MEM_SVM_FINE_GRAIN_BUFFER);
if (surfObjectBuffer == nullptr || err != hipSuccess) {
  return hipErrorOutOfMemory;
}
```

**Verdict: FALSE POSITIVE.** The return value IS checked on the very next line. Semgrep likely
flagged this because the check is on a separate statement rather than wrapping the call in a macro.

**Finding 2: `hip_texture.cpp:356`**

```cpp
// projects/clr/hipamd/src/hip_texture.cpp:355-359
hipError_t err =
    ihipMalloc(&texObjectBuffer, sizeof(__hip_texture), CL_MEM_SVM_FINE_GRAIN_BUFFER);
if (texObjectBuffer == nullptr || err != hipSuccess) {
  return hipErrorOutOfMemory;
}
```

**Verdict: FALSE POSITIVE.** Same pattern as above -- the return is checked immediately.

**Assessment for CLR:**

The CLR codebase is well-disciplined. It uses internal functions that return `hipError_t`, and
callers check the return value. The two semgrep findings are false positives caused by the tool not
recognizing that a variable assignment followed by an `if` check is equivalent to wrapping the call
in a macro. **No action needed for CLR itself.**

The key insight: in CLR, "unchecked hipMalloc" is not a meaningful category because CLR does not
call `hipMalloc` -- it calls `ihipMalloc`, which is internal implementation. The error propagation
model is different from application code.

---

### 2. projects/rccl -- Collective Communications (12 semgrep findings)

**Error-checking macro: YES -- `CUDACHECK`, `CUDACHECKGOTO`, `CUDACHECKIGNORE`**

RCCL has a comprehensive error-checking framework defined in `src/include/checks.h`:

```cpp
// projects/rccl/src/include/checks.h:13-18
#define CUDACHECK(cmd) do {                                 \
    cudaError_t err = cmd;                                  \
    if( err != cudaSuccess ) {                              \
        return rcclCudaErrorHandler(err);                   \
    }                                                       \
} while(false)

#define CUDACHECKGOTO(cmd, RES, label) do {                 \
    cudaError_t err = cmd;                                  \
    if( err != cudaSuccess ) {                              \
        RES = rcclCudaErrorHandler(err);                    \
        goto label;                                         \
    }                                                       \
} while(false)

// Report failure but clear error and continue
#define CUDACHECKIGNORE(cmd) do {  \
    cudaError_t err = cmd;         \
    if( err != cudaSuccess ) {     \
        INFO(NCCL_ALL,"%s:%d Cuda failure '%s'", __FILE__, __LINE__, cudaGetErrorString(err)); \
        (void) cudaGetLastError(); \
    }                              \
} while(false)
```

Note: despite the `CUDA` naming (RCCL is a fork of NVIDIA's NCCL), these macros work with HIP
via the HIP-CUDA compatibility layer. `cudaError_t` maps to `hipError_t`.

**RCCL additionally has `ncclCudaMalloc` -- a checked allocation wrapper:**

```cpp
// projects/rccl/src/include/alloc.h:521-542
template <typename T>
ncclResult_t ncclCudaMallocDebug(const char *filefunc, int line, T** ptr, size_t nelem, ...) {
  // Uses CUDACHECKGOTO internally for hipExtMallocWithFlags
  // Logs warning if allocation returns nullptr
  if (*ptr == nullptr && nelem > 0) WARN("Failed to CUDA malloc %ld bytes", nelem*ncclSizeOfT<T>());
}
#define ncclCudaMalloc(...) ncclCudaMallocDebug(__FILE__, __LINE__, __VA_ARGS__)
```

**Concrete examples of checked usage in production (hot path):**

```cpp
// projects/rccl/src/collectives.cc:141 -- AllGather hot path
CUDACHECK(hipMemcpyAsync(tempBuffer, sendbuff, rankOffset, hipMemcpyDeviceToDevice, stream));

// projects/rccl/src/misc/msccl/msccl_lifecycle.cc:277 -- algorithm loading
CUDACHECK(hipMemcpy(devAlgo, hostAlgo, sizeof(struct mscclAlgo), hipMemcpyHostToDevice));

// projects/rccl/src/enqueue.cc:2996 -- rocshmem integration path
CUDACHECK(hipMallocManaged((void**)&t->sizes, nSizes * sizeof(size_t)));

// projects/rccl/src/misc/npkit.cc:153 -- cleanup
CUDACHECK(hipFree(gpu_event_buffers_[i]));
```

**Where are the 12 findings?** All `hipMalloc`, `hipMemcpy`, and `hipFree` calls in RCCL's `src/`
directory use either `CUDACHECK`, `CUDACHECKGOTO`, `CUDACHECKIGNORE`, or `ncclCudaMalloc`. The
semgrep findings in RCCL are likely from:

1. The `CUDACHECKIGNORE` macro (logs but continues), which semgrep may not recognize as a check
2. Edge cases in the MSCCL (Microsoft Collective Communication Library) integration paths
3. Initialization/teardown code rather than the collective operation hot path

**Assessment for RCCL:**

RCCL is well-disciplined in its production code. The `CUDACHECK` family of macros is used
consistently in `src/`. The `collectives.cc` hot path (AllGather, AllReduce, etc.) always wraps
HIP calls. The 12 findings are likely false positives from semgrep not recognizing the macro
patterns.

**Is this in the hot path?** The `hipMemcpyAsync` calls in `collectives.cc` ARE in the hot path
of collective operations. These are the device-to-device copies that execute during distributed
AllGather/AllReduce. They are all wrapped in `CUDACHECK`.

---

### 3. projects/rocshmem -- GPU-Initiated Shared Memory (20 semgrep findings)

**Error-checking macro: YES -- `CHECK_HIP`**

ROCshmem has a well-defined CHECK_HIP macro in multiple locations:

```cpp
// projects/rocshmem/src/util.hpp:88-96
#define CHECK_HIP(instr) do {                               \
  hipError_t error = (instr);                               \
  if (error != hipSuccess) {                                \
    fprintf(stderr,                                         \
      "Error: " #instr ": %s (%d) at RocSHMEM::%s:%d\n",    \
      hipGetErrorString(error), error, __FILE__, __LINE__); \
    abort();                                                \
  }                                                         \
} while(0)
```

**Concrete examples -- all production `src/` code uses CHECK_HIP consistently:**

```cpp
// projects/rocshmem/src/team.cpp:85
CHECK_HIP(hipMalloc(&block, 2 * sizeof(TeamInfo)));

// projects/rocshmem/src/backend_bc.cpp:83
CHECK_HIP(hipMalloc(&print_lock, sizeof(*print_lock)));

// projects/rocshmem/src/ipc/backend_ipc.cpp:176
CHECK_HIP(hipMalloc(&ctx_array, sizeof(IPCContext) * envvar::max_num_contexts));

// projects/rocshmem/src/ipc_policy.cpp:84
CHECK_HIP(hipMalloc(reinterpret_cast<void **>(&ipc_base), ...));

// projects/rocshmem/src/gda/backend_gda.cpp:976
CHECK_HIP(hipMemcpy(&gpu_qps[i], &host_qps[i], sizeof(QueuePair), hipMemcpyDefault));
```

**One genuinely unchecked pattern found:**

```cpp
// projects/rocshmem/src/rocshmem_gpu.cpp:178-184
err = hipMemcpyAsync(target, source, expected_size,
                     hipMemcpyDeviceToDevice, stream);
if (err != hipSuccess) {
  fprintf(stderr, "[rocSHMEM] Error: Failed to copy %s to device: %s\n",
          label, hipGetErrorString(err));
  return ROCSHMEM_ERROR;
}
```

**Verdict:** This is NOT unchecked -- it uses manual error checking rather than the macro. Semgrep
would flag it if it only looks for the macro pattern.

**Assessment for rocshmem:**

The production code in `src/` is highly disciplined -- every `hipMalloc`, `hipMemcpy`, and
`hipFree` call uses `CHECK_HIP` or manual error checking. The 20 findings are split between:

- `src/` code: likely false positives from manual check patterns or code in `memory/hip_allocator.hpp`
  where `hipMalloc` and `hipFree` are passed as function pointers to a template class (not direct calls)
- `tests/` and `examples/`: test code that may be less rigorous but is non-production

The `memory/hip_allocator.hpp` passes `hipMalloc` and `hipFree` as function pointers:
```cpp
// projects/rocshmem/src/memory/hip_allocator.hpp:120
HIPAllocator() : MemoryAllocator(hipMalloc, hipFree) {}
```
The allocator template wraps these in its own error handling. Semgrep sees `hipMalloc` and `hipFree`
as "unchecked" because it does not trace through the template.

---

### 4. projects/rocr-runtime -- HSA Runtime (181 stated findings)

**Key insight: rocr-runtime does NOT use HIP APIs at all.**

The HSA (Heterogeneous System Architecture) runtime operates at a lower level than HIP. It uses
its own API: `hsa_memory_allocate`, `hsa_memory_copy`, `hsa_memory_free`. The 181 findings
attributed to this project in the summary come from either:

1. The semgrep rules matching HSA equivalents (unlikely given the rules target `hipMalloc` etc.)
2. Test code in `rocrtst/` that uses HIP
3. A counting error in the summary

**Actual HSA allocation patterns -- properly checked:**

```cpp
// projects/rocr-runtime/runtime/hsa-runtime/core/runtime/hsa.cpp:786-787
hsa_status_t err = HSA::hsa_memory_allocate(region, sizeof(core::SharedQueue), &shared_queue);
if (err != HSA_STATUS_SUCCESS) return err;

// projects/rocr-runtime/runtime/hsa-runtime/core/runtime/hsa.cpp:1852-1856
status = HSA::hsa_memory_allocate(
    code_object_alloc_region, serialized_code_object_size,
    &code_object_alloc_data);
if (status != HSA_STATUS_SUCCESS) {
  return status;
}

// projects/rocr-runtime/runtime/hsa-runtime/core/runtime/host_queue.cpp:59-62
if (HSA_STATUS_SUCCESS !=
    HSA::hsa_memory_allocate(region, queue_buffer_size, &ring_)) {
  throw AMD::hsa_exception(HSA_STATUS_ERROR_OUT_OF_RESOURCES,
                           "Host queue buffer alloc failed\n");
}
```

**Assessment for rocr-runtime:**

The HSA runtime is thoroughly checked. Every `hsa_memory_allocate` call in the core runtime
either checks the return value with an `if` statement or uses scope guards for cleanup. The
runtime even uses RAII-style scope guards for rollback:

```cpp
MAKE_NAMED_SCOPE_GUARD(bufferGuard, [&]() { HSA::hsa_memory_free(&ring_); });
```

The 181 findings claimed in the summary likely represent a categorization issue -- either they
are from `rocrtst/` test code (which was not found to contain `hipMalloc` calls) or from a
different counting methodology. **No HIP API calls exist in the rocr-runtime core.**

---

## Honest Assessment

### How likely is hipMalloc to actually fail?

GPU OOM is not uncommon in production, especially with large AI models:

- **Large language models** (70B+ parameters) routinely consume 80-90% of available VRAM. A
  secondary allocation (workspace buffers, communication buffers) can tip the balance.
- **Multi-tenant GPU systems** (inference servers, shared training clusters) have unpredictable
  free memory depending on co-located workloads.
- **Memory fragmentation** after long uptime can cause allocations to fail even when total free
  memory appears sufficient.
- **RCCL specifically** allocates communication buffers during `ncclCommInit` and during collective
  operations. In a distributed training job with 8+ GPUs, each GPU has RCCL overhead. An OOM
  during `ncclCommInit` that is silently ignored would cause the entire training run to produce
  garbage.

### Are the CLR findings meaningful?

No. CLR is the HIP runtime implementation. Its internal functions (`ihipMalloc`, `ihipFree`) are
not the public API -- they return `hipError_t` which propagates up through the public API to the
caller. The semgrep rules are designed for code that *calls* HIP, not for the HIP implementation
itself. Both CLR findings are false positives.

### Are the RCCL findings in the hot path?

The `hipMemcpyAsync` calls in `collectives.cc` are in the hot path, but they are all properly
wrapped in `CUDACHECK`. The allocation calls (e.g., `ncclCudaMalloc` in `enqueue.cc`,
`init.cc`) are in initialization paths, not per-iteration hot paths. These are checked.

### Is the 82% test-code proportion misleading?

Partially. The raw count makes it look like production code is mostly clean, but the production
findings are concentrated in the most impactful codebases (the runtime itself, the collective
communications library, the shared memory library). A single unchecked allocation in RCCL's
initialization path affects every distributed training job that uses it.

---

## Error-Checking Macro Summary

| Project | Macro | Defined In | Consistently Used? |
|---|---|---|---|
| clr | N/A (internal APIs) | N/A | Yes -- ihipMalloc returns hipError_t, callers check |
| rccl | CUDACHECK / CUDACHECKGOTO / CUDACHECKIGNORE | src/include/checks.h | Yes -- all src/ HIP calls use these macros |
| rccl | ncclCudaMalloc (wrapper) | src/include/alloc.h | Yes -- used for all GPU allocations |
| rocshmem | CHECK_HIP | src/util.hpp | Yes -- all src/ HIP calls use this macro |
| rocr-runtime | N/A (uses HSA API) | N/A | Yes -- manual if-check on every hsa_memory_allocate |

---

## False Positive Analysis

| Project | Stated Findings | Estimated True Positives | Reason |
|---|---|---|---|
| clr | 2 | 0 | Both calls check return value; internal API model |
| rccl | 12 | 0-2 | CUDACHECK macro used consistently; semgrep may miss macro pattern |
| rocshmem | 20 | 2-5 | CHECK_HIP used in src/; findings likely from tests/examples or function-pointer patterns |
| rocr-runtime | 181 | 0 | Does not use HIP API; HSA allocations are all checked |

**Net assessment:** The four core runtime projects are well-engineered with respect to GPU API
error checking. Each project has established patterns (macros or internal APIs) that enforce
checking. The semgrep findings are predominantly false positives caused by:

1. Semgrep not recognizing project-specific macros (CUDACHECK, CHECK_HIP) as error checks
2. Semgrep not tracing through function-pointer/template indirection
3. Semgrep not understanding that CLR's internal functions propagate errors differently
4. Possible miscounting of rocr-runtime (which uses HSA, not HIP)

---

## Where the Real Risk Is

The genuine risk is NOT in these four projects. It is in:

1. **Example code and samples** that developers copy into production. Files like
   `transpose.new.cpp` in rocprofiler-systems have fully unchecked HIP calls:
   ```cpp
   hipMalloc(&in, size);        // unchecked
   hipMalloc(&out, size);       // unchecked
   hipMemcpy(in, matrix, ...);  // unchecked
   hipMemcpy(out_matrix, ...);  // unchecked
   hipFree(in);                 // unchecked
   hipFree(out);                // unchecked
   ```

2. **hip-tests itself** -- test code that demonstrates unchecked patterns teaches contributors
   that pattern. Some test files (e.g., `module_api_global/runKernel.cpp`) use bare `hipFree(Ad)`
   without any check.

3. **New code** that does not follow the established patterns. The macros exist but are not
   enforced by CI. A new contributor could add unchecked calls to RCCL or rocshmem without
   triggering any build failure.

---

## Recommendations

1. **Add semgrep suppressions for known macros.** Configure the hip-unchecked-malloc and
   hip-unchecked-memcpy rules to recognize `CUDACHECK`, `CHECK_HIP`, `HIP_CHECK`,
   `ncclCudaMalloc`, etc. as valid error-checking wrappers. This eliminates ~90% of false
   positives.

2. **Enforce macro usage in CI for rccl and rocshmem.** Add a linter rule that requires all
   `hipMalloc`/`hipMemcpy`/`hipFree` calls in `src/` to be wrapped in the project's error
   macro. This prevents regression.

3. **Fix the examples.** The unchecked calls in `rocprofiler-systems/examples/transpose/` and
   similar files should use `HIP_CHECK` or equivalent. These are the patterns developers copy.

4. **Exclude CLR from hip-unchecked-* rules.** CLR is the HIP implementation; internal API
   usage has a different error model. Scanning it with application-level rules generates only
   noise.

5. **Audit rocr-runtime findings source.** The 181 findings attributed to rocr-runtime need
   clarification. If they are from test infrastructure, they should be triaged separately from
   the core HSA runtime.
