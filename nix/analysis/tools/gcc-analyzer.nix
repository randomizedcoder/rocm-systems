# gcc-analyzer — GCC -fanalyzer interprocedural static analysis.
#
# Performs deep path-sensitive analysis at compile time: null derefs,
# use-after-free, double-free, buffer overflows, leaks, and infinite loops
# across function boundaries.
#
# DB-driven: iterates the merged compile_commands.json, re-driving gcc
# -fanalyzer per first-party translation unit with that entry's include/define
# flags (compiler-specific clang-only flags are stripped). This mirrors how
# cppcheck/clang-tidy/clang-analyzer consume the shared DB, so enriching the DB
# once benefits every path-sensitive tool.
#
{ pkgs, lib, src, analysisLib, compileDb }:

let
  driver = pkgs.writeText "gcc-analyzer-driver.py" ''
    """Re-drive gcc -fanalyzer over first-party TUs in a compile DB."""
    import json
    import os
    import re
    import shlex
    import subprocess
    import sys
    from concurrent.futures import ThreadPoolExecutor

    compile_db_dir = sys.argv[1]
    output_dir = sys.argv[3]

    with open(os.path.join(compile_db_dir, "compile_commands.json")) as fh:
        db = json.load(fh)

    SRC_RE = re.compile(r"/nix/store/[a-z0-9]+-source/")
    def rel(p):
        return SRC_RE.sub("", p) if p else p

    # First-party shipping code only (mirrors the triage aggregator).
    FIRST = ("projects/clr", "projects/rocr-runtime", "projects/rccl",
             "projects/amdsmi", "projects/rocm-smi-lib", "projects/rocprofiler",
             "projects/rocprofiler-sdk", "projects/rocprofiler-systems",
             "projects/rocprofiler-compute", "projects/rocdecode",
             "projects/rocjpeg", "projects/rocdbgapi", "projects/rocshmem",
             "projects/roctracer", "projects/rocr-debug-agent", "projects/rdc",
             "projects/aqlprofile", "projects/hip", "projects/rocm-core",
             "shared/kpack", "shared/")
    EXCL = ("/test/", "/tests/", "/samples/", "/example", "/external/",
            "/third-party/", "/third_party/", "/googletest/", "hip-tests/",
            "/addrlib/", "/gtest", "/benchmark", "/prebuilt", "/tools/",
            "_test.", "test_", ".spec.", "/vendor/", "/deps/")
    def firstparty(p):
        if not p or not any(p.startswith(f) for f in FIRST):
            return False
        low = p.lower()
        return not any(e in low for e in EXCL)

    # Flags worth carrying into gcc; everything else (clang-only -f*, -x, -W*,
    # the compiler token, -c/-o) is dropped so gcc does not choke.
    KEEP_PREFIX = ("-I", "-isystem", "-D", "-std", "-include")
    TAKES_ARG = ("-I", "-isystem", "-D", "-include")
    C_EXTS = (".c",)
    CXX_EXTS = (".cc", ".cpp", ".cxx")

    def extract_flags(cmd):
        toks = shlex.split(cmd)
        flags = []
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.startswith(KEEP_PREFIX):
                flags.append(t)
                if t in TAKES_ARG and i + 1 < len(toks):
                    flags.append(toks[i + 1])
                    i += 1
            i += 1
        return flags

    # Dedup by file; keep only first-party C/C++ TUs.
    units = []
    seen = set()
    for e in db:
        f = e.get("file")
        if not f or f in seen:
            continue
        ext = os.path.splitext(f)[1]
        if ext not in C_EXTS and ext not in CXX_EXTS:
            continue
        if not firstparty(rel(f)):
            continue
        seen.add(f)
        cmd = e.get("command") or " ".join(e.get("arguments", []))
        units.append((f, extract_flags(cmd)))

    def analyze(unit):
        f, flags = unit
        inv = ["gcc", "-c", "-o", "/dev/null",
               "-fanalyzer", "-fdiagnostics-plain-output", "-fmax-errors=0"]
        inv += flags + [f]
        try:
            p = subprocess.run(inv, capture_output=True, text=True, timeout=180)
        except Exception:
            return (f, None, [])
        out = p.stderr + p.stdout
        hits = [ln for ln in out.splitlines() if "[-Wanalyzer-" in ln]
        return (f, True, hits)

    analyzed = 0
    failed = 0
    findings = 0
    report_path = os.path.join(output_dir, "report.txt")
    with open(report_path, "w") as report, \
         ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for f, ok, hits in pool.map(analyze, units):
            if ok is None:
                failed += 1
                continue
            analyzed += 1
            if hits:
                report.write("== " + rel(f) + " ==\n")
                report.write("\n".join(hits) + "\n")
                findings += len(hits)

    with open(os.path.join(output_dir, "count.txt"), "w") as fh:
        fh.write(str(findings) + "\n")
    with open(os.path.join(output_dir, "coverage.txt"), "w") as fh:
        fh.write(
            f"units={len(units)} analyzed={analyzed} failed={failed} "
            f"findings={findings}\n"
        )
    print(
        f"gcc-analyzer: {findings} findings across {analyzed} TUs "
        f"({failed} failed, {len(units)} first-party units)"
    )
  '';

  runner = pkgs.writeShellApplication {
    name = "run-gcc-analyzer";
    runtimeInputs = with pkgs; [ gcc python3 coreutils gnugrep ];
    text = ''
      compile_db="$1"
      source_dir="$2"
      output_dir="$3"

      echo "=== GCC -fanalyzer Analysis (DB-driven) ==="

      python3 ${driver} "$compile_db" "$source_dir" "$output_dir"

      echo "gcc-analyzer: $(cat "$output_dir/count.txt") findings"
    '';
  };
in
analysisLib.mkCompileDbReport "gcc-analyzer" runner compileDb
