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
  geocode_engine = c("auto", "s2", "planar"),
  max_files = 50L,
  history = NULL,
  source = NULL,
  inputs = NULL,
  columns = NULL,
  check = TRUE,
  rows_per_group = 50000L,
  crs = NULL
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It is updated in place, so that it can be used for further writes
  without refreshing.

- x:

  The data: a data frame, an `sf` object, a
  [`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html),
  or a lazy table on a DuckDB connection (see "DuckDB input").

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
  table (no engine is recorded); spatial reads then use bounding boxes
  only.

- geocode_engine:

  `"auto"`, `"s2"` or `"planar"`: how the H3 cells of geometries that
  cross cell edges are computed (see "Geocoding engines"); recorded with
  the dataset. An update uses the stored engine (a different one
  aborts); a dataset written without one geocodes new rows with `"s2"`.

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

- crs:

  The coordinate reference system of the column `geometry` of a lazy
  DuckDB table (anything
  [`sf::st_crs()`](https://r-spatial.github.io/sf/reference/st_crs.html)
  accepts, e.g. `4326`); required for such a table, ignored otherwise
  (an `sf` object carries its own).

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

- Prepared geospatial data
  ([`rcs_geo_add()`](https://ebukin.github.io/rcs/reference/rcs_geo_add.md),
  or rows read back with `collect()`) may hold these columns already:
  `.rcs_id` is dropped and assigned again; `h3` and `bbox` must equal
  what the write computes (else the write aborts naming the rows;
  prepare with the same `geocode_engine`, or call
  [`rcs_geo_strip()`](https://ebukin.github.io/rcs/reference/rcs_geo_add.md)
  first), and `h3_res`, when not given, is taken from the cells. Columns
  `h3_p<r>` are written as they are; with `partition = "h3"` one named
  as the chosen partition column must hold the same cells, and then
  serves as it. Raw and prepared data give the same version.

- A raster is written as one Cloud Optimized GeoTIFF; it cannot be
  partitioned or updated.

- A lazy table on a DuckDB connection is a `table`, or `geospatial` when
  it has a column `geometry` (see "DuckDB input").

## DuckDB input

`x` may be a lazy table on a DuckDB connection (from
[`dplyr::tbl()`](https://dplyr.tidyverse.org/reference/tbl.html), for
example on a view of
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md),
or from `store_open(engine = "duckdb")`), so that a result computed in
DuckDB is stored without being collected into R as a whole. Its query
runs once inside DuckDB into a temporary copy, the table
`rcs_write_<random>` on the same connection, which every later step
reads and which is dropped when the call ends, also after an error; the
copy needs room in DuckDB's memory or its temporary folder. The key and
the partitions are checked in DuckDB, and the rows are fetched in
batches of `getOption("rcs.duckdb_batch_rows")` rows (default `5e5`), so
that R holds about one batch at a time; a progress bar shows the batches
unless `options(rcs.quiet = TRUE)`. DuckDB never uploads: the files are
staged and land in every location as for any other write. The files
equal those written from the same rows collected into R, so both give
the same version.

- Modes `"create"` and `"replace"` only; `"update"` aborts (collect the
  rows and update from R, or write the whole dataset).

- Columns `.rcs_id`, `h3`, `bbox` and `geom` are the package's own: they
  are dropped with a message and computed again. Columns `h3_p<r>` are
  user columns.

- Types: integer, double, `VARCHAR`, `DATE` and `BOOLEAN` are stored as
  they are; `BIGINT` is stored as 64-bit integers read back as
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html);
  `TIMESTAMP` is stored without time zone (its wall clock) and
  `TIMESTAMP WITH TIME ZONE` in UTC. `HUGEINT`, `UHUGEINT`, `INTERVAL`,
  `UNION` and `MAP` columns abort, naming them; cast them in the query.
  DuckDB's [`sum()`](https://rdrr.io/r/base/sum.html) of an integer
  column is a `HUGEINT`: write `as.integer(sum(x))` or
  `as.numeric(sum(x))` in dbplyr. Values keep their storage types: a
  factor read through a view is `VARCHAR` and is stored as text.

- Geospatial data: a column `geometry` holding WKB (`BLOB`, as in views
  in arrow mode) or of type `GEOMETRY` (as in native views) makes the
  dataset geospatial, and `crs` is then required. The geometries pass
  through R in batches: for each batch the bounding boxes, the H3 cells
  and the index rows are computed as for an `sf` object (with
  `geocode_engine`, and the warning of "Geocoding engines") and kept in
  the staging folder; the rows are then sorted by cell and written from
  DuckDB. `partition = "h3"` and `geocode = FALSE` work as for an `sf`
  object.

- Lazy tables on other databases abort: collect them first.

## Geocoding engines

A geospatial row whose geometry lies inside one H3 cell gets that cell.
For a row that crosses cell edges, the package computes the cells it
touches and the share of the row in each; `h3` is the cell of the
largest share, and every touched cell goes to the index table.
`geocode_engine` says how these cells are computed:

- `"auto"` (the default): each such row is checked on the sphere (s2). A
  valid row is geocoded on the sphere. An invalid one (for example valid
  in the plane, but with a duplicated vertex or a spike that s2 rejects)
  is rebuilt by s2; when the rebuilt copy is empty or does not keep its
  area (length for lines) within `getOption("rcs.s2_rebuild_tol")`
  (default `1e-3`), the row is geocoded in the plane instead.

- `"s2"`: on the sphere; invalid rows are rebuilt by s2 (geocoded in the
  plane when the rebuild fails).

- `"planar"`: every crossing row in the plane of the coordinates
  (slower).

Rows whose box spans 180 degrees of longitude or more are geocoded on
the sphere with every engine. Rebuilt geometries are used only for the
cells; the stored geometry is unchanged. One warning per write (class
`rcs_warning_s2_rebuild`) counts the rows rebuilt and those geocoded in
the plane, and names the first five of each by key (or `.rcs_id`). The
engine is recorded with the dataset, and the exact test of
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
and
[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
follows it by default (`exact_engine`). The same input always gives the
same cells, shares and version. Data in a projected CRS are geocoded
from a copy in EPSG:4326.

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
  missing from `x` disappear. In this mode `key`, `partition`, `h3_res`,
  `geocode` and `geocode_engine` come from the stored dataset; arguments
  that disagree abort. With `partition = "h3"`, an update that would
  need more than `max_files` files re-partitions the whole dataset at a
  coarser H3 resolution.

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
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md),
[`rcs_geo_add()`](https://ebukin.github.io/rcs/reference/rcs_geo_add.md),
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

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
#> ✔ primary    /tmp/Rtmp/rcs-example-write/primary  2/2
#>   files sent  27.8 kB  0.3s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     2/2
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
#> ✔ primary    /tmp/Rtmp/rcs-example-write/primary  unchanged
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     up
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
#> ✔ primary    /tmp/Rtmp/rcs-example-write/primary  1/2
#>   files sent  13.8 kB  0.3s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     1/2
#>   files sent  13.8 kB  0.3s
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary      local  /tmp/Rtmp/rcs-example-write/primary
#>   secondary 1  local  /tmp/Rtmp/rcs-example-write/copy
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated           1
#>   sales/
#>     daily  table   200  27.8 kB      2  2026-11-22 10:52  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.
unlink(root, recursive = TRUE)
```
