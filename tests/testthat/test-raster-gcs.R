# Plan 0006 against Google Cloud Storage: rasters written to, read from and
# versioned in the bucket `RCS_TEST_GCS`, at level `full`. Every test works
# under its own random prefix `rcs-test-<random>/` and removes it.

# Helpers ----------------------------------------------------------------------

# A backend under a random prefix of `RCS_TEST_GCS`. The prefix is emptied
# when the test ends, and the test fails if anything is left. Reading through
# GDAL sets credentials process-wide: GDAL's options and the cached GDAL state
# of `the_auth` are restored afterwards, as in test-raster.R.
local_raster_bucket <- function(env = parent.frame()) {
  skip_below_level("full")
  uri <- Sys.getenv("RCS_TEST_GCS")
  skip_if(!nzchar(uri), "RCS_TEST_GCS is not set.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  skip_if_not_installed("terra")

  gdal_opts <- c(
    "GS_OAUTH2_REFRESH_TOKEN", "GS_OAUTH2_CLIENT_ID", "GS_OAUTH2_CLIENT_SECRET",
    "GOOGLE_APPLICATION_CREDENTIALS", "GDAL_HTTP_HEADERS"
  )
  old_gdal <- terra::getGDALconfig(gdal_opts)
  names(old_gdal) <- gdal_opts
  withr::defer(for (k in gdal_opts) terra::setGDALconfig(k, old_gdal[[k]]), envir = env)
  fields <- c("gdal_id", "gdal_header", "gdal_warned")
  old_auth <- mget(fields, envir = the_auth, ifnotfound = list(NULL))
  rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
  withr::defer(
    {
      rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
      for (f in names(old_auth)) if (!is.null(old_auth[[f]])) assign(f, old_auth[[f]], envir = the_auth)
    },
    envir = env
  )

  withr::local_options(rcs.quiet = TRUE, .local_envir = env)
  gcs_reset_clients()
  prefix <- paste0("rcs-test-", paste(sample(c(letters, 0:9), 12, TRUE), collapse = ""))
  be <- be_new(paste0(sub("/+$", "", uri), "/", prefix))
  withr::defer(
    {
      left <- be_list(be)$path
      if (length(left) > 0) be_delete(be, left)
      testthat::expect_identical(be_list(be)$path, character())
    },
    envir = env
  )
  be
}

# Lines of `gdalinfo` for a stored file, read through the backend's GDAL path
# (`/vsigs/...` for the bucket).
bucket_info <- function(be, path) {
  terra::describe(be_gdal_path(be, path))
}

expect_info <- function(info, text) {
  expect_true(any(grepl(text, info, fixed = TRUE)), label = paste0("gdalinfo shows '", text, "'"))
}

# The finite NoData tag of each band, read with GDAL alone; NA when there is
# none or it is not finite.
bucket_nodata <- function(be, path) {
  info <- jsonlite::fromJSON(
    paste(terra::describe(be_gdal_path(be, path), options = "json"), collapse = "\n"),
    simplifyVector = FALSE
  )
  tags <- vapply(info$bands, function(band) {
    value <- band$noDataValue
    if (is.null(value)) NA_real_ else suppressWarnings(as.numeric(value))
  }, numeric(1))
  tags[!is.finite(tags)] <- NA_real_
  tags
}

# The path of the data file of a dataset in the primary's catalog.
raster_path <- function(st, dataset) {
  st$primary$files$path[st$primary$files$dataset == dataset]
}

raster_version <- function(st, dataset) {
  st$primary$catalog$version[st$primary$catalog$dataset == dataset]
}

# The layers of a version's manifest, downloaded from a location.
bucket_manifest_layers <- function(be, dataset, version) {
  file <- withr::local_tempfile(fileext = ".json")
  be_get(be, manifest_path(dataset, version), file)
  manifest <- jsonlite::fromJSON(file, simplifyVector = FALSE)
  jsonlite::fromJSON(manifest$entry$columns, simplifyVector = FALSE)
}

# The codes a read returns for a class map written with `nodata = 0`: the
# cells holding `0` are missing.
codes_of <- function(x) {
  x <- terra::deepcopy(x)
  levels(x) <- NULL
  v <- as.vector(terra::values(x))
  v[!is.na(v) & v == 0] <- NA
  v
}

# The same class map as a plain raster of codes with the zeros missing: the
# reference a crop of a read is compared with.
codes_raster <- function(x) {
  out <- terra::rast(x)
  terra::values(out) <- codes_of(x)
  out
}

expect_codes <- function(got, expected) {
  got <- as.vector(terra::values(got))
  expect_identical(is.na(got), is.na(expected))
  expect_equal(got, as.numeric(expected))
}

expect_legend <- function(got, values = 1:5, labels = sim_landcover_labels) {
  expect_true(all(terra::is.factor(got)))
  legend <- terra::cats(got)[[1]]
  expect_equal(legend$value, values)
  expect_identical(as.character(legend$label), labels)
}

# A window of a read against the same crop of the reference raster.
expect_window <- function(part, whole_codes, box) {
  expect_lt(terra::ncell(part), terra::ncell(whole_codes))
  # the window covers the query box, by less than one cell on each side
  got <- as.vector(terra::ext(part))
  want <- sf::st_bbox(box)
  res <- terra::res(whole_codes)
  expect_lte(got[["xmin"]], want[["xmin"]])
  expect_gte(got[["xmax"]], want[["xmax"]])
  expect_lte(got[["ymin"]], want[["ymin"]])
  expect_gte(got[["ymax"]], want[["ymax"]])
  expect_lt(want[["xmin"]] - got[["xmin"]], res[[1]])
  expect_lt(got[["xmax"]] - want[["xmax"]], res[[1]])
  expect_lt(want[["ymin"]] - got[["ymin"]], res[[2]])
  expect_lt(got[["ymax"]] - want[["ymax"]], res[[2]])
  reference <- terra::crop(whole_codes, terra::ext(part))
  expect_identical(dim(part), dim(reference))
  expect_codes(part, as.vector(terra::values(reference)))
}

write_cover <- function(st, x, dataset = "grids/cover", ...) {
  store_write(st, x, dataset, title = "Cover", description = "Simulated class map.", ...)
}

query_box <- function(xmin = -28, ymin = 7, xmax = -27, ymax = 8) {
  sf::st_as_sfc(sf::st_bbox(c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax), crs = sf::st_crs(4326)))
}

