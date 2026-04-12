# yamllint Analysis Report

## Executive Summary

yamllint found **20,706 findings** across YAML files in the monorepo. This number is dominated by a single project: rocprofiler-compute contributes 15,381 findings (74% of the total). Virtually all findings are formatting issues — indentation inconsistencies, trailing spaces, missing document-start markers, and overly long lines. There are zero findings that indicate actual YAML parsing bugs or semantic errors. This is the lowest-priority tool in the static analysis suite. Remediation is best handled by running an auto-formatter (e.g., `prettier --parser yaml` or `yamlfmt`) rather than making manual edits.

---

## Findings Breakdown

| Category | Count | Description | Priority |
|---|---|---|---|
| indentation | 13,322 | Incorrect indentation level | Low (style) |
| anchors | 3,803 | Anchor/alias usage warnings | Low |
| line-length | 2,068 | Lines exceeding max length | Low (style) |
| trailing-spaces | 707 | Trailing whitespace on lines | Low (style) |
| document-start | 431 | Missing `---` document start marker | Low |
| comments | 223 | Comment formatting (spacing) | Low (style) |
| braces | 56 | Flow mapping style | Low (style) |
| brackets | 24 | Flow sequence style | Low (style) |
| hyphens | 20 | List item hyphen spacing | Low (style) |
| new-line-at-end-of-file | 12 | Missing trailing newline | Low (style) |

**Total: 20,706**

---

## False Positive Analysis by Category

### indentation (13,322) — ~5% false positive

YAML is whitespace-sensitive, so these are genuine deviations from the configured indentation standard. However, "genuine deviation from style standard" is not the same as a bug. YAML parsers accept any consistent indentation. The findings indicate that rocprofiler-compute's YAML files were authored with different indentation conventions than what yamllint is configured to enforce. These are all auto-fixable.

### anchors (3,803) — ~30% false positive

YAML anchors (`&anchor`) and aliases (`*alias`) are a valid YAML feature used extensively in CI configuration for job inheritance (e.g., GitHub Actions, GitLab CI). yamllint warns about duplicate anchors, which are technically valid but can cause confusion. Many of these are intentional patterns in CI YAML. True duplicate-anchor bugs (where the wrong value gets silently overridden) are rare and require manual review to identify.

### line-length (2,068) — ~80% false positive

Long lines in YAML are often unavoidable for URLs, command strings, and shell script inlines in CI files. Wrapping these introduces folded/literal block scalars that can reduce readability. Most line-length findings in CI YAML are not worth fixing.

### trailing-spaces (707) — ~0% false positive

Trailing whitespace is always removable and is universally agreed to be unwanted. Auto-fixable with any editor or `sed -i 's/[[:space:]]*$//'`.

### document-start (431) — ~50% false positive

The `---` document start marker is optional in YAML files that contain a single document. It is required in multi-document streams. Many files omit it by convention; requiring it is a stylistic choice. GitHub Actions YAML files do not require it.

### comments (223) — ~70% false positive

yamllint enforces a space between `#` and the comment text. Many CI YAML files use `#comment` without space as a formatting choice. This is purely cosmetic.

### braces / brackets / hyphens (100 combined) — ~60% false positive

Flow vs. block style preferences. Entirely stylistic with no functional impact.

### new-line-at-end-of-file (12) — ~0% false positive

Missing final newline is a genuine (though trivial) issue. Auto-fixable.

---

## Per-Project Breakdown

| Project | Findings | Share | Notes |
|---|---|---|---|
| rocprofiler-compute | 15,381 | 74% | Bulk of findings; test/benchmark configs |
| hip-tests | 3,847 | 19% | Test configuration YAML |
| rocprofiler-sdk | 561 | 3% | SDK configuration files |
| .github/workflows | 366 | 2% | CI workflow files |
| Other | 551 | 3% | Scattered across other projects |

### rocprofiler-compute (15,381 findings)

This single project accounts for three-quarters of all yamllint findings. The files are likely auto-generated or bulk-created benchmark/test configuration files with inconsistent formatting. The most efficient remediation is a one-time bulk auto-format pass, not individual file edits.

### .github/workflows (366 findings)

CI workflow files are higher priority than test configs because formatting errors can cause subtle bugs (e.g., a command string that wraps incorrectly, an anchor that shadows the wrong job). Worth reviewing manually before bulk auto-formatting.

---

## Priority Remediation List

### P1 — LOW: Auto-format rocprofiler-compute YAML files

Run `prettier --write --parser yaml` or `yamlfmt -w` on all YAML files in rocprofiler-compute. This will resolve approximately 15,000 of the 20,706 total findings in a single automated pass. Commit the result as a dedicated formatting-only commit for clean diff history.

### P2 — LOW: Fix trailing-spaces globally (707 findings)

Add trailing-whitespace removal to the project's `.editorconfig` and run a one-time cleanup. This affects all projects and is the highest-signal category (zero false positives).

### P3 — LOW: Review .github/workflows anchor usage (subset of 3,803)

Manually audit duplicate anchor warnings in CI workflow files. A duplicated anchor in a GitHub Actions workflow can cause a job to silently inherit the wrong configuration. The number of findings in this category for workflow files is small.

### P4 — LOW: Fix missing trailing newlines (12 findings)

Trivial; fix with `sed -i -e '$a\' file` or via editor settings.

### P5 — DEFER: All other categories

indentation, line-length, document-start, comments, braces, brackets, hyphens in non-CI files are purely cosmetic and should be handled by setting up an auto-formatter in pre-commit hooks rather than targeted fixes.

---

## Recommended Next Steps

1. Add `yamlfmt` or `prettier` (YAML mode) to the pre-commit hook configuration so new files are automatically formatted.
2. Run a bulk auto-format pass on rocprofiler-compute and commit separately from functional changes.
3. Configure yamllint with a project-appropriate `.yamllint.yml` that relaxes line-length and document-start rules where they generate noise, reducing the reported findings to a meaningful signal set.
4. Do not treat the 20,706 number as indicating significant technical debt — the real actionable count after false-positive filtering and auto-fix is near zero.
