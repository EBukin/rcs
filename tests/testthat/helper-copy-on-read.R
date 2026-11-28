# Helpers ------------------------------------------------------------------------

# A primary and `secondaries` local secondary folders under
# `withr::local_tempdir()` of `frame`, the datasets written through a
# primary-only connection, secondaries pre-filled with `store_copy()`, and a
# connection made with `store_connect()` whose primary is faked as a cloud
# backend (as `test-read.R` does), so that local secondaries are eligible.
#
#   secondaries  number of secondary folders (0, 1, 2, ...)
#   datasets     datasets written to the primary, any of
#                  "sales/daily"     g_sim(30, 1), key g_key, partition year
#                                    (two files, 2023 and 2024)
#                  "sales/summary"   g_sim(15, 3), key g_key, partition year
#                  "shapes/polygons" rcs_sim_polygons(60, seed = 1), key id,
#                                    partition h3, with its index table
#                  "shapes/points"   rcs_sim_points(80, seed = 1), key id
#                  "grids/sim"       rcs_sim_raster(seed = 1, nrow = 20, ncol = 20)
#                  "grids/cover"     sim_landcover(file = , legend = TRUE,
#                                    colors = TRUE), written with nodata = 0
#   prefill      datasets copied from the primary to the secondaries with
#                `store_copy()` before the connection: a character vector
#                (every secondary) or a list with one character vector per
#                secondary
#   cloud        TRUE: fake the primary's backend type as "gcs" after each
#                connect; FALSE: a local primary
#   connect      TRUE: connect now (`fx$st`); FALSE: `fx$st` is NULL and the
#                test calls `fx$connect()` itself, for example after starting
#                a backend stub (a stub acts only on connections made after it)
#   history      the stores keep history (`store_create(history = )`)
#
# Returns a list:
#   fx$st          the connection, or NULL when `connect = FALSE`
#   fx$connect(...) a new connection (quiet; `...` goes to `store_connect()`),
#                  with the faked cloud primary when `cloud = TRUE`
#   fx$copy(dataset, to)  `store_copy()` of `dataset` from the primary to the
#                  secondary folder `to`, through a local connection of its own
#   fx$root, fx$primary, fx$secondary   the folders (normalised, "/")
#   fx$data        named list: the object each dataset was written from
local_cor_store <- function(secondaries = 1L, datasets = "sales/daily", prefill = character(),
                            cloud = TRUE, connect = TRUE, history = FALSE,
                            frame = parent.frame()) {
  menu <- c("sales/daily", "sales/summary", "shapes/polygons", "shapes/points", "grids/sim", "grids/cover")
  stopifnot(all(datasets %in% menu))
  if (any(c("shapes/polygons", "shapes/points") %in% datasets)) skip_if_no_h3()
  if (any(c("grids/sim", "grids/cover") %in% datasets)) testthat::skip_if_not_installed("terra")

  paths <- g_paths(secondaries = secondaries, history = history, frame = frame)
  primary <- paths[[1]]
  secondary <- paths[-1]
  writer <- g_connect(primary)
  data <- list()
  write <- function(x, dataset, ...) {
    g_quiet(store_write(writer, x, dataset,
      title = dataset, description = paste("Simulated", dataset), ...
    ))
    data[[dataset]] <<- x
  }
  for (dataset in datasets) {
    switch(dataset,
      "sales/daily" = write(g_sim(30, 1), dataset, key = g_key, partition = "year"),
      "sales/summary" = write(g_sim(15, 3), dataset, key = g_key, partition = "year"),
      "shapes/polygons" = write(rcs_sim_polygons(60, seed = 1), dataset, key = "id", partition = "h3"),
      "shapes/points" = write(rcs_sim_points(80, seed = 1), dataset, key = "id"),
      "grids/sim" = write(rcs_sim_raster(seed = 1, nrow = 20, ncol = 20), dataset),
      "grids/cover" = write(
        sim_landcover(
          file = withr::local_tempfile(fileext = ".tif", .local_envir = frame),
          legend = TRUE, colors = TRUE
        ),
        dataset,
        nodata = 0
      )
    )
  }

  copy <- function(dataset, to) {
    g_quiet(store_copy(g_connect(c(primary, to)), dataset, from = primary, to = to))
  }
  if (!is.list(prefill)) prefill <- rep(list(prefill), length(secondary))
  stopifnot(length(prefill) == length(secondary))
  for (i in seq_along(secondary)) {
    for (dataset in prefill[[i]]) copy(dataset, secondary[[i]])
  }

  connect_store <- function(...) {
    st <- g_quiet(store_connect(primary, secondary = secondary, ...))
    if (cloud) cor_cloud(st)
    st
  }
  list(
    st = if (connect) connect_store() else NULL,
    connect = connect_store,
    copy = copy,
    root = dirname(primary),
    primary = primary,
    secondary = secondary,
    data = data
  )
}

