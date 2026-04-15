# switch-no-default-on-type Triage (Phase 3)

**Date**: 2026-04-14
**Rule**: `switch-no-default-on-type` from semgrep-case-coverage scan
**Total findings**: 288 production code (308 total, 20 test/example excluded)
**Triaged**: 111 high-value (rocr-runtime core, clr, rocdecode, rocjpeg)
**Skipped**: 177 (lower-priority projects, vendored addrlib, image subsystem)

## Results

**Real bugs: 0**
**Low risk: 12** (missing default but all current values handled, or minor extensibility gap)
**False positives: 99** (tool missed existing `default:`, intentionally partial, or exhaustive)

### Key observation

The tool has a very high false positive rate (~89%) for this rule. The dominant patterns:
1. **Tool missed existing `default:`** (~40% of FPs) — semgrep's pattern matching fails to see `default:` when separated by nested switches, preprocessor directives, or when at the end of a long switch
2. **Intentionally partial switches** (~30% of FPs) — e.g., NAL type dispatch in video parsers, or capability probing where unknown values are correctly ignored
3. **Fully exhaustive** (~20% of FPs) — all enum values covered, just no `default:` label

---

## rocr-runtime (27 findings → 0 bugs, 3 low risk, 24 FP)

Most findings have explicit `default:` clauses the tool missed. The `amd_hsa_code_util.cpp` findings (6 total) are all stringify functions with `default: return "UNKNOWN"`.

**Low risk:**
- `amd_xdna_driver.cpp:262` — `XDNADeviceType` switch; new AI Engine silicon types need case here
- `events.c:313` — SVM attr switch missing CLR_FLAGS/GRANULARITY in debug path; has `default:`
- `executable.cpp:1683` — V1 reloc switch silently ignores `R_AMDGPU_V1_RELATIVE64`; frozen legacy ABI

## clr (50 findings → 0 bugs, 7 low risk, 43 FP)

~40 of 50 have `default:` clauses. The low-risk items are switches on stable API enums that currently cover all values but lack a defensive `default:`.

**Low risk:**
- `hip_conversions.hpp:560` — `hipMemcpyKind` (5/5 values, no default)
- `hip_memory.cpp:533` — `hip::MemcpyType` (6/6 values, no default; new type → null command ptr)
- `hip_memory.cpp:2826` — same enum
- `cl_d3d9.cpp:66` — adapter type (3/3 values, no default; uninitialized vars if bad value)
- `palblit.cpp:2404` — `cl_channel_data_type` (14/14 values, no default)
- `rocdevice.cpp:878` — `hsa_region_segment_t` (only GLOBAL handled for CPU pools)
- `platform/memory.cpp:1428` — `cl_channel_data_type` formatColor (14/14, no default)

## rocdecode (25 findings → 0 bugs, 2 low risk, 23 FP)

Video parser switches are intentionally partial — NAL type dispatch only handles types relevant to decoding.

**Initially flagged as real bug (revised to FP):** `avc_parser.cpp:1003` — `chroma_format_idc` switch missing case 0 (monochrome). The `default:` sets `sub_width_c = 0`. However, the code correctly uses `chroma_array_type == 0` (line 1022) to bypass the `sub_width_c`/`sub_height_c` variables entirely for monochrome — the `default:` value is dead code in the monochrome path. **Not a bug.**

**Low risk:**
- `hevc_parser.cpp:1381` — `chroma_format_idc` 4/4 values but no default; protected by `CHECK_ALLOWED_RANGE`
- `vaapi_videodecoder.cpp:92` — Monochrome falls to default (NV12); plausibly correct but undocumented

## rocjpeg (9 findings → 0 bugs, 0 low risk, 9 FP)

All switches have explicit `default:` clauses returning error status codes.

---

## Skipped projects (177 findings)

| Project | Findings | Reason for skip |
|---------|----------|----------------|
| rocprofiler | 29 | Plugin/trace dispatch — likely intentionally partial |
| rocdbgapi | 19 | Debugger agent — separate review needed |
| rocprofiler-sdk | 15 | Tracing/buffer dispatch |
| rocprofiler-systems | 15 | Instrumentation/monitoring |
| hipfile | 12 | File I/O fallback dispatch |
| amdsmi | 9 | System management |
| rccl | 9 | Already triaged in Phase 2 patterns |
| rocshmem | 7 | Shared memory |
| rocprof-trace-decoder | 5 | Trace processing |
| roctracer | 2 | Tracing |
| rocprofiler-compute | 1 | Compute profiler |
| rocr-runtime image/ | ~20 | Image format dispatch — many similar switches |

These can be triaged in a future pass if needed.
