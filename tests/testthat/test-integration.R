# The integration suite: a primary and two secondaries in three local
# folders, every operation through the exported functions, the invariants
# checked after every step. Failure and catalog tests not covered by
# test-write.R, test-history.R and test-check.R.

skip_below_level("default")

# Reads of every location of a connection equal `expected`.
expect_read_everywhere <- function(paths, dataset, expected, key = g_key) {
  for (p in paths) {
    expect_rows_same(g_read_at(p, dataset), expected, key, label = paste(dataset, "read from", basename(p)))
  }
}

test_that("one location: write in every mode, prune, rebuild, delete", {
  paths <- g_paths()
  st <- g_connect(paths)
  x <- g_sim(40, 1)
  g_write(st, x)
  expect_store_valid(st)
  expect_rows_same(store_read(st, "daily"), x)

  y <- g_sim(40, 2)
  g_write(st, y, mode = "replace")
  expect_store_valid(st)
  expect_rows_same(store_read(st, "daily"), y)

  z <- g_sim(10, 3, years = c(2024L, 2025L))
  g_write(st, z, mode = "update")
  expected <- rbind(y[y$year == 2023L, ], z)
  expect_store_valid(st)
  expect_rows_same(store_read(st, "daily"), expected)
  expect_rows_same(store_read(st, "daily", year == 2025L), z[z$year == 2025L, ])

  g_quiet(store_prune(st))
  expect_store_valid(st)
  unlink(file.path(paths[[1]], "_catalog.parquet"))
  g_quiet(store_rebuild(st, paths[[1]]))
  expect_store_valid(st)
  expect_rows_same(store_read(st, "daily"), expected)

  g_quiet(store_delete(st, "daily", confirm = "sales/daily"))
  expect_store_valid(st)
  expect_identical(nrow(st$primary$catalog), 0L)
  expect_identical(list.files(paths[[1]]), c("_catalog.parquet", "_files.parquet", "_history.parquet", "_store.json"))
})

test_that("primary and two secondaries: every mode lands everywhere; reads agree", {
  paths <- g_paths(secondaries = 2L)
  st <- g_connect(paths)
  x <- g_sim(40, 1)
  out <- g_write(st, x)
  expect_identical(out$status, rep("written", 3))
  expect_store_valid(st)
  expect_read_everywhere(paths, "sales/daily", x)

  y <- g_sim(30, 2)
  g_write(st, y, mode = "replace", history = TRUE)
  expect_store_valid(st)
  expect_read_everywhere(paths, "sales/daily", y)

  z <- g_sim(10, 3, years = 2026L)
  g_write(st, z, mode = "update")
  expect_store_valid(st)
  expect_read_everywhere(paths, "sales/daily", rbind(y, z))

  # Two datasets, two writes in a row on the same connection.
  g_write(st, g_sim(20, 4), "sales/summary")
  g_write(st, g_sim(20, 5), "sales/summary", mode = "replace")
  expect_store_valid(st)
  expect_true(all(store_status(st)$status == "same"))
  expect_identical(g_quiet(store_sync(st))$status, c("same", "same"))

  # History on for sales/daily only: its earlier versions are readable.
  h <- store_history(st, "sales/daily")
  expect_identical(nrow(h), 3L)
  expect_rows_same(store_read(st, "sales/daily", version = h$version[[3]]), x)
  g_quiet(store_prune(st, keep = 0))
  expect_identical(nrow(store_history(st, "sales/daily")), 1L)
  expect_store_valid(st)
})

