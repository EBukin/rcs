# Primary-only writes (plan 0005, Part C). Each test names its id (C-Tn) and
# whether it is red (fails before the change, for the reason given) or a
# guard (passes before and after). Most red tests stop today at their first
# `store_write(..., locations = "primary")`, with the error
# `unused argument (locations = "primary")`: `store_write()` has no argument
# `locations` yet. Checks that do not need the argument come first.
#
# Helpers: `helper-copy-on-read.R` (`cor_*()`, `local_test_bucket()`),
# `helper-model.R` (`g_*()`).

# A primary and `secondaries` local secondary folders under
# `withr::local_tempdir()` of `frame` (`g_paths()`).
#   fx$writer       a connection to every folder, made now
#   fx$connect()    a new quiet connection to every folder; `cloud = TRUE`
#                   fakes the primary as a cloud backend (`cor_cloud()`)
#   fx$root, fx$primary, fx$secondary   the folders
po_store <- function(secondaries = 1L, frame = parent.frame()) {
  paths <- g_paths(secondaries = secondaries, frame = frame)
  list(
    writer = g_connect(paths),
    connect = function(cloud = FALSE) {
      st <- g_quiet(store_connect(paths[[1]], secondary = paths[-1]))
      if (cloud) cor_cloud(st)
      st
    },
    root = dirname(paths[[1]]),
    primary = paths[[1]],
    secondary = paths[-1]
  )
}

# `g_scrub()`, the times of the print of a connection (no seconds), and the
# R and rcs versions of "Written by", fixed as in `fix_catalogs()` of test-inspect.R.
po_scrub <- function(root) {
  scrub <- g_scrub(root)
  function(x) {
    x <- gsub("[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}", "<date>", scrub(x))
    gsub("R [0-9.]+, rcs [0-9.]+", "R 4.6.2, rcs 0.0.0.9000", x)
  }
}

# The `primary_only` value of `dataset` in the catalog stored at `path`
# (NULL while the column does not exist).
po_flag <- function(path, dataset) {
  catalog <- location_read(g_plain_backend(path))$catalog
  catalog[["primary_only"]][catalog$dataset == dataset]
}

# Files stored at `path` below the folder of `dataset`.
po_files_of <- function(path, dataset) {
  files <- list.files(path, recursive = TRUE, all.files = TRUE)
  files[startsWith(files, paste0(dataset, "/"))]
}

test_that("store_write(locations = \"primary\") writes a table to the primary only", {
  # C-T1 (red). Red: unused argument (locations = "primary"); the setup
  # checks pass, nothing after the write is reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  # setup: both locations empty
  expect_identical(g_listed(fx$primary), character())
  expect_identical(g_listed(sec), character())
  before <- cor_state(sec)

  withr::local_options(rcs.quiet = FALSE)
  msgs <- cor_messages(expect_message(
    out <- store_write(fx$writer, g_sim(30, 1), "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      key = g_key, partition = "year", locations = "primary"
    ),
    "kept in the primary only"
  ))
  expect_identical(g_listed(fx$primary), "sales/daily")
  expect_identical(g_listed(sec), character())
  expect_identical(po_files_of(sec, "sales/daily"), character())
  expect_identical(cor_state(sec), before)
  row <- out[out$role == "secondary", ]
  expect_identical(row$status, "primary only")
  expect_identical(row$uploaded, 0)
  expect_identical(row$bytes, 0)
  expect_true(is.na(row$files))
  expect_false(any(grepl("behind", msgs)))
  expect_store_valid(fx$writer)
})

