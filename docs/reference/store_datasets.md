# List the datasets of a store

The primary catalog as a tibble, with the state of each dataset in every
secondary location. Works from the catalogs held by the connection.

## Usage

``` r
store_datasets(st, pattern = NULL, kind = NULL, index = FALSE)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- pattern:

  `NULL`, or a regular expression the dataset names must match.

- kind:

  `NULL`, or any of `"table"`, `"geospatial"` and `"raster"`.

- index:

  `TRUE` also lists the H3 index tables of geospatial datasets
  (`<dataset>__h3`), which are hidden by default.

## Value

A tibble, one row per dataset, sorted by name: `dataset`, `kind`,
`title`, `rows`, `bytes`, `n_files`, `partition` (the partition columns,
a list), `version`, `updated` (in the session's time zone), then one
column `in_<n>` per secondary location, numbered in connection order,
holding `"same"`, `"differs"`, `"missing"` or `"primary only"` (a
dataset kept in the primary only, see
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)'s
`locations`, that the location does not hold; `NA` when the location is
unavailable). With `index = TRUE` a column `index_of` names the dataset
an index table belongs to. The attribute `locations` holds the
addresses: a named character vector with the names `primary` and
`in_<n>`.

## See also

[`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md)
for one dataset,
[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-datasets")
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-datasets/primary  2/2
#>   files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_datasets(st)
#> # A tibble: 1 × 9
#>   dataset  kind  title  rows bytes n_files partition version updated            
#>   <chr>    <chr> <chr> <dbl> <dbl>   <int> <list>    <chr>   <dttm>             
#> 1 sales/d… table Dail…   100 23832       2 <chr [1]> 0f9e01… 2026-11-27 21:23:58
store_datasets(st, pattern = "^sales/", kind = "table")
#> # A tibble: 1 × 9
#>   dataset  kind  title  rows bytes n_files partition version updated            
#>   <chr>    <chr> <chr> <dbl> <dbl>   <int> <list>    <chr>   <dttm>             
#> 1 sales/d… table Dail…   100 23832       2 <chr [1]> 0f9e01… 2026-11-27 21:23:58
unlink(root, recursive = TRUE)
```
