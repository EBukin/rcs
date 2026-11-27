# Rasters: staging as a Cloud Optimized GeoTIFF and opening through GDAL,
# on local paths, without `store_write()`.

# Stage a small simulated raster into a fresh folder and return the result.
stage_sim_raster <- function(x = rcs_sim_raster(nrow = 12, ncol = 16), dataset = "grids/sim",
                             dir = withr::local_tempdir(.local_envir = parent.frame()), ...) {
  raster_stage(
    x, dataset,
    title = "Simulated grid", description = "A small simulated raster.",
    dir = dir, ...
  )
}

values_equal <- function(a, b) {
  a <- unname(terra::values(a))
  b <- unname(terra::values(b))
  identical(dim(a), dim(b)) && identical(is.na(a), is.na(b)) &&
    identical(a[!is.na(a)], b[!is.na(b)])
}

# The integer type of plan 0006, D-A2 rule 3, for values from `lo` to `hi`:
# the first type whose range holds them and leaves its default NoData flag
# free (D-A3 rule 4); `FLT8S` when none does.
smallest_int_type <- function(lo, hi) {
  ranges <- list(
    INT1U = c(0, 254), INT2U = c(0, 65534), INT2S = c(-32767, 32767),
    INT4U = c(0, 4294967294), INT4S = c(-2147483647, 2147483647)
  )
  fits <- vapply(ranges, function(r) lo >= r[[1]] && hi <= r[[2]], logical(1))
  if (any(fits)) names(ranges)[[which(fits)[[1]]]] else "FLT8S"
}

test_that("raster_stage() writes one COG and describes it", {
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 12, ncol = 16)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, columns = c(cover = "Cover class."))

  expect_named(out, c("entry", "files", "staged"))
  expect_true(file.exists(out$staged))
  expect_identical(out$staged, file.path(dir, out$files$path))
  version <- out$entry$version
  expect_identical(out$files$path, paste0("grids/sim/part-", version, ".tif"))
  expect_identical(version, version_hash("{}", md5_file(out$staged)))
  expect_identical(out$files$md5, md5_file(out$staged))
  expect_equal(as.numeric(out$files$bytes), file.size(out$staged))
  expect_identical(out$files$partition_values, "{}")
  expect_identical(out$files$version, version)
  expect_true(is.na(out$files$h3_min) && is.na(out$files$h3_max))
  # nothing but the data file is left in the staging folder
  expect_identical(
    list.files(dir, recursive = TRUE, all.files = TRUE),
    out$files$path
  )

  entry <- out$entry
  expect_silent(schema_validate(entry, "catalog"))
  expect_identical(entry$kind, "raster")
  expect_equal(as.numeric(entry$n_files), 1)
  expect_equal(as.numeric(entry$rows), 12 * 16)
  expect_equal(as.numeric(entry$bytes), file.size(out$staged))
  expect_identical(lengths(c(entry$key, entry$partition)), c(0L, 0L))
  expect_true(is.na(entry$h3_res))
  expect_true(sf::st_crs(entry$crs) == sf::st_crs(4326))
  expect_equal(unlist(entry$bbox), c(xmin = -30, ymin = 6, xmax = -24, ymax = 9))
  expect_equal(unlist(out$files$bbox), unlist(entry$bbox))

  spec <- columns_from_json(entry$columns)
  expect_identical(spec$name, c("height", "cover", "moisture"))
  expect_identical(spec$type, rep("FLT8S", 3))
  expect_identical(spec$description, c(NA, "Cover class.", NA))
  for (r_type in spec$r_type) {
    expect_identical(r_type$class, "SpatRaster")
    expect_equal(r_type$resolution, terra::res(x))
    expect_identical(r_type$dim, c(12L, 16L))
  }
  expect_s3_class(new_manifest(entry, out$files), "rcs_manifest")
})

test_that("staging is deterministic", {
  skip_if_not_installed("terra")
  a <- stage_sim_raster(rcs_sim_raster(seed = 3, nrow = 10, ncol = 10))
  b <- stage_sim_raster(rcs_sim_raster(seed = 3, nrow = 10, ncol = 10))
  expect_identical(a$files$md5, b$files$md5)
  expect_identical(a$entry$version, b$entry$version)
  expect_identical(a$files$path, b$files$path)
  c <- stage_sim_raster(rcs_sim_raster(seed = 4, nrow = 10, ncol = 10))
  expect_false(identical(a$entry$version, c$entry$version))
})

test_that("values, CRS, extent, names and types survive stage and open", {
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 12, ncol = 16)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  r <- raster_open(be_new(dir), out$files$path)

  expect_s4_class(r, "SpatRaster")
  expect_identical(names(r), names(x))
  expect_true(values_equal(r, x))
  expect_identical(as.vector(terra::ext(r)), as.vector(terra::ext(x)))
  expect_identical(terra::res(r), terra::res(x))
  expect_identical(dim(r), dim(x))
  expect_true(sf::st_crs(terra::crs(r)) == sf::st_crs(out$entry$crs))
  expect_identical(terra::datatype(r), columns_from_json(out$entry$columns)$type)
  # opened from the file, not read into memory
  expect_false(any(terra::inMemory(r)))
})

test_that("integer layers are stored as integers", {
  skip_if_not_installed("terra")
  x <- terra::as.int(rcs_sim_raster(nrow = 8, ncol = 9))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  # the smallest type that holds the values (plan 0006, D-A2 rule 3)
  range <- terra::minmax(x, compute = TRUE)
  expected <- smallest_int_type(min(range), max(range))
  expect_identical(columns_from_json(out$entry$columns)$type, rep(expected, 3))
  r <- raster_open(be_new(dir), out$files$path)
  expect_true(all(terra::is.int(r)))
  expect_true(values_equal(r, x))
})

test_that("a projected raster keeps its CRS and extent", {
  skip_if_not_installed("terra")
  x <- terra::project(rcs_sim_raster(nrow = 10, ncol = 12), "EPSG:32626")
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_true(sf::st_crs(out$entry$crs) == sf::st_crs(32626))
  r <- raster_open(be_new(dir), out$files$path)
  expect_true(sf::st_crs(terra::crs(r)) == sf::st_crs(32626))
  expect_equal(as.vector(terra::ext(r)), as.vector(terra::ext(x)))
  expect_true(values_equal(r, x))
})

test_that("intersects crops to the query's box, snapped out to whole cells", {
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 20, ncol = 30) # cells of 0.2 x 0.15 degrees
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  be <- be_new(dir)

  box <- sf::st_bbox(c(xmin = -27.1, ymin = 7.3, xmax = -26.5, ymax = 8.1), crs = sf::st_crs(4326))
  r <- raster_open(be, out$files$path, intersects = box)
  expect_equal(as.vector(terra::ext(r)), c(xmin = -27.2, xmax = -26.4, ymin = 7.2, ymax = 8.1))
  expect_true(values_equal(r, terra::crop(x, terra::ext(r))))

  # an sf polygon gives the same result as its box
  polygon <- sf::st_as_sfc(box)
  expect_equal(
    as.vector(terra::ext(raster_open(be, out$files$path, intersects = sf::st_sf(geometry = polygon)))),
    as.vector(terra::ext(r))
  )

  # a point gives the one cell that holds it
  point <- sf::st_sfc(sf::st_point(c(-27.1, 7.3)), crs = 4326)
  p <- raster_open(be, out$files$path, intersects = point)
  expect_equal(dim(p)[1:2], c(1, 1))
  expect_equal(as.vector(terra::ext(p)), c(xmin = -27.2, xmax = -27.0, ymin = 7.2, ymax = 7.35))

  # a box larger than the raster gives the whole raster
  large <- sf::st_bbox(c(xmin = -40, ymin = 0, xmax = -20, ymax = 20), crs = sf::st_crs(4326))
  expect_true(values_equal(raster_open(be, out$files$path, intersects = large), x))
})

test_that("intersects accepts a query in another CRS", {
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 20, ncol = 30)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  # a rectangle in UTM zone 26N, inside the raster
  query <- sf::st_bbox(c(xmin = 270000, ymin = 810000, xmax = 330000, ymax = 890000), crs = sf::st_crs(32626))
  r <- raster_open(be_new(dir), out$files$path, intersects = query)
  e <- as.vector(terra::ext(r))
  # every corner of the query, in the raster's CRS, lies in the snapped extent
  corners <- sf::st_coordinates(sf::st_transform(sf::st_cast(sf::st_as_sfc(query), "POINT"), 4326))
  expect_true(all(corners[, "X"] >= e[["xmin"]] & corners[, "X"] <= e[["xmax"]]))
  expect_true(all(corners[, "Y"] >= e[["ymin"]] & corners[, "Y"] <= e[["ymax"]]))
  # and the extent is no more than one cell wider than the corners' box
  expect_lte(e[["xmax"]] - e[["xmin"]], diff(range(corners[, "X"])) + 2 * 0.2 + 1e-9)
  expect_lte(e[["ymax"]] - e[["ymin"]], diff(range(corners[, "Y"])) + 2 * 0.15 + 1e-9)
  expect_true(values_equal(r, terra::crop(x, terra::ext(r))))
})

test_that("intersects accepts H3 cells", {
  skip_if_not_installed("terra")
  skip_if_not_installed("h3o")
  x <- rcs_sim_raster(nrow = 20, ncol = 30)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  cell <- h3o::h3_from_xy(7.5, -27, 4L) # latitude first
  hex <- as.character(cell)
  r <- raster_open(be_new(dir), out$files$path, intersects = hex)
  cell_box <- sf::st_bbox(sf::st_as_sfc(cell))
  e <- as.vector(terra::ext(r))
  expect_lte(e[["xmin"]], cell_box[["xmin"]])
  expect_gte(e[["xmax"]], cell_box[["xmax"]])
  expect_lte(e[["ymin"]], cell_box[["ymin"]])
  expect_gte(e[["ymax"]], cell_box[["ymax"]])
  expect_identical(
    as.vector(terra::ext(raster_open(be_new(dir), out$files$path, intersects = h3_as_int64(hex)))),
    e
  )
})

test_that("a query outside the raster aborts", {
  skip_if_not_installed("terra")
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(dir = dir)
  far <- sf::st_bbox(c(xmin = -20, ymin = 7, xmax = -19, ymax = 8), crs = sf::st_crs(4326))
  expect_error(
    raster_open(be_new(dir), out$files$path, intersects = far),
    class = "rcs_error_raster"
  )
  expect_snapshot(
    raster_open(be_new(dir), out$files$path, intersects = far),
    error = TRUE,
    transform = function(x) gsub("part-[0-9a-f]{16}", "part-<version>", x)
  )
})

test_that("raster_open() counts one opened file", {
  skip_if_not_installed("terra")
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(dir = dir)
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  raster_open(be_new(dir), out$files$path)
  counts <- rcs_trace()
  expect_equal(sum(counts$n[counts$counter == "file_open"]), 1)
  expect_equal(sum(counts$n[counts$detail %in% "be_gdal_path"]), 1)
})

test_that("a file GDAL cannot open aborts with the backend's hint", {
  skip_if_not_installed("terra")
  dir <- withr::local_tempdir()
  expect_error(
    raster_open(be_new(dir), "grids/none/part-0000000000000000.tif"),
    class = "rcs_error_backend"
  )
})

test_that("raster_stage() aborts on unusable rasters", {
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 5, ncol = 5)

  no_crs <- x
  terra::crs(no_crs) <- ""
  expect_error(stage_sim_raster(no_crs), class = "rcs_error_raster")

  empty <- terra::rast(nrows = 5, ncols = 5, crs = "EPSG:4326")
  expect_error(stage_sim_raster(empty), class = "rcs_error_raster")

  repeated <- x
  names(repeated) <- c("a", "a", "b")
  expect_error(stage_sim_raster(repeated), class = "rcs_error_raster")

  expect_error(stage_sim_raster(data.frame(a = 1)), class = "rcs_error_argument")
  expect_error(
    stage_sim_raster(x, columns = c(nothing = "No such layer.")),
    class = "rcs_error_argument"
  )
  expect_error(stage_sim_raster(x, dataset = "Bad Name"), class = "rcs_error_dataset_name")

  expect_snapshot(stage_sim_raster(no_crs), error = TRUE)
})