# Tests ------------------------------------------------------------------------

test_that("a class map written to a bucket primary keeps its type, nodata and legend, and reads back through /vsigs/", {
  skip_below_level("full")
  be <- local_raster_bucket()
  copy <- file.path(withr::local_tempdir(), "copy")
  st <- store_connect(be$uri, secondary = copy, create = TRUE)
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)

  # written to both locations
  first <- write_cover(st, x, nodata = 0)
  expect_identical(first$role, c("primary", "secondary"))
  expect_identical(first$location[[1]], be$uri)
  expect_identical(first$status, c("written", "written"))
  expect_identical(first$uploaded, c(1, 1))
  version <- raster_version(st, "grids/cover")
  expect_identical(st$secondary[[1]]$catalog$version, version)
  path <- raster_path(st, "grids/cover")
  expect_identical(path, paste0("grids/cover/part-", version, ".tif"))

  # the same map again: nothing is uploaded, the version stays (determinism)
  second <- write_cover(st, x, nodata = 0, mode = "replace")
  expect_identical(second$uploaded, c(0, 0))
  expect_identical(second$bytes, c(0, 0))
  expect_identical(raster_version(st, "grids/cover"), version)

  # the object in the bucket, as GDAL sees it through /vsigs/
  expect_match(be_gdal_path(be, path), "^/vsigs/")
  info <- bucket_info(be, path)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=0")
  expect_info(info, "Block=512x512")
  expect_info(info, "LAYOUT=COG")
  expect_info(info, "COMPRESSION=DEFLATE")
  expect_info(info, "PREDICTOR=2")
  expect_identical(bucket_nodata(be, path), 0)
  # one data file and its manifest, no side file
  expect_identical(
    sort(be_list(be, "grids/")$path),
    sort(c(manifest_path("grids/cover", version), path))
  )
  # the MD5 the bucket reports is that of the secondary's file and the catalog's
  local_file <- file.path(copy, path)
  expect_true(file.exists(local_file))
  expect_identical(be_md5(be, path), md5_file(local_file))
  expect_identical(be_md5(be, path), st$primary$files$md5[st$primary$files$dataset == "grids/cover"])
  listed <- be_list(be, "grids/cover/")
  expect_equal(listed$bytes[listed$path == path], file.size(local_file))

  # the manifest, as it is in the bucket
  layers <- bucket_manifest_layers(be, "grids/cover", version)
  expect_length(layers, 1L)
  layer <- layers[[1]]
  expect_identical(layer$name, "cover")
  expect_identical(layer$type, "INT1U")
  expect_identical(layer$r_type$class, "SpatRaster")
  expect_equal(layer$r_type$nodata, 0)
  expect_equal(unlist(layer$r_type$resolution), terra::res(x))
  expect_equal(unlist(layer$r_type$dim), c(60, 80))
  expect_equal(unlist(layer$r_type$values), 1:5)
  expect_identical(unlist(layer$r_type$levels), sim_landcover_labels)
  expect_identical(layer$r_type$levels_name, "label")

  # a connection that has only the bucket reads through /vsigs/
  only <- store_connect(be$uri)
  expect_length(only$secondary, 0L)
  codes <- codes_of(x)
  withr::local_options(rcs.trace = TRUE)
  got <- store_read(only, "grids/cover")
  whole_trace <- rcs_trace()
  expect_s4_class(got, "SpatRaster")
  expect_match(terra::sources(got), "^/vsigs/")
  expect_identical(names(got), "cover")
  expect_identical(terra::datatype(got), "INT1U")
  expect_legend(got)
  expect_true(all(is.na(terra::values(got)[c(1:2, 79:80), ])))
  expect_codes(got, codes)

  # a window: the right extent, the categories, the values of the same crop
  box <- query_box()
  part <- store_read(only, "grids/cover", intersects = box)
  part_trace <- rcs_trace()
  expect_legend(part)
  expect_window(part, codes_raster(x), box)
  # Work counters: a read through /vsigs/ is one opened file and no download
  # by the backend (`be_get()` counts `bytes_down`). The bytes GDAL fetches
  # itself by range requests are not counted by `rcs_trace()`, so "fewer
  # bytes than the whole file" cannot be asserted here.
  for (trace in list(whole_trace, part_trace)) {
    expect_identical(sum(trace$n[trace$counter == "file_open"]), 1)
    expect_false(any(trace$counter == "bytes_down"))
    expect_false(any(trace$detail %in% "be_get"))
  }
  withr::local_options(rcs.trace = FALSE)

  # described, checked against the source, and the same in the secondary
  d <- store_describe(only, "grids/cover")
  expect_identical(d$columns$type, "INT1U")
  expect_identical(d$columns$r_type, "raster layer (60 x 80 cells, nodata 0, 5 classes)")
  checked <- store_check(st, "grids/cover", x = x, n = terra::ncell(x))
  expect_identical(checked$location, c(be$uri, st$secondary[[1]]$uri))
  expect_identical(checked$status, c("ok", "ok"))
  status <- store_status(st)
  expect_identical(status$dataset, "grids/cover")
  expect_identical(status$status, "same")
  # the secondary alone returns the same raster
  from_copy <- store_read(store_connect(copy), "grids/cover")
  expect_legend(from_copy)
  expect_codes(from_copy, codes)

  # another nodata is another file and another version, in both locations
  third <- write_cover(st, x, nodata = 255, mode = "replace")
  expect_identical(third$uploaded, c(1, 1))
  changed <- raster_version(st, "grids/cover")
  expect_false(identical(changed, version))
  expect_identical(st$secondary[[1]]$catalog$version, changed)
  changed_path <- raster_path(st, "grids/cover")
  expect_identical(be_md5(be, changed_path), md5_file(file.path(copy, changed_path)))
  expect_identical(store_status(st)$status, "same")
  # The new object, downloaded and inspected locally: GDAL has listed this
  # folder of the bucket above, and the read of a replaced raster through
  # /vsigs/ has a test of its own below.
  downloaded <- withr::local_tempfile(fileext = ".tif")
  be_get(be, changed_path, downloaded)
  info <- terra::describe(downloaded)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=255")
})

