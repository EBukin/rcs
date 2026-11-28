# Query a store's datasets in DuckDB

Creates one DuckDB view per dataset of the store's primary catalog
(rasters excluded, the H3 index tables of geospatial datasets included),
so that the datasets can be queried with SQL or with dbplyr. A view
stores no data: DuckDB reads the Parquet files when a query runs, and
only the columns and row groups the query needs. The file list comes
from the catalog held by the connection `st`, so the views show the
versions it knows: after
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
call `store_duckdb()` again. One message names the views made. Unlike
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md),
it never copies a dataset to a secondary location.

## Usage

``` r
store_duckdb(
  st,
  path = NULL,
  datasets = NULL,
  mode = c("native", "arrow"),
  spatial = FALSE,
  con = NULL
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).
  It may be left out only with `path`, to reopen a file prepared
  earlier.

- path:

  `NULL` for an in-memory database, or the path of a DuckDB database
  file (see "Database files").

- datasets:

  `NULL` for every dataset, or full or short dataset names; their index
  tables are added.

- mode:

  `"native"` or `"arrow"`, see above.

- spatial:

  `TRUE` loads the DuckDB `spatial` extension (downloaded on first use).

- con:

  `NULL` to create a new connection, or an existing DuckDB connection
  made with `bigint = "integer64"` (H3 cells do not fit a double);
  `path` must then be `NULL`.

## Value

The DuckDB connection, invisibly. Close it with
`DBI::dbDisconnect(con, shutdown = TRUE)`.

## Details

The views are queried with SQL
([`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)),
with dbplyr (`dplyr::tbl(con, DBI::Id(schema = , table = ))`, or
`store_open(st, dataset, engine = "duckdb", con = con)`, whose
`collect()` restores the R types and the geometry and which takes
[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)),
and can be joined with your own tables. A lazy table on the connection
can be written back to the store with
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).
[`vignette("duckdb")`](https://ebukin.github.io/rcs/articles/duckdb.md)
shows each step.

- View names: the first part of the dataset name is the schema, the
  other parts joined with `__` are the view; a one-part name goes to
  schema `main`. `"sales/daily"` is the view `sales.daily`, `"a/b/c"` is
  `a.b__c`. Two datasets with the same view name, a first part `rcs`, or
  a first part equal to the name of an attached database (such as
  `memory` or `system`) abort.

- `mode = "native"` (the default): DuckDB reads the files itself with
  `read_parquet()`, from the location a read would use. For locations on
  Google Cloud Storage a temporary DuckDB secret is created from the
  location's credential (see
  [`rcs_auth_gcs()`](https://ebukin.github.io/rcs/reference/rcs_auth_gcs.md));
  it lives only in this connection and holds an access token, valid for
  about an hour. After an hour of DuckDB work on a bucket, call
  `store_duckdb()` again: every call renews the secrets. The `geometry`
  column of geospatial datasets is of DuckDB type `GEOMETRY`, readable
  without the `spatial` extension.

- `mode = "arrow"`: the Arrow dataset the package opens for reads is
  registered in DuckDB and the view selects from it, so DuckDB needs no
  credential of its own; filters are pushed into the Arrow scan. The
  `geometry` column is WKB (`BLOB`). The registration lasts only as long
  as the connection: in a database file such views stop working once it
  is closed (see "Database files").

- `spatial = TRUE` installs and loads DuckDB's `spatial` extension and,
  in arrow mode, adds a column `geom` (`GEOMETRY`) to geospatial views.

- H3 cells are `BIGINT` columns, read into R as
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html);
  the macro `rcs_h3_hex(x)` turns them into hex strings in SQL.

The connection records its views in the table `rcs.views` (`view`,
`dataset`, `version`, `location`, `mode`, `refreshed` in UTC) and the
store's locations in `rcs.store` (`role`, `uri`); neither holds a
credential. A connection serves one store. With `datasets = NULL` both
tables are rewritten and the views of datasets no longer in the catalog
are dropped; with `datasets` given only those views and rows are
replaced.
[`store_tables()`](https://ebukin.github.io/rcs/reference/store_tables.md)
lists what a connection holds.

## Database files

With `path`, the views, the `rcs` tables and the tables you create live
in a DuckDB file, created when missing. A file `work.duckdb` is attached
as the database `work`, so no dataset may have the first part `work`.
The file must lie outside every local location of the store, which a
sync would carry it to.

Calling `store_duckdb(st, path)` again on the same file refreshes it:
views are replaced to show the versions in `st`'s catalog, views of
deleted datasets are dropped, secrets are recreated, and your own tables
and views are left untouched (a table or a view not made by
`store_duckdb()` with a view's name aborts). `store_duckdb(path = )`
without `st` reconnects to the store recorded in `rcs.store`, with
default credentials, and refreshes the same way.

A plain
`DBI::dbConnect(duckdb::duckdb(dbdir = path), bigint = "integer64")`
also opens the file: your tables work, and native views work while their
files exist, but they show the versions of the last refresh (a later
write may have deleted those files, unless the store keeps history),
views on Google Cloud Storage need a secret first, and views in arrow
mode do not work until `store_duckdb()` is called again.
[`store_tables()`](https://ebukin.github.io/rcs/reference/store_tables.md)
with `st` says which views are not current.

## See also

[`store_tables()`](https://ebukin.github.io/rcs/reference/store_tables.md),
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md),
[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md),
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-duckdb")
st <- store_connect(root, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-duckdb  2/2
#>   files sent  23.8 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
con <- store_duckdb(st)
#> ✔ DuckDB view (native mode, nothing read yet): `sales.daily`.
DBI::dbGetQuery(con, "SELECT year, sum(qty) AS qty FROM sales.daily GROUP BY year")
#>   year  qty
#> 1 2023 1328
#> 2 2024 1028
store_tables(con, st)
#> # A tibble: 1 × 6
#>   schema name  type  dataset     version          current
#> * <chr>  <chr> <chr> <chr>       <chr>            <lgl>  
#> 1 sales  daily view  sales/daily 0f9e01793cbea58a TRUE   
DBI::dbDisconnect(con, shutdown = TRUE)
unlink(root, recursive = TRUE)
```