test_that("raster functions need terra", {
  local_mocked_bindings(
    check_installed = function(pkg, ...) {
      cli::cli_abort("The package {.pkg {pkg}} is required.", class = "rlib_error_package_not_found")
    },
    .package = "rlang"
  )
  expect_error(raster_stage(NULL, "a", "t", "d"), class = "rlib_error_package_not_found")
  expect_error(raster_open(NULL, "a.tif"), class = "rlib_error_package_not_found")
})

test_that("a raster opens from GCS through /vsigs/", {
  skip_if_not_installed("terra")
  skip_below_level("full")
  uri <- Sys.getenv("RCS_TEST_GCS")
  skip_if(!nzchar(uri), "RCS_TEST_GCS is not set.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  # `raster_open()` sets GDAL credentials process-wide: restore GDAL's options
  # and the cached GDAL state of `the_auth` afterwards.
  gdal_opts <- c(
    "GS_OAUTH2_REFRESH_TOKEN", "GS_OAUTH2_CLIENT_ID", "GS_OAUTH2_CLIENT_SECRET",
    "GOOGLE_APPLICATION_CREDENTIALS", "GDAL_HTTP_HEADERS"
  )
  old_gdal <- terra::getGDALconfig(gdal_opts)
  names(old_gdal) <- gdal_opts
  withr::defer(for (k in gdal_opts) terra::setGDALconfig(k, old_gdal[[k]]))
  fields <- c("gdal_id", "gdal_header", "gdal_warned")
  old_auth <- mget(fields, envir = the_auth, ifnotfound = list(NULL))
  rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
  withr::defer({
    rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
    for (f in names(old_auth)) if (!is.null(old_auth[[f]])) assign(f, old_auth[[f]], envir = the_auth)
  })
  prefix <- paste0("rcs-test-", paste(sample(c(letters, 0:9), 12, TRUE), collapse = ""))
  be <- be_new(paste0(sub("/+$", "", uri), "/", prefix))
  withr::defer({
    left <- be_list(be)$path
    if (length(left) > 0) be_delete(be, left)
  })
  x <- rcs_sim_raster(nrow = 20, ncol = 30)
  out <- stage_sim_raster(x)
  be_put(be, out$staged, out$files$path)
  r <- raster_open(be, out$files$path)
  expect_true(values_equal(r, x))
  box <- sf::st_bbox(c(xmin = -27.1, ymin = 7.3, xmax = -26.5, ymax = 8.1), crs = sf::st_crs(4326))
  cropped <- raster_open(be, out$files$path, intersects = box)
  expect_true(values_equal(cropped, terra::crop(x, terra::ext(cropped))))

  # Plan 0006, A-T20: a class map with nodata and a legend, opened with its
  # columns. Red until WP3: unused argument `nodata`.
  source <- withr::local_tempfile(fileext = ".tif")
  map <- sim_landcover(file = source, legend = TRUE)
  staged <- stage_sim_raster(map, dataset = "grids/cover", nodata = 0)
  be_put(be, staged$staged, staged$files$path)
  spec <- columns_from_json(staged$entry$columns)
  whole <- raster_open(be, staged$files$path, columns = spec)
  expect_true(terra::is.factor(whole))
  expect_identical(terra::datatype(whole), "INT1U")
  codes <- sim_landcover()
  codes[codes == 0] <- NA
  expect_true(all(is.na(terra::values(whole)) == is.na(terra::values(codes))))
  expect_equal(as.vector(terra::values(whole)), as.vector(terra::values(codes)))
  part <- raster_open(be, staged$files$path, intersects = box, columns = spec)
  expect_true(terra::is.factor(part))
  expect_identical(as.character(terra::cats(part)[[1]]$label), sim_landcover_labels)
  expect_equal(
    as.vector(terra::values(part)),
    as.vector(terra::values(terra::crop(codes, terra::ext(part))))
  )
})

# Plan 0006: types, nodata, options, legend, staging ---------------------------
#
# Each test states why it fails before the code of plan 0006 exists ("Red"),
# or that it passes already ("Guard").

# The finite NoData tag of each band of a GeoTIFF; NA when there is none or it
# is not finite (`NoData Value=nan`). Read here with GDAL alone, so that the
# tests do not depend on the package's own reader.
nodata_tag <- function(file) {
  info <- jsonlite::fromJSON(
    paste(terra::describe(file, options = "json"), collapse = "\n"),
    simplifyVector = FALSE
  )
  tags <- vapply(info$bands, function(band) {
    value <- band$noDataValue
    if (is.null(value)) NA_real_ else suppressWarnings(as.numeric(value))
  }, numeric(1))
  tags[!is.finite(tags)] <- NA_real_
  tags
}

# Lines of `gdalinfo` for a file.
gdal_info <- function(file) {
  terra::describe(file)
}

expect_info <- function(info, text) {
  expect_true(any(grepl(text, info, fixed = TRUE)), label = paste0("gdalinfo shows '", text, "'"))
}

# The `r_type` of layer `i` of a staged raster.
staged_r_type <- function(out, i = 1L) {
  columns_from_json(out$entry$columns)$r_type[[i]]
}

staged_type <- function(out) {
  columns_from_json(out$entry$columns)$type
}

# As `values_equal()`, for a categorical raster: terra returns its codes as
# doubles, so the codes are compared by value, not by storage type.
codes_equal <- function(a, b) {
  a <- unname(terra::values(a))
  b <- unname(terra::values(b))
  identical(dim(a), dim(b)) && identical(is.na(a), is.na(b)) &&
    all(a[!is.na(a)] == b[!is.na(b)])
}

# The cells holding `0` become missing.
zero_as_missing <- function(x) {
  x[x == 0] <- NA
  x
}

# A small class map whose cell `i` holds `value`.
landcover_with <- function(value, i = 40L) {
  x <- sim_landcover(nrow = 12, ncol = 16)
  x[i] <- value
  x
}

# A source file with an exact NoData tag (or none: `tag = "none"`).
write_source <- function(x, file, datatype, tag = "none") {
  tmp <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(x, tmp, datatype = datatype, gdal = "COMPRESS=LZW")
  sf::gdal_utils(
    "translate", tmp, file,
    options = c("-a_nodata", as.character(tag), "-co", "COMPRESS=LZW"), quiet = TRUE
  )
  terra::rast(file)
}

spat_files <- function() {
  list.files(tempdir(), pattern = "^spat_", recursive = TRUE, all.files = TRUE)
}

test_that("in-memory whole numbers with missing cells are stored as INT1U with nodata 255", {
  # A-T1. Red: the type is INT4S and no nodata is recorded.
  skip_if_not_installed("terra")
  x <- zero_as_missing(sim_landcover(nrow = 12, ncol = 16))
  expect_true(terra::is.int(x))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(staged_type(out), "INT1U")
  expect_equal(staged_r_type(out)$nodata, 255)
  expect_identical(nodata_tag(out$staged), 255)
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), "INT1U")
  expect_true(values_equal(r, x))
})

test_that("the integer type follows the range of the values", {
  # A-T2. Red: every integer raster is stored as INT4S (the last case, which
  # expects INT4S, fails on its nodata alone).
  skip_if_not_installed("terra")
  cases <- list(
    list(value = 254L, type = "INT1U", nodata = 255),
    list(value = 255L, type = "INT2U", nodata = 65535),
    list(value = -5L, type = "INT2S", nodata = -32768),
    list(value = 70000L, type = "INT4U", nodata = 4294967295),
    list(value = -70000L, type = "INT4S", nodata = -2147483648)
  )
  for (case in cases) {
    x <- landcover_with(case$value)
    dir <- withr::local_tempdir()
    out <- stage_sim_raster(x, dir = dir)
    expect_identical(staged_type(out), case$type, info = case$type)
    expect_equal(staged_r_type(out)$nodata, case$nodata, info = case$type)
    expect_identical(nodata_tag(out$staged), case$nodata, info = case$type)
    r <- raster_open(be_new(dir), out$files$path)
    expect_identical(terra::datatype(r), case$type, info = case$type)
    expect_true(values_equal(r, x), info = case$type)
  }
})

test_that("in-memory doubles stay FLT8S, without nodata, and round-trip exactly", {
  # A-T3. Guard.
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 12, ncol = 16)
  x[["height"]][5] <- NA
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(staged_type(out), rep("FLT8S", 3))
  expect_null(staged_r_type(out)$nodata)
  expect_identical(nodata_tag(out$staged), rep(NA_real_, 3))
  r <- raster_open(be_new(dir), out$files$path)
  expect_true(values_equal(r, x))
})

test_that("a Byte file written with nodata = 0 stays Byte and its zeros read as missing", {
  # A-T4. Red: unused argument `nodata`.
  skip_if_not_installed("terra")
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"))
  expect_identical(terra::datatype(x), "INT1U")
  expect_identical(nodata_tag(terra::sources(x)), NA_real_)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  info <- gdal_info(out$staged)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=0")
  expect_identical(staged_type(out), "INT1U")
  expect_equal(staged_r_type(out)$nodata, 0)
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), "INT1U")
  edge <- terra::cellFromRowCol(r, c(1, 2, 59, 60, 30, 30), c(40, 40, 40, 40, 1, 80))
  expect_true(all(is.na(terra::values(r)[edge])))
  expect_true(values_equal(r, zero_as_missing(sim_landcover())))
})

test_that("a file-backed FLT4S source stays FLT4S", {
  # A-T5. Red: stored as FLT8S.
  skip_if_not_installed("terra")
  file <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(rcs_sim_raster(nrow = 12, ncol = 16), file, datatype = "FLT4S")
  x <- terra::rast(file)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(staged_type(out), rep("FLT4S", 3))
  expect_null(staged_r_type(out)$nodata)
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), rep("FLT4S", 3))
  expect_true(values_equal(r, x))
})

test_that("a file-backed INT4S source with small values stays INT4S", {
  # A-T5. Guard: the type of the source is kept, not narrowed (D-A2 rule 2).
  skip_if_not_installed("terra")
  file <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(sim_landcover(nrow = 12, ncol = 16), file, datatype = "INT4S")
  x <- terra::rast(file)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(staged_type(out), "INT4S")
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), "INT4S")
  expect_true(values_equal(r, x))
})

test_that("nodata comes from the argument, then a flag set in the session, then the source's tag", {
  # A-T6. Red: the source is widened to INT4S and no nodata is recorded; then
  # unused argument `nodata`.
  skip_if_not_installed("terra")
  cells <- landcover_with(-1L)
  cells[41] <- -1L
  file <- withr::local_tempfile(fileext = ".tif")
  x <- write_source(cells, file, datatype = "INT2S", tag = -1)
  expect_identical(nodata_tag(file), -1)
  expect_identical(sum(is.na(terra::values(x))), 2L)

  # the source's tag is kept and recorded
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(staged_type(out), "INT2S")
  expect_equal(staged_r_type(out)$nodata, -1)
  expect_identical(nodata_tag(out$staged), -1)
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), x))

  # a flag set in the session wins over the source's tag
  flagged <- terra::rast(file)
  terra::NAflag(flagged) <- 9
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(flagged, dir = dir)
  expect_identical(staged_type(out), "INT2S")
  expect_equal(staged_r_type(out)$nodata, 9)
  expect_identical(nodata_tag(out$staged), 9)
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), flagged))

  # the argument wins over both
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(flagged, dir = dir, nodata = 7)
  expect_equal(staged_r_type(out)$nodata, 7)
  expect_identical(nodata_tag(out$staged), 7)
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), flagged))
})

test_that("an explicit datatype is used, and values or nodata that do not fit abort", {
  # A-T7. Red: unused argument `datatype`.
  skip_if_not_installed("terra")
  doubles <- rcs_sim_raster(nrow = 12, ncol = 16)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(doubles, dir = dir, datatype = "FLT4S")
  expect_identical(staged_type(out), rep("FLT4S", 3))
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), rep("FLT4S", 3))
  expect_equal(unname(terra::values(r)), unname(terra::values(doubles)), tolerance = 1e-6)

  too_large <- landcover_with(300L)
  whole <- sim_landcover(nrow = 12, ncol = 16)
  # doubles with fractions inside the range of INT1U: only the "all integer"
  # rule of D-A4 refuses them
  fractions <- doubles[["moisture"]]
  limits <- as.vector(terra::minmax(fractions, compute = TRUE))
  expect_true(limits[[1]] > 0 && limits[[2]] < 1)
  expect_error(stage_sim_raster(too_large, datatype = "INT1U"), class = "rcs_error_raster")
  expect_error(stage_sim_raster(fractions, datatype = "INT1U"), class = "rcs_error_raster")
  expect_error(stage_sim_raster(whole + 0.5, datatype = "INT1U"), class = "rcs_error_raster")
  expect_error(stage_sim_raster(whole, datatype = "INT8S"), class = "rcs_error_argument")
  expect_error(stage_sim_raster(whole, datatype = 1L), class = "rcs_error_argument")
  expect_error(stage_sim_raster(whole, datatype = "INT1U", nodata = 300), class = "rcs_error_argument")
  expect_error(stage_sim_raster(whole, nodata = 0.5), class = "rcs_error_argument")
  expect_error(stage_sim_raster(whole, nodata = NA), class = "rcs_error_argument")
  expect_error(stage_sim_raster(whole, nodata = c(0, 1)), class = "rcs_error_argument")

  expect_snapshot(stage_sim_raster(too_large, datatype = "INT1U"), error = TRUE)
  expect_snapshot(stage_sim_raster(whole, datatype = "INT8S"), error = TRUE)
})

