# Bring the locations of a store into step

Copies datasets from one location, the source (by default the primary),
to the other locations of the connection: every dataset whose copy in a
target differs from the source's (another version, or another entry) or,
where the scope below allows it, is missing. Only the files a target
lacks are sent, each verified by MD5; the catalogs of a target are
switched last, so that its readers always see a complete version. A
geospatial dataset's index table travels with it.

## Usage

``` r
store_sync(
  st,
  datasets = NULL,
  all = FALSE,
  to = NULL,
  from = NULL,
  delete = FALSE,
  force = FALSE,
  dry_run = FALSE
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place.

- datasets:

  `NULL` for every dataset of the source, or names of datasets (full
  names, or last parts that are unique in the source). With
  `delete = TRUE` it restricts the deletions too, and a full name the
  source does not hold is accepted.

- all:

  `TRUE` copies every dataset of the source to every target, including
  datasets a secondary does not hold, but not the datasets kept in the
  primary only (see "Scope"). `FALSE` (the default) refreshes in a
  secondary only the datasets it already holds (see "Scope"). Cannot be
  combined with `datasets`.

- to:

  `NULL` for every location other than the source, or the addresses of
  some of them.

- from:

  `NULL` for the primary, or the address of the location to copy from.

- delete:

  `TRUE` deletes from each target the datasets the source does not hold.

- force:

  `TRUE` copies over versions that are newer in a target, and lets
  `delete = TRUE` delete datasets from the primary.

- dry_run:

  `TRUE` reports what would be copied, deleted and found in conflict,
  and changes nothing.

## Value

A tibble, invisibly, one row per target location: `location`, `status`
(`"synced"`, `"same"` when nothing was copied or deleted, `"conflict"`
when the target holds a newer version of a dataset, `"behind"` when it
failed, `"unavailable"`, or `"to sync"` with `dry_run = TRUE`), the list
columns `datasets` (copied, or to copy), `deleted` (deleted, or to
delete), `kept` (not deleted from the primary without `force`) and
`conflicts`; then the datasets left out by the scope (those kept in the
primary only included): `skipped` (a list column of names),
`skipped_files` and `skipped_bytes` (the files of those datasets the
target lacks, and their size: at most what `all = TRUE` would send);
then `files` (files sent, or to send), `bytes` and `seconds`. A status
of `"same"` can go with skipped datasets.

## Details

With `from` set to a secondary location, work done there (for example
through a connection whose primary was that location, while the primary
could not be reached) is brought to the primary and to the other
secondaries.

## Scope

By default (`datasets = NULL`, `all = FALSE`) a secondary location
receives only the datasets it already holds, at any version: they are
brought to the source's version, and nothing new is copied there. The
call says which datasets were not copied to each secondary, with the
number of files and the bytes a full sync would send at most (an empty
secondary is named as such). `all = TRUE` copies every dataset of the
source, except the datasets kept in the primary only
(`store_write(locations = "primary")`) to a secondary that does not hold
them; they are listed apart among the datasets not copied. `datasets = `
copies the named datasets, whether or not a secondary holds them, those
kept in the primary only included (the copy keeps that setting). A
secondary that holds a primary-only dataset gets it refreshed like any
other dataset it holds. The primary, as a target (`from` a secondary),
always receives every dataset of the source.

## Conflicts

When a target holds another version of a dataset and its entry was
updated later than the source's (the times recorded in the catalogs),
the dataset is not copied there: it is a conflict. Every other copy and
deletion goes ahead; after the last target the call aborts with class
`rcs_error_sync_conflict`, listing the conflicts, and the condition's
field `result` holds the result tibble. `force = TRUE` copies the source
over the newer version instead. Every version of a target that is
replaced by another one is listed in one warning (class
`rcs_warning_sync_overwrite`). The times compared are those of the
machines that wrote; their clocks may differ.

## Deletions

By default `store_sync()` never deletes a dataset: datasets found only
in a target are left alone (see
[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md),
status `"extra"`). With `delete = TRUE` they are deleted from that
target, with their index table, after its copies, as
[`store_delete()`](https://ebukin.github.io/rcs/reference/store_delete.md)
does for one location (the history kept). The primary is a target only
when `from` is a secondary; datasets are deleted there only with
`force = TRUE`, and are otherwise reported in the result column `kept`.
Files of a version a target replaces are deleted when the dataset keeps
no history, as in
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

A target that fails is reported as behind with a warning, and the next
one is synced; running the call again sends only what is still missing.

## See also

[`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md)
to compare the locations,
[`store_copy()`](https://ebukin.github.io/rcs/reference/store_copy.md)
for one dataset between any two locations;
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md)
for syncs from a secondary, conflicts and deletions.

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
#>   files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.

