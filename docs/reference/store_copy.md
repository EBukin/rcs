# Copy one dataset between two locations

Copies the current version of a dataset, as one location's catalog
records it, to another location of the connection: the primary, or any
secondary, in either direction. Only the files the target lacks are
sent, each verified by MD5, and the target's catalogs are switched last.
A geospatial dataset's index table travels with it.

## Usage

``` r
store_copy(st, dataset, from, to)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place.

- dataset:

  The dataset's full name, or its last part when that is unique among
  the datasets of `from`.

- from, to:

  Addresses of two locations of the connection.

## Value

A one-row tibble, invisibly: `dataset`, `from`, `to`, `version`,
`status` (`"copied"`, or `"same"` when `to` already held this version),
`files` (files of the version), `uploaded` (files sent), `bytes` and
`seconds`.

## Details

Copying into the primary changes the store's current version of the
dataset;
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
then brings the other secondaries to it. Files of the version the target
replaces are deleted when the dataset keeps no history, as in
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

## See also

[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-copy")
store_create(file.path(root, "copy"))
#> ✔ Created an empty store in
#>   /tmp/Rtmp/rcs-example-copy/copy.
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-copy/primary  2/2
#>   files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
st <- store_connect(file.path(root, "primary"),
  secondary = file.path(root, "copy")
)
store_copy(st, "sales/daily",
  from = file.path(root, "primary"), to = file.path(root, "copy")
)
#> ℹ Copying "sales/daily" (version 0f9e01793cbea58a, 2 files) from
#>   /tmp/Rtmp/rcs-example-copy/primary to
#>   /tmp/Rtmp/rcs-example-copy/copy.
#> ✔ 2/2 files sent (23.8 kB) in 0.2s, MD5 verified. Catalogs of
#>   /tmp/Rtmp/rcs-example-copy/copy updated.
store_status(st)
#> Source: /tmp/Rtmp/rcs-example-copy/primary
#> Locations: [1] /tmp/Rtmp/rcs-example-copy/copy
#> # A tibble: 1 × 8
#>   dataset     location status newer primary_version  location_version
#>   <chr>       <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily [1]      same   NA    0f9e01793cbea58a 0f9e01793cbea58a
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
unlink(root, recursive = TRUE)
```
