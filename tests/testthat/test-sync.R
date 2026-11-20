# store_sync(), store_copy(), store_delete() and store_rebuild(): behaviour,
# summaries and aborts (snapshots), failures and counters.

# store_sync() -------------------------------------------------------------------

test_that("store_sync() checks its arguments", {
  paths <- g_paths(secondaries = 1L)
  st <- g_connect(paths)
  g_snapshot_output()
  expect_snapshot(error = TRUE, transform = g_scrub(dirname(paths[[1]])), {
    store_sync(st, datasets = 1)
    store_sync(st, datasets = "nothing")
    store_sync(st, to = paths[[1]])
    store_sync(st, to = "elsewhere")
    store_sync(st, dry_run = NA)
    store_sync(list())
  })
})

test_that("store_sync() copies missing and differing datasets; a dry run changes nothing", {
  skip_below_level("default")
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  root <- dirname(fx$primary)
  status <- store_status(st)
  expect_identical(
    status$status[status$location == fx$secondary[[2]]],
    c("differs", "missing")
  )
  g_snapshot_output()
  expect_snapshot(dry <- store_sync(st, dry_run = TRUE), transform = g_scrub(root))
  expect_identical(dry$status, c("same", "to sync"))
  expect_identical(dry$datasets[[2]], c("sales/daily", "sales/summary"))
  expect_identical(store_status(st)$status, status$status)

  expect_snapshot(out <- store_sync(st), transform = g_scrub(root))
  expect_identical(out$status, c("same", "synced"))
  expect_identical(out$files, dry$files)
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
  expect_rows_same(
    g_read_at(fx$secondary[[2]], "sales/daily"),
    store_read(st, "sales/daily")
  )

  expect_snapshot(again <- store_sync(st), transform = g_scrub(root))
  expect_identical(again$status, c("same", "same"))
})

test_that("store_sync() on an identical secondary transfers nothing", {
  skip_below_level("default")
  fx <- local_test_store()
  withr::local_options(rcs.trace = TRUE, rcs.quiet = TRUE)
  out <- store_sync(fx$st)
  expect_identical(out$status, c("same", "same"))
  trace <- rcs_trace()
  expect_false(any(trace$counter == "backend_call" & trace$detail %in% c("be_put", "be_delete", "be_md5")))
  expect_false(any(trace$counter %in% c("bytes_up", "file_open")))
  # Only the catalogs of the three locations were read.
  gets <- trace[trace$counter == "backend_call" & trace$detail == "be_get", ]
  expect_identical(sum(gets$n), 6)
})

test_that("store_sync() follows datasets and to; index tables travel with their dataset", {
  skip_below_level("default")
  skip_if_no_h3()
  paths <- g_paths(secondaries = 2L)
  writer <- g_connect(paths[[1]])
  g_write(writer, g_sim(30, 1))
  pol <- rcs_sim_polygons(30, seed = 2)
  suppressMessages(store_write(writer, pol, "shapes/polygons", title = "Polygons", description = "d"))
  st <- g_connect(paths)
  out <- g_quiet(store_sync(st, datasets = "polygons", to = paths[[3]]))
  expect_identical(out$location, paths[[3]])
  expect_identical(out$datasets[[1]], "shapes/polygons")
  expect_identical(g_listed(paths[[3]]), "shapes/polygons")
  expect_identical(g_listed(paths[[2]]), character())
  expect_true("shapes/polygons__h3" %in% st$secondary[[2]]$catalog$dataset)
  expect_store_valid(st)

  # The primary drops the index table; a sync drops it in the secondary too.
  suppressMessages(store_write(writer, pol, "shapes/polygons",
    title = "Polygons", description = "d", geocode = FALSE, mode = "replace"
  ))
  store_refresh(st)
  g_quiet(store_sync(st))
  expect_identical(st$secondary[[2]]$catalog$dataset, c("sales/daily", "shapes/polygons"))
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
  read <- g_read_at(paths[[3]], "shapes/polygons")
  expect_s3_class(read, "sf")
  expect_setequal(read$id, pol$id)
})

