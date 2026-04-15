# alloca() Audit — rocr-runtime

**Date**: 2026-04-14

**Issue**: https://github.com/ROCm/rocm-systems/issues/5051

**Tool**: cppcheck flagged `alloca` as obsolete; manual review of each call site for sizeof mismatches, unbounded sizes, and other bugs.

**Fixed**:
- `signal.cpp:243` sizeof mismatch — PR https://github.com/ROCm/rocm-systems/pull/5052
- `amd_hsa_code.cpp:530` wrong sizeof in AddNoteIsa() — PR https://github.com/ROCm/rocm-systems/pull/5059

## Summary

| # | File | Line | Function | Verdict |
|---|------|------|----------|---------|
| 1 | `fmm.c` | 1129 | `fmm_register_mem_svm_api()` | SAFE |
| 2 | `fmm.c` | 1167 | `fmm_map_mem_svm_api()` | RISK |
| 3 | `svm.c` | 61 | `hsakmt_svm_set_attribute_ext()` | RISK |
| 4 | `svm.c` | 129 | `hsakmt_svm_get_attribute_ext()` | RISK |
| 5 | `events.c` | 295 | `get_mem_info_svm_api()` | SAFE |
| 6 | `queues.c` | 486 | `register_svm_range()` | SAFE |
| 7 | `runtime.cpp` | 1118 | `PointerInfo` | RISK |
| 8 | `runtime.cpp` | 1639 | `MemoryImport` | RISK |
| 9 | `hsa_ext_amd.cpp` | 1310 | `hsa_amd_ipc_memory_attach()` | RISK |
| 10 | `os_win.cpp` | 184 | `GetEnvVar()` | RISK |
| 11 | `amd_hsa_code.cpp` | 530 | `AddNoteIsa()` | **BUG** — PR [#5059](https://github.com/ROCm/rocm-systems/pull/5059) |
| 12 | `amd_hsa_code.cpp` | 816 | `AddNoteProducer()` | RISK |
| 13 | `amd_hsa_code.cpp` | 838 | `AddNoteProducerOptions()` | RISK |
| 14 | `amd_hsa_code.cpp` | 1403 | `PrintRawData()` | RISK |
| 15 | `device.cpp` | 843 | `SetCuMask()` | SAFE |
| 16 | `device.cpp` | 958 | `WaitOnMultipleEvents()` | RISK |
| 17 | `KFDTestUtil.cpp` | 873 | `RegisterSVMRange()` | LOW |
| 18 | `KFDSVMRangeTest.cpp` | 1375 | `MigrateFileBackedRangeTest()` | LOW |

---

## #1: fmm.c — fmm_register_mem_svm_api()

**Path**: `projects/rocr-runtime/libhsakmt/src/fmm.c:1129`

```c
s_attr = 2 * sizeof(struct kfd_ioctl_svm_attribute);
args = alloca(sizeof(*args) + s_attr);
```

**Assessment: SAFE** — `s_attr` is a compile-time constant (`2 * sizeof(struct)`). Size is small and bounded.

---

## #2: fmm.c — fmm_map_mem_svm_api()

**Path**: `projects/rocr-runtime/libhsakmt/src/fmm.c:1167`

```c
static HSAKMT_STATUS fmm_map_mem_svm_api(HsaKFDContext *ctx,
                          void *address, uint64_t size,
                          uint32_t *nodes_to_map, uint32_t nodes_array_size)
{
    nattr = nodes_array_size;
    s_attr = sizeof(struct kfd_ioctl_svm_attribute) * nattr;
    args = alloca(sizeof(*args) + s_attr);
```

**Assessment: RISK** — `nodes_array_size` comes from the caller with no bounds check. A large value would overflow the stack. In practice, this is the number of GPU nodes (typically < 16), but there is no validation.

---

## #3: svm.c — hsakmt_svm_set_attribute_ext()

**Path**: `projects/rocr-runtime/libhsakmt/src/svm.c:61`

```c
hsakmt_svm_set_attribute_ext(HsaKFDContext *ctx,
     void *start_addr, HSAuint64 size, unsigned int nattr,
     HSA_SVM_ATTRIBUTE *attrs)
{
    s_attr = sizeof(*attrs) * nattr;
    args = alloca(sizeof(*args) + s_attr);
```

**Assessment: RISK** — `nattr` is an external parameter with no bounds check. This is a public API function — callers control `nattr` directly.

---

## #4: svm.c — hsakmt_svm_get_attribute_ext()

**Path**: `projects/rocr-runtime/libhsakmt/src/svm.c:129`

```c
hsakmt_svm_get_attribute_ext(HsaKFDContext *ctx,
     void *start_addr, HSAuint64 size, unsigned int nattr,
     HSA_SVM_ATTRIBUTE *attrs)
{
    s_attr = sizeof(*attrs) * nattr;
    args = alloca(sizeof(*args) + s_attr);
```

**Assessment: RISK** — Same pattern as #3. `nattr` is an external parameter with no bounds check.

---

## #5: events.c — get_mem_info_svm_api()

**Path**: `projects/rocr-runtime/libhsakmt/src/events.c:295`

```c
HSA_SVM_ATTRIBUTE attrs[] = {
    {HSA_SVM_ATTR_PREFERRED_LOC, 0},
    {HSA_SVM_ATTR_PREFETCH_LOC, 0},
    {HSA_SVM_ATTR_ACCESS, gpu_id},
    {HSA_SVM_ATTR_SET_FLAGS, 0},
};

s_attr = sizeof(attrs);
args = alloca(sizeof(*args) + s_attr);
```

**Assessment: SAFE** — `sizeof(attrs)` is a compile-time constant (fixed array of 4 elements).

---

## #6: queues.c — register_svm_range()

**Path**: `projects/rocr-runtime/libhsakmt/src/queues.c:486`

```c
nattr = 6;
s_attr = sizeof(*attrs) * nattr;
attrs = (HSA_SVM_ATTRIBUTE *)alloca(s_attr);
```

**Assessment: SAFE** — `nattr` is hardcoded to 6. Size is small and bounded.

---

## #7: runtime.cpp — PointerInfo

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/core/runtime/runtime.cpp:1118`

```cpp
if (returnListData) {
  assert(thunkInfo.NMappedNodes <= agents_by_node_.size() &&
         "PointerInfo: Thunk returned more than all agents in NMappedNodes.");
  mappedNodes = (uint32_t*)alloca(thunkInfo.NMappedNodes * sizeof(uint32_t));
  memcpy(mappedNodes, thunkInfo.MappedNodes, thunkInfo.NMappedNodes * sizeof(uint32_t));
}
```

**Assessment: RISK** — `NMappedNodes` comes from the kernel thunk return. The assert provides a debug-mode check against `agents_by_node_.size()`, but asserts are stripped in release builds. A corrupted or malicious thunk response could overflow the stack.

---

## #8: runtime.cpp — MemoryImport

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/core/runtime/runtime.cpp:1639`

```cpp
HSAuint32* nodes = nullptr;
if (num_agents > tinyArraySize)
  nodes = new HSAuint32[num_agents];
else
  nodes = (HSAuint32*)alloca(sizeof(HSAuint32) * num_agents);
if (nodes == NULL) return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
```

**Assessment: RISK** — Has a heap fallback for large `num_agents` (> `tinyArraySize` = 8), which mitigates the worst case. However, the `alloca` path has no failure check (`alloca` cannot return NULL — the `nodes == NULL` check is dead code for the alloca branch). Low practical risk due to the size cap.

---

## #9: hsa_ext_amd.cpp — hsa_amd_ipc_memory_attach()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/core/runtime/hsa_ext_amd.cpp:1310`

```cpp
static const int tinyArraySize = 8;
core::Agent** core_agents = nullptr;
if (num_agents > tinyArraySize)
  core_agents = new core::Agent*[num_agents];
else
  core_agents = (core::Agent**)alloca(sizeof(core::Agent*) * num_agents);
if (core_agents == NULL) return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
```

**Assessment: RISK** — Same pattern as #8. Heap fallback for > 8 agents mitigates worst case. Same dead-code NULL check on alloca path. Low practical risk.

---

## #10: os_win.cpp — GetEnvVar()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/core/util/win/os_win.cpp:184`

```cpp
std::string GetEnvVar(std::string env_var_name) {
  char* buff;
  DWORD char_count = GetEnvironmentVariable(env_var_name.c_str(), NULL, 0);
  if (char_count == 0) return "";
  buff = (char*)alloca(sizeof(char) * char_count);
  GetEnvironmentVariable(env_var_name.c_str(), buff, char_count);
  buff[char_count - 1] = '\0';
  std::string ret = buff;
  return ret;
}
```

**Assessment: RISK** — `char_count` comes from `GetEnvironmentVariable()`. Environment variable length is user-controlled. A very long env var would overflow the stack. Windows-only code. Should use `std::string` or `std::vector<char>` instead.

---

## #11: amd_hsa_code.cpp — AddNoteIsa()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/libamdhsacode/amd_hsa_code.cpp:530`

```cpp
size_t size = sizeof(amdgpu_hsa_note_producer_t) + vendor_name.length() + architecture_name.length() + 1;
amdgpu_hsa_note_isa_t* desc = (amdgpu_hsa_note_isa_t*) _alloca(size);
memset(desc, 0, size);
desc->vendor_name_size = vendor_name.length()+1;
desc->architecture_name_size = architecture_name.length()+1;
```

**Assessment: BUG (fixed)** — Used `sizeof(amdgpu_hsa_note_producer_t)` (16 bytes) instead of `sizeof(amdgpu_hsa_note_isa_t)` (20 bytes), under-allocating by 4 bytes. Subsequent `memset` and `memcpy` write past the buffer. Likely copy-paste error from `AddNoteProducer()`. Present since original 2016 import. No callers found in repo (possible dead code, but public API method). Fixed in PR [#5059](https://github.com/ROCm/rocm-systems/pull/5059).

Additional risk: string lengths come from ELF note data with no overflow check on the size calculation.

---

## #12: amd_hsa_code.cpp — AddNoteProducer()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/libamdhsacode/amd_hsa_code.cpp:816`

```cpp
size_t size = sizeof(amdgpu_hsa_note_producer_t) + producer.length();
amdgpu_hsa_note_producer_t* desc = (amdgpu_hsa_note_producer_t*) _alloca(size);
memset(desc, 0, size);
memcpy(desc->producer_name, producer.c_str(), producer.length() + 1);
```

**Assessment: RISK** — `producer.length()` from ELF data. No overflow check on size. Note: the apparent off-by-one (`memcpy` copies `length() + 1` but `size` only adds `length()`) is actually correct — `sizeof(amdgpu_hsa_note_producer_t)` includes 1 byte from the `char producer_name[1]` flexible array member, which accounts for the null terminator.

---

## #13: amd_hsa_code.cpp — AddNoteProducerOptions()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/libamdhsacode/amd_hsa_code.cpp:838`

```cpp
size_t size = sizeof(amdgpu_hsa_note_producer_options_t) + options.length();
amdgpu_hsa_note_producer_options_t *desc =
    (amdgpu_hsa_note_producer_options_t*) _alloca(size);
desc->producer_options_size = options.length();
memcpy(desc->producer_options, options.c_str(), options.length() + 1);
```

**Assessment: RISK** — Same pattern as #12. The apparent off-by-one (`memcpy` copies `length() + 1` but `size` only adds `length()`) is actually correct — `sizeof(amdgpu_hsa_note_producer_options_t)` includes 1 byte from the `char producer_options[1]` flexible array member.

---

## #14: amd_hsa_code.cpp — PrintRawData()

**Path**: `projects/rocr-runtime/runtime/hsa-runtime/libamdhsacode/amd_hsa_code.cpp:1403`

```cpp
void AmdHsaCode::PrintRawData(std::ostream& out, Section* section)
{
  out << "    Data:" << std::endl;
  unsigned char *sdata = (unsigned char*)alloca(section->size());
  section->getData(0, sdata, section->size());
  PrintRawData(out, sdata, section->size());
}
```

**Assessment: RISK — HIGHEST SEVERITY** — `section->size()` comes from an ELF binary section header. ELF section sizes are completely externally controlled and can be gigabytes. A crafted code object would trivially overflow the stack. This should use heap allocation (`new` or `std::vector`).

---

## #15: device.cpp — SetCuMask()

**Path**: `projects/rocr-runtime/libhsakmt/src/dxg/wddm/device.cpp:843`

```cpp
int priv_size = Wkmi::GetCuMaskPrivDataSize();
void* priv_data = alloca(priv_size);
memset(priv_data, 0, priv_size);
Wkmi::FillinCuMaskPrivData(priv_data, doorbell, cu_mask_count, queue_cu_mask);
```

**Assessment: SAFE** — `priv_size` comes from `GetCuMaskPrivDataSize()` which returns a constant. Size is small and bounded. Windows/DXG path only. (The other `alloca(priv_size)` calls at lines 862, 909, 941, 1000, 1016, 1048 follow the same pattern.)

---

## #16: device.cpp — WaitOnMultipleEvents()

**Path**: `projects/rocr-runtime/libhsakmt/src/dxg/wddm/device.cpp:958`

```cpp
HSAKMT_STATUS WDDMDevice::WaitOnMultipleEvents(HsaEvent* events[], uint32_t num_elems,
                                               bool wait_all, uint32_t msec) {
  HANDLE* event_handles_ = reinterpret_cast<HANDLE*>(_alloca(sizeof(HANDLE) * num_elems));
  for (uint32_t i = 0; i < num_elems; ++i) {
    event_handles_[i] = reinterpret_cast<Event*>(events[i])->GetHandle();
  }
```

**Assessment: RISK** — `num_elems` is a function parameter with no bounds check. A large value would overflow the stack. Windows/DXG path only.

---

## #17: KFDTestUtil.cpp — RegisterSVMRange()

**Path**: `projects/rocr-runtime/libhsakmt/tests/kfdtest/src/KFDTestUtil.cpp:873`

```cpp
nattr = 4;
s_attr = sizeof(*attrs) * nattr;
attrs = (HSA_SVM_ATTRIBUTE *)alloca(s_attr);
```

**Assessment: LOW** — Test code. `nattr` is hardcoded to 4. No risk.

---

## #18: KFDSVMRangeTest.cpp — MigrateFileBackedRangeTest()

**Path**: `projects/rocr-runtime/libhsakmt/tests/kfdtest/src/KFDSVMRangeTest.cpp:1375`

```cpp
size_t size = PAGE_SIZE;
char *buf = reinterpret_cast<char *>(alloca(size));
memset(buf, 0x30, size);
```

**Assessment: LOW** — Test code. `size` is `PAGE_SIZE` (4096). No risk.

---

## Bugs Found During Audit

### BUG: signal.cpp:243 — sizeof mismatch (FIXED)

`sizeof(unique_evts)` = 4 bytes instead of `sizeof(uint64_t)` = 8 bytes. Allocates half the needed memory. Stack buffer overflow on Windows path. Fixed in PR #5052.

### BUG: amd_hsa_code.cpp:816 — off-by-one in AddNoteProducer()

Allocates `sizeof(...) + producer.length()` but `memcpy` copies `producer.length() + 1` bytes (null terminator). One byte overflow past the allocation.

### BUG: amd_hsa_code.cpp:838 — off-by-one in AddNoteProducerOptions()

Same pattern as above. Allocates `sizeof(...) + options.length()` but copies `options.length() + 1` bytes.

### HIGHEST RISK: amd_hsa_code.cpp:1403 — PrintRawData()

`alloca(section->size())` where section size comes from ELF binary. Completely externally controlled. Trivial stack overflow with a crafted code object.