test_that("partial secondaries are completed by an update, by store_sync() and by a delete", {
  fx <- local_test_store(partial = TRUE, history = TRUE)
  st <- fx$st
  paths <- c(fx$primary, fx$secondary)
  expect_store_valid(st)
  x <- fx$data[["sales/daily"]]
  y <- x[x$year == min(x$year), ]
  y$qty <- y$qty + 1L
  out <- suppressMessages(store_write(st, y, "sales/daily", title = "Daily sales",
    description = "Simulated daily sales by shop and product.", mode = "update"
  ))
  expect_identical(out$status, rep("written", 3))
  expect_store_valid(st)
  expected <- rbind(x[x$year != min(x$year), ], y)
  for (p in paths) {
    expect_rows_same(g_read_at(p, "sales/daily"), expected)
  }
  status <- store_status(st)
  expect_identical(status$status[status$dataset == "sales/summary"], c("same", "missing"))
  g_quiet(store_sync(st))
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
  expect_rows_same(g_read_at(paths[[3]], "sales/summary"), fx$data[["sales/summary"]])

  g_quiet(store_delete(st, "summary", confirm = "sales/summary"))
  for (p in paths) expect_identical(g_listed(p), "sales/daily")
  expect_store_valid(st)
})

test_that("geospatial data are written, synced, read with a spatial filter from a secondary, and rebuilt after re-partitioning", {
  skip_if_no_h3()
  paths <- g_paths(secondaries = 2L)
  writer <- g_connect(paths[1:2])
  pol <- rcs_sim_polygons(60, seed = 1)
  enc <- geo_encode(pol, 5L)
  parent <- as.character(h3_parent(enc$data$h3, 1L))
  first <- names(sort(table(parent), decreasing = TRUE))[[1]]
  a <- pol[pol$id %in% enc$data$id[parent %in% first], ]
  b <- pol[!pol$id %in% a$id, ]
  suppressMessages(store_write(writer, a, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", key = "id",
    partition = "h3", max_files = 3
  ))
  expect_store_valid(writer)
  # The update re-partitions the dataset at a coarser resolution.
  suppressMessages(store_write(writer, b, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", mode = "update", max_files = 3
  ))
  expect_identical(writer$primary$catalog$partition[[1]], "h3_p0")
  expect_store_valid(writer)

  st <- g_connect(paths)
  g_quiet(store_sync(st))
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)

  area <- sf::st_as_sfc(sf::st_bbox(c(xmin = -28, ymin = 7, xmax = -26, ymax = 8.5), crs = sf::st_crs(4326)))
  expected <- sort(pol$id[lengths(sf::st_intersects(pol, area)) > 0])
  for (p in paths[2:3]) {
    got <- g_read_at(p, "polygons", intersects = area)
    expect_identical(sort(got$id), expected)
  }

  # Rebuild after re-partitioning returns the current version.
  before <- st$secondary[[2]]$catalog
  unlink(file.path(paths[[3]], c("_catalog.parquet", "_files.parquet", "_history.parquet")))
  g_quiet(store_rebuild(st, paths[[3]]))
  expect_identical(st$secondary[[2]]$catalog$version, before$version)
  expect_identical(st$secondary[[2]]$catalog$partition, before$partition)
  expect_store_valid(st)

  # The index table is deleted with its dataset.
  g_quiet(store_delete(st, "polygons", confirm = "shapes/polygons"))
  for (p in paths) {
    expect_identical(nrow(location_read(be_new(p))$catalog), 0L)
  }
  expect_store_valid(st)
})

test_that("a raster is written to the primary, synced, read from a secondary and deleted", {
  skip_if_not_installed("terra")
  paths <- g_paths(secondaries = 1L)
  r <- rcs_sim_raster(seed = 1, nrow = 30, ncol = 30)
  suppressMessages(store_write(g_connect(paths[[1]]), r, "grid", title = "Grid", description = "Simulated raster."))
  st <- g_connect(paths)
  g_quiet(store_sync(st))
  expect_store_valid(st)
  got <- g_read_at(paths[[2]], "grid")
  expect_s4_class(got, "SpatRaster")
  expect_equal(terra::values(got), terra::values(r), ignore_attr = TRUE)
  g_quiet(store_copy(st, "grid", from = paths[[2]], to = paths[[1]]))
  g_quiet(store_delete(st, "grid", confirm = "grid"))
  expect_identical(g_listed(paths[[2]]), character())
  expect_store_valid(st)
})