test_that("store_sync() never deletes a dataset found only in a secondary", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths[[2]]), g_sim(20, 3), "only/here")
  st <- g_connect(paths)
  g_write(st, g_sim(20, 1))
  g_quiet(store_sync(st))
  expect_identical(g_listed(paths[[2]]), c("only/here", "sales/daily"))
  status <- store_status(st)
  expect_identical(status$status[status$dataset == "only/here"], "extra")
  expect_store_valid(st)
})

test_that("store_sync() repairs a secondary that failed during a write", {
  skip_below_level("default")
  g_no_wait()
  paths <- g_paths(secondaries = 2L)
  stub <- local_backend_stub(uri = paths[[2]], generic = "be_put", path = "part-", fail_at = 2:4)
  st <- g_connect(paths)
  expect_warning(g_write(st, g_sim(30, 1)), class = "rcs_warning_secondary_behind")
  expect_identical(store_status(st)$status, c("missing", "same"))
  expect_store_valid(st, orphans_ok = TRUE)
  stub$fail_at <- NULL
  stub_reset(stub)
  out <- g_quiet(store_sync(st))
  expect_identical(out$status, c("synced", "same"))
  # The file sent before the failure is reused.
  expect_identical(g_data_puts(stub), 1L)
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
})

test_that("a secondary failing during store_sync() warns, is reported behind, and the next call completes it", {
  skip_below_level("default")
  g_no_wait()
  paths <- g_paths(secondaries = 2L)
  g_write(g_connect(paths[[1]]), g_sim(30, 1))
  stub <- local_backend_stub(uri = paths[[2]], generic = "be_put", path = "part-", fail_at = 2:4)
  st <- g_connect(paths)
  g_snapshot_output()
  expect_snapshot(out <- store_sync(st), transform = g_scrub(dirname(paths[[1]])))
  expect_identical(out$status, c("behind", "synced"))
  expect_store_valid(st, orphans_ok = TRUE)
  stub$fail_at <- NULL
  stub_reset(stub)
  out <- g_quiet(store_sync(st))
  expect_identical(out$status, c("synced", "same"))
  expect_identical(g_data_puts(stub), 1L)
  expect_store_valid(st)
})

test_that("an unavailable secondary is skipped by store_sync()", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 2L)
  st <- g_connect(paths)
  g_write(st, g_sim(20, 1))
  location <- st$secondary[[1]]
  location$available <- FALSE
  location$catalog <- catalog_empty()
  location$files <- files_empty()
  location$token <- NA_character_
  store_set_location(st, location)
  out <- g_quiet(store_sync(st))
  expect_identical(out$status, c("unavailable", "same"))
})

# store_copy() -------------------------------------------------------------------

test_that("store_copy() checks its arguments", {
  paths <- g_paths(secondaries = 1L)
  st <- g_connect(paths)
  g_snapshot_output()
  expect_snapshot(error = TRUE, transform = g_scrub(dirname(paths[[1]])), {
    store_copy(st, "sales", from = paths[[1]], to = paths[[1]])
    store_copy(st, "sales", from = "elsewhere", to = paths[[2]])
    store_copy(st, "sales", from = paths[[1]], to = paths[[2]])
    store_copy(st, 1, from = paths[[1]], to = paths[[2]])
  })
})

test_that("store_copy() copies between any two locations, into the primary too", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 2L)
  root <- dirname(paths[[1]])
  st <- g_connect(paths)
  x <- g_sim(30, 1)
  g_write(st, x)
  y <- g_sim(30, 2)
  g_write(g_connect(paths[[2]]), y, mode = "replace")
  store_refresh(st)
  expect_identical(store_status(st)$status, c("differs", "same"))

  g_snapshot_output()
  expect_snapshot(out <- store_copy(st, "daily", from = paths[[2]], to = paths[[3]]), transform = g_scrub(root))
  expect_identical(out$status, "copied")
  expect_identical(out$uploaded, 2)
  expect_rows_same(g_read_at(paths[[3]], "sales/daily"), y)
  expect_store_valid(st)

  expect_snapshot(same <- store_copy(st, "sales/daily", from = paths[[2]], to = paths[[3]]), transform = g_scrub(root))
  expect_identical(same$status, "same")

  # Into the primary: the store's current version changes.
  out <- g_quiet(store_copy(st, "sales/daily", from = paths[[3]], to = paths[[1]]))
  expect_identical(out$uploaded, 2)
  expect_rows_same(store_read(st, "sales/daily"), y)
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
})

