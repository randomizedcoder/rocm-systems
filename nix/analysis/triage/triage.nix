# Nix derivation wrapping the Python triage engine.
#
# Takes raw tool output directories and produces triaged reports
# with anomaly matching against .analysis/anomalies.toml.
#
{ pkgs, lib, src }:

let
  triageDir = ./.;

  # Package the triage Python code
  triagePkg = pkgs.stdenv.mkDerivation {
    pname = "analysis-triage";
    version = "0.1.0";
    src = triageDir;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/lib/triage
      cp -r *.py $out/lib/triage/
      cp -r parsers $out/lib/triage/
    '';
  };

in
{
  # Run triage on a result directory.
  # Usage: mkTriagedReport "tool-name" rawReportDerivation
  mkTriagedReport = toolName: rawReport:
    pkgs.runCommand "analysis-${toolName}-triaged" {
      nativeBuildInputs = [ pkgs.python3 ];
    } ''
      mkdir -p $out

      export PYTHONPATH="${triagePkg}/lib/triage"

      python3 -m triage \
        --source-root ${src} \
        --anomalies-file ${src}/.analysis/anomalies.toml \
        --output-dir $out \
        ${rawReport}
    '';

  # Run triage on a composite result directory (all tools).
  mkCompositeTriagedReport = resultDir:
    pkgs.runCommand "analysis-triaged" {
      nativeBuildInputs = [ pkgs.python3 ];
    } ''
      mkdir -p $out

      export PYTHONPATH="${triagePkg}/lib/triage"

      python3 -m triage \
        --source-root ${src} \
        --anomalies-file ${src}/.analysis/anomalies.toml \
        --output-dir $out \
        ${resultDir}
    '';

  # Export the package for use in dev shell
  package = triagePkg;
}
