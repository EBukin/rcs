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
#> ✔ primary    <tempdir>/locations/primary  2/2 files sent  27.9 kB  0.2s
#> ✔ secondary  <tempdir>/locations/copy-1   2/2 files sent  27.9 kB  0.1s
#> ✔ secondary  <tempdir>/locations/copy-2   2/2 files sent  27.9 kB  0.1s
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
#>     daily  table   200  27.9 kB      2  2026-11-27 23:53  =  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

## Reads use the closest copy

A read picks, among the locations that hold the dataset at the primary’s
version, a local folder first, then the primary, then the other
secondaries. With a bucket as primary and a local folder as secondary,
reads come from the local folder when it holds the primary’s version,
and a line says so:

``` r

st <- store_connect("gs://my-bucket/store", secondary = "~/data/my-store")
x <- store_read(st, "sales/daily")
#> ℹ Reading "sales/daily" from secondary ~/data/my-store.
```

`options(rcs.quiet = TRUE)` silences that line. When the local folder
lacks the dataset or holds an older version,
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
first copies the dataset there and then reads from the copy (see “Local
working copies of a bucket”). A secondary that is behind and is not
brought up to date that way, for example another bucket, is skipped, and
the read goes to the primary.

Here all three locations are local folders. The primary is local too, so
reads come from it, and a read never copies anything.

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
#>     daily  table   200  27.9 kB      2  2026-11-27 23:53  =  =
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
nothing can be read or written without the truth. For a secondary, it
depends on what goes wrong:

- The secondary cannot be reached (a network or credential error):
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
  gives a warning, marks it unavailable, and reads and writes skip it.
- The secondary answers but holds no catalogs (a local folder that does
  not exist, say):
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
  stops with an error of class `rcs_error_no_catalog`, as for a primary.
  With `create = TRUE` it sets the location up as a new, empty store
  instead.
