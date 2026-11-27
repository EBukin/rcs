# List the versions of a dataset

The current version and the earlier versions kept in the primary's
history (see "History" in
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)),
with the time each was written and replaced, its size, and whether all
its files are still stored. Reads `_history.parquet` of the primary and
checks that the files exist; no data file is opened.

## Usage

``` r
store_history(st, dataset)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  The dataset's full name, or its last part when that is unique. A
  dataset that was deleted but whose history was kept can be named by
  its full name.

## Value

A tibble, one row per version, the current one first and then by time of
replacement, latest first: `version`, `current` (logical), `written`
(when its newest file was written), `replaced` (when a later version
replaced it; `NA` for the current one), `n_files`, `rows`, `bytes` and
`complete` (`TRUE` when every file of the version is still stored).
Times are shown in the session's time zone. Such a version can be read
with `store_read(version = )`.

## See also

[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-history")
store_create(file.path(root, "primary"), history = TRUE)
#> ✔ Created an empty store in
#>   /tmp/Rtmp/rcs-example-history/primary.
st <- store_connect(file.path(root, "primary"))
sales <- rcs_sim_table(100, seed = 1)
store_write(st, sales, "sales/daily",
  title = "Daily sales", description = "Simulated daily sales."
)
#> ℹ Writing "sales/daily": 100 rows in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-history/primary  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
sales$qty <- sales$qty + 1L
store_write(st, sales, "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  mode = "replace"
)
#> ℹ Replacing "sales/daily": 100 rows in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-history/primary  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_history(st, "sales/daily")
#> # A tibble: 2 × 8
#>   version    current written             replaced            n_files  rows bytes
#>   <chr>      <lgl>   <dttm>              <dttm>                <int> <dbl> <dbl>
#> 1 e359aee05… TRUE    2026-11-27 13:56:30 NA                        1   100 13733
#> 2 9eda87d6a… FALSE   2026-11-27 13:56:30 2026-11-27 13:56:30       1   100 13733
#> # ℹ 1 more variable: complete <lgl>
unlink(root, recursive = TRUE)
```