test_that("a raster replaced after it was read from the bucket is read again in the same session", {
  skip_below_level("full")
  be <- local_raster_bucket()
  st <- store_connect(be$uri, create = TRUE)
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  write_cover(st, x, nodata = 0)
  old <- raster_version(st, "grids/cover")
  # the first read opens the file through /vsigs/
  got <- store_read(st, "grids/cover")
  expect_match(terra::sources(got), paste0("^/vsigs/.*part-", old, "\\.tif$"))
  expect_codes(got, codes_of(x))

  # class 5 recoded to 4: a new file in the same folder of the bucket
  y <- sim_landcover()
  y[y == 5] <- 4L
  names(y) <- "cover"
  out <- write_cover(st, y, nodata = 0, mode = "replace")
  expect_identical(out$status, "written")
  new <- raster_version(st, "grids/cover")
  expect_false(identical(new, old))
  expect_identical(be_list(be, "grids/cover/")$path, sort(c(manifest_path("grids/cover", new), raster_path(st, "grids/cover"))))

  # the same connection, and a new one, read the new version
  again <- store_read(st, "grids/cover")
  expect_match(terra::sources(again), paste0("^/vsigs/.*part-", new, "\\.tif$"))
  expect_codes(again, codes_of(y))
  fresh <- store_read(store_connect(be$uri), "grids/cover", intersects = query_box())
  expect_window(fresh, codes_raster(y), query_box())
})

