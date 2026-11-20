
<!-- README.md is generated from README.Rmd. Please edit that file -->

# rcs

rcs (R Cloud Storage) keeps tabular data, geospatial vector data (`sf`)
and rasters (`terra`) from R in one *store*, mostly as Parquet files. A
store is kept in one *primary* location and any number of *secondary*
ones: local folders or Google Cloud Storage buckets.

- **Catalog first.** Each location holds a small catalog of its datasets
  and files. Every function starts from it: listing a store, describing
  a dataset or finding the files a filter needs reads no data file.
- **Every write lands everywhere, verified.** A write goes to the
  primary and to every secondary, each file is checked by its MD5
  checksum, and the catalog is switched last, so readers see the old or
  the new version, never a mixture.
- **Reads fetch only what they need.** Filters and column selections are
  passed to the Parquet reader. Spatial filters use H3 cells and
  bounding boxes stored with the data, so an area is read without
  scanning every geometry.
- **Same data, same version.** Writing identical data again changes
  nothing and copies nothing.

## Installation

``` r
# install.packages("pak")
pak::pak("EBukin/rcs")
```

Geospatial datasets need the package h3o, rasters need terra, and Google
Cloud Storage needs gargle and httr2 and an arrow build with GCS
support.

## Example

Create a store in a folder, here a temporary one, and write a table. The
data are simulated by `rcs_sim_table()`.

``` r
library(rcs)

st <- store_connect(file.path(tempdir(), "my-store"), create = TRUE)

store_write(st, rcs_sim_table(500, seed = 1), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/my-store  2/2 files sent  38.2 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

See what the store holds:

``` r
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  <tempdir>/my-store
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   500  38.2 kB      2  2026-11-20 20:10
```

Read part of a dataset. Only the file of the year 2024 is opened.

``` r
store_read(st, "sales/daily", year == 2024, qty > 45,
  columns = c(shop_id, date, product, qty)
)
#> # A tibble: 20 × 4
#>    shop_id date       product   qty
#>      <int> <date>     <fct>   <int>
#>  1       4 2024-06-17 p16        48
#>  2       4 2024-09-16 p04        47
#>  3       4 2024-11-26 p15        49
#>  4       9 2024-10-04 p07        47
#>  5       9 2024-10-04 p10        46
#>  6      10 2024-02-24 p07        50
#>  7      10 2024-07-25 p17        47
#>  8      11 2024-12-11 p17        46
#>  9      12 2024-06-12 p17        50
#> 10      12 2024-09-09 p03        48
#> 11      13 2024-08-15 p10        48
#> 12      14 2024-04-24 p19        46
#> 13      14 2024-04-25 p06        50
#> 14      16 2024-09-13 p17        47
#> 15      17 2024-07-01 p19        48
#> 16      18 2024-07-25 p11        47
#> 17      18 2024-08-03 p13        48
#> 18      19 2024-08-26 p07        49
#> 19      20 2024-10-01 p05        50
#> 20      20 2024-10-10 p09        48
```

Keep the same store in a bucket and in a local copy; writes reach both
and reads use the local copy:

``` r
st <- store_connect("gs://my-bucket/store", secondary = "~/data/my-store")
```

## Learn more

- `vignette("rcs")`: getting started with a local store.
- `vignette("locations")`: primary and secondary locations, environment
  variables, cloud credentials.
- `vignette("geospatial")`: `sf` objects, spatial filters, rasters.

The package is developed and tested on simulated data only.
