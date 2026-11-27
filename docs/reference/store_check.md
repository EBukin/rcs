# Check a stored dataset

Two checks, chosen by `x`:

## Usage

``` r
store_check(
  st,
  dataset,
  x = NULL,
  n = 20,
  columns = NULL,
  locations = "all",
  error = TRUE
)
```

## Arguments

- st:

  A store connection made by
  [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md).

- dataset:

  The dataset's full name, or its last part when that is unique.

- x:

  `NULL` for the integrity check, or the data the dataset was written
  from (data frame, `sf` object or `SpatRaster`) for the serialization
  check.

- n:

  Rows (or raster cells) compared per file.

- columns:

  `NULL` for all columns that `x` and the files share, or the names of
  the columns to compare.

- locations:

  `"all"` for every available location, or addresses of locations of the
  connection.

- error:

  `TRUE` aborts when a check fails; `FALSE` only reports.

## Value

A tibble, invisibly, with one row per location and file: `location`,
`dataset`, `path`, `status` (`"ok"`, `"failed"`, or `"missing"` when the
location does not hold the dataset) and `problem` (a description, `NA`
when ok).

## Details

- With `x`, a serialization check: for each file of the dataset, `n`
  rows of one random row group are read and compared, column by column,
  with the matching rows of `x`: matched by the key, else by `.rcs_id`,
  else (tables without key) by row order. Values are compared exactly,
  after normalisation (a tibble and a data frame are alike, geometries
  are compared as WKB, times as instants). Geospatial data without key
  and without a column `.rcs_id` are geocoded again to find the row
  identifiers, which matches only a dataset written in one call (not
  after an `update`). For a raster, see "Rasters".
  [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
  runs this check on the staged files before it uploads them.

- Without `x`, an integrity check of each location: every file of the
  current version exists with the MD5 its catalog records (read from the
  backend's metadata, so no data file is downloaded where the backend
  reports MD5), its Parquet footer has the recorded rows and the columns
  of the entry, the version is the hash of the file rows, the totals
  match, and the manifest agrees with the catalog. The dataset's index
  table is checked with it.

The catalogs of the checked locations are read again first, and the
connection is updated with them.

## Rasters

- With `x`, a
  [`terra::SpatRaster`](https://rspatial.github.io/terra/reference/SpatRaster-class.html):
  the stored file must have the layer names and the number of cells of
  `x`, and `n` random cells are compared, layer by layer, as a read
  returns them. A categorical layer is compared by its codes, not its
  labels. Cells of `x` that hold the dataset's NoData value count as
  missing, as they are in the file (after `store_write(nodata = 0)`, a
  `0` in `x` equals a missing cell of the file). A layer stored in
  single precision (`FLT4S`) may differ from `x` by a relative `1e-6`;
  every other type must be equal. The legend and the colours are not
  compared: they are in the catalog, not in the file. The file is opened
  through GDAL and only the sampled cells are read.

- Without `x`: the file exists with the MD5 its catalog records, the
  version and the totals match, and the manifest agrees with the
  catalog. The checks of Parquet footers do not apply to a raster.

## See also

[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md).

## Examples

``` r
root <- file.path(tempdir(), "rcs-example-check")
st <- store_connect(file.path(root, "primary"), create = TRUE)
sales <- rcs_sim_table(100, seed = 1)
store_write(st, sales, "sales/daily",
  title = "Daily sales", description = "Simulated daily sales.",
  key = c("shop_id", "date", "product"), partition = "year"
)
#> ℹ Writing "sales/daily": 100 rows in 2 files (partition year).
#> ✔ primary  /tmp/Rtmp/rcs-example-check/primary  2/2
#>   files sent  23.8 kB  0.2s
#> ✔ MD5 identical for 2 files in 1 location. Catalogs updated.
store_check(st, "sales/daily")
#> ✔ 2 files checked in 1 location: no problem found.
store_check(st, "sales/daily", x = sales)
#> ✔ 2 files checked in 1 location: no problem found.

# A class map written with `nodata = 0`: the cells of `x` that hold 0
# equal the missing cells of the file, and codes are compared with codes
if (requireNamespace("terra", quietly = TRUE)) {
  cover <- terra::as.int(rcs_sim_raster(nrow = 60, ncol = 80)[["cover"]])
  cover[1:2, ] <- 0L
  levels(cover) <- data.frame(
    value = 1:5,
    label = c("water", "forest", "crop", "grass", "bare")
  )
  names(cover) <- "cover"
  store_write(st, cover, "grids/cover",
    title = "Land cover", description = "A simulated class map.",
    nodata = 0
  )
  store_check(st, "grids/cover")
  store_check(st, "grids/cover", x = cover, n = 500)
}
#> ℹ Writing "grids/cover": 4,800 cells in 1 file.
#> ✔ primary  /tmp/Rtmp/rcs-example-check/primary  1/1
#>   files sent  1.9 kB  0.2s
#> ✔ MD5 identical for 1 file in 1 location. Catalogs updated.
#> ✔ 1 file checked in 1 location: no problem found.
#> ✔ 1 file checked in 1 location: no problem found.
unlink(root, recursive = TRUE)
```
