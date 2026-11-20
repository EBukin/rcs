# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: work package C, R/catalog.R (rebuild from file metadata), used by
# store_rebuild() in work package G.
#
# What it shows: reading the key-value metadata, row count, size and MD5 of
# every Parquet file under a local folder and binding one row per file.
#
# What the plan changes:
#   * files are listed through the backend (`be_list()`), not `list.files()`;
#   * the metadata is one JSON object under the key `rcs`;
#   * the result is split into `_catalog.parquet` (one row per dataset) and
#     `_files.parquet` (one row per file), with the plan's schemas;
#   * the current version of a dataset comes from its newest manifest
#     (`<dataset>/_manifest-<version>.json`), not from the file listing alone;
#   * raster files (`.tif`) are described by their manifest.

#' Read the footers of all Parquet files under a local folder
#'
#' @param root Local folder.
#' @param fields Metadata keys to return as columns; missing keys give `NA`.
#'
#' @return A tibble with one row per file: the metadata fields, `path`
#'   (relative, forward slashes), `rows`, `bytes`, `md5` (hex).
#' @noRd
catalog_scan_local <- function(root, fields) {
  files <- list.files(root, pattern = "\\.parquet$", recursive = TRUE)
  files <- files[!grepl("^_", basename(files))]
  if (length(files) == 0) {
    cli::cli_abort("No Parquet data files under {.path {root}}.")
  }
  rows <- lapply(files, function(file) {
    path <- file.path(root, file)
    reader <- arrow::ParquetFileReader$create(path)
    meta <- reader$GetSchema()$metadata
    if (is.null(meta$dataset)) {
      cli::cli_abort("{.path {file}} carries no store metadata.")
    }
    row <- lapply(stats::setNames(fields, fields), \(f) meta[[f]] %||% NA_character_)
    row$path <- gsub("\\\\", "/", file)
    row$rows <- reader$num_rows
    row$bytes <- file.size(path)
    row$md5 <- digest::digest(path, algo = "md5", file = TRUE)
    tibble::as_tibble(row)
  })
  dplyr::bind_rows(rows)
}
