# Copy on read (plan 0005, Part B). Each test names its id (B-Tn) and whether
# it is red (fails before the change, for the reason given) or a guard
# (passes before and after).

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

# Tests --------------------------------------------------------------------------

test_that("store_read() copies a dataset to an empty local secondary of a cloud primary, then reads from the copy", {
  # B-T1 (red). Red: nothing is copied; the secondary stays empty and the read
  # comes from the primary, with no "Copying" or "Reading ... from secondary"
  # message.
  skip_below_level("default")
  fx <- local_cor_store()
  cor_snapshot_output()
  expected <- g_read_at(fx$primary, "sales/daily")
  expect_message(
    expect_message(got <- store_read(fx$st, "sales/daily"), "Copying"),
    "Reading .* from secondary"
  )
  version <- cor_version(fx$primary, "sales/daily")
  expect_identical(cor_version(fx$secondary[[1]], "sales/daily"), version)
  expect_identical(
    cor_files(fx$secondary[[1]], "sales/daily")$md5,
    cor_files(fx$primary, "sales/daily")$md5
  )
  expect_rows_same(got, expected)
  expect_store_valid(fx$st)

  fx <- local_cor_store()
  expect_snapshot(invisible(store_read(fx$st, "sales/daily")), transform = g_scrub(fx$root))
})

test_that("store_read() shows a progress bar while it copies", {
  # B-T2 (red). Red: nothing is copied, so no progress bar.
  skip_below_level("default")
  fx <- local_cor_store()
  testthat::local_reproducible_output(width = 300)
  withr::local_options(rcs.quiet = FALSE, cli.progress_show_after = 0)
  msgs <- cor_messages(store_read(fx$st, "sales/daily"))
  expect_match(msgs, "\\d+/\\d+ files", all = FALSE)
})

test_that("a second store_read() of a copied dataset copies nothing and reads from the secondary", {
  # B-T3 (red). Red: the first read copies nothing, so the second read comes
  # from the primary and does not inform "Reading ... from secondary".
  skip_below_level("default")
  fx <- local_cor_store()
  g_quiet(store_read(fx$st, "sales/daily"))
  withr::local_options(rcs.quiet = FALSE, rcs.trace = TRUE)
  msgs <- cor_messages(store_read(fx$st, "sales/daily"))
  trace <- rcs_trace()
  expect_match(msgs, "Reading .* from secondary", all = FALSE)
  expect_false(any(grepl("Copying", msgs)))
  expect_identical(sum(trace$n[trace$counter == "bytes_up"]), 0)
})

test_that("after an update on the primary, store_read() copies the new version and sends only the changed files", {
  # B-T4 (red). Red: nothing is copied; no data file is put in the secondary,
  # which keeps the old version.
  skip_below_level("default")
  fx <- local_cor_store(prefill = "sales/daily", connect = FALSE)
  stub <- local_backend_stub(uri = fx$secondary[[1]])
  st <- fx$connect()
  before <- cor_files(fx$primary, "sales/daily")
  g_write(g_connect(fx$primary), g_sim(12, 7, years = 2024L), mode = "update")
  g_quiet(store_refresh(st))
  after <- cor_files(fx$primary, "sales/daily")
  changed <- sum(!paste(after$path, after$md5) %in% paste(before$path, before$md5))
  # setup: the update changed some partition files, not all
  expect_gt(changed, 0L)
  expect_lt(changed, nrow(after))

  stub_reset(stub)
  got <- g_quiet(store_read(st, "sales/daily"))
  expect_identical(g_data_puts(stub), changed)
  expect_identical(cor_version(fx$secondary[[1]], "sales/daily"), cor_version(fx$primary, "sales/daily"))
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily"))
})

