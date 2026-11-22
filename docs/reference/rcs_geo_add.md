# Add, index and strip the package's geospatial columns

In-memory verbs that prepare an `sf` object the way
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
does, without contacting a store, and take a dataset read from a store
back to its raw form. They keep the row order and the column order of
`x`; new columns go immediately before the active geometry column.

## Usage

``` r
rcs_geo_add(
  x,
  h3_res = 5L,
  bbox = TRUE,
  parents = NULL,
  geocode_engine = c("auto", "s2", "planar"),
  replace = FALSE
)

rcs_geo_index(
  x,
  id,
  h3_res = 5L,
  geocode_engine = c("auto", "s2", "planar"),
  crossing_only = TRUE
)

rcs_geo_strip(x, columns = NULL)
```

## Arguments

- x:

  An `sf` object with a CRS.

- h3_res:

  H3 resolution of the cells, 0 to 15. For `rcs_geo_add()`, `NULL` adds
  no cell column.

- bbox:

  `TRUE` adds the column `bbox`.

- parents:

  Resolutions below `h3_res` to add as `h3_p<r>` columns, or `NULL`.

- geocode_engine:

  How the cells of geometries that cross cell edges are computed:
  `"auto"`, `"s2"` or `"planar"`, as in
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

- replace:

  A column that is already in `x` with other values aborts unless
  `replace = TRUE`, which recomputes it; one with equal values is kept.

- id:

  Name of the column of `x` that identifies its rows.