test_that("a primary-only dataset is flagged in the catalog and its manifest only; ordinary datasets keep their bytes and values", {
  # C-T2 (red). The ordinary manifest without the field passes today (guard).
  # Red, reached today: a catalog read without the column has no
  # `primary_only` (NULL instead of NA). Then red: unused argument
  # (locations = "primary"); the later checks are not reached.
  skip_below_level("default")
  fx <- po_store()
  g_write(fx$writer, g_sim(15, 3), "sales/summary")
  plain <- g_plain_backend(fx$primary)
  catalog <- location_read(plain)$catalog
  ordinary <- catalog[catalog$dataset == "sales/summary", ]
  manifest <- file.path(fx$primary, manifest_path("sales/summary", ordinary$version))
  manifest_md5 <- unname(tools::md5sum(manifest))
  expect_false(grepl("primary_only", paste(readLines(manifest, warn = FALSE), collapse = "\n"), fixed = TRUE))

  # A catalog file written before the column (as test-schema.R does for
  # geocode_engine) is read with NA and validated.
  expect_true("primary_only" %in% names(catalog_schema()))
  old <- ordinary[setdiff(names(ordinary), "primary_only")]
  expect_no_error(schema_validate(old, "catalog"))
  back <- schema_as_tibble(old, "catalog")
  expect_identical(names(back), names(catalog_schema()))
  expect_identical(back[["primary_only"]], NA)
  path <- withr::local_tempfile(fileext = ".parquet")
  table <- schema_as_arrow(ordinary, "catalog")
  arrow::write_parquet(table[, setdiff(names(table), "primary_only")], path)
  read <- schema_as_tibble(arrow::read_parquet(path, as_data_frame = FALSE), "catalog")
  expect_identical(read[["primary_only"]], NA)
  expect_identical(names(schema_as_arrow(read, "catalog")), names(catalog_schema()))

  # The flag: TRUE for the primary-only dataset, NA for the ordinary one.
  g_write(fx$writer, g_sim(30, 1), "sales/daily", locations = "primary")
  expect_identical(po_flag(fx$primary, "sales/daily"), TRUE)
  expect_identical(po_flag(fx$primary, "sales/summary"), NA)
  catalog <- location_read(plain)$catalog
  expect_identical(catalog[catalog$dataset == "sales/summary", names(ordinary)], ordinary)
  expect_identical(unname(tools::md5sum(manifest)), manifest_md5)
  version <- cor_version(fx$primary, "sales/daily")
  expect_identical(manifest_read(plain, "sales/daily", version)$entry[["primary_only"]], TRUE)
  text <- readLines(file.path(fx$primary, manifest_path("sales/daily", version)), warn = FALSE)
  expect_true(grepl("primary_only", paste(text, collapse = "\n"), fixed = TRUE))

  # Where a dataset is kept does not change its files or its version.
  other <- g_paths()
  g_write(g_connect(other), g_sim(30, 1), "sales/daily")
  expect_identical(cor_version(other, "sales/daily"), version)
  expect_identical(cor_files(other, "sales/daily"), cor_files(fx$primary, "sales/daily"))
  expect_store_valid(fx$writer)
})

test_that("store_status(), store_datasets(), the print and store_describe() report \"primary only\"", {
  # C-T3. The first part (a store without a primary-only dataset prints the
  # legend line as today) is a guard, reached and passing today. Red: unused
  # argument (locations = "primary"); the rest is not reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  g_write(fx$writer, g_sim(30, 1), "sales/daily")
  g_snapshot_output()
  withr::local_timezone("UTC")
  s <- status_symbols()
  legend <- function(st) grep("^Secondary copies:", utils::capture.output(print(st)), value = TRUE)
  expect_identical(
    legend(fx$connect()),
    sprintf(
      "Secondary copies: %s same, %s differs, %s missing, %s unavailable.",
      s[["same"]], s[["differs"]], s[["missing"]], s[["unavailable"]]
    )
  )

  g_write(fx$writer, g_sim(15, 3), "sales/summary", locations = "primary")
  cor_drop_entry(sec, "sales/daily")
  st <- fx$connect()
  status <- store_status(st)
  expect_identical(
    status$status[match(c("sales/daily", "sales/summary"), status$dataset)],
    c("missing", "primary only")
  )
  datasets <- store_datasets(st)
  expect_identical(
    datasets$in_1[match(c("sales/daily", "sales/summary"), datasets$dataset)],
    c("missing", "primary only")
  )
  printed <- utils::capture.output(print(st))
  expect_identical(
    legend(st),
    sprintf(
      "Secondary copies: %s same, %s differs, %s missing, P primary only, %s unavailable.",
      s[["same"]], s[["differs"]], s[["missing"]], s[["unavailable"]]
    )
  )
  expect_true(any(grepl("^\\s+summary\\s.*\\sP$", printed)))
  expect_identical(store_describe(st, "sales/summary")$locations$status, c("primary", "primary only"))
  expect_snapshot(
    {
      print(st)
      print(store_status(st))
      print(store_describe(st, "sales/summary"), n = 0)
    },
    transform = po_scrub(fx$root)
  )
})

