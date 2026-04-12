# clippy — Rust linting via cargo clippy.
#
# Scans Rust projects for common mistakes, style issues,
# and potential bugs.
#
{ pkgs, lib, src, analysisLib }:

let
  excludes = analysisLib.mkExcludeArgs analysisLib.defaultExcludes;

  runner = pkgs.writeShellApplication {
    name = "run-clippy";
    runtimeInputs = with pkgs; [ rustc cargo clippy coreutils findutils gnugrep ];
    text = ''
      source_dir="$1"
      output_dir="$2"

      echo "=== Rust Clippy Analysis ==="

      total_findings=0

      # Find Cargo.toml files to locate Rust projects
      find "$source_dir" \
        -name 'Cargo.toml' \
        ${excludes} \
        > "$output_dir/cargo-projects.txt" 2>/dev/null || true

      while IFS= read -r cargo_file; do
        project_dir=$(dirname "$cargo_file")
        project_name=$(basename "$project_dir")
        echo "Checking Rust project: $project_name"

        # Copy to writable dir (cargo needs to write)
        workdir=$(mktemp -d)
        cp -r "$project_dir" "$workdir/source"
        chmod -R u+w "$workdir/source"

        cd "$workdir/source"
        cargo clippy \
          --all-targets \
          --message-format=short \
          -- -W clippy::all -W clippy::pedantic \
          >> "$output_dir/report.txt" 2>&1 || true
        cd - > /dev/null
        rm -rf "$workdir"
      done < "$output_dir/cargo-projects.txt"

      findings=$(grep -c ': warning\[' "$output_dir/report.txt" 2>/dev/null || echo "0")
      echo "$findings" > "$output_dir/count.txt"

      echo "clippy: $findings findings"
    '';
  };
in
analysisLib.mkSourceReport "clippy" runner
