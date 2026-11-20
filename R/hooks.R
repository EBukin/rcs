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