test_that("a primary-only dataset stays so on later writes until locations = \"all\"; bad values abort", {
  # C-T4 (red). Red: unused argument (locations = "primary") at the first
  # write; nothing later is reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  stub <- local_backend_stub(uri = fx$primary)
  st <- fx$connect()
  g_write(st, g_sim(30, 1), "sales/daily", locations = "primary")

  x <- g_sim(30, 2)
  g_write(st, x, "sales/daily", mode = "replace")
  expect_identical(g_listed(sec), character())
  expect_identical(po_flag(fx$primary, "sales/daily"), TRUE)
  version <- cor_version(fx$primary, "sales/daily")

  stub_reset(stub)
  g_write(st, x, "sales/daily", mode = "replace", locations = "all")
  expect_identical(cor_version(fx$primary, "sales/daily"), version)
  expect_identical(cor_version(sec, "sales/daily"), version)
  expect_identical(po_flag(fx$primary, "sales/daily"), NA)
  expect_identical(po_flag(sec, "sales/daily"), NA)
  expect_identical(g_data_puts(stub), 0L)
  expect_store_valid(st)

  write <- function(locations) {
    store_write(st, x, "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      mode = "replace", locations = locations
    )
  }
  expect_error(write("secondary"), class = "rcs_error_argument")
  expect_error(write(NA), class = "rcs_error_argument")
  expect_error(write(c("all", "primary")), class = "rcs_error_argument")
  expect_identical(cor_version(sec, "sales/daily"), version)
  expect_snapshot(write("secondary"), error = TRUE)
})

test_that("a primary-only replace leaves a secondary that holds the dataset as it was, and says so once", {
  # C-T5 (red). Red: unused argument (locations = "primary"); the setup
  # checks pass, nothing after the write is reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  g_write(fx$writer, g_sim(30, 1), "sales/daily")
  st <- fx$connect()
  # setup: the secondary holds the primary's version
  expect_identical(cor_version(sec, "sales/daily"), cor_version(fx$primary, "sales/daily"))
  before <- cor_state(sec)
  catalog <- location_read(g_plain_backend(sec))$catalog

  cor_snapshot_output()
  replace <- function(x) {
    store_write(st, x, "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      mode = "replace", locations = "primary"
    )
  }
  # expect_message() takes the first matching message; any other one would
  # reach `msgs`.
  msgs <- cor_messages(expect_message(replace(g_sim(30, 2)), "not updated by this primary-only write"))
  expect_false(any(grepl("not updated by this primary-only write", msgs)))
  expect_false(any(grepl("behind", msgs)))
  expect_identical(cor_state(sec), before)
  expect_identical(location_read(g_plain_backend(sec))$catalog, catalog)
  status <- store_status(st)
  expect_identical(status$status[status$dataset == "sales/daily"], "differs")
  expect_store_valid(st)
  expect_snapshot(invisible(replace(g_sim(30, 3))), transform = g_scrub(fx$root))
})

test_that("a geospatial dataset and its index table are both kept in the primary only", {
  # C-T6 (red). Red: unused argument (locations = "primary").
  # `rcs_sim_points()` has no index table (checked), so the polygons of
  # `local_cor_store()` are used (partition h3, with an index table).
  skip_below_level("default")
  skip_if_no_h3()
  fx <- po_store()
  sec <- fx$secondary[[1]]
  index <- index_name("shapes/polygons")
  g_quiet(store_write(fx$writer, rcs_sim_polygons(60, seed = 1), "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.",
    key = "id", partition = "h3", locations = "primary"
  ))
  catalog <- location_read(g_plain_backend(fx$primary))$catalog
  expect_true(index %in% catalog$dataset)
  expect_identical(po_flag(fx$primary, "shapes/polygons"), TRUE)
  expect_identical(po_flag(fx$primary, index), TRUE)
  expect_identical(
    manifest_read(g_plain_backend(fx$primary), index, cor_version(fx$primary, index))$entry[["primary_only"]],
    TRUE
  )
  expect_identical(location_read(g_plain_backend(sec))$catalog$dataset, character())
  expect_identical(po_files_of(sec, "shapes"), character())
  expect_store_valid(fx$writer)
})

