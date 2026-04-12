// Detect switch statements without a default case.
//
// Missing default cases are the primary vector for "incomplete dispatch" bugs
// where new enum values are silently ignored. This catches the pattern that
// led to the doorbell type 1 handling bug.
//
// Note: -Wswitch-enum catches missing *named* enum values but NOT the absence
// of a default case when the switch is on an int or when new values might be
// added to the enum in the future.
@@
expression E;
statement S;
@@

* switch (E) {
    ...
-   // no default case
  }
