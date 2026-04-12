# semgrep-case-coverage — detect incomplete type/enum dispatch patterns.
#
# Catches the "missing case" bug class: code that dispatches on a
# type/kind/mode discriminator but doesn't cover all valid values.
# This is the pattern that led to the doorbell type 1 handling bug
# going undetected.
#
# Rules cover: switch without default, if-else without catch-all,
# numeric dispatch gaps, ternary on discriminators, GPU generation
# dispatch without fallback.
#
{ pkgs, lib, src, analysisLib }:

let
  excludes = analysisLib.mkExcludeArgs analysisLib.defaultExcludes;

  rulesFile = ../rules/semgrep-case-coverage.yaml;

  runner = pkgs.writeShellApplication {
    name = "run-semgrep-case-coverage";
    runtimeInputs = with pkgs; [ semgrep coreutils gnugrep cacert ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== semgrep (Case Coverage) Analysis ==="

      export SEMGREP_ENABLE_VERSION_CHECK=0
      export SEMGREP_SEND_METRICS=off
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export OTEL_TRACES_EXPORTER=none
      HOME="$(mktemp -d)"
      export HOME

      # Run with case-coverage rules
      semgrep \
        --config "${rulesFile}" \
        --json \
        --no-git-ignore \
        --exclude='third_party' \
        --exclude='build' \
        --exclude='_build' \
        --exclude='shared/amdgpu-windows-interop' \
        --include='*.c' --include='*.cc' --include='*.cpp' --include='*.cxx' \
        --include='*.h' --include='*.hh' --include='*.hpp' --include='*.hxx' \
        --include='*.hip' --include='*.cu' --include='*.cuh' --include='*.cl' \
        "$source_dir" \
        > "$output_dir/report.json" 2>"$output_dir/semgrep-stderr.log" || true

      # Human-readable report
      semgrep \
        --config "${rulesFile}" \
        --no-git-ignore \
        --exclude='third_party' \
        --exclude='build' \
        --exclude='_build' \
        --exclude='shared/amdgpu-windows-interop' \
        --include='*.c' --include='*.cc' --include='*.cpp' --include='*.cxx' \
        --include='*.h' --include='*.hh' --include='*.hpp' --include='*.hxx' \
        --include='*.hip' --include='*.cu' --include='*.cuh' --include='*.cl' \
        "$source_dir" \
        > "$output_dir/report.txt" 2>>"$output_dir/semgrep-stderr.log" || true

      findings=$(grep -c '"check_id"' "$output_dir/report.json" || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "semgrep (case-coverage): $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "semgrep-case-coverage" runner
