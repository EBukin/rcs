# Rebuild the catalogs of a location

Writes the three catalog files of a location again from what it stores,
for a location whose catalogs were lost or damaged. For each dataset,
the manifest with the latest time of writing whose files all exist gives
the current version; earlier complete manifests become its history. A
dataset without any manifest is rebuilt from the metadata embedded in
its Parquet files, when they all belong to one version. Everything else
is reported as skipped: datasets whose manifests all name missing files,
files of several versions without manifest, data files without metadata,
rasters without manifest.

## Usage

``` r
store_rebuild(st, location)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place, and a secondary that was unavailable becomes
  available.

- location:

  The address of a location of the connection.

## Value

A tibble, invisibly, one row per dataset rebuilt and per item skipped:
`dataset` (`NA` for files of no known dataset), `status` (`"rebuilt"` or
`"skipped"`), `version`, `n_files`, `history` (number of earlier
versions), `reason` (why it was skipped) and `paths` (a list column: the
files concerned).

## Details

A rebuild knows only what is stored: a dataset deleted with its history
kept (`store_delete(history = FALSE)`) is listed again with its latest
kept version, and the manifest of a write that failed after its files
and manifest were uploaded counts as that write's version;
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
removes such orphans first.

The location is listed, so the call reads every manifest and the footer
of every data file without manifest; it takes the location's write guard
before it writes.

## See also

[`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md)
to find damaged files,
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-rebuild")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-rebuild  2/2
#>   files sent  23.8 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
# The catalogs are lost
unlink(file.path(location, "_catalog.parquet"))
store_rebuild(st, location)
#> ✔ Rebuilt the catalogs of
#>   /tmp/Rtmp/rcs-example-rebuild: 1 dataset in
#>   2 files, 0 earlier versions.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  /tmp/Rtmp/rcs-example-rebuild
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   100  23.8 kB      2  2026-11-27 18:51
unlink(location, recursive = TRUE)
```
