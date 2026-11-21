# Write a dataset to a store

Writes a table, an `sf` object or a
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
as one dataset of the store, in the primary location and in every
available secondary one. The files are staged locally, checked, uploaded
where they are missing, verified by MD5, and the catalogs of each
location are switched to the new version last, so that readers always
see either the old or the new version.

## Usage

``` r
store_write(
  st,
  x,
  dataset,
  title,
  description,
  key = NULL,
  partition = NULL,
  mode = c("create", "replace", "update"),
  h3_res = 5L,
  geocode = TRUE,
  max_files = 50L,
  history = NULL,
  source = NULL,
  inputs = NULL,
  columns = NULL,
  check = TRUE,
  rows_per_group = 50000L
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place, so that it can be used for further writes
  without refreshing.

- x:

  The data: a data frame, an `sf` object or a
  [`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html).

- dataset:

  The dataset's full name: lower-case letters, digits and `_`, with `/`
  between folders, e.g. `"sales/daily"`.

- title, description:

  Short title and description, required.

- key:

  Columns that identify the rows, or `NULL`. Their values must be unique
  together.

- partition:

  `NULL` for one file; column names to write one file per combination of
  their values; or `"h3"` (geospatial data) to partition by the H3
  parent cell at the finest resolution that gives at most `max_files`
  files.

- mode:

  `"create"`, `"replace"` or `"update"` (see "Modes").

- h3_res:

  H3 resolution of the geocodes, 0 to 15.

- geocode:

  `FALSE` writes geospatial data without H3 cells and without index
  table; spatial reads then use bounding boxes only.

- max_files:

  Most partition files.

- history:

  `TRUE` or `FALSE` sets the dataset's history setting; `NULL` leaves it
  as it is.

- source, inputs:

  Optional provenance: where the data come from and what they were made
  from.

- columns:

  Named character vector, column (or layer) name to description. `NULL`
  keeps the descriptions already stored for columns that still exist.

- check:

  `TRUE` compares sampled rows of the staged files with `x` before
  anything is uploaded (see
  [`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md)).

- rows_per_group:

  Rows per Parquet row group.

## Value

A tibble with one row per location, invisibly: `location`, `role`,
`status` (`"written"`, `"unchanged"`, `"same"` for a secondary that
already held the version, `"behind"` or `"unavailable"`), `files` (files
of the version), `uploaded` (files sent), `bytes` (bytes sent) and
`seconds`. The attribute `version` holds the dataset's version.

## Kinds

The kind is set by the class of `x`: an `sf` object is `geospatial`, a
`SpatRaster` is a `raster`, any other data frame is a `table`.

- Geospatial data get the columns `.rcs_id` (row identifier), `h3` (the
  H3 cell at `h3_res` holding the largest part of each geometry; not
  with `geocode = FALSE`) and `bbox` (bounding box), and are sorted by
  `h3`. Rows that cross H3 cells are listed in an index table
  `<dataset>__h3`, written, replaced and removed with the dataset.

- A raster is written as one Cloud Optimized GeoTIFF; it cannot be
  partitioned or updated.

## Modes

- `"create"`: the dataset must not exist yet.

- `"replace"`: the whole dataset is replaced by `x`; columns, key,
  partitioning and kind may change. A dataset that does not exist yet is
  created.

- `"update"`: for partitioned datasets only. The partitions whose values
  occur in `x` are replaced entirely by the rows of `x`; the other
  partitions are kept; new values add partitions. The columns and their
  types must equal the stored ones, and the key must stay unique across
  the whole dataset. A message lists every replaced partition with its
  old and new number of rows: rows of a replaced partition that are
  missing from `x` disappear. In this mode `key`, `partition`, `h3_res`
  and `geocode` come from the stored dataset; arguments that disagree
  abort. With `partition = "h3"`, an update that would need more than
  `max_files` files re-partitions the whole dataset at a coarser H3
  resolution.

Writing the same data again gives the same version: the call reports the
dataset as unchanged, uploads nothing to the primary, and only brings
secondary locations that differ up to date.

## History

Whether the replaced version is kept is decided by the dataset's own
setting (`history`, recorded in its catalog entry), else by the
connection's (`store_connect(history = )`), else by the store's default
([`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md)).
Without history, the files of the replaced version are deleted right
after the catalogs are switched; with history, they stay until
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
removes them.

## Failures

Every transfer is tried up to three times. If the primary fails before
its catalog is switched, the call aborts and no catalog has changed;
uploaded files are reused when the call is repeated (and removed by
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
otherwise). If a secondary fails, the call warns, continues with the
next location and reports the secondary as behind;
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
repairs it.

## See also

[`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md),
[`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md),
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-write")
st <- store_connect(
  file.path(root, "primary"),
  secondary = file.path(root, "copy"),
  create = TRUE
)
sales <- rcs_sim_table(200, seed = 1)
store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 200 rows in 2 files (partition year).
#> ✔ primary    C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/primary  2/2
#>   files sent  27.8 kB  0.2s
#> ✔ secondary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/copy     2/2
#>   files sent  27.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.

# The same data again: nothing is uploaded
store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"), partition = "year",
  mode = "replace"
)
#> ℹ "sales/daily" is unchanged (version e39540d1414c4708): 200 rows in 2 files
#>   (partition year).
#> ✔ primary    C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/primary  unchanged
#> ✔ secondary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/copy     up
#>   to date
#> ✔ All 2 locations hold this version.

# Replace one year
year_2024 <- sales[sales$year == 2024, ]
year_2024$qty <- year_2024$qty + 1L
store_write(st, year_2024, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  mode = "update"
)
#> ℹ Updating "sales/daily": 1 partition replaced, 0 added, 1 kept.
#> • year = 2024: 97 rows -> 97 rows
#> ℹ Writing "sales/daily": 200 rows in 2 files (partition year).
#> ✔ primary    C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/primary  1/2
#>   files sent  13.8 kB  0.2s
#> ✔ secondary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/copy     1/2
#>   files sent  13.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/primary
#>   secondary 1  local  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-write/copy
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1
#>   sales/
#>     daily  table   200  27.8 kB      2  2026-11-21 16:55  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
unlink(root, recursive = TRUE)
```
