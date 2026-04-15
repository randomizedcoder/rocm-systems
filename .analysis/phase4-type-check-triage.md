# Phase 4 Triage: type-check-no-else, ternary-type-dispatch, unconditional-after-type-member

**Date**: 2026-04-14
**Total findings**: 365 production code
**Triaged**: 126 (rocr-runtime 29, rocdecode 51, ternary+unconditional 46)
**Skipped**: 239 (clr, rocprofiler-*, rccl, etc.)

## Results

**Real bugs: 2** (both in rocdecode utils — always-true `||` conditions)
**Low risk: 7**
**False positives: 117**

---

## REAL BUGS

### Bug 1: `roc_video_dec.cpp:308` — always-true chroma format check

```cpp
if (video_chroma_format_ == rocDecVideoChromaFormat_420 || rocDecVideoChromaFormat_Monochrome)
```

`rocDecVideoChromaFormat_Monochrome` is a bare enum value (non-zero integer), not a comparison. The `||` evaluates to `(comparison) || (non-zero)` which is **always true**. Every chroma format is silently mapped to NV12/P016, and the `else if` branches for YUV444 and YUV422 surface formats are **dead code** on the initial decoder creation path.

**Correct form** (already present at line 553 in the reconfigure path):
```cpp
if (video_chroma_format_ == rocDecVideoChromaFormat_420 || video_chroma_format_ == rocDecVideoChromaFormat_Monochrome)
```

**Impact**: 4:4:4 and 4:2:2 video content gets decoded to NV12/P016 instead of the appropriate surface format on first decode. The fallback logic at line 316 may mitigate this by checking `decode_caps.output_format_mask`, but the intent is clearly to match the surface format to the chroma format.

### Bug 2: `ffmpeg_video_dec.cpp:361` — always-true codec check

```cpp
if (codec_id_ == rocDecVideoCodec_AVC || rocDecVideoCodec_HEVC)
```

Same pattern. `rocDecVideoCodec_HEVC` is non-zero, so the condition is always true. The AV1 branch at line 373 (`if (codec_id_ == rocDecVideoCodec_AV1)`) is **unreachable** when `fp_sei_` is open — AV1 SEI messages are never written to the output file. The `sei_buffer` pointer is still advanced correctly (line 376), so no memory corruption, but AV1 SEI data is silently dropped.

**Correct form**:
```cpp
if (codec_id_ == rocDecVideoCodec_AVC || codec_id_ == rocDecVideoCodec_HEVC)
```

---

## rocr-runtime (29 findings → 0 bugs, 5 low risk, 24 FP)

No real bugs. Low-risk items:
- `hsa.cpp:653,688` — extension support silently returns `false` for non-GPU agents
- `hsakmtmodel.c:690` — non-SIGNAL events skip age bookkeeping
- `runtime.cpp:3497` — AIE agents silently fall back to `cpu_agents_[0]` for prefetch
- `amd_topology.cpp:513` — non-XGMI links implicitly get `gang_factor=1`

## rocdecode (51 findings → 2 bugs, 2 low risk, 47 FP)

Most codec parser findings are spec-correct conditional processing (B-slice-only fields, optional VUI blocks, etc.).

Low-risk items:
- `av1_parser.cpp:599,1031` — only key-frame paths handled; other frame types fall through safely

## ternary-type-dispatch (42 findings → 0 bugs, 2 notes, 40 FP)

All ternaries are genuinely binary (GPU/CPU, send/recv, read/write) or the else-branch is correct for all non-matching values.

Notes:
- `rocdevice.cpp:3697` / `rocdevice.hpp:767` — `HwQueueEngine` has 6 values but ternary only checks `SdmaD2H`; likely intentional but worth a comment

## unconditional-after-type-member (4 findings → 0 bugs, 4 FP)

All are false positives — type fields are only used in debug printf or as plain integers, not discriminators.

---

## Conclusion

The `type-check-no-else` rule (the broadest WARNING-level rule) found **2 real bugs** — but not through its intended detection mechanism (missing else for discriminator values). Instead, it flagged lines where a missing `==` operator created always-true conditions. This is a known C/C++ pitfall: `if (x == A || B)` instead of `if (x == A || x == B)`.

These bugs are better detected by `-Wint-in-bool-context` (GCC) or `-Wconstant-logical-operand` (Clang). The semgrep rule caught them incidentally.
