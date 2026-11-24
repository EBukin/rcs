# arguments are checked before anything is written

    Code
      store_write(s$st, x, "Sales", title = "t", description = "d")
    Condition
      Error in `store_write()`:
      ! `dataset` is not a valid dataset name: "Sales".
      x Use lower-case letters, digits and `_`, with `/` between folders.
    Code
      store_write(s$st, x, "sales__h3", title = "t", description = "d")
    Condition
      Error in `store_write()`:
      ! `dataset` is not a valid dataset name: "sales__h3".
      x Names ending in `__h3` are reserved for index tables.
    Code
      store_write(s$st, x, "sales", title = "", description = "d")
    Condition
      Error in `store_write()`:
      ! `title` must be a single non-empty string, not `""`.
    Code
      store_write(s$st, list(a = 1), "sales", title = "t", description = "d")
    Condition
      Error in `store_write()`:
      ! `x` must be a data frame, an <sf> object or a <SpatRaster>, not a list.
    Code
      store_write(s$st, x, "sales", title = "t", description = "d", history = "yes")
    Condition
      Error in `store_write()`:
      ! `history` must be `TRUE` or `FALSE`, not a string.
    Code
      store_write(s$st, x, "sales", title = "t", description = "d", mode = "update")
    Condition
      Error in `store_write()`:
      ! Dataset "sales" does not exist, so it cannot be updated.
      i Use `mode = "create"` to write it.
    Code
      store_write(s$st, x[0, ], "sales", title = "t", description = "d", partition = "year")
    Condition
      Error in `store_write()`:
      ! Zero rows can only be written as one file.
      i Use `partition = NULL`.

# create writes a table to every location; create again aborts

    Code
      out <- store_write(s$st, x, "sales/daily", title = "Daily sales", description = "Simulated daily sales.", key = sales_key, partition = "year", source = "simulation")
    Message
      i Writing "sales/daily": 120 rows in 2 files (partition year).
      v primary    <root>/primary     2/2 files sent  <bytes>  <time>
      v secondary  <root>/secondary1  2/2 files sent  <bytes>  <time>
      v secondary  <root>/secondary2  2/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files in 3 locations. Catalogs updated.

---

    Code
      write_sales(s$st, x)
    Condition
      Error in `store_write()`:
      ! Dataset "sales/daily" already exists.
      i Daily sales: 120 rows, updated <date>.
      i Use `mode = "replace"` to replace it, or `mode = "update"` to replace the partitions that `x` holds.

# the same data give the same version and upload nothing; one value changes it

    Code
      again <- store_write(s$st, x, "sales/daily", title = "Daily sales", description = "Simulated daily sales.", key = sales_key, partition = "year", mode = "replace")
    Message
      i "sales/daily" is unchanged (version <version>): 120 rows in 2 files (partition year).
      v primary    <root>/primary     unchanged
      v secondary  <root>/secondary1  up to date
      v All 2 locations hold this version.

# update replaces the partitions of x, keeps the others and uploads only new files

    Code
      out <- store_write(s$st, y, "sales/daily", title = "Daily sales", description = "Simulated daily sales.", mode = "update")
    Message
      i Updating "sales/daily": 1 partition replaced, 1 added, 1 kept.
      * year = 2024: 97 rows -> 96 rows
      * year = 2025: new, 3 rows
      i Writing "sales/daily": 202 rows in 3 files (partition year).
      v primary    <root>/primary     2/3 files sent  <bytes>  <time>
      v secondary  <root>/secondary1  2/3 files sent  <bytes>  <time>
      v MD5 identical for 3 files in 2 locations. Catalogs updated.

