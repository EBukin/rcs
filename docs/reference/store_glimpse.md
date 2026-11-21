# A first look at a dataset

Prints what the catalog says about a dataset (kind, rows, files,
version, key, partition, coordinate reference system) and the first rows
of its first file, read from one row group. Opens one file.

## Usage

``` r
store_glimpse(st, dataset)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset: the full name, or its last part when that is
  unique in the store.

## Value

The rows shown (a tibble, or an `sf` object for geospatial data),
invisibly; for a raster, the
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html),
invisibly.

## See also

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
[`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-glimpse")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(500), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-glimpse  2/2
#>   files sent  38.1 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_glimpse(st, "daily")
#> Dataset:   sales/daily (table)
#> Rows:      500
#> Files:     2
#> Version:   9401e5a1f05ad19e
#> Key:       shop_id, date, product
#> Partition: year
#> 
#> Rows: 252
#> Columns: 15
#> $ shop_id   <int> 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, …
#> $ date      <date> 2023-01-22, 2023-01-24, 2023-01-28, 2023-03-12, 2023-03-15,…
#> $ year      <int> 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, …
#> $ product   <fct> p07, p19, p17, p07, p18, p08, p06, p04, p18, p08, p04, p08, …
#> $ qty       <int> 31, 42, 12, 21, 29, NA, 10, 39, 43, 28, 12, 13, 46, 7, 47, 4…
#> $ price     <dbl> 69.09, 182.48, 83.44, 128.94, 156.59, 81.90, 152.18, 180.19,…
#> $ promo     <lgl> FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, TRUE, FALSE, …
#> $ grade     <ord> low, low, mid, low, mid, high, high, mid, high, low, high, h…
#> $ delivered <date> NA, 2023-01-28, 2023-01-29, NA, 2023-03-25, 2023-04-03, 202…
#> $ big       <int64> 9007199254741873, 331, 204, 621, 9007199254741483, 9007199…
#> $ wait      <drtn> 47.51 hours, 71.65 hours, 32.02 hours, 46.74 hours, 61.72 h…
#> $ note      <chr> "αβγ δεζ", "数据", "αβγ δεζ", "two words", "two words", "naïve…
#> $ tags      <list> <"new", "sale">, "new", <>, <>, "new", <>, <>, <"new", "sal…
#> $ ts        <dttm> 2023-01-22 14:56:06, 2023-01-24 05:59:50, 2023-01-28 18:27:…
#> $ ts_local  <dttm> 2023-01-22 09:56:06, 2023-01-24 00:59:50, 2023-01-28 13:27:…
unlink(location, recursive = TRUE)
```