test_that("store_read() of a primary-only raster reads from the cloud primary and says so; copy = TRUE copies it", {
  # C-T7 (red). Red: unused argument (locations = "primary"); nothing after
  # the write is reached.
  skip_below_level("default")
  skip_if_not_installed("terra")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  g_quiet(store_write(fx$writer, rcs_sim_raster(seed = 1, nrow = 20, ncol = 20), "grids/sim",
    title = "Grid", description = "Simulated grid.", locations = "primary"
  ))
  st <- fx$connect(cloud = TRUE)
  reference <- g_read_at(fx$primary, "grids/sim")

  cor_snapshot_output()
  msgs <- cor_messages(expect_message(got <- store_read(st, "grids/sim"), "kept in the primary only"))
  expect_false(any(grepl("Copying", msgs)))
  expect_identical(as.vector(terra::values(got)), as.vector(terra::values(reference)))
  expect_identical(g_listed(sec), character())
  expect_snapshot(invisible(store_read(st, "grids/sim")), transform = g_scrub(fx$root))
  expect_identical(g_listed(sec), character())

  msgs <- cor_messages(store_read(st, "grids/sim", copy = FALSE))
  expect_false(any(grepl("primary only", msgs)))
  expect_identical(g_listed(sec), character())

  g_quiet(store_read(st, "grids/sim", copy = TRUE))
  expect_identical(cor_version(sec, "grids/sim"), cor_version(fx$primary, "grids/sim"))
})

test_that("store_sync(all = TRUE) leaves a primary-only dataset out; datasets = copies it, and a default sync then keeps it fresh", {
  # C-T8 (red). Red: unused argument (locations = "primary"); the ordinary
  # writes of the setup pass, nothing after the write is reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  g_write(fx$writer, g_sim(30, 1), "sales/daily")
  g_write(g_connect(fx$primary), g_sim(20, 2), "sales/monthly")
  # setup: the secondary holds sales/daily only
  expect_identical(g_listed(sec), "sales/daily")
  g_write(fx$writer, g_sim(15, 3), "sales/summary", locations = "primary")
  st <- fx$connect()
  withr::local_options(rcs.quiet = FALSE)

  # The default sync copies nothing the secondary lacks.
  g_quiet(store_sync(st))
  expect_identical(g_listed(sec), "sales/daily")

  # all = TRUE copies the ordinary dataset only.
  msgs <- cor_messages(expect_message(out <- store_sync(st, all = TRUE), "primary-only"))
  expect_identical(g_listed(sec), c("sales/daily", "sales/monthly"))
  expect_identical(out$skipped[[1]], "sales/summary")
  expect_false(any(grepl("store_sync(st, all = TRUE)", msgs, fixed = TRUE)))
  expect_false(any(grepl("Synced only the datasets already", msgs, fixed = TRUE)))

  # Again: nothing to copy, only the primary-only dataset skipped (default 3).
  msgs <- cor_messages(out <- store_sync(st, all = TRUE))
  expect_identical(out$status, "same")
  expect_match(msgs, "1 primary-only dataset not copied", all = FALSE)
  expect_match(msgs, "Every secondary location is up to date.", all = FALSE, fixed = TRUE)
  expect_false(any(grepl("store_sync(st, all = TRUE)", msgs, fixed = TRUE)))
  expect_false(any(grepl("Synced only the datasets already", msgs, fixed = TRUE)))
  cor_snapshot_output()
  expect_snapshot(invisible(store_sync(st, all = TRUE)), transform = g_scrub(fx$root))

  # datasets = copies it, with its flag.
  g_quiet(store_sync(st, datasets = "sales/summary"))
  status <- store_status(st)
  expect_identical(status$status[status$dataset == "sales/summary"], "same")
  expect_identical(po_flag(sec, "sales/summary"), TRUE)

  # A new primary-only write leaves the copy behind; a default sync refreshes it.
  g_write(st, g_sim(15, 4), "sales/summary", mode = "replace", locations = "primary")
  expect_false(identical(cor_version(sec, "sales/summary"), cor_version(fx$primary, "sales/summary")))
  g_quiet(store_sync(st))
  expect_identical(cor_version(sec, "sales/summary"), cor_version(fx$primary, "sales/summary"))
  expect_store_valid(st)
})

