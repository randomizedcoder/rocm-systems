// Copyright Advanced Micro Devices, Inc.
// SPDX-License-Identifier: MIT

// Shared helpers for the container-ID libFuzzer harnesses.
//
// GuardedBuffer<N> flanks a fixed-size char buffer with 8-byte canaries so an
// off-by-one write past either end corrupts a recognizable constant even in a
// build without a sanitizer. Under -fsanitize=address the write is caught
// directly; the canary is a second, sanitizer-independent net (and keeps these
// harnesses meaningful if rebuilt without ASan).
//
// The canaries are unsigned char arrays so nothing in the struct has alignment
// above 1: a wider canary would pad buf[N] out and let an overflow land in the
// padding, invisibly. This mirrors the in-tree test helper guarded_buffer.h;
// it is vendored here so the fuzz build depends only on the production header,
// never on the test tree.

#ifndef ROCM_SYSTEMS_NIX_ANALYSIS_FUZZ_GUARD_H_
#define ROCM_SYSTEMS_NIX_ANALYSIS_FUZZ_GUARD_H_

#include <array>
#include <cstddef>
#include <cstdio>
#include <cstdlib>

namespace rocm_fuzz {

template <size_t N>
struct GuardedBuffer {
  static constexpr std::array<unsigned char, 8> kPre = {0xDE, 0xAD, 0xBE, 0xEF,
                                                        0xDE, 0xAD, 0xBE, 0xEF};
  static constexpr std::array<unsigned char, 8> kPost = {0xCA, 0xFE, 0xBA, 0xBE,
                                                         0xCA, 0xFE, 0xBA, 0xBE};

  std::array<unsigned char, 8> pre_canary = kPre;
  char buf[N] = {0};
  std::array<unsigned char, 8> post_canary = kPost;

  bool CanariesIntact() const { return pre_canary == kPre && post_canary == kPost; }
};

// Report a violated invariant and abort so libFuzzer records a crash input.
[[noreturn]] inline void Fail(const char* what) {
  std::fprintf(stderr, "fuzz invariant violated: %s\n", what);
  std::abort();
}

}  // namespace rocm_fuzz

#endif  // ROCM_SYSTEMS_NIX_ANALYSIS_FUZZ_GUARD_H_
