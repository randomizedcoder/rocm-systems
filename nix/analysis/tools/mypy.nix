# mypy — Python type checking.
#
# Runs with --ignore-missing-imports since many dependencies
# (ROCm packages, etc.) are not available in the nix sandbox.
#
{ pkgs, lib, src, analysisLib }:

let
  runner = pkgs.writeShellApplication {
    name = "run-mypy";
    runtimeInputs = with pkgs; [ mypy coreutils findutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== mypy Analysis ==="

      # Find Python files
      find "$source_dir" \
        -type f -name '*.py' \
        -not -path '*/third_party/*' \
        -not -path '*/build/*' \
        -not -path '*/_build/*' \
        -not -path '*/.git/*' \
        -not -path '*/shared/amdgpu-windows-interop/*' \
        > "$output_dir/file-list.txt" 2>/dev/null || true

      file_count=$(wc -l < "$output_dir/file-list.txt" || echo "0")
      echo "Type-checking $file_count Python files..."

      xargs < "$output_dir/file-list.txt" \
        mypy \
        --ignore-missing-imports \
        --no-error-summary \
        --show-column-numbers \
        --no-color-output \
        > "$output_dir/report.txt" 2>&1 || true

      findings=$(grep -c ': error:' "$output_dir/report.txt" || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "mypy: $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "mypy" runner
