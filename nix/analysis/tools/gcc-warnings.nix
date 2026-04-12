# gcc-warnings — extended compiler warning flags.
#
# Builds projects with aggressive -W flags to catch issues that
# the default build misses. Requires full CMake build capability.
# Only works for projects with minimal external dependencies.
#
{ pkgs, lib, src, analysisLib }:

let
  warningFlags = lib.concatStringsSep " " analysisLib.gccWarningFlags;

  runner = pkgs.writeShellApplication {
    name = "run-gcc-warnings";
    runtimeInputs = with pkgs; [ cmake gcc gnumake coreutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== GCC Extended Warnings Analysis ==="

      total_findings=0

      # Try to build each project with extended warnings.
      # Projects that fail cmake configure are skipped.
      for project_dir in "$source_dir"/experimental/perf-dkms "$source_dir"/shared/kpack; do
        if [ ! -d "$project_dir" ]; then
          continue
        fi

        project_name=$(basename "$project_dir")
        echo "Building $project_name with extended warnings..."

        workdir=$(mktemp -d)
        cp -r "$project_dir" "$workdir/source"
        chmod -R u+w "$workdir/source"

        if cmake -B "$workdir/build" \
          -S "$workdir/source" \
          -DCMAKE_C_FLAGS="${warningFlags}" \
          -DCMAKE_CXX_FLAGS="${warningFlags}" \
          -DCMAKE_C_COMPILER=${pkgs.gcc}/bin/gcc \
          -DCMAKE_CXX_COMPILER=${pkgs.gcc}/bin/g++ \
          2>&1; then

          make -C "$workdir/build" -j"$(nproc)" 2>&1 | \
            grep -E ': warning:|: error:' >> "$output_dir/report.txt" || true
        else
          echo "# Skipped $project_name (cmake configure failed)" >> "$output_dir/report.txt"
        fi

        rm -rf "$workdir"
      done

      findings=$(grep -c ': warning:\|: error:' "$output_dir/report.txt" 2>/dev/null || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "gcc-warnings: $findings findings"
    '';
  };
in
analysisLib.mkBuildReport "gcc-warnings" runner
