# Delete a dataset

Removes a dataset, and its index table, from every available location:
first its entry from the catalogs of every location (the primary first),
then the files of its current version. The earlier versions kept in the
history stay readable with `store_read(version = )` unless
`history = TRUE`, which removes them, their files and their manifests as
well.

## Usage

``` r
store_delete(st, dataset, confirm, history = FALSE)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place.

- dataset:

  The dataset's full name, or its last part when that is unique.

- confirm:

  The dataset's full name, typed again.

- history:

  `TRUE` also removes the dataset's history versions.

## Value

A tibble, invisibly, one row per location: `location`, `role`, `status`
(`"deleted"`, `"absent"` when the location did not list the dataset,
`"behind"` when it failed, `"unavailable"`), `files` (files deleted) and
`bytes`.

## Details

As a guard against slips, `confirm` must repeat the dataset's full name.

If the primary fails, nothing is changed and the call aborts. If a
secondary fails, the call warns and goes on; run it again to remove the
dataset there. Files that could not be deleted are no longer named by
any catalog;
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
removes them. Deleting a dataset that no location lists informs and
changes nothing.

## See also

[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-delete")
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales."
)
#> ℹ Writing "sales/daily": 100 rows in 1 file.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-delete/primary  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_delete(st, "daily", confirm = "sales/daily")
#> ℹ Deleting "sales/daily" and its index table from every location, keeping its
#>   history.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-delete/primary  2
#>   files deleted  13.7 kB
#> ✔ "sales/daily" is removed from 1 location.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-delete/primary
#> History: off (store default)
#> Datasets: none
unlink(root, recursive = TRUE)
```
