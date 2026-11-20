# Hooks: the functions that one work package implements and another calls.
# Wave 0 fixes their signatures here as stubs that abort with class
# `rcs_error_not_implemented`. The work package that implements a function
# moves its documentation to its own file, keeps the signature and the return
# value exactly, and deletes the stub from this file. Changing a signature
# means updating the plan first.
#
# Conventions shared by all hooks:
#   * H3 cells inside the package are `bit64::integer64`, always. Cells given
#     by a user are hex strings, `integer64` or `h3o` `H3` vectors; a plain
#     numeric aborts (it cannot hold a cell).
#   * WKB geometry is a bare list of raw vectors, one per row, in the column
#     `geometry`; Arrow writes it as `binary`.
#   * A bounding box is a named double `c(xmin, ymin, xmax, ymax)`; a column of
#     boxes is a `bbox_df()`.
#   * A CRS travels as one PROJJSON string.

# Work package B: R/geo-h3.R --------------------------------------------------

#' Convert H3 cells to the internal form
#'
#' Implemented by B; called by C, E and F.
#'
#' @param x Cells: hex strings, `integer64` or an `h3o` `H3` vector; `NA`
#'   stays `NA`.
#' @param arg,call Used in the error message.
#' @return `h3_as_int64()`: an `integer64` vector of the same length.
#'   `h3_as_hex()`: a character vector of the same length (15 lower-case hex
#'   characters). Both abort with class `rcs_error_h3_input` when `x` is a
#'   plain numeric or any other type, or holds a string that is not a valid
#'   cell.
#' @noRd
h3_as_int64 <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  abort_not_implemented("h3_as_int64", "B")
}

#' @noRd
h3_as_hex <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  abort_not_implemented("h3_as_hex", "B")
}

#' Parent cells, for grouping only
#'
#' A cell is not inside its parent, so the result is used to group rows into
#' partitions (`h3_p<r>`) and for nothing geometric. Implemented by B; called
#' by C.
#'
#' @param cells `integer64` vector of cells of one resolution; `NA` stays
#'   `NA`.
#' @param res One integer, 0 to the resolution of `cells`.
#' @return `integer64` vector of the same length: the parent of each cell at
#'   resolution `res` (the cell itself when `res` is its own resolution).
#'   Aborts when `res` is finer than the cells.
#' @noRd
h3_parent <- function(cells, res) {
  abort_not_implemented("h3_parent", "B")
}

# Work package B: R/geo-encode.R ----------------------------------------------

#' Prepare an `sf` object for writing
#'
#' Step 4 and, for geospatial data, step 6 of `store_write()`: identifiers,
#' geocodes, bounding boxes, WKB, the written order and the index-table rows.
#' Implemented by B; called by E.
#'
#' @param x An `sf` object with a CRS, in any CRS; zero rows are allowed. A
#'   column named `.rcs_id`, `h3` or `bbox`, or a geometry column not named
#'   `geometry` next to another column named `geometry`, aborts.
#' @param h3_res One integer, 0 to 15: the geocode resolution.
#' @param geocode `FALSE` skips geocoding: no `h3` column, `index` is `NULL`.
#' @param key Character vector of key columns, or `NULL`; used for the row
#'   order only (uniqueness is checked by the caller).
#' @param id_start `integer64` of length 1: the first `.rcs_id` to assign
#'   (`update` passes the dataset's current maximum plus one).
#'
#' @return A list:
#'
#'   * `data`: a tibble (not `sf`) with the columns of `x` without its
#'     geometry, then `.rcs_id` (`integer64`), `h3` (`integer64`, the cell at
#'     `h3_res` holding the largest part of the geometry; absent when
#'     `geocode = FALSE`), `bbox` (a `bbox_df()` in the CRS of `x`) and
#'     `geometry` (WKB, a bare list of raw vectors). Rows are in written
#'     order: by `h3`, then the key columns, ties in the order of `x`; with
#'     `geocode = FALSE` by the key columns, or as in `x` without a key.
#'     `.rcs_id` is `id_start`, `id_start + 1`, ... in that order. An empty
#'     geometry has `h3 = NA`, an all-`NA` `bbox`, and sorts last; with
#'     `partition = "h3"` such rows form one partition of their own, whose
#'     value is `NA` (`null` in `partition_values` and in the path).
#'   * `index`: the rows of the index table for the crossing rows, a tibble
#'     with `.rcs_id`, `h3` (every cell the row touches), `h3_main` (the
#'     row's `h3`) (all `integer64`) and `share` (double: fraction of the
#'     row's area or length in that cell; `1 / n` for points), sorted by
#'     `h3`, then `.rcs_id`. Zero rows when no row crosses; `NULL` when
#'     `geocode = FALSE`.
#'   * `crs`: the CRS of `x` as one PROJJSON string.
#'   * `bbox`: the extent of all rows, named double
#'     `c(xmin, ymin, xmax, ymax)` in the CRS of `x`; all `NA` when there is
#'     no non-empty geometry.
#'
#'   Aborts with class `rcs_error_geo` when `x` has no CRS or a reserved
#'   column name, and with the install hint (`rlang::check_installed()`) when
#'   the H3 package is missing and `geocode = TRUE`.
#' @noRd
geo_encode <- function(x, h3_res = 5L, geocode = TRUE, key = NULL,
                       id_start = bit64::as.integer64(1)) {
  abort_not_implemented("geo_encode", "B")
}

