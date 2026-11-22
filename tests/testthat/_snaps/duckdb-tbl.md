# version = aborts with the DuckDB engine

    Code
      store_open(st, "daily", version = "0123456789abcdef", engine = "duckdb")
    Condition
      Error in `store_open()`:
      ! `version` must be `NULL` with `engine = "duckdb"`.
      i DuckDB views show the current versions; read an earlier version with `engine = "arrow"`.

# a user connection is used, and one without bigint = 'integer64' aborts

    Code
      store_open(st, "daily", engine = "duckdb", con = plain)
    Condition
      Error in `store_open()`:
      ! `con` returns `BIGINT` as <numeric>, which cannot hold H3 cells exactly.
      i Connect with `DBI::dbConnect(duckdb::duckdb(), bigint = "integer64")`.

