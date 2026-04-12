# fortran-lint — Fortran analysis via gfortran extended warnings.
#
# Scans .f90/.F90 files with strict warning flags to catch:
# - Implicit typing
# - Unused variables
# - Argument mismatches
# - Array bounds issues
#
{ pkgs, lib, src, analysisLib }:

let
  excludes = analysisLib.mkExcludeArgs analysisLib.defaultExcludes;

  runner = pkgs.writeShellApplication {
    name = "run-fortran-lint";
    runtimeInputs = with pkgs; [ gfortran coreutils findutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== Fortran Lint Analysis ==="

      # Find all Fortran files
      find "$source_dir" \
        -type f \( -name '*.f90' -o -name '*.F90' -o -name '*.f95' -o -name '*.f' \) \
        ${excludes} \
        > "$output_dir/file-list.txt" 2>/dev/null || true

      file_count=$(wc -l < "$output_dir/file-list.txt" || echo "0")
      echo "Scanning $file_count Fortran files..."

      # Syntax-check each file with aggressive warnings
      while IFS= read -r f; do
        gfortran \
          -fsyntax-only \
          -Wall -Wextra -Wpedantic \
          -Wimplicit-interface \
          -Wimplicit-procedure \
          -Wunused \
          -fcheck=all \
          "$f" 2>&1 || true
      done < "$output_dir/file-list.txt" > "$output_dir/report.txt" 2>&1

      findings=$(grep -c ': Warning:\|: Error:' "$output_dir/report.txt" || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "fortran-lint: $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "fortran-lint" runner
