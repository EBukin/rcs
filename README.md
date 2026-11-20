
<!-- README.md is generated from README.Rmd. Please edit that file -->

# rcs

rcs (R Cloud Storage) stores tabular, geospatial vector and raster data
from R in one store, mainly as Parquet files. A store is kept in one
primary location and any number of secondary ones, local folders or
cloud buckets. Every operation starts from the catalog of the store.

The package is under construction: this version holds the foundations
(catalog schema, simulated data, work counters) and no storage functions
yet.

## Installation

``` r
# install.packages("pak")
pak::pak("EBukin/rcs")
```

## Simulated data

The package is developed and tested on simulated data only. The
generators are exported for examples:

``` r
library(rcs)
rcs_sim_table(5)
#> # A tibble: 5 × 15
#>   shop_id date        year product   qty price promo grade delivered      big
#>     <int> <date>     <int> <fct>   <int> <dbl> <lgl> <ord> <date>     <int64>
#> 1       8 2023-03-06  2023 p04        44  92.1 NA    <NA>  2023-03-12    9e15
#> 2      13 2023-11-24  2023 p08        25  66.8 TRUE  high  2023-12-02   NA   
#> 3       3 2024-01-11  2024 p08         6 130.  FALSE high  NA            9e15
#> 4      13 2023-03-08  2023 p05        39  52.0 FALSE mid   2023-03-09    3e 1
#> 5       7 2023-11-03  2023 p11        NA  NA   FALSE high  2023-11-07    9e15
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
```
