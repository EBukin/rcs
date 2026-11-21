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
  exact = TRUE
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
  `geometry`.

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

- geometry:

  `FALSE` drops the geometry before reading and returns a tibble.

- version:

  `NULL` for the current version, or the 16 hex characters of an earlier
  version kept in the history.

- exact:

  `TRUE` tests the candidate rows of a spatial filter exactly with
  [`sf::st_intersects()`](https://r-spatial.github.io/sf/reference/geos_binary_pred.html),
  under the session's
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  setting.

## Value

A tibble; an `sf` object for geospatial data read with geometry; a
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
for a raster.

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
  crops it to the query's bounding box. Filters, `columns`, `geometry`
  and `exact` do not apply to rasters and abort.

The location read from is, among the available locations that hold the
dataset at the primary's version, a local one first, then the primary,
then the other secondaries. Reading from a secondary prints a line
saying so (silenced by `options(rcs.quiet = TRUE)`). Reads use the
catalogs held by the connection;
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
reads them again.

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
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-read  2/2
#>   files sent  38.1 kB  0.2s
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
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-read  2/2
#>   files sent  41.1 kB  0.2s
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
#>       id       area cat        h3 bbox$xmin $ymin                       geometry
#>    <int>      <dbl> <chr> <int64>     <dbl> <dbl>                 <GEOMETRY [°]>
#>  1     6     0.392  b        6e17     -28.0  7.73 MULTIPOLYGON (((-27.96559 7.7…
#>  2   119     0.272  b        6e17     -28.0  7.74 POLYGON ((-27.97298 7.736041,…
#>  3    19     0.166  e        6e17     -27.6  7.34 POLYGON ((-27.63064 7.34118, …
#>  4   117     0.428  d        6e17     -27.5  7.33 POLYGON ((-27.5089 7.333518, …
#>  5     8     4.90   a        6e17     -27.6  7.49 POLYGON ((-27.59022 7.49, -27…
#>  6   196     0.0479 a        6e17     -27.5  7.43 POLYGON ((-27.49999 7.429893,…
#>  7    34     0.180  a        6e17     -27.6  7.80 POLYGON ((-27.59195 7.798493,…
#>  8    49     0.463  b        6e17     -27.5  7.85 POLYGON ((-27.53358 7.846119,…
#>  9    10     0.134  c        6e17     -27.6  7.97 POLYGON ((-27.6311 7.965744, …
#> 10    21     0.204  a        6e17     -27.8  7.89 POLYGON ((-27.76669 7.894771,…
#> 11     1 46041.     a        6e17     -29.8  6.1  POLYGON ((-29.8 6.1, -27.3 6.…
#> 12    53     0.310  c        6e17     -27.9  7.15 POLYGON ((-27.86865 7.154465,…
#> 13    64     0.0367 e        6e17     -27.8  7.13 POLYGON ((-27.84618 7.131019,…
#> 14    22     0.0558 a        6e17     -27.1  7.31 POLYGON ((-27.08991 7.31366, …
#> 15    59     0.0445 b        6e17     -27.1  7.43 POLYGON ((-27.13006 7.433258,…
#> 16    74     0.138  d        6e17     -27.1  7.00 POLYGON ((-27.09025 6.99834, …
#> # ℹ 2 more variables: bbox$xmax <dbl>, $ymax <dbl>
store_read(st, "polygons", geometry = FALSE)
#> # A tibble: 200 × 5
#>       id   area cat        h3 bbox$xmin $ymin $xmax $ymax
#>    <int>  <dbl> <chr> <int64>     <dbl> <dbl> <dbl> <dbl>
#>  1   185 0.269  e        6e17     -26.2  8.78 -26.2  8.79
#>  2   188 0.425  c        6e17     -25.9  8.31 -25.9  8.32
#>  3     7 0.391  a        6e17     -26.4  8.28 -25.9  8.54
#>  4   158 0.287  c        6e17     -26.6  8.56 -26.6  8.56
#>  5    93 0.476  d        6e17     -26.4  8.49 -26.4  8.49
#>  6    44 0.0618 b        6e17     -26.2  8.33 -26.2  8.33
#>  7    23 0.191  a        6e17     -26.4  8.28 -26.4  8.29
#>  8   168 0.414  b        6e17     -26.1  8.46 -26.1  8.46
#>  9    63 0.0938 d        6e17     -25.6  8.60 -25.6  8.60
#> 10   139 0.499  c        6e17     -25.7  8.62 -25.7  8.62
#> # ℹ 190 more rows
unlink(location, recursive = TRUE)
```
