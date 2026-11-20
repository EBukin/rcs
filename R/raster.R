# Rasters: staging a `terra::SpatRaster` as one Cloud Optimized GeoTIFF with
# its catalog entry and file row, and opening a stored raster through GDAL.
#
# Rules (see the plan, "Rasters"):
#   * One file per dataset, `<dataset>/part-<version>.tif`; no partitions.
#   * Nothing of the package is embedded in the TIFF; the manifest, built by
#     the caller from `entry` and `files`, describes the file. Layer names
#     travel as GDAL band descriptions, which terra writes and reads itself.
#   * Every layer of a GeoTIFF has one data type. Layers that are all integer
#     (`terra::is.int()`) are written as `INT4S`, anything else as `FLT8S`, so
#     that values survive unchanged; the type is recorded per layer in
#     `columns$type` as terra reports it for the written file. terra returns
#     missing cells of a floating-point layer as `NaN`.
#   * Writing is deterministic: two stagings of the same raster give the same
#     MD5 and the same version.
#   * Categorical layers are refused: terra keeps their categories in a side
#     file (`.aux.xml`) that would not travel with the dataset.

check_terra <- function(call = caller_env()) {
  rlang::check_installed("terra", reason = "to store rasters.", call = call)
}

raster_abort <- function(message, ..., call = caller_env(), .envir = parent.frame()) {
  cli::cli_abort(message, ..., class = "rcs_error_raster", call = call, .envir = .envir)
}

# PROJJSON of a raster's CRS, or NA when it has none.
raster_crs_json <- function(x) {
  wkt <- terra::crs(x)
  if (!nzchar(wkt)) {
    return(NA_character_)
  }
  crs <- tryCatch(sf::st_crs(wkt), error = function(e) sf::NA_crs_)
  if (is.na(crs)) NA_character_ else crs$ProjJson
}

# Extent of a raster as a named double `c(xmin, ymin, xmax, ymax)`.
raster_bbox <- function(x) {
  e <- as.vector(terra::ext(x))
  c(xmin = e[["xmin"]], ymin = e[["ymin"]], xmax = e[["xmax"]], ymax = e[["ymax"]])
}