#' Turn rows read from a geospatial dataset into `sf`
#'
#' Implemented by B; called by F (`collect()`) and E (`store_check()`).
#'
#' @param data A data frame with a WKB column `geometry` (a list of raw
#'   vectors, as written by `geo_encode()` and as Arrow returns a `binary`
#'   column). All other columns are kept as they are, including `.rcs_id`,
#'   `h3` and `bbox` when present. A read drops `.rcs_id` (unless asked for)
#'   and returns `h3`, `bbox` and `h3_p<r>`; that is the caller's business.
#' @param crs The dataset's CRS: one PROJJSON string (`entry$crs`).
#' @return An `sf` object (a tibble) with the same rows in the same order
#'   and the geometry column `geometry` as its last column, in `crs`. Aborts
#'   with class `rcs_error_geo` when `data` has no `geometry` column.
#' @noRd
geo_decode <- function(data, crs) {
  abort_not_implemented("geo_decode", "B")
}

#' GeoParquet 1.1 `geo` metadata of one data file
#'
#' Implemented by B; called by C when it writes a file.
#'
#' @param data The rows of one file, as in `geo_encode()$data` (needs the
#'   columns `bbox` and `geometry`).
#' @param crs One PROJJSON string.
#' @return One JSON string for the key `geo`: `version "1.1.0"`,
#'   `primary_column "geometry"`, and for the column `encoding "WKB"`,
#'   `geometry_types` of the rows (sorted), `crs` (the PROJJSON as an object,
#'   not a string), `bbox` of the rows and `covering` pointing at the `bbox`
#'   struct column. The same rows give the same string.
#' @noRd
geo_metadata <- function(data, crs) {
  abort_not_implemented("geo_metadata", "B")
}

#' Cells that geometries touch
#'
#' Every cell at `h3_res` that intersects each geometry: the polygon-to-cells
#' function in the mode that returns all intersecting cells, applied to the
#' geometry itself; for lines and points the cells of the vertices and along
#' every segment. Geometries across the antimeridian or around a pole are
#' handled on the sphere. Implemented by B; called by B and F.
#'
#' @param x An `sfc` or `sf` object with a CRS, in any CRS.
#' @param h3_res One integer, 0 to 15.
#' @return A list with one element per geometry: a sorted `integer64` vector
#'   of distinct cells; `integer64(0)` for an empty geometry.
#' @noRd
geo_cells_touched <- function(x, h3_res) {
  abort_not_implemented("geo_cells_touched", "B")
}

#' Covering of a query shape
#'
#' Steps 1 and 2 of the spatial filter: normalise the query shape and find
#' the cells that can hold matching rows. Implemented by B; called by F and I.
#'
#' @param shape The query: an `sf`, `sfc` or `bbox` object with a CRS (several
#'   geometries are combined), or H3 cells of any resolution (hex strings,
#'   `integer64` or `H3`), which stand for their cell polygons. A plain
#'   numeric aborts with class `rcs_error_h3_input`.
#' @param h3_res The dataset's geocode resolution (`entry$h3_res`), or `NA`
#'   for a dataset written with `geocode = FALSE` or a raster; `cells` is
#'   then `NULL`.
#' @param crs The data CRS: one PROJJSON string (`entry$crs`).
#' @return A list:
#'
#'   * `shape`: an `sfc` of length 1 in the data CRS: the query shape,
#'     densified before the change of CRS; used for the exact test;
#'   * `bbox`: the box of that shape, named double
#'     `c(xmin, ymin, xmax, ymax)` in the data CRS; `NULL` when the shape
#'     crosses the antimeridian or holds a pole, and bounding-box tests must
#'     be skipped;
#'   * `cells`: sorted `integer64` vector of distinct cells at `h3_res`: every
#'     cell that intersects the shape plus their first ring; `NULL` when
#'     `h3_res` is `NA`.
#'
#'   Informs (through `rcs_inform()`) when a query cell is finer than
#'   `h3_res`. Aborts with class `rcs_error_geo` for a shape without CRS or an
#'   empty shape.
#' @noRd
geo_covering <- function(shape, h3_res, crs) {
  abort_not_implemented("geo_covering", "B")
}

# Work package I: R/raster.R --------------------------------------------------

