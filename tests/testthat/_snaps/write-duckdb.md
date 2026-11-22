# more partitions than max_files abort before anything is staged

    Code
      duck_write(s$st, tbl, key = duck_key, partition = "date", max_files = 3)
    Condition
      Error in `store_write()`:
      ! Partitioning by date gives 91 files, more than `max_files` = 3.
      i Partition by a coarser column, or raise `max_files`.

# duplicate keys abort naming the first duplicates, nothing staged

    Code
      duck_write(s$st, tbl, key = duck_key)
    Condition
      Error in `store_write()`:
      ! The key shop_id, date, and product does not identify the rows: 7 key values repeat.
      x shop_id = 3, date = 2024-01-11, product = p08
      x shop_id = 7, date = 2023-11-03, product = p11
      x shop_id = 4, date = 2023-02-02, product = p03
      x shop_id = 2, date = 2023-11-20, product = p09
      x shop_id = 10, date = 2024-02-24, product = p07
      i And 2 more.

# DuckDB types Arrow cannot write abort naming the columns

    Code
      duck_write(s$st, dplyr::tbl(con, "odd"), key = "id")
    Condition
      Error in `store_write()`:
      ! 2 columns of `x` have a DuckDB type that cannot be stored:
      x huge: HUGEINT
      x span: INTERVAL
      i Cast them to a supported type in the query, for example with `CAST(... AS VARCHAR)`.

# unsupported DuckDB types nested in STRUCT, LIST or MAP abort naming the columns

    Code
      duck_write(s$st, dplyr::tbl(con, "nested"), key = "id")
    Condition
      Error in `store_write()`:
      ! 4 columns of `x` have a DuckDB type that cannot be stored:
      x st: STRUCT(a HUGEINT)
      x spans: INTERVAL[]
      x deep: STRUCT(b UHUGEINT[])
      x maps: STRUCT(m MAP(BIGINT, BIGINT))[]
      i Cast them to a supported type in the query, for example with `CAST(... AS VARCHAR)`.

# mode update and lazy tables on other databases abort

    Code
      duck_write(s$st, tbl, mode = "update", key = duck_key)
    Condition
      Error in `store_write()`:
      ! A lazy DuckDB table cannot be written with `mode = "update"`.
      i Collect the rows with `dplyr::collect()` and update from R, or write the whole dataset with `mode = "replace"`.

---

    Code
      duck_write(s$st, other)
    Condition
      Error in `store_write()`:
      ! `x` is a lazy table on a database other than DuckDB.
      i Collect it with `dplyr::collect()` first, or write it from a DuckDB connection.

# package columns in x are dropped with one message

    Code
      cat(dropped)
    Output
      i Columns h3 and .rcs_id of `x` are the package's own and are dropped.