check_raster_descriptions <- function(descriptions, layers, call = caller_env()) {
  if (is.null(descriptions)) {
    return(invisible())
  }
  if (!is.character(descriptions) || !rlang::is_named(descriptions)) {
    cli::cli_abort(
      "{.arg columns} must be a named character vector of descriptions.",
      class = "rcs_error_argument", call = call
    )
  }
  unknown <- setdiff(names(descriptions), layers)
  if (length(unknown) > 0) {
    cli::cli_abort(
      "{.arg columns} describes layer{?s} the raster lacks: {.field {unknown}}.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible()
}

#' Stage a raster for writing
#'
#' Writes a Cloud Optimized GeoTIFF into the staging folder and describes it.
#' Implemented by I; called by E.
#'
#' The file is written with `terra::writeRaster(filetype = "COG")`, as
#' `INT4S` when every layer is integer and as `FLT8S` otherwise. No manifest
#' is written: the caller sets `created` and `updated` of the entry and then
#' builds the manifest from `entry` and `files` (`new_manifest()`).
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
#'   no CRS, no values, repeated layer names or categorical layers, with class
#'   `rcs_error_argument` when `x` is not a `SpatRaster` or `columns`
#'   describes a layer `x` lacks, and with the install hint when terra is
#'   missing.
#' @noRd
raster_stage <- function(x, dataset, title, description,
                         source = NA_character_, inputs = NA_character_,
                         columns = NULL, history = NA,
                         dir = rcs_option("rcs.staging_dir")) {
  check_terra()
  if (!inherits(x, "SpatRaster")) {
    cli::cli_abort(
      "{.arg x} must be a {.cls SpatRaster}, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument"
    )
  }
  check_dataset_name(dataset)
  check_string(title)
  check_string(description)
  crs <- raster_crs_json(x)
  if (is.na(crs)) {
    raster_abort(c(
      "The raster has no coordinate reference system.",
      i = "Set one with {.code terra::crs(x) <- ...}."
    ))
  }
  if (!all(terra::hasValues(x))) {
    raster_abort("The raster has no cell values.")
  }
  layers <- names(x)
  if (anyDuplicated(layers) > 0) {
    raster_abort(c(
      "Layer names must be unique.",
      x = "Repeated: {.field {unique(layers[duplicated(layers)])}}."
    ))
  }
  if (any(terra::is.factor(x))) {
    raster_abort(c(
      "Categorical layers cannot be stored: {.field {layers[terra::is.factor(x)]}}.",
      i = "Store the codes, e.g. with {.code terra::as.int()}, and the categories as a table."
    ))
  }
  check_raster_descriptions(columns, layers)

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  tmp_dir <- file.path(
    dir,
    paste0(".rcs-tmp-", md5_string(paste(dataset, Sys.getpid(), as.numeric(Sys.time()))))
  )
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  tmp <- file.path(tmp_dir, "part.tif")
  datatype <- if (all(terra::is.int(x))) "INT4S" else "FLT8S"
  terra::writeRaster(x, tmp, filetype = "COG", datatype = datatype, overwrite = TRUE)
  types <- terra::datatype(terra::rast(tmp))

  md5 <- md5_file(tmp)
  bytes <- file.size(tmp)
  version <- version_hash("{}", md5)
  path <- data_file_path(dataset, version, ext = "tif")
  staged <- file.path(dir, path)
  dir.create(dirname(staged), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(staged)) unlink(staged)
  if (!file.rename(tmp, staged)) {
    cli::cli_abort("Cannot move a staged file to {.path {staged}}.")
  }

  r_type <- list(
    class = "SpatRaster",
    resolution = as.double(terra::res(x)),
    dim = as.integer(c(terra::nrow(x), terra::ncol(x)))
  )
  description_of <- if (!is.null(columns)) unname(columns[layers])
  spec <- columns_spec(
    name = layers,
    type = types,
    r_type = rep(list(r_type), length(layers)),
    description = description_of
  )
  bbox <- raster_bbox(x)
  now <- now_utc()
  files <- new_file_rows(
    dataset = dataset, version = version, path = path,
    partition_values = "{}", rows = terra::ncell(x), bytes = bytes, md5 = md5,
    bbox = as_bbox_row(bbox), created = now
  )
  entry <- new_entry(
    dataset = dataset, kind = "raster", title = title, description = description,
    version = version, n_files = 1, rows = terra::ncell(x), bytes = bytes,
    columns = columns_to_json(spec), source = source, inputs = inputs,
    crs = crs, bbox = bbox, history = history, created = now, updated = now
  )
  list(entry = entry, files = files, staged = staged)
}

#' Open a stored raster
#'
#' Implemented by I; called by F.
#'
#' The query's bounding box in the raster's CRS comes from `geo_covering()`
#' (the shape densified before any change of CRS). The crop snaps outwards
#' to whole cells, so a point or a line still gives the cells it touches. A
#' shape that crosses the antimeridian or holds a pole has no usable box
#' (`geo_covering()$bbox` is `NULL`); the raster is then returned uncropped.
#'
#' @param be The backend object of the location to read from.
#' @param path Relative path of the `.tif` file (`files$path`).
#' @param intersects `NULL`, or a query shape as for `geo_covering()`; the
#'   raster is then cropped to the bounding box of the shape in the raster's
#'   CRS.
#' @return A `terra::SpatRaster` opened through `be_gdal_path(be, path)`, so
#'   that only the tiles needed are read. Aborts with class
#'   `rcs_error_raster` when the shape does not overlap the raster, and with
#'   the bullets of `be_auth_hint(be)` when GDAL cannot open the file (class
#'   `rcs_error_backend`). Counts one `file_open`.
#' @noRd
raster_open <- function(be, path, intersects = NULL) {
  check_terra()
  gdal_path <- be_gdal_path(be, path)
  r <- tryCatch(
    terra::rast(gdal_path),
    error = function(e) {
      cli::cli_abort(
        c("GDAL cannot open {.path {path}} in {.path {be$uri}}.", be_auth_hint_safe(be)),
        class = "rcs_error_backend", parent = e, call = NULL
      )
    }
  )
  trace_count("file_open", 1, location = be$uri, detail = path)
  if (is.null(intersects)) {
    return(r)
  }
  crs <- raster_crs_json(r)
  if (is.na(crs)) {
    raster_abort("The stored raster {.path {path}} has no coordinate reference system.")
  }
  query <- geo_covering(intersects, NA_integer_, crs)
  if (is.null(query$bbox)) {
    return(r)
  }
  terra::crop(r, raster_snap_extent(r, query$bbox, path), snap = "near")
}

# The query box snapped outwards to the raster's cells and clipped to its
# extent, as a `terra::ext()`. A box of zero width or height still covers
# the cells it touches. Aborts with class `rcs_error_raster` when the box
# does not overlap the raster.
raster_snap_extent <- function(r, bbox, path, call = caller_env()) {
  full <- raster_bbox(r)
  overlaps <- bbox[["xmin"]] <= full[["xmax"]] && bbox[["xmax"]] >= full[["xmin"]] &&
    bbox[["ymin"]] <= full[["ymax"]] && bbox[["ymax"]] >= full[["ymin"]]
  if (!isTRUE(overlaps)) {
    raster_abort(
      c(
        "The query does not overlap the raster {.path {path}}.",
        i = "Query box: {format_box(bbox)}.",
        i = "Raster extent: {format_box(full)}."
      ),
      call = call
    )
  }
  res <- terra::res(r)
  snap <- function(lo, hi, origin, step, n) {
    i0 <- min(max(floor((lo - origin) / step), 0), n)
    i1 <- min(max(ceiling((hi - origin) / step), 0), n)
    if (i1 <= i0) {
      if (i0 >= n) i0 <- n - 1 else i1 <- i0 + 1
    }
    origin + c(i0, i1) * step
  }
  x <- snap(bbox[["xmin"]], bbox[["xmax"]], full[["xmin"]], res[[1]], terra::ncol(r))
  y <- snap(bbox[["ymin"]], bbox[["ymax"]], full[["ymin"]], res[[2]], terra::nrow(r))
  terra::ext(x[[1]], x[[2]], y[[1]], y[[2]])
}

format_box <- function(bbox) {
  paste0(names(bbox), " ", signif(bbox, 6), collapse = ", ")
}
