# Getting started with rcs

rcs keeps tabular, geospatial vector and raster data in a *store*: a
named collection of *datasets*, written mostly as Parquet files. This
vignette works with a store in one local folder. It shows how to create
the store, write a table, see what the store holds, read data back with
filters, and keep earlier versions.

Two other vignettes go further:
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md)
keeps the same store in several places, local folders or cloud buckets,
and
[`vignette("geospatial")`](https://ebukin.github.io/rcs/articles/geospatial.md)
writes `sf` objects and rasters.

``` r

library(rcs)
```

## Words used here

- A **store** is a collection of datasets, whatever the place it is kept
  in.
- A **location** is one place that holds a copy of a store: a local
  folder, or a Google Cloud Storage address such as
  `gs://my-bucket/store`.
- The **catalog** is a set of three small Parquet files at the root of
  each location. It lists every dataset and every data file, with
  checksums. Every function starts from the catalog; folders are never
  searched for files.
- A **dataset** is one logical table, named like a path: `sales/daily`.
  It is stored as one file, or as one file per *partition* (for example
  one per year).
- A **version** is a 16-character code computed from the content of a
  dataset’s files. The same data always give the same version.

## Create a store

[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
connects to a store and returns a connection object. With
`create = TRUE`, a folder that holds no store yet is set up with empty
catalogs. Here the store lives in the session’s temporary folder.

``` r

path <- file.path(tempdir(), "my-store")
st <- store_connect(path, create = TRUE)
st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  <tempdir>/my-store
#> History: off (store default)
#> Datasets: none
```

`store_create(path)` does the same set-up without connecting. Use it
once, when a store is new; connect with `store_connect(path)`
afterwards.

## Write a table

The package ships generators of simulated data for examples.
[`rcs_sim_table()`](https://ebukin.github.io/rcs/reference/rcs_sim_table.md)
returns a panel of invented daily sales, with a column of almost every R
type: integers, doubles, dates, factors, 64-bit integers, time
differences, text with accents, list columns and times.

``` r

sales <- rcs_sim_table(300, seed = 1)
sales
#> # A tibble: 300 × 15
#>    shop_id date        year product   qty  price promo grade delivered      big
#>      <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
#>  1       8 2023-03-06  2023 p04         6 126.   FALSE high  NA            9e15
#>  2      13 2023-11-24  2023 p08        24 163.   FALSE high  2023-12-02    9e15
#>  3       3 2024-01-11  2024 p08        38  83.6  FALSE low   2024-01-19    9e15
#>  4      13 2023-03-08  2023 p05        18 188.   TRUE  mid   2023-03-15    9e15
#>  5       7 2023-11-03  2023 p11        10  58.5  FALSE low   2023-11-12    5e 2
#>  6       3 2023-02-06  2023 p12        44  23.2  FALSE high  2023-02-13   NA   
#>  7      13 2024-12-12  2024 p10        35 121.   NA    high  2024-12-22    8e 2
#>  8       5 2023-03-08  2023 p12        33   5.56 FALSE NA    2023-03-17    9e15
#>  9      10 2023-10-03  2023 p17        17  17.4  FALSE mid   2023-10-10    4e 2
#> 10       4 2023-02-02  2023 p03         2  67.1  NA    high  2023-02-06    9e15
#> # ℹ 290 more rows
#> # ℹ 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
#> #   ts_local <dttm>
```

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
writes a data frame as one dataset. A title and a description are
required. `key` names the columns that identify a row: their values must
be unique together, and the write stops if they are not. `partition`
writes one file per value of the named columns.

``` r

store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year"
)
#> ℹ Writing "sales/daily": 300 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/my-store  2/2 files sent  31.3 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

The summary says what was written and where. Before anything is copied
to the store, the files are written to a local staging folder and a
sample of their rows is compared with `sales`. After the copy, the
checksum (MD5) of every file in the store is compared with the staged
one. Only then is the catalog switched to the new version, so a reader
never sees a half-written dataset.

Writing the same data again changes nothing. The version is computed
from the content, so the package sees that the store already holds it. A
dataset that exists can only be written again with `mode = "replace"` or
`mode = "update"`:

``` r

store_write(st, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year",
  mode = "replace"
)
#> ℹ "sales/daily" is unchanged (version b74a078c7191e5d3): 300 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/my-store  unchanged
```

## See what the store holds

Printing the connection lists its locations and its datasets, grouped by
folder.

``` r

st
#> ── rcs store ───────────────────────────────────────────────────────────────────
#> Locations:
#>   primary  local  <tempdir>/my-store
#> History: off (store default)
#> Datasets: 1
#>   name     kind   rows     size  files  updated
#>   sales/
#>     daily  table   300  31.3 kB      2  2026-11-21 21:57
```

[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md)
returns the same list as a tibble, one row per dataset.

``` r

datasets <- store_datasets(st)
datasets
#> # A tibble: 1 × 9
#>   dataset  kind  title  rows bytes n_files partition version updated            
#>   <chr>    <chr> <chr> <dbl> <dbl>   <int> <list>    <chr>   <dttm>             
#> 1 sales/d… table Dail…   300 31289       2 <chr [1]> b74a07… 2026-11-21 21:57:20
datasets$title
#> [1] "Daily sales"
```

[`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md)
shows everything the catalog knows about one dataset: title,
description, key, partition, the columns with their types, and the files
of the current version.

``` r

store_describe(st, "sales/daily")
#> ── sales/daily ─────────────────────────────────────────────────────────────────
#> Daily sales
#> Simulated daily sales by shop and product.
#> 
#> Kind        table
#> Version     b74a078c7191e5d3
#> Rows        300
#> Files       2
#> Size        31.3 kB
#> Key         shop_id, date, product
#> Partition   year
#> Sorted by   shop_id, date, product
#> Source      –
#> Inputs      –
#> History     not set (the connection's setting applies)
#> Created     2026-11-21 21:57:20 UTC
#> Updated     2026-11-21 21:57:20 UTC
#> Written by  R 4.6.2, rcs 0.0.0.9000
#> 
#> Locations:
#>   primary    <tempdir>/my-store
#> 
#> Columns (15):
#>   name       type                                              r_type                     description
#>   shop_id    int32
#>   date       date32[day]
#>   year       int32
#>   product    dictionary<values=string, indices=int8>           factor (20 levels)
#>   qty        int32
#>   price      double
#>   promo      bool
#>   grade      dictionary<values=string, indices=int8, ordered>  ordered factor (3 levels)
#>   delivered  date32[day]
#>   big        int64                                             integer64
#>   wait       double                                            difftime (hours)
#>   note       string
#>   tags       list<item: string>                                list
#>   ts         timestamp[us, tz=UTC]
#>   ts_local   timestamp[us]
#> 
#> Files (2):
#>   path                                                 partition      rows     size
#>   sales/daily/year=2023/part-b74a078c7191e5d3.parquet  {"year":2023}   156  15.9 kB
#>   sales/daily/year=2024/part-b74a078c7191e5d3.parquet  {"year":2024}   144  15.4 kB
```

These three functions read only the catalog that the connection holds.
They open no data file, so they are fast also for a store in a cloud
bucket.

A dataset can be named by the last part of its name when that is unique
in the store: `"daily"` stands for `"sales/daily"` below.

## Read data

[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
reads a dataset into R. Filters are written as in
[`dplyr::filter()`](https://dplyr.tidyverse.org/reference/filter.html),
and `columns` selects columns as in
[`dplyr::select()`](https://dplyr.tidyverse.org/reference/select.html).

``` r

store_read(st, "daily", year == 2024, product == "p07",
  columns = c(shop_id, date, qty)
)
#> # A tibble: 8 × 3
#>   shop_id date         qty
#>     <int> <date>     <int>
#> 1       1 2024-03-03    16
#> 2       3 2024-11-16     9
#> 3       6 2024-11-11    36
#> 4       9 2024-01-22    34
#> 5       9 2024-10-04    41
#> 6      10 2024-02-24    40
#> 7      12 2024-05-24    43
#> 8      19 2024-08-26    NA
```

Filters and the column selection are passed to the Parquet reader, so
only the needed files, blocks of rows and columns are read. A filter on
the partition columns alone is first applied to the catalog, and only
the files of the matching partitions are opened. The work counters show
it: with `options(rcs.trace = TRUE)`,
[`rcs_trace()`](https://ebukin.github.io/rcs/reference/rcs_trace.md)
reports the work done by the last call.

``` r

options(rcs.trace = TRUE)
x <- store_read(st, "daily", year == 2023)
rcs_trace()[c("counter", "detail", "n")]
#> # A tibble: 4 × 3
#>   counter          detail                                                  n
#>   <chr>            <chr>                                               <dbl>
#> 1 backend_call     be_arrow_fs                                             3
#> 2 file_open        sales/daily/year=2023/part-b74a078c7191e5d3.parquet     1
#> 3 row_groups_total NA                                                      1
#> 4 rows_returned    NA                                                    156
options(rcs.trace = FALSE)
```

One of the two files was opened.

The types of the columns come back as they were written: factor levels,
64-bit integers, time differences with their units, list columns and
time zones included. Rows come back sorted by the key within each
partition, so both sides are sorted before they are compared.

``` r

back <- store_read(st, "daily")
identical(
  dplyr::arrange(sales, shop_id, date, product),
  dplyr::arrange(back, shop_id, date, product)
)
#> [1] TRUE
```

Two functions give a first look without reading a whole dataset.
[`store_glimpse()`](https://ebukin.github.io/rcs/reference/store_glimpse.md)
prints the catalog facts and the first rows of one file.
[`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md)
draws rows from a few randomly chosen blocks of rows. It is a quick way
to look at the data, not a simple random sample: rows of one block are
alike, because rows are stored sorted.

``` r

store_glimpse(st, "daily")
#> Dataset:   sales/daily (table)
#> Rows:      300
#> Files:     2
#> Version:   b74a078c7191e5d3
#> Key:       shop_id, date, product
#> Partition: year
#> 
#> Rows: 156
#> Columns: 15
#> $ shop_id   <int> 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, …
#> $ date      <date> 2023-03-12, 2023-03-15, 2023-03-27, 2023-04-14, 2023-05-11,…
#> $ year      <int> 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, 2023, …
#> $ product   <fct> p07, p18, p08, p06, p04, p08, p04, p09, p15, p10, p05, p16, …
#> $ qty       <int> 9, 13, 18, 39, NA, 45, 8, 32, 41, 18, 45, 39, 29, 42, 24, 35…
#> $ price     <dbl> 171.88, 77.83, NA, 46.74, 158.59, 137.52, 151.30, 189.31, 88…
#> $ promo     <lgl> FALSE, TRUE, TRUE, FALSE, FALSE, TRUE, FALSE, TRUE, TRUE, FA…
#> $ grade     <ord> mid, low, mid, mid, low, high, high, high, low, mid, low, lo…
#> $ delivered <date> 2023-03-17, 2023-03-21, 2023-04-02, 2023-04-15, 2023-05-14,…
#> $ big       <int64> 9007199254741345, 9007199254741745, 9007199254741345, 9007…
#> $ wait      <drtn> 29.95 hours, 21.41 hours, 65.29 hours, 16.95 hours, 65.21 h…
#> $ note      <chr> "مثال", "", "αβγ δεζ", "two words", "plain text", "数据", "αβγ…
#> $ tags      <list> "new", <"new", "sale">, <"new", "sale", "bulk">, <>, <NULL>…
#> $ ts        <dttm> 2023-03-12 11:04:28, 2023-03-15 05:01:15, 2023-03-27 20:26:…
#> $ ts_local  <dttm> 2023-03-12 11:04:28, 2023-03-15 05:01:15, 2023-03-27 20:26:…
store_sample(st, "daily", n = 5, qty > 40, columns = c(shop_id, date, qty),
  seed = 42
)
#> # A tibble: 5 × 3
#>   shop_id date         qty
#>     <int> <date>     <int>
#> 1       1 2024-02-29    44
#> 2       3 2024-06-20    46
#> 3      10 2024-06-12    45
#> 4      17 2024-01-04    43
#> 5      18 2024-07-09    42
```

## Lazy queries

[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
returns a lazy query. It is changed with the dplyr verbs
[`filter()`](https://rdrr.io/r/stats/filter.html), `select()`,
`mutate()`, `rename()`, `arrange()`, `distinct()` and
[`head()`](https://rdrr.io/r/utils/head.html), and nothing is read until
`collect()`.

``` r

q <- store_open(st, "daily")
q
#> <rcs_query> sales/daily (table, current)
#> Location: primary
#> Files:    2 of 2
#> Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local

q |>
  dplyr::filter(year == 2024, qty > 45) |>
  dplyr::mutate(revenue = qty * price) |>
  dplyr::select(shop_id, date, qty, revenue) |>
  dplyr::arrange(dplyr::desc(qty)) |>
  dplyr::collect()
#> # A tibble: 7 × 4
#>   shop_id date         qty revenue
#>     <int> <date>     <int>   <dbl>
#> 1       7 2024-08-19    50   8860.
#> 2      12 2024-10-19    49    654.
#> 3      19 2024-09-04    49   5888.
#> 4       7 2024-11-27    48   9347.
#> 5       1 2024-12-24    46   3428.
#> 6       3 2024-06-20    46    669.
#> 7      12 2024-08-12    46   4654.
```

## Update some partitions

With `mode = "update"`, only the partitions whose values occur in the
new data are replaced; the other partitions stay as they are. Here the
rows of 2024 are written again with corrected quantities. The key, the
partition columns and the column types come from the stored dataset and
must match.

``` r

fix <- sales[sales$year == 2024, ]
fix$qty <- fix$qty + 1L
store_write(st, fix, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  mode = "update"
)
#> ℹ Updating "sales/daily": 1 partition replaced, 0 added, 1 kept.
#> • year = 2024: 144 rows -> 144 rows
#> ℹ Writing "sales/daily": 300 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/my-store  1/2 files sent  15.4 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

The message lists every replaced partition with its old and new number
of rows. Check it: a row of a replaced partition that is missing from
the new data is gone after the update.

## Keep earlier versions

By default a store keeps only the current version of each dataset: the
files of a replaced version are deleted once the catalog points to the
new ones. A store created with `history = TRUE` keeps them. The setting
can also be given for one connection (`store_connect(history = )`) or
one dataset (`store_write(history = )`); the dataset’s setting wins over
the connection’s, and the connection’s over the store’s.

``` r

path_h <- file.path(tempdir(), "store-with-history")
store_create(path_h, history = TRUE)
#> ✔ Created an empty store in
#> <tempdir>/store-with-history.
sth <- store_connect(path_h)

store_write(sth, sales, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"),
  partition = "year"
)
#> ℹ Writing "sales/daily": 300 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/store-with-history  2/2 files sent  31.3 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_write(sth, fix, "sales/daily",
  title = "Daily sales",
  description = "Simulated daily sales by shop and product.",
  mode = "update"
)
#> ℹ Updating "sales/daily": 1 partition replaced, 0 added, 1 kept.
#> • year = 2024: 144 rows -> 144 rows
#> ℹ Writing "sales/daily": 300 rows in 2 files (partition year).
#> ✔ primary  <tempdir>/store-with-history  1/2 files sent  15.4 kB  0.1s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
```

[`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md)
lists the versions, the current one first.

``` r

versions <- store_history(sth, "daily")
versions[c("version", "current", "n_files", "rows", "complete")]
#> # A tibble: 2 × 5
#>   version          current n_files  rows complete
#>   <chr>            <lgl>     <int> <dbl> <lgl>   
#> 1 e0ce507f7ddb7d09 TRUE          2   300 TRUE    
#> 2 b74a078c7191e5d3 FALSE         2   300 TRUE
```

An earlier version is read by its code:

``` r

first <- versions$version[!versions$current][1]
store_read(sth, "daily", year == 2024, columns = c(shop_id, date, qty),
  version = first
) |>
  head(3)
#> # A tibble: 3 × 3
#>   shop_id date         qty
#>     <int> <date>     <int>
#> 1       1 2024-01-14    33
#> 2       1 2024-02-27    28
#> 3       1 2024-02-29    44
```

Old versions stay until
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
removes them. `keep` is the number of earlier versions to keep;
`dry_run = TRUE` only reports. Files that the current version still uses
are never deleted.

``` r

store_prune(sth, keep = 0, dry_run = TRUE)
#> ✔ Would remove 1 history version and 2 files (18.3 kB) in 1
#> location.
store_prune(sth, keep = 0)
#> ✔ Removed 1 history version and 2 files (18.3 kB) in 1 location.
```

## Check a dataset

[`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md)
without data checks the integrity of a stored dataset: every file exists
with the checksum and the number of rows its catalog records, and the
catalog agrees with itself. Given the data the dataset was written from,
it compares a sample of stored rows with them.

``` r

store_check(st, "daily")
#> ✔ 2 files checked in 1 location: no problem found.
store_check(sth, "daily", x = rbind(sales[sales$year != 2024, ], fix))
#> ✔ 2 files checked in 1 location: no problem found.
```

Both return a tibble of results invisibly, and stop with an error when a
check fails (`error = FALSE` only reports).
