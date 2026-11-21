# Add a spatial filter to a lazy query

Keeps the rows of a geospatial dataset whose geometry intersects `y`.
The filter first prunes files by their extent, then pushes a candidate
test on the stored bounding boxes (`bbox`) into the scan, and finally,
in `collect()`, tests the candidate rows exactly with
[`sf::st_intersects()`](https://r-spatial.github.io/sf/reference/geos_binary_pred.html)
under the session's
[`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
setting. When the box of `y` is much larger than `y` itself (a thin
diagonal strip, a line), or `y` crosses the antimeridian or holds a
pole, files are also pruned by their H3 cell range and the candidate
test also requires the stored H3 cell (`h3`, and the dataset's index
table for rows that cross cell edges) to touch `y`.

## Usage

``` r
store_intersects(q, y, exact = TRUE)
```

## Arguments

- q:

  A query made by
  [`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
  on a geospatial dataset.

- y:

  The query: an `sf`, `sfc` or `bbox` object with a coordinate reference
  system (in any CRS; several geometries are combined), or H3 cells of
  any resolution as hex strings,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
  or `h3o` `H3` vectors, which stand for their cell polygons. A plain
  number aborts: it cannot hold an H3 cell. The geometries of an `sf` or
  `sfc` query must be valid, or the call aborts with the reason and
  advice to repair them with
  [`sf::st_make_valid()`](https://r-spatial.github.io/sf/reference/valid.html)
  (only the query is checked). The check reads them as the exact test
  does: on the sphere (s2) when the query is in the data's geographic
  CRS and
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  is on, in the plane otherwise.

- exact:

  `TRUE` runs the exact test in `collect()`. `FALSE` returns the
  candidate rows, a superset of the intersecting rows, with a message
  saying so. The candidate set is also returned, with the same message,
  when the geometry is not collected.

## Value

The query with the filter added.

## Details

The filter applies to the rows of the dataset, before the other verbs of
the query. Several calls combine: a row must intersect every query.

## See also

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
whose `intersects` argument does the same.

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-intersects")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_polygons(200), "shapes/polygons",
  title = "Polygons", description = "Simulated polygons in open ocean."
)
#> Linking to GEOS 3.14.1, GDAL 3.12.1, PROJ 9.7.1; sf_use_s2() is TRUE
#> ℹ Writing "shapes/polygons": 200 rows in 1 file, and its index table in 1 file.
#> ✔ primary  C:/Users/EB2/AppData/Local/Temp/Rtmp6hCb4K/rcs-example-intersects  2/2
#>   files sent  41.1 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
area <- sf::st_as_sfc(sf::st_bbox(
  c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
  crs = sf::st_crs(4326)
))
store_open(st, "polygons") |>
  store_intersects(area) |>
  dplyr::collect()
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
unlink(location, recursive = TRUE)
```
