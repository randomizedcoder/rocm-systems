# Static Analysis Findings Report

**Repository**: rocm-systems
**Date**: 2026-04-11
**Branch**: basic-static-analysis
**Scope**: Full repository (28 projects, ~7,600 source files, 10+ languages)
**Tools**: 13 static analysis tools via Nix (`nix build .#analysis-all`)

---

## Executive Summary

| Tool | Findings | Severity | Report |
|------|----------|----------|--------|
| **flawfinder** | 3,359 | 33 critical, 421 high | [Details](analysis-reports/flawfinder.md) |
| **semgrep-cpp** | 34,525 | 100 memcpy bugs, 59 use-after-free | [Details](analysis-reports/semgrep-cpp.md) |
| **hip-check** | 9,835 | 11 double-free, 172 missing sync | [Details](analysis-reports/hip-check.md) |
| **cpplint** | 38,259 | 121 thread-unsafe, rest style | [Details](analysis-reports/cpplint.md) |
| **ruff** | 51,967 | Mostly style, 576 unused imports | [Details](analysis-reports/ruff.md) |
| **pylint** | 29,065 | 334 unused imports, 319 unused vars | [Details](analysis-reports/pylint.md) |
| **bandit** | 7,185 | 52 high (shell injection, SSL) | [Details](analysis-reports/bandit.md) |
| **semgrep-python** | ~1,763 | Security patterns | [Details](analysis-reports/semgrep-python.md) |
| **shellcheck** | 1,300 | 838 unquoted variables | [Details](analysis-reports/shellcheck.md) |
| **yamllint** | 20,706 | All formatting | [Details](analysis-reports/yamllint.md) |
| **cmake-lint** | 650 | All formatting | [Details](analysis-reports/cmake-lint.md) |
| **fortran-lint** | 0 | Missing module deps | [Details](analysis-reports/fortran-lint.md) |

**Total**: ~199,000+ findings (significant cross-tool overlap; estimated ~2,000 unique actionable issues after dedup and false-positive removal).

---

## Findings by Severity

### CRITICAL (Fix Immediately) — ~20 findings

| Finding | Tool | Files | Risk |
|---------|------|-------|------|
| `sscanf`/`sprintf` buffer overflows | flawfinder | amdsmi (22+ locations) | Unbounded writes from sysfs/proc input |
| `chmod` TOCTOU on crypto keys | flawfinder | cuid (3 files) | Symlink attack on key material |
| `memcpy(dst, src, sizeof(ptr))` | semgrep-cpp | 100 locations | Copies 8 bytes instead of data |
| `strncat` with wrong size | flawfinder | hip-tests (3 locations) | Buffer overflow |
| HIP double-free | hip-check | 11 locations | GPU memory corruption |

### HIGH (Fix This Sprint) — ~500 findings

| Finding | Tool | Count | Risk |
|---------|------|-------|------|
| Dangling `.c_str()` | semgrep-cpp | 59 | Use-after-free |
| Unchecked `hipMalloc` in runtime | hip-check + semgrep | ~300 non-test | Silent GPU failures |
| `readlink` TOCTOU (sysfs paths) | flawfinder | ~13 | Race condition in daemon |
| `access()` TOCTOU | flawfinder | ~60 | Race condition before open |
| `popen()` shell injection | flawfinder | 2 | Command injection if input is tainted |
| Python `shell=True` in CI | bandit | 52 | Command injection from PR data |
| SSL `verify=False` | bandit | 2 | MITM attacks |
| Thread-unsafe functions | cpplint + semgrep | 207 | Data races (`strtok`, `strerror`) |
| Missing HIP sync | hip-check | ~50 non-test | Undefined behavior on GPU data |

### MEDIUM (Fix Next Sprint) — ~3,000 findings

| Finding | Tool | Count | Risk |
|---------|------|-------|------|
| Raw `malloc`/`free` in C++ | semgrep-cpp | 1,887 | Memory leaks on exceptions |
| `const_cast` usage | semgrep-cpp | 312 | UB if modifying const data |
| `reinterpret_cast` | semgrep-cpp | 2,604 | Type safety bypass |
| HIP resource leaks (free/stream/event) | hip-check | 261 | GPU memory exhaustion |
| Unused Python imports | ruff + pylint | 910 | Dead code |
| `relaxed` memory ordering | semgrep-cpp | 64 | Subtle concurrency bugs |
| Unquoted shell variables | shellcheck | 838 | Word splitting/globbing |
| SQL injection patterns | bandit + ruff | 151 | If queries use user input |

### LOW (Ongoing Cleanup) — ~195,000 findings

Style, formatting, documentation, naming conventions. See per-tool reports for details.

---

## Per-Project Risk Assessment