test_that("store_copy() of a dataset only a secondary holds, and a failing copy changes nothing", {
  skip_below_level("default")
  g_no_wait()
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths[[2]]), g_sim(20, 3), "only/here")
  stub <- local_backend_stub(uri = paths[[1]], generic = "be_put", path = "part-", fail_at = 2:4)
  st <- g_connect(paths)
  g_snapshot_output()
  expect_snapshot(store_copy(st, "here", from = paths[[2]], to = paths[[1]]),
    error = TRUE, transform = g_scrub(dirname(paths[[1]]))
  )
  expect_identical(nrow(st$primary$catalog), 0L)
  expect_store_valid(st, orphans_ok = TRUE)
  stub$fail_at <- NULL
  stub_reset(stub)
  out <- g_quiet(store_copy(st, "here", from = paths[[2]], to = paths[[1]]))
  expect_identical(out$dataset, "only/here")
  expect_identical(g_data_puts(stub), 1L)
  expect_store_valid(st)
})

# store_delete() -----------------------------------------------------------------

test_that("store_delete() needs the full name in confirm", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 1L)
  st <- g_connect(paths)
  g_write(st, g_sim(20, 1))
  g_snapshot_output()
  expect_snapshot(error = TRUE, transform = g_scrub(dirname(paths[[1]])), {
    store_delete(st, "daily")
    store_delete(st, "daily", confirm = "daily")
    store_delete(st, "sales/daily", confirm = "sales/daily", history = "yes")
    store_delete(st, "sales/daily__h3", confirm = "sales/daily__h3")
    store_delete(st, "Bad Name", confirm = "Bad Name")
  })
  expect_identical(g_listed(paths[[2]]), "sales/daily")
})

test_that("store_delete() removes the entry everywhere first, then the files", {
  skip_below_level("default")
  skip_if_no_h3()
  paths <- g_paths(secondaries = 2L)
  root <- dirname(paths[[1]])
  st <- g_connect(paths)
  suppressMessages(store_write(st, rcs_sim_polygons(30, seed = 1), "shapes/polygons",
    title = "Polygons", description = "d"
  ))
  g_write(st, g_sim(20, 1))
  g_snapshot_output()
  expect_snapshot(out <- store_delete(st, "polygons", confirm = "shapes/polygons"), transform = g_scrub(root))
  expect_identical(out$status, rep("deleted", 3))
  for (p in paths) {
    expect_identical(g_listed(p), "sales/daily")
    expect_false(dir.exists(file.path(p, "shapes")))
  }
  expect_store_valid(st)
  expect_snapshot(none <- store_delete(st, "shapes/polygons", confirm = "shapes/polygons"), transform = g_scrub(root))
  expect_identical(none$status, rep("absent", 3))
})

test_that("store_delete() keeps the history unless history = TRUE", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 1L, history = TRUE)
  st <- g_connect(paths)
  x1 <- g_sim(20, 1)
  g_write(st, x1)
  v1 <- st$primary$catalog$version
  g_write(st, g_sim(20, 2), mode = "replace")
  g_quiet(store_delete(st, "sales/daily", confirm = "sales/daily"))
  expect_identical(nrow(st$primary$catalog), 0L)
  expect_store_valid(st)
  # The kept version stays readable by its version through the files.
  h <- store_history(st, "sales/daily")
  expect_identical(h$version, v1)
  expect_true(h$complete)
  expect_identical(nrow(files_lookup(st$primary, "sales/daily", v1)), 2L)

  out <- g_quiet(store_delete(st, "sales/daily", confirm = "sales/daily", history = TRUE))
  expect_identical(out$status, c("deleted", "deleted"))
  expect_identical(nrow(history_read(st$primary$backend)), 0L)
  for (p in paths) expect_false(dir.exists(file.path(p, "sales")))
  expect_store_valid(st)
})

