# Print a store connection

Shows the locations with their backend and availability, the history
setting, and the datasets grouped by folder: name, kind, rows, size,
files, last update and, per secondary location, whether its copy is the
same (`=`), differs (a not-equal sign, `!=` on a console without UTF-8)
or is missing (a dash), `P` when it does not hold a dataset kept in the
primary only (see
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)'s
`locations`; the legend names `P` only when the store holds such a
dataset), and `?` for an unavailable location. Works from the catalogs
held by the connection.

## Usage

``` r
# S3 method for class 'rcs_store'
print(x, index = FALSE, n = 50, ...)
```

## Arguments

- x:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- index:

  `TRUE` also lists the H3 index tables, hidden by default.

- n:

  Most datasets to list; the rest are counted.

- ...:

  Ignored.

## Value

`x`, invisibly.

## See also

[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md)
for the same as a tibble.

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-print")
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-print/primary  2/2
#>   files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
print(st)
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  /tmp/Rtmp/rcs-example-print/primary
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   100  23.8 kB      2  2026-11-27 21:23
unlink(root, recursive = TRUE)
```