- crossing_only:

  `TRUE` lists only the rows that touch more than one cell (as a
  dataset's index table does); `FALSE` adds one line per other row, with
  its cell and `share = 1`.

- columns:

  Names of the columns to drop; `NULL` drops `.rcs_id`, `h3`, `h3_main`,
  `bbox`, every `h3_p<r>`, and `geom` unless it is the active geometry
  column.

## Value

`rcs_geo_add()` and `rcs_geo_strip()`: `x` with the columns added or
removed. `rcs_geo_index()`: a tibble with the column `id`, then `h3` (a
cell the row touches), `h3_main` (the row's own cell; both
[rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md)) and `share`
(the fraction of the row's area or length in that cell; `1 / n` for
points), ordered by row of `x`, then cell.

## Details

- `rcs_geo_add()` adds `h3` (class
  [rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md): the H3
  cell at `h3_res` holding the largest part of each geometry), one
  `h3_p<r>` per resolution `r` in `parents` (the parent of `h3` at that
  resolution, for grouping and partitioning) and `bbox` (a data-frame
  column with `xmin`, `ymin`, `xmax`, `ymax` in the CRS of `x`). The
  values equal those a write with the same `h3_res` and `geocode_engine`
  computes, so prepared data can be written as they are.

- `rcs_geo_index()` gives the cells each geometry touches: one line per
  row and cell, as the index table of a dataset holds them, keyed by a
  column of `x` instead of the package's row identifier.

- `rcs_geo_strip()` removes the package's columns, so that a dataset
  read with `collect()` goes back to the form it was written from.

Geometries invalid on the sphere are handled as in
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
(see its argument `geocode_engine`); one warning names their row
numbers.

## Prepared writes

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
accepts the result of `rcs_geo_add()`: it drops `.rcs_id`, computes `h3`
and `bbox` itself and compares them with the supplied ones. Equal values
are accepted silently, so that raw and prepared writes of the same data
give the same version; different values abort (class
`rcs_error_prepared`) naming the first rows and the engine of the write.
`h3_res` is taken from the supplied cells when the write does not give
it. The `h3_p<r>` columns are stored as user columns; with
`partition = "h3"`, one equal to the partition column the write chooses
serves as it.

## Round trip

For `store_write(st, rcs_geo_add(raw), dataset, key = k)`,
`rcs_geo_strip(collect(store_open(st, dataset)))` ordered by `k` equals
`raw` ordered by `k`: the same attributes, identical WKB geometries and
the same CRS.

## See also

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md),
which accepts prepared data and checks them;
[`vignette("geospatial")`](https://ebukin.github.io/rcs/articles/geospatial.md).

## Examples

``` r
raw <- rcs_sim_polygons(20, seed = 1)

prepared <- rcs_geo_add(raw, h3_res = 5, parents = 3)
#> Linking to GEOS 3.14.1, GDAL 3.12.1, PROJ 9.7.1; sf_use_s2() is TRUE
prepared
#> Simple feature collection with 20 features and 6 fields (with 1 geometry empty)
#> Geometry type: GEOMETRY
#> Dimension:     XY
#> Bounding box:  xmin: -29.87392 ymin: 6.1 xmax: -24.818 ymax: 8.615313
#> Geodetic CRS:  WGS 84
#> # A tibble: 20 × 7
#>       id       area cat   h3              h3_p3           bbox$xmin $ymin $xmax
#>  * <int>      <dbl> <chr> <h3>            <h3>                <dbl> <dbl> <dbl>
#>  1     1 46041.     c     857c4bd3fffffff 837c4bfffffffff     -29.8  6.1  -27.3
#>  2     2  4487.     b     8556494bfffffff 835649fffffffff     -25.9  7.88 -25.2
#>  3     3  6755.     b     857c5ab3fffffff 837c5afffffffff     -26.6  6.2  -25.8
#>  4     4    30.1    e     85565813fffffff 835658fffffffff     -29    8.5  -26.3
#>  5     5     0.392  b     857c5b47fffffff 837c5bfffffffff     -26.8  7.29 -26.7
#>  6     6     0.392  a     85565903fffffff 835659fffffffff     -28.0  7.73 -27.9
#>  7     7     0.391  c     8556483bfffffff 835648fffffffff     -26.4  8.28 -25.9
#>  8     8     4.90   c     85565937fffffff 835659fffffffff     -27.6  7.49 -27.6
#>  9     9    NA      d     NA              NA                   NA   NA     NA  
#> 10    10     0.131  c     85565d27fffffff 83565dfffffffff     -27.6  8.43 -27.6
#> 11    11     0.0227 a     857ce987fffffff 837ce9fffffffff     -25.5  6.76 -25.5
#> 12    12     0.395  d     857c59a3fffffff 837c59fffffffff     -28.4  6.59 -28.4
#> 13    13     0.282  e     85565d23fffffff 83565dfffffffff     -27.7  8.45 -27.7
#> 14    14     0.271  a     85565a13fffffff 83565afffffffff     -29.9  7.99 -29.9
#> 15    15     0.399  a     85565d2ffffffff 83565dfffffffff     -27.7  8.35 -27.7
#> 16    16     0.0215 d     857ced6bfffffff 837cedfffffffff     -24.8  6.36 -24.8
#> 17    17     0.245  e     8556599bfffffff 835659fffffffff     -27.9  8.15 -27.9
#> 18    18     0.370  e     857c5b07fffffff 837c5bfffffffff     -27.1  7.24 -27.1
#> 19    19     0.351  d     8556487bfffffff 835648fffffffff     -26.4  8.43 -26.4
#> 20    20     0.245  e     85564a77fffffff 83564afffffffff     -27.0  7.92 -27.0
#> # ℹ 2 more variables: bbox$ymax <dbl>, geometry <GEOMETRY [°]>

rcs_geo_index(raw, "id", h3_res = 5)
#> # A tibble: 315 × 4
#>       id h3              h3_main             share
#>    <int> <h3>            <h3>                <dbl>
#>  1     1 85565907fffffff 857c4bd3fffffff 0.000372 
#>  2     1 8556590bfffffff 857c4bd3fffffff 0.0000199
#>  3     1 8556590ffffffff 857c4bd3fffffff 0.00316  
#>  4     1 85565923fffffff 857c4bd3fffffff 0.00564  
#>  5     1 85565927fffffff 857c4bd3fffffff 0.00563  
#>  6     1 8556592bfffffff 857c4bd3fffffff 0.00565  
#>  7     1 8556592ffffffff 857c4bd3fffffff 0.00565  
#>  8     1 85565933fffffff 857c4bd3fffffff 0.00375  
#>  9     1 85565937fffffff 857c4bd3fffffff 0.00562  
#> 10     1 8556593bfffffff 857c4bd3fffffff 0.00564  
#> # ℹ 305 more rows

identical(rcs_geo_strip(prepared), raw)
#> [1] TRUE
```