# update aborts on a key repeated across partitions, other columns and one-file datasets

    Code
      write_sales(s$st, dup, mode = "update")
    Condition
      Error in `store_write()`:
      ! The key shop_id, date, and product would repeat across partitions: 2 key values of `x` are already in partitions that are kept.
      x shop_id = 8, date = 2023-03-06, product = p04 (kept partition year = 2023)
      x shop_id = 13, date = 2023-11-24, product = p08 (kept partition year = 2023)
    Code
      write_sales(s$st, x[x$year == 2024, -5], mode = "update")
    Condition
      Error in `store_write()`:
      ! The columns of `x` differ from those of "sales/daily".
      x Missing: qty.
      i An update keeps the columns and types; use `mode = "replace"` to change them.
    Code
      write_sales(s$st, transform(x[x$year == 2024, ], qty = as.double(qty)), mode = "update")
    Condition
      Error in `store_write()`:
      ! The columns of `x` differ from those of "sales/daily".
      x qty: stored int32, given double
      i An update keeps the columns and types; use `mode = "replace"` to change them.
    Code
      store_write(s$st, x, "sales/daily", title = "t", description = "d", key = "shop_id", mode = "update")
    Condition
      Error in `store_write()`:
      ! An update keeps the key of "sales/daily".
      i Stored key: shop_id, date, and product; given: shop_id. Use `mode = "replace"` to change it.

---

    Code
      store_write(s$st, x, "plain", title = "Plain", description = "One file.", mode = "update")
    Condition
      Error in `store_write()`:
      ! "plain" is stored as one file, so it cannot be updated by partitions.
      i Use `mode = "replace"`.

# sf with partition = "h3" updates with and without partition as before

    Code
      store_write(s$st, y, "points/auto", title = "Points", description = "Automatic h3 partition.", mode = "update", partition = "h3", max_files = 10)
    Message
      i Updating "points/auto": 1 partition replaced, 0 added, 5 kept.
      * h3_p2 = 827ceffffffffff: 18 rows -> 18 rows
      i Writing "points/auto": 60 rows in 6 files (partition h3_p2).
      v primary  <root>/primary  1/6 files sent  <bytes>  <time>
      v MD5 identical for 6 files in 1 location. Catalogs updated.

---

    Code
      store_write(s$st, z, "points/auto", title = "Points", description = "Automatic h3 partition.", mode = "update", max_files = 10)
    Message
      i Updating "points/auto": 4 partitions replaced, 0 added, 2 kept.
      * h3_p2 = 82565ffffffffff: 14 rows -> 5 rows
      * h3_p2 = 827c4ffffffffff: 2 rows -> 2 rows
      * h3_p2 = 827c5ffffffffff: 10 rows -> 2 rows
      * h3_p2 = 827ceffffffffff: 18 rows -> 1 row
      i Writing "points/auto": 26 rows in 6 files (partition h3_p2).
      v primary  <root>/primary  4/6 files sent  <bytes>  <time>
      v MD5 identical for 6 files in 1 location. Catalogs updated.

# an update whose partition differs from the stored kind aborts naming the stored partition

    Code
      store_write(s$st, x[1:5, ], "points/auto", title = "Points", description = "Automatic partition.", mode = "update", partition = "h3_p5")
    Condition
      Error in `store_write()`:
      ! An update keeps the partitioning of "points/auto".
      i Stored partition: `"h3"` (written as h3_p5). Use `mode = "replace"` to change it.
    Code
      store_write(s$st, d$update, "points/user", title = "Points", description = "User h3_p3 partition.", mode = "update", partition = "h3")
    Condition
      Error in `store_write()`:
      ! An update keeps the partitioning of "points/user".
      i Stored partition: h3_p3. Use `mode = "replace"` to change it.

# the update message of a character user h3_p3 shows the values as given

    Code
      store_write(s$st, d$y, "t/plain", title = "Plain", description = "User h3_p3 partition.", mode = "update", partition = "h3_p3")
    Message
      i Updating "t/plain": 1 partition replaced, 0 added, 1 kept.
      * h3_p3 = 831e5cfffffffff: 2 rows -> 2 rows
      i Writing "t/plain": 5 rows in 2 files (partition h3_p3).
      v primary  <root>/primary  1/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files in 1 location. Catalogs updated.

