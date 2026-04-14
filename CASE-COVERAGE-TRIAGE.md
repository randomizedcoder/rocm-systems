# Case Coverage / Incomplete Dispatch — Triage

Tracking document for the second wave of static analysis: the **semgrep case-coverage** scan targeting incomplete dispatch patterns — the same bug class as [PR #4936](https://github.com/ROCm/rocm-systems/pull/4936) (doorbell type handling 1 of 4 values).

See also: [analysis-reports/semgrep-case-coverage.md](analysis-reports/semgrep-case-coverage.md) for the full scan report.

---

## Background

The semgrep case-coverage scan produced ~35,000 findings across 10 rules.  The WARNING-level rules (~650 findings) have the highest signal.  We triage these first, starting with `gfxip-incomplete-dispatch` (12 findings, ~90% real-bug rate).

**Rule priority:**

| Phase | Rule | Findings | Status |
|-------|------|----------|--------|
| **1** | `gfxip-incomplete-dispatch` | 12 | 🔵 In triage |
| 2 | `incomplete-numeric-dispatch` (both) | 76 | ⚪ Pending |
| 3 | `switch-no-default-on-type` (core only) | 135 | ⚪ Pending |
| 4 | `type-check-no-else` + others | 610 | ⚪ Pending |

---

## Phase 1: `gfxip-incomplete-dispatch` — 12 findings

### Triage Results

| # | File | Line | Verdict | Summary |
|---|------|------|---------|---------|
| 1 | `rocr-runtime/.../runtime.cpp` | 176 | ✅ **FP** | All 3 device types (CPU/GPU/AIE) handled in complete if-else-if chain |
| 2 | `rocr-runtime/.../runtime.cpp` | 3493 | 🔍 **Needs review** | SVM prefetch handles CPU + GPU but AIE falls through to fallback. Likely intentional (AIE → use first CPU) but no comment documents this |
| 3 | `clr/hipamd/src/hip_conversions.hpp` | 15 | ✅ **FP** | Both switch blocks cover all 8 hipArray_Format enum values; line 56 handles unknown hipReadMode |
| 4 | `clr/rocclr/device/pal/paldevice.cpp` | 2311 | ✅ **FP** | mipFilter defaults to no filtering via zero-init (`= {}`). CL_FILTER_NONE is the implicit third case — intentional |
| 5 | `aqlprofile/src/core/gfx940_factory.cpp` | 143 | 🟡 **Latent bug** | `InitSpmBlockDelayTable` handles MI300 and MI350 GPU IDs only. Currently safe (factory dispatch prevents other IDs reaching this), but a future MI-series GPU will silently leave delay tables uninitialized |
| 6 | `aqlprofile/src/core/navi_reg_init.cpp` | 93 | 🔍 **Needs review** | IP discovery loop handles only "gc" and "athub" out of 20+ possible IP blocks. Vega20 hardcoded version initializes all 20. May be intentional (only GC/ATHUB needed for Navi profiling) or may be incomplete port |
| 7 | `rocprofiler-sdk/.../gfx940_factory.cpp` | 173 | 🟡 **Dup of #5** | Vendored copy — same latent bug |
| 8 | `rocprofiler-sdk/.../navi_reg_init.cpp` | 106 | 🔍 **Dup of #6** | Vendored copy — same question |
| 9 | `rocprofiler-sdk/.../agent.cpp` | 773 | ✅ **FP** | Handles GPU (773) and CPU (883) — the only two agent types in rocprofiler |
| 10 | `rocdecode/src/rocdecode/roc_decoder.cpp` | 179 | 🔍 **Needs review** | num_layers dispatch handles 2 and 3 but not 1. For single-plane formats (num_layers==1), dev_mem_ptr[1]/[2] aren't set. Layer 0 always set. Need to verify caller expectations |
| 11 | `rocjpeg/src/rocjpeg_decoder.cpp` | 653 | 🔍 **Needs review** | GetPlanarYUVOutputFormat handles YUY2, NV12, 444P, 422V but no else. New surface format → chroma channels not copied, returns SUCCESS silently |
| 12 | `rocprofiler-systems/examples/TransferBench.hpp` | 2909 | ⬜ **Wont-fix** | Example/benchmark code. blockOrder only valid as 0/1/2 per config |

### Triage Summary

- **4 false positives** (#1, #3, #4, #9)
- **1 latent bug + 1 vendored duplicate** (#5, #7 — InitSpmBlockDelayTable missing default case)
- **5 needs-review** (#2, #6, #8, #10, #11 — require domain expertise to determine if the missing cases are intentional)
- **1 wont-fix** (#12 — example code)

### Latent Bug: Finding #5 / #7 — `InitSpmBlockDelayTable` missing default case

**Files:**
- `projects/aqlprofile/src/core/gfx940_factory.cpp:141-194`
- `projects/rocprofiler-sdk/source/lib/aqlprofile/core/gfx940_factory.cpp:169-231` (vendored copy)

**Bug:** `Mi300Factory::InitSpmBlockDelayTable(gpu_id_t gpu_id)` uses an if-else chain dispatching on `gpu_id == MI300_GPU_ID` and `gpu_id == MI350_GPU_ID` with no `else` clause. For any other `gpu_id_t` value, the function returns without initializing `spm_block_delay_global`, `spm_block_delay_se`, or `cu_block_delay_table_size` — leaving them as whatever was in memory.

**Current reachability:** The top-level `Pm4Factory::Create()` switch (`pm4_factory.h:315-350`) prevents unknown GPU IDs from reaching this function today. Only MI300_GPU_ID and MI350_GPU_ID are routed to Mi300Factory/Mi350Factory. The top-level switch itself has a correct `default: throw`.

**Why it's still worth fixing:**
1. `Pm4Factory::Create()` has the correct defensive pattern (`switch` + `default: throw`), but `InitSpmBlockDelayTable` does not. Consistency matters — the top-level dispatch is a single point of defense for a function that has its own `gpu_id_t` parameter.
2. When the next MI-series GPU ships (MI400), a developer adds `MI400_GPU_ID` to the enum, adds a case in `Pm4Factory::Create()`, and either creates a new Mi400Factory subclass of Mi300Factory or reuses Mi300Factory with a new gpu_id. In the subclass case, `InitSpmBlockDelayTable(MI400_GPU_ID)` silently leaves delay tables uninitialized — exactly the doorbell bug pattern.
3. The if-else chain on an enum type should be a `switch` with `default:` to match the existing pattern in `Pm4Factory::Create()`. This is the minimal change that prevents the latent bug from becoming a real one.

**Severity:** LOW (currently unreachable via normal dispatch) but structurally identical to the doorbell bug (#4936). The fix is cheap (convert to switch + default) and adds a safety net for future GPU bring-up.

**Fix:** Convert the if-else chain to a `switch` on `gpu_id` with explicit `case MI300_GPU_ID:`, `case MI350_GPU_ID:`, and `default:` that throws `aql_profile_exc_val<gpu_id_t>("Unsupported GPU id for SPM block delay table", gpu_id)` — matching the pattern in `Pm4Factory::Create()`.

### Needs-Review Findings

These findings represent real incomplete dispatch patterns, but require maintainer input to determine whether the missing cases are intentional design decisions:

**#2 — SVM prefetch AIE device handling** (`rocr-runtime/runtime.cpp:3493`)
- AIE devices fall through to the `if (!cpu)` fallback at line 3503 → uses first available CPU agent.
- This may be correct (AIE co-processor uses host CPU for prefetch) but is undocumented.

**#6 / #8 — Navi IP discovery only handles gc + athub** (`navi_reg_init.cpp:93`)
- The vega20 hardcoded version initializes 20 IP blocks (GC, HDP, MMHUB, ATHUB, NBIO, MP0, MP1, UVD, VCE, DF, DCE, OSSSYS, SDMA0, SDMA1, SMUIO, NBIF, THM, CLK, UMC, RSMU).
- The navi sysfs discovery version only handles 2 (GC, ATHUB).
- May be intentional: the profiler may only need GC+ATHUB register offsets on Navi.

**#10 — rocdecode num_layers==1 not handled** (`roc_decoder.cpp:179`)
- VA-API's `num_layers` for NV12 is 2 (Y+UV planes). Single-layer (YUYV packed) has num_layers==1.
- For num_layers==1, only dev_mem_ptr[0] is set (correct for packed format where everything is in one plane).
- But dev_mem_ptr[1] and [2] are not explicitly zeroed either — may contain stale values from a previous frame.

**#11 — rocjpeg surface_format missing else** (`rocjpeg_decoder.cpp:653`)
- Handles YUY2, NV12, 444P, 422V. Missing: any future format added to VA-API.
- Returns ROCJPEG_STATUS_SUCCESS without copying chroma → silent data corruption for new formats.

---

## PRs Filed

*(none yet — triage in progress)*

---

## Phase 2: `incomplete-numeric-dispatch` — 76 findings

*(not yet started)*

---

## Phase 3: `switch-no-default-on-type` — 135 findings (core runtime only)

*(not yet started)*
