// Detect bitfield structs that may need more thorough test coverage.
// Flags struct definitions containing bitfield members with small widths (1-4 bits)
// to highlight areas where combinatorial testing may be needed.
@@
identifier S;
type T;
identifier F;
constant C;
@@

  struct S {
    ...
*   T F : C;
    ...
  };
