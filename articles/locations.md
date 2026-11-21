# Primary and secondary locations

A store can be kept in several places at once: for example in a cloud
bucket that a team shares and in a local folder on each laptop, for fast
reads and for work without a network. This vignette explains how rcs
keeps these copies in step, and what happens when one of them cannot be
reached or falls behind. It assumes you have read
[`vignette("rcs")`](https://ebukin.github.io/rcs/articles/rcs.md).

``` r

library(rcs)
```

## Primary and secondaries

Each place that holds a copy of the store is a **location**: a local
folder, or a Google Cloud Storage address of the form
`gs://bucket/prefix`. A connection has:

- exactly one **primary** location. Its catalog is the truth: a
  dataset’s current version is the version the primary’s catalog names.
  Writes go there first.
- any number of **secondary** locations. Each holds a full or partial
  copy. A secondary copy of a dataset is up to date when its version
  equals the primary’s.

The connection is not saved anywhere. Each script, or each user’s
environment, says which locations it uses, so one person can read a
shared bucket through a local copy while another works on the bucket
alone.

Here three local folders play the three locations. In practice the
primary would often be a bucket.

``` r

root <- file.path(tempdir(), "locations")
primary <- file.path(root, "primary")
copy_1 <- file.path(root, "copy-1")
copy_2 <- file.path(root, "copy-2")

st <- store_connect(primary, secondary = c(copy_1, copy_2), create = TRUE)
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#>   secondary 2  local  <tempdir>/locations/copy-2
#> History: off (store default)
#> Datasets: none
```

## Writes land everywhere

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
writes to the primary and then to every secondary, in the order given.
There is no argument to choose locations: a write always tries them all.
Each location gets only the files it lacks, each file is checked by its
MD5 checksum after the copy, and each location’s catalog is switched
last.

``` r

store_write(st, rcs_sim_table(200, seed = 1), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year"
)
#> ℹ Writing "sales/daily": 200 rows in 2 files (partition year).
#> ✔ primary    <tempdir>/locations/primary  2/2 files sent  27.8 kB  0.2s
#> ✔ secondary  <tempdir>/locations/copy-1   2/2 files sent  27.8 kB  0.1s
#> ✔ secondary  <tempdir>/locations/copy-2   2/2 files sent  27.8 kB  0.1s
#> ✔ MD5 identical for 2 files in 3 locations. Catalogs updated.
```

In the printed connection, the columns `1` and `2` show the state of
each secondary copy: `=` the same as the primary, `≠` another version,
`–` missing, `?` location unavailable.

``` r

st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#>   secondary 2  local  <tempdir>/locations/copy-2
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1  2
#>   sales/
#>     daily  table   200  27.8 kB      2  2026-11-21 21:57  =  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

## Reads use the closest copy

A read picks, among the locations that hold the dataset at the primary’s
version, a local folder first, then the primary, then the other
secondaries. With a bucket as primary and a local folder as secondary,
reads come from the local folder as long as it is up to date, and a line
says so:

``` r

st <- store_connect("gs://my-bucket/store", secondary = "~/data/my-store")
x <- store_read(st, "sales/daily")
#> ℹ Reading "sales/daily" from secondary ~/data/my-store.
```

`options(rcs.quiet = TRUE)` silences that line. A secondary that is
behind is skipped, and the read goes to the primary.

## Addresses from the environment

Scripts often should not name the locations: they differ between users
and machines. When `primary` is not given,
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
reads it from the environment variable `STORE_PRIMARY`, and the
secondaries from `STORE_SECONDARY`, several separated by `;`. A line
like this in a user’s `.Renviron` file sets them for every session:

    STORE_PRIMARY=gs://my-bucket/store
    STORE_SECONDARY=~/data/my-store

The script then only says:

``` r

st <- store_connect()
```

Here the variables are set for one call:

``` r

st_env <- withr::with_envvar(
  c(STORE_PRIMARY = primary, STORE_SECONDARY = paste(copy_1, copy_2, sep = ";")),
  store_connect()
)
st_env
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#>   secondary 2  local  <tempdir>/locations/copy-2
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1  2
#>   sales/
#>     daily  table   200  27.8 kB      2  2026-11-21 21:57  =  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

`env` changes the prefix of the variables, so one session can use
several stores: `store_connect(env = "ARCHIVE")` reads `ARCHIVE_PRIMARY`
and `ARCHIVE_SECONDARY`. `<env>_SECONDARY` is read only when neither
`primary` nor `secondary` is given, so a primary named in the call is
never mixed with the secondaries of another store. Without a primary,
the call stops and names the variable to set:

``` r

withr::with_envvar(c(STORE_PRIMARY = NA), store_connect())
#> Error in `store_connect()`:
#> ! No primary location given.
#> ℹ Pass `primary`, or set the environment variable `STORE_PRIMARY` (and `STORE_SECONDARY` for secondary locations,
#>   separated by `;`).
```

## A secondary that cannot be reached

A primary that cannot be reached stops
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md):
nothing can be read or written without the truth. A secondary that
cannot be reached only gives a warning; it is marked unavailable and
skipped by reads and writes.

