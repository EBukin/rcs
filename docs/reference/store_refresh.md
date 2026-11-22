# Re-read the catalogs of a connection

Reads the catalogs of every location again, so that the connection sees
what other sessions wrote since it connected. A secondary that could not
be reached before is tried again; one that cannot be reached now gives a
warning and is marked unavailable. Write functions refresh the locations
they touch by themselves.

## Usage

``` r
store_refresh(st)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

## Value

`st`, invisibly. The object is updated in place.

## See also

[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

## Examples

``` r
primary <- file.path(tempdir(), "rcs-example-refresh")
st <- store_connect(primary, create = TRUE)
store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-refresh  2/2
#>   files sent  23.7 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_refresh(st)
unlink(primary, recursive = TRUE)
```
