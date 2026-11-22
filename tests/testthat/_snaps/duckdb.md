# store_duckdb() makes its own in-memory connection and names the views

    Code
      con <- store_duckdb(st)
    Message
      v DuckDB views (native mode, nothing read yet): `sales.daily`, `shapes.polygons`, `shapes.polygons__h3`, and `main.summary`.

# a second store on the same connection aborts

    Code
      store_duckdb(other, con = con)
    Condition
      Error in `store_duckdb()`:
      ! This DuckDB connection serves another store.
      i Its primary location is '<primary>', not '<other>'.
      i Use a new connection for each store.

# view names that collide, schema rcs and database names abort before any view

    Code
      store_duckdb(st, con = con)
    Condition
      Error in `store_duckdb()`:
      ! Datasets "a/b/c" and "a/b__c" map to the same DuckDB view name `a.b__c`.
      i The first part of a name is the schema; the other parts are joined with `__`.

---

    Code
      store_duckdb(st, con = con)
    Condition
      Error in `store_duckdb()`:
      ! Dataset "rcs/t" would be shown in schema `rcs`.
      i Schema `rcs` holds the package's own tables; rename the dataset.

---

    Code
      store_duckdb(st, con = con)
    Condition
      Error in `store_duckdb()`:
      ! Dataset "memory/t" would be shown in a schema named like a database: `memory`.
      i DuckDB could not tell the schema from the database; rename the dataset.

# a connection without bigint = 'integer64' and bad arguments abort

    Code
      store_duckdb(st, con = con)
    Condition
      Error in `store_duckdb()`:
      ! `con` returns `BIGINT` as <numeric>, which cannot hold H3 cells exactly.
      i Connect with `DBI::dbConnect(duckdb::duckdb(), bigint = "integer64")`.

---

    Code
      store_duckdb(st, con = "not a connection")
    Condition
      Error in `store_duckdb()`:
      ! `con` must be a DuckDB connection, not a string.

---

    Code
      store_duckdb(st, datasets = "nothing")
    Condition
      Error in `store_duckdb()`:
      ! No dataset "nothing" in the store.

---

    Code
      store_duckdb(st, path = "x.duckdb", con = good)
    Condition
      Error in `store_duckdb()`:
      ! Give `path` or `con`, not both.

---

    Code
      store_duckdb("not a store")
    Condition
      Error in `store_duckdb()`:
      ! `st` must be a store connection made by `store_connect()`.
      x It is a string.

# store_tables() lists a plain DuckDB connection and rejects other input

    Code
      store_tables(1)
    Condition
      Error in `store_tables()`:
      ! `x` must be a store connection or a DuckDB connection.
      x It is a number.

---

    Code
      store_tables(con, st = "x")
    Condition
      Error in `store_tables()`:
      ! `st` must be `NULL` or a store connection made by `store_connect()`.
      x It is a string.