test_that("an explicit integer type gets its default nodata only when cells are missing", {
  # A-T8. Red: unused argument `datatype`.
  skip_if_not_installed("terra")
  with_missing <- zero_as_missing(sim_landcover(nrow = 12, ncol = 16))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(with_missing, dir = dir, datatype = "INT2S")
  expect_identical(staged_type(out), "INT2S")
  expect_equal(staged_r_type(out)$nodata, -32768)
  expect_identical(nodata_tag(out$staged), -32768)
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), with_missing))

  # a value equal to the default flag, with missing cells: no flag is free
  flag_taken <- with_missing
  flag_taken[40] <- 255L
  expect_error(stage_sim_raster(flag_taken, datatype = "INT1U"), class = "rcs_error_raster")

  # every value of the type in use and no missing cell: no nodata at all
  full <- sim_landcover(nrow = 16, ncol = 16)
  terra::values(full) <- 0:255
  expect_true(terra::is.int(full))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(full, dir = dir, datatype = "INT1U")
  expect_identical(staged_type(out), "INT1U")
  expect_null(staged_r_type(out)$nodata)
  expect_identical(nodata_tag(out$staged), NA_real_)
  r <- raster_open(be_new(dir), out$files$path)
  expect_false(anyNA(terra::values(r)))
  expect_true(values_equal(r, full))
})

test_that("the file is a DEFLATE COG in 512 blocks whose overviews hold class codes only", {
  # A-T9. Red: the compression is LZW and the overviews are resampled with
  # CUBIC (values between the codes), as 0.0.0.9004 writes them; the type is
  # Int32. Guards: `LAYOUT=COG`, `Block=512x512` and the presence of overviews.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 1100, ncol = 1100) * 40L
  names(x) <- "cover"
  expect_true(terra::is.int(x))
  codes <- seq(0, 200, by = 40)
  expect_setequal(unique(as.vector(terra::values(x))), codes)
  out <- stage_sim_raster(x)
  info <- gdal_info(out$staged)
  expect_info(info, "LAYOUT=COG")
  expect_info(info, "Block=512x512")
  expect_info(info, "Overviews: 550x550")
  expect_info(info, "Type=Byte")
  expect_info(info, "COMPRESSION=DEFLATE")
  expect_info(info, "PREDICTOR=2")
  expect_info(info, "OVERVIEW_RESAMPLING=NEAREST")
  overview <- terra::rast(out$staged, opts = "OVERVIEW_LEVEL=0")
  expect_equal(dim(overview)[1:2], c(550, 550))
  expect_in(unique(stats::na.omit(as.vector(terra::values(overview)))), codes)
})

test_that("gdal = replaces the defaults by key, whatever its order and case", {
  # A-T10. Red: unused argument `gdal`.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 600, ncol = 600)
  a <- stage_sim_raster(x, gdal = c("COMPRESS=LZW", "BLOCKSIZE=256"))
  info <- gdal_info(a$staged)
  expect_info(info, "COMPRESSION=LZW")
  expect_info(info, "Block=256x256")
  # the other defaults stay
  expect_info(info, "LAYOUT=COG")
  expect_info(info, "PREDICTOR=2")
  expect_info(info, "OVERVIEW_RESAMPLING=NEAREST")
  expect_info(info, "Type=Byte")
  # the order given does not change the file
  b <- stage_sim_raster(x, gdal = c("BLOCKSIZE=256", "COMPRESS=LZW"))
  expect_identical(b$files$md5, a$files$md5)
  expect_identical(b$entry$version, a$entry$version)
  # keys are compared in upper case
  upper <- stage_sim_raster(x, gdal = "BLOCKSIZE=256")
  lower <- stage_sim_raster(x, gdal = "blocksize=256")
  expect_info(gdal_info(lower$staged), "Block=256x256")
  expect_info(gdal_info(lower$staged), "COMPRESSION=DEFLATE")
  expect_identical(lower$files$md5, upper$files$md5)
  # and an option changes the bytes
  plain <- stage_sim_raster(x)
  expect_false(identical(plain$files$md5, upper$files$md5))

  small <- sim_landcover(nrow = 12, ncol = 16)
  expect_error(stage_sim_raster(small, gdal = "COMPRESS"), class = "rcs_error_argument")
  expect_error(stage_sim_raster(small, gdal = 1), class = "rcs_error_argument")
  expect_error(stage_sim_raster(small, gdal = NA_character_), class = "rcs_error_argument")
})

test_that("a categorical layer is stored as codes, with its legend in the entry", {
  # A-T11. Red: categorical layers abort ("Categorical layers cannot be
  # stored").
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16, legend = TRUE)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  # no side file (`.aux.xml`), no temp file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)

  r_type <- staged_r_type(out)
  expect_identical(r_type$class, "SpatRaster")
  expect_equal(r_type$values, 1:5)
  expect_identical(r_type$levels, sim_landcover_labels)
  expect_identical(r_type$levels_name, "label")
  expect_identical(staged_type(out), "INT1U")

  # the file is the one of the same map without its legend
  plain <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16))
  expect_identical(out$files$md5, plain$files$md5)
  expect_identical(out$entry$version, plain$entry$version)
  expect_null(staged_r_type(plain)$values)
  expect_false(identical(out$entry$columns, plain$entry$columns))

  # the legend survives the JSON of the entry with its types
  spec <- columns_from_json(out$entry$columns)
  again <- columns_from_json(columns_to_json(spec))
  expect_identical(again$r_type, spec$r_type)
  expect_true(is.numeric(r_type$values))
  expect_type(r_type$levels, "character")
  expect_type(r_type$levels_name, "character")
  # also a legend of one class: `values` and `levels` stay arrays
  one <- columns_spec(
    name = "cover", type = "INT1U",
    r_type = list(list(
      class = "SpatRaster", resolution = c(1, 1), dim = c(2L, 2L),
      values = 7, levels = "water", levels_name = "label"
    ))
  )
  json <- columns_to_json(one)
  expect_match(json, '"values":[7]', fixed = TRUE)
  expect_match(json, '"levels":["water"]', fixed = TRUE)
  expect_equal(columns_from_json(json)$r_type[[1]]$values, 7)

  # the caller's raster keeps its categories
  expect_true(terra::is.factor(x))
  expect_identical(as.character(terra::cats(x)[[1]]$label), sim_landcover_labels)
  expect_identical(names(x), "cover")
})

test_that("a legend with a missing label or a repeated code aborts", {
  # A-T12 (AM6). Red: the raster aborts today as well, with the same class,
  # for being categorical, so that expectation is a guard; the red reason is
  # `raster_legend_check()`, which does not exist yet.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16)
  levels(x) <- data.frame(value = 1:5, label = c("water", NA, "crop", "grass", "bare"))
  names(x) <- "cover"
  expect_error(stage_sim_raster(x), class = "rcs_error_raster")
  # terra refuses to build a raster with a repeated code: the check is called
  # with a table.
  expect_error(
    raster_legend_check(c(1, 1, 2), c("water", "forest", "crop"), "cover"),
    class = "rcs_error_raster"
  )
  expect_error(
    raster_legend_check(c(1, 2, 3), c("water", NA, "crop"), "cover"),
    class = "rcs_error_raster"
  )
  expect_no_error(raster_legend_check(c(1, 2, 3), c("water", "forest", "crop"), "cover"))
})

test_that("the active label column is the legend; the other columns are dropped with a message", {
  # A-T12. Red: categorical layers abort.
  skip_if_not_installed("terra")
  french <- c("eau", "foret", "culture", "herbe", "nu")
  x <- sim_landcover(nrow = 12, ncol = 16)
  # column names that do not contain each other, so that a message naming
  # one cannot be taken for the other
  levels(x) <- data.frame(value = 1:5, name_en = sim_landcover_labels, name_fr = french)
  names(x) <- "cover"
  staging_messages <- function(x) {
    seen <- character()
    withCallingHandlers(
      stage_sim_raster(x),
      message = function(m) {
        seen <<- c(seen, conditionMessage(m))
        invokeRestart("muffleMessage")
      }
    )
    seen
  }
  expect_message(out <- stage_sim_raster(x), "name_fr", fixed = TRUE)
  # one message, naming the dropped column and not the one kept
  said <- staging_messages(x)
  expect_length(said, 1L)
  expect_match(said, "name_fr", fixed = TRUE)
  expect_no_match(said, "name_en", fixed = TRUE)
  expect_identical(staged_r_type(out)$levels_name, "name_en")
  expect_identical(staged_r_type(out)$levels, sim_landcover_labels)
  expect_equal(staged_r_type(out)$values, 1:5)
  expect_snapshot(out <- stage_sim_raster(x))

  terra::activeCat(x) <- 2
  names(x) <- "cover"
  expect_message(out <- stage_sim_raster(x), "name_en", fixed = TRUE)
  said <- staging_messages(x)
  expect_length(said, 1L)
  expect_match(said, "name_en", fixed = TRUE)
  expect_no_match(said, "name_fr", fixed = TRUE)
  expect_identical(staged_r_type(out)$levels_name, "name_fr")
  expect_identical(staged_r_type(out)$levels, french)
  expect_equal(staged_r_type(out)$values, 1:5)
})

test_that("raster_open() restores the categories from the entry's columns", {
  # A-T13. Red: categorical layers abort at staging; then unused argument
  # `columns` of `raster_open()`.
  skip_if_not_installed("terra")
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  spec <- columns_from_json(out$entry$columns)
  be <- be_new(dir)
  before <- list.files(dir, recursive = TRUE, all.files = TRUE)

  r <- raster_open(be, out$files$path, columns = spec)
  expect_true(terra::is.factor(r))
  legend <- terra::cats(r)[[1]]
  expect_named(legend, c("value", "label"))
  expect_equal(legend$value, 1:5)
  expect_identical(as.character(legend$label), sim_landcover_labels)
  expect_identical(names(r), "cover")
  expect_identical(terra::datatype(r), "INT1U")
  expect_true(codes_equal(r, sim_landcover()))

  # a crop keeps the categories
  box <- sf::st_bbox(c(xmin = -27.1, ymin = 7.3, xmax = -26.5, ymax = 8.1), crs = sf::st_crs(4326))
  cropped <- raster_open(be, out$files$path, intersects = box, columns = spec)
  expect_lt(terra::ncell(cropped), terra::ncell(r))
  expect_true(terra::is.factor(cropped))
  expect_identical(as.character(terra::cats(cropped)[[1]]$label), sim_landcover_labels)
  expect_identical(names(cropped), "cover")
  expect_true(codes_equal(cropped, terra::crop(sim_landcover(), terra::ext(cropped))))

  # without the columns the raster holds codes
  codes <- raster_open(be, out$files$path)
  expect_false(terra::is.factor(codes))
  expect_true(values_equal(codes, sim_landcover()))

  # opening writes nothing next to the file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), before)
})

test_that("raster_open() restores the categories of the one categorical layer among several", {
  # A-T13. Red: categorical layers abort at staging.
  skip_if_not_installed("terra")
  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  x <- c(other[["height"]], sim_landcover(nrow = 12, ncol = 16, legend = TRUE), other[["moisture"]])
  expect_identical(names(x), c("height", "cover", "moisture"))
  expect_identical(terra::is.factor(x), c(FALSE, TRUE, FALSE))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  spec <- columns_from_json(out$entry$columns)
  expect_null(spec$r_type[[1]]$values)
  expect_equal(spec$r_type[[2]]$values, 1:5)
  expect_null(spec$r_type[[3]]$values)
  r <- raster_open(be_new(dir), out$files$path, columns = spec)
  expect_identical(names(r), names(x))
  expect_identical(terra::is.factor(r), c(FALSE, TRUE, FALSE))
  expect_identical(as.character(terra::cats(r)[[2]]$label), sim_landcover_labels)
  expect_true(codes_equal(r, x))
})

