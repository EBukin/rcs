# a DuckDB table with a geometry column needs crs

    Code
      dgeo_write(s$st, tbl, key = "id")
    Condition
      Error in `store_write()`:
      ! `crs` is required to write a DuckDB table with a geometry column.
      i Give the coordinate reference system of the geometries, for example `crs = 4326`.

# a geometry column of another type aborts naming it

    Code
      dgeo_write(s$st, dplyr::tbl(con, "bad"), key = "id", crs = 4326)
    Condition
      Error in `store_write()`:
      ! Column geometry of `x` must hold WKB (`BLOB`) or be a `GEOMETRY`, not `VARCHAR`.
      i Convert it in the query, for example with `ST_AsWKB()` of the spatial extension.