# an update of partition = "h3" beyond max_files re-partitions the dataset

    Code
      store_write(s$st, b, "shapes/polygons", title = "Polygons", description = "Simulated polygons.", mode = "update", max_files = 3)
    Message
      i Updating "shapes/polygons": 0 partitions replaced, 5 added, 2 kept.
      * h3_p2 = 827c4ffffffffff: new, 2 rows
      * h3_p2 = 827c5ffffffffff: new, 13 rows
      * h3_p2 = 827ccffffffffff: new, 1 row
      * h3_p2 = 827ceffffffffff: new, 12 rows
      * h3_p2 = null: new, 1 row
      i Partition h3_p2 would give 7 files, more than `max_files` = 3.
      i The whole dataset is re-partitioned as h3_p0.
      i Writing "shapes/polygons": 60 rows in 3 files (partition h3_p0), and its index table in 1 file.
      v primary  <root>/primary  4/4 files sent  <bytes>  <time>
      v MD5 identical for 4 files in 1 location. Catalogs updated.

# geocode_engine is checked and stored; NA for tables and geocode = FALSE

    Code
      store_write(s$st, x, "shapes/polygons", title = "t", description = "d",
      geocode_engine = "sphere")
    Condition
      Error in `store_write()`:
      ! `geocode_engine` must be one of "auto", "s2", or "planar", not "sphere".

# update geocodes with the stored engine; another explicit engine aborts

    Code
      store_write(s$st, x[16:22, ], "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", geocode_engine = "auto")
    Condition
      Error in `store_write()`:
      ! An update keeps the geocoding engine of "shapes/polygons".
      i Stored: "s2"; given: "auto". Use `mode = "replace"` to change it.

# update of a dataset without engine geocodes new rows with s2; an explicit engine aborts

    Code
      store_write(st, x[16:22, ], "shapes/polygons", title = "Polygons", description = "Simulated polygons.",
      mode = "update", geocode_engine = "s2")
    Condition
      Error in `store_write()`:
      ! "shapes/polygons" has no geocoding engine recorded; an update geocodes its new rows with "s2".
      i Leave out `geocode_engine`, or use `mode = "replace"` to set one.

# an explicit engine on update of a geocode = FALSE dataset aborts without naming s2

    Code
      store_write(s$st, x[16:22, ], "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", geocode_engine = "s2")
    Condition
      Error in `store_write()`:
      ! "shapes/polygons" is stored with `geocode = FALSE`, so it has no geocoding engine.
      i Leave out `geocode_engine`, or use `mode = "replace"` to geocode it.

# the rebuild warning names rebuilt rows and fallbacks, before the upload lines

    Code
      store_write(s$st, x, "shapes/polygons", title = "Polygons", description = "Simulated polygons.", key = "id")
    Condition
      Warning:
      Geocoding "shapes/polygons": 2 rows are invalid on the sphere.
      i 1 rebuilt by s2, 1 geocoded in the plane after a failed rebuild check.
      * Rebuilt: id = 21.
      * In the plane: id = 22.
    Message
      i Writing "shapes/polygons": 22 rows in 1 file, and its index table in 1 file.
      v primary  <root>/primary  2/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files in 1 location. Catalogs updated.

---

    Code
      store_write(s$st, x, "shapes/keyless", title = "Polygons", description = "Simulated polygons.")
    Condition
      Warning:
      Geocoding "shapes/keyless": 2 rows are invalid on the sphere.
      i 0 rebuilt by s2, 2 geocoded in the plane after a failed rebuild check.
      * In the plane: .rcs_id = 17; .rcs_id = 18.
    Message
      i Writing "shapes/keyless": 22 rows in 1 file, and its index table in 1 file.
      v primary  <root>/primary  2/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files in 1 location. Catalogs updated.

# a raster is written, replaced, and cannot be updated

    Code
      store_write(s$st, r, "grid", title = "Grid", description = "d", mode = "update")
    Condition
      Error in `store_write()`:
      ! A raster cannot be updated.
      i Use `mode = "replace"`.
    Code
      store_write(s$st, r, "grid2", title = "Grid", description = "d", partition = "x")
    Condition
      Error in `store_write()`:
      ! A raster is stored as one file: `partition` and `key` do not apply.

# a primary failing during upload changes no catalog; the repeated call sends only what is missing

    Code
      write_sales(st, x)
    Condition
      Error in `store_write()`:
      ! Writing "sales/daily" to the primary location '<root>/primary' failed.
      i No catalog was changed. Run the call again: files already uploaded are reused.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call <n> (be_put).

