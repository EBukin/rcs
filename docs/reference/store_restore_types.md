# Restore the R types of a dataset's columns

Data read from a dataset's files by other tools
([`arrow::read_parquet()`](https://arrow.apache.org/docs/r/reference/read_parquet.html),
DuckDB, ...) carries the storage types: character instead of factor,
double instead of difftime, integer or double instead of `integer64`,
plain 64-bit integers instead of H3 cells. `store_restore_types()` gives
back the R types recorded in the catalog's columns specification of
`dataset`. No data file is read.

## Usage

``` r
store_restore_types(x, st, dataset)
```

## Arguments

- x:

  A data frame, tibble or `sf` object.

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset `x` comes from: the full name, or its last part
  when that is unique. Index tables (`<dataset>__h3`) are accepted.

## Value

`x` with the columns restored, of the same class (data frame, tibble or
`sf`).

## Details

Each column of `x` whose name is in the specification is restored when
its type is compatible:

- factor and ordered factor from character or factor, with the recorded
  levels (also the unused ones). Values outside the levels become `NA`,
  with one warning per column giving the count.

- difftime from double (taken in the recorded units) or difftime
  (converted to them).

- `integer64` from integer, `integer64`, or double when every value is
  whole and below 2^53 in absolute value; otherwise the column is left
  as it is, with a warning.

- list from an Arrow list or a list: a bare list.

- H3 cells (class
  [rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md)): the `h3`,
  `h3_main` and `h3_p<r>` columns of geospatial datasets and index
  tables, and every column recorded as `rcs_h3`.

Other columns are left unchanged, silently. Columns are matched by name
only: a computed column that reuses the name of a source column is
restored as that column.

`collect()` of a query from
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md),
with either engine, already restores the types; this function is for
data that reached R another way, such as a DuckDB query of your own on
the views of
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

## See also

[`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md)
for the recorded types (`r_type`),
[rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-restore-types")
st <- store_connect(root, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales."
)
#> ℹ Writing "sales/daily": 100 rows in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-restore-types  1/1
#>   files sent  13.7 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
path <- list.files(file.path(root, "sales/daily"),
  pattern = "\\.parquet$", full.names = TRUE
)
raw <- arrow::read_parquet(path[[1]])
class(raw$wait)
#> [1] "numeric"
restored <- store_restore_types(raw, st, "sales/daily")
class(restored$wait)
#> [1] "difftime"
unlink(root, recursive = TRUE)
```