test_that("store_read() does not copy above rcs.copy_on_read_max_bytes and says how to copy", {
  # B-T5 (red). Red: no "above the" message.
  skip_below_level("default")
  fx <- local_cor_store()
  withr::local_options(rcs.copy_on_read_max_bytes = cor_bytes(fx$primary, "sales/daily") - 1)
  cor_snapshot_output()
  expected <- g_read_at(fx$primary, "sales/daily")

  expect_message(got <- store_read(fx$st, "sales/daily"), "above the")
  expect_rows_same(got, expected)
  expect_identical(g_listed(fx$secondary[[1]]), character())

  expect_message(got <- store_read(fx$st, "sales/daily", year == 2024), "above the")
  expect_rows_same(got, expected[expected$year == 2024, ])

  expect_message(
    got <- store_read(fx$st, "sales/daily", columns = c(shop_id, date, product, qty)),
    "above the"
  )
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily", columns = c(shop_id, date, product, qty)))
  expect_identical(g_listed(fx$secondary[[1]]), character())

  expect_snapshot(invisible(store_read(fx$st, "sales/daily")), transform = g_scrub(fx$root))
})

test_that("store_read(copy = TRUE) copies above the limit, copy = FALSE never copies, other values abort", {
  # B-T6 (red, every part). Red: `copy` is not an argument yet; it is taken
  # as a filter expression and the read aborts with the simple error
  # "filter expressions must be either an expression or a list of
  # expressions" (the first part errors, the later parts are not reached).
  skip_below_level("default")
  fx <- local_cor_store()
  withr::local_options(rcs.copy_on_read_max_bytes = 1, rcs.quiet = FALSE)
  expect_message(got <- store_read(fx$st, "sales/daily", copy = TRUE), "Copying")
  expect_identical(cor_version(fx$secondary[[1]], "sales/daily"), cor_version(fx$primary, "sales/daily"))
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily"))

  withr::local_options(rcs.copy_on_read_max_bytes = 2e9)
  fx <- local_cor_store()
  expect_silent(got <- store_read(fx$st, "sales/daily", copy = FALSE))
  expect_identical(g_listed(fx$secondary[[1]]), character())
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily"))

  expect_error(store_read(fx$st, "sales/daily", copy = "yes"), class = "rcs_error_argument")
  expect_error(store_read(fx$st, "sales/daily", copy = NA), class = "rcs_error_argument")
  expect_identical(g_listed(fx$secondary[[1]]), character())
})

test_that("store_connect(copy_on_read = FALSE) turns copying off for the connection, copy = TRUE still copies", {
  # B-T7 (red, every part). Red: `store_connect()` has no argument
  # `copy_on_read`: "unused argument (copy_on_read = FALSE)" (the later parts
  # are not reached).
  skip_below_level("default")
  fx <- local_cor_store(connect = FALSE)
  st <- fx$connect(copy_on_read = FALSE)
  expect_identical(st$copy_on_read, FALSE)
  withr::local_options(rcs.quiet = FALSE)
  expect_silent(store_read(st, "sales/daily"))
  expect_identical(g_listed(fx$secondary[[1]]), character())

  g_quiet(store_refresh(st))
  expect_identical(st$copy_on_read, FALSE)
  expect_silent(store_read(st, "sales/daily"))
  expect_identical(g_listed(fx$secondary[[1]]), character())

  expect_message(store_read(st, "sales/daily", copy = TRUE), "Copying")
  expect_identical(cor_version(fx$secondary[[1]], "sales/daily"), cor_version(fx$primary, "sales/daily"))

  expect_error(
    store_connect(fx$primary, secondary = fx$secondary, copy_on_read = "no"),
    class = "rcs_error_argument"
  )
})

test_that("store_read() copies nothing without an eligible secondary, and copy = TRUE then says so", {
  # B-T8. First two parts guard; the last part red. Red: `copy = TRUE` is
  # taken as a filter expression and the read aborts with the simple error
  # "filter expressions must be either an expression or a list of
  # expressions", instead of informing "No secondary location to copy to".
  skip_below_level("default")
  withr::local_options(rcs.quiet = FALSE)

  # No secondary (cloud primary): nothing is written next to the primary,
  # nothing is said (guard).
  fx <- local_cor_store(secondaries = 0L)
  listed <- function() sort(list.files(fx$root, recursive = TRUE, all.files = TRUE), method = "radix")
  before <- listed()
  expect_silent(got <- store_read(fx$st, "sales/daily"))
  expect_identical(listed(), before)
  expect_rows_same(got, fx$data[["sales/daily"]])

  # A local primary with an empty local secondary: nothing copied, nothing
  # said (guard).
  fx <- local_cor_store(cloud = FALSE)
  expect_silent(store_read(fx$st, "sales/daily"))
  expect_identical(g_listed(fx$secondary[[1]]), character())

  # The same with copy = TRUE: one line, still nothing copied (red).
  expect_message(
    store_read(fx$st, "sales/daily", copy = TRUE),
    "No secondary location to copy to"
  )
  expect_identical(g_listed(fx$secondary[[1]]), character())
})