To show this, the folder of the second copy is moved away, as if a drive
had been disconnected.
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
reads the catalogs of all locations again and notices.

``` r

file.rename(copy_2, paste0(copy_2, "-away"))
#> [1] TRUE
store_refresh(st)
#> Warning: The secondary location <tempdir>/locations/copy-2 is not available; it is skipped.
#> ℹ It holds no store catalogs.
#> ℹ Run `store_refresh()` to try it again.
```

A write now reaches the primary and the first copy, skips the second,
and says that it is behind:

``` r

store_write(st, rcs_sim_table(300, seed = 2), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year",
  mode = "replace"
)
#> ℹ Replacing "sales/daily": 300 rows in 2 files (partition year).
#> ✔ primary    <tempdir>/locations/primary  2/2 files sent  31.2 kB  0.2s
#> ✔ secondary  <tempdir>/locations/copy-1   2/2 files sent  31.2 kB  0.1s
#> ! secondary  <tempdir>/locations/copy-2   unavailable, skipped
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.
#> ! 1 secondary location is behind; run `store_sync()` to bring it up to date.
```

If a secondary fails during a write (a network error, say), the write
goes on with the next location and reports the failed one as behind in
the same way. Only a failure in the primary stops a write, and then no
catalog of any location has changed.

## A secondary that is behind

When the folder is back,
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
finds it again. It still holds the old version of `sales/daily`:

``` r

file.rename(paste0(copy_2, "-away"), copy_2)
#> [1] TRUE
store_refresh(st)
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#>   secondary 2  local  <tempdir>/locations/copy-2
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1  2
#>   sales/
#>     daily  table   300  31.2 kB      2  2026-11-21 21:57  =  ≠
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

A secondary also falls behind when someone writes through a connection
that does not include it:

``` r

only_primary <- store_connect(primary)
store_write(only_primary, rcs_sim_table(50, seed = 3), "sales/weekly",
  title = "Weekly sales",
  description = "Simulated weekly sales."
)
#> ℹ Writing "sales/weekly": 50 rows in 1 file.
#> ✔ primary  <tempdir>/locations/primary  1/1 files sent  11.7 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_refresh(st)
```

[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md)
compares every secondary with the primary, dataset by dataset, from the
catalogs alone. `status` is `same`, `differs` (another version),
`missing` (not in the secondary) or `extra` (only in the secondary); for
`differs`, `newer` says which side was written last, a hint only, as
clocks of different machines can differ. Printed, the addresses of the
secondaries are listed once above the table and numbered in the column
`location`.

``` r

store_status(st)[c("dataset", "location", "status", "newer")]
#> Locations: [1] <tempdir>/locations/copy-1
#>            [2] <tempdir>/locations/copy-2
#> # A tibble: 4 × 4
#>   dataset      location status  newer  
#>   <chr>        <chr>    <chr>   <chr>  
#> 1 sales/daily  [1]      same    NA     
#> 2 sales/weekly [1]      missing NA     
#> 3 sales/daily  [2]      differs primary
#> 4 sales/weekly [2]      missing NA
```

A copy that is behind is never read: reads go to a location that holds
the primary’s version. The next write of a dataset brings every
available secondary up to date for that dataset, whatever version it
held.

## Bringing secondaries up to date

[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
copies datasets from the primary to the secondaries: by default every
dataset that is missing or differs, to every secondary. Like a write, it
copies only the files a location lacks, checks each by MD5 and switches
the catalog last. It never deletes a dataset. `dry_run = TRUE` shows
what it would do.

``` r

store_sync(st, dry_run = TRUE)
#> ℹ Dry run: nothing is changed.
#> ℹ Syncing 2 datasets from the primary <tempdir>/locations/primary to 2 secondary
#>   locations.
#> • secondary  <tempdir>/locations/copy-1   would copy 1 dataset, 1 file (11.7 kB):
#>   "sales/weekly"
#> • secondary  <tempdir>/locations/copy-2   would copy 2 datasets, 3 files (42.9 kB):
#>   "sales/daily", "sales/weekly"
```

`datasets` and `to` limit it to some datasets or some secondaries. Here
only the second copy is brought up to date:

``` r

store_sync(st, to = copy_2)
#> ℹ Syncing 2 datasets from the primary <tempdir>/locations/primary to 1 secondary
#>   location.
#> ✔ secondary  <tempdir>/locations/copy-2   2 datasets, 3/3 files sent  42.9 kB  0.2s
#> ✔ MD5 identical for 3 files sent to 1 location. Catalogs updated.
```

[`store_copy()`](https://ebukin.github.io/rcs/reference/store_copy.md)
copies one dataset between any two locations of the connection, in
either direction. The first copy still lacks `sales/weekly`; here it
gets it from the second copy:

``` r

