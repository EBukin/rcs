# Compare the locations of a connection with one of them

For each location other than the source and each dataset, compares the
catalogs held by the connection: a copy is the same when its version
equals the source's. The source is the primary unless `from` names
another location. No file is read and no location contacted; run
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
first to compare what is stored now.

## Usage

``` r
store_status(st, from = NULL)

# S3 method for class 'rcs_status'
print(x, ...)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- from:

  `NULL` (the default) to compare every secondary location with the
  primary, or the address of a location of the connection (as given to
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md))
  to compare every other location, the primary included, with that one.

- x:

  The result of `store_status()`.

- ...:

  Passed on to the tibble's print method.

## Value

A tibble with one row per location other than the source and dataset of
the source catalog (index tables included), plus one per dataset found
only in that location, ordered by location (in connection order) and
dataset:

- `dataset`: the full name;

- `location`: the address of the location compared with the source;

- `status`: `"same"`, `"differs"` (another version), `"missing"` (not in
  that location), `"extra"` (only in that location), or `"unavailable"`
  when it or the source could not be reached;

- `newer`: for `"differs"`, the side with the later `updated` time,
  `"source"` or `"target"` (the location of the row); `NA` otherwise. A
  hint only: the clocks of the machines that wrote may differ;

- `primary_version`, `location_version`: the versions compared;
  `primary_version` is the source's (the primary's by default);

- `primary_updated`, `location_updated`: the times of the last writes,
  `primary_updated` in the source.

The attribute `source` holds the address of the source. Zero rows when
the connection has no other location.
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
brings missing and differing datasets up to date.

## Details

Printed, the source is named first; the addresses of the other locations
are listed once above the table and the column `location` shows their
numbers, so that long addresses stay readable; the values of the column
are the full addresses.

## See also

[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md),
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md),
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-status")
st <- store_connect(
  file.path(root, "primary"),
  secondary = file.path(root, "copy"),
  create = TRUE
)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary    /tmp/Rtmp/rcs-example-status/primary  2/2
#>   files sent  23.7 kB  0.2s
#> ✔ secondary  /tmp/Rtmp/rcs-example-status/copy     2/2
#>   files sent  23.7 kB  0.2s
#> ✔ MD5 identical for 2 files in 2 locations. Catalogs updated.
store_status(st)
#> Source: /tmp/Rtmp/rcs-example-status/primary
#> Locations: [1] /tmp/Rtmp/rcs-example-status/copy
#> # A tibble: 1 × 8
#>   dataset     location status newer primary_version  location_version
#>   <chr>       <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily [1]      same   NA    bf16efd1aebea856 bf16efd1aebea856
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
store_status(st, from = file.path(root, "copy"))
#> Source: /tmp/Rtmp/rcs-example-status/copy
#> Locations: [1] /tmp/Rtmp/rcs-example-status/primary
#> # A tibble: 1 × 8
#>   dataset     location status newer primary_version  location_version
#>   <chr>       <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily [1]      same   NA    bf16efd1aebea856 bf16efd1aebea856
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
unlink(root, recursive = TRUE)
```
