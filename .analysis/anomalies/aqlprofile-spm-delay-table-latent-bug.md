# aqlprofile InitSpmBlockDelayTable: missing default for gpu_id dispatch

**Status:** 🟡 confirmed-bug (latent — not reachable via current dispatch, but structurally dangerous)
**Tool:** semgrep `gfxip-incomplete-dispatch`
**Files:**
- `projects/aqlprofile/src/core/gfx940_factory.cpp:141-194`
- `projects/rocprofiler-sdk/source/lib/aqlprofile/core/gfx940_factory.cpp:169-231` (vendored copy)
**Reviewed:** 2026-04-13

## Bug

`Mi300Factory::InitSpmBlockDelayTable(gpu_id_t gpu_id)` uses an if-else
chain to dispatch on `gpu_id`:

```cpp
void Mi300Factory::InitSpmBlockDelayTable(gpu_id_t gpu_id) {
    const uint32_t** p;
    if (gpu_id == MI300_GPU_ID) {
        cu_block_delay_table_size = sizeof(gfx940::TaBlockDelayValue) / ...;
        // ... initialize spm_block_delay_global and spm_block_delay_se
    } else if (gpu_id == MI350_GPU_ID) {
        cu_block_delay_table_size = sizeof(gfx950::TaBlockDelayValue) / ...;
        // ... initialize spm_block_delay_global and spm_block_delay_se
    }
    // ← NO else/default — unrecognized gpu_id silently leaves tables uninitialized
}
```

For any `gpu_id` value other than `MI300_GPU_ID` or `MI350_GPU_ID`, the
function returns without initializing `spm_block_delay_global`,
`spm_block_delay_se`, or `cu_block_delay_table_size`. Downstream code
reads uninitialized delay values → silent SPM profiling data corruption.

## Reachability Analysis

Currently **NOT reachable** via normal code paths. The top-level factory
dispatcher `Pm4Factory::Create()` (`pm4_factory.h:315-350`) has a
`switch(gpu_id)` with:
- `case MI300_GPU_ID:` → `Mi300Create()` → `Mi300Factory(MI300_GPU_ID)`
- `case MI350_GPU_ID:` → `Mi350Create()` → `Mi350Factory(MI350_GPU_ID)`
- `default: throw aql_profile_exc_val<gpu_id_t>("GPU id error", gpu_id);`

All other GPU IDs route to entirely different factory classes (Gfx9, Gfx10,
Gfx11, Gfx12, Mi100, Mi200) that don't call `InitSpmBlockDelayTable(gpu_id_t)`.

## Why it's still worth fixing

This is the **doorbell bug pattern** (PR #4936):

1. `gpu_id_t` enum already has 10 values (`INVAL_GPU_ID` through `GFX12_GPU_ID`).
   When the next MI-series GPU ships (e.g., MI400), a developer:
   - Adds `MI400_GPU_ID` to the enum
   - Adds a case in `Pm4Factory::Create()` → creates a new `Mi400Factory`
     subclass of `Mi300Factory` (the standard pattern — Mi350Factory is exactly
     this: `class Mi350Factory : public Mi300Factory`)
   - Mi400Factory calls `Mi300Factory(agent_info, MI400_GPU_ID)`
   - `InitSpmBlockDelayTable(MI400_GPU_ID)` → neither if-branch matches →
     **delay tables uninitialized → silent corruption**

2. The top-level `Pm4Factory::Create()` switch already uses the correct
   defensive pattern (`switch` + `default: throw`). `InitSpmBlockDelayTable`
   should match.

## Fix

Convert the if-else chain to a `switch` on `gpu_id` with explicit cases and
a `default:` that throws, matching the existing `Pm4Factory::Create()` pattern:

```cpp
void Mi300Factory::InitSpmBlockDelayTable(gpu_id_t gpu_id) {
    const uint32_t** p;
    switch (gpu_id) {
    case MI300_GPU_ID:
        cu_block_delay_table_size = sizeof(gfx940::TaBlockDelayValue) / ...;
        // ... MI300 initialization
        break;
    case MI350_GPU_ID:
        cu_block_delay_table_size = sizeof(gfx950::TaBlockDelayValue) / ...;
        // ... MI350 initialization
        break;
    default:
        throw aql_profile_exc_val<gpu_id_t>(
            "Unsupported GPU id for SPM block delay table", gpu_id);
    }
}
```

This ensures that any future GPU ID that reaches this function either has
explicit delay table initialization or fails loudly at profiler init time,
rather than silently producing incorrect SPM data.

## Severity

LOW (currently unreachable) but structurally identical to the doorbell bug.
Fix cost is minimal — mechanical conversion of if-else to switch + default.

## Test Strategy (TDD)

Unit test calls `InitSpmBlockDelayTable` with a gpu_id outside {MI300, MI350}
(e.g. `GFX12_GPU_ID`) and asserts that it throws. Pre-fix: test fails (no
throw, function returns silently). Post-fix: test passes (throws
`aql_profile_exc_val`). Also verify MI300 and MI350 paths still initialize
correctly.
