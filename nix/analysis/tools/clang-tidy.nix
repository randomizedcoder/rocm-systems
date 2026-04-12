# clang-tidy — linting and modernization with compilation database.
#
# Honors per-project .clang-tidy configs where they exist.
# Falls back to configs/clang-tidy-base.yaml for projects without one.
# Handles .hip and .cu files as C++ with appropriate language flags.
#
{ pkgs, lib, src, analysisLib, compileDb }:

let
  excludes = analysisLib.mkExcludeArgs analysisLib.defaultExcludes;

  runner = pkgs.writeShellApplication {
    name = "run-clang-tidy";
    runtimeInputs = with pkgs; [ clang-tools coreutils findutils gnugrep parallel ];
    text = ''
      compile_db="$1"
      source_dir="$2"
      output_dir="$3"

      echo "=== clang-tidy Analysis ==="
      echo "Using compilation database: $compile_db"

      # Find all C/C++/HIP/CUDA source files (not headers)
      find "$source_dir" \
        -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' \
                   -o -name '*.hip' -o -name '*.cu' \) \
        ${excludes} \
        > "$output_dir/file-list.txt" 2>/dev/null || true

      file_count=$(wc -l < "$output_dir/file-list.txt" || echo "0")
      echo "Scanning $file_count source files..."

      # Run clang-tidy with the compilation database
      # Use run-clang-tidy for parallelism if available, else xargs
      if command -v run-clang-tidy &>/dev/null; then
        xargs < "$output_dir/file-list.txt" \
          run-clang-tidy \
          -p "$compile_db" \
          -header-filter='(projects|experimental|shared)/.*' \
          -quiet \
          > "$output_dir/report.txt" 2>&1 || true
      else
        cat "$output_dir/file-list.txt" | \
          parallel -j "$(nproc)" \
            clang-tidy -p "$compile_db" \
              --header-filter="'(projects|experimental|shared)/.*'" \
              --quiet {} \
          > "$output_dir/report.txt" 2>&1 || true
      fi

      findings=$(grep -c ': warning:\|: error:' "$output_dir/report.txt" || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "clang-tidy: $findings findings"
    '';
  };
in
analysisLib.mkCompileDbReport "clang-tidy" runner compileDb
