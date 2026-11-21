# Open a dataset as a lazy query

Builds a lazy query on one dataset of a store, from the files its
catalog names (the folder is never listed). The query is transformed
with the dplyr verbs [`filter()`](https://rdrr.io/r/stats/filter.html),
`select()`, `mutate()`, `rename()`, `arrange()`, `distinct()`,
[`head()`](https://rdrr.io/r/utils/head.html), and run with `collect()`
(an R data frame), `compute()` (rows kept in memory as Arrow data),
`pull()` or `glimpse()`. Arrow pushes filters and column selection into
the scan, so only the needed files, row groups and columns are read.

## Usage

``` r
store_open(st, dataset, version = NULL)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset: the full name, or its last part when that is
  unique in the store.

- version:

  `NULL` for the current version, or the 16 hex characters of an earlier
  version kept in the history (see
  [`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md)).

## Value

A lazy query of class `rcs_query`. Print it to see the dataset, the
files left after pruning and the columns.

## Details

- A filter whose columns are all partition columns is first evaluated on
  the partition values recorded in the catalog: only the files of the
  matching partitions are opened.

- [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
  adds a spatial filter.

- `collect()` returns a tibble, or an `sf` object for a geospatial
  dataset whose geometry is read, with the catalog's coordinate
  reference system. It restores the R types Arrow does not restore by
  itself (difftime units,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  factor levels, plain list columns) and drops the row identifier
  `.rcs_id` that the package adds to geospatial data; the columns `h3`,
  `bbox` and `h3_p<r>` are returned.

The query reads from the location chosen as for
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
with the catalogs held by the connection.

## See also

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-open")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(500), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-open  2/2
#>   files sent  38.1 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
q <- store_open(st, "daily")
q
#> <rcs_query> sales/daily (table, current)
#> Location: primary
#> Files:    2 of 2
#> Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local
q |>
  dplyr::filter(year == 2024, qty > 40) |>
  dplyr::select(shop_id, date, qty) |>
  dplyr::collect()
#> # A tibble: 43 × 3
#>    shop_id date         qty
#>      <int> <date>     <int>
#>  1       1 2024-12-24    43
#>  2       2 2024-12-17    43
#>  3       3 2024-01-03    45
#>  4       4 2024-06-14    43
#>  5       4 2024-06-17    48
#>  6       4 2024-09-16    47
#>  7       4 2024-11-26    49
#>  8       5 2024-06-09    45
#>  9       6 2024-02-21    43
#> 10       9 2024-02-28    41
#> # ℹ 33 more rows
unlink(location, recursive = TRUE)
```