test_that("staging leaves no temp file and restores terra's temp folder, also after an abort", {
  # A-T14. Red: unused argument `datatype` (the staging that must abort with
  # `rcs_error_raster`). The expectations before it are guards: small rasters
  # get no intermediate file from terra.
  skip_if_not_installed("terra")
  terra_tempdir <- terra::terraOptions(print = FALSE)$tempdir
  spat_before <- spat_files()

  file_backed <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(file_backed, dir = dir)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_identical(terra::terraOptions(print = FALSE)$tempdir, terra_tempdir)

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(sim_landcover(), dir = dir)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_identical(terra::terraOptions(print = FALSE)$tempdir, terra_tempdir)

  dir <- withr::local_tempdir()
  expect_error(
    stage_sim_raster(landcover_with(300L), dir = dir, datatype = "INT1U"),
    class = "rcs_error_raster"
  )
  expect_identical(terra::terraOptions(print = FALSE)$tempdir, terra_tempdir)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), character())

  expect_identical(spat_files(), spat_before)
})

test_that("terra's temp folder lies below the staging folder while the file is written", {
  # A-T14 (AM4, D-A11). Red: `raster_write_terra()` does not exist yet (object
  # not found). Small rasters get no intermediate file from terra, so the
  # folder terra is given is recorded at the time of the write.
  skip_if_not_installed("terra")
  by_terra <- raster_write_terra
  full_path <- function(path) tolower(normalizePath(path, winslash = "/", mustWork = FALSE))
  seen <- character()
  existed <- logical()
  local_mocked_bindings(
    raster_write_terra = function(...) {
      folder <- terra::terraOptions(print = FALSE)$tempdir
      seen <<- c(seen, full_path(folder))
      existed <<- c(existed, dir.exists(folder))
      by_terra(...)
    }
  )
  before <- terra::terraOptions(print = FALSE)$tempdir
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16), dir = dir)

  expect_length(seen, 1L)
  expect_true(existed)
  # below the staging folder, so not R's `tempdir()`, terra's default
  expect_true(startsWith(seen, paste0(full_path(dir), "/")))
  expect_false(identical(seen, full_path(before)))
  expect_false(identical(seen, full_path(tempdir())))
  # restored, and removed with everything but the data file
  expect_identical(terra::terraOptions(print = FALSE)$tempdir, before)
  expect_false(dir.exists(seen))
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
})

test_that("the default options follow the type, are sorted by key, and gdal = replaces them by key", {
  # D-A5, AM1. Red: `raster_gdal_options()` does not exist yet.
  key_of <- function(options) toupper(sub("=.*$", "", options))
  value_of <- function(options, key) sub("^[^=]*=", "", options[key_of(options) == key])

  whole <- raster_gdal_options("INT1U", NULL)
  expect_setequal(whole, c(
    "BIGTIFF=IF_SAFER", "BLOCKSIZE=512", "COMPRESS=DEFLATE",
    "OVERVIEWS=IGNORE_EXISTING", "OVERVIEW_RESAMPLING=NEAREST", "PREDICTOR=2"
  ))
  for (type in c("INT2U", "INT2S", "INT4U", "INT4S")) {
    expect_identical(raster_gdal_options(type, NULL), whole, info = type)
  }
  for (type in c("FLT4S", "FLT8S")) {
    float <- raster_gdal_options(type, NULL)
    expect_setequal(float, c(
      "BIGTIFF=IF_SAFER", "BLOCKSIZE=512", "COMPRESS=DEFLATE",
      "OVERVIEWS=IGNORE_EXISTING", "OVERVIEW_RESAMPLING=AVERAGE", "PREDICTOR=3"
    ))
    expect_identical(key_of(float), sort(key_of(float), method = "radix"), info = type)
  }
  expect_identical(key_of(whole), sort(key_of(whole), method = "radix"))

  # a key given replaces the default of that key, in any case; others are added
  given <- raster_gdal_options("INT1U", c("zstd_level=9", "compress=ZSTD", "Predictor=1"))
  expect_setequal(
    key_of(given),
    c("BIGTIFF", "BLOCKSIZE", "COMPRESS", "OVERVIEWS", "OVERVIEW_RESAMPLING", "PREDICTOR", "ZSTD_LEVEL")
  )
  expect_identical(value_of(given, "COMPRESS"), "ZSTD")
  expect_identical(value_of(given, "PREDICTOR"), "1")
  expect_identical(value_of(given, "ZSTD_LEVEL"), "9")
  expect_identical(value_of(given, "BLOCKSIZE"), "512")
  expect_identical(value_of(given, "OVERVIEW_RESAMPLING"), "NEAREST")
  expect_identical(key_of(given), sort(key_of(given), method = "radix"))
  # the order given does not change the result
  expect_identical(
    raster_gdal_options("INT1U", c("Predictor=1", "compress=ZSTD", "zstd_level=9")),
    given
  )
})

test_that("a float raster is written with the floating-point predictor and averaged overviews", {
  # D-A5, AM1. Red: 0.0.0.9004 writes LZW without a predictor and resamples
  # the overviews with CUBIC. Guards: `LAYOUT=COG`, `Block=512x512`,
  # `Type=Float64`.
  skip_if_not_installed("terra")
  x <- rcs_sim_raster(nrow = 600, ncol = 600)
  out <- stage_sim_raster(x)
  info <- gdal_info(out$staged)
  expect_info(info, "LAYOUT=COG")
  expect_info(info, "Block=512x512")
  expect_info(info, "Type=Float64")
  expect_info(info, "Overviews: 300x300")
  expect_info(info, "COMPRESSION=DEFLATE")
  expect_info(info, "PREDICTOR=3")
  expect_info(info, "OVERVIEW_RESAMPLING=AVERAGE")
  expect_identical(staged_type(out), rep("FLT8S", 3))
  expect_true(values_equal(terra::rast(out$staged), x))
})

test_that("layers with different NoData tags or session flags need nodata =", {
  # D-A3 rules 2 and 3. Red: 0.0.0.9004 stages such a raster without an error
  # (`expect_error()` sees none); then unused argument `nodata`.
  skip_if_not_installed("terra")
  first <- landcover_with(-1L)
  names(first) <- "first"
  second <- sim_landcover(nrow = 12, ncol = 16, seed = 2)
  second[41] <- -2L
  names(second) <- "second"
  folder <- withr::local_tempdir()
  source_of <- function(x, name, tag = "none") {
    write_source(x, file.path(folder, name), datatype = "INT2S", tag = tag)
  }

  # two sources whose NoData tags differ (rule 3)
  tags <- c(source_of(first, "a.tif", tag = -1), source_of(second, "b.tif", tag = -2))
  expect_identical(names(tags), c("first", "second"))
  expect_identical(unname(colSums(is.na(terra::values(tags)))), c(1, 1))
  expect_error(stage_sim_raster(tags), class = "rcs_error_raster")
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(tags, dir = dir, nodata = -9)
  expect_identical(staged_type(out), rep("INT2S", 2))
  expect_identical(nodata_tag(out$staged), c(-9, -9))
  expect_equal(staged_r_type(out, 1)$nodata, -9)
  expect_equal(staged_r_type(out, 2)$nodata, -9)
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), tags))
  # the same tag in both sources is kept
  same <- c(source_of(first, "c.tif", tag = -1), source_of(second, "d.tif", tag = -1))
  out <- stage_sim_raster(same)
  expect_identical(nodata_tag(out$staged), c(-1, -1))

  # two sources without tags, with different flags set in the session (rule 2)
  flag_a <- source_of(first, "e.tif")
  flag_b <- source_of(second, "f.tif")
  terra::NAflag(flag_a) <- 9
  terra::NAflag(flag_b) <- 8
  flags <- c(flag_a, flag_b)
  expect_identical(terra::NAflag(flags), c(9, 8))
  expect_error(stage_sim_raster(flags), class = "rcs_error_raster")
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(flags, dir = dir, nodata = -9)
  expect_identical(nodata_tag(out$staged), c(-9, -9))
  expect_true(values_equal(raster_open(be_new(dir), out$files$path), flags))
})

test_that("staging a file-backed raster warns when the staging drive looks too small", {
  # A-T14. Red: `disk_free()` does not exist yet, so the mock fails.
  skip_if_not_installed("terra")
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"))
  dir <- withr::local_tempdir()
  local_mocked_bindings(disk_free = function(path) 1)
  expect_warning(out <- stage_sim_raster(x, dir = dir), class = "rcs_warning_staging_space")
  # it warns and still writes
  expect_true(file.exists(out$staged))
  expect_true(values_equal(terra::rast(out$staged), x))
  mask <- function(lines) {
    gsub(paste0("[^ '\"`]*", basename(dir), "[^ '\"`]*"), "<staging>", lines)
  }
  expect_snapshot(out <- stage_sim_raster(x, dir = dir), transform = mask)
  # no check for a raster in memory
  expect_no_warning(stage_sim_raster(sim_landcover(), dir = dir))
  # no warning when the free space is unknown
  local_mocked_bindings(disk_free = function(path) NA_real_)
  expect_no_warning(stage_sim_raster(x, dir = dir))
})

test_that("an unchanged view of one file is translated; everything else is written by terra", {
  # A-T15 (AM3). Red: `raster_write_translate()` and `raster_write_terra()` do
  # not exist yet (object not found).
  skip_if_not_installed("terra")
  translate <- raster_write_translate
  by_terra <- raster_write_terra
  calls <- character()
  local_mocked_bindings(
    raster_write_translate = function(...) {
      calls <<- c(calls, "translate")
      translate(...)
    },
    raster_write_terra = function(...) {
      calls <<- c(calls, "terra")
      by_terra(...)
    }
  )
  test_env <- environment()
  path_of <- function(x, ...) {
    calls <<- character()
    dir <- withr::local_tempdir(.local_envir = test_env)
    out <- stage_sim_raster(x, dir = dir, ...)
    list(calls = calls, out = out, r = terra::rast(out$staged), tag = nodata_tag(out$staged))
  }
  file <- withr::local_tempfile(fileext = ".tif")
  x <- sim_landcover(file = file)

  # the file as it is, also with a legend set on it
  view <- path_of(x, nodata = 0)
  expect_identical(view$calls, "translate")
  expect_identical(path_of(x)$calls, "translate")
  expect_identical(path_of(sim_landcover(file = file, legend = TRUE), nodata = 0)$calls, "translate")

  # in memory
  memory <- path_of(sim_landcover(), nodata = 0)
  expect_identical(memory$calls, "terra")
  # renamed
  renamed <- terra::rast(file)
  names(renamed) <- "landcover"
  expect_identical(path_of(renamed)$calls, "terra")
  # cropped
  cropped <- terra::crop(terra::rast(file), terra::ext(-28, -26, 7, 8))
  expect_identical(path_of(cropped)$calls, "terra")
  # one layer of a three-layer file
  three <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(rcs_sim_raster(nrow = 12, ncol = 16), three)
  expect_identical(path_of(terra::rast(three)[["cover"]])$calls, "terra")
  expect_identical(path_of(terra::rast(three))$calls, "translate")
  # a legend on a file whose layer has another name
  other_name <- sim_landcover()
  names(other_name) <- "lc"
  other_file <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(other_name, other_file, datatype = "INT1U")
  labelled <- terra::rast(other_file)
  levels(labelled) <- data.frame(value = 1:5, label = sim_landcover_labels)
  names(labelled) <- "cover"
  expect_identical(path_of(labelled)$calls, "terra")

  # both paths give the same raster
  expect_true(values_equal(view$r, memory$r))
  expect_identical(terra::datatype(view$r), "INT1U")
  expect_identical(terra::datatype(memory$r), "INT1U")
  expect_identical(view$tag, 0)
  expect_identical(memory$tag, 0)
  expect_identical(names(view$r), "cover")
  expect_identical(names(memory$r), "cover")
  expect_identical(staged_r_type(view$out), staged_r_type(memory$out))

  # AM3: a source whose NoData tag differs from the nodata chosen is written
  # by terra, and its missing cells stay missing
  tagged_file <- withr::local_tempfile(fileext = ".tif")
  tagged <- write_source(sim_landcover(), tagged_file, datatype = "INT1U", tag = 0)
  expect_identical(nodata_tag(tagged_file), 0)
  expect_identical(sum(is.na(terra::values(tagged))), 544L)
  other_flag <- path_of(tagged, nodata = 255)
  expect_identical(other_flag$calls, "terra")
  expect_identical(other_flag$tag, 255)
  expect_equal(staged_r_type(other_flag$out)$nodata, 255)
  expect_true(values_equal(other_flag$r, tagged))
  # the same tag (kept from the source, or given) is translated
  kept <- path_of(tagged)
  expect_identical(kept$calls, "translate")
  expect_identical(kept$tag, 0)
  expect_true(values_equal(kept$r, tagged))
  expect_identical(path_of(tagged, nodata = 0)$calls, "translate")
})

