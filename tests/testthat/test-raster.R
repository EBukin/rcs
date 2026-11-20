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
  expect_identical(columns_from_json(out$entry$columns)$type, rep("INT4S", 3))
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

  categorical <- terra::as.int(x[["cover"]])
  levels(categorical) <- data.frame(id = 1:5, class = letters[1:5])
  expect_error(stage_sim_raster(categorical), class = "rcs_error_raster")

  expect_error(stage_sim_raster(data.frame(a = 1)), class = "rcs_error_argument")
  expect_error(
    stage_sim_raster(x, columns = c(nothing = "No such layer.")),
    class = "rcs_error_argument"
  )
  expect_error(stage_sim_raster(x, dataset = "Bad Name"), class = "rcs_error_dataset_name")

  expect_snapshot(stage_sim_raster(no_crs), error = TRUE)
  expect_snapshot(stage_sim_raster(categorical), error = TRUE)
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
  skip_if(!nzchar(Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS")), "GDAL needs GOOGLE_APPLICATION_CREDENTIALS.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
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
})
