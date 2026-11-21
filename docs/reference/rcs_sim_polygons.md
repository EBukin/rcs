# Simulated geospatial data

Polygons, points, lines and a raster in a box of open ocean: longitude
-30 to -24, latitude 6 to 9, EPSG:4326. The box is cut by an edge
between two H3 cells of resolution 0, so the shapes exercise every level
of the H3 grid. The result is the same for the same arguments; the
random number stream of the session is not changed.

## Usage

``` r
rcs_sim_polygons(n = 1000, seed = 1, crossing_share = 0.1, special = FALSE)

rcs_sim_points(n = 1000, seed = 1)

rcs_sim_lines(n = 1000, seed = 1)

rcs_sim_raster(seed = 1, nrow = 1000, ncol = 1000)
```

## Arguments

- n:

  Number of rows (without the two special rows); at least 20 for
  polygons, at least 0 for points and lines.

- seed:

  Seed of the generator.

- crossing_share:

  Share of rows built to cross H3 cell edges of resolution 5, between 0
  and 0.5.

- special:

  Add the antimeridian and the pole polygon.

- nrow, ncol:

  Size of the raster in cells.

## Value

`rcs_sim_polygons()`: an `sf` tibble with the columns `id` (integer),
`area` (double, square kilometres, `NA` for the empty geometry), `cat`
(character, `a` to `e`) and `geometry` (polygons and multipolygons). It
needs the h3o package.

`rcs_sim_points()`: an `sf` tibble with the columns `id` (integer),
`value` (double), `cat` (character) and `geometry` (points spread evenly
over the box).

`rcs_sim_lines()`: an `sf` tibble with the columns `id` (integer),
`length` (double, kilometres), `cat` (character) and `geometry` (lines
of two to six vertices, up to some tens of kilometres long).

`rcs_sim_raster()`: a
[`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html)
over the box with the layers `height` (double, smooth), `cover` (integer
classes 1 to 5) and `moisture` (double, with missing cells). It needs
the terra package.

## Details

`rcs_sim_polygons()` returns rows of three groups, in this order of
`id`:

- `id` 1 to 9, fixed shapes: (1) a rectangle with four vertices that
  covers more than 100 H3 cells of resolution 5; (2) a large polygon
  with many vertices; (3) a large polygon with a hole; (4) a thin
  polygon about 300 km long and 100 m wide; (5 to 7) multipolygons, the
  last with parts in different cells; (8) a polygon across the edge
  between the two resolution-0 cells; (9) an empty geometry.

- then `round(crossing_share * n)` small squares centred on a vertex of
  an H3 cell of resolution 5, so each crosses cell edges;

- then small squares and hexagons of 0.01 to 0.5 square kilometres at
  random places.

With `special = TRUE`, two rows outside the box follow, both in open
ocean: `id` `n + 1`, a polygon across the antimeridian (longitude 179 to
-179, latitude 6 to 9), and `id` `n + 2`, a polygon around the north
pole (above latitude 88).

For a projected case, transform the result:
`sf::st_transform(rcs_sim_polygons(), 32626)`.

## Examples

``` r
rcs_sim_polygons(30)
#> Simple feature collection with 30 features and 3 fields (with 1 geometry empty)
#> Geometry type: GEOMETRY
#> Dimension:     XY
#> Bounding box:  xmin: -29.8 ymin: 6.1 xmax: -24.55762 ymax: 8.700378
#> Geodetic CRS:  WGS 84
#> # A tibble: 30 × 4
#>       id       area cat                                                 geometry
#>    <int>      <dbl> <chr>                                         <GEOMETRY [°]>
#>  1     1 46041.     e     POLYGON ((-29.8 6.1, -27.3 6.1, -27.3 7.6, -29.8 7.6,…
#>  2     2  4487.     d     POLYGON ((-25.18752 8.2, -25.21461 8.36477, -25.31917…
#>  3     3  6755.     d     POLYGON ((-26.6 6.2, -25.8 6.2, -25.8 7, -26.6 7, -26…
#>  4     4    30.1    a     POLYGON ((-29 8.5, -26.27514 8.5, -26.27514 8.500904,…
#>  5     5     0.392  e     MULTIPOLYGON (((-26.75391 7.293398, -26.74991 7.29339…
#>  6     6     0.392  e     MULTIPOLYGON (((-27.96559 7.733237, -27.96159 7.73323…
#>  7     7     0.391  a     MULTIPOLYGON (((-26.42263 8.281812, -26.41863 8.28181…
#>  8     8     4.90   a     POLYGON ((-27.59022 7.49, -27.57022 7.49, -27.57022 7…
#>  9     9    NA      c                                              POLYGON EMPTY
#> 10    10     0.0430 b     POLYGON ((-27.62909 6.7148, -27.62722 6.7148, -27.627…
#> # ℹ 20 more rows
rcs_sim_points(5)
#> Simple feature collection with 5 features and 3 fields
#> Geometry type: POINT
#> Dimension:     XY
#> Bounding box:  xmin: -28.78991 ymin: 6.185359 xmax: -24.55075 ymax: 8.834026
#> Geodetic CRS:  WGS 84
#> # A tibble: 5 × 4
#>      id value cat               geometry
#>   <int> <dbl> <chr>          <POINT [°]>
#> 1     1  87.7 a     (-28.40695 8.695169)
#> 2     2 107.  e     (-27.76726 8.834026)
#> 3     3 111.  e     (-26.56288 7.982393)
#> 4     4 109.  a     (-24.55075 7.887342)
#> 5     5  95.4 a     (-28.78991 6.185359)
rcs_sim_lines(5)
#> Simple feature collection with 5 features and 3 fields
#> Geometry type: LINESTRING
#> Dimension:     XY
#> Bounding box:  xmin: -29.6897 ymin: 6.52967 xmax: -24.28276 ymax: 8.341432
#> Geodetic CRS:  WGS 84
#> # A tibble: 5 × 4
#>      id length cat                                                      geometry
#>   <int>  <dbl> <chr>                                            <LINESTRING [°]>
#> 1     1   5.75 d                         (-24.33195 6.52967, -24.28276 6.546517)
#> 2     2  18.0  a     (-26.03521 8.061069, -26.00747 8.021863, -25.964 8.044234,…
#> 3     3   4.06 b                        (-26.22532 7.152311, -26.24859 7.180604)
#> 4     4   8.83 c     (-29.62928 8.309524, -29.67794 8.312496, -29.6897 8.341432)
#> 5     5  12.3  b     (-28.76415 7.493098, -28.78012 7.490821, -28.78191 7.51405…
rcs_sim_raster(nrow = 20, ncol = 20)
#> class       : SpatRaster
#> size        : 20, 20, 3  (nrow, ncol, nlyr)
#> resolution  : 0.3, 0.15  (x, y)
#> extent      : -30, -24, 6, 9  (xmin, xmax, ymin, ymax)
#> coord. ref. : lon/lat WGS 84 (EPSG:4326)
#> source(s)   : memory
#> names       :     height, cover, moisture
#> min values  : -100.90093,     1,   0.0013
#> max values  : 101.841787,     5,   0.9999
```
