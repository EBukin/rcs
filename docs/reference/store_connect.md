# Connect to a store

Reads the catalogs of the primary location and of every secondary one
and returns the connection object. Nothing about the connection is
saved: each script, or the environment of the session, decides which
locations it has.

## Usage

``` r
store_connect(
  primary = NULL,
  secondary = NULL,
  env = "STORE",
  history = NULL,
  create = FALSE
)
```

## Arguments

- primary:

  Address of the primary location, the source of truth. `NULL` reads it
  from the environment variable `<env>_PRIMARY`.

- secondary:

  Addresses of secondary locations, a character vector, in the order in
  which writes reach them. `NULL` reads them from `<env>_SECONDARY` when
  `primary` is `NULL` too, and means none otherwise.

- env:

  Prefix of the environment variables, `"STORE"` by default.

- history:

  Whether writes of this connection keep earlier versions: `TRUE` or
  `FALSE` override the store's default (set by
  [`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md));
  `NULL` uses it. A dataset's own setting, given to
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md),
  overrides both.

- create:

  `TRUE` initialises locations that hold no catalogs yet.

## Value

An object of class `rcs_store`. Print it to see its locations and
datasets.

## Details

A location is a local folder or a Google Cloud Storage address of the
form `gs://bucket/prefix`. When `primary` is `NULL`, the addresses come
from the environment variables `<env>_PRIMARY` and `<env>_SECONDARY`;
the second may hold several addresses separated by `;`.
`<env>_SECONDARY` is read only when both `primary` and `secondary` are
`NULL`, so that a primary given in the call is never mixed with
secondaries of another store.

- A primary that cannot be reached aborts, with the credentials each
  client of its backend needs.

- A secondary that cannot be reached gives a warning and is marked
  unavailable: reads and writes skip it until
  [`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
  finds it again.

- A location without catalogs aborts, unless `create = TRUE`, which
  initialises it with empty catalogs (as
  [`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md)
  does, with the store's history default off).

The object has reference semantics: functions that change a location
update it in place, so the same object serves several writes in a row.
Read functions use the catalogs held by the object; call
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
to see what other sessions wrote since.

## See also

[`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md),
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md),
[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md),
[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md).

## Examples

``` r
primary <- file.path(tempdir(), "rcs-example-connect")
st <- store_connect(primary, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-connect  2/2
#>   files sent  23.7 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-connect
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   100  23.7 kB      2  2026-11-21 16:55

# The same, with the address in the environment
withr::with_envvar(c(STORE_PRIMARY = primary), store_connect())
unlink(primary, recursive = TRUE)
```
