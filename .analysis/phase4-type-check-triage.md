# Phase 4 Triage: type-check-no-else, ternary-type-dispatch, unconditional-after-type-member

**Date**: 2026-04-14
**Total findings**: 365 production code
**Triaged**: 126 (rocr-runtime 29, rocdecode 51, ternary+unconditional 46)
**Skipped**: 239 (clr, rocprofiler-*, rccl, etc.)

## Results

**Real bugs: 2** (both in rocdecode utils — missing `==` in `||` conditions)
**PRs filed**: #5063 (bug 1 — roc_video_dec.cpp), #5064 (bug 2 — ffmpeg_video_dec.cpp)
**Low risk: 7**
**False positives: 117**

---

## REAL BUGS

### Bug 1: `roc_video_dec.cpp:308` — always-false chroma format check (PR #5063)

```cpp
if (video_chroma_format_ == rocDecVideoChromaFormat_420 || rocDecVideoChromaFormat_Monochrome)
```

`rocDecVideoChromaFormat_Monochrome` is enum value **0**, not a comparison. The `||` evaluates to `(comparison) || (0)` which makes the Monochrome term **always false** — the condition reduces to just `video_chroma_format_ == rocDecVideoChromaFormat_420`. Monochrome video silently falls through to the 4:4:4 or 4:2:2 path, producing the wrong surface format.

**Correct form** (already present at line 553 in the reconfigure path):
```cpp
if (video_chroma_format_ == rocDecVideoChromaFormat_420 || video_chroma_format_ == rocDecVideoChromaFormat_Monochrome)
```

**Impact**: Monochrome video (e.g. grayscale HEVC) gets the wrong output surface format in `HandleVideoSequence()`, potentially causing incorrect decode output or downstream failures.

**Introduced in**: `db6dbf7076` _"Rr/roc video decode class (#20)"_ (2023-10-23) by Rajy Rawther.

### Bug 2: `ffmpeg_video_dec.cpp:361` — always-true codec check (PR #5064)

```cpp
if (codec_id_ == rocDecVideoCodec_AVC || rocDecVideoCodec_HEVC)
```

Same pattern. `rocDecVideoCodec_HEVC` is enum value **4** (non-zero), so the condition is always true. Every codec enters the AVC/HEVC SEI path, and AV1 streams get SEI data double-written (once via the always-true path, once via the AV1 check at line 373). The `sei_buffer` pointer is still advanced correctly (line 376), so no memory corruption.

**Correct form**:
```cpp
if (codec_id_ == rocDecVideoCodec_AVC || codec_id_ == rocDecVideoCodec_HEVC)
```

**Introduced in**: `fb82691ef2` _"ffmpeg software decoder implementation (#461)"_ (2024-12-04) by Rajy Rawther.

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

The `type-check-no-else` rule (the broadest WARNING-level rule) found **2 real bugs** — but not through its intended detection mechanism (missing else for discriminator values). Instead, it flagged lines where a missing `==` operator created always-true or always-false conditions depending on the enum's integer value. This is a known C/C++ pitfall: `if (x == A || B)` instead of `if (x == A || x == B)`.

- Bug 1: `Monochrome = 0` → `|| 0` is always **false** (Monochrome silently unhandled)
- Bug 2: `HEVC = 4` → `|| 4` is always **true** (all codecs enter AVC/HEVC path)

These bugs are better detected by `-Wint-in-bool-context` (GCC) or `-Wconstant-logical-operand` (Clang). The semgrep rule caught them incidentally.

**PRs**: #5063, #5064