| Project | Critical | High | Key Concerns |
|---------|----------|------|--------------|
| **amdsmi** | 5 | 80+ | Buffer overflows, TOCTOU races, popen injection. Runs as daemon with elevated privileges. |
| **cuid** | 3 | 10+ | `chmod` TOCTOU on HMAC key files. Security-critical daemon. |
| **clr** | 0 | 150+ | Core HIP runtime. 150 unchecked HIP API returns, 6,067 cpplint issues. |
| **hip-tests** | 3 | 800+ | Largest finding count but test code. `strncat` overflow is real. |
| **rccl** | 0 | 140+ | GPU collective communications. Unchecked HIP returns risk silent corruption. |
| **rocr-runtime** | 0 | 180+ | HSA runtime. 181 semgrep findings, 2,587 cpplint. |
| **rocprofiler-systems** | 0 | 115+ | Profiling runtime. readlink TOCTOU (mostly /proc/self — safe). |
| **rocshmem** | 0 | 94+ | GPU shared memory. Thread safety and HIP API concerns. |
| **rdc** | 0 | 55+ | Remote device control. `access()` TOCTOU, readlink races. |
| **rocprofiler-sdk** | 0 | 100+ | Profiling SDK. 4,107 cpplint, 93 semgrep findings. |

---

## Tools Not Yet Run

These require compile databases or full builds and take longer:

| Tool | What It Does | Est. Time |
|------|-------------|-----------|
| clang-tidy | Deep C++ linting with type info | ~30 min |
| cppcheck | Interprocedural C++ analysis | ~20 min |
| clang-analyzer | Path-sensitive analysis | ~30 min |
| gcc-warnings | Extended compiler warnings | ~20 min |
| gcc-analyzer | GCC interprocedural analysis | ~20 min |
| iwyu | Include-what-you-use | ~15 min |
| coccinelle | Semantic pattern matching | ~10 min |
| mypy | Python type checking | ~10 min |
| clippy | Rust linting | ~5 min |

Run with `nix build .#analysis-all` to execute everything.

---

## Cross-Tool Correlations

Files flagged by 3+ tools (highest confidence findings):

| File/Area | Tools | Likely Issue |
|-----------|-------|--------------|
| `amdsmi/rocm_smi/src/rocm_smi_utils.cc` | flawfinder, cpplint, semgrep | Buffer overflows, TOCTOU, format strings |
| `amdsmi/src/amd_smi/amd_smi.cc` | flawfinder, cpplint, semgrep | TOCTOU, sscanf overflows, shell injection |
| `amdsmi/src/amd_smi/fdinfo.cc` | flawfinder, cpplint, semgrep | sscanf overflows, strcpy, readlink |
| `cuid/lib/src/cuid_file.cc` | flawfinder, cpplint | chmod TOCTOU on file permissions |
| `cuid/lib/src/hmac.cc` | flawfinder | chmod TOCTOU on HMAC key file |
| `hip-tests/catch/unit/device/` | flawfinder, cpplint | strncat buffer overflow |

---

## Recommended Remediation Phases

### Phase 1: Security-Critical (This Week)
- [ ] Fix `sscanf`/`sprintf` buffer overflows in amdsmi (add width limits)
- [ ] Replace `chmod` with `fchmod` in cuid
- [ ] Audit `popen()` calls in amdsmi for input sanitization
- [ ] Fix `memcpy-sizeof-pointer` findings (100 locations)
- [ ] Fix SSL `verify=False` or document accepted risk
- [ ] Review HIP double-free findings (11 locations)

### Phase 2: Correctness (This Sprint)
- [ ] Add `HIP_CHECK()` wrappers in clr/rccl/rocshmem production code
- [ ] Fix `dangling-c-str` findings (59 locations)
- [ ] Replace `strtok` with `strtok_r` (121 locations)
- [ ] Fix `strncat` buffer overflow in hip-tests
- [ ] Add sync barriers for HIP missing-sync in production code

### Phase 3: Code Quality (Next Sprint)
- [ ] Remove unused Python imports (`ruff --fix --select=F401`)
- [ ] Replace `access()+open()` with direct `open()` in amdsmi
- [ ] Replace raw `malloc`/`free` with RAII in C++ code
- [ ] Harden `.github/scripts/` against shell injection
- [ ] Fix `unspecified-encoding` in Python (650 locations)

### Phase 4: Style Cleanup (Ongoing)
- [ ] Run `ruff --fix` for auto-fixable issues (~30,000)
- [ ] Run `gersemi` for CMake formatting (650 files)
- [ ] Address yamllint issues in rocprofiler-compute (15,381)
- [ ] Apply cpplint include ordering (8,223)

---

## Running the Analysis

```bash
# Quick checks (~5 min)
nix build .#analysis-quick

# All 21 tools
nix build .#analysis-all

# Individual tools
nix build .#analysis-flawfinder
nix build .#analysis-semgrep-cpp

# Per-project
nix build .#analysis-amdsmi-clang-tidy

# View results
cat result/summary.txt
ls result/          # Each tool has its own subdirectory
```

## Triage System

After reviewing findings, add entries to `.analysis/anomalies.toml` to suppress false positives:

```bash
# Run triage
python3 -m nix.analysis.triage result/ --summary --source-root .
python3 -m nix.analysis.triage result/ --high-confidence --source-root .
python3 -m nix.analysis.triage result/ --new-only --source-root .
```

See [nix/README.md](nix/README.md) for full documentation.