# A connection with a secondary location that missed the write
st <- store_connect(file.path(root, "primary"),
  secondary = file.path(root, "copy")
)
#> ℹ Secondary /tmp/Rtmp/rcs-example-sync/copy is
#>   empty.
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `store_sync(st,
#>   datasets = )` to copy some.
store_status(st)
#> Source: /tmp/Rtmp/rcs-example-sync/primary
#> Locations: [1] /tmp/Rtmp/rcs-example-sync/copy
#> # A tibble: 1 × 8
#>   dataset     location status  newer primary_version  location_version
#>   <chr>       <chr>    <chr>   <chr> <chr>            <chr>           
#> 1 sales/daily [1]      missing NA    0f9e01793cbea58a NA              
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>

# The secondary is empty: a default sync copies nothing and says so
store_sync(st)
#> ℹ Syncing the datasets already held by each secondary location, from the
#>   primary /tmp/Rtmp/rcs-example-sync/primary
#>   to 1 secondary location.
#> ✔ secondary  /tmp/Rtmp/rcs-example-sync/copy     nothing
#>   copied
#> ℹ Synced only the datasets already in each secondary location.
#> ℹ /tmp/Rtmp/rcs-example-sync/copy is empty: 1
#>   dataset not copied (2 files, 23.8 kB).
#>   Use `store_sync(st, all = TRUE)` to copy every dataset, or `datasets = ` to
#>   copy some.

# Every dataset
store_sync(st, all = TRUE, dry_run = TRUE)
#> ℹ Dry run: nothing is changed.
#> ℹ Syncing 1 dataset from the primary
#>   /tmp/Rtmp/rcs-example-sync/primary to 1
#>   secondary location.
#> • secondary  /tmp/Rtmp/rcs-example-sync/copy     would
#>   copy 1 dataset, 2 files (23.8 kB): "sales/daily"
store_sync(st, all = TRUE)
#> ℹ Syncing 1 dataset from the primary
#>   /tmp/Rtmp/rcs-example-sync/primary to 1
#>   secondary location.
#> ✔ secondary  /tmp/Rtmp/rcs-example-sync/copy     1
#>   dataset, 2/2 files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files sent to 1 location. Catalogs updated.

# Work done on the secondary alone, brought back to the primary
offline <- store_connect(file.path(root, "copy"))
store_write(offline, rcs_sim_table(50, seed = 2), "sales/weekly",
  title = "Weekly sales", description = "Simulated weekly sales."
)
#> ℹ Writing "sales/weekly": 50 rows in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-sync/copy  1/1
#>   files sent  11.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_sync(st, from = file.path(root, "copy"))
#> ℹ Syncing 2 datasets from the secondary
#>   /tmp/Rtmp/rcs-example-sync/copy to 1
#>   location.
#> ✔ primary    /tmp/Rtmp/rcs-example-sync/primary  1
#>   dataset, 1/1 files sent  11.7 kB  0.2s
#> ✔ MD5 identical for 1 file sent to 1 location. Catalogs updated.
store_status(st)
#> Source: /tmp/Rtmp/rcs-example-sync/primary
#> Locations: [1] /tmp/Rtmp/rcs-example-sync/copy
#> # A tibble: 2 × 8
#>   dataset      location status newer primary_version  location_version
#>   <chr>        <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily  [1]      same   NA    0f9e01793cbea58a 0f9e01793cbea58a
#> 2 sales/weekly [1]      same   NA    e8bcbde15b3cbebc e8bcbde15b3cbebc
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
unlink(root, recursive = TRUE)
```
