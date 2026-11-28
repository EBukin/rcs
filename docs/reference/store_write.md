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
  crs = NULL,
  datatype = NULL,
  nodata = NULL,
  gdal = NULL
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
  files. The catalog records which of the two it was. On update, leave
  it out or give what was given on create (see "Modes").

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
  Rows geocoded in the plane (`"planar"`, or the fallback of `"auto"`)
  that are invalid in the plane too (for example a self-intersecting
  ring) are first repaired with
  [`sf::st_make_valid()`](https://r-spatial.github.io/sf/reference/valid.html),
  silently: the repaired copy is used only for the cells, and keeps only
  the parts of the row's own dimension (none: no cells, `h3` is `NA`).
  The stored geometry is unchanged.

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

- datatype:

  For a raster: the data type of the file, one for all layers. `NULL`
  (the default) keeps the type of the file the raster was read from; a
  raster that is not read from a file gets the smallest integer type
  that holds its values when they are whole numbers, else `"FLT8S"`. Or
  one of `"INT1U"`, `"INT2U"`, `"INT2S"`, `"INT4U"`, `"INT4S"`,
  `"FLT4S"`, `"FLT8S"`; the write aborts when the values do not fit an
  integer type given. See "Rasters". Aborts for any other data.

- nodata:

  For a raster: the one number that marks missing cells in the file.
  Cells holding it are missing when read back, so `nodata = 0` declares
  that `0` is not a value of the map. `NULL` (the default) uses, in this
  order: a flag set with `terra::NAflag(x) <- ` on a raster read from
  files (a raster in memory keeps no flag: its cells become missing at
  once); the NoData tag of the source file; for an integer type its
  default (`255` for `INT1U`, `65535` for `INT2U`, `-32768` for `INT2S`,
  `4294967295` for `INT4U`, `-2147483648` for `INT4S`), which a type
  kept from the file or given with `datatype` gets only when cells are
  missing; none for a float type, whose missing cells are `NaN`. A Byte
  file without a tag whose `0` means "outside the map" therefore gets no
  NoData value unless `nodata = 0` is given. See "Rasters". Aborts for
  any other data.

- gdal:

  For a raster: `NULL`, or a character vector of `KEY=VALUE` creation
  options of GDAL's COG driver, e.g. `c("COMPRESS=ZSTD", "LEVEL=9")`. An
  option replaces the default of the same key (`COMPRESS=DEFLATE`,
  `PREDICTOR=2` or `3`, `BLOCKSIZE=512`, `BIGTIFF=IF_SAFER`,
  `OVERVIEWS=IGNORE_EXISTING`, `OVERVIEW_RESAMPLING=NEAREST` or
  `AVERAGE`); other options are added. See "Rasters". Aborts for any
  other data.

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

- A raster is written as one Cloud Optimized GeoTIFF (COG), the only
  raster format; it cannot be partitioned or updated (see "Rasters").

- A lazy table on a DuckDB connection is a `table`, or `geospatial` when
  it has a column `geometry` (see "DuckDB input").

## Rasters

A `SpatRaster` is written as one Cloud Optimized GeoTIFF (COG), the only
raster format: a reader can fetch a part of it without the rest, also
from a bucket. The raster needs a CRS, cell values and unique layer
names.

**What is stored where.** The file holds the cell values only; for a
class map, the codes. What describes them is recorded per layer in the
catalog and in the dataset's manifest: the data type, the NoData value
(`nodata`), the resolution and the dimensions (`resolution`, `dim`), the
legend of a categorical layer (`values`, `levels`, `levels_name`) and
its colours (`color_values`, `colors`).
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
returns the raster with its categories and colours set again, and
[`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md)
shows the record. No side file (`.aux.xml`, `.aux.json`) is written.

- **Data type** (`datatype`). All layers get one type, as a GeoTIFF
  requires. With `datatype = NULL`, the first rule that applies:

  1.  A raster read from files, with its cells still on disk, keeps the
      type of its source: a Byte map stays `INT1U`, an `FLT4S` file
      stays `FLT4S`. No pass over the cells is needed. This rule is
      skipped when the layers have different types, and for a raster
      with a scale or an offset (in the file, or set with
      [`terra::scoff()`](https://rspatial.github.io/terra/reference/scoff.html)),
      whose values are not the stored numbers.

  2.  Whole numbers get the smallest of `INT1U`, `INT2U`, `INT2S`,
      `INT4U`, `INT4S` that holds the values and the NoData value: codes
      1 to 5 with `nodata = 0` take one byte per cell. Whole numbers are
      integer layers
      ([`terra::is.int()`](https://rspatial.github.io/terra/reference/is.bool.html))
      and categorical layers; doubles that happen to be whole are not,
      so convert them with
      [`terra::as.int()`](https://rspatial.github.io/terra/reference/is.bool.html)
      first.

  3.  Anything else is `FLT8S`. Doubles are never narrowed to `FLT4S`
      unless `datatype = "FLT4S"` asks for it (it rounds them to single
      precision).

  A `datatype` given is used as it is. An integer type needs whole
  numbers inside its range, else the write aborts.

- **NoData** (`nodata`). One value marks the missing cells of all
  layers. Cells that hold this value are missing when read back; this is
  how a map whose `0` means "outside the map" is written (`nodata = 0`).
  With `nodata = NULL`, the first rule that applies:

  1.  A flag set in the session on a raster read from files
      (`terra::NAflag(x) <- `). On a raster in memory terra applies the
      flag at once, the cells become missing, and no flag is left: the
      rules below then apply.

  2.  The NoData tag of the source file. It is not used for a layer with
      a scale or an offset, whose values are not the stored numbers the
      tag refers to.

  3.  For an integer type chosen from the values (rule 2 of "Data
      type"), the default of the type: `255` for `INT1U`, `65535` for
      `INT2U`, `-32768` for `INT2S`, `4294967295` for `INT4U`,
      `-2147483648` for `INT4S`. The type is chosen so that no cell
      holds that value: values up to 254 fit `INT1U`, and with 255 among
      them the type is `INT2U`.

  4.  For an integer type kept from the source or given with `datatype`,
      the same default, but only when cells are missing (found by one
      pass over the cells, made only in this case). The write aborts
      when a cell holds that value; give `nodata` then. Without missing
      cells the file has no NoData value: a Byte file without a tag
      whose `0` means "outside the map" gets none unless `nodata = 0` is
      given.

  5.  A float type has none: its missing cells are `NaN`.

  Layers whose flags or tags differ abort and ask for `nodata`. A
  `nodata` that the data type cannot hold aborts.

- **Creation options** (`gdal`). The defaults suit reads from a bucket:
  `COMPRESS=DEFLATE`, `PREDICTOR=2` (integer types) or `PREDICTOR=3`
  (float types), `BLOCKSIZE=512`, `BIGTIFF=IF_SAFER`, and overviews
  built anew, never copied from a source file
  (`OVERVIEWS=IGNORE_EXISTING`), with `OVERVIEW_RESAMPLING=NEAREST`
  (integer types) or `AVERAGE` (float types). `gdal` is a character
  vector of `KEY=VALUE` options of GDAL's COG driver, e.g.
  `gdal = c("COMPRESS=ZSTD", "LEVEL=9")`: a key that has a default
  replaces it, other keys are added. Keys are compared in upper case, a
  key given twice aborts, and the order given does not change the file.
  The options are kept in the file, not in the catalog.

- **Legend of a class map.** A categorical layer is one with a category
  table, set with `levels(x) <- data.frame(value = , label = )`: the
  codes in the first column, their labels in the second. `levels<-`
  renames the layer to the label column, so set `names(x)` after it. The
  codes are written to the file; the legend is recorded as `values` (the
  codes, sorted), `levels` (their labels) and `levels_name` (the name of
  the label column). Codes must be whole numbers and every code needs a
  label, else the write aborts. Of a category table with several label
  columns, only the active one
  ([`terra::activeCat()`](https://rspatial.github.io/terra/reference/activeCat.html))
  is kept; the others are dropped, with a message.

- **Colours.** The colour table of a layer, set with
  `terra::coltab(x) <- data.frame(value = , col = )`, is recorded as
  `color_values` (the codes, sorted) and `colors` (`#RRGGBBAA`). With a
  legend, only the colours of the legend's codes are kept. Without a
  legend every row of the colour table is kept; a colour table read from
  a file has 256 rows (the codes 0 to 255; a code without a colour is
  black, or transparent when it is the file's NoData value), and all 256
  are recorded. Colours come from the raster only: a style file such as
  a QGIS `.qml` is not read.

- **Not stored.** The time and the units of layers
  ([`terra::time()`](https://rspatial.github.io/terra/reference/time.html),
  [`terra::units()`](https://rspatial.github.io/terra/reference/units.html)),
  and the columns of a category table other than the codes and the
  active labels. The file is written without categories, colour table,
  time and units; `x` itself is never changed. Only other metadata that
  a source file holds itself may be copied with it when GDAL copies the
  file (next point).

- **Two ways to write, and the room they need.** The file is first
  written on the local disk, in the staging folder
  `getOption("rcs.staging_dir")` (default
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html)), and then
  uploaded. Every temporary file lies below that folder.

  - A raster opened with `terra::rast(file)` and not changed in the
    session is copied by GDAL straight from its file, with no
    intermediate file. On a simulated map of 25,000 x 25,000 cells the
    staging folder held at most about 1.4 times the size of the output.
    "Not changed" means: all layers of one file in their order, with the
    file's layer names, extent and CRS, and no NoData flag or tag other
    than the value written. Setting a legend (and the layer name again)
    or colours is not a change. A file with a scale or an offset is not
    copied by GDAL.

  - Any other raster is written by terra: one in memory, computed,
    cropped, renamed, a subset of the layers, from several files, with a
    scale or an offset, or with another CRS or NoData value than its
    file. For a large raster terra first writes an intermediate file; on
    the same map the staging folder then held about 3.6 times the size
    of the output. A raster held in memory also needs RAM for all its
    cells, so write a large map from its file.

  For a raster read from files, the write warns (class
  `rcs_warning_staging_space`) when the drive of the staging folder has
  less free room than twice the size of the source files, and goes on.
  The ps package tells the free room; without it, and for a raster in
  memory, there is no check. `options(rcs.staging_dir = )` moves the
  staging to another drive.

The same raster written with the same arguments gives the same file and
the same version. The legend, the colours, the time and the units do not
change the file: the same cells with and without them give the same
version, and only the catalog entry differs. Writing the same cells with
another legend or other colours keeps the version, sends no file and
replaces the legend and the colours recorded for that version; the
earlier ones are not kept. A `datatype`, `nodata` or `gdal` gives
another file and another version only when it changes the file:
`nodata = 0` for a source file already tagged `0`, or an option equal to
its default, gives the same one. The two ways of writing may give
different bytes for the same cells. A raster written with a version of
the package before `0.0.0.9005` gets a new version when it is written
again, even with unchanged cells: the bytes of the file differ.

## DuckDB input

`x` may be a lazy table on a DuckDB connection (from
[`dplyr::tbl()`](https://dplyr.tidyverse.org/reference/tbl.html), for
example on a view of
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md),
or from `store_open(engine = "duckdb")`), so that a result computed in
DuckDB is stored without being collected into R as a whole.

- A table (no `geometry` column) with a `partition` is written one
  partition at a time. The query runs as a subquery `2 + P` times (P
  partitions): once to check the key, once for the partition values and
  row counts, then once per partition, whose rows are copied into the
  temporary table `rcs_write_<random>_part`, written, checked and
  dropped. DuckDB then needs room for about the largest partition, not
  for the whole result. The query must therefore be deterministic (give
  the same rows each time), and is best a scan of stored files or views;
  an expensive query is better computed once into a DuckDB table first.
  `options(rcs.duckdb_stream = FALSE)` turns this off.

- Otherwise (no partition, geospatial data, or
  `rcs.duckdb_stream = FALSE`) the query runs once into a temporary
  copy, the table `rcs_write_<random>` on the same connection, which
  every later step reads; the copy needs room for the whole result in
  DuckDB's memory or its temporary folder.

The temporary tables are dropped when the call ends, also after an
error. The key and the partitions are checked in DuckDB, and the rows
are fetched in batches of `getOption("rcs.duckdb_batch_rows")` rows
(default `5e5`), so that R holds about one batch at a time; a progress
bar shows the batches unless `options(rcs.quiet = TRUE)`. For the
duration of the call the connection runs with
`preserve_insertion_order = true`, so that the rows reach R in the order
the write asks for; the caller's setting is restored when the call ends,
also after an error. DuckDB never uploads: the files are staged and land
in every location as for any other write. Staged files need free room
equal to the output in `getOption("rcs.staging_dir")` (default
[`tempdir()`](https://rdrr.io/r/base/tempfile.html)); setting it to a
folder on the store's drive avoids copying them across drives. The files
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
  that disagree abort. `partition` may be left out; if given, it must be
  what was given on create: `"h3"`, or the column names. Partition
  columns given by the user, even ones named `h3_p<r>`, are kept as
  given: never recomputed from the geometries. With `partition = "h3"`,
  an update that would need more than `max_files` files re-partitions
  the whole dataset at a coarser H3 resolution.

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
`store_sync(st, datasets = "<name>")` repairs it, or
`store_sync(st, all = TRUE)` for every dataset (a plain
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
refreshes only the datasets a secondary already holds).

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
#>   files sent  27.9 kB  0.1s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     2/2
#>   files sent  27.9 kB  0.1s
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.

# The same data again: nothing is uploaded
store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"), partition = "year",
  mode = "replace"
)
#> ℹ "sales/daily" is unchanged (version 41ec22ed5b5602ce): 200 rows in 2 files
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
#>   files sent  13.9 kB  0.1s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     1/2
#>   files sent  13.9 kB  0.1s
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
#>     daily  table   200  27.9 kB      2  2026-11-27 18:51  =
#> Secondary copies: = same, ≠ differs, – missing, ? unavailable.

# A class map: the codes go into the file, the legend and the colours
# into the catalog. `nodata = 0`: cells holding 0 are outside the map.
if (requireNamespace("terra", quietly = TRUE)) {
  cover <- terra::as.int(rcs_sim_raster(nrow = 60, ncol = 80)[["cover"]])
  cover[1:2, ] <- 0L
  levels(cover) <- data.frame(
    value = 1:5,
    label = c("water", "forest", "crop", "grass", "bare")
  )
  names(cover) <- "cover" # `levels<-` renamed the layer
  terra::coltab(cover) <- data.frame(
    value = 1:5,
    col = c("#1F78B4", "#33A02C", "#FFD92F", "#B2DF8A", "#B15928")
  )
  store_write(st, cover, "grids/cover",
    title = "Land cover", description = "A simulated class map.",
    nodata = 0
  )
  # One byte per cell, the NoData value and the number of classes
  print(store_describe(st, "grids/cover")$columns)

  # A large map is best written straight from its file: the data type
  # and the NoData tag of the file are kept. `gdal` changes the
  # compression here.
  file <- file.path(root, "cover.tif")
  terra::writeRaster(cover, file, datatype = "INT1U", NAflag = 0)
  store_write(st, terra::rast(file), "grids/cover_zstd",
    title = "Land cover, ZSTD", description = "A simulated class map.",
    gdal = c("COMPRESS=ZSTD", "LEVEL=9")
  )
  # The label column is named `cover` here, not `label`:
  # `terra::writeRaster()` named it after the layer
  print(terra::levels(store_read(st, "grids/cover_zstd"))[[1]])
}
#> ℹ Writing "grids/cover": 4,800 cells in 1 file.
#> ✔ primary    /tmp/Rtmp/rcs-example-write/primary  1/1
#>   files sent  1.9 kB  0.1s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     1/1
#>   files sent  1.9 kB  0.1s
#> ✔ MD5 identical for 1 file in 2 locations. Catalogs updated.
#> # A tibble: 1 × 4
#>   name  type  r_type                                            description
#>   <chr> <chr> <chr>                                             <chr>      
#> 1 cover INT1U raster layer (60 x 80 cells, nodata 0, 5 classes) NA         
#> ℹ Writing "grids/cover_zstd": 4,800 cells in 1 file.
#> ✔ primary    /tmp/Rtmp/rcs-example-write/primary  1/1
#>   files sent  1.6 kB  0.1s
#> ✔ secondary  /tmp/Rtmp/rcs-example-write/copy     1/1
#>   files sent  1.6 kB  0.1s
#> ✔ MD5 identical for 1 file in 2 locations. Catalogs updated.
#>   value  cover
#> 1     1  water
#> 2     2 forest
#> 3     3   crop
#> 4     4  grass
#> 5     5   bare
unlink(root, recursive = TRUE)
```
