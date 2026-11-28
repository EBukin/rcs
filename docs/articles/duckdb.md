# Querying a store with DuckDB

[DuckDB](https://duckdb.org) is a database that runs inside the R
process and reads Parquet files directly. rcs opens a whole store in
DuckDB with one call: every dataset becomes a *view*, a named query over
the dataset’s files. No data is copied; DuckDB reads the files when a
query runs, and only the columns and row groups the query needs. SQL and
dbplyr then work on the store, joins between datasets included, and
results can be written back to the store without passing through R as a
whole.

This vignette needs the packages duckdb, DBI and dbplyr. It works with a
store in a local folder; the last sections say what changes on Google
Cloud Storage.
[`vignette("rcs")`](https://ebukin.github.io/rcs/articles/rcs.md)
introduces stores and
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md).

``` r

library(rcs)
```

## A store to work with

A store with two datasets: a table of simulated daily sales, one file
per year, and simulated polygons, a geospatial dataset with its H3 index
table.

``` r

path <- file.path(tempdir(), "duckdb-store")
st <- store_connect(path, create = TRUE)

store_write(st, rcs_sim_table(500, seed = 1), "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year"
)
#> ℹ Writing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/duckdb-store  2/2 files sent  38.3 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_write(st, rcs_sim_polygons(300, seed = 3), "shapes/polygons",
  title = "Polygons",
  description = "Simulated polygons in open ocean.",
  key = "id"
)
#> ℹ Writing "shapes/polygons": 300 rows in 1 file, and its index table in 1 file.
#> ✔ primary  <tempdir>/duckdb-store  2/2 files sent  51.9 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

## Views in memory

[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
creates a DuckDB connection, here an in-memory database, with one view
per dataset of the store (rasters excluded, index tables included), and
returns the connection invisibly.

``` r

con <- store_duckdb(st)
#> ✔ DuckDB views (native mode, nothing read yet): `sales.daily`,
#> `shapes.polygons`, and `shapes.polygons__h3`.
```

The first part of a dataset’s name is the schema, the other parts,
joined with `__`, are the view: `sales/daily` is the view `sales.daily`,
and the index table of `shapes/polygons` is `shapes.polygons__h3`. A
dataset with a one-part name goes to the schema `main`. Two datasets
that would get the same view name abort, as does a first part `rcs` or
one equal to the name of an attached database (such as `memory`).

Views are queried with SQL like tables:

``` r

DBI::dbGetQuery(con, "
  SELECT year, count(*) AS n, sum(qty) AS qty
  FROM sales.daily
  GROUP BY year
  ORDER BY year
")
#>   year   n  qty
#> 1 2023 252 5851
#> 2 2024 248 6065
```

and can be joined. Here each polygon is joined with its rows in the
index table, the H3 cells it touches; the macro
[`rcs_h3_hex()`](https://ebukin.github.io/rcs/reference/rcs_h3_hex.md),
defined on every connection the package prepares, shows a cell, stored
as a 64-bit integer, as its hex code:

``` r

DBI::dbGetQuery(con, '
  SELECT p.id, count(*) AS cells, rcs_h3_hex(min(i.h3)) AS first_cell
  FROM shapes.polygons AS p
  JOIN shapes.polygons__h3 AS i USING (".rcs_id")
  GROUP BY p.id
  ORDER BY cells DESC, p.id
  LIMIT 3
')
#>   id cells      first_cell
#> 1  1   212 85565907fffffff
#> 2  3    41 857c584bfffffff
#> 3  2    29 85564823fffffff
```

H3 cells are `BIGINT` columns. The connections the package makes use
`bigint = "integer64"`, so that cells reach R as
[`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
values: a double cannot hold a cell exactly. A connection you make
yourself and pass to the package must use the same setting, or the call
aborts.

## What a connection holds

[`store_tables()`](https://ebukin.github.io/rcs/reference/store_tables.md)
lists the views of a connection, with the dataset and the version each
one shows. Given the store as well, the column `current` says whether a
view shows the version in the store’s catalog.

``` r

store_tables(con, st)
#> # A tibble: 3 × 6
#>   schema name         type  dataset             version          current
#> * <chr>  <chr>        <chr> <chr>               <chr>            <lgl>  
#> 1 sales  daily        view  sales/daily         99995a06f9e462f1 TRUE   
#> 2 shapes polygons     view  shapes/polygons     7d045aaa53d8b240 TRUE   
#> 3 shapes polygons__h3 view  shapes/polygons__h3 e72b28d7c379c808 TRUE
```

Given a store, it lists the datasets with the name of the view each one
gets. Index tables are left out here, though the connection has views
for them (`shapes.polygons__h3` above):

``` r

store_tables(st)[c("dataset", "kind", "rows", "duckdb_view")]
#> # A tibble: 2 × 4
#>   dataset         kind        rows duckdb_view    
#>   <chr>           <chr>      <dbl> <chr>          
#> 1 sales/daily     table        500 sales.daily    
#> 2 shapes/polygons geospatial   300 shapes.polygons
```

The connection records its views in the table `rcs.views` and the
store’s locations in `rcs.store`. Neither holds a credential. A
connection serves one store: preparing it for a second store aborts.

``` r

DBI::dbGetQuery(con, "SELECT view, dataset, mode FROM rcs.views")
#>                  view             dataset   mode
#> 1         sales.daily         sales/daily native
#> 2     shapes.polygons     shapes/polygons native
#> 3 shapes.polygons__h3 shapes/polygons__h3 native
```

`store_duckdb(st, datasets = )` adds or refreshes the views of some
datasets only (with their index tables) and leaves the others alone;
without `datasets`, every view is refreshed and the views of datasets no
longer in the catalog are dropped.

## Two modes

[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
has two modes, which differ in who reads the files.

- `mode = "native"` (the default): each view is a `read_parquet()` query
  over the dataset’s file list, and DuckDB reads the files itself. The
  views are plain query text, so they keep working in a database file
  after it is reopened (see below). The `geometry` column of a
  geospatial dataset has the DuckDB type `GEOMETRY`. On a bucket, DuckDB
  needs a credential of its own, which the package gives it (see
  “Buckets”).
- `mode = "arrow"`: the Arrow dataset that the package opens for its own
  reads is registered in DuckDB, and the view selects from it. DuckDB
  needs no credential, filters are passed into the Arrow scan, and
  `geometry` is WKB (a `BLOB`). The registration lives only as long as
  the connection.

``` r

con_arrow <- store_duckdb(st, mode = "arrow")
#> ✔ DuckDB views (arrow mode, nothing read yet): `sales.daily`,
#> `shapes.polygons`, and `shapes.polygons__h3`.
DBI::dbGetQuery(con_arrow, "SELECT count(*) AS n FROM sales.daily WHERE year = 2024")
#>     n
#> 1 248
DBI::dbDisconnect(con_arrow, shutdown = TRUE)
```

In both modes each dataset is read from the location a read with
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
would use, and the views show the versions of the catalog held by `st`.
After `store_refresh(st)` or a write through another connection, call
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
again.

`spatial = TRUE` also installs and loads DuckDB’s `spatial` extension
(downloaded on first use), and in arrow mode adds a column `geom` of
type `GEOMETRY` to geospatial views, for DuckDB’s spatial functions.

``` r

con_spatial <- store_duckdb(st, mode = "arrow", spatial = TRUE)
DBI::dbGetQuery(con_spatial, "SELECT id, ST_Area(geom) AS area FROM shapes.polygons LIMIT 3")
DBI::dbDisconnect(con_spatial, shutdown = TRUE)
```

## dbplyr tables

`store_open(engine = "duckdb")` returns a dbplyr table on a dataset’s
view. With `con`, the view is made (or refreshed) on that connection;
without it, on an in-memory connection the package keeps for the store
until the end of the session. The table prints as any dbplyr table.

The dplyr verbs that dbplyr translates to SQL
([`filter()`](https://rdrr.io/r/stats/filter.html), `select()`,
`mutate()`, `summarise()`, `arrange()`, joins,
[`head()`](https://rdrr.io/r/utils/head.html) and others) stay lazy:
they build a query that runs in DuckDB. Rows come into R only with
`collect()`, or with verbs that collect, such as `pull()`. A verb or a
function that dbplyr cannot translate, or that DuckDB does not know,
gives an error, as for any dbplyr table. `compute()` returns a plain
dbplyr table, whose `collect()` does not restore the R types described
below. An earlier version cannot be opened this way: `version` must be
`NULL` with `engine = "duckdb"`.

``` r

daily <- store_open(st, "daily", engine = "duckdb", con = con)
daily |>
  dplyr::filter(year == 2024) |>
  dplyr::count(product, sort = TRUE) |>
  head(3) |>
  dplyr::collect()
#> # A tibble: 3 × 2
#>   product       n
#>   <fct>   <int64>
#> 1 p17          24
#> 2 p04          18
#> 3 p02          17
```

Inside DuckDB, values keep the types they are stored with: a factor is
text, a time difference a number. `collect()` on a table made by
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
restores the R types from the catalog, as the Arrow engine does: factor
levels, difftime units, 64-bit integers, and H3 cells as `rcs_h3`
vectors printed as hex. A geospatial dataset comes back as an `sf`
object with the catalog’s coordinate reference system, without the row
identifier `.rcs_id`. A column computed in DuckDB keeps its DuckDB type:
a count, for example, comes back as a 64-bit integer.

``` r

daily |>
  dplyr::filter(year == 2024, qty > 48) |>
  dplyr::select(shop_id, date, product, grade, wait) |>
  dplyr::collect()
#> # A tibble: 6 × 5
#>   shop_id date       product grade wait       
#>     <int> <date>     <fct>   <ord> <drtn>     
#> 1       4 2024-11-26 p15     mid    9.44 hours
#> 2      10 2024-02-24 p07     low    0.70 hours
#> 3      12 2024-06-12 p17     mid   51.88 hours
#> 4      14 2024-04-25 p06     mid   37.39 hours
#> 5      19 2024-08-26 p07     mid    0.78 hours
#> 6      20 2024-10-01 p05     high  10.82 hours
```

A plain `dplyr::tbl(con, DBI::Id(schema = "sales", table = "daily"))`
gives the same rows with DuckDB’s types.
[`store_restore_types()`](https://ebukin.github.io/rcs/reference/store_restore_types.md)
restores the types of any data frame from a dataset’s catalog entry.

## Spatial filter in DuckDB

[`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
works on a table made by `store_open(engine = "duckdb")`. The candidate
test is added to the table’s SQL: the box test on `bbox` and, for
queries that fill little of their bounding box (a thin diagonal strip, a
line), the H3 cells with the index view. The table must still hold those
columns, so call it before a `select()` that drops them.

``` r

area <- sf::st_as_sfc(sf::st_bbox(
  c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
  crs = sf::st_crs(4326)
))
polygons <- store_open(st, "polygons", engine = "duckdb", con = con)
```

`exact` says where the exact test runs:

- `exact = TRUE` (the default): in R, in `collect()`, on the candidate
  rows, with the same engine as the Arrow path. The rows are exactly
  those of
  `store_open(st, "polygons") |> store_intersects(area) |> collect()`.
- `exact = FALSE`: no exact test; the result is the candidate set, which
  holds every intersecting row and may hold others, with a message
  saying so.
- `exact = "sql"`: in DuckDB, with `ST_Intersects()` of the `spatial`
  extension (installed and loaded when needed). The query stays lazy, so
  the result can be aggregated or joined in DuckDB. The test is in the
  plane of the coordinates: the rows are those of the Arrow path with
  `exact_engine = "planar"`, except for queries across the antimeridian
  or around a pole.

``` r

polygons |>
  store_intersects(area) |>
  dplyr::collect() |>
  nrow()
#> [1] 15

polygons |>
  store_intersects(area, exact = FALSE) |>
  dplyr::collect() |>
  nrow()
#> ℹ Spatial filter: `exact = FALSE`, so the result is the candidate set.
#>   It holds every intersecting row and may hold rows that do not intersect the query.
#> [1] 15
```

``` r

polygons |>
  store_intersects(area, exact = "sql") |>
  dplyr::count(cat)
```

Several calls combine: a row must intersect every query. A count or
other aggregate computed in DuckDB after a pending exact test
(`exact = TRUE`) counts the candidate rows, since the exact test runs
only in `collect()`; use `exact = "sql"` for that. A query of more than
10,000 H3 cells puts the cells in a temporary table on the connection,
kept until it is closed.

## Writing from DuckDB

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
accepts a lazy table on a DuckDB connection: a dbplyr query on the
views, on your own tables, or both. The result is stored without being
collected into R as a whole.

``` r

by_product <- dplyr::tbl(con, DBI::Id(schema = "sales", table = "daily")) |>
  dplyr::group_by(year, product) |>
  dplyr::summarise(
    qty = as.integer(sum(qty, na.rm = TRUE)),
    days = dplyr::n(),
    .groups = "drop"
  )

store_write(st, by_product, "sales/by_product",
  title = "Sales by product and year",
  description = "Quantity sold and number of rows per product and year.",
  key = c("year", "product")
)
#> ℹ Writing "sales/by_product": 38 rows in 1 file.
#> ✔ primary  <tempdir>/duckdb-store  1/1 files sent  3.2 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
```

How it works:

- The query runs once inside DuckDB into a temporary copy, a table
  `rcs_write_<random>` on the same connection. Every later step reads
  that copy, and it is dropped when the call ends, also after an error.
  It needs room in DuckDB’s memory or its temporary folder.
- The key is checked and the partitions are listed in DuckDB. Then the
  rows are fetched in batches of as many rows as the option
  `rcs.duckdb_batch_rows` says (`5e5` by default), sorted as the package
  sorts them, and streamed into the Parquet files; R holds about one
  batch at a time. A progress bar shows the batches of a long write.
- The files are staged, checked and land in every location as for any
  other write (in the primary only for a dataset kept there with
  `locations = "primary"`); DuckDB never uploads. They are identical to
  those written from the same rows collected into R, so both give the
  same version.
- Modes `"create"` and `"replace"` work; `"update"` aborts.
- Types: integers, doubles, text, dates and logicals are stored as they
  are, `BIGINT` as 64-bit integers
  ([`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
  in R), `TIMESTAMP` without time zone and `TIMESTAMP WITH TIME ZONE` in
  UTC. `HUGEINT`, `UHUGEINT`, `INTERVAL`, `UNION` and `MAP` columns
  abort, naming the columns. DuckDB’s
  [`sum()`](https://rdrr.io/r/base/sum.html) of an integer column is a
  `HUGEINT`; that is why the query above casts it with
  [`as.integer()`](https://rdrr.io/r/base/integer.html).
- Values keep their DuckDB types: a factor read through a view is text,
  and is stored as text.

A table with a column `geometry`, WKB (`BLOB`) or `GEOMETRY`, is written
as a geospatial dataset, and `crs` must give its coordinate reference
system. The geometries pass through R in batches: per batch, the
bounding boxes, the H3 cells and the index rows are computed as for an
`sf` object, with the same geocoding engine and warning (see
[`?store_write`](https://ebukin.github.io/rcs/reference/store_write.md)).
The rows are then sorted and written from DuckDB. The columns `.rcs_id`,
`h3`, `bbox` and `geom` of the input are the package’s own: they are
dropped with a message and computed again.

``` r

cat_a <- polygons |>
  dplyr::filter(cat == "a") |>
  dplyr::select(id, area, geometry)

store_write(st, cat_a, "shapes/cat_a",
  title = "Polygons of category a",
  description = "The polygons of category a, written from DuckDB.",
  key = "id", crs = 4326
)
#> ℹ Writing "shapes/cat_a": 59 rows in 1 file, and its index table in 1 file.
#> ✔ primary  <tempdir>/duckdb-store  2/2 files sent  23.0 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

`partition = "h3"`, `geocode = FALSE` and `geocode_engine` work as for
an `sf` object.

## A database file

With `path`, the views live in a DuckDB database file, created when
missing, together with any table or view you create in it. The file must
lie outside the folders of the store (a sync would carry it along). A
file `work.duckdb` is attached as the database `work`, so no dataset of
the store may have the first part `work`.

``` r

DBI::dbDisconnect(con, shutdown = TRUE)

db <- file.path(tempdir(), "analysis.duckdb")
con <- store_duckdb(st, path = db)
#> ✔ DuckDB views (native mode, nothing read yet): `sales.by_product`, `sales.daily`, `shapes.cat_a`, `shapes.cat_a__h3`,
#>   `shapes.polygons`, and `shapes.polygons__h3`.
```

A view is query text, so the file stays small whatever the size of the
datasets. Your own tables sit next to the views. The cell column is
named `cell` here, because a column `h3` of a table written with
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
is taken as the package’s own and dropped.

``` r

DBI::dbExecute(con, "
  CREATE TABLE main.cell_counts AS
  SELECT h3 AS cell, count(*) AS polygons
  FROM shapes.polygons__h3
  GROUP BY h3
")
#> [1] 366
store_tables(con, st)
#> # A tibble: 7 × 6
#>   schema name         type  dataset             version          current
#> * <chr>  <chr>        <chr> <chr>               <chr>            <lgl>  
#> 1 main   cell_counts  table NA                  NA               NA     
#> 2 sales  by_product   view  sales/by_product    b5d62d115f8723b8 TRUE   
#> 3 sales  daily        view  sales/daily         99995a06f9e462f1 TRUE   
#> 4 shapes cat_a        view  shapes/cat_a        fa75cbab22985b29 TRUE   
#> 5 shapes cat_a__h3    view  shapes/cat_a__h3    e8056628ad9ec1c5 TRUE   
#> 6 shapes polygons     view  shapes/polygons     7d045aaa53d8b240 TRUE   
#> 7 shapes polygons__h3 view  shapes/polygons__h3 e72b28d7c379c808 TRUE
DBI::dbDisconnect(con, shutdown = TRUE)
```

### Reopening

Call `store_duckdb(st, path = db)` again to reopen the file. It
refreshes the file to the catalog of `st`: views of new datasets are
added, views of deleted datasets dropped, every view points to the
current version, the credentials are renewed, and your own tables and
views are left as they are. A table or a view of yours that has the name
of a dataset’s view aborts, naming it.

`store_duckdb(path = db)`, without `st`, reads the store’s locations
from the table `rcs.store` in the file, connects to the store with
default credentials, and refreshes the same way:

``` r

con <- store_duckdb(path = db)
#> ✔ DuckDB views (native mode, nothing read yet): `sales.by_product`, `sales.daily`, `shapes.cat_a`, `shapes.cat_a__h3`,
#>   `shapes.polygons`, and `shapes.polygons__h3`.
DBI::dbGetQuery(con, "SELECT * FROM main.cell_counts ORDER BY polygons DESC, cell LIMIT 3")
#>                 cell polygons
#> 1 600496714289250303        3
#> 2 600496811999756287        3
#> 3 600497847086874623        3
DBI::dbDisconnect(con, shutdown = TRUE)
```

The file is also a plain DuckDB database:
`DBI::dbConnect(duckdb::duckdb(dbdir = db), bigint = "integer64")` opens
it without rcs. Your tables then work, and native views work as long as
their files exist, with these limits:

- the views show the versions of the last refresh. A store without
  history deletes the files of a replaced version, so a view of a
  dataset written since then fails until the file is refreshed;
- views on Google Cloud Storage need a DuckDB secret first;
- views in arrow mode do not work until
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
  is called again (it says so when it prepares them in a file).

`store_tables(con, st)` shows which views are no longer current. Here
the daily sales are written again with changed quantities, and the file
is opened without rcs:

``` r

sales <- rcs_sim_table(500, seed = 1)
sales$qty <- sales$qty + 1L
store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year",
  mode = "replace"
)
#> ℹ Replacing "sales/daily": 500 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/duckdb-store  2/2 files sent  38.3 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

``` r

con <- DBI::dbConnect(duckdb::duckdb(dbdir = db), bigint = "integer64")
store_tables(con, st)[c("schema", "name", "type", "current")]
#> # A tibble: 7 × 4
#>   schema name         type  current
#>   <chr>  <chr>        <chr> <lgl>  
#> 1 main   cell_counts  table NA     
#> 2 sales  by_product   view  TRUE   
#> 3 sales  daily        view  FALSE  
#> 4 shapes cat_a        view  TRUE   
#> 5 shapes cat_a__h3    view  TRUE   
#> 6 shapes polygons     view  TRUE   
#> 7 shapes polygons__h3 view  TRUE
DBI::dbDisconnect(con, shutdown = TRUE)
```

`store_duckdb(st, path = db)` brings the view up to date.

## The local-first workflow

DuckDB and a local store together make a complete workplace on one
machine, with no cloud credential:

1.  Keep the store in a local folder and write to it as usual.
2.  Open it in a DuckDB file with `store_duckdb(st, path = )`; build
    aggregations, joins and your own tables in SQL or dbplyr.
3.  Write the results that should be kept back to the store with
    [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md),
    from DuckDB directly.
4.  Reopen the file any time with
    [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md),
    which refreshes the views.

``` r

con <- store_duckdb(st, path = db)
#> ✔ DuckDB views (native mode, nothing read yet): `sales.by_product`, `sales.daily`, `shapes.cat_a`, `shapes.cat_a__h3`,
#>   `shapes.polygons`, and `shapes.polygons__h3`.
cells <- dplyr::tbl(con, DBI::Id(schema = "main", table = "cell_counts")) |>
  dplyr::filter(polygons > 1)
store_write(st, cells, "shapes/shared_cells",
  title = "Shared cells",
  description = "H3 cells touched by more than one polygon.",
  key = "cell"
)
#> ℹ Writing "shapes/shared_cells": 70 rows in 1 file.
#> ✔ primary  <tempdir>/duckdb-store  1/1 files sent  2.3 kB  0.1s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
DBI::dbDisconnect(con, shutdown = TRUE)
```

5.  When the work is ready to share, add a bucket as a secondary
    location and copy the store there with `store_sync(all = TRUE)`
    (every dataset except those kept in the primary only with
    `locations = "primary"`; see
    [`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md);
    a plain
    [`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
    copies nothing to an empty secondary). Only then are cloud
    credentials needed.

``` r

st <- store_connect(path, secondary = "gs://my-bucket/store", create = TRUE)
store_sync(st, all = TRUE)
```

Afterwards every write reaches both locations (except writes with
`locations = "primary"`), and reads, DuckDB views included, keep using
the local copy.

## Buckets

On Google Cloud Storage nothing changes in the calls; only who reads the
files does. In arrow mode, Arrow reads them with the connection’s
credentials (see
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md)),
as for any read. In native mode DuckDB reads them itself, through its
`httpfs` extension (downloaded on first use), and needs a credential:
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
creates for each bucket location a temporary DuckDB secret from the
location’s credential. The secret lives only in this connection; it is
never written to the database file, to the store or to an environment
variable.

``` r

st <- store_connect("gs://my-bucket/store")
con <- store_duckdb(st, path = "~/work/analysis.duckdb")
DBI::dbGetQuery(con, "SELECT year, sum(qty) AS qty FROM sales.daily GROUP BY year")
```

A secret holds an access token, not a key, and the token is valid for
about an hour. After an hour of DuckDB work on a bucket, call
[`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
again: every call renews the secrets (and refreshes the views).

``` r

con <- store_duckdb(st, path = "~/work/analysis.duckdb")
```

A credential that DuckDB cannot use (the ambient credential of a Google
Cloud machine without a key file) aborts in native mode; use
`mode = "arrow"` there. `store_auth_check(st)` reports whether DuckDB,
and each other client, can read each location.
