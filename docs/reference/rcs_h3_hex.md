# Hex strings of H3 cells

Converts any vector of H3 cells to the 15-character lower-case hex
strings that other H3 tools use. Inside a DuckDB connection prepared by
the package, the SQL macro of the same name gives the same strings, so
`dplyr::mutate(cell = rcs_h3_hex(h3))` reads the same in both engines.

## Usage

``` r
rcs_h3_hex(x)
```

## Arguments

- x:

  Cells: `rcs_h3`,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  hex strings (any case), an `h3o` `H3` vector, or doubles. A double
  cannot hold a cell exactly (cells are above 2^53), so doubles give a
  warning of class `rcs_warning_h3_double` and are then validated like
  any other input; a cell whose last bits were lost is no longer a valid
  cell.

## Value

A character vector of the same length; `NA` stays `NA`. Aborts with
class `rcs_error_h3_input` when a value is not a valid cell or `x` has
another type.

## See also

[rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md),
[`store_h3_hex()`](https://ebukin.github.io/rcs/reference/store_h3_hex.md)
for the cell columns of a data frame.

## Examples

``` r
cells <- bit64::as.integer64(c("599686042433355775", NA))
rcs_h3_hex(cells)
#> [1] "85283473fffffff" NA               
rcs_h3_hex("85283473FFFFFFF")
#> [1] "85283473fffffff"
rcs_h3_hex(h3o::h3_from_strings("85283473fffffff"))
#> [1] "85283473fffffff"
```
