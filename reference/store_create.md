# Initialise an empty store

Writes the store's settings (`_store.json`) and three empty catalog
files at the root of a location. Use it once for the first location of a
new store; connect to it with
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
afterwards. A location that already holds catalogs is left unchanged and
the call aborts.

## Usage

``` r
store_create(location, history = FALSE)
```

## Arguments

- location:

  Address of the location: a local folder (created when missing) or
  `gs://bucket/prefix`.

- history:

  The store's default for keeping earlier versions of datasets, `FALSE`
  unless switched on. A connection (`store_connect(history = )`) and a
  dataset (`store_write(history = )`) can override it.

## Value

The normalised address of the location, invisibly.

## See also

[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-create")
store_create(location, history = TRUE)
#> ✔ Created an empty store in
#>   C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-create.
st <- store_connect(location)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-create  2/2
#>   files sent  23.7 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-create
#> History: on (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   100  23.7 kB      2  2026-11-21 16:55
unlink(location, recursive = TRUE)
```
