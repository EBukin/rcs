# Simulated table of daily sales

A panel of invented shops selling invented products, with one column of
every type the package has to store faithfully. The rows are in random
order and are the same for the same `n` and `seed`; the random number
stream of the session is not changed.

## Usage

``` r
rcs_sim_table(n = 1000, seed = 1)
```

## Arguments

- n:

  Number of rows; zero gives an empty table with all columns.

- seed:

  Seed of the generator.

## Value

A tibble with `n` rows and the columns:

- `shop_id` (integer), `date` (Date) and `product` (factor with the
  levels `p01` to `p20`, of which `p20` is never used): together they
  identify a row, and hold no missing values;

- `year` (integer): the year of `date`, at least two different years, no
  missing values;

- `qty` (integer), `price` (double), `promo` (logical);

- `grade` (ordered factor `low` \< `mid` \< `high`);

- `delivered` (Date);

- `big`
  ([bit64::integer64](https://bit64.r-lib.org/reference/bit64-package.html),
  with small values and values above 2^53);

- `wait` (difftime in hours);

- `note` (character, with accented and non-Latin text);

- `tags` (list of character vectors, some empty, some `NULL`);

- `ts` (POSIXct in UTC) and `ts_local` (the same instants in the time
  zone of the session).

Every column from `qty` on holds missing values when `n` is positive.

## Examples

``` r
rcs_sim_table(5)
#> # A tibble: 5 × 15
#>   shop_id date        year product   qty price promo grade delivered      big
#>     <int> <date>     <int> <fct>   <int> <dbl> <lgl> <ord> <date>     <int64>
#> 1       8 2023-03-06  2023 p04        44  92.1 NA    NA    2023-03-12    9e15
#> 2      13 2023-11-24  2023 p08        25  66.8 TRUE  high  2023-12-02   NA   
#> 3       3 2024-01-11  2024 p08         6 130.  FALSE high  NA            9e15
#> 4      13 2023-03-08  2023 p05        39  52.0 FALSE mid   2023-03-09    3e 1
#> 5       7 2023-11-03  2023 p11        NA  NA   FALSE high  2023-11-07    9e15
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
```
