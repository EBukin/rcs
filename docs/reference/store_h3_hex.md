# H3 cells as hex strings

Cells are stored as 64-bit integers
([`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)),
the compact form that Parquet filters and sorts fast. `store_h3_hex()`
converts them to the 15-character hex strings that other H3 tools use.

## Usage

``` r
store_h3_hex(x, columns = NULL)
```

## Arguments

- x:

  A data frame returned by a read (a tibble or an `sf` object), or a
  vector of cells
  ([`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  hex strings or `h3o` `H3`).

- columns:

  For a data frame, the columns to convert (tidyselect); `NULL` converts
  the cell columns the package adds that are present: `h3`, `h3_main`
  and `h3_p<r>`.

## Value

For a data frame, `x` with those columns as character; for a vector, a
character vector of the same length. `NA` stays `NA`. A plain number
aborts: it cannot hold an H3 cell.

## Examples

``` r
cells <- bit64::as.integer64("599686042433355775")
store_h3_hex(cells)
#> [1] "85283473fffffff"

x <- data.frame(id = 1, h3 = cells)
store_h3_hex(x)
#>   id              h3
#> 1  1 85283473fffffff
```