- [`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
  reads the catalogs of a connection again. There, a secondary that
  cannot be reached or holds no catalogs only gives a warning and is
  marked unavailable.

To show this, the folder of the second copy is moved away, as if a drive
had been disconnected.
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
reads the catalogs of all locations again, notices, and warns.

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
#> ✔ primary    <tempdir>/locations/primary  2/2 files sent  31.3 kB  0.1s
#> ✔ secondary  <tempdir>/locations/copy-1   2/2 files sent  31.3 kB  0.2s
#> ! secondary  <tempdir>/locations/copy-2   unavailable, skipped
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.
#> ! 1 secondary location is behind; run `store_sync(st, datasets = "sales/daily")` to bring it up to date, or
#>   `store_sync(st, all = TRUE)` for every dataset.
```

The message names the call that repairs it later:
`store_sync(st, datasets = "sales/daily")`, or
`store_sync(st, all = TRUE)` for every dataset. Name the dataset: a
plain
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
refreshes only the datasets a secondary already holds (see “Bringing
secondaries up to date”), so it would not copy a new dataset whose first
write missed that secondary.

If a secondary fails during a write (a network error, say), the write
goes on with the next location and reports the failed one as behind in
the same way, with the same hint. Only a failure in the primary stops a
write, and then no catalog of any location has changed.

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
#>     daily  table   300  31.3 kB      2  2026-11-27 23:53  =  ≠
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
`differs`, `newer` says which side was written last: `"source"` (the
primary here) or `"target"` (the location of the row). It is a hint
only, as clocks of different machines can differ. Printed, the source is
named first, and the addresses of the other locations are listed once
above the table and numbered in the column `location`.

``` r

store_status(st)
#> Source: <tempdir>/locations/primary
#> Locations: [1] <tempdir>/locations/copy-1
#>            [2] <tempdir>/locations/copy-2
#> # A tibble: 4 × 8
#>   dataset      location status  newer  primary_version  location_version
#>   <chr>        <chr>    <chr>   <chr>  <chr>            <chr>           
#> 1 sales/daily  [1]      same    NA     0f1993a2e5855aa8 0f1993a2e5855aa8
#> 2 sales/weekly [1]      missing NA     72f66b800c3fa743 NA              
#> 3 sales/daily  [2]      differs source 0f1993a2e5855aa8 41ec22ed5b5602ce
#> 4 sales/weekly [2]      missing NA     72f66b800c3fa743 NA              
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
```

`from` compares every other location, the primary included, with one of
the secondaries instead. The columns keep their names: `primary_version`
and `primary_updated` then describe that source.

``` r

store_status(st, from = copy_2)[c("dataset", "location", "status", "newer")]
#> Source: <tempdir>/locations/copy-2
#> Locations: [1] <tempdir>/locations/primary
#>            [2] <tempdir>/locations/copy-1
#> # A tibble: 3 × 4
#>   dataset      location status  newer 
#>   <chr>        <chr>    <chr>   <chr> 
#> 1 sales/daily  [1]      differs target
#> 2 sales/weekly [1]      extra   NA    
#> 3 sales/daily  [2]      differs target
```

A copy that is behind is never read: reads go to a location that holds
the primary’s version. The next write of a dataset brings every
available secondary up to date for that dataset, whatever version it
held.

## Bringing secondaries up to date

[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
copies datasets from one location, the *source*, to the others, the
*targets*: by default from the primary to every secondary. Like a write,
it copies only the files a location lacks, checks each by MD5 and
switches the catalog last. By default it never deletes a dataset.
`dry_run = TRUE` shows what it would do and changes nothing.

A plain
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
refreshes in each secondary only the datasets it already holds, at
whatever version: a local copy that holds a few datasets of a large
bucket stays small. It then says which datasets it did not copy to each
secondary, and how many files and bytes a full sync would send there at
most. Here both copies lack `sales/weekly`, and the second copy holds an
old version of `sales/daily`:

``` r

store_sync(st, dry_run = TRUE)
#> ℹ Dry run: nothing is changed.
#> ℹ Syncing the datasets already held by each secondary location, from the primary
#>   <tempdir>/locations/primary to 2 secondary locations.
#> ✔ secondary  <tempdir>/locations/copy-1   nothing copied
#> • secondary  <tempdir>/locations/copy-2   would copy 1 dataset, 2 files (31.3 kB):
#>   "sales/daily"
#> ℹ Synced only the datasets already in each secondary location.
#> ℹ <tempdir>/locations/copy-1: 1 dataset not copied (1 file, 11.7 kB).
#> ℹ <tempdir>/locations/copy-2: 1 dataset not copied (1 file, 11.7 kB).
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `datasets = ` to copy some.
```

`to` limits the sync to some secondaries. Here only the second copy is
brought up to date, for the dataset it holds:

``` r

store_sync(st, to = copy_2)
#> ℹ Syncing the datasets already held by each secondary location, from the primary
#>   <tempdir>/locations/primary to 1 secondary location.
#> ✔ secondary  <tempdir>/locations/copy-2   1 dataset, 2/2 files sent  31.3 kB  0.2s
#> ℹ Synced only the datasets already in each secondary location.
#> ℹ <tempdir>/locations/copy-2: 1 dataset not copied (1 file, 11.7 kB).
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `datasets = ` to copy some.
#> ✔ MD5 identical for 2 files sent to 1 location. Catalogs updated.
#> Warning: `store_sync()` replaced 1 version held by the target locations:
#> • '<tempdir>/locations/copy-2': "sales/daily" version 41ec22ed5b5602ce (updated
#>   2026-11-27 23:53:53) replaced by version 0f1993a2e5855aa8 (updated 2026-11-27 23:53:55).
```

`datasets` names the datasets to copy, whether a secondary holds them or
not, and `all = TRUE` copies every dataset of the source:

``` r

store_sync(st, datasets = "sales/weekly", to = copy_2)
#> ℹ Syncing 1 dataset from the primary <tempdir>/locations/primary to 1 secondary
#>   location.
#> ✔ secondary  <tempdir>/locations/copy-2   1 dataset, 1/1 files sent  11.7 kB  0.1s
#> ✔ MD5 identical for 1 file sent to 1 location. Catalogs updated.
```

A sync to the primary, with `from` set to a secondary (see “Syncing from
a secondary”), always sends every dataset there.

A secondary that holds no dataset at all is announced when you connect,
so that you can decide how much of the store to copy there:

``` r

copy_3 <- file.path(root, "copy-3")
st_new <- store_connect(primary, secondary = copy_3, create = TRUE)
#> ℹ Secondary <tempdir>/locations/copy-3 is empty.
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `store_sync(st, datasets = )` to copy some.
```

A plain `store_sync(st_new)` would copy nothing there; `all = TRUE`
fills it:

``` r

store_sync(st_new, all = TRUE)
#> ℹ Syncing 2 datasets from the primary <tempdir>/locations/primary to 1 secondary
#>   location.
#> ✔ secondary  <tempdir>/locations/copy-3   2 datasets, 3/3 files sent  43.0 kB  0.2s
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
#> Source: <tempdir>/locations/primary
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

To check that a copy is sound, `store_check(st, dataset)` checks the
dataset’s files in every available location. `locations` limits the
check to some of them, for example
`store_check(st, "sales/daily", locations = copy_2)`.

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

## Local working copies of a bucket

With a bucket as primary, a local secondary is a **working copy**: it
holds the datasets you read, so that later reads are fast and work
without a network.

``` r

st <- store_connect("gs://my-bucket/store", secondary = "~/data/my-store")
x <- store_read(st, "sales/daily")
```

When the local folder lacks `sales/daily`, or holds an older version of
it,
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
first copies the current version of the whole dataset there, with its
index table, and then reads from the copy. As in a sync, only the files
the folder lacks are sent, each checked by its MD5, with a progress bar.
The read says what it copied:

    ℹ Copying "sales/daily" (version 3f9a1c0d2b4e5f60, 2 files, 41.2 kB) from 'gs://my-bucket/store' to '~/data/my-store' before reading.
    ✔ 2/2 files sent to '~/data/my-store' (41.2 kB) in 0.8s, MD5 verified.
    ℹ Reading "sales/daily" from secondary ~/data/my-store.

The next read of `sales/daily` copies nothing and reads from the folder.
After a new write on the bucket, the next read copies the new version,
again sending only the files that changed. Filters, `columns` and
`intersects` do not change this: the whole dataset is copied, and the
filter is applied to the copy. With several local secondaries, each one
gets the copy, and each file is downloaded once.

When the folder holds the current version but another catalog entry of
it (a raster whose legend or colours were written again for the same
cells, say), the read updates only the entry and sends no file, whatever
the limit below:

    ℹ Updating the catalog entry of "sales/daily" in '~/data/my-store' to the primary's (version 3f9a1c0d2b4e5f60, no file sent).

A read copies only:

- to secondaries that are local folders and can be reached, and only
  when the primary is not local. Secondaries in buckets never get a copy
  from a read, and with a local primary a read copies nothing;
- the current version of a dataset;
- when the bytes to download are at or under a limit: 2 GB by default,
  set by `options(rcs.copy_on_read_max_bytes = )` in bytes.

Above the limit nothing is copied. The read then fetches only what it
needs from the bucket, and says how to copy:

    ℹ "sales/daily" needs 3.4 GB, above the 2.0 GB limit for copying on read (`rcs.copy_on_read_max_bytes`). Reading from 'gs://my-bucket/store'.
      Use `copy = TRUE`, or `store_sync(st, datasets = "sales/daily")`, to copy it.

`copy` controls one read, and `copy_on_read` the whole connection:

``` r

# Copy whatever the size
x <- store_read(st, "sales/daily", copy = TRUE)

# Never copy, read from the bucket
x <- store_read(st, "sales/daily", copy = FALSE)

# Never copy on this connection, unless a read says copy = TRUE
st <- store_connect("gs://my-bucket/store",
  secondary = "~/data/my-store",
  copy_on_read = FALSE
)
```

With copying turned off, no message about copying is printed, and a
local folder that already holds the current version is still read from.

Earlier versions (`version =`) are not copied. When such a read comes
from the bucket, it says so:

    ℹ Read version 3f9a1c0d2b4e5f60 of "sales/daily" from 'gs://my-bucket/store'; old versions are not copied to secondary locations.
      Use `copy = TRUE` to copy it.

With `copy = TRUE` the version is added to the history of the local
secondaries that lack it; their current version of the dataset does not
change.

A local secondary whose version of a dataset was written later than the
primary’s (by a connection to that folder alone, say) is never replaced
by a read. It is left as it is and not read from, and a line says so:

    ! '~/data/my-store' holds a newer version of "sales/daily"; it is not replaced. See `store_sync()`.

A copy that fails (a network error, say) gives a warning, and the read
goes on from the bucket; the next read tries again.
[`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md),
[`store_glimpse()`](https://ebukin.github.io/rcs/reference/store_glimpse.md),
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
and
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
never copy: they read from the local folder when it already holds the
current version, and from the bucket otherwise. Reading an index table
never copies either.

Copying on read and syncing work together. A working copy holds the
datasets that were read, and a plain
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
refreshes exactly those (see “Bringing secondaries up to date”), so the
copy stays small however large the bucket is. `datasets =` copies some
more, and `all = TRUE` makes the folder a full copy of the store.

The stores of this vignette are local folders, primary included, so
their reads copy nothing. A new, empty secondary is announced when you
connect, and a read leaves it empty:

``` r

copy_4 <- file.path(root, "copy-4")
st_work <- store_connect(primary, secondary = copy_4, create = TRUE)
#> ℹ Secondary <tempdir>/locations/copy-4 is empty.
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `store_sync(st, datasets = )` to copy some.
x <- store_read(st_work, "sales/daily")
store_status(st_work)[c("dataset", "status")]
#> Source: <tempdir>/locations/primary
#> # A tibble: 1 × 2
#>   dataset     status 
#>   <chr>       <chr>  
#> 1 sales/daily missing
```

## Syncing from a secondary

Work can also start on a secondary: on a laptop without network, say, a
connection whose primary is the local copy writes there alone.

``` r

offline <- store_connect(copy_1)
store_write(offline, rcs_sim_table(80, seed = 4), "sales/monthly",
  title = "Monthly sales",
  description = "Simulated monthly sales."
)
#> ℹ Writing "sales/monthly": 80 rows in 1 file.
#> ✔ primary  <tempdir>/locations/copy-1  1/1 files sent  13.1 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
```

Back on the full connection, `from` names the location to sync from. The
targets are then every other location, the primary included; `to` limits
them as before. The primary receives every dataset of the source, here
the new `sales/monthly`. The second copy, a secondary, would only have
its own datasets refreshed and would not get `sales/monthly`;
`all = TRUE` sends it there too:

``` r

store_refresh(st)
store_sync(st, from = copy_1, all = TRUE)
#> ℹ Syncing 2 datasets from the secondary <tempdir>/locations/copy-1 to 2 locations.
#> ✔ primary    <tempdir>/locations/primary  1 dataset, 1/1 files sent  13.1 kB  0.2s
#> ✔ secondary  <tempdir>/locations/copy-2   1 dataset, 1/1 files sent  13.1 kB  0.1s
#> ✔ MD5 identical for 2 files sent to 2 locations. Catalogs updated.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  <tempdir>/locations/primary
#>   secondary 1  local  <tempdir>/locations/copy-1
#>   secondary 2  local  <tempdir>/locations/copy-2
#> History: off (store default)
#> Datasets: 2
#>   name       kind   rows     size  files  updated           1  2
#>   sales/
#>     daily    table   300  31.3 kB      2  2026-11-27 23:53  =  =
#>     monthly  table    80  13.1 kB      1  2026-11-27 23:54  =  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

## Conflicts

A dataset may have changed on both sides: here `sales/daily` is written
through a connection to the primary alone, and later through the
connection to the first copy alone.

``` r

store_write(only_primary, rcs_sim_table(120, seed = 5), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year",
  mode = "replace"
)
#> ℹ Replacing "sales/daily": 120 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/locations/primary  2/2 files sent  24.7 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
Sys.sleep(1)
store_write(offline, rcs_sim_table(140, seed = 6), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year",
  mode = "replace"
)
#> ℹ Replacing "sales/daily": 140 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/locations/copy-1  2/2 files sent  25.8 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_refresh(st)
```

A sync from the primary finds that the first copy holds another version
that was written *later* than the primary’s: a **conflict**. That
dataset is not copied there. Everything else goes ahead (here the second
copy, which held an older version, gets the primary’s, and a warning
lists the version it replaced); after the last target the call stops
with an error of class `rcs_error_sync_conflict` that lists every
conflict. The condition’s field `result` holds the result table, so a
script can inspect it.

``` r

store_sync(st)
#> ℹ Syncing the datasets already held by each secondary location, from the primary
#>   <tempdir>/locations/primary to 2 secondary locations.
#> ✖ secondary  <tempdir>/locations/copy-1   1 conflict, newer here: "sales/daily"
#> ✔ secondary  <tempdir>/locations/copy-2   1 dataset, 2/2 files sent  24.7 kB  0.2s
#> ✔ MD5 identical for 2 files sent to 1 location. Catalogs updated.
#> Warning: `store_sync()` replaced 1 version held by the target locations:
#> • '<tempdir>/locations/copy-2': "sales/daily" version 0f1993a2e5855aa8 (updated
#>   2026-11-27 23:53:55) replaced by version 98d066b5654644d4 (updated 2026-11-27 23:54:02).
#> Error in `store_sync()`:
#> ! 1 dataset was not copied: the target holds a newer version.
#> ✖ '<tempdir>/locations/copy-1': "sales/daily" version 7f31826d9513c336 (updated
#>   2026-11-27 23:54:03) is newer than the source's version 98d066b5654644d4 (updated 2026-11-27 23:54:02).
#> ℹ The other copies and deletions were made.
#> ℹ Run with `force = TRUE` to copy the source over it, or sync from the location that holds the newer version.
```

Conflicts are detected by the times of the last writes recorded in the
catalogs, which come from the clocks of the machines that wrote. Decide
which version to keep: to keep the primary’s, `force = TRUE` copies it
over the newer one, and the warning names the version that was replaced.
To keep the copy’s, sync from the copy instead.

``` r

store_sync(st, force = TRUE)
#> ℹ Syncing the datasets already held by each secondary location, from the primary
#>   <tempdir>/locations/primary to 2 secondary locations.
#> ✔ secondary  <tempdir>/locations/copy-1   1 dataset, 2/2 files sent  24.7 kB  0.2s
#> ✔ secondary  <tempdir>/locations/copy-2   up to date
#> ✔ MD5 identical for 2 files sent to 1 location. Catalogs updated.
#> Warning: `store_sync()` replaced 1 version held by the target locations:
#> • '<tempdir>/locations/copy-1': "sales/daily" version 7f31826d9513c336 (updated
#>   2026-11-27 23:54:03) replaced by version 98d066b5654644d4 (updated 2026-11-27 23:54:02).
```

When the source is the newer side, the copy goes ahead without `force`;
the warning (class `rcs_warning_sync_overwrite`) still lists every
target version that was overwritten.

## Deletions

A dataset deleted in one location stays in the others:
[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md)
shows it there as `extra`, and a sync leaves it alone. `delete = TRUE`
deletes from each target the datasets the source no longer holds, with
their index tables, after the copies; history versions are kept, as with
`store_delete(history = FALSE)`. `datasets` limits the deletions too.

Here `sales/monthly` is deleted on the first copy only, then the
deletion is synced from there:

``` r

store_delete(offline, "sales/monthly", confirm = "sales/monthly")
#> ℹ Deleting "sales/monthly" and its index table from every location, keeping its history.
#> ✔ primary  <tempdir>/locations/copy-1  2 files deleted  13.1 kB
#> ✔ "sales/monthly" is removed from 1 location.
store_refresh(st)
store_sync(st, from = copy_1, delete = TRUE)
#> ℹ Syncing the datasets already held by each secondary location, from the secondary
#>   <tempdir>/locations/copy-1 to 2 locations.
#> ! primary    <tempdir>/locations/primary  1 dataset kept, delete on primary needs
#>   force: "sales/monthly"
#> ✔ secondary  <tempdir>/locations/copy-2   1 dataset deleted: "sales/monthly"
#> ✔ 1 dataset deleted in 1 location.
#> ! 1 dataset kept in the primary: delete on primary needs force (`force = TRUE`).
```

The second copy lost the dataset, but the primary kept it: deleting from
the primary, the truth of the store, also needs `force = TRUE`. Until
then the result lists it in the column `kept`.

``` r

store_sync(st, from = copy_1, delete = TRUE, force = TRUE)
#> ℹ Syncing the datasets already held by each secondary location, from the secondary
#>   <tempdir>/locations/copy-1 to 2 locations.
#> ✔ primary    <tempdir>/locations/primary  1 dataset deleted: "sales/monthly"
#> ✔ secondary  <tempdir>/locations/copy-2   up to date
#> ✔ 1 dataset deleted in 1 location.
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
#>     daily  table   120  24.7 kB      2  2026-11-27 23:54  =  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```

Deletions run also when conflicts were found, and are reported with
them.

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
of rows it needs, without downloading whole datasets. The exception is a
local secondary of a bucket: there
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
first copies the whole dataset to the local folder, up to a size limit,
and then reads from the copy (see “Local working copies of a bucket”).

### Credentials

Four clients of the package talk to Google Cloud Storage: **Arrow**
reads data and copies files (the installed arrow package must support
GCS:
[`arrow::arrow_with_gcs()`](https://arrow.apache.org/docs/r/reference/arrow_info.html)
returns `TRUE`); the **storage JSON API** reads the MD5 checksums of
stored files, so that files need not be downloaded to be verified (it
needs the packages gargle and httr2); **GDAL** reads rasters through its
`/vsigs/` path; and **DuckDB** reads data files when a store is opened
in DuckDB (see
[`vignette("duckdb")`](https://ebukin.github.io/rcs/articles/duckdb.md)).
They all get their credentials from the connection: set them once, with
the argument `auth` of
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
or
[`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md),
and every client uses them. No environment variable is needed or
changed.

Without `auth`, every bucket location uses
[`rcs_auth_gcs()`](https://ebukin.github.io/rcs/reference/rcs_auth_gcs.md),
the default lookup. It is a chain in which the first variable that is
set decides; it does not fall through to the next step:

1.  when the environment variable `GOOGLE_APPLICATION_CREDENTIALS` is
    set, the key file it names, and only that file: a missing file is an
    error (class `rcs_error_backend`);
2.  else, when `CLOUDSDK_CONFIG` is set,
    `application_default_credentials.json` in that folder only; gcloud’s
    own folder is not tried;
3.  else the same file in gcloud’s own folder (`%APPDATA%/gcloud` on
    Windows, `~/.config/gcloud` elsewhere), written once by
    `gcloud auth application-default login`;
4.  when the file of step 2 or 3 does not exist, *ambient* credentials:
    Arrow and the JSON API use Google’s own defaults, such as the
    machine’s account on Google Cloud. GDAL and DuckDB cannot use these.

For a personal account, the usual setup is therefore one command in a
terminal, once per machine, and nothing in R:

    gcloud auth application-default login

[`rcs_auth_gcs()`](https://ebukin.github.io/rcs/reference/rcs_auth_gcs.md)
also takes a credential explicitly: `key` is a JSON key file, of a
service account or of a user login; `token` is an access token obtained
elsewhere; `fun` is a function that returns a fresh token each time it
is called. `auth` accepts such an object, the path of a key file, or a
list named by address that gives each location its own credential
(locations left out use the default lookup):

``` r

# A service account for every bucket of the connection
st <- store_connect("gs://my-bucket/store",
  auth = rcs_auth_gcs(key = "~/keys/reader.json")
)

# The same, with the path alone
st <- store_connect("gs://my-bucket/store", auth = "~/keys/reader.json")

# One credential per location
st <- store_connect("gs://my-bucket/store",
  secondary = c("~/data/my-store", "gs://other-bucket/store"),
  auth = list(
    "gs://my-bucket/store" = "~/keys/reader.json",
    "gs://other-bucket/store" = rcs_auth_gcs(fun = my_token_function)
  )
)
```

Tokens of a key file or a function are renewed five minutes before they
expire, so a long session never needs to sign in again; a `token` given
directly cannot be renewed and lasts as long as its issuer allows,
usually an hour. Asking for the same source twice gives the same object,
with its token. Printing a credential never contacts the network and
never shows a secret; the identity (the account’s e-mail) is known after
the first token:

``` r

rcs_auth_gcs(token = "<an access token>")
#> <rcs_auth_gcs>
#> Source:   an access token given to rcs_auth_gcs(token = )
#> Identity: known after the first token
#> Token:    given by the caller, not renewed
```

Credentials are never written to files, catalogs or logs, nor put in
environment variables, with one exception: **GDAL’s options are
process-wide**. Reading a raster from a bucket gives GDAL the credential
of that location (the three `GS_OAUTH2_*` options for a user login,
`GOOGLE_APPLICATION_CREDENTIALS` as a GDAL option for a service account,
an `Authorization` header for a token or a function), and it applies to
every GDAL read in the R process. Reading rasters through two
connections with different credentials therefore switches GDAL from one
to the other; the first switch warns (class
`rcs_warning_gdal_credential`), because a raster opened with the
previous credential reads its tiles lazily and may fail on its next
read. Also, GDAL remembers a failed open: after a credential problem is
fixed, a raster that failed may need a new R session.

DuckDB gets a temporary secret in its own connection, made from the
location’s token. A secret holds a token, not a key: after about an hour
of DuckDB work on a bucket, call
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
again to refresh it.

[`store_auth_check()`](https://ebukin.github.io/rcs/reference/store_auth_check.md)
tries each client on each location with a small probe and reports,
without stopping, which work. Local folders need no credentials; each
local location gives one row (the column `location`, the address, is
left out here):

``` r

store_auth_check(st)[c("client", "ok", "note")]
#> # A tibble: 3 × 3
#>   client ok    note                               
#>   <chr>  <lgl> <chr>                              
#> 1 all    TRUE  local folder: no credentials needed
#> 2 all    TRUE  local folder: no credentials needed
#> 3 all    TRUE  local folder: no credentials needed
```

On a bucket it gives one row per client: Arrow and the JSON API look up
the catalog file, GDAL opens the first raster of the location (`ok` is
`NA` when there is none), and DuckDB counts the rows of the catalog
(`NA` when duckdb is not installed):

``` r

st <- store_connect("gs://my-bucket/store")
store_auth_check(st)
```

When a location cannot be reached, the error names the credential in use
and how to pass another one with `auth`. A primary that cannot be
reached stops
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md);
a secondary that cannot be reached gives a warning and is skipped (see
“A secondary that cannot be reached”).

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
#>     daily  table   120  24.7 kB      2  2026-11-27 23:54  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
```
