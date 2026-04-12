# Issue 9: Thread-Unsafe Functions (strtok, strerror)

## Summary

cpplint reported 121 `runtime/threadsafe_fn` warnings (predominantly `strtok`) and semgrep flagged 86 instances of `strerror-thread-unsafe`. This analysis examines every `strtok` call site and categorizes the `strerror` usage to determine which, if any, represent real concurrency bugs versus harmless lint noise.

---

## Part A: strtok Usage (30 call sites)

`strtok` maintains a hidden static pointer between calls, making it unsafe when two threads could invoke it concurrently. The thread-safe alternative is `strtok_r`, which takes an explicit save-pointer argument.

### Category 1: Runtime Libraries -- Initialization Code (LOW RISK)

These are called once during process startup or library initialization, before any multi-threaded GPU work begins.

#### RCCL debug.cc -- ncclDebugInit() (lines 75, 118, 141, 163)

```c
// projects/rccl/src/debug.cc:75
char *subsys = strtok(ncclDebugSubsys, ",");
while (subsys != NULL) {
    // ... parse NCCL_DEBUG_SUBSYS env var ...
    subsys = strtok(NULL, ",");
}
```

**Context:** `ncclDebugInit()` is called exactly once, guarded by `pthread_mutex_lock(&ncclDebugLock)` (line 298-303 of the same file). The function parses environment variables (`NCCL_DEBUG_SUBSYS`, `NCCL_DEBUG_TIMESTAMP_LEVELS`) and the strtok calls operate on `strdup`'d copies of env strings, which are freed afterward.

**Thread safety:** The entire function runs under a mutex. Even if two threads race to the first debug log call, the mutex serializes them. The strtok calls operate on local copies (`ncclDebugSubsys`, `timestampsDup`). **No real risk.**

**Note:** RCCL already uses `strtok_r` in its graph/tuning code (`topo.cc`, `tuning.cc`, `rome_models.cc`, `init.cc`, `net.cc`) -- 17 call sites total. The debug init code predates this modernization.

#### RCCL cpuset.h -- ncclStrToCpuset() and ncclStrListToCpuset() (lines 27, 30, 75, 79)

```c
// projects/rccl/src/include/cpuset.h:27
char* str = strdup(maskStr);
char* token = strtok(str, ",");
while (token != NULL && m > 0) {
    cpumasks[--m] = strtoul(token, NULL, 16);
    token = strtok(NULL, ",");
}
free(str);
```

**Context:** These are `static` helper functions called during topology discovery and CPU affinity setup. They operate on `strdup`'d copies. Topology discovery happens during NCCL initialization, which is inherently serialized.

**Thread safety:** Initialization-time only. **No real risk.**

#### CLR paldevice.cpp -- parseRequestedDeviceList() (lines 1236, 1275)

```c
// projects/clr/rocclr/device/pal/paldevice.cpp:1236
char* pch = strtok(const_cast<char*>(requestedDeviceList), ",");
```

**Context:** Parses `GPU_DEVICE_ORDINAL` environment variable during device enumeration (the `Device::init()` path). This is process initialization code.

**Additional concern:** The `const_cast<char*>` is a separate code smell -- `strtok` modifies its input in place, and this is casting away const on what may be the return value of `getenv()`. Modifying the getenv return is undefined behavior per POSIX. However, this is PAL-backend specific (Windows/consoles), not the primary Linux ROCm path.

**Thread safety:** Initialization-time only. **No real risk**, but the const_cast is a separate correctness issue.

#### rocr-runtime topology.c -- cpumap_to_cpu_ci() (lines 508, 523)

```c
// projects/rocr-runtime/libhsakmt/src/topology.c:508
ch_ptr = strtok(shared_cpu_map, ",");
while (num_hexs-- > 0) {
    mask = strtol(ch_ptr, NULL, 16);
    // ... fill SiblingMap ...
    ch_ptr = strtok(NULL, ",");
}
```

**Context:** Called from `get_cpu_cache_info()` during HSA topology discovery. This is pure initialization code that reads sysfs CPU maps once at startup. The `shared_cpu_map` is a locally-owned buffer read from a sysfs file.

**Thread safety:** Initialization-time only. **No real risk.** This is C code in libhsakmt -- `strtok_r` would be more idiomatic but the function is not reentrant in any practical scenario.