test_that("with no secondary, locations = \"primary\" writes what a normal write does, apart from the flag", {
  # C-T9 (guard once the argument exists). Today: unused argument
  # (locations = "primary") at the second write; only the first, ordinary
  # write is reached.
  skip_below_level("default")
  a <- g_paths()
  b <- g_paths()
  x <- g_sim(30, 1)
  out_a <- g_write(g_connect(a), x, "sales/daily")
  out_b <- g_write(g_connect(b), x, "sales/daily", locations = "primary")
  cols <- c("role", "status", "files", "uploaded", "bytes")
  expect_identical(out_b[cols], out_a[cols])
  expect_identical(cor_version(b, "sales/daily"), cor_version(a, "sales/daily"))
  expect_identical(cor_files(b, "sales/daily"), cor_files(a, "sales/daily"))
  expect_identical(names(cor_state(b)), names(cor_state(a)))
  data_files <- function(state) state[grepl("part-", names(state))]
  expect_identical(data_files(cor_state(b)), data_files(cor_state(a)))
  entry <- function(path) {
    catalog <- location_read(g_plain_backend(path))$catalog
    catalog[setdiff(names(catalog), c("primary_only", "created", "updated"))]
  }
  expect_identical(entry(b), entry(a))
  expect_identical(po_flag(b, "sales/daily"), TRUE)
  expect_identical(po_flag(a, "sales/daily"), NA)
})

test_that("a primary-only write makes no backend call to a secondary and no warning for an unreachable one", {
  # C-T10 (red). Red: unused argument (locations = "primary") at the first
  # write; nothing later is reached.
  skip_below_level("default")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  stub <- local_backend_stub(uri = sec)
  st <- fx$connect()
  sec_uri <- st$secondary[[1]]$uri
  write <- function(x, dataset) {
    suppressMessages(store_write(st, x, dataset,
      title = dataset, description = paste("Simulated", dataset),
      key = g_key, partition = "year", locations = "primary"
    ))
  }
  withr::local_options(rcs.trace = TRUE)
  stub_reset(stub)
  write(g_sim(30, 1), "sales/daily")
  expect_identical(cor_trace_sum("bytes_up", location = sec_uri), 0)
  expect_gt(cor_trace_sum("bytes_up", location = st$primary$uri), 0)
  expect_identical(stub$calls, 0L)

  # Unreachable: every call to the secondary would fail.
  stub$fail_at <- seq_len(1000)
  stub_reset(stub)
  expect_no_warning(out <- write(g_sim(15, 3), "sales/summary"))
  expect_identical(out$status[out$role == "secondary"], "primary only")
  expect_identical(stub$calls, 0L)

  # Unavailable: still a row "primary only".
  location <- st$secondary[[1]]
  location$available <- FALSE
  store_set_location(st, location)
  expect_no_warning(out <- write(g_sim(20, 2), "sales/monthly"))
  expect_identical(out$status[out$role == "secondary"], "primary only")
  expect_identical(stub$calls, 0L)
})

test_that("a class map written to the primary only is read as a window from the cloud primary, with legend and colours", {
  # C-T11 (red). Red: unused argument (locations = "primary"); nothing after
  # the write is reached.
  skip_below_level("default")
  skip_if_not_installed("terra")
  fx <- po_store()
  sec <- fx$secondary[[1]]
  whole <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE)
  g_quiet(store_write(fx$writer, whole, "grids/cover",
    title = "Cover", description = "Simulated class map.", nodata = 0, locations = "primary"
  ))
  st <- fx$connect(cloud = TRUE)
  box <- cor_box()
  reference <- g_read_at(fx$primary, "grids/cover", intersects = box)

  withr::local_options(rcs.trace = TRUE)
  got <- g_quiet(store_read(st, "grids/cover", intersects = box))
  expect_identical(cor_opened_at(), st$primary$uri)
  expect_s4_class(got, "SpatRaster")
  expect_cor_window(got, reference, whole)

  all <- g_quiet(store_read(st, "grids/cover"))
  expect_identical(as.character(terra::cats(all)[[1]]$label), sim_landcover_labels)
  expect_true(terra::has.colors(all))
  ct <- terra::coltab(all)[[1]]
  ct <- ct[match(1:5, ct$value), ]
  expect_identical(grDevices::rgb(ct$red, ct$green, ct$blue, ct$alpha, maxColorValue = 255), sim_landcover_colors)

  expect_false("grids/cover" %in% location_read(g_plain_backend(sec))$catalog$dataset)
  expect_identical(list.files(sec, pattern = "\\.tif$", recursive = TRUE), character())
  version <- cor_version(fx$primary, "grids/cover")
  expect_false(file.exists(file.path(sec, manifest_path("grids/cover", version))))
})