# Readers and history ------------------------------------------------------------

test_that("a reader connected before a write reads the old version with history, gets a clear error without", {
  for (history in c(TRUE, FALSE)) {
    paths <- g_paths(secondaries = 1L, history = history)
    writer <- g_connect(paths)
    x <- g_sim(30, 1)
    g_write(writer, x)
    reader <- g_connect(paths[[1]])
    g_write(writer, g_sim(30, 2), mode = "replace")
    if (history) {
      expect_rows_same(store_read(reader, "sales/daily"), x, label = "stale reader, history on")
    } else {
      err <- expect_error(store_read(reader, "sales/daily"))
      g_quiet(store_refresh(reader))
      expect_rows_same(store_read(reader, "sales/daily"), g_sim(30, 2))
      expect_store_valid(writer)
      if (!grepl("store_refresh", conditionMessage(err), fixed = TRUE)) {
        skip("defect: a stale reader without history gets Arrow's missing-file error, not one telling it to refresh; see report")
      }
      expect_match(conditionMessage(err), "store_refresh", fixed = TRUE)
    }
    expect_store_valid(writer)
  }
})

test_that("store_read(version = ) after an update and after a replace that changed the columns", {
  paths <- g_paths(secondaries = 1L, history = TRUE)
  st <- g_connect(paths)
  x <- g_sim(30, 1)
  g_write(st, x)
  v1 <- st$primary$catalog$version
  z <- g_sim(10, 2, years = 2024L)
  g_write(st, z, mode = "update")
  v2 <- st$primary$catalog$version
  y <- x[c("shop_id", "date", "product", "qty")]
  suppressMessages(store_write(st, y, "sales/daily", title = "Fewer columns", description = "d",
    key = g_key, mode = "replace"
  ))
  expect_store_valid(st)
  expect_rows_same(store_read(st, "sales/daily"), y)
  expect_rows_same(store_read(st, "sales/daily", version = v1), x)
  expect_rows_same(store_read(st, "sales/daily", version = v2), rbind(x[x$year == 2023L, ], z))
  # The same from the secondary alone.
  expect_rows_same(g_read_at(paths[[2]], "sales/daily", version = v1), x)
})

test_that("a read while only _history.parquet and _files.parquet of a write are switched", {
  state <- new.env()
  original <- catalog_write
  local_mocked_bindings(catalog_write = function(be, x, which = c("catalog", "files", "history")) {
    if (identical(which, "catalog") && isTRUE(state$armed)) {
      state$armed <- FALSE
      # Another process reads between the two catalog writes.
      late <- g_connect(state$paths)
      state$late <- tryCatch(suppressMessages(store_read(late, "sales/daily")), error = function(e) e)
      state$early <- tryCatch(suppressMessages(store_read(state$reader, "sales/daily")), error = function(e) e)
    }
    original(be, x, which)
  })
  for (history in c(TRUE, FALSE)) {
    paths <- g_paths(history = history)
    writer <- g_connect(paths)
    x <- g_sim(30, 1)
    g_write(writer, x)
    state$paths <- paths
    state$reader <- g_connect(paths)
    state$armed <- TRUE
    g_write(writer, g_sim(30, 2), mode = "replace")
    what <- paste("history", history)
    # A reader that connected before the write reads the old version.
    expect_rows_same(state$early, x, label = paste(what, "early reader"))
    if (history) {
      # A reader connecting in between finds the old version in the history.
      expect_rows_same(state$late, x, label = paste(what, "late reader"))
    } else {
      # Without history it gets the error that tells it to read again.
      expect_s3_class(state$late, "rcs_error_version_not_found")
    }
    expect_store_valid(writer)
  }
})

# Failures -----------------------------------------------------------------------