test_that("staging an in-memory class map twice gives the same file", {
  # A-T16 (b). Guard: deterministic today as well (as INT4S).
  skip_if_not_installed("terra")
  a <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16))
  b <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16))
  expect_identical(a$files$md5, b$files$md5)
  expect_identical(a$entry$version, b$entry$version)
})

test_that("staging is deterministic for every type, nodata and legend; another nodata is another version", {
  # A-T16 (a), (c). Red: unused argument `nodata`.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16, file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  a <- stage_sim_raster(x, nodata = 0)
  b <- stage_sim_raster(x, nodata = 0)
  expect_identical(staged_type(a), "INT1U")
  expect_identical(a$files$md5, b$files$md5)
  expect_identical(a$entry$version, b$entry$version)
  expect_identical(a$entry$columns, b$entry$columns)

  doubles <- rcs_sim_raster(nrow = 12, ncol = 16)
  a <- stage_sim_raster(doubles, datatype = "FLT4S")
  b <- stage_sim_raster(doubles, datatype = "FLT4S")
  expect_identical(staged_type(a), rep("FLT4S", 3))
  expect_identical(a$files$md5, b$files$md5)
  expect_identical(a$entry$version, b$entry$version)

  memory <- sim_landcover(nrow = 12, ncol = 16)
  zero <- stage_sim_raster(memory, nodata = 0)
  other <- stage_sim_raster(memory, nodata = 255)
  expect_false(identical(zero$files$md5, other$files$md5))
  expect_false(identical(zero$entry$version, other$entry$version))
})

# AM9: what the staged file must share with `x` when `x` is a view of a file --

# The class map as a file whose band has no description, as other software
# writes it: terra then names the layer after the file. The description is
# dropped by way of a VRT.
write_undescribed <- function(file, nrow = 12, ncol = 16) {
  folder <- withr::local_tempdir()
  described <- file.path(folder, "described.tif")
  sim_landcover(nrow = nrow, ncol = ncol, file = described)
  vrt <- file.path(folder, "plain.vrt")
  sf::gdal_utils("translate", described, vrt, options = c("-of", "VRT"), quiet = TRUE)
  lines <- readLines(vrt)
  writeLines(lines[!grepl("<Description>", lines, fixed = TRUE)], vrt)
  sf::gdal_utils("translate", vrt, file, options = c("-co", "COMPRESS=LZW"), quiet = TRUE)
  terra::rast(file)
}

# Counting wrappers around the two ways to write the file, as in A-T15. The
# returned function gives the paths taken since its last call.
local_write_paths <- function(frame = parent.frame()) {
  translate <- raster_write_translate
  by_terra <- raster_write_terra
  calls <- character()
  local_mocked_bindings(
    raster_write_translate = function(...) {
      calls <<- c(calls, "translate")
      translate(...)
    },
    raster_write_terra = function(...) {
      calls <<- c(calls, "terra")
      by_terra(...)
    },
    .env = frame
  )
  function() {
    taken <- calls
    calls <<- character()
    taken
  }
}

test_that("a source without band descriptions is staged with the names of x", {
  # AM9, names (MF1). Red: the file is copied by GDAL without a band
  # description, so the staged layer is named after the staged file
  # (`part-<version>`), not `cropmap_2020`. The path taken is not asserted.
  skip_if_not_installed("terra")
  folder <- withr::local_tempdir()
  file <- file.path(folder, "cropmap_2020.tif")
  x <- write_undescribed(file)
  expect_false(any(grepl("Description", gdal_info(file), fixed = TRUE)))
  expect_identical(names(x), "cropmap_2020")
  expect_identical(names(terra::rast(file)), "cropmap_2020")
  expect_identical(terra::datatype(x), "INT1U")

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  expect_identical(columns_from_json(out$entry$columns)$name, "cropmap_2020")
  expect_identical(staged_type(out), "INT1U")
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(names(r), names(x))
  expect_identical(terra::datatype(r), "INT1U")
  expect_identical(nodata_tag(out$staged), 0)
  expect_true(values_equal(r, zero_as_missing(sim_landcover(nrow = 12, ncol = 16))))

  # deterministic: the same file from another staging folder
  again <- stage_sim_raster(x, nodata = 0)
  expect_identical(again$files$md5, out$files$md5)
  expect_identical(again$entry$version, out$entry$version)

  # with a legend, the name set back to the one terra gave the layer
  labelled <- terra::rast(file)
  levels(labelled) <- data.frame(value = 1:5, label = sim_landcover_labels)
  names(labelled) <- "cropmap_2020"
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(labelled, dir = dir, nodata = 0)
  spec <- columns_from_json(out$entry$columns)
  expect_identical(spec$name, "cropmap_2020")
  r <- raster_open(be_new(dir), out$files$path, columns = spec)
  expect_identical(names(r), "cropmap_2020")
  expect_true(terra::is.factor(r))
  expect_identical(as.character(terra::cats(r)[[1]]$label), sim_landcover_labels)
  expect_true(codes_equal(r, zero_as_missing(sim_landcover(nrow = 12, ncol = 16))))
})

test_that("a CRS set in the session is the CRS of the staged file", {
  # AM9, CRS (MF2). Red: the raster counts as an unchanged view of its file,
  # so GDAL copies the file and it keeps the CRS of the source (EPSG:4326),
  # while the entry records the CRS of `x`.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  x <- sim_landcover(nrow = 12, ncol = 16, file = withr::local_tempfile(fileext = ".tif"))
  terra::crs(x) <- "EPSG:3857"
  expect_false(any(terra::inMemory(x)))
  expect_true(sf::st_crs(terra::crs(x)) == sf::st_crs(3857))

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(paths(), "terra")
  expect_true(sf::st_crs(out$entry$crs) == sf::st_crs(3857))
  r <- raster_open(be_new(dir), out$files$path)
  expect_true(sf::st_crs(terra::crs(r)) == sf::st_crs(terra::crs(x)))
  expect_true(sf::st_crs(terra::crs(r)) == sf::st_crs(out$entry$crs))
  expect_identical(as.vector(terra::ext(r)), as.vector(terra::ext(x)))
  expect_true(values_equal(r, x))
})

test_that("a scale and offset set in the session are applied to the values written", {
  # AM9, scale and offset (MF3 a). Red: GDAL copies the file, so it reads
  # back with the stored codes 0-5, not the 1-11 that `x` reads.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  x <- sim_landcover(nrow = 12, ncol = 16, file = withr::local_tempfile(fileext = ".tif"))
  terra::scoff(x) <- cbind(2, 1)
  expect_false(any(terra::inMemory(x)))
  expect_equal(range(terra::values(x)), c(1, 11))

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(paths(), "terra")
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(names(r), "cover")
  expect_equal(as.vector(terra::values(r)), as.vector(terra::values(x)))
})

test_that("a source with a scale and offset is staged with the values x reads", {
  # AM9, scale and offset (MF3 b). Red: GDAL copies the file (the path is
  # "translate") and the entry records `INT1U`, the type of the stored codes,
  # for a raster that reads fractions. The values themselves already read
  # back equal today, because GDAL copies the scale and offset too: a guard.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  folder <- withr::local_tempdir()
  plain <- file.path(folder, "plain.tif")
  sim_landcover(nrow = 12, ncol = 16, file = plain)
  scaled <- file.path(folder, "scaled.tif")
  sf::gdal_utils(
    "translate", plain, scaled,
    options = c("-a_scale", "0.1", "-a_offset", "0.05", "-co", "COMPRESS=LZW"), quiet = TRUE
  )
  x <- terra::rast(scaled)
  expect_equal(as.vector(terra::scoff(x)), c(0.1, 0.05))
  expect_equal(range(terra::values(x)), c(0.05, 0.55))

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(paths(), "terra")
  expect_identical(staged_type(out), "FLT8S")
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(terra::datatype(r), "FLT8S")
  expect_equal(as.vector(terra::values(r)), as.vector(terra::values(x)))
})

test_that("a scaled source opened raw is staged with its raw values", {
  # AM9, scale and offset (MF3 c). Red: GDAL copies the file with its scale
  # and offset, so it reads back as 0.05-0.55, not the 0-5 that `x` reads.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  folder <- withr::local_tempdir()
  plain <- file.path(folder, "plain.tif")
  sim_landcover(nrow = 12, ncol = 16, file = plain)
  scaled <- file.path(folder, "scaled.tif")
  sf::gdal_utils(
    "translate", plain, scaled,
    options = c("-a_scale", "0.1", "-a_offset", "0.05", "-co", "COMPRESS=LZW"), quiet = TRUE
  )
  x <- terra::rast(scaled, raw = TRUE)
  expect_false(any(terra::inMemory(x)))
  expect_equal(range(terra::values(x)), c(0, 5))

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(paths(), "terra")
  expect_identical(staged_type(out), "INT1U")
  r <- raster_open(be_new(dir), out$files$path)
  expect_equal(as.vector(terra::scoff(r)), c(1, 0))
  expect_equal(as.vector(terra::values(r)), as.vector(terra::values(x)))
  expect_true(values_equal(r, sim_landcover(nrow = 12, ncol = 16)))
})

# AM10: side files, mask bands, scaled tags, source overviews -----------------

test_that("layers with time or units are staged as one file", {
  # AM10, side files. Red: terra writes `part.tif.aux.json` for a raster with
  # time or units, and staging aborts with the internal error "Staging a
  # raster must leave one file, not part.tif and part.tif.aux.json."
  skip_if_not_installed("terra")
  expect_one_file <- function(x) {
    dir <- withr::local_tempdir()
    out <- stage_sim_raster(x, dir = dir)
    expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
    r <- raster_open(be_new(dir), out$files$path)
    expect_identical(names(r), names(x))
    expect_true(values_equal(r, x))
    out
  }
  # AM11: time and units are not stored, so the file is the one of the same
  # raster without them
  expect_same_file <- function(out, plain) {
    reference <- stage_sim_raster(plain)
    expect_identical(out$files$md5, reference$files$md5)
    expect_identical(out$entry$version, reference$entry$version)
  }
  dates <- as.Date("2020-01-01") + 0:2
  units <- c("m", "class", "share")

  timed <- rcs_sim_raster(nrow = 12, ncol = 16)
  terra::time(timed) <- dates
  out <- expect_one_file(timed)
  expect_same_file(out, rcs_sim_raster(nrow = 12, ncol = 16))
  # the caller's raster keeps its time
  expect_identical(terra::time(timed), dates)

  with_units <- rcs_sim_raster(nrow = 12, ncol = 16)
  terra::units(with_units) <- units
  out <- expect_one_file(with_units)
  expect_same_file(out, rcs_sim_raster(nrow = 12, ncol = 16))
  expect_identical(terra::units(with_units), units)

  # a renamed view of a file, which terra writes
  file <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(rcs_sim_raster(nrow = 12, ncol = 16), file)
  view <- terra::rast(file)
  names(view) <- c("first", "second", "third")
  terra::time(view) <- dates
  expect_false(any(terra::inMemory(view)))
  out <- expect_one_file(view)
  renamed <- terra::rast(file)
  names(renamed) <- c("first", "second", "third")
  expect_same_file(out, renamed)
  expect_identical(terra::time(view), dates)
})