test_that("in-memory rasters written to the bucket keep the smallest type, a requested type and the gdal options", {
  skip_below_level("full")
  be <- local_raster_bucket()
  st <- store_connect(be$uri, create = TRUE)
  only <- store_connect(be$uri)
  write <- function(x, dataset, ...) {
    out <- store_write(st, x, dataset, title = "Grid", description = "Simulated raster.", ...)
    expect_identical(out$status, "written")
    expect_identical(out$uploaded, 1)
    store_refresh(only)
    raster_path(st, dataset)
  }

  # whole numbers 1-5 with missing cells: Byte with the type's default flag
  classes <- sim_landcover(nrow = 12, ncol = 16)
  classes[classes == 0] <- NA
  names(classes) <- "cover"
  expect_true(all(terra::inMemory(classes)))
  expect_true(anyNA(terra::values(classes)))
  path <- write(classes, "grids/classes")
  info <- bucket_info(be, path)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=255")
  expect_info(info, "COMPRESSION=DEFLATE")
  expect_identical(bucket_nodata(be, path), 255)
  layer <- bucket_manifest_layers(be, "grids/classes", raster_version(st, "grids/classes"))[[1]]
  expect_identical(layer$type, "INT1U")
  expect_equal(layer$r_type$nodata, 255)
  got <- store_read(only, "grids/classes")
  expect_match(terra::sources(got), "^/vsigs/")
  expect_identical(terra::datatype(got), "INT1U")
  expect_false(terra::is.factor(got))
  expected <- as.vector(terra::values(classes))
  expect_identical(is.na(as.vector(terra::values(got))), is.na(expected))
  expect_equal(as.vector(terra::values(got)), as.numeric(expected))

  # doubles with datatype = "FLT4S": Float32, equal within single precision
  doubles <- rcs_sim_raster(seed = 1, nrow = 12, ncol = 16)
  expect_true(all(terra::inMemory(doubles)))
  path <- write(doubles, "grids/single", datatype = "FLT4S")
  info <- bucket_info(be, path)
  expect_info(info, "Type=Float32")
  expect_info(info, "PREDICTOR=3")
  expect_identical(bucket_nodata(be, path), rep(NA_real_, terra::nlyr(doubles)))
  got <- store_read(only, "grids/single")
  expect_identical(names(got), names(doubles))
  expect_identical(terra::datatype(got), rep("FLT4S", terra::nlyr(doubles)))
  a <- terra::values(got)
  b <- terra::values(doubles)
  expect_identical(dim(a), dim(b))
  expect_identical(is.na(a), is.na(b))
  keep <- !is.na(b)
  expect_true(all(abs(a[keep] - b[keep]) <= 1e-6 * pmax(1, abs(b[keep]))))
  expect_identical(store_check(st, "grids/single", x = doubles, n = terra::ncell(doubles))$status, "ok")

  # doubles without a datatype stay Float64 and read back exactly
  path <- write(doubles, "grids/double")
  expect_info(bucket_info(be, path), "Type=Float64")
  got <- store_read(only, "grids/double")
  expect_identical(terra::datatype(got), rep("FLT8S", terra::nlyr(doubles)))
  a <- unname(terra::values(got))
  b <- unname(terra::values(doubles))
  expect_identical(is.na(a), is.na(b))
  expect_identical(a[!is.na(a)], b[!is.na(b)])

  # gdal = replaces the default compression and keeps the other defaults
  path <- write(classes, "grids/zstd", gdal = c("COMPRESS=ZSTD"))
  info <- bucket_info(be, path)
  expect_info(info, "COMPRESSION=ZSTD")
  expect_info(info, "Type=Byte")
  expect_info(info, "Block=512x512")
  expect_info(info, "LAYOUT=COG")
  expect_false(identical(raster_version(st, "grids/zstd"), raster_version(st, "grids/classes")))
  got <- store_read(only, "grids/zstd")
  expect_equal(as.vector(terra::values(got)), as.numeric(expected))
})

