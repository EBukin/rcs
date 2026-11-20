# store_check(): integrity (catalogs against stored files) and serialization
# (stored rows against the data they were written from).

# Test-side work-around for a defect in R/files.R (see test-write.R):
# difftime is truncated to whole seconds; whole hours survive exactly.
whole_hours <- function(x) {
  x$wait <- as.difftime(round(as.numeric(x$wait, units = "hours")), units = "hours")
  x
}

local_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
}

scrub <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) {
    x <- gsub(root, "<root>", x, fixed = TRUE)
    x <- gsub("(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])", "<version>", x, perl = TRUE)
    gsub("(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])", "<md5>", x, perl = TRUE)
  }
}

local_written_store <- function(secondaries = 1L, frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  paths <- file.path(root, c("primary", sprintf("secondary%d", seq_len(secondaries))))
  st <- suppressMessages(suppressWarnings(store_connect(paths[[1]], secondary = paths[-1], create = TRUE)))
  x <- whole_hours(rcs_sim_table(120, seed = 1))
  suppressMessages(store_write(st, x, "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.",
    key = c("shop_id", "date", "product"), partition = "year"
  ))
  list(st = st, x = x, root = normalizePath(root, winslash = "/"), paths = normalizePath(paths, winslash = "/"))
}

daily_path <- function(st) {
  st$primary$files$path[st$primary$files$dataset == "sales/daily"][[1]]
}

# Integrity ---------------------------------------------------------------------

test_that("the integrity check passes on a valid store and downloads no data file", {
  fx <- local_test_store(secondaries = 1L)
  stub <- local_backend_stub(uri = fx$primary)
  st <- store_connect(fx$primary, secondary = fx$secondary)
  withr::local_options(rcs.trace = TRUE)
  local_snapshot_output()
  expect_snapshot(out <- store_check(st, "sales/daily"))
  expect_s3_class(out, "tbl_df")
  expect_identical(names(out), c("location", "dataset", "path", "status", "problem"))
  expect_true(all(out$status == "ok"))
  expect_identical(nrow(out), 2L * nrow(st$primary$files[st$primary$files$dataset == "sales/daily", ]))
  gets <- stub$log$path[stub$log$generic == "be_get"]
  expect_false(any(grepl("part-", gets)))
  trace <- rcs_trace()
  expect_identical(unique(trace$call), "store_check")
  expect_store_valid(st)
})

test_that("an altered data file is named", {
  fx <- local_test_store(secondaries = 0L)
  path <- daily_path(fx$st)
  stub_flip_byte(file.path(fx$primary, path))
  local_snapshot_output()
  expect_snapshot(store_check(fx$st, "daily"), error = TRUE, transform = scrub(fx$primary))
  out <- store_check(fx$st, "daily", error = FALSE) |> suppressMessages()
  expect_identical(out$status[out$path == path], "failed")
  expect_true(all(out$status[out$path != path] == "ok"))
})

test_that("a missing data file is named", {
  fx <- local_test_store(secondaries = 0L)
  path <- daily_path(fx$st)
  unlink(file.path(fx$primary, path))
  local_snapshot_output()
  expect_snapshot(store_check(fx$st, "sales/daily"), error = TRUE, transform = scrub(fx$primary))
})

test_that("a wrong MD5 in _files.parquet is named", {
  fx <- local_test_store(secondaries = 0L)
  be <- fx$st$primary$backend
  files <- strip_md5_attr(catalog_read(be, "files"))
  i <- which(files$dataset == "sales/summary")
  files$md5[i] <- strrep("0", 32)
  catalog_write(be, files, "files")
  local_snapshot_output()
  expect_snapshot(store_check(fx$st, "summary"), error = TRUE, transform = scrub(fx$primary))
  out <- store_check(fx$st, "summary", error = FALSE) |> suppressMessages()
  expect_true(files$path[i] %in% out$path[out$status == "failed"])
})

test_that("a manifest that disagrees with the catalog is named", {
  fx <- local_test_store(secondaries = 0L)
  be <- fx$st$primary$backend
  entry <- catalog_entry(fx$st$primary$catalog, "sales/summary")
  m <- manifest_read(be, "sales/summary", entry$version)
  m$entry$title <- "Another title"
  manifest_write(be, m)
  local_snapshot_output()
  expect_snapshot(store_check(fx$st, "summary"), error = TRUE, transform = scrub(fx$primary))
})

test_that("a truncated _catalog.parquet is named", {
  fx <- local_test_store(secondaries = 1L)
  file <- file.path(fx$secondary[[1]], "_catalog.parquet")
  bytes <- readBin(file, "raw", file.size(file))
  writeBin(bytes[seq_len(length(bytes) %/% 2)], file)
  local_snapshot_output()
  expect_snapshot(store_check(fx$st, "summary"), error = TRUE, transform = scrub(dirname(fx$primary)))
  out <- suppressMessages(store_check(fx$st, "summary", locations = fx$primary))
  expect_identical(unique(out$location), fx$primary)
})

