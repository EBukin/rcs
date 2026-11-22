# store_duckdb(path = ) without st aborts for a file without rcs.store, or no file

    Code
      store_duckdb(path = path)
    Condition
      Error in `store_duckdb()`:
      ! The DuckDB file <path> holds no table `rcs.store`.
      i Only a file prepared by `store_duckdb()` can be reopened without `st`.

# a path inside a local location aborts

    Code
      store_duckdb(st, path = inside)
    Condition
      Error in `store_duckdb()`:
      ! The DuckDB file <path> is inside the store location <path>.
      i A sync would copy it; put it outside every location of the store.

# a file stem equal to a used schema aborts and leaves no file

    Code
      store_duckdb(st, path = path)
    Condition
      Error in `store_duckdb()`:
      ! Dataset "sales/daily" would be shown in a schema named like a database: `sales`.
      i DuckDB could not tell the schema from the database; rename the dataset.

# a table or an unlisted view with a view's name aborts, naming it

    Code
      store_duckdb(st, path = path)
    Condition
      Error in `store_duckdb()`:
      ! The DuckDB connection already holds `sales.daily`, which `store_duckdb()` did not make.
      i Rename or drop it first.

# arrow mode with a path informs that views must be refreshed after reopening

    Code
      con <- store_duckdb(st, path = path, datasets = "summary", mode = "arrow")
    Message
      v DuckDB view (arrow mode, nothing read yet): `main.summary`.
      i Views in arrow mode do not work after the file is closed: call `store_duckdb()` again after reopening it.