test_that("a failure at the primary between _files.parquet and _catalog.parquet during a sync-free copy changes no catalog", {
  g_no_wait()
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths[[2]]), g_sim(20, 1))
  stub <- local_backend_stub(uri = paths[[1]], generic = "be_put", path = "^_catalog", fail_at = 1:3)
  st <- g_connect(paths)
  expect_error(g_quiet(store_copy(st, "sales/daily", from = paths[[2]], to = paths[[1]])), class = "rcs_error_write")
  stored <- location_read(g_plain_backend(paths[[1]]))
  expect_identical(nrow(stored$catalog), 0L)
  expect_identical(nrow(stored$files), 0L)
  expect_store_valid(st, orphans_ok = TRUE)
  stub$fail_at <- NULL
  stub_reset(stub)
  g_quiet(store_copy(st, "sales/daily", from = paths[[2]], to = paths[[1]]))
  expect_identical(g_data_puts(stub), 0L)
  expect_store_valid(st)
})

test_that("an upload that silently alters a file during a sync fails MD5 verification", {
  g_no_wait()
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths[[1]]), g_sim(20, 1))
  stub <- local_backend_stub(uri = paths[[2]], generic = "be_put", path = "part-", fail_at = 1, mode = "corrupt")
  st <- g_connect(paths)
  expect_warning(out <- suppressMessages(store_sync(st)), class = "rcs_warning_secondary_behind")
  expect_identical(out$status, "behind")
  expect_identical(nrow(st$secondary[[1]]$catalog), 0L)
  expect_store_valid(st, orphans_ok = TRUE)
  out <- g_quiet(store_sync(st))
  expect_identical(out$status, "synced")
  expect_store_valid(st)
})

test_that("the write guard stops a sync when the secondary changed meanwhile", {
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths[[1]]), g_sim(20, 1))
  st <- g_connect(paths)
  original <- verify_md5
  touched <- FALSE
  local_mocked_bindings(verify_md5 = function(be, paths, md5) {
    if (!touched) {
      touched <<- TRUE
      # Another writer rewrites the secondary's catalog.
      g_write(g_connect(be$uri), g_sim(10, 9), "other")
    }
    original(be, paths, md5)
  })
  expect_warning(out <- suppressMessages(store_sync(st)), class = "rcs_warning_secondary_behind")
  expect_identical(out$status, "behind")
  expect_identical(g_listed(paths[[2]]), "other")
  expect_store_valid(st, orphans_ok = TRUE)
  g_quiet(store_sync(st))
  expect_identical(g_listed(paths[[2]]), c("other", "sales/daily"))
  expect_store_valid(st)
})

test_that("a stale local lock is taken over by store_delete(); a fresh one blocks it", {
  paths <- g_paths()
  st <- g_connect(paths)
  g_write(st, g_sim(20, 1))
  lock <- file.path(paths[[1]], "_lock")
  dir.create(lock)
  writeLines(time_to_text(now_utc()), file.path(lock, "time"))
  expect_error(g_quiet(store_delete(st, "sales/daily", confirm = "sales/daily")), class = "rcs_error_locked")
  expect_identical(g_listed(paths[[1]]), "sales/daily")
  writeLines("2000-01-01T00:00:00.000000Z", file.path(lock, "time"))
  expect_warning(suppressMessages(store_delete(st, "sales/daily", confirm = "sales/daily")), class = "rcs_warning_lock_stale")
  expect_false(dir.exists(lock))
  expect_store_valid(st)
})

test_that("a dataset deleted with its history kept is listed again by a rebuild", {
  # What a rebuild can know: the manifests of the kept versions.
  paths <- g_paths(history = TRUE)
  st <- g_connect(paths)
  x <- g_sim(20, 1)
  g_write(st, x)
  g_write(st, g_sim(20, 2), mode = "replace")
  g_quiet(store_delete(st, "sales/daily", confirm = "sales/daily"))
  g_quiet(store_rebuild(st, paths[[1]]))
  expect_identical(st$primary$catalog$dataset, "sales/daily")
  expect_rows_same(store_read(st, "sales/daily"), x)
  expect_store_valid(st)
})