test_that("store_read() of an old version copies nothing by default and says so; copy = TRUE adds it to the secondaries' history", {
  # B-T9. Red, every part. Red (first part): nothing informs "old versions
  # are not copied". Red (second part): `copy` is not an argument yet; it is
  # taken as a filter expression and the read aborts with the simple error
  # "filter expressions must be either an expression or a list of
  # expressions" (the later checks are not reached).
  skip_below_level("default")
  fx <- local_cor_store(secondaries = 2L, history = TRUE, connect = FALSE)
  old <- cor_version(fx$primary, "sales/daily")
  g_write(g_connect(fx$primary), g_sim(12, 7, years = 2024L), mode = "update")
  current <- cor_version(fx$primary, "sales/daily")
  fx$copy("sales/daily", fx$secondary[[1]])
  st <- fx$connect()
  a <- fx$secondary[[1]]
  b <- fx$secondary[[2]]
  # setup: two versions; A holds the current one, B nothing
  expect_false(identical(old, current))
  expect_identical(cor_version(a, "sales/daily"), current)
  expect_identical(g_listed(b), character())
  expect_gt(nrow(cor_history(fx$primary, "sales/daily", old)), 0L)

  cor_snapshot_output()
  before <- list(a = cor_state(a), b = cor_state(b))
  expect_message(
    got <- store_read(st, "sales/daily", version = old),
    "old versions are not copied"
  )
  expect_rows_same(got, fx$data[["sales/daily"]])
  expect_identical(list(a = cor_state(a), b = cor_state(b)), before)
  expect_snapshot(
    invisible(store_read(st, "sales/daily", version = old)),
    transform = g_scrub(fx$root)
  )

  # copy = TRUE: the old version lands in the history of A and of B
  g_quiet(store_read(st, "sales/daily", version = old, copy = TRUE))
  rows <- cor_history(fx$primary, "sales/daily", old)
  manifest <- manifest_path("sales/daily", old)
  written <- manifest_read(g_plain_backend(fx$primary), "sales/daily", old)$written
  for (sec in c(a, b)) {
    expect_true(all(file.exists(file.path(sec, rows$path))))
    expect_true(file.exists(file.path(sec, manifest)))
    expect_identical(cor_history(sec, "sales/daily", old), rows)
    expect_identical(manifest_read(g_plain_backend(sec), "sales/daily", old)$written, written)
  }
  expect_identical(cor_version(a, "sales/daily"), current)
  expect_identical(g_listed(b), character())
  expect_store_valid(st)

  expect_message(
    got <- store_read(st, "sales/daily", version = old),
    "Reading .* from secondary"
  )
  expect_rows_same(got, fx$data[["sales/daily"]])

  n_rows <- c(nrow(history_read(g_plain_backend(a))), nrow(history_read(g_plain_backend(b))))
  g_quiet(store_read(st, "sales/daily", version = old, copy = TRUE))
  expect_identical(
    c(nrow(history_read(g_plain_backend(a))), nrow(history_read(g_plain_backend(b)))),
    n_rows
  )
})

test_that("store_sample(), store_glimpse(), store_open(), store_duckdb() and reads of an index table copy nothing", {
  # B-T10 (guard). Lazy reads, samples and glimpses never copy (D-B12 for
  # index tables).
  skip_below_level("default")
  skip_if_not_installed("duckdb")
  fx <- local_cor_store()
  sec <- fx$secondary[[1]]
  before <- cor_state(sec)

  sample <- g_quiet(store_sample(fx$st, "sales/daily", n = 5))
  expect_gt(nrow(sample), 0L)
  utils::capture.output(g_quiet(store_glimpse(fx$st, "sales/daily")))
  lazy <- dplyr::collect(g_quiet(store_open(fx$st, "sales/daily")))
  expect_identical(nrow(lazy), nrow(fx$data[["sales/daily"]]))
  lazy <- dplyr::collect(g_quiet(store_open(fx$st, "sales/daily", engine = "duckdb")))
  store_duckdb_close(fx$st)
  expect_identical(nrow(lazy), nrow(fx$data[["sales/daily"]]))
  con <- g_quiet(store_duckdb(fx$st))
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_identical(cor_state(sec), before)
  expect_identical(g_listed(sec), character())

  fx <- local_cor_store(datasets = "shapes/polygons")
  sec <- fx$secondary[[1]]
  before <- cor_state(sec)
  index <- g_quiet(store_read(fx$st, index_name("shapes/polygons")))
  expect_gt(nrow(index), 0L)
  expect_identical(cor_state(sec), before)
})