store_copy(st, "sales/weekly", from = copy_2, to = copy_1)
#> ℹ Copying "sales/weekly" (version 72f66b800c3fa743, 1 file) from
#>   <tempdir>/locations/copy-2 to
#>   <tempdir>/locations/copy-1.
#> ✔ 1/1 file sent (11.7 kB) in 0.1s, MD5 verified. Catalogs of
#>   <tempdir>/locations/copy-1 updated.
store_status(st)[c("dataset", "location", "status")]
#> Locations: [1] <tempdir>/locations/copy-1
#>            [2] <tempdir>/locations/copy-2
#> # A tibble: 4 × 3
#>   dataset      location status
#>   <chr>        <chr>    <chr> 
#> 1 sales/daily  [1]      same  
#> 2 sales/weekly [1]      same  
#> 3 sales/daily  [2]      same  
#> 4 sales/weekly [2]      same
```

Two more functions maintain locations.
[`store_delete()`](https://ebukin.github.io/rcs/reference/store_delete.md)
removes a dataset from every location; it stops unless `confirm` repeats
the full name.
[`store_rebuild()`](https://ebukin.github.io/rcs/reference/store_rebuild.md)
rebuilds a location’s catalog from the small description file (manifest)
that every version of every dataset leaves next to its data files, for
example after a catalog file was lost.

``` r

store_delete(st, "sales/weekly", confirm = "sales/weekly")
#> ℹ Deleting "sales/weekly" and its index table from every location, keeping its history.
#> ✔ primary    <tempdir>/locations/primary  2 files deleted  11.7 kB
#> ✔ secondary  <tempdir>/locations/copy-1   2 files deleted  11.7 kB
#> ✔ secondary  <tempdir>/locations/copy-2   2 files deleted  11.7 kB
#> ✔ "sales/weekly" is removed from 3 locations.
store_rebuild(st, copy_2)
#> ✔ Rebuilt the catalogs of <tempdir>/locations/copy-2: 1 dataset in 2 files, 0 earlier
#>   versions.
```

## Cloud locations

A Google Cloud Storage location is given by its address. Nothing else
changes: the same functions work on buckets and on folders, in any mix.

``` r

# A bucket alone
st <- store_connect("gs://my-bucket/store")

# A bucket as primary, a local copy for fast reads
st <- store_connect("gs://my-bucket/store", secondary = "~/data/my-store")

# Two buckets and a local copy
st <- store_connect("gs://my-bucket/store",
  secondary = c("~/data/my-store", "gs://other-bucket/store")
)

# A new, empty store in a bucket
store_create("gs://my-bucket/new-store")
```

Data are streamed: a read with filters fetches only the files and blocks
of rows it needs, without downloading whole datasets.

### Authentication

Three clients talk to Google Cloud Storage, and each finds its
credentials on its own.

- **Arrow** reads data and copies files. It uses Google’s default
  credentials: the key file named by the environment variable
  `GOOGLE_APPLICATION_CREDENTIALS` (a service account), or the
  credentials written by `gcloud auth application-default login`, or, on
  Google Cloud machines, those of the machine. The installed arrow
  package must support GCS:
  [`arrow::arrow_with_gcs()`](https://arrow.apache.org/docs/r/reference/arrow_info.html)
  returns `TRUE`.
- **The storage JSON API** reads the MD5 checksums of stored files, so
  that files need not be downloaded to be verified. It needs the
  packages gargle and httr2 and uses the same credentials as Arrow.
- **GDAL** reads rasters through its `/vsigs/` path. It does not find
  the credentials of `gcloud auth application-default login` by itself.
  Set `GOOGLE_APPLICATION_CREDENTIALS` to a service-account key, or to
  the credentials file that `gcloud` wrote, or set
  `GS_OAUTH2_REFRESH_TOKEN`, `GS_OAUTH2_CLIENT_ID` and
  `GS_OAUTH2_CLIENT_SECRET`.

For a personal account, one setup covers all three: log in once in a
terminal, then point the variable to the file it wrote, for example in
`.Renviron`:

    # after: gcloud auth application-default login
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/application_default_credentials.json

For a service account, point the same variable to its key file instead.

When a location cannot be reached, the error lists what each client
needs. A primary that cannot be reached stops
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
with that list; a secondary gives a warning that includes it.

## History per connection

Whether replaced versions are kept is a setting of the store
(`store_create(history = )`), which a connection can override for its
own writes, and a dataset for itself (see
[`vignette("rcs")`](https://ebukin.github.io/rcs/articles/rcs.md)). This
store keeps no history by default; a connection can keep it for its own
writes:

``` r

st_keep <- store_connect(primary, secondary = copy_1, history = TRUE)
st_keep
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#> History: on (this connection; store default off)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1
#>   sales/
#>     daily  table   300  31.2 kB      2  2026-11-21 21:57  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```
