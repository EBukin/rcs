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
      print(dplyr::arrange(q, shop_id, date, ts))
    Output
      # Dataset:  sales/daily [?? x 15] (table)
      # Location: primary (local)
      # Version:  5ee47480 (earlier)
      # Files:    2 of 2
         shop_id date        year product   qty  price promo grade delivered      big
           <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
       1       1 2023-01-20  2023 p08         2   7.52 FALSE low   2023-01-26    8e 2
       2       1 2023-08-07  2023 p12         1 151.   FALSE mid   2023-08-15    4e 2
       3       1 2024-03-24  2024 p10        48 112.   FALSE low   2024-04-01    9e15
       4       1 2024-04-18  2024 p12         9  72.1  FALSE mid   2024-04-26    9e15
       5       2 2023-12-11  2023 p09        46  23.1  TRUE  low   2023-12-13    9e15
       6       2 2024-02-19  2024 p05        28  99.6  TRUE  mid   2024-02-20    9e15
       7       2 2024-03-27  2024 p15        11 138.   TRUE  high  2024-04-04    9e15
       8       2 2024-05-07  2024 p10        33  33.5  FALSE low   2024-05-15    6e 2
       9       2 2024-05-14  2024 p19        34   7.81 FALSE mid   2024-05-19    9e 2
      10       2 2024-10-27  2024 p16        32  84.2  FALSE mid   2024-10-30    3e 2
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i more rows
      # i Use `collect()` to read the rows into R.

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
      $ id    <int> 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29
      $ year  <int> 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023~
      $ value <dbl> 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5, 10.5, 11.5, 12~
      $ cat   <fct> a, c, b, a, c, b, a, c, b, a, c, b, a, c, b

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
      store_read(fx$st, "grids/sim", exact_engine = "planar")
    Condition
      Error in `store_read()`:
      ! "grids/sim" is a raster: `exact_engine` does not apply.
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

