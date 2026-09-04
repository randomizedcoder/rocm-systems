# libFuzzer harnesses for the hardened untrusted-input parsers.
#
# Two derivations:
#   fuzz       build the fuzzer binaries + seed corpora + a run-fuzzers wrapper
#              (does not run them)
#   fuzz-run   build, then run each harness for a bounded time, saving any crash
#              inputs and a symbolized reproduction (always exits 0 — the crashes
#              are the deliverable, not a build failure)
#
# Harnesses target the header-only container-ID parser
# (projects/amdsmi/include/amd_smi/impl/amd_smi_container_id_parser.h), which is
# self-contained and so compiles standalone with no GPU/ROCm dependency. Other
# parser sites (the sscanf calls in amd_smi.cc / fdinfo.cc) are inline in large
# translation units and need a production refactor to fuzz faithfully; see
# nix/analysis/fuzz/README.md.
#
{ pkgs, lib, src, analysisLib }:

let
  # C++17 header, so the harnesses are C++ and built with clang++.
  sanFlags = "-std=c++17 -fsanitize=fuzzer,address,undefined -g -O1 -fno-omit-frame-pointer";

  includeFlags = lib.concatStringsSep " " [
    "-Iprojects/amdsmi/include"  # amd_smi/impl/amd_smi_container_id_parser.h
    "-Inix/analysis/fuzz"        # fuzz_guard.h
  ];

  symbolizer = "${lib.getBin pkgs.llvm}/bin/llvm-symbolizer";

  # Harness base names -> the .cpp under nix/analysis/fuzz/. Each is header-only
  # against the production parser, so there are no extra TUs to link.
  names = [ "container_id" "oci_container_id" "resolve_container_id" ];

  # A realistic and a degenerate seed per harness so each corpus starts useful.
  oci64 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
  seedLines = {
    container_id = [ "0::/docker/abcdef0123456789" "0::/lxc/my-container_01" "" ];
    oci_container_id = [ "0::/system.slice/docker-${oci64}.scope" "12:cpuset:/kubepods/pod0/${oci64}" "" ];
    resolve_container_id = [ "0::/docker/abcdef0123456789\n1:name=systemd:/lxc/box" "0::/system.slice/docker-${oci64}.scope" "" ];
  };

  writeSeeds = name: lib.concatImapStringsSep "\n"
    (i: line: ''printf '%s' ${lib.escapeShellArg line} > "out/corpus/${name}/seed${toString i}"'')
    (seedLines.${name});

  compileLines = lib.concatMapStringsSep "\n" (name: ''
    echo "Building fuzz_${name}..."
    clang++ ${sanFlags} ${includeFlags} \
      "nix/analysis/fuzz/fuzz_${name}.cpp" \
      -o "out/bin/fuzz_${name}"
    mkdir -p "out/corpus/${name}"
    ${writeSeeds name}
  '') names;

  # Shellcheck-clean, self-contained runner. Runs each harness for FUZZ_TIME
  # seconds (default 60), never failing on a crash — the caller inspects the
  # workdir. Kept parallel-free so per-harness logs stay readable.
  runFuzzers = pkgs.writeShellApplication {
    name = "run-fuzzers";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    bashOptions = [ "nounset" ];
    text = ''
      root="$(cd "$(dirname "$0")/.." && pwd)"
      time="''${FUZZ_TIME:-60}"
      workdir="''${FUZZ_WORKDIR:-$(mktemp -d)}"
      export ASAN_SYMBOLIZER_PATH="${symbolizer}"
      export UBSAN_SYMBOLIZER_PATH="${symbolizer}"
      export ASAN_OPTIONS="abort_on_error=0:detect_leaks=0:symbolize=1"
      export UBSAN_OPTIONS="print_stacktrace=1:symbolize=1"

      echo "Fuzzing for ''${time}s each; workdir=$workdir"
      for name in ${lib.concatStringsSep " " names}; do
        echo "=== fuzz_$name ==="
        mkdir -p "$workdir/$name"
        cp "$root/corpus/$name"/* "$workdir/$name/" 2>/dev/null || true
        "$root/bin/fuzz_$name" \
          -max_total_time="$time" \
          -artifact_prefix="$workdir/$name/" \
          "$workdir/$name" \
          > "$workdir/$name.log" 2>&1 || true
        crashes=$(find "$workdir/$name" -name 'crash-*' 2>/dev/null | wc -l)
        echo "  crashes: $crashes (log: $workdir/$name.log)"
      done
      echo "$workdir"
    '';
  };

  fuzz = pkgs.stdenv.mkDerivation {
    pname = "rocm-systems-fuzzers";
    version = "1.0";
    inherit src;

    nativeBuildInputs = [ pkgs.clang ];
    # -fsanitize=address/fuzzer inject their own hardening; the cc-wrapper's
    # FORTIFY at -O1 collides, so disable wrapper hardening for these harnesses.
    hardeningDisable = [ "all" ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p out/bin out/corpus
      ${compileLines}
      install -m755 ${lib.getExe runFuzzers} out/bin/run-fuzzers
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      cp -r out/* $out/
    '';

    dontFixup = true;
  };

  # Bounded run: exercise every harness briefly, collect crashes + a symbolized
  # reproduction for each, and summarise. Always succeeds.
  runSeconds = 20;

  fuzz-run = pkgs.stdenv.mkDerivation {
    pname = "rocm-systems-fuzz-run";
    version = "1.0";
    dontUnpack = true;
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      export FUZZ_TIME=${toString runSeconds}
      export FUZZ_WORKDIR="$PWD/work"
      mkdir -p "$FUZZ_WORKDIR"
      ${fuzz}/bin/run-fuzzers || true
      runHook postBuild
    '';

    installPhase = ''
      mkdir -p $out
      work="$PWD/work"

      total=0
      {
        echo "=== Fuzzing summary (${toString runSeconds}s per harness) ==="
        echo ""
        for name in ${lib.concatStringsSep " " names}; do
          n=$(find "$work/$name" -name 'crash-*' 2>/dev/null | wc -l)
          total=$((total + n))
          printf '  %-24s %s crash input(s)\n' "$name:" "$n"

          if [ -f "$work/$name.log" ]; then
            cp "$work/$name.log" "$out/$name.log"
          fi

          first_crash=$(find "$work/$name" -name 'crash-*' 2>/dev/null | head -1)
          if [ -n "$first_crash" ]; then
            mkdir -p "$out/crashes/$name"
            cp "$work/$name"/crash-* "$out/crashes/$name/" 2>/dev/null || true
            ASAN_SYMBOLIZER_PATH="${symbolizer}" \
            ASAN_OPTIONS="symbolize=1:detect_leaks=0:abort_on_error=0" \
              ${fuzz}/bin/fuzz_$name "$first_crash" \
              > "$out/crashes/$name/repro.txt" 2>&1 || true
          fi
        done
        echo ""
        echo "Total crash inputs: $total"
        echo ""
        echo "Crash inputs + symbolized repros under crashes/<harness>/."
        echo "Full logs: <harness>.log."
      } > $out/summary.txt

      echo "$total" > $out/count.txt
      cat $out/summary.txt
    '';

    dontFixup = true;
  };
in
{
  inherit fuzz fuzz-run;
}
