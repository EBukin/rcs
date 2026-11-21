# Remove old versions and orphan files

In every available location: removes history versions beyond the last
`keep` of each dataset, or replaced before `before`, deletes their files
and manifests unless a remaining version still names them, and deletes
orphan files that no catalog names (left by failed or interrupted
writes, found by listing the location). Orphans younger than one hour
are kept: they may belong to a write in progress. A file that a kept
version names is never deleted.

## Usage

``` r
store_prune(st, dataset = NULL, keep = 1, before = NULL, dry_run = FALSE)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place.

- dataset:

  `NULL` for every dataset, or one dataset's name (its index table is
  pruned with it). A deleted dataset whose history was kept can be named
  by its full name.

- keep:

  Number of history versions kept per dataset, not counting the current
  version; `0` removes all history.

- before:

  `NULL`, or a time (`POSIXct`, `Date` or a string
  [`as.POSIXct()`](https://rdrr.io/r/base/as.POSIXlt.html) understands,
  in UTC): history versions replaced before it are removed as well.

- dry_run:

  `TRUE` reports what would be removed and changes nothing.

## Value

A tibble, invisibly, one row per file removed (or to be removed with
`dry_run = TRUE`): `location`, `dataset`, `version` (`NA` for orphans),
`path`, `reason` (`"history"` or `"orphan"`) and `bytes`.

## See also

[`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-prune")
store_create(file.path(root, "primary"), history = TRUE)
#> ✔ Created an empty store in
#>   C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-prune/primary.
st <- store_connect(file.path(root, "primary"))
sales <- rcs_sim_table(100, seed = 1)
for (i in 1:3) {
  sales$qty <- sales$qty + 1L
  store_write(st, sales, "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.",
    mode = "replace"
  )
}
#> ℹ Writing "sales/daily": 100 rows in 1 file.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-prune/primary  1/1
#>   files sent  13.7 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
#> ℹ Replacing "sales/daily": 100 rows in 1 file.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-prune/primary  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
#> ℹ Replacing "sales/daily": 100 rows in 1 file.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-prune/primary  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_prune(st, keep = 1, dry_run = TRUE)
#> ✔ Would remove 1 history version and 2 files (16.2 kB) in 1 location.
store_prune(st, keep = 0)
#> ✔ Removed 2 history versions and 4 files (32.4 kB) in 1 location.
store_history(st, "sales/daily")
#> # A tibble: 1 × 8
#>   version    current written             replaced n_files  rows bytes
#>   <chr>      <lgl>   <dttm>              <dttm>     <int> <dbl> <dbl>
#> 1 19a32f7f8… TRUE    2026-11-21 16:55:24 NA             1   100 13734
#> # ℹ 1 more variable: complete <lgl>
unlink(root, recursive = TRUE)
```