test_that("a replaced class map is a new version in the bucket, and the old one stays readable with its legend", {
  skip_below_level("full")
  be <- local_raster_bucket()
  # history is off by default (`store_create(history = FALSE)`): keep it here
  store_create(be$uri, history = TRUE)
  st <- store_connect(be$uri)
  old_map <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  first <- write_cover(st, old_map, nodata = 0)
  expect_identical(first$status, "written")
  old <- raster_version(st, "grids/cover")
  old_path <- raster_path(st, "grids/cover")

  # class 5 recoded to 4, with a legend of four classes
  new_map <- sim_landcover()
  new_map[new_map == 5] <- 4L
  new_labels <- sim_landcover_labels[1:4]
  levels(new_map) <- data.frame(value = 1:4, label = new_labels)
  names(new_map) <- "cover"
  expect_error(write_cover(st, new_map, nodata = 0), class = "rcs_error_dataset_exists")
  second <- write_cover(st, new_map, nodata = 0, mode = "replace")
  expect_identical(second$status, "written")
  expect_identical(second$uploaded, 1)
  new <- raster_version(st, "grids/cover")
  expect_false(identical(new, old))
  new_path <- raster_path(st, "grids/cover")
  expect_identical(new_path, paste0("grids/cover/part-", new, ".tif"))

  # both versions are in the bucket, each with its manifest
  expect_identical(
    sort(be_list(be, "grids/")$path),
    sort(c(manifest_path("grids/cover", c(old, new)), old_path, new_path))
  )
  history <- store_history(st, "grids/cover")
  expect_identical(history$version, c(new, old))
  expect_true(all(history$complete))

  # a fresh connection with only the bucket
  only <- store_connect(be$uri)
  expect_identical(raster_version(only, "grids/cover"), new)
  got <- store_read(only, "grids/cover")
  expect_match(terra::sources(got), paste0("^/vsigs/.*part-", new, "\\.tif$"))
  expect_legend(got, 1:4, new_labels)
  expect_codes(got, codes_of(new_map))
  expect_false(any(as.vector(terra::values(got)) == 5, na.rm = TRUE))
  d <- store_describe(only, "grids/cover")
  expect_identical(d$columns$r_type, "raster layer (60 x 80 cells, nodata 0, 4 classes)")

  # the old version: its values and its legend of five classes
  before <- store_read(only, "grids/cover", version = old)
  expect_match(terra::sources(before), paste0("^/vsigs/.*part-", old, "\\.tif$"))
  expect_identical(terra::datatype(before), "INT1U")
  expect_legend(before)
  expect_codes(before, codes_of(old_map))
  expect_true(any(as.vector(terra::values(before)) == 5, na.rm = TRUE))
  box <- query_box()
  part <- store_read(only, "grids/cover", version = old, intersects = box)
  expect_legend(part)
  expect_window(part, codes_raster(old_map), box)
  expect_identical(
    as.vector(terra::values(store_read(only, "grids/cover", version = new))),
    as.vector(terra::values(got))
  )
})

