"""Unified finding loader across all tool parsers."""

from pathlib import Path

from finding import Finding
from parsers import cppcheck, semgrep, clang, flawfinder, generic


def load_all_findings(result_dir: str) -> list[Finding]:
    """Load findings from all available tool reports."""
    findings = []
    rd = Path(result_dir)

    # cppcheck XML
    p = rd / 'cppcheck' / 'report.xml'
    if p.exists():
        findings.extend(cppcheck.parse(str(p)))

    # semgrep JSON (C/C++ and Python)
    for subdir in ('semgrep-cpp', 'semgrep-python', 'hip-check'):
        p = rd / subdir / 'report.json'
        if p.exists():
            findings.extend(semgrep.parse(str(p)))

    # clang-tidy
    p = rd / 'clang-tidy' / 'report.txt'
    if p.exists():
        findings.extend(clang.parse(str(p), 'clang-tidy'))

    # clang-analyzer
    p = rd / 'clang-analyzer' / 'report.txt'
    if p.exists():
        findings.extend(clang.parse(str(p), 'clang-analyzer'))

    # gcc-warnings
    p = rd / 'gcc-warnings' / 'report.txt'
    if p.exists():
        findings.extend(clang.parse(str(p), 'gcc-warnings'))

    # gcc-analyzer
    p = rd / 'gcc-analyzer' / 'report.txt'
    if p.exists():
        findings.extend(clang.parse(str(p), 'gcc-analyzer'))

    # flawfinder
    p = rd / 'flawfinder' / 'report.txt'
    if p.exists():
        findings.extend(flawfinder.parse(str(p)))

    # cpplint (generic line-based)
    p = rd / 'cpplint' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'cpplint'))

    # coccinelle
    p = rd / 'coccinelle' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'coccinelle'))

    # shellcheck
    p = rd / 'shellcheck' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'shellcheck'))

    # ruff
    p = rd / 'ruff' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'ruff'))

    # pylint
    p = rd / 'pylint' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'pylint'))

    # bandit JSON
    p = rd / 'bandit' / 'report.json'
    if p.exists():
        findings.extend(generic.parse_bandit_json(str(p)))

    # iwyu
    p = rd / 'iwyu' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'iwyu'))

    # fortran-lint
    p = rd / 'fortran-lint' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'fortran-lint'))

    # clippy
    p = rd / 'clippy' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'clippy'))

    # yamllint
    p = rd / 'yamllint' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'yamllint'))

    # cmake-lint
    p = rd / 'cmake-lint' / 'report.txt'
    if p.exists():
        findings.extend(generic.parse(str(p), 'cmake-lint'))

    return findings
