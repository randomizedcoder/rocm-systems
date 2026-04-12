# hip-check — HIP-specific pattern analysis.
#
# Uses semgrep with HIP-specific rules to detect:
# - Missing error checks on HIP API calls
# - Missing device synchronization
# - Stream lifecycle issues
# - Unchecked memory allocations
# - Kernel launch configuration issues
#
{ pkgs, lib, src, analysisLib }:

let
  hipRulesFile = ../rules/semgrep-hip.yaml;

  runner = pkgs.writeShellApplication {
    name = "run-hip-check";
    runtimeInputs = with pkgs; [ semgrep coreutils gnugrep cacert ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== HIP-specific Analysis ==="

      export SEMGREP_ENABLE_VERSION_CHECK=0
      export SEMGREP_SEND_METRICS=off
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export OTEL_TRACES_EXPORTER=none
      HOME="$(mktemp -d)"
      export HOME

      # Run HIP-focused semgrep rules on HIP and CUDA files
      semgrep \
        --config "${hipRulesFile}" \
        --json \
        --no-git-ignore \
        --exclude='third_party' \
        --exclude='build' \
        --include='*.hip' --include='*.cu' --include='*.cuh' \
        --include='*.cpp' --include='*.cc' --include='*.h' --include='*.hpp' \
        "$source_dir" \
        > "$output_dir/report.json" 2>"$output_dir/semgrep-stderr.log" || true

      # Human-readable
      semgrep \
        --config "${hipRulesFile}" \
        --no-git-ignore \
        --exclude='third_party' \
        --exclude='build' \
        --include='*.hip' --include='*.cu' --include='*.cuh' \
        --include='*.cpp' --include='*.cc' --include='*.h' --include='*.hpp' \
        "$source_dir" \
        > "$output_dir/report.txt" 2>>"$output_dir/semgrep-stderr.log" || true

      findings=$(grep -c '"check_id"' "$output_dir/report.json" || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "hip-check: $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "hip-check" runner