test_that("an unavailable secondary gets no copy and the read succeeds from the primary", {
  # B-T11 (guard).
  skip_below_level("default")
  fx <- local_cor_store()
  location <- fx$st$secondary[[1]]
  location$available <- FALSE
  location$catalog <- catalog_empty()
  location$files <- files_empty()
  location$token <- NA_character_
  store_set_location(fx$st, location)
  withr::local_options(rcs.quiet = FALSE)
  expect_no_warning(expect_no_error(got <- store_read(fx$st, "sales/daily")))
  expect_rows_same(got, fx$data[["sales/daily"]])
  expect_identical(g_listed(fx$secondary[[1]]), character())
})

test_that("store_read() does not replace a secondary holding a newer version, and says so", {
  # B-T12 (red). Red: no "holds a newer version" message.
  skip_below_level("default")
  fx <- local_cor_store(prefill = "sales/daily", connect = FALSE)
  sec <- fx$secondary[[1]]
  g_write(g_connect(sec), g_sim(12, 9, years = 2025L), mode = "update")
  st <- fx$connect()
  newer <- cor_version(sec, "sales/daily")
  # setup: the secondary holds another version, written after the primary's
  expect_false(identical(newer, cor_version(fx$primary, "sales/daily")))

  cor_snapshot_output()
  expect_message(got <- store_read(st, "sales/daily"), "holds a newer version")
  expect_identical(cor_version(sec, "sales/daily"), newer)
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily"))
  expect_snapshot(invisible(store_read(st, "sales/daily")), transform = g_scrub(fx$root))
  expect_identical(cor_version(sec, "sales/daily"), newer)
})

test_that("one store_read() copies to two empty secondaries, fetching each data file once", {
  # B-T13 (red). Red: nothing is copied; both secondaries stay empty and no
  # data file is fetched from the primary.
  skip_below_level("default")
  fx <- local_cor_store(secondaries = 2L, connect = FALSE)
  stub <- local_backend_stub(uri = fx$primary)
  st <- fx$connect()
  stub_reset(stub)
  got <- g_quiet(store_read(st, "sales/daily"))
  version <- cor_version(fx$primary, "sales/daily")
  expect_identical(cor_version(fx$secondary[[1]], "sales/daily"), version)
  expect_identical(cor_version(fx$secondary[[2]], "sales/daily"), version)
  gets <- stub$log$path[stub$log$generic == "be_get" & grepl("part-", stub$log$path)]
  expect_false(anyDuplicated(gets) > 0)
  expect_identical(sort(gets, method = "radix"), cor_files(fx$primary, "sales/daily")$path)
  expect_rows_same(got, fx$data[["sales/daily"]])
})

test_that("store_read() copies a dataset's index table with it, and a raster as one file", {
  # B-T14 (red, every part). Red: nothing is copied: the secondary has no
  # index entry (first and second part) and no raster (third part).
  skip_below_level("default")
  skip_if_not_installed("terra")
  index <- index_name("shapes/polygons")

  # An empty secondary: the dataset and its index table.
  fx <- local_cor_store(datasets = "shapes/polygons")
  g_quiet(store_read(fx$st, "shapes/polygons"))
  catalog <- location_read(g_plain_backend(fx$secondary[[1]]))$catalog
  expect_true(index %in% catalog$dataset)
  expect_identical(cor_version(fx$secondary[[1]], index), cor_version(fx$primary, index))

  # A secondary that holds the dataset but not its index table.
  fx <- local_cor_store(datasets = "shapes/polygons", prefill = "shapes/polygons", connect = FALSE)
  cor_drop_entry(fx$secondary[[1]], index)
  st <- fx$connect()
  # setup: the dataset is held, its index table is not
  expect_identical(
    cor_version(fx$secondary[[1]], "shapes/polygons"),
    cor_version(fx$primary, "shapes/polygons")
  )
  expect_identical(cor_version(fx$secondary[[1]], index), character())
  g_quiet(store_read(st, "shapes/polygons"))
  expect_identical(cor_version(fx$secondary[[1]], index), cor_version(fx$primary, index))

  # A raster: one data file, the primary's.
  fx <- local_cor_store(datasets = "grids/sim")
  g_quiet(store_read(fx$st, "grids/sim"))
  expect_identical(cor_version(fx$secondary[[1]], "grids/sim"), cor_version(fx$primary, "grids/sim"))
  files <- cor_files(fx$secondary[[1]], "grids/sim")
  expect_identical(nrow(files), 1L)
  expect_identical(files$md5, cor_files(fx$primary, "grids/sim")$md5)
})

