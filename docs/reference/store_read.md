# Read a dataset

Reads a table, a geospatial dataset or a raster from a store. Filters
and column selection are pushed into the scan, so only the needed files,
row groups and columns are read.

## Usage

``` r
store_read(
  st,
  dataset,
  ...,
  columns = NULL,
  intersects = NULL,
  geometry = TRUE,
  version = NULL,
  copy = NULL,
  exact = TRUE,
  exact_engine = NULL
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset: the full name, or its last part when that is
  unique in the store.

- ...:

  Filter expressions, as in
  [`dplyr::filter()`](https://dplyr.tidyverse.org/reference/filter.html).

- columns:

  Columns to return, as in
  [`dplyr::select()`](https://dplyr.tidyverse.org/reference/select.html)
  (tidyselect); `NULL` for all. The geometry column is controlled by
  `geometry`. A raster has no column selection.

- intersects:

  `NULL`, or a query: an `sf`, `sfc` or `bbox` object with a coordinate
  reference system, or H3 cells of any resolution as hex strings,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
  or `h3o` `H3` vectors. A plain number aborts: it cannot hold an H3
  cell. An `sf` or `sfc` query with an invalid geometry (for example a
  ring that crosses itself) aborts, with the reason and advice to use
  [`sf::st_make_valid()`](https://r-spatial.github.io/sf/reference/valid.html);
  validity is read on the sphere or in the plane as in
  [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md).
  For a raster, the query's bounding box is the window that is read (see
  "Rasters").

- geometry:

  `FALSE` drops the geometry before reading and returns a tibble.

- version:

  `NULL` for the current version, or the 16 hex characters of an earlier
  version kept in the history.

- copy:

  Whether to copy the dataset to the local secondary locations before
  reading (see "Copy to secondary locations"). `NULL` (the default)
  copies the current version when the connection's `copy_on_read` is
  `TRUE` and the bytes to download are at or under the limit. `TRUE`
  copies whatever the limit and the connection's setting, and copies an
  earlier version too, into the secondaries' history. `FALSE` never
  copies.

- exact:

  `TRUE` tests the candidate rows of a spatial filter exactly, on the
  sphere or in the plane as `exact_engine` says.

- exact_engine:

  How the exact test of a spatial filter reads the geometries: `NULL`
  (the default) follows the geocoding engine the dataset was written
  with (`"s2"`: on the sphere; `"planar"`: in the plane; `"auto"`: on
  the sphere for rows valid on the sphere, in the plane for the others),
  and the session's
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  setting for a dataset with no recorded engine (written before engines
  were recorded, or with `geocode = FALSE`). `"s2"`, `"planar"` or
  `"session"` override it. Data in a projected CRS are always tested in
  the plane of that CRS. See
  [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md).

## Value

A tibble; an `sf` object for geospatial data read with geometry; a
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
for a raster, with the categories and the colours recorded when it was
written.

## Details

- Filters (`...`) are dplyr filter expressions. A filter whose columns
  are all partition columns is first evaluated on the partition values
  in the catalog, so only the files of the matching partitions are
  opened.

- `intersects` keeps the rows of a geospatial dataset whose geometry
  intersects a query shape or H3 cells (see
  [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
  for the steps). With `exact = FALSE` or `geometry = FALSE` the result
  is the candidate set, a superset of the intersecting rows, and a
  message says so.

- A geospatial dataset is returned as an `sf` object with the catalog's
  coordinate reference system, or as a tibble with `geometry = FALSE`.
  Of the columns the package adds, the row identifier `.rcs_id` is
  dropped (unless named in `columns`); the H3 cell `h3`
  ([`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  see
  [`store_h3_hex()`](https://ebukin.github.io/rcs/reference/store_h3_hex.md)),
  the bounding box `bbox` and the partition column `h3_p<r>` are
  returned.

- A raster is returned as a
  [`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
  opened through GDAL, so only the tiles needed are read; `intersects`
  crops it to the query's bounding box (see "Rasters"). Filters,
  `columns`, `geometry`, `exact` and `exact_engine` do not apply to
  rasters and abort.

## Rasters

A raster is returned as a
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
that points to the stored file: at the location itself for a local
store, through GDAL's virtual file system for a bucket. No cell is read
until it is needed: GDAL fetches only the tiles a calculation or a
window needs, from the location read from. The file itself is copied
only by a copy to a secondary location (below).

A raster is one file, so copying it to a secondary location is all or
nothing (see "Copy to secondary locations"). With a primary in a bucket
and a local secondary that lacks the raster or holds an older version,
the whole file is first copied to the secondary when it is at or under
the size limit, and the raster, or its window, is then read from that
copy. With `copy = FALSE`, a connection made with
`copy_on_read = FALSE`, or a file above the limit, nothing is copied and
the read stays on the bucket.

- **The whole raster.** `store_read(st, "name")` returns every layer,
  with the layer names, the data type and the NoData value of the file.
  Cells that hold the NoData value are missing (`NA`).

- **A window.** `intersects` returns only the part inside the bounding
  box of the query, in the raster's CRS, rounded outwards to whole
  cells; a point or a line gives the cells it touches. The cells of the
  window are read at once, from the location read from (straight from
  the bucket when no local copy holds the version): this is the way to
  work with a map too large to read whole. The query takes the same
  forms as for geospatial data (an `sf`, `sfc` or `bbox` object in any
  CRS, or H3 cells). A query that does not overlap the raster aborts;
  one that crosses the antimeridian or holds a pole returns the raster
  uncropped.

- **Legend.** A layer written with categories (see "Rasters" in
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md))
  comes back categorical:
  [`terra::levels()`](https://rspatial.github.io/terra/reference/factors.html)
  gives the codes and labels recorded with the dataset,
  [`terra::freq()`](https://rspatial.github.io/terra/reference/freq.html)
  and
  [`terra::plot()`](https://rspatial.github.io/terra/reference/plot.html)
  use the labels, and `terra::extract(x, cells, raw = TRUE)` gives the
  codes. The label column is named as it was when the map was written;
  the code column is named `value` (`code` when the label column is
  itself called `value`).

- **Colours.** A layer written with a colour table has it again:
  [`terra::has.colors()`](https://rspatial.github.io/terra/reference/colors.html)
  is `TRUE`,
  [`terra::coltab()`](https://rspatial.github.io/terra/reference/colors.html)
  gives the table, and
  [`terra::plot()`](https://rspatial.github.io/terra/reference/plot.html)
  draws with it.

The legend and the colours come from the catalog, not from the file, and
nothing is written next to the file. A window and a subset of the layers
(`x[["name"]]`) keep both. There is no `columns` for rasters: read the
raster and take the layers from it.

The location read from is, among the available locations that hold the
dataset at the primary's version, a local one first, then the primary,
then the other secondaries. Reading from a secondary prints a line
saying so (silenced by `options(rcs.quiet = TRUE)`). Reads use the
catalogs held by the connection;
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
reads them again.

## Copy to secondary locations

When the primary location is not local (a bucket) and a secondary is a
local folder, `store_read()` first copies the dataset there, so that
this read and the next ones come from the local copy. It copies only:

- to secondaries that are available and local, while the primary is not
  local: with a local primary, or with secondaries in buckets only, a
  read copies nothing;

- the current version, to a secondary that lacks the dataset or its
  index table, or holds an older version of it. The dataset is copied
  from the primary with its index table, and only the files the
  secondary lacks are sent, each verified by its MD5;

- when the connection's `copy_on_read` is `TRUE` (the default of
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md))
  and `copy` is not `FALSE`;

- when the bytes to download, for the secondary that lacks the most, are
  at or under the limit `getOption("rcs.copy_on_read_max_bytes")`, 2 GB
  (`2e9`) by default. Above it nothing is copied and a message says how
  to copy (`copy = TRUE`, or
  [`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
  with `datasets = `).

Filters, `columns` and `intersects` do not change the rule: the whole
dataset is copied, then read from the copy. A secondary whose version
was written later than the primary's is never replaced by a read; a
message says so. A secondary that holds the primary's version under
another catalog entry (for example a raster written again with another
legend or other colours) gets the primary's entry, without any file sent
and whatever the limit. A copy that fails gives a warning, and the read
goes on from the primary; the next read tries again. Reading an index
table never copies; nor do
[`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md),
[`store_glimpse()`](https://ebukin.github.io/rcs/reference/store_glimpse.md),
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
and
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

Earlier versions (`version = `) are not copied by default. When such a
read comes from the primary while an available local secondary could
hold a copy, a message says so (unless copying is turned off).
`copy = TRUE` adds the version to the history of each of these
secondaries, other than the one it is read from, that holds neither it
as its current version nor it in its history: its files, its manifest
unchanged, and its rows of the history. With no such secondary at all, a
message says there is none to copy to. The secondary's current version
of the dataset does not change, and a secondary that does not hold the
dataset still does not list it. One effect to know:
[`store_rebuild()`](https://ebukin.github.io/rcs/reference/store_rebuild.md)
of a secondary that holds only an earlier version of a dataset makes
that version its current one.

To turn copying off, connect with `store_connect(copy_on_read = FALSE)`,
or pass `copy = FALSE` to one read: nothing is copied and no message
about copying is printed (a secondary that already holds the version is
still read from). Messages are silenced by `options(rcs.quiet = TRUE)`.

## See also

[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
for lazy queries,
[`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md),
[`store_glimpse()`](https://ebukin.github.io/rcs/reference/store_glimpse.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-read")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(500), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-read  2/2
#>   files sent  38.3 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_read(st, "sales/daily", year == 2023, product == "p07",
  columns = c(shop_id, date, qty)
)
#> # A tibble: 14 × 3
#>    shop_id date         qty
#>      <int> <date>     <int>
#>  1       1 2023-01-22    31
#>  2       1 2023-03-12    21
#>  3       2 2023-08-29    11
#>  4       3 2023-08-07    33
#>  5       3 2023-10-11    48
#>  6       5 2023-01-29    43
#>  7       5 2023-12-23    21
#>  8       9 2023-10-23    31
#>  9      10 2023-02-21    17
#> 10      11 2023-03-01    25
#> 11      13 2023-08-09     6
#> 12      15 2023-10-17    10
#> 13      17 2023-01-17    41
#> 14      17 2023-07-06    36

store_write(st, rcs_sim_polygons(200), "shapes/polygons",
  title = "Polygons", description = "Simulated polygons in open ocean."
)
#> ℹ Writing "shapes/polygons": 200 rows in 1 file, and its index table in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-read  2/2
#>   files sent  41.2 kB  0.3s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
area <- sf::st_as_sfc(sf::st_bbox(
  c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
  crs = sf::st_crs(4326)
))
store_read(st, "polygons", intersects = area)
#> Simple feature collection with 16 features and 5 fields
#> Geometry type: GEOMETRY
#> Dimension:     XY
#> Bounding box:  xmin: -29.8 ymin: 6.1 xmax: -27.08777 ymax: 7.969043
#> Geodetic CRS:  WGS 84
#> # A tibble: 16 × 6
#>       id       area cat   h3              bbox$xmin                     geometry
#>    <int>      <dbl> <chr> <h3>                <dbl>               <GEOMETRY [°]>
#>  1     6     0.392  b     85565903fffffff     -28.0 MULTIPOLYGON (((-27.96559 7…
#>  2   119     0.272  b     85565903fffffff     -28.0 POLYGON ((-27.97298 7.73604…
#>  3    19     0.166  e     85565927fffffff     -27.6 POLYGON ((-27.63064 7.34118…
#>  4   117     0.428  d     85565927fffffff     -27.5 POLYGON ((-27.5089 7.333518…
#>  5     8     4.90   a     85565937fffffff     -27.6 POLYGON ((-27.59022 7.49, -…
#>  6   196     0.0479 a     85565937fffffff     -27.5 POLYGON ((-27.49999 7.42989…
#>  7    34     0.180  a     855659a3fffffff     -27.6 POLYGON ((-27.59195 7.79849…
#>  8    49     0.463  b     855659a3fffffff     -27.5 POLYGON ((-27.53358 7.84611…
#>  9    10     0.134  c     855659b3fffffff     -27.6 POLYGON ((-27.6311 7.965744…
#> 10    21     0.204  a     855659bbfffffff     -27.8 POLYGON ((-27.76669 7.89477…
#> 11     1 46041.     a     857c4bd3fffffff     -29.8 POLYGON ((-29.8 6.1, -27.3 …
#> 12    53     0.310  c     857c596ffffffff     -27.9 POLYGON ((-27.86865 7.15446…
#> 13    64     0.0367 e     857c596ffffffff     -27.8 POLYGON ((-27.84618 7.13101…
#> 14    22     0.0558 a     857c5b0ffffffff     -27.1 POLYGON ((-27.08991 7.31366…
#> 15    59     0.0445 b     857c5b3bfffffff     -27.1 POLYGON ((-27.13006 7.43325…
#> 16    74     0.138  d     857c5b8ffffffff     -27.1 POLYGON ((-27.09025 6.99834…
#> # ℹ 3 more variables: bbox$ymin <dbl>, $xmax <dbl>, $ymax <dbl>
store_read(st, "polygons", geometry = FALSE)
#> # A tibble: 200 × 5
#>       id   area cat   h3              bbox$xmin $ymin $xmax $ymax
#>    <int>  <dbl> <chr> <h3>                <dbl> <dbl> <dbl> <dbl>
#>  1   185 0.269  e     8556481bfffffff     -26.2  8.78 -26.2  8.79
#>  2   188 0.425  c     8556482bfffffff     -25.9  8.31 -25.9  8.32
#>  3     7 0.391  a     8556483bfffffff     -26.4  8.28 -25.9  8.54
#>  4   158 0.287  c     8556484bfffffff     -26.6  8.56 -26.6  8.56
#>  5    93 0.476  d     8556484ffffffff     -26.4  8.49 -26.4  8.49
#>  6    44 0.0618 b     85564863fffffff     -26.2  8.33 -26.2  8.33
#>  7    23 0.191  a     8556486bfffffff     -26.4  8.28 -26.4  8.29
#>  8   168 0.414  b     85564877fffffff     -26.1  8.46 -26.1  8.46
#>  9    63 0.0938 d     855648affffffff     -25.6  8.60 -25.6  8.60
#> 10   139 0.499  c     855648affffffff     -25.7  8.62 -25.7  8.62
#> # ℹ 190 more rows

# A class map: whole, and a window of it
if (requireNamespace("terra", quietly = TRUE)) {
  cover <- terra::as.int(rcs_sim_raster(nrow = 60, ncol = 80)[["cover"]])
  cover[1:2, ] <- 0L
  levels(cover) <- data.frame(
    value = 1:5,
    label = c("water", "forest", "crop", "grass", "bare")
  )
  names(cover) <- "cover"
  terra::coltab(cover) <- data.frame(
    value = 1:5,
    col = c("#1F78B4", "#33A02C", "#FFD92F", "#B2DF8A", "#B15928")
  )
  store_write(st, cover, "grids/cover",
    title = "Land cover", description = "A simulated class map.",
    nodata = 0
  )

  map <- store_read(st, "grids/cover")
  print(map)
  print(terra::levels(map)[[1]]) # the legend
  print(terra::has.colors(map))
  print(terra::coltab(map)[[1]]) # the colours
  print(map[1, 1]) # a cell holding the NoData value is missing

  # Only the cells inside the box of `area`, with legend and colours
  window <- store_read(st, "grids/cover", intersects = area)
  print(dim(window))
  print(terra::freq(window))
  rm(map, window)
}
#> ℹ Writing "grids/cover": 4,800 cells in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-read  1/1
#>   files sent  1.9 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
#> class       : SpatRaster
#> size        : 60, 80, 1  (nrow, ncol, nlyr)
#> resolution  : 0.075, 0.05  (x, y)
#> extent      : -30, -24, 6, 9  (xmin, xmax, ymin, ymax)
#> coord. ref. : lon/lat WGS 84 (EPSG:4326)
#> source      : part-0a57aa5e38cbde52.tif
#> color table : 1
#> categories  : label
#> name        : cover
#> min value   : water
#> max value   :  bare
#>   value  label
#> 1     1  water
#> 2     2 forest
#> 3     3   crop
#> 4     4  grass
#> 5     5   bare
#> [1] TRUE
#>   values red green blue alpha
#> 1      1  31   120  180   255
#> 2      2  51   160   44   255
#> 3      3 255   217   47   255
#> 4      4 178   223  138   255
#> 5      5 177    89   40   255
#>   cover
#> 1  <NA>
#> [1] 20 14  1
#>   layer  value count
#> 1     1  water    53
#> 2     1 forest    52
#> 3     1   crop    78
#> 4     1  grass    48
#> 5     1   bare    49
unlink(location, recursive = TRUE)
```
