# a plain numeric or another type aborts

    Code
      h3_as_int64(1.5)
    Condition
      Error:
      ! `1.5` must hold H3 cells as hex strings, <integer64> or <H3>, not a number.
      i A plain number cannot hold an H3 cell: it would be rounded to another cell.

# strings and integers that are not cells abort

    Code
      h3_as_hex(c("8928308280fffff", "8928308280ffff0"))
    Condition
      Error:
      ! `c("8928308280fffff", "8928308280ffff0")` holds 1 value that is not a valid H3 cell.
      x First: "8928308280ffff0".