test_that("a failing copy warns and the read goes on from the primary; other errors propagate", {
  # B-T15 (red, both parts). Red: no copy is attempted, so no warning of
  # class rcs_warning_secondary_behind (first part), and land_location() is
  # never called, so no error of class "other_error" (second part).
  skip_below_level("default")
  g_no_wait()
  fx <- local_cor_store(connect = FALSE)
  sec <- fx$secondary[[1]]
  stub <- local_backend_stub(uri = sec, generic = "be_put", path = "part-", fail_at = 1:3)
  st <- fx$connect()
  catalog <- location_read(g_plain_backend(sec))$catalog
  expect_warning(
    suppressMessages(got <- store_read(st, "sales/daily")),
    regexp = 'datasets = "sales/daily"', fixed = TRUE,
    class = "rcs_warning_secondary_behind"
  )
  expect_rows_same(got, g_read_at(fx$primary, "sales/daily"))
  expect_identical(location_read(g_plain_backend(sec))$catalog, catalog)

  fx <- local_cor_store()
  local_mocked_bindings(land_location = function(...) {
    rlang::abort("Not a write error.", class = "other_error")
  })
  expect_error(g_quiet(store_read(fx$st, "sales/daily")), class = "other_error")
})

test_that("with a current secondary, store_read() and store_read(copy = FALSE) cost the same", {
  # B-T16 (red until `copy` exists, then the efficiency guard). The first
  # read passes today; the read with `copy = FALSE` aborts with the simple
  # error "filter expressions must be either an expression or a list of
  # expressions".
  skip_below_level("default")
  fx <- local_cor_store(prefill = "sales/daily")
  withr::local_options(rcs.trace = TRUE)
  cost <- function(...) {
    g_quiet(store_read(fx$st, "sales/daily", ...))
    c(
      backend_call = cor_trace_sum("backend_call"),
      catalog_read = cor_trace_sum("catalog_read"),
      bytes_up = cor_trace_sum("bytes_up")
    )
  }
  default <- cost()
  expect_identical(default[["bytes_up"]], 0)
  off <- cost(copy = FALSE)
  expect_identical(off, default)
})

test_that("a read refused by its arguments copies nothing", {
  # B-T17 (guard for D-B9; passes today because nothing copies yet).
  skip_below_level("default")
  skip_if_not_installed("terra")
  fx <- local_cor_store(datasets = c("sales/daily", "grids/sim"))
  sec <- fx$secondary[[1]]
  expect_error(store_read(fx$st, "grids/sim", columns = cover), class = "rcs_error_argument")
  expect_identical(g_listed(sec), character())
  expect_error(store_read(fx$st, "grids/sim", cover > 1), class = "rcs_error_argument")
  expect_identical(g_listed(sec), character())
  expect_error(store_read(fx$st, "no/such", copy = TRUE), class = "rcs_error_dataset_not_found")
  expect_identical(g_listed(sec), character())
  expect_error(
    store_read(fx$st, "sales/daily", version = "not-a-version", copy = TRUE),
    class = "rcs_error_argument"
  )
  expect_identical(g_listed(sec), character())
})