#' Stage a raster for writing
#'
#' Writes a Cloud Optimized GeoTIFF into the staging folder and describes it.
#' Implemented by I; called by E.
#'
#' @param x A `terra::SpatRaster` with a CRS.
#' @param dataset Full dataset name.
#' @param title,description Non-empty strings.
#' @param source,inputs Strings or `NA`.
#' @param columns Named character vector, layer name to description, or
#'   `NULL`.
#' @param history Dataset-level history setting: `TRUE`, `FALSE` or `NA`.
#' @param dir The staging folder.
#' @return A list:
#'
#'   * `entry`: the entry, a one-row tibble made by `new_entry()`:
#'     `kind = "raster"`, `crs`, `bbox`, `rows` = number of cells,
#'     `n_files = 1`, `columns` with one row per layer whose `r_type` is
#'     `list(class = "SpatRaster", resolution = c(x, y), dim = c(nrow, ncol))`;
#'     `created` and `updated` are set by the caller;
#'   * `files`: its file row, made by `new_file_rows()`, with
#'     `path = data_file_path(dataset, version, ext = "tif")`,
#'     `partition_values = "{}"`, the `bbox` and no cells;
#'   * `staged`: the local file, `file.path(dir, files$path)`.
#'
#'   The version is `version_hash("{}", md5)`. Two calls with the same raster
#'   give the same version. Aborts with class `rcs_error_raster` when `x` has
#'   no CRS, and with the install hint when terra is missing.
#' @noRd
raster_stage <- function(x, dataset, title, description,
                         source = NA_character_, inputs = NA_character_,
                         columns = NULL, history = NA,
                         dir = rcs_option("rcs.staging_dir")) {
  abort_not_implemented("raster_stage", "I")
}

#' Open a stored raster
#'
#' Implemented by I; called by F.
#'
#' @param be The backend object of the location to read from.
#' @param path Relative path of the `.tif` file (`files$path`).
#' @param intersects `NULL`, or a query shape as for `geo_covering()`; the
#'   raster is then cropped to the bounding box of the shape in the raster's
#'   CRS.
#' @return A `terra::SpatRaster` opened through `be_gdal_path(be, path)`, so
#'   that only the tiles needed are read. Aborts with class
#'   `rcs_error_raster` when the shape does not overlap the raster, and with
#'   the bullets of `be_auth_hint(be)` when GDAL cannot open the file.
#' @noRd
raster_open <- function(be, path, intersects = NULL) {
  abort_not_implemented("raster_open", "I")
}

# Work package C: R/files.R ---------------------------------------------------

#' Row groups of stored Parquet files
#'
#' Reads the footers only. Implemented by C; called by E (`store_check()`)
#' and F (`store_sample()`, `store_glimpse()`).
#'
#' @param be A backend object.
#' @param paths Character vector of relative paths of Parquet files.
#' @return A tibble with one row per row group, in file and group order:
#'   `path` (character), `row_group` (integer, starting at 1) and `rows`
#'   (double). Counts one `file_open` per file.
#' @noRd
files_row_groups <- function(be, paths) {
  abort_not_implemented("files_row_groups", "C")
}

#' Read chosen row groups of one stored Parquet file
#'
#' Fetches only those row groups and columns. Implemented by C; called by E
#' and F.
#'
#' @param be A backend object.
#' @param path One relative path of a Parquet file.
#' @param row_groups Integer vector of row groups, starting at 1.
#' @param columns Character vector of column names, or `NULL` for all.
#' @return An [arrow::Table] with the rows of those groups in file order;
#'   no R types are restored and no geometry is decoded. Counts one
#'   `file_open`. Aborts with class `rcs_error_backend` when the file cannot
#'   be read, and (internal error) when a row group does not exist.
#' @noRd
files_read_row_groups <- function(be, path, row_groups, columns = NULL) {
  abort_not_implemented("files_read_row_groups", "C")
}

# Work package C: R/resolve.R -------------------------------------------------

#' Resolve a dataset name given by the user
#'
#' Implemented by C; called by every function that takes `dataset` for an
#' existing dataset.
#'
#' @param st An `rcs_store`.
#' @param dataset One string: a full name, or the last segment of one when it
#'   is unique among the datasets of the primary catalog that are not index
#'   tables.
#' @param index `TRUE` lets the name of an index table (`...__h3`) resolve.
#' @param call Environment for the error.
#' @return The full name, one string, as it stands in the primary catalog.
#'   Aborts with class `rcs_error_dataset_not_found` for an unknown name and
#'   `rcs_error_dataset_ambiguous` for a short name shared by several
#'   datasets; both list the closest names (`agrep()`).
#' @noRd
resolve_dataset <- function(st, dataset, index = FALSE, call = caller_env()) {
  abort_not_implemented("resolve_dataset", "C")
}

#' Choose the location a read is served from
#'
#' Among the available locations whose catalog holds the dataset at the
#' primary's version: local backends first, then the primary, then the other
#' secondaries in connection order. For an old `version`, a location is
#' eligible only if it still holds every file of that version. Uses the
#' catalogs held by the connection; makes no backend call for the current
#' version. Implemented by C; called by F.
#'
#' @param st An `rcs_store`.
#' @param dataset Full dataset name, already resolved.
#' @param version `NULL` for the current version, or 16 hex characters.
#' @param call Environment for the error.
#' @return The chosen `rcs_location`. Informs
#'   `Reading "<dataset>" from secondary <uri>.` through `rcs_inform()` when
#'   it is not the primary. Aborts with class `rcs_error_version_not_found`
#'   when no location holds the version.
#' @noRd
choose_location <- function(st, dataset, version = NULL, call = caller_env()) {
  abort_not_implemented("choose_location", "C")
}
