# gfxip-incomplete-dispatch Triage

**Date**: 2026-04-14
**Rule**: `gfxip-incomplete-dispatch` from semgrep-case-coverage scan
**Total findings**: 12
**Real bugs**: 1 (rocdecode #10 — already fixed in PR #5032)
**False positives**: 5
**Low risk / defensive**: 3
**Duplicates**: 2 (vendored copies)
**Skipped**: 1 (example code)

---

## Summary Table

| # | File | Line | Classification | Notes |
|---|------|------|---------------|-------|
| 1 | rocr-runtime runtime.cpp | 226 | **Low risk** | All 3 device types handled; `kUnknownDevice` unreachable via current callers |
| 2 | rocr-runtime runtime.cpp | 3493 | **False positive** | Falls through to safe `!cpu` fallback; AIE not in SVM migration |
| 3 | clr hip_conversions.hpp | 15 | **False positive** | All enum values covered; `return {}` is intentional error sentinel |
| 4 | clr paldevice.cpp | 2311 | **False positive** | Zero-init struct means missing `CL_FILTER_NONE` case is correct by default |
| 5 | aqlprofile gfx940_factory.cpp | 143 | **Low risk** | Outer factory throws on unknown GPU; only MI300/MI350 can reach this |
| 6 | aqlprofile navi_reg_init.cpp | 93 | **False positive** | Intentional filtering — comment says "only initialize the blocks needed" |
| 7 | rocprofiler-sdk gfx940_factory.cpp | 173 | **Duplicate** | Vendored copy of #5 |
| 8 | rocprofiler-sdk navi_reg_init.cpp | 106 | **Duplicate** | Vendored copy of #6 |
| 9 | rocprofiler-sdk agent.cpp | 773 | **Low risk** | `NONE` type deliberately produced; WARNING already logged; fields zero by design |
| 10 | rocdecode roc_decoder.cpp | 179 | **Real bug** | Fixed in PR [#5032](https://github.com/ROCm/rocm-systems/pull/5032) |
| 11 | rocjpeg rocjpeg_decoder.cpp | 653 | **False positive** | `roi_offset` only used in NV12 path; other formats handle ROI internally |
| 12 | rocprofiler-systems TransferBench.hpp | 2909 | **Skipped** | Example code, low priority |

---

## #1: rocr-runtime runtime.cpp:226 — RegisterAgent

**Classification: Low risk**

**Code:**
```cpp
void Runtime::RegisterAgent(Agent* agent, bool Enabled) {
  agents_by_node_[agent->node_id()].push_back(agent);

  if (agent->device_type() == Agent::DeviceType::kAmdCpuDevice) {
    cpu_agents_.push_back(agent);
    // ... CPU-specific init ...
  } else if (agent->device_type() == Agent::DeviceType::kAmdGpuDevice) {
    if (Enabled) {
      gpu_agents_.push_back(agent);
    } else {
      disabled_gpu_agents_.push_back(agent);
    }
  } else if (agent->device_type() == Agent::DeviceType::kAmdAieDevice) {
    aie_agents_.push_back(agent);
  }
  // NO else / default branch
}
```

**Enum:**
```cpp
enum DeviceType {
  kAmdGpuDevice = 0,
  kAmdCpuDevice = 1,
  kAmdAieDevice = 2,
  kUnknownDevice = 3
};
```

**Analysis:** All three real device types are handled. `kUnknownDevice` is a sentinel that never reaches `RegisterAgent` — the three callers (`DiscoverCpu`, `DiscoverGpu`, `DiscoverAie`) always pass concrete types. However, a future 4th device type would be silently skipped (added to `agents_by_node_` but none of the typed lists). Other dispatch points in the same file (e.g., line 3611) do include `kUnknownDevice` with an error return.

**Suggested fix:** Add `else { assert(false && "RegisterAgent: unhandled DeviceType"); }` — zero risk, defensive improvement.

---

## #2: rocr-runtime runtime.cpp:3493 — SVM prefetch

**Classification: False positive**

**Code:**
```cpp
if (agent->device_type() == core::Agent::kAmdCpuDevice) {
    op->target_cpus.push_back(UINT32_MAX);
    continue;
} else if (agent->device_type() == core::Agent::kAmdGpuDevice) {
    AMD::GpuAgent* gpu = static_cast<AMD::GpuAgent*>(agent);
    cpu = static_cast<AMD::CpuAgent*>(gpu->GetNearestCpuAgent());
}
// Falls through...
if (!cpu) {
    cpu = static_cast<AMD::CpuAgent*>(cpu_agents_[0]);
}
```

**Analysis:** When `kAmdAieDevice` (or any unhandled type) is encountered, neither branch fires, `cpu` stays `nullptr`, and the immediately-following `if (!cpu)` fallback safely picks the first CPU agent. AIE devices don't participate in KFD SVM page migration — this code path is unreachable in practice. The fallback is intentional, not an omission.

---

## #3: clr hip_conversions.hpp:15 — getCLChannelType

**Classification: False positive**

**Analysis:** The function contains two switch statements on `hipArray_Format` (8 values) and `hipTextureReadMode` (2 values). All enum values are handled in both switches. The function ends with `return {}` which value-initializes `cl_uint` to 0 — this is a deliberate error sentinel, not an uninitialized value. Callers check for errors downstream via `isValid()`. The analyzer flagged the missing `default:` labels, but the switches are exhaustive.

---

## #4: clr paldevice.cpp:2311 — fillHwSampler mipFilter

**Classification: False positive**

**Code:**
```cpp
Pal::SamplerInfo samplerInfo = {};  // zero-initialized

if (mipFilter == CL_FILTER_NEAREST) {
    samplerInfo.filter.mipFilter = Pal::MipFilterPoint;
} else if (mipFilter == CL_FILTER_LINEAR) {
    samplerInfo.filter.mipFilter = Pal::MipFilterLinear;
}
// CL_FILTER_NONE not handled explicitly
```

**Analysis:** `Pal::MipFilterNone == 0`, which is the zero-init value. The "missing" `CL_FILTER_NONE` case is correct by default. The OpenCL validation layer rejects any value other than `NONE/NEAREST/LINEAR` before it reaches this code.

---

## #5: aqlprofile gfx940_factory.cpp:143 — InitSpmBlockDelayTable

**Classification: Low risk**

**Code:**
```cpp
void Mi300Factory::InitSpmBlockDelayTable(gpu_id_t gpu_id) {
  if (gpu_id == MI300_GPU_ID) {
    // populate with gfx940 tables
  } else if (gpu_id == MI350_GPU_ID) {
    // populate with gfx950 tables
  }
  // NO else
}
```

**Analysis:** The outer `Pm4Factory::Create()` switch throws an exception for unknown GPU IDs before any factory is constructed. Only `MI300_GPU_ID` and `MI350_GPU_ID` can reach this function. If an unknown value somehow got through, the tables would retain MI100 parent values (wrong data but no crash). The pattern is intentional — `Mi300Factory` is a private class with only two construction paths.

---

## #6: aqlprofile navi_reg_init.cpp:93 — IP discovery filtering

**Classification: False positive**

**Code:**
```cpp
for (auto& entry : table) {
    if (entry.ipname == "gc") {
        init_hwip(GC_HWIP, entry);
    } else if (entry.ipname == "athub") {
        init_hwip(ATHUB_HWIP, entry);
    }
    // other IP blocks silently dropped
}
```

**Analysis:** Intentional filtering, documented with the comment `"HW has more IP blocks, only initialize the blocks needed"` in the static fallback path. Only GC and ATHUB base offsets are needed for gfx10/11/12 profiling. Exhaustive search of all `REG_32B_ADDR` references in gfx10/11/12 block tables confirms no other HWIP types are dereferenced.

---

## #7: rocprofiler-sdk gfx940_factory.cpp:173

**Classification: Duplicate of #5** — vendored copy with identical logic.

---

## #8: rocprofiler-sdk navi_reg_init.cpp:106

**Classification: Duplicate of #6** — vendored copy with identical logic.

---

## #9: rocprofiler-sdk agent.cpp:773 — agent type dispatch

**Classification: Low risk**

**Code:**
```cpp
if (agent_info.type == ROCPROFILER_AGENT_TYPE_GPU) {
    // ... extensive GPU-specific init (uuid, DRM, names, etc.)
} else if (agent_info.type == ROCPROFILER_AGENT_TYPE_CPU) {
    // ... CPU-specific init
}
// NO else
```

**Enum:**
```c
typedef enum rocprofiler_agent_type_t {
    ROCPROFILER_AGENT_TYPE_NONE = 0,
    ROCPROFILER_AGENT_TYPE_CPU,
    ROCPROFILER_AGENT_TYPE_GPU,
    ROCPROFILER_AGENT_TYPE_LAST,
};
```

**Analysis:** `NONE` is deliberately produced for unrecognized hardware nodes (lines 724–731) with a WARNING already logged. When a `NONE` agent reaches the dispatch, all fields stay at their zero/empty defaults (name, vendor set to `""` just above at lines 769–771). The agent is marked invisible via `zero_visibility`. All GPU-specific iteration code guards on `type != GPU`. The missing else is intentional — there's nothing to populate for an unknown agent type.

---

## #10: rocdecode roc_decoder.cpp:179 — GetVideoFrame layer dispatch

**Classification: Real bug (FIXED)**

Fixed in PR [#5032](https://github.com/ROCm/rocm-systems/pull/5032). See `.analysis/anomalies/rocdecode-get-video-frame-layer-dispatch.md` for full details.

---

## #11: rocjpeg rocjpeg_decoder.cpp:653 — GetPlanarYUVOutputFormat ROI offset

**Classification: False positive**

**Code:**
```cpp
if (hip_interop_dev_mem.surface_format == VA_FOURCC_NV12) {
    roi_offset = (top >> 1) * hip_interop_dev_mem.pitch[1] + left;
} else if (hip_interop_dev_mem.surface_format == VA_FOURCC_YUY2) {
    roi_offset = top * hip_interop_dev_mem.pitch[0] + (left * 2);
}
// 444P, 422V, Y800 not handled — roi_offset stays 0
```

**Analysis:** The `roi_offset` computed here is only used in the NV12 UV-conversion call (line 669). The other formats (`444P`, `422V`, `Y800`) delegate entirely to `CopyChannel`, which has its own internal ROI logic and doesn't use the outer `roi_offset`. Leaving it at 0 for those paths has no effect. `VA_FOURCC_RGBA` and `VA_FOURCC_RGBP` cannot reach this function due to upstream output_format gating.

---

## #12: rocprofiler-systems TransferBench.hpp:2909

**Classification: Skipped** — example/benchmark code, not production. Low priority.