test_that("a file view whose source has a side file with categories is staged as one file", {
  # AM10, side files (mutation gap of WP3-V round 3). Green against the code
  # of AM10 / AM11. GDAL copies the file (translate path) and writes
  # `part.tif.aux.xml` from the source's side file; without its removal
  # staging aborts on the one-file assertion.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  folder <- withr::local_tempdir()
  file <- file.path(folder, "classes.tif")
  terra::writeRaster(sim_landcover(nrow = 12, ncol = 16, legend = TRUE), file, datatype = "INT1U")
  expect_true(file.exists(paste0(file, ".aux.xml")))
  x <- terra::rast(file)
  expect_true(terra::is.factor(x))
  expect_identical(names(x), "cover")
  expect_identical(as.character(terra::cats(x)[[1]][[2]]), sim_landcover_labels)
  before <- list.files(folder, recursive = TRUE, all.files = TRUE)
  before_md5 <- md5_file(file.path(folder, before))

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(paths(), "translate")
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  r_type <- staged_r_type(out)
  expect_equal(r_type$values, 1:5)
  expect_identical(r_type$levels, sim_landcover_labels)
  expect_identical(staged_type(out), "INT1U")

  # the file holds codes; the legend comes back from the entry's columns
  be <- be_new(dir)
  codes <- raster_open(be, out$files$path)
  expect_false(terra::is.factor(codes))
  expect_true(codes_equal(codes, x))
  r <- raster_open(be, out$files$path, columns = columns_from_json(out$entry$columns))
  expect_true(terra::is.factor(r))
  expect_identical(names(r), "cover")
  expect_true(codes_equal(r, x))
  expect_true(codes_equal(r, sim_landcover(nrow = 12, ncol = 16)))
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)

  # the source and its side file are as they were
  expect_identical(list.files(folder, recursive = TRUE, all.files = TRUE), before)
  expect_identical(md5_file(file.path(folder, before)), before_md5)
  expect_true(terra::is.factor(x))
})

test_that("a source with a mask band and no band description is staged with the names of x", {
  # AM10, VRT bands. Red: internal error "A VRT of 1 band was expected, not
  # of 2." (the mask band is counted as a band). The path taken is not
  # asserted.
  skip_if_not_installed("terra")
  folder <- withr::local_tempdir()
  described <- file.path(folder, "described.tif")
  sim_landcover(nrow = 12, ncol = 16, file = described)
  vrt <- file.path(folder, "plain.vrt")
  sf::gdal_utils("translate", described, vrt, options = c("-of", "VRT"), quiet = TRUE)
  lines <- readLines(vrt)
  writeLines(lines[!grepl("<Description>", lines, fixed = TRUE)], vrt)
  file <- file.path(folder, "masked_2020.tif")
  sf::gdal_utils(
    "translate", vrt, file,
    options = c("-mask", "1", "-co", "COMPRESS=LZW"),
    config_options = c(GDAL_TIFF_INTERNAL_MASK = "YES"), quiet = TRUE
  )
  info <- gdal_info(file)
  expect_info(info, "Mask Flags: PER_DATASET")
  expect_false(any(grepl("Description", info, fixed = TRUE)))
  expect_false(file.exists(paste0(file, ".msk")))
  x <- terra::rast(file)
  expect_identical(names(x), "masked_2020")
  expect_identical(terra::datatype(x), "INT1U")
  expected <- as.vector(terra::values(x))
  expected[expected == 0] <- NA

  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_identical(columns_from_json(out$entry$columns)$name, "masked_2020")
  expect_identical(staged_type(out), "INT1U")
  r <- raster_open(be_new(dir), out$files$path)
  expect_identical(names(r), names(x))
  expect_identical(terra::datatype(r), "INT1U")
  got <- as.vector(terra::values(r))
  expect_identical(is.na(got), is.na(expected))
  expect_equal(got, expected)
})

test_that("the source's NoData tag is not taken for a layer with a scale or offset", {
  # AM10, source tag of a scaled layer. Red: the tag 0, which is in stored
  # units, is recorded as nodata (`r_type$nodata` is 0) and written, so the
  # valid cells that read 0 come back missing.
  skip_if_not_installed("terra")
  folder <- withr::local_tempdir()
  plain <- file.path(folder, "plain.tif")
  sim_landcover(nrow = 12, ncol = 16, file = plain)
  expect_reads_as_x <- function(x) {
    values <- as.vector(terra::values(x))
    # the setup: missing cells, and valid cells that read 0
    expect_true(anyNA(values))
    expect_true(any(values == 0, na.rm = TRUE))
    dir <- withr::local_tempdir()
    out <- stage_sim_raster(x, dir = dir)
    expect_false(isTRUE(staged_r_type(out)$nodata == 0))
    got <- as.vector(terra::values(raster_open(be_new(dir), out$files$path)))
    expect_identical(is.na(got), is.na(values))
    expect_equal(got, values)
    expect_identical(sum(got == 0, na.rm = TRUE), sum(values == 0, na.rm = TRUE))
  }

  # a source with the tag 0 and a scale and offset: stored 1 reads 0
  scaled <- file.path(folder, "scaled.tif")
  sf::gdal_utils(
    "translate", plain, scaled,
    options = c("-a_nodata", "0", "-a_scale", "0.5", "-a_offset", "-0.5", "-co", "COMPRESS=LZW"),
    quiet = TRUE
  )
  expect_identical(nodata_tag(scaled), 0)
  expect_reads_as_x(terra::rast(scaled))

  # a source with the tag 0, and an offset set in the session
  tagged <- file.path(folder, "tagged.tif")
  sf::gdal_utils(
    "translate", plain, tagged,
    options = c("-a_nodata", "0", "-co", "COMPRESS=LZW"), quiet = TRUE
  )
  shifted <- terra::rast(tagged)
  terra::scoff(shifted) <- cbind(1, -1)
  expect_false(any(terra::inMemory(shifted)))
  expect_reads_as_x(shifted)
})

test_that("the overviews of the source are not copied", {
  # AM10, source overviews. Red: GDAL copies the AVERAGE overviews of the
  # source, so the staged overview holds values between the class codes, the
  # file differs from the one staged from a source without overviews, and
  # `OVERVIEWS=IGNORE_EXISTING` is not among the default options.
  skip_if_not_installed("terra")
  paths <- local_write_paths()
  codes <- seq(0, 200, by = 40)
  map <- sim_landcover(nrow = 1100, ncol = 1100) * 40L
  names(map) <- "cover"
  # the same cells under the same file name in two folders
  source_in <- function(folder) {
    file <- file.path(folder, "map.tif")
    tmp <- withr::local_tempfile(fileext = ".tif")
    terra::writeRaster(map, tmp, datatype = "INT1U", gdal = "COMPRESS=LZW")
    sf::gdal_utils(
      "translate", tmp, file,
      options = c("-a_nodata", "none", "-co", "COMPRESS=LZW"), quiet = TRUE
    )
    file
  }
  plain <- source_in(withr::local_tempdir())
  averaged <- source_in(withr::local_tempdir())
  expect_identical(md5_file(averaged), md5_file(plain))
  # `gdal_addo()` prints its progress
  utils::capture.output(sf::gdal_addo(averaged, overviews = c(2L, 4L), method = "AVERAGE"))
  expect_info(gdal_info(averaged), "Overviews: 550x550, 275x275")
  expect_false(any(grepl("Overviews", gdal_info(plain), fixed = TRUE)))
  source_overview <- terra::rast(averaged, opts = "OVERVIEW_LEVEL=0")
  expect_false(all(unique(as.vector(terra::values(source_overview))) %in% codes))

  expect_true("OVERVIEWS=IGNORE_EXISTING" %in% raster_gdal_options("INT1U", NULL))

  out <- stage_sim_raster(terra::rast(averaged), nodata = 0)
  expect_identical(paths(), "translate")
  info <- gdal_info(out$staged)
  expect_info(info, "Overviews: 550x550")
  expect_info(info, "OVERVIEW_RESAMPLING=NEAREST")
  overview <- terra::rast(out$staged, opts = "OVERVIEW_LEVEL=0")
  expect_equal(dim(overview)[1:2], c(550, 550))
  expect_in(unique(stats::na.omit(as.vector(terra::values(overview)))), codes[codes != 0])
  expect_true(values_equal(terra::rast(out$staged), zero_as_missing(map)))

  # the file of the same cells staged from the source without overviews
  reference <- stage_sim_raster(terra::rast(plain), nodata = 0)
  expect_identical(paths(), "translate")
  expect_identical(out$files$md5, reference$files$md5)
  expect_identical(out$entry$version, reference$entry$version)
})

# Plan 0006, part C: legend colours ---------------------------------------------
#
# Decisions D-C1 to D-C7. Each test states why it fails before the code of
# part C exists ("Red"); expectations that hold already are marked "guard".
# Facts these tests rest on (terra 1.9.50, GDAL 3.12.1):
#   * a colour table set in the session has one row per code given; one read
#     from a GeoTIFF has 256 rows (codes 0-255, the codes without a colour
#     black), so colours are compared per code, never as whole tables;
#   * `terra::coltab(x) <- NULL` removes the colours of the first layer only.

# The colours of a layer as `#RRGGBBAA` (upper case), named by code and sorted
# by code; `NULL` for a layer without a colour table. Read with terra alone,
# so that the tests do not depend on the package's own reader.
color_hex <- function(x, layer = 1L) {
  table <- terra::coltab(x)[[layer]]
  if (is.null(table)) {
    return(NULL)
  }
  hex <- toupper(grDevices::rgb(
    table[[2]], table[[3]], table[[4]], table[[5]],
    maxColorValue = 255
  ))
  stats::setNames(hex, table[[1]])[order(table[[1]])]
}

expect_colors <- function(r, codes = 1:5, colors = sim_landcover_colors, layer = 1L) {
  expect_true(terra::has.colors(r)[[layer]])
  expect_identical(unname(color_hex(r, layer)[as.character(codes)]), colors)
}

# `TRUE` when GDAL reports a colour table in a file.
has_color_table <- function(file) {
  any(grepl("Color Table|ColorInterp=Palette", gdal_info(file)))
}

# A small class map as a plain stripped LZW `INT1U` GeoTIFF without a NoData
# tag, as `sim_landcover(file = )` writes it, whose file itself holds a colour
# table for the classes 1-5 (`colors = TRUE`) or none. A TIFF colour table has
# no transparency: every colour reads back opaque.
write_color_source <- function(file, colors = TRUE) {
  tmp <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(
    sim_landcover(nrow = 12, ncol = 16, colors = colors), tmp,
    datatype = "INT1U", gdal = "COMPRESS=LZW"
  )
  sf::gdal_utils(
    "translate", tmp, file,
    options = c("-a_nodata", "none", "-co", "COMPRESS=LZW"), quiet = TRUE
  )
  terra::rast(file)
}

test_that("sim_landcover(colors = TRUE) sets a colour table and changes nothing else", {
  # Guard for the helper: the tests below rest on it.
  skip_if_not_installed("terra")
  plain <- sim_landcover(nrow = 12, ncol = 16)
  x <- sim_landcover(nrow = 12, ncol = 16, colors = TRUE)
  expect_false(terra::has.colors(plain))
  expect_true(terra::has.colors(x))
  expect_false(terra::is.factor(x))
  expect_identical(names(x), "cover")
  expect_true(values_equal(x, plain))
  expect_identical(color_hex(x), stats::setNames(sim_landcover_colors, 1:5))
  both <- sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE)
  expect_true(terra::is.factor(both))
  expect_identical(as.character(terra::cats(both)[[1]]$label), sim_landcover_labels)
  expect_identical(names(both), "cover")
  expect_colors(both)
  # with `file`, the colours are set in the session: the file holds none
  file <- withr::local_tempfile(fileext = ".tif")
  backed <- sim_landcover(nrow = 12, ncol = 16, file = file, legend = TRUE, colors = TRUE)
  expect_false(any(terra::inMemory(backed)))
  expect_colors(backed)
  expect_true(terra::is.factor(backed))
  expect_false(has_color_table(file))
  expect_false(terra::has.colors(terra::rast(file)))
})

test_that("raster_colors() gives the colour table of each layer as sorted codes and upper-case hex", {
  # D-C1, D-C5. Red: could not find function "raster_colors".
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16)
  # rows given in another order, colours in lower case
  terra::coltab(x, layer = 1) <- data.frame(value = 5:1, col = tolower(rev(sim_landcover_colors)))
  got <- raster_colors(x)
  expect_length(got, 1L)
  expect_named(got[[1]], c("color_values", "colors"))
  expect_true(is.numeric(got[[1]]$color_values))
  expect_equal(got[[1]]$color_values, 1:5)
  expect_type(got[[1]]$colors, "character")
  expect_identical(got[[1]]$colors, sim_landcover_colors)

  # a layer without a colour table has `NULL`
  expect_null(raster_colors(sim_landcover(nrow = 12, ncol = 16))[[1]])
  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  several <- c(other[["height"]], sim_landcover(nrow = 12, ncol = 16, colors = TRUE), other[["moisture"]])
  expect_identical(terra::has.colors(several), c(FALSE, TRUE, FALSE))
  got <- raster_colors(several)
  expect_null(got[[1]])
  expect_equal(got[[2]]$color_values, 1:5)
  expect_identical(got[[2]]$colors, sim_landcover_colors)
  expect_null(got[[3]])
})

