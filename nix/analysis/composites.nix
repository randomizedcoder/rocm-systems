# Composite analysis targets: quick, standard, deep.
#
# Each tier includes progressively more tools, trading speed for coverage.
#
{ pkgs, lib, tools, extras ? { } }:

let
  # All tool names — used by deep and all targets
  allTools = lib.attrNames tools;

  # Helper to create a composite target that links to a set of report
  # derivations (an attrset of name -> derivation) and prints a summary.
  mkComposite = name: description: drvs:
    pkgs.runCommand "analysis-${name}" { } (
      let
        drvNames = lib.attrNames drvs;

        linkCommands = lib.concatMapStringsSep "\n" (t:
          "ln -s ${drvs.${t}} $out/${t}"
        ) drvNames;

        summaryLines = lib.concatMapStringsSep "\n" (t:
          ''echo "${t}: $(cat ${drvs.${t}}/count.txt 2>/dev/null || echo 'N/A') findings"''
        ) drvNames;
      in
      ''
        mkdir -p $out

        ${linkCommands}

        {
          echo "=== Analysis Summary (${name}) ==="
          echo "${description}"
          echo ""
          ${summaryLines}
          echo ""
          echo "Reports in: $out/<tool>/report.txt"
        } > $out/summary.txt

        cat $out/summary.txt
      ''
    );

  # Select a subset of tools by name into a name -> derivation attrset.
  pick = names: lib.getAttrs names tools;

in
{
  # Quick: source-only tools, no compilation needed (~2-5 min)
  quick = mkComposite "quick"
    "Fast checks for pre-commit and immediate feedback."
    (pick [
      "flawfinder"
      "cpplint"
      "ruff"
      "shellcheck"
      "yamllint"
      "cmake-lint"
      "fortran-lint"
    ]);

  # Standard: quick + compile-db tools (~10-20 min)
  standard = mkComposite "standard"
    "Comprehensive analysis balanced with runtime."
    (pick [
      # Quick tools
      "flawfinder"
      "cpplint"
      "ruff"
      "shellcheck"
      "yamllint"
      "cmake-lint"
      "fortran-lint"
      # Compile-db tools
      "clang-tidy"
      "cppcheck"
      # Python tools
      "bandit"
      "pylint"
      # Rust
      "clippy"
    ]);

  # Deep: all tools + fuzzing (~30-60 min)
  deep = mkComposite "deep"
    "Exhaustive analysis including interprocedural, pattern-based, and fuzz tools."
    (tools // extras);

  # All: explicit alias for deep — every tool plus fuzzing, no exceptions
  all = mkComposite "all"
    "Every analysis tool (${toString (lib.length allTools)} tools) plus fuzzing."
    (tools // extras);
}