# Test-side simulation of a cloud primary (`test-read.R`): backend generics
# dispatch on the class, so the folder keeps working.
cor_cloud <- function(st) {
  primary <- st$primary
  primary$backend$type <- "gcs"
  st$primary <- primary
  invisible(st)
}

# Rows of the files table stored at `path` for `dataset` (path, md5, bytes).
cor_files <- function(path, dataset) {
  files <- location_read(g_plain_backend(path))$files
  files <- files[files$dataset == dataset, c("path", "md5", "bytes")]
  files[order(files$path, method = "radix"), ]
}

# Version of `dataset` in the catalog stored at `path` (character(0) if none).
cor_version <- function(path, dataset) {
  catalog <- location_read(g_plain_backend(path))$catalog
  catalog$version[catalog$dataset == dataset]
}

cor_bytes <- function(path, dataset) {
  sum(as.numeric(cor_files(path, dataset)$bytes))
}

# Plain messages of `expr`.
cor_messages <- function(expr) {
  cli::ansi_strip(testthat::capture_messages(expr))
}

# Messages shown, wide, without progress bars (snapshots).
cor_snapshot_output <- function(frame = parent.frame()) {
  g_snapshot_output(frame)
  withr::local_options(cli.progress_show_after = Inf, .local_envir = frame)
}

# Every file stored at `path`, named by relative path, with its MD5: equal
# before and after means nothing was written there.
cor_state <- function(path) {
  files <- sort(list.files(path, recursive = TRUE, all.files = TRUE), method = "radix")
  stats::setNames(unname(tools::md5sum(file.path(path, files))), files)
}

# Rows of `_history.parquet` at `path` for one version (path, md5, replaced).
cor_history <- function(path, dataset, version) {
  history <- history_read(g_plain_backend(path))
  rows <- history[history$dataset == dataset & history$version == version, c("path", "md5", "replaced")]
  rows[order(rows$path, method = "radix"), ]
}

# Catalog entry of `dataset` held by a location (version, columns, updated).
cor_entry <- function(location, dataset) {
  location$catalog[location$catalog$dataset == dataset, c("version", "columns", "updated")]
}

# Remove the entry and file rows of `dataset` from the catalogs stored at
# `path`; the files stay on disk.
cor_drop_entry <- function(path, dataset) {
  location <- location_read(g_plain_backend(path))
  location_write(
    location,
    location$catalog[location$catalog$dataset != dataset, ],
    location$files[location$files$dataset != dataset, ]
  )
  invisible(path)
}

# Work counters of the last call, summed per counter (and location).
cor_trace_sum <- function(counter, location = NULL) {
  trace <- rcs_trace()
  keep <- trace$counter == counter
  if (!is.null(location)) keep <- keep & trace$location %in% location
  sum(trace$n[keep])
}

# Locations of the `file_open` records of the last call.
cor_opened_at <- function() {
  trace <- rcs_trace()
  trace$location[trace$counter == "file_open"]
}

# A box inside the class map of "grids/cover" (extent -30, -24, 6, 9).
cor_box <- function() {
  sf::st_as_sfc(sf::st_bbox(c(xmin = -28, ymin = 7, xmax = -27, ymax = 8), crs = sf::st_crs(4326)))
}

# A window of a class map against a reference window: fewer cells than the
# whole map, the same extent and codes, the legend and the colours.
expect_cor_window <- function(got, reference, whole) {
  expect_lt(terra::ncell(got), terra::ncell(whole))
  expect_identical(as.vector(terra::ext(got)), as.vector(terra::ext(reference)))
  expect_identical(as.vector(terra::values(got)), as.vector(terra::values(reference)))
  expect_identical(as.character(terra::cats(got)[[1]]$label), sim_landcover_labels)
  expect_true(terra::has.colors(got))
  expect_identical(terra::coltab(got), terra::coltab(reference))
}

# A backend under a random prefix `rcs-test-<random>/` of `RCS_TEST_GCS`
# (a copy of `local_raster_bucket()` in test-raster-gcs.R). It skips below
# level `full`, without `RCS_TEST_GCS`, without Arrow's GCS support or terra.
# The prefix is emptied when the test ends, and the test fails if anything is
# left. GDAL's options and the cached GDAL state of `the_auth` are restored.
local_test_bucket <- function(env = parent.frame()) {
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
