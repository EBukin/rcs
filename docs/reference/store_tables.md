# List a store's datasets or a DuckDB connection's tables

For a store:
[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md)
plus the column `duckdb_view`, the name of the view
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
gives each dataset (`NA` for rasters, which have none). For a DuckDB
connection: its tables and views outside the schemas
`information_schema`, `pg_catalog` and `rcs`, with the dataset and
version of the views made by
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

## Usage

``` r
store_tables(x, st = NULL)
```

## Arguments

- x:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md),
  or a DuckDB connection.

- st:

  `NULL`, or, with a DuckDB connection, the store connection to compare
  the views' versions with.

## Value

A tibble. For a store, see
[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md).
For a connection, one row per table or view, sorted: `schema`, `name`,
`type` (`"table"` or `"view"`), `dataset` and `version` (`NA` for
objects not made by
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)),
and with `st` a column `current`: `TRUE` when the view shows the version
in `st`'s catalog, `FALSE` when not (call
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
again), `NA` for other objects.

## See also

[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md),
[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-tables")
st <- store_connect(root, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales."
)
#> ℹ Writing "sales/daily": 100 rows in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-tables  1/1
#>   files sent  13.7 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
store_tables(st)
#> # A tibble: 1 × 10
#>   dataset  kind  title  rows bytes n_files partition version updated            
#>   <chr>    <chr> <chr> <dbl> <dbl>   <int> <list>    <chr>   <dttm>             
#> 1 sales/d… table Dail…   100 13733       1 <chr [0]> 9eda87… 2026-11-27 13:56:52
#> # ℹ 1 more variable: duckdb_view <chr>
con <- store_duckdb(st)
#> ✔ DuckDB view (native mode, nothing read yet): `sales.daily`.
DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
store_tables(con, st)
#> # A tibble: 2 × 6
#>   schema name  type  dataset     version          current
#> * <chr>  <chr> <chr> <chr>       <chr>            <lgl>  
#> 1 main   mine  table NA          NA               NA     
#> 2 sales  daily view  sales/daily 9eda87d6a9e1e320 TRUE   
DBI::dbDisconnect(con, shutdown = TRUE)
unlink(root, recursive = TRUE)
```
