# exact = FALSE returns the Arrow path's candidate set, with its message

    Code
      got <- duckdb_rows(st, "polygons", queries$bbox, exact = FALSE)
    Message
      i Spatial filter: `exact = FALSE`, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

# a table without bbox, a table that is not geospatial and a bad exact abort

    Code
      store_intersects(dplyr::select(x, -bbox), q)
    Condition
      Error in `store_intersects()`:
      ! A spatial filter on a DuckDB table needs the column bbox.
      i Call `store_intersects()` before `dplyr::select()` drops it.

---

    Code
      store_intersects(dplyr::select(x, -h3), strip)
    Condition
      Error in `store_intersects()`:
      ! A spatial filter on a DuckDB table needs the column h3.
      i Call `store_intersects()` before `dplyr::select()` drops it.

---

    Code
      store_intersects(store_open(st, "daily", engine = "duckdb"), q)
    Condition
      Error in `store_intersects()`:
      ! A spatial filter needs a geospatial dataset.
      x "sales/daily" is a table.

---

    Code
      store_intersects(x, q, exact = "sphere")
    Condition
      Error in `store_intersects()`:
      ! `exact` must be `TRUE`, `FALSE` or "sql" on a DuckDB table.
      x It is "sphere".

# an aggregate after a pending exact test informs about the candidate set

    Code
      n <- dplyr::collect(dplyr::count(x))
    Message
      i Spatial filter: the geometry is not read, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