test_that("a secondary failing during store_delete() warns; the next call completes it", {
  skip_below_level("default")
  g_no_wait()
  paths <- g_paths(secondaries = 2L)
  g_write(g_connect(paths), g_sim(20, 1))
  stub <- local_backend_stub(uri = paths[[3]], generic = "be_lock", fail_at = 1)
  st <- g_connect(paths)
  g_snapshot_output()
  expect_snapshot(out <- store_delete(st, "sales/daily", confirm = "sales/daily"),
    transform = g_scrub(dirname(paths[[1]]))
  )
  expect_identical(out$status, c("deleted", "deleted", "behind"))
  expect_store_valid(st)
  stub$fail_at <- NULL
  out <- g_quiet(store_delete(st, "sales/daily", confirm = "sales/daily"))
  expect_identical(out$status, c("absent", "absent", "deleted"))
  expect_store_valid(st)
})

test_that("a primary failing during store_delete() changes no catalog", {
  skip_below_level("default")
  g_no_wait()
  paths <- g_paths(secondaries = 1L)
  g_write(g_connect(paths), g_sim(20, 1))
  stub <- local_backend_stub(uri = paths[[1]], generic = "be_put", path = "^_catalog", fail_at = 1:3)
  st <- g_connect(paths)
  expect_error(
    suppressMessages(store_delete(st, "sales/daily", confirm = "sales/daily")),
    class = "rcs_error_write"
  )
  expect_identical(g_listed(paths[[1]]), "sales/daily")
  expect_identical(g_listed(paths[[2]]), "sales/daily")
  expect_store_valid(st)
})

# store_rebuild() ----------------------------------------------------------------

test_that("store_rebuild() restores lost catalogs and keeps the history", {
  skip_below_level("default")
  paths <- g_paths(secondaries = 1L, history = TRUE)
  root <- dirname(paths[[1]])
  st <- g_connect(paths)
  g_write(st, g_sim(30, 1))
  x2 <- g_sim(30, 1, years = c(2023L, 2025L))
  g_write(st, x2[x2$year == 2025L, ], mode = "update")
  g_write(st, g_sim(20, 4), "sales/summary")
  before <- location_read(st$secondary[[1]]$backend)
  unlink(file.path(paths[[2]], c("_catalog.parquet", "_files.parquet", "_history.parquet")))
  g_snapshot_output()
  expect_snapshot(out <- store_rebuild(st, paths[[2]]), transform = g_scrub(root))
  expect_identical(out$status, c("rebuilt", "rebuilt"))
  expect_identical(out$history, c(1L, 0L))
  after <- location_read(st$secondary[[1]]$backend)
  expect_identical(after$catalog$version, before$catalog$version)
  expect_identical(after$files$path, before$files$path)
  expect_true(all(store_status(st)$status == "same"))
  expect_store_valid(st)
})

test_that("store_rebuild() reports what it skips and replaces a damaged catalog", {
  skip_below_level("default")
  paths <- g_paths()
  root <- dirname(paths[[1]])
  st <- g_connect(paths)
  g_write(st, g_sim(20, 1))
  g_write(st, g_sim(20, 2), "sales/summary")
  # A dataset whose files are gone, and a stray file without metadata.
  unlink(file.path(paths[[1]], st$primary$files$path[st$primary$files$dataset == "sales/summary"]))
  dir.create(file.path(paths[[1]], "stray"))
  arrow::write_parquet(data.frame(a = 1:3), file.path(paths[[1]], "stray", "part-0000000000000000.parquet"))
  writeBin(as.raw(1:10), file.path(paths[[1]], "_catalog.parquet"))
  g_snapshot_output()
  expect_snapshot(out <- store_rebuild(st, paths[[1]]), transform = g_scrub(root))
  expect_identical(out$status, c("rebuilt", "skipped", "skipped"))
  expect_identical(st$primary$catalog$dataset, "sales/daily")
  expect_identical(location_read(st$primary$backend)$token, st$primary$token)
})

test_that("store_rebuild() checks its location and takes the write guard", {
  skip_below_level("default")
  paths <- g_paths()
  st <- g_connect(paths)
  expect_snapshot(store_rebuild(st, "elsewhere"), error = TRUE, transform = g_scrub(dirname(paths[[1]])))
  lock <- file.path(paths[[1]], "_lock")
  dir.create(lock)
  writeLines(time_to_text(now_utc()), file.path(lock, "time"))
  expect_error(store_rebuild(st, paths[[1]]), class = "rcs_error_locked")
})