test_that("raster_drop_colors() gives a copy without colours and leaves x, its levels and names alone", {
  # D-C3, D-C5. Red: could not find function "raster_drop_colors".
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE)
  out <- raster_drop_colors(x)
  expect_false(terra::has.colors(out))
  expect_true(terra::is.factor(out))
  expect_identical(as.character(terra::cats(out)[[1]]$label), sim_landcover_labels)
  expect_identical(names(out), "cover")
  expect_true(codes_equal(out, x))
  # the caller's raster keeps its colours
  expect_colors(x)

  # every layer, not only the first (`coltab(x) <- NULL` clears layer 1 only)
  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  several <- c(other[["height"]], sim_landcover(nrow = 12, ncol = 16, colors = TRUE), other[["moisture"]])
  out <- raster_drop_colors(several)
  expect_identical(terra::has.colors(out), c(FALSE, FALSE, FALSE))
  expect_identical(names(out), names(several))
  expect_identical(terra::has.colors(several), c(FALSE, TRUE, FALSE))

  # file-backed: no cells are read, the source file stays as it is
  folder <- withr::local_tempdir()
  file <- file.path(folder, "map.tif")
  backed <- write_color_source(file)
  expect_true(terra::has.colors(backed))
  md5 <- md5_file(file)
  out <- raster_drop_colors(backed)
  expect_false(terra::has.colors(out))
  expect_false(any(terra::inMemory(out)))
  expect_true(terra::has.colors(backed))
  expect_identical(list.files(folder, all.files = TRUE, no.. = TRUE), "map.tif")
  expect_identical(md5_file(file), md5)

  # a raster without colours comes back as it is
  plain <- sim_landcover(nrow = 12, ncol = 16)
  expect_true(values_equal(raster_drop_colors(plain), plain))
})

test_that("a class map with a legend and colours round-trips through stage and open", {
  # D-C1, D-C2, D-C4. Red: the entry's `r_type` has no `color_values` and no
  # `colors`; the staged TIFF holds a colour table (`ColorInterp=Palette`),
  # so the raster opened without the columns has colours.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  # one file: no side file (`.aux.xml`, `.aux.json`), no temp file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_false(has_color_table(out$staged))

  r_type <- staged_r_type(out)
  expect_equal(r_type$values, 1:5)
  expect_identical(r_type$levels, sim_landcover_labels)
  expect_true(is.numeric(r_type$color_values))
  expect_equal(r_type$color_values, 1:5)
  expect_type(r_type$colors, "character")
  expect_identical(r_type$colors, sim_landcover_colors)
  expect_true(all(grepl("^#[0-9A-F]{8}$", r_type$colors)))
  # the fields survive the JSON of the entry with their types
  spec <- columns_from_json(out$entry$columns)
  expect_identical(columns_from_json(columns_to_json(spec))$r_type, spec$r_type)

  be <- be_new(dir)
  r <- raster_open(be, out$files$path, columns = spec)
  expect_identical(names(r), "cover")
  expect_true(terra::is.factor(r))
  legend <- terra::cats(r)[[1]]
  expect_equal(legend$value, 1:5)
  expect_identical(as.character(legend$label), sim_landcover_labels)
  expect_colors(r)
  expect_identical(terra::datatype(r), "INT1U")
  expect_true(codes_equal(r, x))

  # the colours come from the entry, not from the file
  codes <- raster_open(be, out$files$path)
  expect_false(terra::has.colors(codes))
  expect_false(terra::is.factor(codes))
  # opening writes nothing next to the file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)

  # the caller's raster keeps its colours and categories
  expect_colors(x)
  expect_true(terra::is.factor(x))
  expect_identical(names(x), "cover")
})

test_that("with a legend, only the colours of the legend's codes are stored", {
  # D-C2. Red: `r_type` has no `color_values` and no `colors`.
  skip_if_not_installed("terra")
  # colours for two of the five classes
  x <- sim_landcover(nrow = 12, ncol = 16, legend = TRUE)
  terra::coltab(x, layer = 1) <- data.frame(value = c(4, 2), col = sim_landcover_colors[c(4, 2)])
  names(x) <- "cover"
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  r_type <- staged_r_type(out)
  expect_equal(r_type$values, 1:5)
  expect_equal(r_type$color_values, c(2, 4))
  expect_identical(r_type$colors, sim_landcover_colors[c(2, 4)])
  r <- raster_open(be_new(dir), out$files$path, columns = columns_from_json(out$entry$columns))
  expect_colors(r, codes = c(2, 4), colors = sim_landcover_colors[c(2, 4)])
  expect_identical(as.character(terra::cats(r)[[1]]$label), sim_landcover_labels)

  # a colour table with more codes than the legend: that of a file, which has
  # a row for each of the codes 0-255
  file <- file.path(withr::local_tempdir(), "map.tif")
  backed <- write_color_source(file)
  levels(backed) <- data.frame(value = 1:5, label = sim_landcover_labels)
  names(backed) <- "cover"
  expect_true(terra::has.colors(backed))
  expect_identical(nrow(terra::coltab(backed)[[1]]), 256L)
  out <- stage_sim_raster(backed, nodata = 0)
  r_type <- staged_r_type(out)
  expect_equal(r_type$color_values, 1:5)
  expect_identical(r_type$colors, unname(color_hex(backed)[as.character(1:5)]))
  # a TIFF colour table is opaque
  expect_identical(r_type$colors, paste0(substr(sim_landcover_colors, 1, 7), "FF"))
})

test_that("colours without a legend are stored for every row of the colour table and restored", {
  # D-C2, D-C4. Red: `r_type` has no `color_values` and no `colors`; the
  # staged TIFF holds the colour table.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16, colors = TRUE)
  expect_false(terra::is.factor(x))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_false(has_color_table(out$staged))
  r_type <- staged_r_type(out)
  expect_null(r_type$values)
  expect_null(r_type$levels)
  expect_equal(r_type$color_values, 1:5)
  expect_identical(r_type$colors, sim_landcover_colors)

  spec <- columns_from_json(out$entry$columns)
  r <- raster_open(be_new(dir), out$files$path, columns = spec)
  expect_false(terra::is.factor(r))
  expect_identical(names(r), "cover")
  expect_colors(r)
  expect_true(values_equal(r, x))
  expect_false(terra::has.colors(raster_open(be_new(dir), out$files$path)))
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
})

test_that("a layer without a colour table gets neither field; one coloured layer among several keeps its colours", {
  # D-C2, D-C4. Guard: the plain raster has neither field. Red: layer 2 of
  # the three-layer raster has no `color_values` and no `colors`, and the
  # opened raster has no colours.
  skip_if_not_installed("terra")
  plain <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16, legend = TRUE))
  expect_null(staged_r_type(plain)$color_values)
  expect_null(staged_r_type(plain)$colors)
  expect_no_match(plain$entry$columns, "color", fixed = TRUE)

  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  x <- c(
    other[["height"]],
    sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE),
    other[["moisture"]]
  )
  expect_identical(names(x), c("height", "cover", "moisture"))
  expect_identical(terra::has.colors(x), c(FALSE, TRUE, FALSE))
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir)
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)
  expect_false(has_color_table(out$staged))
  spec <- columns_from_json(out$entry$columns)
  expect_null(spec$r_type[[1]]$color_values)
  expect_null(spec$r_type[[1]]$colors)
  expect_equal(spec$r_type[[2]]$color_values, 1:5)
  expect_identical(spec$r_type[[2]]$colors, sim_landcover_colors)
  expect_equal(spec$r_type[[2]]$values, 1:5)
  expect_null(spec$r_type[[3]]$color_values)
  expect_null(spec$r_type[[3]]$colors)

  r <- raster_open(be_new(dir), out$files$path, columns = spec)
  expect_identical(names(r), names(x))
  expect_identical(terra::has.colors(r), c(FALSE, TRUE, FALSE))
  expect_identical(terra::is.factor(r), c(FALSE, TRUE, FALSE))
  expect_colors(r, layer = 2L)
  expect_true(codes_equal(r, x))
  # the same file as without the colours
  bare <- c(other[["height"]], sim_landcover(nrow = 12, ncol = 16, legend = TRUE), other[["moisture"]])
  expect_identical(out$files$md5, stage_sim_raster(bare)$files$md5)
})

test_that("in memory, the same cells with and without colours give the same file", {
  # D-C3. Red: terra writes the colour table into the TIFF, so the MD5 and
  # the version differ and gdalinfo shows `ColorInterp=Palette` and a
  # "Color Table".
  skip_if_not_installed("terra")
  dir <- withr::local_tempdir()
  colored <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16, colors = TRUE), dir = dir)
  plain <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16))
  expect_identical(colored$files$md5, plain$files$md5)
  expect_identical(colored$entry$version, plain$entry$version)
  expect_false(has_color_table(colored$staged))
  expect_info(gdal_info(colored$staged), "ColorInterp=Gray")
  # no side file in the staging folder
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), colored$files$path)
  expect_length(list.files(dir, pattern = "\\.aux\\.(xml|json)$", recursive = TRUE, all.files = TRUE), 0L)
  # only the entries differ
  expect_false(identical(colored$entry$columns, plain$entry$columns))

  # also with a legend, and whatever the colours are
  both <- stage_sim_raster(sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE))
  expect_identical(both$files$md5, plain$files$md5)
  other <- sim_landcover(nrow = 12, ncol = 16)
  terra::coltab(other, layer = 1) <- data.frame(value = 1:5, col = rev(sim_landcover_colors))
  names(other) <- "cover"
  recolored <- stage_sim_raster(other)
  expect_identical(recolored$files$md5, plain$files$md5)
  expect_identical(staged_r_type(recolored)$colors, rev(sim_landcover_colors))
})

test_that("a source file with a colour table gives the same file as the same cells without one", {
  # D-C3. Red: GDAL copies the colour table of the source (translate path),
  # so the MD5 and the version differ from those of the file without one and
  # the staged TIFF holds a "Color Table"; `r_type` has no `color_values`.
  # The path taken (GDAL copy or terra) is not asserted: D-C3 leaves it to
  # the code.
  skip_if_not_installed("terra")
  # the same cells under the same file name in two folders
  with_table <- file.path(withr::local_tempdir(), "map.tif")
  without <- file.path(withr::local_tempdir(), "map.tif")
  x <- write_color_source(with_table)
  y <- write_color_source(without, colors = FALSE)
  expect_true(has_color_table(with_table))
  expect_false(has_color_table(without))
  expect_true(terra::has.colors(x))
  expect_false(terra::has.colors(y))
  expect_false(any(terra::inMemory(x)))
  expect_true(values_equal(x, y))
  source_md5 <- md5_file(with_table)
  source_colors <- color_hex(x)

  dir <- withr::local_tempdir()
  colored <- stage_sim_raster(x, dir = dir, nodata = 0)
  plain <- stage_sim_raster(y, nodata = 0)
  expect_identical(colored$files$md5, plain$files$md5)
  expect_identical(colored$entry$version, plain$entry$version)
  expect_false(has_color_table(colored$staged))
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), colored$files$path)
  expect_length(list.files(dir, pattern = "\\.aux\\.(xml|json)$", recursive = TRUE, all.files = TRUE), 0L)
  expect_identical(staged_type(colored), "INT1U")
  expect_identical(nodata_tag(colored$staged), 0)
  # deterministic: the same file from another staging folder
  expect_identical(stage_sim_raster(x, nodata = 0)$files$md5, colored$files$md5)

  # without a legend, every row of the file's colour table is stored: the
  # codes 0-255
  r_type <- staged_r_type(colored)
  expect_equal(r_type$color_values, 0:255)
  expect_identical(r_type$colors, unname(source_colors))
  expect_identical(r_type$colors[2:6], paste0(substr(sim_landcover_colors, 1, 7), "FF"))
  expect_null(staged_r_type(plain)$color_values)

  # read back: the values of the source, its colours from the entry
  be <- be_new(dir)
  r <- raster_open(be, colored$files$path, columns = columns_from_json(colored$entry$columns))
  expect_true(values_equal(r, zero_as_missing(sim_landcover(nrow = 12, ncol = 16))))
  expect_identical(names(r), "cover")
  expect_identical(color_hex(r), source_colors)
  expect_false(terra::has.colors(raster_open(be, colored$files$path)))

  # the source is as it was
  expect_identical(md5_file(with_table), source_md5)
  expect_identical(list.files(dirname(with_table), all.files = TRUE, no.. = TRUE), "map.tif")
  expect_true(terra::has.colors(x))
})

