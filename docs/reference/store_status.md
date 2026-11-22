# Compare the secondary locations with the primary

For each secondary location and each dataset, compares the catalogs held
by the connection: a copy is the same when its version equals the
primary's. No file is read and no location contacted; run
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
first to compare what is stored now.

## Usage

``` r
store_status(st)

# S3 method for class 'rcs_status'
print(x, ...)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- x:

  The result of `store_status()`.

- ...:

  Passed on to the tibble's print method.

## Value

A tibble with one row per secondary location and dataset of the primary
catalog (index tables included), plus one per dataset found only in a
secondary, ordered by location (in connection order) and dataset:

- `dataset`: the full name;

- `location`: the address of the secondary location;

- `status`: `"same"`, `"differs"` (another version), `"missing"` (not in
  the secondary), `"extra"` (only in the secondary), or `"unavailable"`
  when the location could not be reached;

- `newer`: for `"differs"`, the side with the later `updated` time,
  `"primary"` or `"secondary"`; `NA` otherwise. A hint only: the clocks
  of the machines that wrote may differ;

- `primary_version`, `location_version`: the versions compared;

- `primary_updated`, `location_updated`: the times of the last writes.

Zero rows when the connection has no secondary location.
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
brings missing and differing datasets up to date.

## Details

Printed, the addresses are listed once above the table and the column
`location` shows their numbers, so that long addresses stay readable;
the values of the column are the full addresses.

## See also

[`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md),
[`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md).

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
#> Locations: [1] /tmp/Rtmp/rcs-example-status/copy
#> # A tibble: 1 × 8
#>   dataset     location status newer primary_version  location_version
#>   <chr>       <chr>    <chr>  <chr> <chr>            <chr>           
#> 1 sales/daily [1]      same   NA    bf16efd1aebea856 bf16efd1aebea856
#> # ℹ 2 more variables: primary_updated <dttm>, location_updated <dttm>
unlink(root, recursive = TRUE)
```