test_that("a windowed read of a class map copies the whole file first, unless it is above the limit or copy = FALSE", {
  # B-T18. (a) red: the secondary stays empty, no "Copying" message, the
  # window is read from the primary. (b) red: no "above the" message (its
  # other checks pass today). (c) guard once `copy` exists; today it aborts:
  # `copy = FALSE` is taken as a filter, which a raster refuses ("is a
  # raster: `...` does not apply", class rcs_error_argument).
  skip_below_level("default")
  skip_if_not_installed("terra")
  box <- cor_box()
  withr::local_options(rcs.trace = TRUE)

  # (a) Empty secondary, default limit: the whole file is copied first.
  fx <- local_cor_store(datasets = "grids/cover")
  sec <- fx$secondary[[1]]
  whole <- fx$data[["grids/cover"]]
  reference <- g_read_at(fx$primary, "grids/cover", intersects = box)
  withr::local_options(rcs.quiet = FALSE)
  expect_message(
    expect_message(got <- store_read(fx$st, "grids/cover", intersects = box), "Copying"),
    "Reading .* from secondary"
  )
  opened <- cor_opened_at()
  expect_identical(cor_version(sec, "grids/cover"), cor_version(fx$primary, "grids/cover"))
  files <- cor_files(sec, "grids/cover")
  expect_identical(nrow(files), 1L)
  expect_identical(files$md5, cor_files(fx$primary, "grids/cover")$md5)
  expect_identical(opened, fx$st$secondary[[1]]$uri)
  expect_cor_window(got, reference, whole)

  # (b) Above the limit: nothing copied, the window comes from the primary.
  fx <- local_cor_store(datasets = "grids/cover")
  sec <- fx$secondary[[1]]
  reference <- g_read_at(fx$primary, "grids/cover", intersects = box)
  withr::local_options(rcs.copy_on_read_max_bytes = cor_bytes(fx$primary, "grids/cover") - 1)
  expect_message(got <- store_read(fx$st, "grids/cover", intersects = box), "above the")
  expect_identical(cor_opened_at(), fx$st$primary$uri)
  expect_identical(list.files(sec, pattern = "\\.tif$", recursive = TRUE), character())
  expect_cor_window(got, reference, whole)

  # (c) copy = FALSE: nothing copied, no copy line (guard).
  withr::local_options(rcs.copy_on_read_max_bytes = 2e9)
  fx <- local_cor_store(datasets = "grids/cover")
  sec <- fx$secondary[[1]]
  reference <- g_read_at(fx$primary, "grids/cover", intersects = box)
  msgs <- cor_messages(got <- store_read(fx$st, "grids/cover", intersects = box, copy = FALSE))
  expect_false(any(grepl("Copying|above the", msgs)))
  expect_identical(list.files(sec, pattern = "\\.tif$", recursive = TRUE), character())
  expect_cor_window(got, reference, whole)
})

test_that("against a bucket primary, a table is copied to a local secondary and a class map window is read from the bucket or the copy", {
  # B-T19 (red; level `full`, bucket; written in WP4b, first run by WP5-V).
  # Red: nothing is copied; the secondary stays empty and every read comes
  # from the bucket. Touches only its own prefix `rcs-test-<random>/` of
  # RCS_TEST_GCS, which `local_test_bucket()` removes.
  skip_below_level("full")
  be <- local_test_bucket()
  secondary <- file.path(withr::local_tempdir(), "copy")
  suppressMessages(store_create(secondary))
  writer <- suppressMessages(store_connect(be$uri, create = TRUE))
  x <- g_sim(30, 1)
  g_write(writer, x)
  whole <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE)
  suppressMessages(store_write(writer, whole, "grids/cover",
    title = "Cover", description = "Simulated class map.", nodata = 0
  ))
  box <- cor_box()
  reference <- suppressMessages(store_read(writer, "grids/cover", intersects = box))
  st <- suppressMessages(store_connect(be$uri, secondary = secondary))
  version <- function(dataset) st$primary$catalog$version[st$primary$catalog$dataset == dataset]

  # The table is copied, then read.
  got <- suppressMessages(store_read(st, "sales/daily"))
  expect_identical(cor_version(secondary, "sales/daily"), version("sales/daily"))
  expect_rows_same(got, x)

  # Above the limit: the window is read from the bucket, no .tif is fetched.
  gets <- character()
  bucket_get <- utils::getS3method("be_get", "rcs_backend_gcs", envir = environment(be_put))
  testthat::local_mocked_s3_method("be_get", "rcs_backend_gcs", function(be, path, dest) {
    gets <<- c(gets, path)
    bucket_get(be, path, dest)
  })
  withr::local_options(rcs.trace = TRUE)
  withr::with_options(list(rcs.copy_on_read_max_bytes = 1), {
    got <- suppressMessages(store_read(st, "grids/cover", intersects = box))
    expect_identical(cor_opened_at(), st$primary$uri)
  })
  expect_false(any(grepl("\\.tif$", gets)))
  expect_identical(list.files(secondary, pattern = "\\.tif$", recursive = TRUE), character())
  expect_cor_window(got, reference, whole)

  # The default limit: the file is copied, the window is read from the copy.
  got <- suppressMessages(store_read(st, "grids/cover", intersects = box))
  expect_identical(cor_opened_at(), st$secondary[[1]]$uri)
  expect_identical(cor_version(secondary, "grids/cover"), version("grids/cover"))
  expect_cor_window(got, reference, whole)
})