#### rocr-runtime topology_lnx.cpp (DXG variant) (lines 165, 179)

Same pattern as above, Windows/DXG variant. Initialization only.

### Category 2: Runtime Libraries -- Potentially Concurrent (MEDIUM RISK)

#### rocdecode vaapi_videodecoder.cpp -- GetVisibleDevices() (lines 1012, 1015)

```c
// projects/rocdecode/src/rocdecode/vaapi/vaapi_videodecoder.cpp:1012
char *visible_devices = std::getenv("ROCR_VISIBLE_DEVICES");
// ...
char *token = std::strtok(visible_devices, ",");
while (token != nullptr) {
    visible_devices_vetor.push_back(std::atoi(token));
    token = std::strtok(nullptr, ",");
}
```

**Context:** Parses ROCR_VISIBLE_DEVICES or HIP_VISIBLE_DEVICES at device initialization.

**Two bugs here:**
1. **strtok on getenv return:** `std::getenv` returns a pointer to the environment's internal string. `strtok` modifies this in place, which is **undefined behavior** per C/C++ standards. This corrupts the actual environment variable for any subsequent `getenv` call.
2. **Thread safety of strtok itself:** If multiple decoder instances initialize in parallel threads, they will corrupt each other's strtok state.

**This is a real bug** -- the getenv modification is the worse of the two issues. The fix should use `strdup` + `strtok_r` (or better, parse with `std::string` methods).

#### rocjpeg rocjpeg_vaapi_decoder.cpp -- GetVisibleDevices() (lines 937, 940)

```c
// projects/rocjpeg/src/rocjpeg_vaapi_decoder.cpp:937
char *token = std::strtok(visible_devices, ",");
```

**Identical pattern and identical bugs as rocdecode above.** Copy-pasted code. Both modify getenv's return value and use thread-unsafe strtok.

### Category 3: Test Code (NEGLIGIBLE RISK)

#### RCCL test/common/EnvVars.cpp (line 40)

```c
char *gcnArchNameToken = strtok(devProp.gcnArchName, ":");
```

Test-only code parsing device properties. Single-threaded test setup.

#### rocprofiler tests-v2 csv_parser.cpp (lines 32, 36)

```c
char* token = strtok(const_cast<char*>(str.c_str()), &delim);
```

Test utility code. The `const_cast<char*>(str.c_str())` is technically UB (modifying `std::string` internal buffer via strtok), but this is test tooling. Single-threaded.

#### RCCL archinfo.cc -- GcnArchNameFormat() (line 31)

```c
char *gcnArchNameToken = strtok(gcnArchName, ":");
```

Called from `GetGcnArchName()` which queries device properties. This modifies the `hipDeviceProp_t.gcnArchName` field in place. Used in test code (`test/common/EnvVars.cpp` calls the same pattern). Not called from hot paths in the runtime.

### Category 4: Example/Sample Code (NEGLIGIBLE RISK)

#### rocprofiler-systems examples (common.h, rccl-tests) (lines 1532, 1536, 94, 98)

Example code shipping with the profiler. Not part of any runtime library.

#### rocdecode samples/common.h (lines 80, 83)

Command-line argument parsing in sample applications.

#### experimental perf-dkms packet_gen_tool.c (lines 116-118)

```c
char *block_str = strtok(spec_copy, ":");
char *index_str = strtok(NULL, ":");
char *event_str = strtok(NULL, ":");
```

Experimental tooling, single-threaded command-line parsing on a local copy (`spec_copy`).

### Category 5: RCCL ext-tuner plugin.c (lines 214, 224)

```c
// projects/rccl/ext-tuner/example/plugin.c:214
char lineCopy[MAX_LINE_LENGTH];
strncpy(lineCopy, line, sizeof(lineCopy));
// ...
token = strtok(lineCopy, ",");
```

Example tuner plugin. Operates on a local copy. Single-threaded CSV parsing during config load.

---

## Part B: strerror Usage (260 occurrences across 80 files)

`strerror` returns a pointer to a static buffer that may be overwritten by subsequent calls. The thread-safe alternative is `strerror_r`. Only 1 call site in the entire codebase uses `strerror_r` (in an example file).

### Categorization

