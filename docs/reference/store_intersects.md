# Add a spatial filter to a lazy query

Keeps the rows of a geospatial dataset whose geometry intersects `y`.
The filter first prunes files by their extent, then pushes a candidate
test on the stored bounding boxes (`bbox`) into the scan, and finally,
in `collect()`, tests the candidate rows exactly, on the sphere or in
the plane as `exact_engine` says. When the box of `y` is much larger
than `y` itself (a thin diagonal strip, a line), or `y` crosses the
antimeridian or holds a pole, files are also pruned by their H3 cell
range and the candidate test also requires the stored H3 cell (`h3`, and
the dataset's index table for rows that cross cell edges) to touch `y`.

## Usage

``` r
store_intersects(q, y, exact = TRUE, exact_engine = NULL)
```

## Arguments

- q:

  A query made by
  [`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
  on a geospatial dataset, with either engine.

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
  CRS and the exact engine works on the sphere (`"s2"`, `"auto"`, or
  `"session"` with
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  on), in the plane otherwise. A query valid only in the plane can be
  used with `exact_engine = "planar"`.

- exact:

  `TRUE` runs the exact test in `collect()`. `FALSE` returns the
  candidate rows, a superset of the intersecting rows, with a message
  saying so. The candidate set is also returned, with the same message,
  when the geometry is not collected. On a DuckDB table, `"sql"` runs
  the exact test in DuckDB instead (`ST_Intersects()` of its `spatial`
  extension, installed and loaded when needed; the first installation
  downloads it): the query stays lazy, so the result can be aggregated
  or joined in DuckDB, and the test is in the plane of the coordinates
  whatever `exact_engine`. It returns the rows the Arrow engine returns
  with `exact_engine = "planar"`, except for queries across the
  antimeridian or around a pole.

- exact_engine:

  How the exact test reads the geometries. `NULL` (the default) follows
  the geocoding engine the dataset was written with (`geocode_engine` of
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)):
  `"s2"` tests on the sphere (a row invalid on the sphere is first
  rebuilt by s2, as the write did), `"planar"` in the plane of the
  coordinates, `"auto"` on the sphere for rows valid on the sphere and
  in the plane for the others; a dataset with no recorded engine
  (written before engines were recorded, or with `geocode = FALSE`)
  follows the session's
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  setting. `"s2"`, `"planar"` or `"session"` (the
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  setting) override the dataset's engine. Data in a projected CRS are
  always tested in the plane of that CRS.

## Value

The query with the filter added.

## Details

The filter applies to the rows of the dataset, before the other verbs of
the query. Several calls combine: a row must intersect every query.

On a DuckDB table (`store_open(engine = "duckdb")`) the candidate test
is added to the table's SQL: the box test on `bbox` and, when the cell
filter is used, `h3` and the dataset's index view. The table must
therefore still hold `bbox` and, for the cell filter, `h3` and `.rcs_id`
(`geometry` too with `exact = "sql"`): call `store_intersects()` before
a [`dplyr::select()`](https://dplyr.tidyverse.org/reference/select.html)
that drops them. Above 10,000 cells, the cells go to a temporary table
on the connection, kept until it is closed. With `exact = TRUE` the
exact test runs in R in `collect()`, with the same engine and the same
rows as on the Arrow engine; `exact = FALSE` gives the same candidate
rows as on the Arrow engine. See
[`vignette("duckdb")`](https://ebukin.github.io/rcs/articles/duckdb.md).

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
#> ℹ Writing "shapes/polygons": 200 rows in 1 file, and its index table in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-intersects  2/2
#>   files sent  41.2 kB  0.2s
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
unlink(location, recursive = TRUE)
```
