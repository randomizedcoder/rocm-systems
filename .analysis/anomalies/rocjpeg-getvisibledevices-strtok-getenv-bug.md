# rocjpeg GetVisibleDevices: strtok on getenv() return

**Status:** 🟢 fixed — [ROCm/rocm-systems#5010](https://github.com/ROCm/rocm-systems/pull/5010)
**Tool:** cpplint `runtime/threadsafe_fn`
**File:** `projects/rocjpeg/src/rocjpeg_vaapi_decoder.cpp:937, 940`
**Reviewed:** 2026-04-13

## Bug

Copy-paste of the rocdecode bug
(`rocdecode-getvisibledevices-strtok-getenv-bug.md`). Same shape, same
UB, same fix:

```cpp
void RocJpegVappiDecoder::GetVisibleDevices(std::vector<int>& visible_devices_vetor) {
    char *visible_devices = std::getenv("ROCR_VISIBLE_DEVICES");
    if (visible_devices == nullptr) {
        visible_devices = std::getenv("HIP_VISIBLE_DEVICES");
    }
    if (visible_devices != nullptr) {
        char *token = std::strtok(visible_devices, ",");   // ← line 937
        while (token != nullptr) {
            visible_devices_vetor.push_back(std::atoi(token));
            token = std::strtok(nullptr, ",");              // ← line 940
        }
        ...
    }
}
```

`std::strtok` modifies its input in place; applying it to the pointer
returned by `std::getenv` corrupts the process environment (undefined
behaviour per C11 §7.22.4.6).

## Fix

Identical to the rocdecode remediation — `strdup` + `strtok_r` + `free`,
or preferably `std::string` + `std::stringstream`.

## Severity

Medium. Should be fixed together with the rocdecode site in a single PR
since they share a root cause.

## Follow-up

Fixed in [ROCm/rocm-systems#5010](https://github.com/ROCm/rocm-systems/pull/5010)
— hardened single-pass `ParseVisibleDevicesCsv()` helper with strict
`[0-9,]` charset, length/digit/range caps, and 9 unit tests per
sub-project. Covers both rocdecode and rocjpeg in one PR.
