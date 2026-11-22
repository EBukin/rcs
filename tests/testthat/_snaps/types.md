# values outside the levels become NA with one warning per column

    Code
      got <- store_restore_types(raw, s$st, "t/sales")
    Condition
      Warning:
      Column product: 2 values outside the recorded levels became "NA".
      Warning:
      Column grade: 1 value outside the recorded levels became "NA".

# integer64 from double: whole values below 2^53 only

    Code
      got <- store_restore_types(raw, s$st, "t/sales")
    Condition
      Warning:
      Column big not converted to <integer64>.
      i 1 value is not whole or not below 2^53.

---

    Code
      got <- store_restore_types(raw, s$st, "t/sales")
    Condition
      Warning:
      Column big not converted to <integer64>.
      i 1 value is not whole or not below 2^53.

# unknown dataset and bad arguments abort

    Code
      store_restore_types(x, s$st, "t/nothing")
    Condition
      Error in `store_restore_types()`:
      ! No dataset "t/nothing" in the store.

---

    Code
      store_restore_types(1:3, s$st, "t/sales")
    Condition
      Error in `store_restore_types()`:
      ! `x` must be a data frame, not an integer vector.

