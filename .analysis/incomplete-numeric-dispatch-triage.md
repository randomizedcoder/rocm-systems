# incomplete-numeric-dispatch Triage

**Date**: 2026-04-14
**Rules**: `incomplete-numeric-dispatch` (values 0/1) + `incomplete-numeric-dispatch-2` (values 1/2)
**Total findings**: 50 production code (+ 2 test files excluded)
**Real bugs**: 0
**Suspicious**: 1 (addrlib vendored code — possible copy-paste)
**False positives**: 47
**Low risk**: 2

## Key observation

The dominant false positive pattern is **semgrep splitting multi-arm chains**. When code is `if (x == 0) { ... } else if (x == 1) { ... } else if (x == 2) { ... } else { ... }`, semgrep fires on the first two arms and reports it as "handles 0 and 1 but no else." The tool cannot see that the chain continues. This accounts for ~80% of all findings.

---

## CLR (10 findings)

### interop_d3d9.cpp — plane index dispatch (7 findings)

| Line | Variable | Classification | Reasoning |
|------|----------|---------------|-----------|
| 110 | `plane` (NV12) | FP | NV12 only has 2 planes (0, 1); both handled |
| 117 | `plane` (P010) | FP | P010 only has 2 planes; both handled |
| 145 | `plane` (NV12+P010 setObjDesc) | FP | Both planes handled |
| 161 | `plane` (YV12, values 0/1) | FP | Tool split 3-way chain; plane==2 handled at line 173 |
| 167 | `plane` (YV12, values 1/2) | FP | Same chain as 161; plane==0 handled above |
| 407 | `plane` (NV12 format) | Low risk | Invalid plane leaves `image_channel_order` unset; input controlled by D3D9 interop |
| 415 | `plane` (P010 format) | Low risk | Same pattern as 407 |

### palblit.cpp — dimSize_ dispatch (3 findings)

| Line | Variable | Classification | Reasoning |
|------|----------|---------------|-----------|
| 1093 | `dimSize_` | FP | 2-bit field (1/2/3); `else` clause handles 3D case — complete dispatch |
| 1411 | `dimSize_` | FP | Same pattern |
| 2356 | `dimSize_` | FP | Same pattern |

---

## rocdecode (8 findings)

All in video codec parsers (AV1/H.264). All false positives.

| Line | Variable | Classification | Reasoning |
|------|----------|---------------|-----------|
| av1_parser.cpp:1460 | `seq_profile` | FP | `else` branch at line 1466 handles profile 2+ |
| avc_parser.cpp:941 | loop `i` (scaling list) | FP | `else` at line 950 handles i >= 2 per H.264 fall-back rule A |
| avc_parser.cpp:974 | `pic_order_cnt_type` | FP | Type 2 requires no extra syntax per H.264 §7.4.2.1; omission is spec-correct |
| avc_parser.cpp:1190 | loop `i` (PPS scaling) | FP | Same as 941 pattern |
| avc_parser.cpp:1803 | `pic_order_cnt_type` | FP | Tool saw first 2 arms; type 2 handled at line 1900 |
| avc_parser.cpp:1841 | `pic_order_cnt_type` | FP | Same chain as 1803; middle+last arms |
| avc_parser.cpp:1969 | `pic_order_cnt_type` | FP | Inside `#if 0` dead code — never compiled |
| avc_parser.cpp:1976 | `pic_order_cnt_type` | FP | Same `#if 0` block |

---

## RCCL (7 findings)

All false positives — tool splits multi-arm chains.

| Line | Variable | Classification | Reasoning |
|------|----------|---------------|-----------|
| collectives.h:559 | `phase` (PatRS) | FP | State machine phases 0–4; full chain continues at lines 575/607/629/652 |
| collectives.h:575 | `phase` (PatRS) | FP | Same chain; phases 2/3/4 in subsequent arms |
| collectives.h:823 | `phase` (PatAG) | FP | Phases 0–2; phase 2 at line 864 |
| collectives.h:836 | `phase` (PatAG) | FP | Same chain; phase 0 at line 823 |
| common.h:681 | `COLL_UNROLL` | FP | Compile-time constant (1/2/4); `else` handles value 4 |
| common.h:688 | `COLL_UNROLL` | FP | Same pattern in alternate code path |
| nccl_device/utility.h:260 | `alignof(T)` | FP | 5-way chain (1/2/4/8/else≥16); tool saw only first 2 arms |

---

## rocprofiler-sdk + rocshmem (2 findings)

| Line | Variable | Classification | Reasoning |
|------|----------|---------------|-----------|
| late.cpp:112 | `ret` (registration return) | FP | 0=success, 1=no-tools, else=error — all handled |
| endian.hpp:36 | `sizeof(T)` | FP | `if constexpr` chain covers 1/2/4/8 + `static_assert` else — compile-time exhaustive |

---

## addrlib — vendored AMD address library (19 findings)

16 clean false positives (binary flags, `% 3` dispatch, multi-arm chains with `ADDR_ASSERT`).

### Suspicious: addrlib2.cpp:1705-1711 — possible copy-paste bug

```cpp
// In ComputeSurface3DMicroBlockOffset, IsStandardSwizzle block:
if (log2ElementBytes == 0)
{
    microBlockOffset = ((pIn->slice & 4) >> 2) | ((pIn->y & 4) >> 1);
}
else if (log2ElementBytes == 1)
{
    microBlockOffset = ((pIn->slice & 4) >> 2) | ((pIn->y & 4) >> 1);  // IDENTICAL body
}
```

Both branches produce the same expression. The 2D equivalent (`ComputeSurface2DMicroBlockOffset`) and the ZOrder sibling in the same function both differentiate cases 0 and 1. The structural asymmetry suggests a copy-paste error where case 1 should include an extra bit for 16-bit elements.

**Impact**: Only affects 16-bit-element 3D standard-swizzle textures — would produce wrong microblock offsets. Low severity, vendored code (shared with kernel driver).

**Recommendation**: Flag to AMD addrlib maintainers if pursuing.

---

## Conclusion

The `incomplete-numeric-dispatch` rules have a much higher false positive rate than estimated (~94% vs predicted ~20%). The primary cause is semgrep's inability to see beyond the first two arms of a multi-arm if/else-if chain. These rules would benefit from a pattern-not clause that excludes chains with a trailing `else`.

The one interesting find (addrlib duplicate case body) was discovered not by the rule's intended detection pattern (missing cases) but as a side effect — the duplicate bodies are what made the "incomplete" flag worth investigating.
