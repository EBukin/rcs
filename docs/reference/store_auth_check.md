# Check which clients reach each location of a store

Tries every client the package uses for Google Cloud Storage with the
credential of each location: Arrow (the file system that reads and
writes data files), the JSON API (MD5 checksums), GDAL (rasters, through
`/vsigs/`) and DuckDB (`read_parquet()` with a secret). Local folders
need no credentials and give one row.

## Usage

``` r
store_auth_check(st)
```

## Arguments

- st:

  A store connection from
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

## Value

A tibble with one row per location and client: `location` (the address),
`client` (`"arrow"`, `"json_api"`, `"gdal"`, `"duckdb"`, or `"all"` for
a local folder), `ok` (`TRUE`, `FALSE`, or `NA` when the client was not
tried) and `note` (`"ok"`, the error, or why it was not tried).

## Details

Each probe is small: Arrow and the JSON API look up `_catalog.parquet`,
GDAL opens the first raster file in the location's catalog, DuckDB
counts the rows of `_catalog.parquet`. A failing client is reported,
never raised. GDAL and DuckDB cannot use ambient credentials (no
credential file found); their rows then say so. Opening a raster through
GDAL gives GDAL's process-wide options the location's credential, as
reading a raster does.

## See also

[`rcs_auth_gcs()`](https://ebukin.github.io/rcs/reference/rcs_auth_gcs.md)
for the credentials and
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
to pass them;
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md).

## Examples

``` r
primary <- file.path(tempdir(), "rcs-example-auth-check")
st <- store_connect(primary, create = TRUE)
store_auth_check(st)
#> # A tibble: 1 × 4
#>   location                                                    client ok    note 
#>   <chr>                                                       <chr>  <lgl> <chr>
#> 1 /tmp/Rtmp/rcs-example-aut… all    TRUE  loca…
unlink(primary, recursive = TRUE)
```
