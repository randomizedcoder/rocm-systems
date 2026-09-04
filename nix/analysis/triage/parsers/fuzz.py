"""Parser for libFuzzer crash artifacts produced by the .#fuzz-run target.

The fuzz-run derivation writes, under its output (linked into the deep/all
composite as ``fuzz-run/``)::

    fuzz-run/count.txt              total crash inputs across all harnesses
    fuzz-run/crashes/<harness>/     crash-* inputs + repro.txt (symbolized)

Each crash input is a genuine memory-safety / invariant violation the parser
let through, so it is reported as an ``error`` finding. On a hardened parser
the expected result is zero crashes and therefore zero findings.
"""

import re
from pathlib import Path

from finding import Finding

# ASan/UBSan frames name the offending source as "<path>:<line>:<col>". We
# prefer a frame in the parser header over the harness itself.
_LOC_RE = re.compile(r'([\w./+-]+\.(?:h|hpp|c|cc|cpp|cxx)):(\d+)(?::\d+)?')
_HARNESS_HINT = re.compile(r'nix/analysis/fuzz/')


def _pick_location(repro_text: str) -> tuple[str, int]:
    """Best-effort source location for the crash: first non-harness frame."""
    fallback = ('projects/amdsmi/include/amd_smi/impl/amd_smi_container_id_parser.h', 0)
    first = None
    for m in _LOC_RE.finditer(repro_text):
        path, line = m.group(1), int(m.group(2))
        if first is None:
            first = (path, line)
        if not _HARNESS_HINT.search(path):
            return (path, line)
    return first if first is not None else fallback


def parse(result_dir: str) -> list[Finding]:
    findings: list[Finding] = []
    crashes_root = Path(result_dir) / 'fuzz-run' / 'crashes'
    if not crashes_root.is_dir():
        # Also accept a bare fuzz-run output passed directly.
        crashes_root = Path(result_dir) / 'crashes'
    if not crashes_root.is_dir():
        return findings

    for harness_dir in sorted(crashes_root.iterdir()):
        if not harness_dir.is_dir():
            continue
        harness = harness_dir.name
        repro = harness_dir / 'repro.txt'
        repro_text = repro.read_text(errors='replace') if repro.exists() else ''
        file_path, line = _pick_location(repro_text)

        crash_inputs = sorted(harness_dir.glob('crash-*'))
        # If a crash exists but no crash-* file was captured, still report one.
        count = max(len(crash_inputs), 1) if (crash_inputs or repro_text.strip()) else 0
        for _ in range(count):
            findings.append(Finding(
                tool='fuzz',
                check_id=f'fuzz-{harness}',
                severity='error',
                file=file_path,
                line=line,
                message=(f'libFuzzer found a crashing input for fuzz_{harness}; '
                         f'see fuzz-run/crashes/{harness}/repro.txt'),
            ))
    return findings
