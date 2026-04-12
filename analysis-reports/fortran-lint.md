# Fortran Lint Analysis Report

**Tool**: gfortran -Wall -Wextra -Wpedantic -fcheck=all
**Total Findings**: 0 (all files failed to compile)
**Scope**: 19 Fortran files in projects/rocprofiler-systems/examples/hpc/

---

## Executive Summary

All 19 Fortran files failed to compile because they depend on module files (`kind_mod.mod`, etc.) that are only generated during the full build process. gfortran cannot analyze these files standalone.

## Files Affected

All files are in `projects/rocprofiler-systems/examples/hpc/`:

- `jacobi-fortran-targetdata-markers/input.f90`
- `jacobi-fortran-targetdata-markers/jacobi.f90`
- `jacobi-fortran-targetdata-markers/boundary.f90`
- `jacobi-fortran-targetdata-markers/norm.f90`
- Similar patterns in other jacobi-* subdirectories

## Error Pattern

```
Fatal Error: Cannot open module file 'kind_mod.mod' for reading at (1): No such file or directory
```

All files `use kind_mod` which provides type definitions. The `.mod` file is a compiler-generated binary that doesn't exist until the module source is compiled first.

## Recommendation

1. **Short-term**: Skip Fortran linting (only 19 files, all in examples/)
2. **Medium-term**: Build the module files first, then run gfortran with `-fsyntax-only` for checking
3. **Long-term**: Integrate Fortran checking into the build system (CMake custom target)

## Priority: VERY LOW

These are HPC example programs (Jacobi iterative solver demonstrations for profiler testing). They are not production runtime code.

## Estimated False Positive Rate: N/A (no analysis performed)
