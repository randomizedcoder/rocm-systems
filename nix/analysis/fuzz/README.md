<!--
Copyright Advanced Micro Devices, Inc.
SPDX-License-Identifier: MIT
-->

# libFuzzer harnesses

Coverage-guided fuzzing for the untrusted-input parsers this repo has hardened.
Two flake targets drive them:

- `nix build .#fuzz` — build the fuzzer binaries + seed corpora + a `run-fuzzers`
  wrapper (does not run them).
- `nix build .#fuzz-run` — build, then run each harness for a bounded time,
  saving any crash inputs and a symbolized reproduction. **Always exits 0** — a
  crash is the deliverable, recorded under `crashes/<harness>/`, not a build
  failure. The `deep`/`all` analysis composites include this target.

```sh
# ad hoc, longer run:
nix build .#fuzz
FUZZ_TIME=300 ./result/bin/run-fuzzers
```

## Harnesses

All three target the container-ID parser
`projects/amdsmi/include/amd_smi/impl/amd_smi_container_id_parser.h`, which
`src/amd_smi/fdinfo.cc` uses to copy an attacker-influenceable
`/proc/<pid>/cgroup` value into a fixed-size field of `amdsmi_proc_info_t`.
The parser is header-only, so each harness compiles standalone against the
production header — no test-tree or GPU/ROCm dependency.

| Harness | Target function | What it explores |
|---|---|---|
| `fuzz_container_id` | `ExtractContainerId` | prefix-anchored LXC / Docker-short-ID extraction across output capacities |
| `fuzz_oci_container_id` | `ExtractOciContainerId` | the 64-char SHA-256 scan and the refuse-don't-truncate capacity boundary |
| `fuzz_resolve_container_id` | `ResolveContainerId` | the multi-line dispatch over both scans |

Each harness feeds arbitrary bytes to the parser inside a canary-guarded buffer
(`fuzz_guard.h`) and asserts memory-safety and output-contract invariants
(no OOB write, bounded length, NUL-termination, enforced charset). These mirror
the invariants the in-tree GTest suite
(`projects/amdsmi/tests/amd_smi_test/unit/system/container_id_fuzz_test.cc`)
checks without external tooling; the harnesses here add coverage guidance and
ASan/UBSan.

## Deliberately not fuzzed here

The other parser sites flagged in `analysis-reports/critical/`
(`03-sscanf-buffer-overflow`, and the PCIe BDF `sscanf("%4lx:%2x:%2x.%1x")` in
`src/amd_smi/amd_smi.cc` and the `drm-pdev` `sscanf` in `src/amd_smi/fdinfo.cc`)
are single `sscanf` calls embedded in large translation units that pull in the
full amdsmi/ROCm build. Fuzzing them faithfully means calling the production
code path, which requires either extracting each into a standalone parser
function (a production refactor, out of scope for the analysis branch) or a
full amdsmi build fixture. Reaching them is tracked as future work; a harness
that re-implemented the `sscanf` line here would fuzz a copy, not the shipped
code, and is intentionally omitted.
