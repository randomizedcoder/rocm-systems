# Auto-discover projects from the repo directory structure.
#
# Returns an attrset of { name = { path, type, languages }; ... }
# for each project found under projects/, experimental/, shared/.
#
{ lib, src }:

let
  # Safely read a directory, returning {} if it doesn't exist.
  safeReadDir = path:
    if builtins.pathExists path
    then builtins.readDir path
    else {};

  # Get subdirectory names from a path.
  subdirs = path:
    lib.attrNames (
      lib.filterAttrs (_: type: type == "directory") (safeReadDir path)
    );

  # Build project metadata for a given base directory and project name.
  mkProject = baseDir: type: name: {
    inherit name type;
    path = src + "/${baseDir}/${name}";
    relPath = "${baseDir}/${name}";
  };

  projects = map (mkProject "projects" "project") (subdirs (src + "/projects"));
  experimental = map (mkProject "experimental" "experimental") (subdirs (src + "/experimental"));
  shared = map (mkProject "shared" "shared") (subdirs (src + "/shared"));

  allProjects = projects ++ experimental ++ shared;

  # Exclude known non-code or externally-managed directories.
  excluded = [
    "amdgpu-windows-interop"  # External source of truth
  ];

  filtered = builtins.filter (p: !builtins.elem p.name excluded) allProjects;
in
{
  # List of all project records.
  all = filtered;

  # Attrset keyed by project name for easy lookup.
  byName = builtins.listToAttrs (
    map (p: { name = p.name; value = p; }) filtered
  );

  # Just the project names.
  names = map (p: p.name) filtered;

  # Projects grouped by type.
  byType = {
    project = builtins.filter (p: p.type == "project") filtered;
    experimental = builtins.filter (p: p.type == "experimental") filtered;
    shared = builtins.filter (p: p.type == "shared") filtered;
  };
}
