# Check a stored dataset

Two checks, chosen by `x`:

## Usage

``` r
store_check(
  st,
  dataset,
  x = NULL,
  n = 20,
  columns = NULL,
  locations = "all",
  error = TRUE
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  The dataset's full name, or its last part when that is unique.

- x:

  `NULL` for the integrity check, or the data the dataset was written
  from (data frame, `sf` object or `SpatRaster`) for the serialization
  check.

- n:

  Rows (or raster cells) compared per file.

- columns:

  `NULL` for all columns that `x` and the files share, or the names of
  the columns to compare.

- locations:

  `"all"` for every available location, or addresses of locations of the
  connection.

- error:

  `TRUE` aborts when a check fails; `FALSE` only reports.

## Value

A tibble, invisibly, with one row per location and file: `location`,
`dataset`, `path`, `status` (`"ok"`, `"failed"`, or `"missing"` when the
location does not hold the dataset) and `problem` (a description, `NA`
when ok).

## Details

- With `x`, a serialization check: for each file of the dataset, `n`
  rows of one random row group are read and compared, column by column,
  with the matching rows of `x`: matched by the key, else by `.rcs_id`,
  else (tables without key) by row order. Values are compared exactly,
  after normalisation (a tibble and a data frame are alike, geometries
  are compared as WKB, times as instants). Geospatial data without key
  and without a column `.rcs_id` are geocoded again to find the row
  identifiers, which matches only a dataset written in one call (not
  after an `update`). For a raster, `n` random cells are compared.
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
  runs this check on the staged files before it uploads them.

- Without `x`, an integrity check of each location: every file of the
  current version exists with the MD5 its catalog records (read from the
  backend's metadata, so no data file is downloaded where the backend
  reports MD5), its Parquet footer has the recorded rows and the columns
  of the entry, the version is the hash of the file rows, the totals
  match, and the manifest agrees with the catalog. The dataset's index
  table is checked with it.

The catalogs of the checked locations are read again first, and the
connection is updated with them.

## See also

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-check")
st <- store_connect(file.path(root, "primary"), create = TRUE)
sales <- rcs_sim_table(100, seed = 1)
store_write(st, sales, "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-check/primary  2/2
#>   files sent  23.7 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_check(st, "sales/daily")
#> ✔ 2 files checked in 1 location: no problem found.
store_check(st, "sales/daily", x = sales)
#> ✔ 2 files checked in 1 location: no problem found.
unlink(root, recursive = TRUE)
```