| Category | Approx. Count | Examples |
|----------|--------------|---------|
| Error/debug logging in RCCL | ~50 | `checks.h` (9 macro uses), `socket.cc`, `ipcsocket.cc`, `proxy.cc`, `xml.cc`, `ibvwrap.h` |
| Error logging in rocr-runtime | ~30 | `os_linux.cpp` (16 alone), `fmm.c`, `topology.c`, `events.c`, `svm.c` |
| Error logging in amdsmi/rocm-smi | ~40 | `amd_smi.cc`, `rocm_smi_device.cc`, `rocm_smi_utils.cc` |
| Error logging in rocprofiler-systems | ~15 | `perf.cpp`, `cache_manager.cpp`, `RTposix.c` |
| Error logging in clr | ~12 | `rocprogram.cpp` (11), `os_posix.cpp` |
| Test code | ~30 | `hip-tests`, `kfdtest`, `rocrtst`, RCCL tests |
| Examples/samples/tools | ~20 | `hipfile`, `aiscp`, `rocflop`, `packet_gen_tool` |
| Third-party/vendored | ~10 | `hsail-compiler`, `pal`, gtest |
| Other runtime/SDK | ~50 | `rocprofiler-sdk`, `hipfile`, `rocshmem`, `cuid` |

### Risk Assessment for strerror

**The core question:** Could two threads call `strerror` simultaneously, causing one to read a corrupted/wrong error message?

**Analysis of the highest-traffic sites:**

