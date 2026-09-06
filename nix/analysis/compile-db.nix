# Generate compile_commands.json for the rocm-systems repo.
#
# Strategy:
#   1. For each project, attempt cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
#   2. Projects that fail cmake configure get a synthetic fallback
#   3. All per-project databases are merged into one
#
# The synthetic fallback generates minimal compile_commands.json entries
# that are sufficient for clang-tidy, cppcheck, and iwyu to parse most code
# without full dependency resolution.
#
{ pkgs, lib, src, projects }:

let
  # Common third-party dev headers many ROCm subprojects need. Provisioning
  # these (a) lets dep-light projects actually cmake-configure and (b) raises
  # synthetic-DB parse coverage so the path-sensitive analyzers see real code
  # instead of dying on a missing include.
  commonDeps = with pkgs; [
    libmnl msgpack-cxx zstd numactl libdrm boost gtest
    elfutils pciutils ncurses openssl
  ];

  # -isystem flags for the provisioned deps, injected into every synthetic
  # entry so clang/gcc resolve their headers without a full SDK.
  depIncludeFlags =
    lib.concatMapStringsSep " " (d: "-isystem ${lib.getDev d}/include") commonDeps;

  # In-tree HIP platform includes + libdrm subdirs (best-effort; nonexistent
  # -I dirs are harmless).
  hipIncludeFlags = lib.concatStringsSep " " [
    "-I${src}/projects/clr/hipamd/include"
    "-I${src}/projects/clr/rocclr/include"
    "-I${src}/projects/clr/hipamd/include/hip"
    "-isystem ${lib.getDev pkgs.libdrm}/include/libdrm"
    "-isystem ${lib.getDev pkgs.libdrm}/include/drm"
  ];

  # HIP compiles behind the AMD platform macros; -ferror-limit=0 lets clang keep
  # analysing past still-unresolved *external* headers instead of bailing at the
  # first fatal. (gcc-analyzer strips clang-only -f flags when it re-drives.)
  extraSyntheticFlags =
    "-D__HIP_PLATFORM_AMD__=1 -D__HIP_PLATFORM_HCC__=1 -ferror-limit=0 "
    + "${depIncludeFlags} ${hipIncludeFlags}";

  # Python script to generate a synthetic compile_commands.json
  # for projects where cmake configure fails (missing ROCm deps, etc.).
  syntheticDbScript = pkgs.writeText "synthetic-compile-db.py" ''
    """Generate synthetic compile_commands.json from source file discovery."""
    import json
    import os
    import sys

    source_dir = sys.argv[1]
    output_file = sys.argv[2]
    cpp_standard = sys.argv[3] if len(sys.argv) > 3 else "c++17"
    extra_flags = sys.argv[4] if len(sys.argv) > 4 else ""

    extensions = {
        '.c': 'c',
        '.cc': 'c++',
        '.cpp': 'c++',
        '.cxx': 'c++',
        '.hip': 'hip',
        '.cu': 'cuda',
    }
    header_exts = ('.h', '.hh', '.hpp', '.hxx', '.inc', '.cuh', '.ipp', '.tcc')

    # Directories to skip
    skip_dirs = {'build', '_build', 'third_party', '.git', '__pycache__'}

    # Single walk: collect every directory that holds a header (for -I
    # resolution of the file's own siblings/project headers) and every source
    # file to emit an entry for.
    header_dirs = set()
    source_files = []
    for root, dirs, files in os.walk(source_dir):
        # Prune excluded directories
        dirs[:] = [d for d in dirs if d not in skip_dirs]

        for f in files:
            _, ext = os.path.splitext(f)
            if ext in header_exts:
                header_dirs.add(root)
            if ext in extensions:
                source_files.append((root, f, ext))

    proj_includes = ' '.join(f'-I{d}' for d in sorted(header_dirs))
    base_includes = f'-I{source_dir} -I{source_dir}/include -I{source_dir}/src'

    entries = []
    for root, f, ext in source_files:
        filepath = os.path.join(root, f)
        lang = extensions[ext]

        if lang == 'c':
            std_flag = '-std=c11'
            lang_flag = '-x c'
        elif lang == 'hip':
            std_flag = f'-std={cpp_standard}'
            lang_flag = '-x hip'
        elif lang == 'cuda':
            std_flag = f'-std={cpp_standard}'
            lang_flag = '-x cuda'
        else:
            std_flag = f'-std={cpp_standard}'
            lang_flag = '-x c++'

        command = (
            f'clang++ {lang_flag} {std_flag} '
            f'{base_includes} {proj_includes} {extra_flags} -c {filepath}'
        )
        entries.append({
            'directory': source_dir,
            'file': filepath,
            'command': command,
        })

    with open(output_file, 'w') as fh:
        json.dump(entries, fh, indent=2)

    print(
        f"Generated synthetic compile_commands.json with {len(entries)} entries "
        f"({len(header_dirs)} include dirs)"
    )
  '';

  # Python script to merge multiple compile_commands.json files.
  mergeDbScript = pkgs.writeText "merge-compile-dbs.py" ''
    """Merge multiple compile_commands.json files, deduplicating by file path."""
    import json
    import os
    import sys

    output_file = sys.argv[1]
    input_files = sys.argv[2:]

    seen_files = set()
    merged = []

    for input_file in input_files:
        if not os.path.exists(input_file):
            continue
        with open(input_file) as f:
            try:
                db = json.load(f)
            except json.JSONDecodeError:
                print(f"WARNING: Skipping malformed {input_file}")
                continue

        for entry in db:
            fpath = entry.get('file', ''')
            if fpath not in seen_files:
                seen_files.add(fpath)
                merged.append(entry)

    with open(output_file, 'w') as f:
        json.dump(merged, f, indent=2)

    print(f"Merged {len(merged)} entries from {len(input_files)} databases")
  '';

  # Generate compile_commands.json for a single project.
  # Falls back to synthetic generation if cmake configure fails.
  mkProjectCompileDb = project:
    pkgs.runCommand "compile-db-${project.name}" {
      nativeBuildInputs = (with pkgs; [ cmake python3 gnumake pkg-config ]) ++ commonDeps;
    } ''
      mkdir -p $out

      echo "=== Generating compile_commands.json for ${project.name} ==="

      # Copy source to writable directory (cmake needs to write)
      cp -r ${project.path} source
      chmod -R u+w source

      # Attempt cmake configure
      if cmake -B source/build \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCMAKE_C_COMPILER=${pkgs.gcc}/bin/gcc \
        -DCMAKE_CXX_COMPILER=${pkgs.gcc}/bin/g++ \
        -S source 2>&1 | tee configure.log; then

        if [ -f source/build/compile_commands.json ]; then
          cp source/build/compile_commands.json $out/compile_commands.json
          echo "cmake" > $out/method.txt
          echo "Generated compile_commands.json via cmake for ${project.name}"
        else
          echo "cmake configured but no compile_commands.json found, using synthetic"
          ${pkgs.python3}/bin/python3 ${syntheticDbScript} \
            ${project.path} $out/compile_commands.json c++17 "${extraSyntheticFlags}"
          echo "synthetic" > $out/method.txt
        fi
      else
        echo "cmake configure failed, using synthetic compile_commands.json"
        ${pkgs.python3}/bin/python3 ${syntheticDbScript} \
          ${project.path} $out/compile_commands.json c++17 "${extraSyntheticFlags}"
        echo "synthetic" > $out/method.txt
      fi
    '';

  # Per-project compile databases.
  projectDbs = builtins.listToAttrs (
    map (p: {
      name = p.name;
      value = mkProjectCompileDb p;
    }) projects.all
  );

  # Merged compile database covering all projects.
  mergedDb = pkgs.runCommand "compile-db-merged" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir -p $out

    ${pkgs.python3}/bin/python3 ${mergeDbScript} \
      $out/compile_commands.json \
      ${lib.concatMapStringsSep " \\\n      "
        (p: "${projectDbs.${p.name}}/compile_commands.json")
        projects.all}
  '';

in
{
  # Individual project compile databases.
  inherit projectDbs;

  # Merged compile database for whole-repo analysis.
  inherit mergedDb;

  # For use in tool derivations.
  inherit mkProjectCompileDb;
}
