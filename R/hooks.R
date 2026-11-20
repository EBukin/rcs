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
