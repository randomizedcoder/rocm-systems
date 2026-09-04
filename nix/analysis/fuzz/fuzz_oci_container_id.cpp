// Copyright Advanced Micro Devices, Inc.
// SPDX-License-Identifier: MIT

// libFuzzer harness for amd::smi::ExtractOciContainerId.
//
// ExtractOciContainerId scans a cgroup line for the 64-char SHA-256 that every
// OCI runtime (Docker, containerd, CRI-O, Podman) names a container cgroup
// after, delimited like a path component. The interesting boundaries are the
// exact-length match, the capacity boundary at kOciContainerIdLength (an ID
// that does not fit must be reported as absent, never truncated), and the
// prefix/suffix anchoring — so this harness sweeps capacities straddling 64.
//
// Invariants (any violation aborts -> libFuzzer records the input):
//   1. No out-of-bounds write        — GuardedBuffer canaries stay intact.
//   2. Length is bounded             — bytes written <= cap - 1.
//   3. Output is NUL-terminated at the reported length.
//   4. Result length is exactly 0 or exactly kOciContainerIdLength.
//   5. Every output byte is a lowercase hex digit.
//   6. cap <= kOciContainerIdLength writes nothing (refuse, do not truncate).

#include <cstddef>
#include <cstdint>
#include <string>

#include "amd_smi/impl/amd_smi_container_id_parser.h"
#include "fuzz_guard.h"

using rocm_fuzz::GuardedBuffer;

namespace {

template <size_t Cap>
void CheckWithCap(const std::string& line, size_t out_cap) {
  GuardedBuffer<Cap> gb;
  const size_t n = amd::smi::ExtractOciContainerId(line, gb.buf, out_cap);

  if (!gb.CanariesIntact()) rocm_fuzz::Fail("canary smashed (out-of-bounds write)");
  if (out_cap == 0) {
    if (n != 0) rocm_fuzz::Fail("nonzero write into zero-capacity buffer");
    return;
  }
  if (n > out_cap - 1) rocm_fuzz::Fail("bytes written exceed capacity");
  if (gb.buf[n] != '\0') rocm_fuzz::Fail("output not NUL-terminated at reported length");
  if (n != 0 && n != amd::smi::kOciContainerIdLength) {
    rocm_fuzz::Fail("OCI id length neither 0 nor kOciContainerIdLength");
  }
  if (out_cap <= amd::smi::kOciContainerIdLength && n != 0) {
    rocm_fuzz::Fail("wrote an OCI id that cannot fit (should refuse)");
  }
  for (size_t i = 0; i < n; ++i) {
    if (!amd::smi::IsLowerHexChar(static_cast<unsigned char>(gb.buf[i]))) {
      rocm_fuzz::Fail("output byte is not a lowercase hex digit");
    }
  }
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  const std::string line(reinterpret_cast<const char*>(data), size);
  CheckWithCap<128>(line, 128);  // comfortably fits
  CheckWithCap<65>(line, 65);    // smallest capacity that can hold 64 + NUL
  CheckWithCap<64>(line, 64);    // one short: must refuse
  CheckWithCap<1>(line, 1);
  CheckWithCap<1>(line, 0);
  return 0;
}
