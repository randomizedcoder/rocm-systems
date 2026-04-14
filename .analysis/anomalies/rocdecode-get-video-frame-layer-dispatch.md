# rocdecode: GetVideoFrame layer dispatch bugs

## Location

- `projects/rocdecode/src/rocdecode/roc_decoder.cpp:177-185`
- Introduced: commit `18f165e424` (2024-02-05) — "Fix the performance issue introduced after PR#192 (#220)"
- Author: Aryan Salmanpour

## Bug Description

`RocDecoder::GetVideoFrame()` maps VA-API decoded video surfaces to HIP device
memory. The function returns an array of 3 device memory pointers (`dev_mem_ptr[3]`)
and 3 pitch values (`horizontal_pitch[3]`), one per YUV plane.

### Bug 1: 3-layer surfaces skip layer 1 (U plane)

```cpp
// Line 177-185
*&dev_mem_ptr[0] = hip_interop_[pic_idx].hip_mapped_device_mem;       // always
horizontal_pitch[0] = hip_interop_[pic_idx].pitch[0];                 // always

if (hip_interop_[pic_idx].num_layers == 2) {
    *&dev_mem_ptr[1] = ... + offset[1];       // layer 1 set
    horizontal_pitch[1] = ...pitch[1];
} else if (hip_interop_[pic_idx].num_layers == 3) {
    *&dev_mem_ptr[2] = ... + offset[2];       // layer 2 set, but NOT layer 1
    horizontal_pitch[2] = ...pitch[2];
}
```

The `else if` means the `num_layers == 3` branch **never enters the `num_layers == 2`
branch**. Layer 1 (U plane) is never set. The caller receives an uninitialized
`dev_mem_ptr[1]` — a garbage pointer that, when dereferenced, causes silent
memory corruption or a segfault.

This affects **YUV 4:4:4 planar** surfaces (3 separate planes: Y, U, V).

### Bug 2: Unconditional out-of-bounds read during surface caching

```cpp
// Lines 162-168 — always executed regardless of num_layers
hip_interop_[pic_idx].offset[0] = va_drm_prime_surface_desc.layers[0].offset[0];
hip_interop_[pic_idx].offset[1] = va_drm_prime_surface_desc.layers[1].offset[0];
hip_interop_[pic_idx].offset[2] = va_drm_prime_surface_desc.layers[2].offset[0];

hip_interop_[pic_idx].pitch[0] = va_drm_prime_surface_desc.layers[0].pitch[0];
hip_interop_[pic_idx].pitch[1] = va_drm_prime_surface_desc.layers[1].pitch[0];
hip_interop_[pic_idx].pitch[2] = va_drm_prime_surface_desc.layers[2].pitch[0];
```

`VADRMPRIMESurfaceDescriptor.layers[]` has 4 entries (VA-API spec), but only
`num_layers` of them are valid. For NV12 (2 layers), `layers[2]` is uninitialized.
For Y800 (1 layer, monochrome), `layers[1]` and `layers[2]` are uninitialized.

This reads garbage into the cached `offset[]` and `pitch[]` arrays. The garbage
values are then used when computing device memory pointers in Bug 1.

### Bug 3: No validation of num_layers

Values 0 or >3 are silently ignored. No error is returned. The caller receives
a partially-filled output array with no indication of which entries are valid.

## VA-API Layer Counts by Surface Format

| Format | Chroma | Layers | Planes |
|--------|--------|--------|--------|
| Y800 | Monochrome (4:0:0) | 1 | Y only |
| NV12 | 4:2:0 (8-bit) | 2 | Y + interleaved UV |
| P010 | 4:2:0 (10-bit) | 2 | Y + interleaved UV |
| P012 | 4:2:0 (12-bit) | 2 | Y + interleaved UV |
| YUV 4:2:2 | 4:2:2 | 2-3 | Implementation-dependent |
| YUV 4:4:4 | 4:4:4 | 3 | Y + U + V |

Currently rocdecode supports: Y800 (1 layer), NV12/P010/P012 (2 layers).
YUV 4:2:2 and 4:4:4 are declared in the chroma format enum but the VA-API
surface creation path exists for them (`vaapi_videodecoder.cpp:578-583`).

## Reachability

- **Bug 1 (3-layer skip)**: Reachable when decoding YUV 4:4:4 content. The
  chroma format enum includes `rocDecVideoChromaFormat_444` and the VA surface
  creation handles it. Whether any current AMD GPU VA-API driver produces
  3-layer surfaces depends on hardware support, but the code path exists.
- **Bug 2 (OOB read)**: Reachable NOW for every NV12 decode (the most common
  format). `layers[2]` is read but only 2 layers exist. The VA-API descriptor
  is stack-allocated and zero-initialized (`= {}`), so in practice the garbage
  is zeros. But this is still undefined behavior per the VA-API contract.
- **Bug 3 (no validation)**: Defensive issue. Becomes reachable if VA-API ever
  returns unexpected `num_layers`.

## Root Cause

The layer dispatch logic is embedded in a large function that mixes hardware
interop (VA-API export, HIP memory import) with pure arithmetic (pointer
offset computation). The function is untestable without a GPU + VA-API stack,
so the logic bugs were never caught.

## Fix Approach

1. **Extract** the layer pointer dispatch into a standalone function
   (`PopulateLayerPointers` or similar) that takes the `HipInteropDeviceMem`
   struct and output arrays as parameters.
2. **Fix Bug 1**: Use fallthrough logic — 3 layers sets [0], [1], AND [2].
3. **Fix Bug 2**: Only read `layers[i]` for `i < num_layers`.
4. **Fix Bug 3**: Return an error for `num_layers == 0` or `num_layers > 3`.
5. **Add unit tests**: Table-driven tests covering num_layers 0, 1, 2, 3, 4,
   and beyond (e.g., 8, 255) to validate both correct behavior and error
   rejection. These tests require no hardware.

## PR

Filed as [ROCm/rocm-systems#5032](https://github.com/ROCm/rocm-systems/pull/5032) on branch `fix/rocdecode-get-video-frame-layer-dispatch`. All three bugs fixed, 19 GPU-free unit tests added.

## Existing Test Coverage

- Only negative API tests exist (null params, invalid index)
- Zero coverage of layer dispatch logic
- No mocks or stubs for VA-API
- All functional tests require real GPU hardware