test_that("against a bucket primary, a primary-only class map stays in the bucket and is read as a window through GDAL", {
  # C-T12 (red; level `full`, bucket; written in WP10, first run by WP11-V).
  # Red: unused argument (locations = "primary"). Touches only its own prefix
  # `rcs-test-<random>/` of RCS_TEST_GCS, which `local_test_bucket()` removes.
  skip_below_level("full")
  be <- local_test_bucket()
  secondary <- file.path(withr::local_tempdir(), "copy")
  suppressMessages(store_create(secondary))
  suppressMessages(store_connect(be$uri, create = TRUE))
  st <- suppressMessages(store_connect(be$uri, secondary = secondary))
  whole <- sim_landcover(file = withr::local_tempfile(fileext = ".tif"), legend = TRUE, colors = TRUE)
  write <- function(mode = "create") {
    suppressMessages(store_write(st, whole, "grids/cover",
      mode = mode, title = "Cover", description = "Simulated class map.", nodata = 0, locations = "primary"
    ))
  }
  write()
  expect_identical(sum(grepl("\\.tif$", be_list(be)$path)), 1L)
  expect_identical(po_files_of(secondary, "grids"), character())
  status <- store_status(st)
  expect_identical(status$status[status$dataset == "grids/cover"], "primary only")

  box <- cor_box()
  reference <- suppressMessages(store_read(suppressMessages(store_connect(be$uri)), "grids/cover", intersects = box))
  gets <- character()
  bucket_get <- utils::getS3method("be_get", "rcs_backend_gcs", envir = environment(be_put))
  testthat::local_mocked_s3_method("be_get", "rcs_backend_gcs", function(be, path, dest) {
    gets <<- c(gets, path)
    bucket_get(be, path, dest)
  })
  withr::local_options(rcs.trace = TRUE)
  got <- suppressMessages(store_read(st, "grids/cover", intersects = box))
  expect_identical(cor_opened_at(), st$primary$uri)
  expect_false(any(grepl("\\.tif$", gets)))
  expect_identical(list.files(secondary, pattern = "\\.tif$", recursive = TRUE), character())
  expect_cor_window(got, reference, whole)

  out <- write(mode = "replace")
  expect_identical(sum(out$uploaded), 0)
})

test_that("store_connect() gives no empty-secondary notice when the primary holds only primary-only datasets", {
  # C-T13. Part (a) is a guard reached and passing today (an ordinary dataset
  # alone: the notice is printed). Part (b) red: today it stops at unused
  # argument (locations = "primary"); after the argument, red because the
  # notice is printed. Part (c) guard, needs the argument (not reached today).
  skip_below_level("default")
  withr::local_options(rcs.quiet = FALSE)
  connect_messages <- function(fx) cor_messages(store_connect(fx$primary, secondary = fx$secondary))

  # (a) An ordinary dataset only.
  fx <- po_store()
  g_write(g_connect(fx$primary), g_sim(30, 1), "sales/daily")
  expect_match(connect_messages(fx), "is empty", all = FALSE)

  # (b) Primary-only datasets only.
  fx <- po_store()
  g_write(fx$writer, g_sim(30, 1), "sales/daily", locations = "primary")
  expect_identical(g_listed(fx$secondary[[1]]), character())
  expect_false(any(grepl("is empty", connect_messages(fx))))

  # (c) One ordinary dataset beside them.
  g_write(g_connect(fx$primary), g_sim(15, 3), "sales/summary")
  expect_match(connect_messages(fx), "is empty", all = FALSE)
})