test_that("a larger class map in the bucket is a tiled COG with NEAREST overviews, and a window reads back equal", {
  skip_below_level("full")
  be <- local_raster_bucket()
  st <- store_connect(be$uri, create = TRUE)
  # The raster of A-T9 (plan 0006, "Results", item 9): codes 0, 40, ..., 200,
  # on which averaged overviews would hold other values.
  big <- rcs_sim_raster(seed = 1, nrow = 1100, ncol = 1100)[["cover"]]
  lc <- terra::as.int(big)
  v <- matrix(as.vector(terra::values(lc)), nrow = 1100, byrow = TRUE)
  v[c(1:2, 1099:1100), ] <- 0L
  v[, c(1:2, 1099:1100)] <- 0L
  terra::values(lc) <- as.vector(t(v))
  x <- lc * 40L
  names(x) <- "cover"
  source_codes <- sort(unique(as.vector(terra::values(x))))
  expect_identical(as.numeric(source_codes), seq(0, 200, by = 40))

  out <- write_cover(st, x, "grids/big", nodata = 0)
  expect_identical(out$status, "written")
  path <- raster_path(st, "grids/big")
  gdal_path <- be_gdal_path(be, path)
  info <- terra::describe(gdal_path)
  expect_info(info, "Size is 1100, 1100")
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=0")
  expect_info(info, "Block=512x512")
  expect_info(info, "LAYOUT=COG")
  expect_info(info, "COMPRESSION=DEFLATE")
  expect_info(info, "Overviews: 550x550")
  expect_info(info, "OVERVIEW_RESAMPLING=NEAREST")
  expect_identical(be_md5(be, path), st$primary$files$md5[st$primary$files$dataset == "grids/big"])
  # the first overview, read from the bucket, holds class codes only
  overview <- terra::rast(gdal_path, opts = "OVERVIEW_LEVEL=0")
  expect_identical(dim(overview)[1:2], c(550, 550))
  overview_values <- unique(as.vector(terra::values(overview)))
  expect_true(all(overview_values[!is.na(overview_values)] %in% source_codes[source_codes != 0]))

  # a small window, from a connection with only the bucket
  only <- store_connect(be$uri)
  box <- query_box(xmin = -27.3, ymin = 7.4, xmax = -27.1, ymax = 7.55)
  withr::local_options(rcs.trace = TRUE)
  part <- store_read(only, "grids/big", intersects = box)
  trace <- rcs_trace()
  withr::local_options(rcs.trace = FALSE)
  expect_lt(terra::ncell(part), terra::ncell(x) / 100)
  expect_false(terra::is.factor(part))
  expect_window(part, codes_raster(x), box)
  # no download of the file by the backend; GDAL's own range requests are not
  # counted by `rcs_trace()`
  expect_identical(sum(trace$n[trace$counter == "file_open"]), 1)
  expect_false(any(trace$counter == "bytes_down"))

  # a window on the edge: the cells outside the map are missing
  corner <- store_read(only, "grids/big", intersects = query_box(xmin = -30, ymin = 8.9, xmax = -29.9, ymax = 9))
  expect_true(all(is.na(terra::values(corner)[seq_len(2 * terra::ncol(corner))])))
  expect_window(corner, codes_raster(x), query_box(xmin = -30, ymin = 8.9, xmax = -29.9, ymax = 9))
})

test_that("a class map written to a local primary lands in a bucket secondary with the same MD5 and version", {
  skip_below_level("full")
  be <- local_raster_bucket()
  primary <- file.path(withr::local_tempdir(), "primary")
  store_create(primary)
  store_create(be$uri)
  st <- store_connect(primary, secondary = be$uri)
  x <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)

  out <- write_cover(st, x, nodata = 0)
  expect_identical(out$role, c("primary", "secondary"))
  expect_identical(out$location[[2]], be$uri)
  expect_identical(out$status, c("written", "written"))
  expect_identical(out$uploaded, c(1, 1))
  version <- raster_version(st, "grids/cover")
  path <- raster_path(st, "grids/cover")
  expect_identical(st$secondary[[1]]$catalog$version, version)
  expect_identical(store_status(st)$status, "same")

  # the object in the bucket is the primary's file
  expect_identical(
    sort(be_list(be, "grids/")$path),
    sort(c(manifest_path("grids/cover", version), path))
  )
  expect_identical(be_md5(be, path), md5_file(file.path(primary, path)))
  info <- bucket_info(be, path)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=0")
  expect_info(info, "LAYOUT=COG")
  layer <- bucket_manifest_layers(be, "grids/cover", version)[[1]]
  expect_identical(layer$type, "INT1U")
  expect_equal(layer$r_type$nodata, 0)
  expect_equal(unlist(layer$r_type$values), 1:5)
  expect_identical(unlist(layer$r_type$levels), sim_landcover_labels)

  # a connection with only the bucket returns the categorical raster
  only <- store_connect(be$uri)
  expect_identical(raster_version(only, "grids/cover"), version)
  got <- store_read(only, "grids/cover")
  expect_match(terra::sources(got), "^/vsigs/")
  expect_identical(terra::datatype(got), "INT1U")
  expect_legend(got)
  expect_codes(got, codes_of(x))
  box <- query_box()
  part <- store_read(only, "grids/cover", intersects = box)
  expect_legend(part)
  expect_window(part, codes_raster(x), box)
  expect_identical(store_check(st, "grids/cover", x = x, n = terra::ncell(x))$status, c("ok", "ok"))

  # the same map again sends nothing to the bucket
  again <- write_cover(st, x, nodata = 0, mode = "replace")
  expect_identical(again$uploaded, c(0, 0))
  expect_identical(raster_version(st, "grids/cover"), version)
})

