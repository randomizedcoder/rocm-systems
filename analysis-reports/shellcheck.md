# shellcheck Analysis Report

## Executive Summary

shellcheck found **1,300 findings** across shell scripts in the monorepo. The dominant finding is SC2086 (unquoted variables, 838 occurrences), which accounts for 64% of all findings. Most issues live in build and CI scripts. The overall false positive rate is estimated at 20-30% because some variables are intentionally unquoted (e.g., flag lists, word-split-intended expansions). The most operationally significant category is SC2164 (cd without error checking, 29 findings), which can cause silent failures in CI pipelines that change directories before performing destructive operations.

---

## Findings Breakdown

| Code | Count | Description | Priority |
|---|---|---|---|
| SC2086 | 838 | Double-quote to prevent globbing/word splitting | Medium |
| SC2223 | 113 | Redundant variable assignment (use := default syntax) | Low |
| SC2046 | 49 | Unquoted command substitution | Medium |
| SC2068 | 31 | Array expansion must be double-quoted | Medium |
| SC2164 | 29 | cd without error check (`cd foo || exit`) | Medium |
| SC2034 | 27 | Variable appears unused | Low |
| SC2145 | 26 | Prefix/suffix applied to array rather than last element | Medium |
| SC2162 | 17 | read without -r (backslash interpretation) | Low |
| SC2155 | 15 | Declare and assign separately to capture exit code | Low |
| SC2294 | 13 | eval on array in zsh (deprecated pattern) | Low |
| SC2154 | 11 | Variable referenced but not assigned | Medium |
| SC2329 | 10 | Loop body runs in subshell (while read pattern) | Low |
| SC2242 | 10 | Signal spec should be number or name | Low |
| SC2196 | 9 | egrep is deprecated, use grep -E | Low |
| SC2166 | 8 | Prefer [[ ]] for compound conditions | Low |

**Total: 1,300**

---

## False Positive Analysis by Category

### SC2086 (838) — ~25% false positive

Most unquoted variables should be quoted, but a meaningful fraction are intentional:
- Flag arrays built as space-separated strings and intentionally word-split: e.g., `$CFLAGS`, `$CMAKE_ARGS`
- Variables used as command lists or option sequences

Real findings: ~630 out of 838. These should be fixed because word-splitting on filenames with spaces or special characters causes silent bugs in CI.

### SC2223 (113) — ~5% false positive

`VAR=${VAR:-default}` is the correct idiom for defaulting. The `VAR=; VAR=${VAR:-default}` pattern is almost always just redundancy left over from refactoring. Nearly all are real findings.

### SC2046 (49) — ~20% false positive

Unquoted command substitutions like `$(ls ...)` are usually bugs. A small number are intentional word-splits (e.g., building argument arrays from command output). Around 40 are genuine.

### SC2068 (31) — ~10% false positive

`${array[@]}` must be double-quoted as `"${array[@]}"` to prevent word splitting on array elements containing spaces. Very few legitimate exceptions.

### SC2164 (29) — ~15% false positive

`cd` without `|| exit` (or `|| return`) means that if the directory doesn't exist, the script silently continues in the wrong directory and may delete, overwrite, or corrupt files in the current directory. Most CI scripts should be fixed. A few cases in functions that are expected to fail-and-continue may be intentional.

### SC2034 (27) — ~40% false positive

Unused variables may be exported for child processes or sourced scripts, which shellcheck cannot see. Review each case before removing.

### SC2145 (26) — ~5% false positive

Applying a suffix to `$@` or `${array[@]}` only affects the last element. These are almost always bugs in argument-passing code.

### SC2154 (11) — ~20% false positive

Variables referenced but not assigned in this script may be expected to come from the environment or a sourced file. Still worth auditing — undefined variables in CI often indicate missing setup.

### SC2155 (15) — ~5% false positive

`local var=$(cmd)` masks cmd's exit code. Should be split into `local var; var=$(cmd)`. Nearly all are genuine.

---

## Per-Project Breakdown

| Project | Findings | Notes |
|---|---|---|
| rocprofiler-systems | 465 | Largest contributor; build + CI scripts |
| rocprofiler | 176 | Build scripts, packaging |
| rocprofiler-sdk | 124 | SDK build automation |
| rccl | 111 | Collective comms build/test scripts |
| rocprofiler-compute | 88 | Python-heavy but has shell wrappers |

---

## Priority Remediation List

### P1 — MEDIUM: Fix SC2164 cd-without-error-check (29 findings)

Every `cd` in CI/build scripts that is not followed by `|| exit 1` (or `|| return 1` in functions) must be fixed. Pattern to apply:

```sh
# Before
cd "$BUILD_DIR"
make install

# After
cd "$BUILD_DIR" || exit 1
make install
```

This is especially dangerous in cleanup scripts and scripts that perform `rm -rf` after a `cd`.

Target projects first: rocprofiler-systems (465 total findings, highest concentration of build scripts), then rccl.

### P2 — MEDIUM: Fix SC2086 unquoted variables (838 findings, ~630 real)

Quote all variable expansions that refer to paths, filenames, or user-provided input:

```sh
# Before
cp $SRC_FILE $DEST_DIR/

# After
cp "$SRC_FILE" "$DEST_DIR/"
```

For flag lists and option strings intended to word-split, convert to arrays:

```sh
# Before
FLAGS="-O2 -march=native"
gcc $FLAGS foo.c

# After
FLAGS=(-O2 -march=native)
gcc "${FLAGS[@]}" foo.c
```

### P3 — MEDIUM: Fix SC2046 and SC2068 array expansions (80 findings combined)

Audit all `$(...)` usages without quotes and all `${array[@]}` without double quotes. These are common sources of CI failures on paths with spaces.

### P4 — LOW: Fix SC2155 declare-and-assign (15 findings)

Split `local var=$(cmd)` into two lines. This is a low-effort fix that prevents masking command failure exit codes, improving CI reliability.

### P5 — LOW: Fix SC2223 redundant assignments (113 findings)

Simplify `VAR=; VAR=${VAR:-default}` to `VAR=${VAR:-default}`. Pure cleanup.

### P6 — LOW: Replace deprecated egrep (9 SC2196 findings)

Replace `egrep` with `grep -E` globally. Simple find-replace, no behavior change.

---

## Recommended Next Steps

1. Run `shellcheck --format=diff` to generate auto-applicable patches for SC2086, SC2155, SC2196, and SC2223.
2. Add shellcheck to the pre-commit hooks for all projects with shell scripts.
3. Use `# shellcheck disable=SC2086` with an explanatory comment for the intentional word-split cases, making the intent explicit.
4. For the 29 SC2164 findings, do a manual review — automated patching is unsafe here because the correct recovery action (exit, return, continue, or log-and-continue) depends on context.
5. Consider adopting `set -euo pipefail` at the top of all CI scripts to catch unquoted/unset variable errors at runtime even without shellcheck.
