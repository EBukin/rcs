# Geospatial data

rcs stores `sf` objects and `terra` rasters next to tables, in the same
store and with the same functions. This vignette shows what the package
adds to geospatial data when it writes them, and how to read only the
rows that intersect an area. It assumes you have read
[`vignette("rcs")`](https://ebukin.github.io/rcs/articles/rcs.md).

Geocoding needs the package h3o, and rasters need terra. Both are
suggested, not required; the code below that uses them runs only when
they are installed.

``` r

library(rcs)
library(sf)
st <- store_connect(file.path(tempdir(), "geo-store"), create = TRUE)
```

## Write an `sf` object

[`rcs_sim_polygons()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
returns simulated polygons in a box of open ocean, between longitudes
−30 and −24 and latitudes 6 and 9: small squares and hexagons, a few
large and long thin shapes, multipolygons and one empty geometry.
[`rcs_sim_points()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
and
[`rcs_sim_lines()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
give points and lines in the same box.

``` r

polys <- rcs_sim_polygons(500, seed = 1)
polys
#> Simple feature collection with 500 features and 3 fields (with 1 geometry empty)
#> Geometry type: GEOMETRY
#> Dimension:     XY
#> Bounding box:  xmin: -29.94218 ymin: 6.050584 xmax: -24.07019 ymax: 8.952676
#> Geodetic CRS:  WGS 84
#> # A tibble: 500 × 4
#>       id       area cat                                                 geometry
#>    <int>      <dbl> <chr>                                         <GEOMETRY [°]>
#>  1     1 46041.     d     POLYGON ((-29.8 6.1, -27.3 6.1, -27.3 7.6, -29.8 7.6,…
#>  2     2  4487.     a     POLYGON ((-25.18752 8.2, -25.21461 8.36477, -25.31917…
#>  3     3  6755.     d     POLYGON ((-26.6 6.2, -25.8 6.2, -25.8 7, -26.6 7, -26…
#>  4     4    30.1    e     POLYGON ((-29 8.5, -26.27514 8.5, -26.27514 8.500904,…
#>  5     5     0.392  e     MULTIPOLYGON (((-26.75391 7.293398, -26.74991 7.29339…
#>  6     6     0.392  e     MULTIPOLYGON (((-27.96559 7.733237, -27.96159 7.73323…
#>  7     7     0.391  b     MULTIPOLYGON (((-26.42263 8.281812, -26.41863 8.28181…
#>  8     8     4.90   b     POLYGON ((-27.59022 7.49, -27.57022 7.49, -27.57022 7…
#>  9     9    NA      a                                              POLYGON EMPTY
#> 10    10     0.0779 d     POLYGON ((-27.62909 6.399786, -27.62657 6.399786, -27…
#> # ℹ 490 more rows
```

An `sf` object is written like a table. The dataset’s kind becomes
`geospatial`, and its coordinate reference system (CRS) is kept in the
catalog. Any CRS can be used.

``` r

store_write(st, polys, "shapes/polygons",
  title = "Polygons",
  description = "Simulated polygons in open ocean.",
  key = "id"
)
#> ℹ Writing "shapes/polygons": 500 rows in 1 file, and its index table in 1 file.
#> ✔ primary  <tempdir>/geo-store  2/2 files sent  72.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

Two files were written: the data, and an *index table*, explained below.

## What the package adds, and why

A spatial filter on a large dataset should not read every geometry. To
let the Parquet reader skip rows without looking at geometries, the
package adds three columns when it writes an `sf` object:

- `h3`: an H3 cell. H3 divides the globe into hexagonal cells at 16
  resolutions; at resolution 5, the default, a cell covers about 250
  km². `h3` is the cell that holds the largest part of the geometry,
  stored as a 64-bit integer.
- `bbox`: the bounding box of the geometry, four numbers (`xmin`,
  `ymin`, `xmax`, `ymax`).
- `.rcs_id`: a row number, unique within the dataset, used to link rows
  to the index table. Reads drop it unless it is asked for.

Rows are sorted by `h3` before they are written, so rows that lie close
together sit in the same file and the same blocks of rows. A filter on
`h3` and `bbox` is a comparison of plain numbers, which the Parquet
reader applies before it reads any geometry.

A geometry that crosses the edge of its cell also lies in other cells.
The *index table* `<dataset>__h3` lists every such row with every cell
it touches. It is written, replaced and deleted with its dataset, and is
hidden unless asked for:

``` r

print(st, index = TRUE)
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  <tempdir>/geo-store
#> History: off (store default)
#> Datasets: 2
#>   name            kind        rows     size  files  updated
#>   shapes/
#>     polygons      geospatial   500  62.6 kB      1  2026-11-21 21:56
#>     polygons__h3  table        533  10.2 kB      1  2026-11-21 21:56
```

`h3` and `bbox` come back with the data.
[`store_h3_hex()`](https://ebukin.github.io/rcs/reference/store_h3_hex.md)
turns the cells into the 15-character text form that other H3 tools use:

``` r

x <- store_read(st, "polygons", geometry = FALSE)
store_h3_hex(x)
#> # A tibble: 500 × 5
#>       id   area cat   h3              bbox$xmin $ymin $xmax $ymax
#>    <int>  <dbl> <chr> <chr>               <dbl> <dbl> <dbl> <dbl>
#>  1   288 0.360  d     8556480ffffffff     -26.1  8.58 -26.1  8.58
#>  2     7 0.391  b     8556483bfffffff     -26.4  8.28 -25.9  8.54
#>  3    98 0.456  e     8556484bfffffff     -26.6  8.55 -26.6  8.55
#>  4   211 0.375  e     8556486bfffffff     -26.3  8.30 -26.3  8.31
#>  5   459 0.362  c     85564873fffffff     -26.2  8.48 -26.1  8.49
#>  6   474 0.0809 c     85564873fffffff     -26.1  8.49 -26.1  8.50
#>  7    50 0.0448 b     85564877fffffff     -26.2  8.42 -26.2  8.43
#>  8   274 0.124  a     85564877fffffff     -26.1  8.43 -26.1  8.43
#>  9   159 0.0612 e     855648b7fffffff     -25.5  8.78 -25.5  8.79
#> 10   304 0.0259 c     855648b7fffffff     -25.5  8.89 -25.5  8.89
#> # ℹ 490 more rows
```

## Read the rows in an area

`intersects` keeps the rows whose geometry intersects a query shape: an
`sf`, `sfc` or `bbox` object with a CRS.

``` r

query <- st_sfc(
  st_polygon(list(rbind(
    c(-28.5, 6.5), c(-26, 6.5), c(-27.2, 8.5), c(-28.5, 6.5)
  ))),
  crs = 4326
)
inside <- store_read(st, "polygons", intersects = query)
nrow(inside)
#> [1] 89
```

The read works in steps. It keeps only the files whose extent overlaps
the query’s box, reads the candidate rows (those whose `bbox` overlaps
the query’s box), and finally tests the candidates exactly with
[`sf::st_intersects()`](https://r-spatial.github.io/sf/reference/geos_binary_pred.html).
When the query’s box is much larger than the query (a thin diagonal
strip, a line), or the query crosses the antimeridian, the H3 cells
help: the read then also finds the cells the query touches, keeps only
files whose range of cells matches, and keeps only rows whose `h3`, or a
cell in the index table, is one of them. The result is the same as
filtering everything in memory:

``` r

setequal(inside$id, st_filter(polys, query)$id)
#> [1] TRUE
```

The query may be in another CRS than the data; it is transformed first.

``` r

query_utm <- st_transform(query, 32626)
nrow(store_read(st, "polygons", intersects = query_utm))
#> [1] 89
```

### Candidates only: `exact = FALSE`

The exact test needs the geometries. With `exact = FALSE`, or with
`geometry = FALSE`, the read returns the candidate rows: every
intersecting row and some rows that only come close. A message says so.

``` r

candidates <- store_read(st, "polygons",
  intersects = query, geometry = FALSE
)
#> ℹ Spatial filter: the geometry is not read, so the result is the candidate set.
#>   It holds every intersecting row and may hold rows that do not intersect the query.
nrow(candidates)
#> [1] 162
```

This is useful when the next step is a join on another column, or when
an approximate answer is enough and the geometries are large.

### H3 cells as query

The query can also be one or more H3 cells, of any resolution: as text,
as
[`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
or as an h3o `H3` vector. Each stands for its cell polygon. A plain
number is refused, because a double cannot hold an H3 cell exactly.

``` r

cell <- store_h3_hex(x$h3[1])
cell
#> [1] "8556480ffffffff"
store_read(st, "polygons", intersects = cell, columns = c(id, cat))
#> Simple feature collection with 1 feature and 2 fields
#> Geometry type: POLYGON
#> Dimension:     XY
#> Bounding box:  xmin: -26.05978 ymin: 8.578918 xmax: -26.05433 ymax: 8.584336
#> Geodetic CRS:  WGS 84
#> # A tibble: 1 × 3
#>      id cat                                                             geometry
#>   <int> <chr>                                                      <POLYGON [°]>
#> 1   288 d     ((-26.05978 8.578918, -26.05433 8.578918, -26.05433 8.584336, -26…
```

A cell finer than the stored resolution works too; a message says that
the stored resolution is coarser.

``` r

fine <- h3o::h3_from_xy(7.5, -27.5, 8L)
nrow(store_read(st, "polygons", intersects = fine))
#> ℹ The query holds cells finer than the stored resolution 5; the
#> cell filter works at resolution 5.
#> [1] 1
```

### In a lazy query

[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
adds the same filter to a lazy query from
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md),
where it combines with the dplyr verbs:

``` r

store_open(st, "polygons") |>
  store_intersects(query) |>
  dplyr::filter(cat == "a") |>
  dplyr::select(id, area) |>
  dplyr::collect()
#> # A tibble: 18 × 2
#>       id   area
#>    <int>  <dbl>
#>  1   308 0.207 
#>  2   369 0.464 
#>  3   477 0.423 
#>  4   435 0.0171
#>  5   175 0.196 
#>  6   130 0.0652
#>  7   432 0.454 
#>  8   196 0.0838
#>  9    83 0.208 
#> 10    56 0.205 
#> 11    24 0.0131
#> 12   115 0.325 
#> 13   479 0.0784
#> 14   388 0.0834
#> 15   263 0.455 
#> 16   482 0.415 
#> 17   194 0.462 
#> 18   138 0.144
```

## One file per cell: `partition = "h3"`

`partition = "h3"` writes one file per H3 parent cell. The package picks
the finest resolution at which the number of files stays at most
`max_files` and names the partition column after it (`h3_p2` below:
cells of resolution 2). A spatial read then opens only the files of the
cells near the query. For large datasets this makes small spatial reads
several times faster, most of all from a cloud bucket (see the article
“Benchmark: which steps of the spatial filter pay off”).

``` r

store_write(st, polys, "shapes/polygons_by_cell",
  title = "Polygons by cell",
  description = "Simulated polygons in open ocean, one file per H3 cell.",
  key = "id",
  partition = "h3",
  max_files = 10
)
#> ℹ Writing "shapes/polygons_by_cell": 500 rows in 7 files (partition h3_p2), and its index table in 1 file.
#> ✔ primary  <tempdir>/geo-store  8/8 files sent  156.8 kB  0.2s
#> ✔ MD5 identical for 8 files in 1 location. Catalogs updated.
```

The work counters show which files a read opened:

``` r

small <- st_as_sfc(st_bbox(
  c(xmin = -29.5, ymin = 6.2, xmax = -29.2, ymax = 6.5),
  crs = st_crs(4326)
))
options(rcs.trace = TRUE)
near <- store_read(st, "polygons_by_cell", intersects = small)
trace <- rcs_trace()
options(rcs.trace = FALSE)
trace[trace$counter == "file_open", c("detail", "n")]
#> # A tibble: 1 × 2
#>   detail                                                                       n
#>   <chr>                                                                    <dbl>
#> 1 shapes/polygons_by_cell/h3_p2=587654880185810943/part-c6ab2c8df9a86bde.…     1
```

One data file of seven was opened. The query is a compact box, so the
box test alone selects the rows, and the index table is not read.

## Without H3: `geocode = FALSE`

`geocode = FALSE` writes the geometries with their `bbox` only: no `h3`
column and no index table, so writing skips the geocoding. A spatial
read then filters by bounding boxes alone: as fast for compact queries,
slower for queries much smaller than their box, and always complete.
`partition = "h3"` cannot be combined with it.

``` r

store_write(st, polys, "shapes/polygons_boxes",
  title = "Polygons, boxes only",
  description = "Simulated polygons in open ocean, without H3 cells.",
  key = "id",
  geocode = FALSE
)
#> ℹ Writing "shapes/polygons_boxes": 500 rows in 1 file.
#> ✔ primary  <tempdir>/geo-store  1/1 files sent  61.1 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
nrow(store_read(st, "polygons_boxes", intersects = query))
#> [1] 89
```

## Rasters

A
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
is written as one Cloud Optimized GeoTIFF, a format that lets a reader
fetch only the tiles it needs.
[`rcs_sim_raster()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
returns a simulated three-layer raster over the same box.

``` r

grid <- rcs_sim_raster(seed = 1, nrow = 200, ncol = 200)
store_write(st, grid, "grids/simulated",
  title = "Simulated raster",
  description = "A simulated three-layer raster in open ocean."
)
#> ℹ Writing "grids/simulated": 40,000 cells in 1 file.
#> ✔ primary  <tempdir>/geo-store  1/1 files sent  686.5 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
```

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
opens the raster through GDAL. `intersects` crops it to the query’s
bounding box, rounded outwards to whole cells.

``` r

area <- st_as_sfc(st_bbox(
  c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
  crs = st_crs(4326)
))
store_read(st, "grids/simulated", intersects = area)
#> class       : SpatRaster
#> size        : 68, 34, 3  (nrow, ncol, nlyr)
#> resolution  : 0.03, 0.015  (x, y)
#> extent      : -28.02, -27, 6.99, 8.01  (xmin, xmax, ymin, ymax)
#> coord. ref. : lon/lat WGS 84 (EPSG:4326)
#> source(s)   : memory
#> varname     : part-a2f2827357463723
#> names       :      height, cover, moisture
#> min values  : -101.836024,     1,   0.0011
#> max values  :  103.103297,     5,   0.9989
```

A raster has one file: it cannot be partitioned or updated, only
replaced. Filters, `columns`, `geometry` and `exact` do not apply to
rasters, and
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
and
[`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md)
refuse them.

## Shapes across the antimeridian or around a pole

Geometries that cross the antimeridian (longitude ±180°) or contain a
pole are stored and found correctly. The package detects them, finds
their cells on the sphere, and always lists them in the index table,
because their bounding box, which may span all longitudes, says little
about where they lie. Query shapes of this kind are handled the same
way. These rows are defined on the sphere: with `sf::sf_use_s2(FALSE)` a
read is not guaranteed to find them. `rcs_sim_polygons(special = TRUE)`
adds one such polygon of each kind, for trying this out.