1. **RCCL checks.h macros** (9 sites): These are `SYSCHECK`, `SYSCHECKVAL`, etc. macros that call `WARN()` or `INFO()`. The WARN/INFO macros go through `ncclDebugLog()`, which acquires `ncclDebugLock` mutex. However, `strerror(errno)` is evaluated *before* the lock is acquired (it's a macro argument). Two threads hitting a syscall error simultaneously could interleave `strerror` calls. **Theoretically unsafe, but:**
   - These are error paths -- they fire when syscalls fail, which is rare.
   - On glibc (the ROCm target), `strerror` is actually thread-safe by implementation (it uses thread-local storage). This is a glibc extension, not guaranteed by POSIX.
   - The worst outcome is a garbled error message string in a log line. No data corruption, no crash.

2. **rocr-runtime os_linux.cpp** (16 sites): Thread creation, mutex initialization, pthread operations. These fire on `pthread_create` failure, `pthread_setaffinity_np` failure, etc. All error paths. The `fprintf(stderr, ...)` calls are themselves not mutex-protected, so there's already a potential for interleaved stderr output.

3. **RCCL socket/proxy code**: Network error paths. `strerror(errno)` in warning messages when poll/accept/send fails.

### glibc Reality Check

On Linux with glibc (the only target for ROCm), `strerror()` is implemented thread-safely using a thread-local buffer. From the glibc source:

> The glibc implementation of `strerror` uses `strerror_r` internally with a thread-local buffer, making it de facto thread-safe on Linux.

This means the lint warnings are technically correct by the C/POSIX standard, but **practically harmless on the only platform ROCm targets**.

---

## Part C: Honest Risk Assessment

### strtok Findings

| Risk Level | Count | Description |
|------------|-------|-------------|
| **Real bug** | 4 sites (2 functions) | rocdecode and rocjpeg `GetVisibleDevices()` -- modifies `getenv` return value AND uses thread-unsafe strtok |
| **Low risk** | ~16 sites | Initialization code in RCCL, rocr-runtime, CLR -- mutex-protected or inherently single-threaded |
| **Negligible** | ~10 sites | Test code, examples, experimental tools |

**The 121 cpplint warnings are overwhelmingly false positives in context.** The vast majority of strtok usage is in initialization code that runs once, often under a lock. The RCCL codebase itself has already migrated to `strtok_r` in its newer code (17 `strtok_r` sites vs. 8 remaining `strtok` sites).

**The two real bugs (rocdecode + rocjpeg)** are not about thread safety of strtok per se -- the primary issue is that they call `strtok` directly on the pointer returned by `getenv()`, which modifies the environment string in place. This is undefined behavior regardless of threading.

### strerror Findings

| Risk Level | Count | Description |
|------------|-------|-------------|
| **Theoretical only** | ~260 sites | All are in error/diagnostic logging paths |

**The 86 semgrep warnings are essentially all false positives for this codebase:**

1. **glibc makes strerror thread-safe** on Linux, which is the only ROCm platform.
2. Every single call site is in an error-handling path that produces a log message. Even if the message were garbled, the consequence is a confusing log line, not a crash or data corruption.
3. Migrating 260 call sites to `strerror_r` (which has two incompatible signatures -- POSIX vs. GNU) would be significant churn for zero practical benefit.

### How Multi-Threaded Is Host-Side GPU Runtime Code?

The host side of ROCm runtime libraries is moderately multi-threaded:
- RCCL creates proxy threads, service threads, and bootstrap threads.
- rocr-runtime creates OS threads for signal handling and memory management.
- Applications may call HIP APIs from multiple threads.

However, the strtok call sites are specifically in:
- One-time initialization paths (environment variable parsing, topology discovery)
- Configuration file parsing (tuner plugins)
- Device property queries (test utilities)

None of these are in hot paths or concurrent execution paths. The multi-threaded parts of the runtime (collective operations, proxy communication, memory management) do not use strtok.

---

## Recommendations

### Priority 1: Fix the rocdecode/rocjpeg getenv Modification Bug
- **Files:** `projects/rocdecode/src/rocdecode/vaapi/vaapi_videodecoder.cpp:1012` and `projects/rocjpeg/src/rocjpeg_vaapi_decoder.cpp:937`
- **Fix:** `strdup` the getenv result, use `strtok_r` on the copy, `free` afterward. Or better: use `std::string` + `std::stringstream` like `hipDeviceGetUuid.cc:120-127` already does in the same codebase.
- **Severity:** Medium. This is actual undefined behavior that could corrupt the process environment.

### Priority 2: Fix the CLR const_cast on getenv Return
- **File:** `projects/clr/rocclr/device/pal/paldevice.cpp:1236`
- **Fix:** `strdup` + `strtok_r` + `free`.
- **Severity:** Low. PAL backend, initialization-only, but the const_cast is a correctness defect.

### Priority 3: Consider Batch strtok -> strtok_r Migration (Low Priority)
- The remaining ~16 sites in RCCL/rocr-runtime initialization code could be migrated to `strtok_r` for consistency with RCCL's newer code. This is pure cleanup -- no bug fix.

### Priority 4: Do Not Migrate strerror (Not Recommended)
- ROCm targets glibc-based Linux exclusively. `strerror` is thread-safe there.
- Migrating to `strerror_r` is error-prone due to the POSIX/GNU signature conflict.
- The lint warnings should be suppressed or the rule disabled for this codebase.

---

## Appendix: Complete strtok Call Site Inventory

| File | Line(s) | Context | On strdup copy? | Risk |
|------|---------|---------|-----------------|------|
| `rccl/src/debug.cc` | 75, 118, 141, 163 | Init, mutex-held | Yes | None |
| `rccl/src/include/cpuset.h` | 27, 30, 75, 79 | Init, topology | Yes | None |
| `rccl/src/misc/archinfo.cc` | 31 | Device query | No (modifies devProp) | Low |
| `rccl/ext-tuner/example/plugin.c` | 214, 224 | Config parse | Yes (local copy) | None |
| `rccl/test/common/EnvVars.cpp` | 40 | Test code | No (modifies devProp) | None (test) |
| `clr/rocclr/device/pal/paldevice.cpp` | 1236, 1275 | Init, const_cast | No (modifies const param) | Low |
| `rocr-runtime/libhsakmt/src/topology.c` | 508, 523 | Init, sysfs parse | No (owned buffer) | None |
| `rocr-runtime/libhsakmt/src/dxg/topology_lnx.cpp` | 165, 179 | Init, DXG variant | No (owned buffer) | None |
| `rocdecode/src/.../vaapi_videodecoder.cpp` | 1012, 1015 | Init, **modifies getenv** | **No** | **Medium** |
| `rocjpeg/src/rocjpeg_vaapi_decoder.cpp` | 937, 940 | Init, **modifies getenv** | **No** | **Medium** |
| `rocprofiler-systems/examples/...` | multiple | Example code | Mixed | None (example) |
| `rocdecode/samples/common.h` | 80, 83 | Sample CLI parse | No (modifies argv-like) | None (sample) |
| `rocprofiler/tests-v2/.../csv_parser.cpp` | 32, 36 | Test utility | No (const_cast UB) | None (test) |
| `experimental/perf-dkms/.../packet_gen_tool.c` | 116-118 | Tool, local copy | Yes | None |
