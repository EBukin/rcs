# Sample rows of a dataset

Reads a random sample of about `n` rows without reading the whole
dataset. Row groups (blocks of rows inside the files) are picked at
random across files, with probability proportional to their rows, and
only those are read; the filters are applied, and `n` rows are drawn
from the rows found. When the filters leave fewer than `n` rows, further
row groups are read until `n` rows are found or the dataset is
exhausted.

## Usage

``` r
store_sample(
  st,
  dataset,
  n = 1000,
  ...,
  columns = NULL,
  seed = NULL,
  geometry = TRUE,
  version = NULL
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset: the full name, or its last part when that is
  unique in the store.

- n:

  Number of rows wanted.

- ...:

  Filter expressions, as in
  [`dplyr::filter()`](https://dplyr.tidyverse.org/reference/filter.html).

- columns:

  Columns to return, as in
  [`dplyr::select()`](https://dplyr.tidyverse.org/reference/select.html)
  (tidyselect); `NULL` for all. The geometry column is controlled by
  `geometry`. A raster has no column selection.

- seed:

  `NULL`, or a number that makes the sample reproducible. The global
  random stream is left as it was
  ([`withr::with_seed()`](https://withr.r-lib.org/reference/with_seed.html)).

- geometry:

  `FALSE` drops the geometry before reading and returns a tibble.

- version:

  `NULL` for the current version, or the 16 hex characters of an earlier
  version kept in the history.

## Value

A tibble, or an `sf` object for geospatial data read with geometry, with
at most `n` rows.

## Details

This is a cluster sample, not a simple random sample: rows are stored
sorted (by key, or spatially by H3 cell), so the rows of one row group
are alike, and the sample covers only as many clusters as row groups
were read. Use it to look at data, not to estimate.

Unlike
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
it never copies the dataset to a secondary location.

## See also

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-sample")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(2000), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 2,000 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-sample  2/2
#>   files sent  89.1 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_sample(st, "sales/daily", n = 5, qty > 10, seed = 42)
#> # A tibble: 5 × 15
#>   shop_id date        year product   qty price promo grade delivered      big
#>     <int> <date>     <int> <fct>   <int> <dbl> <lgl> <ord> <date>     <int64>
#> 1       3 2024-04-22  2024 p14        28  95.5 FALSE high  2024-04-28   9 e15
#> 2       5 2024-05-16  2024 p10        23 198.  FALSE low   2024-05-18   9 e15
#> 3       5 2024-06-16  2024 p02        19  20.0 FALSE mid   2024-06-22   9 e15
#> 4       7 2024-07-02  2024 p15        27 164.  FALSE low   2024-07-10   3.e 2
#> 5       9 2024-09-10  2024 p16        15 123.  FALSE high  2024-09-15   9 e15
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
unlink(location, recursive = TRUE)
```