test_that("store_read() brings a secondary's entry of the same version up to the primary's without sending a file", {
  # B-T20. Red: no "Updating the catalog entry" message, and the secondary's
  # entry stays the old one (its own catalog and a connection to it alone
  # show the old label). The label of the read itself, the zero data puts and
  # the second read pass today. Guard part: a secondary whose entry was
  # updated later than the primary's is left as it is, with nothing printed.
  skip_below_level("default")
  skip_if_not_installed("terra")
  relabel <- function(fx, path, labels) {
    x <- terra::deepcopy(fx$data[["grids/cover"]])
    levels(x) <- data.frame(value = 1:5, label = labels)
    terra::coltab(x, layer = 1) <- data.frame(value = 1:5, col = sim_landcover_colors)
    names(x) <- "cover"
    suppressMessages(store_write(g_connect(path), x, "grids/cover",
      title = "grids/cover", description = "Simulated grids/cover", nodata = 0, mode = "replace"
    ))
  }
  labels <- c("lake", sim_landcover_labels[-1])
  entry_at <- function(path) cor_entry(location_read(g_plain_backend(path)), "grids/cover")

  fx <- local_cor_store(datasets = "grids/cover", prefill = "grids/cover", connect = FALSE)
  sec <- fx$secondary[[1]]
  relabel(fx, fx$primary, labels)
  stub <- local_backend_stub(uri = sec)
  st <- fx$connect()
  primary_entry <- cor_entry(st$primary, "grids/cover")
  # setup: the same version, another entry
  expect_identical(cor_entry(st$secondary[[1]], "grids/cover")$version, primary_entry$version)
  expect_false(identical(cor_entry(st$secondary[[1]], "grids/cover")$columns, primary_entry$columns))

  withr::local_options(rcs.quiet = FALSE)
  stub_reset(stub)
  msgs <- cor_messages(got <- store_read(st, "grids/cover"))
  expect_match(msgs, "Updating the catalog entry", all = FALSE)
  expect_false(any(grepl("Copying", msgs)))
  expect_identical(as.character(terra::cats(got)[[1]]$label), labels)
  expect_identical(g_data_puts(stub), 0L)
  expect_identical(entry_at(sec), primary_entry)
  read <- g_read_at(sec, "grids/cover")
  expect_identical(as.character(terra::cats(read)[[1]]$label), labels)

  msgs <- cor_messages(store_read(st, "grids/cover"))
  expect_false(any(grepl("Updating", msgs)))

  # Guard: the secondary's entry was updated after the primary's.
  fx <- local_cor_store(datasets = "grids/cover", prefill = "grids/cover", connect = FALSE)
  sec <- fx$secondary[[1]]
  relabel(fx, fx$primary, labels)
  relabel(fx, sec, c("sea", sim_landcover_labels[-1]))
  st <- fx$connect()
  before <- entry_at(sec)
  primary_entry <- cor_entry(st$primary, "grids/cover")
  # setup: the same version, the secondary's entry the later one
  expect_identical(before$version, primary_entry$version)
  expect_gt(as.numeric(before$updated), as.numeric(primary_entry$updated))
  msgs <- cor_messages(store_read(st, "grids/cover"))
  expect_false(any(grepl("Updating|Copying", msgs)))
  expect_identical(entry_at(sec), before)
})