test_that("the colour fields of one colour stay arrays in the JSON of the entry", {
  # D-C1. Red: `color_values` and `colors` of length one are written as
  # scalars (`"color_values":7`), not as arrays: the two fields are not in
  # the field lists of `columns_to_json()` / `columns_from_json()`.
  one <- columns_spec(
    name = "cover", type = "INT1U",
    r_type = list(list(
      class = "SpatRaster", resolution = c(1, 1), dim = c(2L, 2L),
      values = 7, levels = "water", levels_name = "label",
      color_values = 7, colors = "#1F78B4FF"
    ))
  )
  json <- columns_to_json(one)
  expect_match(json, '"color_values":[7]', fixed = TRUE)
  expect_match(json, '"colors":["#1F78B4FF"]', fixed = TRUE)
  back <- columns_from_json(json)$r_type[[1]]
  expect_equal(back$color_values, 7)
  expect_true(is.numeric(back$color_values))
  expect_identical(back$colors, "#1F78B4FF")
  expect_identical(columns_from_json(columns_to_json(columns_from_json(json)))$r_type[[1]], back)
})

test_that("a class map of one coloured class round-trips through the manifest entry", {
  # D-C1, D-C4. Red: `r_type` has no `color_values` and no `colors`.
  skip_if_not_installed("terra")
  x <- sim_landcover(nrow = 12, ncol = 16)
  x[x != 0] <- 3L
  levels(x) <- data.frame(value = 3, label = "crop")
  terra::coltab(x, layer = 1) <- data.frame(value = 3, col = sim_landcover_colors[[3]])
  names(x) <- "cover"
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  expect_match(out$entry$columns, '"color_values":[3]', fixed = TRUE)
  expect_match(out$entry$columns, paste0('"colors":["', sim_landcover_colors[[3]], '"]'), fixed = TRUE)
  # the entry as the manifest holds it
  manifest <- new_manifest(out$entry, out$files)
  spec <- columns_from_json(manifest$entry$columns)
  expect_equal(spec$r_type[[1]]$color_values, 3)
  expect_identical(spec$r_type[[1]]$colors, sim_landcover_colors[[3]])
  r <- raster_open(be_new(dir), out$files$path, columns = spec)
  expect_colors(r, codes = 3, colors = sim_landcover_colors[[3]])
  expect_identical(as.character(terra::cats(r)[[1]]$label), "crop")
  expect_identical(names(r), "cover")
})

test_that("a window and a subset of the layers keep the colours and the layer names", {
  # D-C4. Red: `r_type` has no colours, so the opened raster has none
  # (file-backed source without a colour table of its own, colours set in
  # the session).
  skip_if_not_installed("terra")
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  expect_false(has_color_table(out$staged))
  spec <- columns_from_json(out$entry$columns)
  be <- be_new(dir)
  whole <- raster_open(be, out$files$path, columns = spec)
  expect_colors(whole)

  box <- sf::st_bbox(c(xmin = -27.1, ymin = 7.3, xmax = -26.5, ymax = 8.1), crs = sf::st_crs(4326))
  window <- raster_open(be, out$files$path, intersects = box, columns = spec)
  expect_lt(terra::ncell(window), terra::ncell(whole))
  expect_identical(names(window), "cover")
  expect_colors(window)
  expect_true(terra::is.factor(window))
  expect_identical(as.character(terra::cats(window)[[1]]$label), sim_landcover_labels)
  expect_true(codes_equal(window, terra::crop(whole, terra::ext(window))))
  # a query in another CRS
  projected <- sf::st_transform(sf::st_as_sfc(box), 32626)
  expect_colors(raster_open(be, out$files$path, intersects = projected, columns = spec))
  # nothing is written next to the file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)

  # several layers: the columns of all layers, then of the coloured one only
  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  several <- c(
    other[["height"]],
    sim_landcover(nrow = 12, ncol = 16, legend = TRUE, colors = TRUE),
    other[["moisture"]]
  )
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(several, dir = dir)
  spec <- columns_from_json(out$entry$columns)
  be <- be_new(dir)
  r <- raster_open(be, out$files$path, intersects = box, columns = spec)
  expect_identical(names(r), c("height", "cover", "moisture"))
  expect_identical(terra::has.colors(r), c(FALSE, TRUE, FALSE))
  expect_colors(r, layer = 2L)
  one <- raster_open(be, out$files$path, columns = spec[spec$name == "cover", ])
  expect_identical(names(one), c("height", "cover", "moisture"))
  expect_identical(terra::has.colors(one), c(FALSE, TRUE, FALSE))
  expect_colors(one, layer = 2L)
  # a layer taken from the opened raster keeps its colours and its name
  cover <- raster_open(be, out$files$path, columns = spec)[["cover"]]
  expect_identical(names(cover), "cover")
  expect_colors(cover)
  expect_true(terra::is.factor(cover))
})

test_that("raster_set_colors() sets the recorded colours and leaves other layers alone", {
  # D-C4, D-C5. Red: could not find function "raster_set_colors".
  skip_if_not_installed("terra")
  dir <- withr::local_tempdir()
  other <- terra::as.int(rcs_sim_raster(nrow = 12, ncol = 16)[[c("height", "moisture")]])
  out <- stage_sim_raster(c(other[["height"]], sim_landcover(nrow = 12, ncol = 16)), dir = dir)
  file <- file.path(dir, out$files$path)
  layer_type <- function(...) {
    c(list(class = "SpatRaster", resolution = c(1, 1), dim = c(12L, 16L)), list(...))
  }
  spec <- columns_spec(
    name = c("height", "cover"), type = c("INT1U", "INT1U"),
    r_type = list(
      layer_type(),
      layer_type(color_values = c(2, 4), colors = c("#33A02CFF", "#B2DF8A80"))
    )
  )
  r <- raster_set_colors(terra::rast(file), spec)
  expect_s4_class(r, "SpatRaster")
  expect_identical(names(r), c("height", "cover"))
  expect_identical(terra::has.colors(r), c(FALSE, TRUE))
  expect_identical(unname(color_hex(r, 2L)[c("2", "4")]), c("#33A02CFF", "#B2DF8A80"))
  expect_false(any(terra::inMemory(r)))
  # nothing is written next to the file
  expect_identical(list.files(dir, recursive = TRUE, all.files = TRUE), out$files$path)

  # no columns, columns without the fields, and a layer the raster lacks
  expect_identical(terra::has.colors(raster_set_colors(terra::rast(file), NULL)), c(FALSE, FALSE))
  bare <- columns_spec(
    name = c("height", "cover"), type = c("INT1U", "INT1U"),
    r_type = list(layer_type(), layer_type())
  )
  expect_identical(terra::has.colors(raster_set_colors(terra::rast(file), bare)), c(FALSE, FALSE))
  absent <- columns_spec(
    name = "elsewhere", type = "INT1U",
    r_type = list(layer_type(color_values = 1, colors = "#1F78B4FF"))
  )
  expect_identical(terra::has.colors(raster_set_colors(terra::rast(file), absent)), c(FALSE, FALSE))
})

test_that("an entry written before part C, without the colour fields, opens as before", {
  # D-C4. The expectations on `raster_open()` are guards: they hold today
  # and must keep holding. Red: could not find function "raster_set_colors"
  # (the last expectation).
  skip_if_not_installed("terra")
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  dir <- withr::local_tempdir()
  out <- stage_sim_raster(x, dir = dir, nodata = 0)
  # the columns as a manifest of version 0.0.0.9005 holds them
  spec <- columns_from_json(out$entry$columns)
  expect_named(
    spec$r_type[[1]],
    c("class", "resolution", "dim", "nodata", "values", "levels", "levels_name")
  )
  be <- be_new(dir)
  expect_no_error(r <- raster_open(be, out$files$path, columns = spec))
  expect_false(terra::has.colors(r))
  expect_true(terra::is.factor(r))
  expect_identical(as.character(terra::cats(r)[[1]]$label), sim_landcover_labels)
  expect_identical(names(r), "cover")
  box <- sf::st_bbox(c(xmin = -27.1, ymin = 7.3, xmax = -26.5, ymax = 8.1), crs = sf::st_crs(4326))
  expect_false(terra::has.colors(raster_open(be, out$files$path, intersects = box, columns = spec)))
  expect_false(terra::has.colors(raster_open(be, out$files$path)))
  expect_false(terra::has.colors(raster_set_colors(terra::rast(out$staged), spec)))
})

test_that("store_write() and store_read() carry the colours of a class map", {
  # D-C1 to D-C4, D-C7, through the public functions. Red: the manifest has
  # no `color_values` and no `colors`, so the raster read has no colours.
  skip_below_level("default")
  skip_if_not_installed("terra")
  root <- withr::local_tempdir()
  paths <- file.path(root, c("primary", "copy"))
  st <- suppressMessages(store_connect(paths[[1]], secondary = paths[[2]], create = TRUE))
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE)
  suppressMessages(store_write(
    st, x, "grids/cover",
    title = "Cover", description = "Simulated class map.", nodata = 0
  ))
  codes <- as.vector(terra::values(sim_landcover()))
  codes[codes == 0] <- NA
  box <- sf::st_as_sfc(sf::st_bbox(c(xmin = -28, ymin = 7, xmax = -27, ymax = 8), crs = sf::st_crs(4326)))

  # the manifest on disk holds the colours next to the legend
  version <- st$primary$catalog$version[st$primary$catalog$dataset == "grids/cover"]
  manifest <- jsonlite::fromJSON(
    file.path(paths[[1]], manifest_path("grids/cover", version)),
    simplifyVector = FALSE
  )
  layer <- jsonlite::fromJSON(manifest$entry$columns, simplifyVector = FALSE)[[1]]
  expect_equal(unlist(layer$r_type$values), 1:5)
  expect_equal(unlist(layer$r_type$color_values), 1:5)
  expect_identical(unlist(layer$r_type$colors), sim_landcover_colors)
  # the data file holds no colour table
  data_file <- file.path(paths[[1]], st$primary$files$path[st$primary$files$dataset == "grids/cover"])
  expect_false(has_color_table(data_file))

  # from the connection, from the primary alone and from the secondary alone
  for (connection in list(st, store_connect(paths[[1]]), store_connect(paths[[2]]))) {
    got <- suppressMessages(store_read(connection, "grids/cover"))
    expect_s4_class(got, "SpatRaster")
    expect_identical(names(got), "cover")
    expect_colors(got)
    expect_true(terra::is.factor(got))
    expect_identical(as.character(terra::cats(got)[[1]]$label), sim_landcover_labels)
    values <- as.vector(terra::values(got))
    expect_identical(is.na(values), is.na(codes))
    expect_equal(values, codes)

    window <- suppressMessages(store_read(connection, "grids/cover", intersects = box))
    expect_lt(terra::ncell(window), terra::ncell(got))
    expect_identical(names(window), "cover")
    expect_colors(window)
    expect_identical(as.character(terra::cats(window)[[1]]$label), sim_landcover_labels)
  }
  # reading wrote nothing next to the files
  expect_length(
    list.files(paths, pattern = "\\.aux\\.(xml|json)$", recursive = TRUE, all.files = TRUE),
    0L
  )
  # the check against the source sees no mismatch (D-C7)
  checked <- suppressMessages(store_check(st, "grids/cover", x = x, n = terra::ncell(x)))
  expect_identical(checked$status, c("ok", "ok"))

  # the same map without its colours: the same version, nothing uploaded
  again <- suppressMessages(store_write(
    st, sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE), "grids/cover",
    title = "Cover", description = "Simulated class map.", nodata = 0, mode = "replace"
  ))
  expect_identical(again$uploaded, c(0, 0))
  expect_identical(st$primary$catalog$version[st$primary$catalog$dataset == "grids/cover"], version)
})