test_that("locations are chosen by address; a location without the dataset is reported", {
  fx <- local_test_store(partial = TRUE)
  out <- suppressMessages(store_check(fx$st, "summary", locations = fx$secondary))
  expect_identical(out$status[out$location == fx$secondary[[2]]], "missing")
  expect_true(all(out$status[out$location == fx$secondary[[1]]] == "ok"))
  local_snapshot_output()
  expect_snapshot(error = TRUE, transform = scrub(dirname(fx$primary)), {
    store_check(fx$st, "summary", locations = file.path(dirname(fx$primary), "elsewhere"))
    store_check(fx$st, "summary", n = 0)
    store_check(fx$st, "nothing")
  })
})

# Serialization -----------------------------------------------------------------

test_that("the serialization check compares sampled rows with x", {
  skip_below_level("default")
  s <- local_written_store()
  local_snapshot_output()
  expect_snapshot(out <- store_check(s$st, "sales/daily", x = s$x))
  expect_true(all(out$status == "ok"))

  # Matched by key, so the row order of x does not matter.
  shuffled <- s$x[rev(seq_len(nrow(s$x))), ]
  expect_true(all(suppressMessages(store_check(s$st, "sales/daily", x = shuffled))$status == "ok"))

  altered <- s$x
  altered$qty <- altered$qty + 1L
  altered$note <- paste0(altered$note, "!")
  expect_snapshot(store_check(s$st, "sales/daily", x = altered), error = TRUE, transform = scrub(s$root))
  only <- suppressMessages(store_check(s$st, "sales/daily", x = altered, columns = "price"))
  expect_true(all(only$status == "ok"))
  missing <- suppressMessages(store_check(s$st, "sales/daily", x = s$x[1:3, ], error = FALSE))
  expect_true(all(missing$status == "failed"))
  expect_match(missing$problem, "not in x")
})

test_that("a table without key is matched by row order within its partitions", {
  skip_below_level("default")
  s <- local_written_store(secondaries = 0L)
  x <- s$x
  suppressMessages(store_write(s$st, x, "plain", title = "Plain", description = "No key.", partition = "year"))
  expect_true(all(suppressMessages(store_check(s$st, "plain", x = x))$status == "ok"))
  x$price <- rev(x$price)
  expect_error(suppressMessages(store_check(s$st, "plain", x = x)), class = "rcs_error_check")
})

test_that("store_write(check = TRUE) aborts before uploading when a staged file differs", {
  skip_below_level("default")
  s <- local_written_store(secondaries = 0L)
  original <- files_write_parquet
  testthat::local_mocked_bindings(files_write_parquet = function(data, path, ...) {
    data$qty <- data$qty + 1L
    original(data, path, ...)
  })
  local_snapshot_output()
  expect_snapshot(
    store_write(s$st, s$x, "sales/copy", title = "Copy", description = "d", key = c("shop_id", "date", "product")),
    error = TRUE, transform = scrub(s$root)
  )
  expect_false("sales/copy" %in% s$st$primary$catalog$dataset)
  expect_false(dir.exists(file.path(s$paths[[1]], "sales/copy")))
  expect_store_valid(s$st)
})

test_that("geospatial data are compared by key, or by the row identifiers of a new geocoding", {
  skip_below_level("default")
  skip_if_no_h3()
  s <- local_written_store(secondaries = 0L)
  pol <- rcs_sim_polygons(30, seed = 2)
  suppressMessages(store_write(s$st, pol, "shapes/polygons", title = "Polygons", description = "Simulated."))
  suppressMessages(store_write(s$st, pol, "shapes/keyed", title = "Keyed", description = "Simulated.", key = "id"))
  expect_true(all(suppressMessages(store_check(s$st, "shapes/polygons", x = pol))$status == "ok"))
  expect_true(all(suppressMessages(store_check(s$st, "shapes/keyed", x = pol))$status == "ok"))
  moved <- pol
  sf::st_geometry(moved) <- sf::st_geometry(pol) + c(0.001, 0)
  sf::st_crs(moved) <- sf::st_crs(pol)
  out <- suppressMessages(store_check(s$st, "shapes/keyed", x = moved, error = FALSE))
  expect_match(out$problem, "geometry")
  out <- suppressMessages(store_check(s$st, "shapes/polygons"))
  expect_true(all(out$status == "ok"))
  expect_true(any(grepl("__h3", out$dataset)))
})

test_that("a raster is compared by sampled cells", {
  skip_below_level("default")
  skip_if_not_installed("terra")
  s <- local_written_store(secondaries = 0L)
  r <- rcs_sim_raster(seed = 1, nrow = 30, ncol = 30)
  suppressMessages(store_write(s$st, r, "grid", title = "Grid", description = "Simulated raster."))
  expect_true(all(suppressMessages(store_check(s$st, "grid", x = r))$status == "ok"))
  expect_true(all(suppressMessages(store_check(s$st, "grid"))$status == "ok"))
  other <- r + 1
  out <- suppressMessages(store_check(s$st, "grid", x = other, error = FALSE))
  expect_identical(out$status, "failed")
  expect_error(store_check(s$st, "grid", x = s$x), class = "rcs_error_argument")
})
