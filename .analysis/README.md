# Static-analysis triage workflow

This directory is the persistent triage record for static-analysis findings
across rocm-systems. Every finding that a human has reviewed should have an
entry here, so that subsequent analysis runs suppress or flag it
automatically and only **new** findings surface for attention.

## Layout

```
.analysis/
├── README.md           # this file
├── anomalies.toml      # machine-readable triage decisions (authoritative)
├── anomalies/<id>.md   # per-finding narrative (only for needs-review / confirmed-bug)
└── config.toml         # tool config shared with the triage CLI
```

## How matching works

The triage engine (`nix/analysis/triage/anomalies.py`) indexes entries by
`(tool, check_id)` and, for each incoming finding, checks:

1. The finding's file matches the entry's `file` field (exact path or
   `fnmatch` glob, e.g. `projects/rccl/src/**`).
2. The entry's `code_anchor` (a literal substring) appears within
   `±anchor_window` lines of the reported line in the current source
   tree. `anchor_window` defaults to 5.

If both match, the finding is suppressed (`false-positive`, `wont-fix`)
or flagged (`needs-review`, `confirmed-bug`). No match → the finding is
re-raised as unknown.

## When to write an entry

Any time you manually review a finding and make a decision.

Four statuses:

| status          | meaning                                           | visible in report? |
|-----------------|---------------------------------------------------|--------------------|
| `false-positive`| Reviewed, not a real issue                        | suppressed         |
| `wont-fix`      | Real issue but accepted risk                      | suppressed         |
| `needs-review`  | Potentially real, needs maintainer eyes           | flagged            |
| `confirmed-bug` | Verified real bug, tracked until fixed            | flagged            |

## Per-finding vs pattern-glob entries

Prefer **one pattern-glob entry that covers many findings** over dozens of
single-line entries, when the findings share a root cause (e.g. all wrapped
by the same error-checking macro).

- **Pattern glob**: broad `file` glob + tight `code_anchor` (the macro name,
  wrapper function, etc). Keep `anchor_window` small (2–5) so the anchor
  stays discriminating.
- **Per-finding**: one entry per location. Use this when the rationale is
  specific to that call site, or when the decision is `needs-review` /
  `confirmed-bug` (in which case pair it with a `.analysis/anomalies/<id>.md`).

**Never** write a glob without a `code_anchor`; anchorless globs risk
silently suppressing a future real bug that happens to land on the same
path.

## When to write a per-finding markdown

Only for `needs-review` and `confirmed-bug`. Carry the reasoning for
`false-positive` / `wont-fix` inline in the TOML `reason` field — that's
sufficient, and a folder of 300 tiny markdown files is noise.

## Required fields

Every entry must have: `id`, `tool`, `check_id`, `file`, `status`,
`reason`, `reviewer`, `date`. Plus `code_anchor` for anything broader
than an exact file+line match (i.e. almost always).

## Verification

After adding entries, confirm the engine matches them:

```sh
python3 nix/analysis/triage/__main__.py <result-dir> \
  --source-root $PWD \
  --anomalies-file .analysis/anomalies.toml --summary
```

The header line reports `<N> suppressed, <M> flagged`; spot-check a handful
of entries by running `--category <check_id>` and confirming the in-scope
locations are gone from the unknown list.

Round-trip sanity: temporarily rename `anomalies.toml`, re-run — all your
entries should reappear as unknown. Restore, re-run — all suppressed/flagged
again. If not, the anchor or glob is wrong.

## Why this matters

Every run without triage re-surfaces the same known-reviewed findings and
wastes human attention. The anomalies file is how we **keep the
signal-to-noise ratio improving over time**: real new bugs land in a
small, legible unknown list instead of a 20 k-line haystack.

See `CRITICAL-ISSUES.md` for which issues have been triaged and what the
real-bug rate has looked like on each pass.
