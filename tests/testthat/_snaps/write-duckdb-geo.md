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

# an invalid crs and partitions that cannot apply abort

    Code
      dgeo_write(s$st, tbl, key = "id", crs = "not a crs")
    Condition
      Error in `store_write()`:
      ! `crs` must be a coordinate reference system that `sf::st_crs()` reads.

---

    Code
      dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "h3", geocode = FALSE)
    Condition
      Error in `store_write()`:
      ! `partition = "h3"` needs geocoded geospatial data.
      i It is not available for tables or with `geocode = FALSE`.

---

    Code
      dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = c("h3", "id"))
    Condition
      Error in `store_write()`:
      ! A geospatial DuckDB table cannot be partitioned by h3.
      i Use `partition = "h3"` alone, or attribute columns of `x`.

---

    Code
      dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "nowhere")
    Condition
      Error in `store_write()`:
      ! The partition column nowhere is not in the data.

---

    Code
      dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "h3", max_files = 1L, h3_res = 9L)
    Condition
      Error in `store_write()`:
      ! Even H3 resolution 0 gives more than `max_files` = 1 partitions.
      i Raise `max_files`.

