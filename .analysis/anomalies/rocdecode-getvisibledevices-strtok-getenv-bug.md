# rocdecode GetVisibleDevices: strtok on getenv() return

**Status:** confirmed-bug
**Tool:** cpplint `runtime/threadsafe_fn`
**File:** `projects/rocdecode/src/rocdecode/vaapi/vaapi_videodecoder.cpp:1012, 1015`
**Reviewed:** 2026-04-13

## Bug

```cpp
void VaContext::GetVisibleDevices(std::vector<int>& visible_devices_vetor) {
    char *visible_devices = std::getenv("ROCR_VISIBLE_DEVICES");
    if (visible_devices == nullptr) {
        visible_devices = std::getenv("HIP_VISIBLE_DEVICES");
    }
    if (visible_devices != nullptr) {
        char *token = std::strtok(visible_devices, ",");   // ← line 1012
        while (token != nullptr) {
            visible_devices_vetor.push_back(std::atoi(token));
            token = std::strtok(nullptr, ",");              // ← line 1015
        }
        ...
    }
}
```

`std::getenv` returns a pointer to the process environment's internal
string. `std::strtok` modifies its input in place (it rewrites delimiter
bytes to `\0`). Applying `strtok` directly to the `getenv` return is
undefined behaviour (C11 §7.22.4.6, POSIX.1-2008) — it corrupts the
environment variable for any subsequent `getenv` call in the same
process.

Secondary concern: `strtok` itself uses a static save-pointer, so two
decoder instances initializing on different threads can corrupt each
other's token state.

## Fix

`strdup` + `strtok_r` + `free`, or use `std::string` + `std::stringstream`.
Pattern already used correctly elsewhere in the same codebase — see
`projects/hip/*/hipDeviceGetUuid.cc:120-127`.

```cpp
char *visible_devices_env = std::getenv("ROCR_VISIBLE_DEVICES");
if (!visible_devices_env) visible_devices_env = std::getenv("HIP_VISIBLE_DEVICES");
if (visible_devices_env) {
    std::string s = visible_devices_env;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        visible_devices_vetor.push_back(std::atoi(item.c_str()));
    }
    std::sort(visible_devices_vetor.begin(), visible_devices_vetor.end());
}
```

## Severity

Medium. Deterministic UB on every call, but only observable if
downstream code re-reads the same env var. Mitigated in practice because
`ROCR_VISIBLE_DEVICES` / `HIP_VISIBLE_DEVICES` are typically read
exactly once per process.

## Follow-up

To file: upstream PR against ROCm/rocm-systems in the `rocdecode`
sub-project. Pair with the identical `rocjpeg` fix
(see `rocjpeg-getvisibledevices-strtok-getenv-bug.md`).