# an upload that silently alters a file fails MD5 verification

    Code
      write_sales(st, sales_data())
    Condition
      Error in `store_write()`:
      ! Writing "sales/daily" to the primary location '<root>/primary' failed.
      i No catalog was changed. Run the call again: files already uploaded are reused.
      Caused by error:
      ! MD5 verification failed for 1 file uploaded to '<root>/primary'.
      x sales/daily/year=2023/part-<version>.parquet

# a secondary failing mid-write warns and is reported behind

    Code
      out <- store_write(st, sales_data(), "sales/daily", title = "Daily sales", description = "Simulated daily sales.", key = sales_key, partition = "year")
    Message
      i Writing "sales/daily": 120 rows in 2 files (partition year).
      v primary    <root>/primary     2/2 files sent  <bytes>  <time>
    Condition
      Warning:
      Writing "sales/daily" to the secondary location '<root>/secondary1' failed; it is behind.
      i Run `store_sync()` to bring it up to date.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call <n> (be_put).
    Message
      x secondary  <root>/secondary1  behind: Injected failure at backend call <n> (be_put).
      v secondary  <root>/secondary2  2/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files in 2 locations. Catalogs updated.
      ! 1 secondary location is behind; run `store_sync()` to bring it up to date.

# the write guard aborts when the catalog changed during the write

    Code
      write_sales(s$st, x, mode = "replace")
    Condition
      Error in `store_write()`:
      ! Writing "sales/daily" to the primary location '<root>/primary' failed.
      i No catalog was changed. Run the call again: files already uploaded are reused.
      Caused by error:
      ! Another writer changed '<root>/primary' since this call read its catalog.
      i Nothing was changed there; run the call again.

# tampered h3 or bbox abort naming the rows

    Code
      store_write(s$st, tampered, "shapes/prepared", title = "t", description = "d", key = "id")
    Condition
      Error in `store_write()`:
      ! 2 rows of `x` have h3 values that differ from those the write computes.
      x First: id = 4; id = 9.
      i The write geocodes with `geocode_engine = "auto"`.
      i Prepare `x` with `rcs_geo_add()` and the same `geocode_engine`, or call `rcs_geo_strip()` first.

---

    Code
      store_write(s$st, moved, "shapes/prepared", title = "t", description = "d")
    Condition
      Error in `store_write()`:
      ! 1 row of `x` has bbox values that differ from those the write computes.
      x First: row 7.
      i The write geocodes with `geocode_engine = "auto"`.
      i Prepare `x` with `rcs_geo_add()` and the same `geocode_engine`, or call `rcs_geo_strip()` first.

# cells prepared with another engine abort and name the write's engine

    Code
      store_write(s$st, planar, "shapes/other", title = "t", description = "d", geocode_engine = "s2")
    Condition
      Error in `store_write()`:
      ! 1 row of `x` has h3 values that differ from those the write computes.
      x First: row 1.
      i The write geocodes with `geocode_engine = "s2"`.
      i Prepare `x` with `rcs_geo_add()` and the same `geocode_engine`, or call `rcs_geo_strip()` first.

# h3_res is taken from the cells; mixed or other resolutions abort

    Code
      store_write(s$st, mixed, "shapes/other", title = "t", description = "d")
    Condition
      Error in `store_write()`:
      ! The column h3 of `x` holds cells of several resolutions: 6 and 7.
      i Prepare `x` with `rcs_geo_add()` at one `h3_res`, or call `rcs_geo_strip()` first.

---

    Code
      store_write(s$st, prepared7, "shapes/other", title = "t", description = "d", h3_res = 5L)
    Condition
      Error in `store_write()`:
      ! The column h3 of `x` holds cells of resolution 7, but the write uses `h3_res = 5`.
      i Leave out `h3_res` to write at resolution 7, or call `rcs_geo_strip()` first.

---

    Code
      store_write(s$st, prepared7, "shapes/other", title = "t", description = "d", geocode = FALSE)
    Condition
      Error in `store_write()`:
      ! `x` has a column h3, but `geocode = FALSE` writes no cells.
      i Remove it with `rcs_geo_strip(x, "h3")`, or leave out `geocode = FALSE`.

