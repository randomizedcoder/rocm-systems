// Copyright Advanced Micro Devices, Inc.
// SPDX-License-Identifier: MIT

// libFuzzer harness for amd::smi::ExtractContainerId.
//
// ExtractContainerId reads a /proc/<pid>/cgroup line (attacker-influenceable:
// a container can name itself) and copies a bounded container ID into a
// fixed-size field of amdsmi_proc_info_t. This harness asserts the parser's
// safety invariants hold for arbitrary input, driving the real production
// prefixes (kContainerIdPrefixes) across a spread of output capacities so the
// truncation, one-byte, and zero-capacity paths are all reached.
//
// Invariants (any violation aborts -> libFuzzer records the input):
//   1. No out-of-bounds write        — GuardedBuffer canaries stay intact.
//   2. Length is bounded             — bytes written <= cap - 1.
//   3. Output is NUL-terminated at the reported length.
//   4. Charset is enforced           — every output byte is [a-zA-Z0-9_-].
//   5. Zero capacity writes nothing.
//
// Build: clang++ -std=c++17 -fsanitize=fuzzer,address,undefined
//                -Iprojects/amdsmi/include -Inix/analysis/fuzz
// See README.md.

#include <cstddef>
#include <cstdint>
#include <string>

#include "amd_smi/impl/amd_smi_container_id_parser.h"
#include "fuzz_guard.h"

using rocm_fuzz::GuardedBuffer;

namespace {

template <size_t Cap>
void CheckWithCap(const std::string& line, const char* prefix, size_t out_cap) {
  GuardedBuffer<Cap> gb;
  const size_t n = amd::smi::ExtractContainerId(line, prefix, gb.buf, out_cap);

  if (!gb.CanariesIntact()) rocm_fuzz::Fail("canary smashed (out-of-bounds write)");
  if (out_cap == 0) {
    if (n != 0) rocm_fuzz::Fail("nonzero write into zero-capacity buffer");
    return;
  }
  if (n > out_cap - 1) rocm_fuzz::Fail("bytes written exceed capacity");
  if (gb.buf[n] != '\0') rocm_fuzz::Fail("output not NUL-terminated at reported length");
  for (size_t i = 0; i < n; ++i) {
    if (!amd::smi::IsContainerIdChar(static_cast<unsigned char>(gb.buf[i]))) {
      rocm_fuzz::Fail("output byte outside [a-zA-Z0-9_-]");
    }
  }
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const std::string line(reinterpret_cast<const char*>(data), size);
  for (const char* prefix : amd::smi::kContainerIdPrefixes) {
    CheckWithCap<256>(line, prefix, 256);
    CheckWithCap<16>(line, prefix, 16);
    CheckWithCap<1>(line, prefix, 1);
    CheckWithCap<1>(line, prefix, 0);
  }
  return 0;
}
