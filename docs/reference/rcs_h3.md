# H3 cells as 64-bit integers, printed as hex

Cells read from a store (`h3`, `h3_main`, `h3_p<r>` and any column
written as `rcs_h3`) have class `rcs_h3`: a
[`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
vector holding the same 64 bits that Parquet stores, sorts and filters,
printed (console, tibble, `sf`) as the 15-character lower-case hex
string that other H3 tools use.

- Comparison, arithmetic, sorting and joins are those of `integer64`;
  joining an `rcs_h3` column with an `integer64` column works and gives
  `rcs_h3` (also with
  [`dplyr::bind_rows()`](https://dplyr.tidyverse.org/reference/bind_rows.html)
  and [`vctrs::vec_c()`](https://vctrs.r-lib.org/reference/vec_c.html)).

- Subsetting, [`c()`](https://rdrr.io/r/base/c.html),
  [`rep()`](https://rdrr.io/r/base/rep.html),
  [`unique()`](https://rdrr.io/r/base/unique.html),
  [`sort()`](https://rdrr.io/r/base/sort.html) and
  [`rev()`](https://rdrr.io/r/base/rev.html) keep the class.

- [`format()`](https://rdrr.io/r/base/format.html) and printing show
  `NA` as `NA` and a value that is not a valid cell as `<invalid>`; they
  never fail.

- [`as.character()`](https://rdrr.io/r/base/character.html) gives
  decimal strings, exactly as for `integer64`; use
  [`rcs_h3_hex()`](https://ebukin.github.io/rcs/reference/rcs_h3_hex.md)
  for hex strings.

- A column of class `rcs_h3` is stored as a 64-bit integer, like an
  `integer64` column; `class(x) <- "integer64"` or
  [`bit64::as.integer64()`](https://bit64.r-lib.org/reference/as.integer64.character.html)
  drops the class.

- Inside DuckDB cells stay 64-bit integers (`BIGINT`); the SQL macro
  [`rcs_h3_hex()`](https://ebukin.github.io/rcs/reference/rcs_h3_hex.md)
  of connections prepared by
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
  gives their hex strings. `collect()` of a table opened with
  `store_open(engine = "duckdb")` gives `rcs_h3` again; a
  [`dplyr::tbl()`](https://dplyr.tidyverse.org/reference/tbl.html) on a
  view of
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
  is collected by dbplyr and does not. Data read by other tools, or by
  such a `tbl()`, get the class back with
  [`store_restore_types()`](https://ebukin.github.io/rcs/reference/store_restore_types.md).

## See also

[`rcs_h3_hex()`](https://ebukin.github.io/rcs/reference/rcs_h3_hex.md),
[`store_h3_hex()`](https://ebukin.github.io/rcs/reference/store_h3_hex.md),
[`store_restore_types()`](https://ebukin.github.io/rcs/reference/store_restore_types.md);
[`vignette("geospatial")`](https://ebukin.github.io/rcs/articles/geospatial.md).

## Examples

``` r
cells <- bit64::as.integer64(c("599686042433355775", "599686030622195711"))
rcs_h3_hex(cells)
#> [1] "85283473fffffff" "85283447fffffff"
```
