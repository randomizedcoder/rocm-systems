# gcc-analyzer — GCC -fanalyzer interprocedural static analysis.
#
# Performs deep path-sensitive analysis at compile time.
# Detects null dereferences, use-after-free, double-free,
# buffer overflows, and infinite loops across function boundaries.
# Only works for projects with minimal external dependencies.
#
{ pkgs, lib, src, analysisLib }:

let
  runner = pkgs.writeShellApplication {
    name = "run-gcc-analyzer";
    runtimeInputs = with pkgs; [ cmake gcc gnumake coreutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== GCC -fanalyzer Analysis ==="

      total_findings=0

      # Try to build projects with -fanalyzer.
      # Only attempt projects known to have minimal deps.
      for project_dir in "$source_dir"/experimental/perf-dkms "$source_dir"/shared/kpack; do
        if [ ! -d "$project_dir" ]; then
          continue
        fi

        project_name=$(basename "$project_dir")
        echo "Building $project_name with -fanalyzer..."

        workdir=$(mktemp -d)
        cp -r "$project_dir" "$workdir/source"
        chmod -R u+w "$workdir/source"

        if cmake -B "$workdir/build" \
          -S "$workdir/source" \
          -DCMAKE_C_FLAGS="-fanalyzer -fdiagnostics-plain-output" \
          -DCMAKE_CXX_FLAGS="-fanalyzer -fdiagnostics-plain-output" \
          -DCMAKE_C_COMPILER=${pkgs.gcc}/bin/gcc \
          -DCMAKE_CXX_COMPILER=${pkgs.gcc}/bin/g++ \
          2>&1; then

          make -C "$workdir/build" -j"$(nproc)" 2>&1 | \
            grep -E '\[-Wanalyzer-' >> "$output_dir/report.txt" || true
        else
          echo "# Skipped $project_name (cmake configure failed)" >> "$output_dir/report.txt"
        fi

        rm -rf "$workdir"
      done

      findings=$(grep -c '\[-Wanalyzer-' "$output_dir/report.txt" 2>/dev/null || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "gcc-analyzer: $findings findings"
    '';
  };
in
analysisLib.mkBuildReport "gcc-analyzer" runner