# Plan 0006, part C: legend colours ---------------------------------------------

# The colours of a layer as `#RRGGBBAA` (upper case), named by code; read with
# terra alone. A colour table set in the session has a row per code given, one
# read from a file 256 rows, so colours are compared per code.
bucket_color_hex <- function(x, layer = 1L) {
  table <- terra::coltab(x)[[layer]]
  if (is.null(table)) {
    return(NULL)
  }
  hex <- toupper(grDevices::rgb(
    table[[2]], table[[3]], table[[4]], table[[5]],
    maxColorValue = 255
  ))
  stats::setNames(hex, table[[1]])
}

expect_bucket_colors <- function(got, codes = 1:5, colors = sim_landcover_colors) {
  expect_true(all(terra::has.colors(got)))
  expect_identical(unname(bucket_color_hex(got)[as.character(codes)]), colors)
}

test_that("a coloured class map written to the bucket reads back through /vsigs/ with its colours and legend, also as a window", {
  # Plan 0006, part C (D-C1 to D-C4). Red before part C: the manifest has no
  # `color_values` and no `colors`, so the raster read has no colours.
  skip_below_level("full")
  be <- local_raster_bucket()
  st <- store_connect(be$uri, create = TRUE)
  x <- sim_landcover(
    file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE
  )
  out <- write_cover(st, x, nodata = 0)
  expect_identical(out$status, "written")
  expect_identical(out$uploaded, 1)
  version <- raster_version(st, "grids/cover")
  path <- raster_path(st, "grids/cover")

  # the object in the bucket: codes only, no colour table, no side file
  info <- bucket_info(be, path)
  expect_info(info, "Type=Byte")
  expect_info(info, "NoData Value=0")
  expect_false(any(grepl("Color Table|ColorInterp=Palette", info)))
  expect_identical(
    sort(be_list(be, "grids/")$path),
    sort(c(manifest_path("grids/cover", version), path))
  )
  # the same file as the map without its colours
  plain <- raster_stage(
    sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE), "grids/cover",
    title = "Cover", description = "Simulated class map.",
    dir = withr::local_tempdir(), nodata = 0
  )
  expect_identical(be_md5(be, path), plain$files$md5)
  expect_identical(version, plain$entry$version)

  # the manifest, as it is in the bucket
  layer <- bucket_manifest_layers(be, "grids/cover", version)[[1]]
  expect_identical(layer$name, "cover")
  expect_equal(unlist(layer$r_type$values), 1:5)
  expect_identical(unlist(layer$r_type$levels), sim_landcover_labels)
  expect_equal(unlist(layer$r_type$color_values), 1:5)
  expect_identical(unlist(layer$r_type$colors), sim_landcover_colors)

  # a connection that has only the bucket reads through /vsigs/
  only <- store_connect(be$uri)
  got <- store_read(only, "grids/cover")
  expect_match(terra::sources(got), "^/vsigs/")
  expect_identical(names(got), "cover")
  expect_identical(terra::datatype(got), "INT1U")
  expect_legend(got)
  expect_bucket_colors(got)
  expect_codes(got, codes_of(x))

  # a window: the extent, the values of the same crop, the legend, the colours
  box <- query_box()
  part <- store_read(only, "grids/cover", intersects = box)
  expect_identical(names(part), "cover")
  expect_legend(part)
  expect_bucket_colors(part)
  expect_window(part, codes_raster(x), box)

  # reading left nothing in the bucket, and the check sees no mismatch
  expect_identical(
    sort(be_list(be, "grids/")$path),
    sort(c(manifest_path("grids/cover", version), path))
  )
  expect_identical(store_check(st, "grids/cover", x = x, n = terra::ncell(x))$status, "ok")
})
