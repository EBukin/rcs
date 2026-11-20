# geometry = FALSE and columns choose what is read

    Code
      store_read(fx$st, "polygons", columns = c(id, nothing))
    Condition
      Error in `store_read()`:
      ! Can't select columns that don't exist.
      x Column `nothing` doesn't exist.

# short names resolve; unknown names and bad versions abort

    Code
      store_read(fx$st, "sales/dialy")
    Condition
      Error in `store_read()`:
      ! No dataset "sales/dialy" in the store.
      i Closest name: "sales/daily".

---

    Code
      store_read(fx$st, "sales/daily", version = "abc")
    Condition
      Error in `store_read()`:
      ! `version` must be 16 hex characters, not "abc".

---

    Code
      store_read("not a store", "sales/daily")
    Condition
      Error in `store_read()`:
      ! `st` must be a store connection made by `store_connect()`.
      x It is a string.

# an earlier version is read from the history with that version's entry

    Code
      q
    Output
      <rcs_query> sales/daily (table, earlier version)
      Location: primary
      Files:    2 of 2
      Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local

# a read served by a local secondary makes no call to the primary

    Code
      got <- store_read(st, "sales/daily", year == 2024)
    Message
      i Reading "sales/daily" from secondary <secondary1>.

# store_sample() reads row groups, applies filters, and is reproducible

    Code
      all <- store_sample(fx$st, "sales/summary", n = 1000, seed = 1)
    Message
      i Only 40 rows match; all are returned.

---

    Code
      store_sample(fx$st, "sales/daily", n = 0)
    Condition
      Error in `store_sample()`:
      ! `n` must be a positive whole number.

# store_glimpse() shows the catalog facts and opens one file

    Code
      store_glimpse(fx$st, "items")
    Output
      Dataset:   demo/items (table)
      Rows:      30
      Files:     2
      Version:   <version>
      Key:       id
      Partition: year
      
      Rows: 15
      Columns: 4
      $ id    [3m[38;5;246m<int>[39m[23m 1[38;5;246m, [39m3[38;5;246m, [39m5[38;5;246m, [39m7[38;5;246m, [39m9[38;5;246m, [39m11[38;5;246m, [39m13[38;5;246m, [39m15[38;5;246m, [39m17[38;5;246m, [39m19[38;5;246m, [39m21[38;5;246m, [39m23[38;5;246m, [39m25[38;5;246m, [39m27[38;5;246m, [39m29
      $ year  [3m[38;5;246m<int>[39m[23m 2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023[38;5;246m, [39m2023~
      $ value [3m[38;5;246m<dbl>[39m[23m 0.5[38;5;246m, [39m1.5[38;5;246m, [39m2.5[38;5;246m, [39m3.5[38;5;246m, [39m4.5[38;5;246m, [39m5.5[38;5;246m, [39m6.5[38;5;246m, [39m7.5[38;5;246m, [39m8.5[38;5;246m, [39m9.5[38;5;246m, [39m10.5[38;5;246m, [39m11.5[38;5;246m, [39m12~
      $ cat   [3m[38;5;246m<fct>[39m[23m a[38;5;246m, [39mc[38;5;246m, [39mb[38;5;246m, [39ma[38;5;246m, [39mc[38;5;246m, [39mb[38;5;246m, [39ma[38;5;246m, [39mc[38;5;246m, [39mb[38;5;246m, [39ma[38;5;246m, [39mc[38;5;246m, [39mb[38;5;246m, [39ma[38;5;246m, [39mc[38;5;246m, [39mb

# store_h3_hex() converts cells to hex strings

    Code
      store_h3_hex(599686042433355008)
    Condition
      Error in `store_h3_hex()`:
      ! `x` must hold H3 cells as hex strings, <integer64> or <H3>, not a number.
      i A plain number cannot hold an H3 cell: it would be rounded to another cell.

# rasters are read as SpatRaster, cropped by intersects, and refuse table arguments

    Code
      store_read(fx$st, "grids/sim", layer > 1, geometry = FALSE)
    Condition
      Error in `store_read()`:
      ! "grids/sim" is a raster: `...` and `geometry` do not apply.
      i A raster read takes only `intersects`, which crops it to the query's box.

---

    Code
      store_read(fx$st, "grids/sim", columns = 1, exact = FALSE)
    Condition
      Error in `store_read()`:
      ! "grids/sim" is a raster: `columns` and `exact` do not apply.
      i A raster read takes only `intersects`, which crops it to the query's box.

---

    Code
      store_open(fx$st, "grids/sim")
    Condition
      Error in `store_open()`:
      ! `store_open()` does not apply to rasters.
      i Read a raster with `store_read()`, which returns a <SpatRaster>.

---

    Code
      store_sample(fx$st, "grids/sim")
    Condition
      Error in `store_sample()`:
      ! `store_sample()` does not apply to rasters.
      i Read a raster with `store_read()`, which returns a <SpatRaster>.

