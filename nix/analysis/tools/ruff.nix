# ruff — fast Python linting and formatting checks.
#
# Covers: pyflakes, pycodestyle, isort, pep8-naming, flake8-bugbear,
# flake8-comprehensions, and many more rule sets.
#
{ pkgs, lib, src, analysisLib }:

let
  excludes = analysisLib.mkExcludeArgs analysisLib.defaultExcludes;

  runner = pkgs.writeShellApplication {
    name = "run-ruff";
    runtimeInputs = with pkgs; [ ruff coreutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== ruff Analysis ==="

      # Run ruff with a broad selection of rules
      # --no-cache because nix store is read-only
      ruff check \
        --no-cache \
        --select=E,W,F,B,C4,C90,I,N,S,T20,UP,YTT,ANN,ASYNC,BLE,FBT,A,COM,DTZ,EM,EXE,ISC,ICN,LOG,G,INP,PIE,PYI,PT,Q,RSE,RET,SLF,SLOT,SIM,TID,TCH,INT,ARG,PTH,TD,FIX,ERA,PD,PGH,PL,TRY,FLY,NPY,PERF,FURB,RUF \
        --ignore=ANN401,E501,COM812,ISC001 \
        --output-format=concise \
        --exclude='third_party,build,_build,shared/amdgpu-windows-interop' \
        "$source_dir" \
        > "$output_dir/report.txt" 2>&1 || true

      # JSON output for triage system
      ruff check \
        --no-cache \
        --select=E,W,F,B,C4,C90,I,N,S,T20,UP,YTT,ANN,ASYNC,BLE,FBT,A,COM,DTZ,EM,EXE,ISC,ICN,LOG,G,INP,PIE,PYI,PT,Q,RSE,RET,SLF,SLOT,SIM,TID,TCH,INT,ARG,PTH,TD,FIX,ERA,PD,PGH,PL,TRY,FLY,NPY,PERF,FURB,RUF \
        --ignore=ANN401,E501,COM812,ISC001 \
        --output-format=json \
        --exclude='third_party,build,_build,shared/amdgpu-windows-interop' \
        "$source_dir" \
        > "$output_dir/report.json" 2>&1 || true

      findings=$(wc -l < "$output_dir/report.txt" 2>/dev/null || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "ruff: $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "ruff" runner
