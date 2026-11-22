# Describe one dataset

The full catalog entry of a dataset: title, description, provenance,
key, partition, coordinate reference system, extent, H3 resolution, the
table of columns, the table of files of its current version and its
state in every secondary location. Works from the catalogs held by the
connection; no data file is opened.

## Usage

``` r
store_describe(st, dataset)

# S3 method for class 'rcs_description'
print(x, n = 10, ...)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  The dataset's full name, or its last part when that is unique. Index
  tables (`<dataset>__h3`) can be named too.

- x:

  An `rcs_description`.

- n:

  Most files to list; the rest are counted.

- ...:

  Ignored.

## Value

An object of class `rcs_description`, printed as a summary: a list with

- `entry`: the catalog entry, a one-row tibble;

- `columns`: a tibble `name`, `type` (Arrow type), `r_type` (the R type
  the package restores on read, as text, `NA` when Arrow restores it by
  itself), `description`;

- `files`: a tibble of the files of the current version: `path`,
  `partition_values`, `rows`, `bytes`, `md5`, `created`;

- `locations`: a tibble `location`, `role` and `status` (as in
  [`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md);
  `"primary"` for the primary);

- `index`: the name of the dataset's index table, or `NA`.

## See also

[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-describe")
st <- store_connect(file.path(root, "primary"), create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-describe/primary  2/2
#>   files sent  23.7 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_describe(st, "sales/daily")
#> ── sales/daily ─────────────────────────────────────────────────────────────────
#> Daily sales
#> Simulated daily sales.
#> 
#> Kind        table
#> Version     bf16efd1aebea856
#> Rows        100
#> Files       2
#> Size        23.7 kB
#> Key         shop_id, date, product
#> Partition   year
#> Sorted by   shop_id, date, product
#> Source      –
#> Inputs      –
#> History     not set (the connection's setting applies)
#> Created     2026-11-22 10:52:01 EST
#> Updated     2026-11-22 10:52:01 EST
#> Written by  R 4.6.2, rcs 0.0.0.9000
#> 
#> Locations:
#>   primary    /tmp/Rtmp/rcs-example-describe/primary
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
#>   sales/daily/year=2023/part-bf16efd1aebea856.parquet  {"year":2023}    55  12.0 kB
#>   sales/daily/year=2024/part-bf16efd1aebea856.parquet  {"year":2024}    45  11.7 kB
unlink(root, recursive = TRUE)
```
