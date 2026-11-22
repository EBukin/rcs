# Open a dataset as a lazy query

The usual way to work with a dataset: open it, describe the rows you
want with dplyr verbs, and read them into R with `collect()`. Opening
reads no data; the query is built from the files the dataset's catalog
names (the folder is never listed). The query is transformed with the
dplyr verbs [`filter()`](https://rdrr.io/r/stats/filter.html),
`select()`, `mutate()`, `rename()`, `arrange()`, `distinct()`,
[`head()`](https://rdrr.io/r/utils/head.html), and run with `collect()`
(an R data frame), `compute()` (rows kept in memory as Arrow data),
`pull()` or `glimpse()`. Arrow pushes filters and column selection into
the scan, so only the needed files, row groups and columns are read.
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
is the shortcut for `store_open()`,
[`filter()`](https://rdrr.io/r/stats/filter.html), `select()` and
`collect()` in one call.

## Usage

``` r
store_open(
  st,
  dataset,
  version = NULL,
  engine = c("arrow", "duckdb"),
  con = NULL,
  mode = "native",
  spatial = FALSE
)

# S3 method for class 'rcs_query'
print(x, ..., n = NULL)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  Name of the dataset: the full name, or its last part when that is
  unique in the store.

- version:

  `NULL` for the current version, or the 16 hex characters of an earlier
  version kept in the history (see
  [`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md)).
  Only `NULL` with `engine = "duckdb"`.

- engine:

  `"arrow"` (the default) for a lazy Arrow query of class `rcs_query`;
  `"duckdb"` for a dbplyr table on the dataset's DuckDB view (see
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
  and
  [`vignette("duckdb")`](https://ebukin.github.io/rcs/articles/duckdb.md)),
  of class `rcs_duckdb_tbl`. Every dbplyr verb works on it; its
  `collect()` restores the R types (factor levels, difftime units,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  [rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md) cells) and
  the geometry as for the Arrow engine, and drops `.rcs_id`. It needs
  the packages duckdb, DBI and dbplyr.

- con:

  With `engine = "duckdb"`: `NULL` for an in-memory connection that the
  package keeps, one per store, until the end of the session; or a
  DuckDB connection made with `bigint = "integer64"`, on which the view
  is created (or refreshed) as by `store_duckdb(st, con = con)`.

- mode, spatial:

  With `engine = "duckdb"`: as in
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

- x:

  A query made by `store_open()` with `engine = "arrow"`.

- ...:

  Passed to the tibble print method (for example `width`).

- n:

  Number of rows to print; `NULL` uses the option `rcs.print_rows` (10).

## Value

`store_open()`: a lazy query of class `rcs_query`, or with
`engine = "duckdb"` a lazy dbplyr table of class `rcs_duckdb_tbl`.
[`print()`](https://rdrr.io/r/base/print.html): `x`, invisibly.

## Details

- A filter whose columns are all partition columns is first evaluated on
  the partition values recorded in the catalog: only the files of the
  matching partitions are opened.

- [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
  adds a spatial filter.

- `collect()` returns a tibble, or an `sf` object for a geospatial
  dataset whose geometry is read, with the catalog's coordinate
  reference system. It restores the R types Arrow does not restore by
  itself (difftime units,
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html),
  factor levels, plain list columns) and drops the row identifier
  `.rcs_id` that the package adds to geospatial data; the columns `h3`,
  `bbox` and `h3_p<r>` are returned, the cells as
  [rcs_h3](https://ebukin.github.io/rcs/reference/rcs_h3.md) vectors.

The query reads from the location chosen as for
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
with the catalogs held by the connection.

## Printing

Printing a query reads its first rows, and only those: `head(n + 1)` of
the query, the exact test of a spatial filter included, so that it can
tell whether more rows exist without counting them. It opens the data
files it needs. The first `n` rows are shown as a tibble under a header:

- `Dataset:` the full name, the number of rows and columns, and the
  kind. The number of rows comes from the catalog when the query is the
  dataset itself, with columns selected, renamed or computed; after a
  filter, a spatial filter or any other verb it is shown as `??`. The
  number of columns is that of the data frame `collect()` returns.

- `Location:` the location read (`primary` or `secondary <n>`, local or
  GCS).

- `Version:` the first 8 characters of the version, current or earlier.

- `Files:` the files kept of the dataset's files, `(pruned)` when a
  filter on partition columns or a spatial filter dropped some.

- `Spatial:` the spatial filter, when set.

- `Filter:` the row filter, or `(with spatial predicate)` when a spatial
  filter is set.

The footer says how many rows are not shown (`more rows` when the total
is not known, `more rows may exist` while an exact spatial test is
pending) and reminds that `collect()` reads the rows into R. A table
opened with `engine = "duckdb"` prints as any dbplyr table.

## See also

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md),
[rcs_query-dplyr](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md),
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md).

## Examples

``` r
location <- file.path(tempdir(), "rcs-example-open")
st <- store_connect(location, create = TRUE)
store_write(st, rcs_sim_table(500), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-open  2/2
#>   files sent  38.1 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
q <- store_open(st, "daily")
q
#> # Dataset:  sales/daily [500 x 15] (table)
#> # Location: primary (local)
#> # Version:  9401e5a1 (current)
#> # Files:    2 of 2
#>    shop_id date        year product   qty price promo grade delivered      big
#>      <int> <date>     <int> <fct>   <int> <dbl> <lgl> <ord> <date>     <int64>
#>  1       1 2023-01-22  2023 p07        31  69.1 FALSE low   NA           9 e15
#>  2       1 2023-01-24  2023 p19        42 182.  FALSE low   2023-01-28   3 e 2
#>  3       1 2023-01-28  2023 p17        12  83.4 TRUE  mid   2023-01-29   2 e 2
#>  4       1 2023-03-12  2023 p07        21 129.  FALSE low   NA           6 e 2
#>  5       1 2023-03-15  2023 p18        29 157.  FALSE mid   2023-03-25   9 e15
#>  6       1 2023-03-27  2023 p08        NA  81.9 FALSE high  2023-04-03   9 e15
#>  7       1 2023-04-14  2023 p06        10 152.  TRUE  high  2023-04-16   3.e 2
#>  8       1 2023-05-11  2023 p04        39 180.  TRUE  mid   2023-05-18   9 e15
#>  9       1 2023-05-30  2023 p18        43 193.  FALSE high  2023-06-09   9 e15
#> 10       1 2023-06-04  2023 p08        28 153.  FALSE low   2023-06-13   8 e 2
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
#> # ℹ 490 more rows
#> # ℹ Use `collect()` to read the rows into R.
print(q, n = 3)
#> # Dataset:  sales/daily [500 x 15] (table)
#> # Location: primary (local)
#> # Version:  9401e5a1 (current)
#> # Files:    2 of 2
#>   shop_id date        year product   qty price promo grade delivered      big
#>     <int> <date>     <int> <fct>   <int> <dbl> <lgl> <ord> <date>     <int64>
#> 1       1 2023-01-22  2023 p07        31  69.1 FALSE low   NA            9e15
#> 2       1 2023-01-24  2023 p19        42 182.  FALSE low   2023-01-28    3e 2
#> 3       1 2023-01-28  2023 p17        12  83.4 TRUE  mid   2023-01-29    2e 2
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
#> # ℹ 497 more rows
#> # ℹ Use `collect()` to read the rows into R.
q |>
  dplyr::filter(year == 2024, qty > 40) |>
  dplyr::select(shop_id, date, qty) |>
  dplyr::collect()
#> # A tibble: 43 × 3
#>    shop_id date         qty
#>      <int> <date>     <int>
#>  1       1 2024-12-24    43
#>  2       2 2024-12-17    43
#>  3       3 2024-01-03    45
#>  4       4 2024-06-14    43
#>  5       4 2024-06-17    48
#>  6       4 2024-09-16    47
#>  7       4 2024-11-26    49
#>  8       5 2024-06-09    45
#>  9       6 2024-02-21    43
#> 10       9 2024-02-28    41
#> # ℹ 33 more rows
unlink(location, recursive = TRUE)
```
