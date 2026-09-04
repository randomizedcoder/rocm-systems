// Copyright Advanced Micro Devices, Inc.
// SPDX-License-Identifier: MIT

// libFuzzer harness for amd::smi::ResolveContainerId.
//
// ResolveContainerId is the top-level entry fdinfo.cc calls: it takes the full
// set of /proc/<pid>/cgroup lines and returns the container ID, trying the
// OCI SHA-256 scan first and the prefix scan second. This harness splits the
// fuzz input on newlines into a cgroup_lines vector so libFuzzer explores the
// multi-line dispatch and the interaction between the two scans, then asserts
// the same output-buffer safety invariants across a spread of capacities.
//
// Invariants (any violation aborts -> libFuzzer records the input):
//   1. No out-of-bounds write        — GuardedBuffer canaries stay intact.
//   2. Length is bounded             — bytes written <= cap - 1.
//   3. Output is NUL-terminated at the reported length.
//   4. Charset is enforced           — every output byte is [a-zA-Z0-9_-]
//      (the union of OCI lowercase-hex and LXC/Docker-short-ID characters).
//   5. Zero capacity writes nothing.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "amd_smi/impl/amd_smi_container_id_parser.h"
#include "fuzz_guard.h"

using rocm_fuzz::GuardedBuffer;

namespace {

std::vector<std::string> SplitLines(const std::string& blob) {
  std::vector<std::string> lines;
  size_t start = 0;
  for (size_t i = 0; i <= blob.size(); ++i) {
    if (i == blob.size() || blob[i] == '\n') {
      lines.emplace_back(blob.substr(start, i - start));
      start = i + 1;
    }
  }
  return lines;
}

template <size_t Cap>
void CheckWithCap(const std::vector<std::string>& lines, size_t out_cap) {
  GuardedBuffer<Cap> gb;
  const size_t n = amd::smi::ResolveContainerId(lines, gb.buf, out_cap);

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
  const std::vector<std::string> lines =
      SplitLines(std::string(reinterpret_cast<const char*>(data), size));
  CheckWithCap<256>(lines, 256);
  CheckWithCap<65>(lines, 65);
  CheckWithCap<16>(lines, 16);
  CheckWithCap<1>(lines, 1);
  CheckWithCap<1>(lines, 0);
  return 0;
}
