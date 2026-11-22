# Bring secondary locations up to date

Copies datasets from the primary location to the secondary ones: every
dataset whose copy in a secondary is missing or differs from the
primary's (another version, or another entry). Only the files the
secondary lacks are sent, each verified by MD5; the catalogs of the
secondary are switched last, so that its readers always see a complete
version. A geospatial dataset's index table travels with it.

## Usage

``` r
store_sync(st, datasets = NULL, to = NULL, dry_run = FALSE)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place.

- datasets:

  `NULL` for every dataset of the primary, or names of datasets (full
  names, or last parts that are unique).

- to:

  `NULL` for every secondary location, or the addresses of some of them.

- dry_run:

  `TRUE` reports what would be copied and changes nothing.

## Value

A tibble, invisibly, one row per secondary location: `location`,
`status` (`"synced"`, `"same"` when nothing was missing, `"behind"` when
it failed, `"unavailable"`, or `"to sync"` with `dry_run = TRUE`),
`datasets` (a list column: the datasets copied, or to copy), `files`
(files sent, or to send), `bytes` and `seconds`.

## Details

`store_sync()` never deletes a dataset: datasets found only in a
secondary are left alone (see
[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md),
status `"extra"`). Files of a version the secondary replaces are deleted
when the dataset keeps no history, as in
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

A secondary that fails is reported as behind with a warning, and the
next one is synced; running the call again sends only what is still
missing.

## See also

[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md)
to compare the locations,
[`store_copy()`](https://ebukin.github.io/rcs/reference/store_copy.md)
for one dataset between any two locations.

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-sync")
store_create(file.path(root, "copy"))
#> ✔ Created an empty store in
#>   /tmp/Rtmp/rcs-example-sync/copy.
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-sync/primary  2/2
#>   files sent  23.7 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.

# A connection with a secondary location that missed the write
st <- store_connect(file.path(root, "primary"),
  secondary = file.path(root, "copy")
)
store_status(st)
#> Locations: [1] /tmp/Rtmp/rcs-example-sync/copy
#> # A tibble: 1 × 8
#>   dataset     location status  newer primary_version  location_version
#>   <chr>       <chr>    <chr>   <chr> <chr>            <chr>           
#> 1 sales/daily [1]      missing NA    bf16efd1aebea856 NA              
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
store_sync(st, dry_run = TRUE)
#> ℹ Dry run: nothing is changed.
#> ℹ Syncing 1 dataset from the primary
#>   /tmp/Rtmp/rcs-example-sync/primary to 1
#>   secondary location.
#> • secondary  /tmp/Rtmp/rcs-example-sync/copy     would
#>   copy 1 dataset, 2 files (23.7 kB): "sales/daily"
store_sync(st)
#> ℹ Syncing 1 dataset from the primary
#>   /tmp/Rtmp/rcs-example-sync/primary to 1
#>   secondary location.
#> ✔ secondary  /tmp/Rtmp/rcs-example-sync/copy     1
#>   dataset, 2/2 files sent  23.7 kB  0.3s
#> ✔ MD5 identical for 2 files sent to 1 location. Catalogs updated.
store_status(st)
#> Locations: [1] /tmp/Rtmp/rcs-example-sync/copy
#> # A tibble: 1 × 8
#>   dataset     location status newer primary_version  location_version
#>   <chr>       <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily [1]      same   NA    bf16efd1aebea856 bf16efd1aebea856
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
unlink(root, recursive = TRUE)
```
