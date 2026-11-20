# print.rcs_store(), store_datasets(), store_describe(), store_status().

# Fixed sizes, times and provenance in the catalogs held by `st`, so that
# printed output is the same on every machine and with every Arrow version.
fix_catalogs <- function(st) {
  fixed <- as.POSIXct("2026-01-31 12:00:00", tz = "UTC")
  for (location in store_locations(st, available_only = TRUE)) {
    cat <- location$catalog
    n <- nrow(cat)
    cat$bytes <- bit64::as.integer64(1000 * seq_len(n) + 234)
    cat$created <- rep(fixed, n)
    cat$updated <- rep(fixed, n)
    cat$r_version <- rep("4.6.2", n)
    cat$rcs_version <- rep("0.0.0.9000", n)
    files <- location$files
    files$bytes <- bit64::as.integer64(rep(5678, nrow(files)))
    files$created <- rep(fixed, nrow(files))
    location$catalog <- cat
    location$files <- files
    store_set_location(st, location)
  }
  invisible(st)
}

local_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
  withr::local_timezone("UTC", .local_envir = frame)
}

scrub <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) {
    x <- gsub(root, "<root>", x, fixed = TRUE)
    gsub("(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])", "<version>", x, perl = TRUE)
  }
}

# Every inspection function makes no backend call and opens no data file.
expect_no_work <- function(expr) {
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  force(expr)
  tr <- rcs_trace()
  expect_false(any(tr$counter %in% c("backend_call", "catalog_read", "file_open", "bytes_down")))
}

test_that("store_status() compares every secondary with the primary", {
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  fixture_write(st, rcs_sim_table(10, seed = 5), "extra/only",
    title = "Only here", description = "A dataset only in the first secondary.",
    locations = st$secondary[1]
  )
  status <- store_status(st)
  expect_named(status, c(
    "dataset", "location", "status", "newer", "primary_version", "location_version",
    "primary_updated", "location_updated"
  ))
  s1 <- status[status$location == fx$secondary[[1]], ]
  s2 <- status[status$location == fx$secondary[[2]], ]
  expect_identical(s1$dataset, c("sales/daily", "sales/summary", "extra/only"))
  expect_identical(s1$status, c("same", "same", "extra"))
  expect_identical(s2$status[match(c("sales/daily", "sales/summary"), s2$dataset)], c("differs", "missing"))
  expect_identical(s2$newer[s2$dataset == "sales/daily"], "primary")
  expect_true(all(is.na(status$newer[status$status != "differs"])))
  expect_identical(s2$primary_version[1], st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"])
  expect_identical(attr(status$primary_updated, "tzone"), "")
  expect_store_valid(st)
})

test_that("newer names the side with the later update", {
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  location <- st$secondary[[2]]
  i <- location$catalog$dataset == "sales/daily"
  location$catalog$updated[i] <- location$catalog$updated[i] + 3600 * 24 * 365
  store_set_location(st, location)
  status <- store_status(st)
  expect_identical(status$newer[status$location == fx$secondary[[2]] & status$dataset == "sales/daily"], "secondary")
})

test_that("an empty store has no status rows and no datasets", {
  dir <- withr::local_tempdir()
  st <- store_connect(file.path(dir, "p"), secondary = file.path(dir, "s"), create = TRUE)
  status <- store_status(st)
  expect_identical(nrow(status), 0L)
  expect_type(status$status, "character")
  ds <- store_datasets(st)
  expect_identical(nrow(ds), 0L)
  expect_type(ds$in_1, "character")
  expect_store_valid(st)
})

test_that("store_status() has zero rows without secondaries", {
  fx <- local_test_store(secondaries = 0L)
  status <- store_status(fx$st)
  expect_identical(nrow(status), 0L)
  expect_true(all(c("dataset", "location", "status", "newer") %in% names(status)))
  expect_store_valid(fx$st)
})

test_that("store_status() lists index tables, and agrees with the invariants", {
  skip_below_level("default")
  fx <- local_test_store(geospatial = "polygons", partial = TRUE)
  status <- store_status(fx$st)
  expect_true("shapes/polygons__h3" %in% status$dataset)
  s2 <- status[status$location == fx$secondary[[2]], ]
  expect_identical(s2$status[s2$dataset == "shapes/polygons__h3"], "missing")
  expect_store_valid(fx$st)
})

test_that("store_datasets() returns the primary catalog with one column per secondary", {
  fx <- local_test_store(partial = TRUE)
  ds <- store_datasets(fx$st)
  expect_identical(ds$dataset, c("sales/daily", "sales/summary"))
  expect_identical(names(ds), c(
    "dataset", "kind", "title", "rows", "bytes", "n_files", "partition",
    "version", "updated", "in_1", "in_2"
  ))
  expect_identical(ds$in_1, c("same", "same"))
  expect_identical(ds$in_2, c("differs", "missing"))
  expect_identical(ds$rows, c(240, 40))
  expect_identical(ds$partition, list("year", character()))
  expect_identical(
    attr(ds, "locations"),
    c(primary = fx$primary, in_1 = fx$secondary[[1]], in_2 = fx$secondary[[2]])
  )
  expect_identical(store_datasets(fx$st, pattern = "summ")$dataset, "sales/summary")
  expect_identical(nrow(store_datasets(fx$st, kind = "geospatial")), 0L)
  expect_identical(store_datasets(fx$st, kind = c("raster", "table"))$dataset, ds$dataset)
})

test_that("store_datasets() hides index tables unless index = TRUE", {
  skip_below_level("default")
  fx <- local_test_store(geospatial = c("polygons", "lines"), secondaries = 1L)
  ds <- store_datasets(fx$st)
  expect_false(any(grepl("__h3$", ds$dataset)))
  expect_false("index_of" %in% names(ds))
  all <- store_datasets(fx$st, index = TRUE)
  expect_true(all(c("shapes/polygons__h3", "shapes/lines__h3") %in% all$dataset))
  expect_identical(all$index_of[all$dataset == "shapes/polygons__h3"], "shapes/polygons")
  expect_identical(store_datasets(fx$st, kind = "geospatial")$dataset, c("shapes/lines", "shapes/polygons"))
})

test_that("store_datasets() marks unavailable secondaries with NA", {
  fx <- local_test_store()
  st <- fx$st
  store_set_location(st, new_location(backend = st$secondary[[1]]$backend, available = FALSE))
  ds <- store_datasets(st)
  expect_true(all(is.na(ds$in_1)))
  expect_identical(ds$in_2, c("same", "same"))
})

test_that("store_datasets() checks its arguments", {
  fx <- local_test_store(secondaries = 0L)
  expect_snapshot(error = TRUE, {
    store_datasets(fx$st, kind = "vector")
    store_datasets(fx$st, pattern = 1)
    store_datasets(fx$st, index = NA)
    store_datasets("not a store")
  })
})

test_that("print() shows locations and datasets grouped by folder", {
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  fixture_write(st, rcs_sim_table(10, seed = 5), "top",
    title = "Top level", description = "A dataset outside any folder."
  )
  fix_catalogs(st)
  local_snapshot_output()
  expect_snapshot(print(st), transform = scrub(dirname(fx$primary)))
  testthat::local_reproducible_output(unicode = TRUE, width = 250)
  expect_snapshot(print(st), transform = scrub(dirname(fx$primary)))
})

test_that("print() shows the history setting, unavailable locations and limits the list", {
  fx <- local_test_store(history = TRUE, secondaries = 1L)
  st <- fx$st
  st$history <- FALSE
  store_set_location(st, new_location(backend = st$secondary[[1]]$backend, available = FALSE))
  fix_catalogs(st)
  local_snapshot_output()
  expect_snapshot(print(st, n = 1), transform = scrub(dirname(fx$primary)))
})

test_that("print() of an empty store and of index tables", {
  dir <- withr::local_tempdir()
  st <- store_connect(file.path(dir, "empty"), create = TRUE)
  local_snapshot_output()
  expect_snapshot(print(st), transform = scrub(dir))
  skip_below_level("default")
  fx <- local_test_store(geospatial = "polygons", tables = FALSE, secondaries = 0L)
  fix_catalogs(fx$st)
  expect_snapshot({
    print(fx$st)
    print(fx$st, index = TRUE)
  }, transform = scrub(dirname(fx$primary)))
})

test_that("store_describe() returns the full entry, columns, files and locations", {
  fx <- local_test_store(partial = TRUE)
  d <- store_describe(fx$st, "daily")
  expect_s3_class(d, "rcs_description")
  expect_named(d, c("entry", "columns", "files", "locations", "index"))
  expect_identical(d$entry$dataset, "sales/daily")
  expect_identical(nrow(d$files), as.integer(d$entry$n_files))
  expect_identical(d$columns$name, names(fx$data[["sales/daily"]]))
  expect_identical(d$columns$r_type[d$columns$name == "wait"], "difftime (hours)")
  expect_identical(d$columns$r_type[d$columns$name == "grade"], "ordered factor (3 levels)")
  expect_identical(d$locations$status, c("primary", "same", "differs"))
  expect_identical(d$index, NA_character_)
  expect_error(store_describe(fx$st, "nothing"), class = "rcs_error_dataset_not_found")
})

test_that("print() of a description", {
  fx <- local_test_store(partial = TRUE)
  fix_catalogs(fx$st)
  local_snapshot_output()
  expect_snapshot(print(store_describe(fx$st, "sales/daily")), transform = scrub(dirname(fx$primary)))
  expect_snapshot(print(store_describe(fx$st, "summary"), n = 0), transform = scrub(dirname(fx$primary)))
})

test_that("print() of a geospatial description and of its index table", {
  skip_below_level("default")
  fx <- local_test_store(geospatial = c("polygons", "flat"), tables = FALSE, secondaries = 0L)
  fix_catalogs(fx$st)
  d <- store_describe(fx$st, "shapes/polygons")
  expect_identical(d$index, "shapes/polygons__h3")
  local_snapshot_output()
  expect_snapshot({
    print(d, n = 3)
    print(store_describe(fx$st, "shapes/polygons__h3"))
    print(store_describe(fx$st, "polygons"), n = 0)
  }, transform = scrub(dirname(fx$primary)))
})

test_that("inspection makes no backend call and opens no data file after connecting", {
  fx <- local_test_store(partial = TRUE)
  st <- store_connect(fx$primary, fx$secondary)
  expect_no_work(utils::capture.output(print(st)))
  expect_identical(rcs_trace(), rcs_trace()[0, ])
  expect_no_work(store_datasets(st, index = TRUE))
  expect_no_work(utils::capture.output(print(store_describe(st, "sales/daily"))))
  expect_no_work(store_status(st))
})

test_that("crs_text() and r_type_text() describe what they get", {
  expect_identical(crs_text(sf::st_crs(4326)$ProjJson), "WGS 84 (EPSG:4326)")
  expect_identical(crs_text(NA_character_), NA_character_)
  expect_identical(crs_text("not json"), "(unreadable PROJJSON)")
  expect_identical(crs_text('{"name": "local"}'), "local")
  expect_identical(r_type_text(NULL), NA_character_)
  expect_identical(r_type_text(list(class = "factor", levels = "a", ordered = FALSE)), "factor (1 level)")
  expect_identical(r_type_text(list(class = "SpatRaster", resolution = c(1, 1), dim = c(10, 20))), "raster layer (10 x 20 cells)")
  expect_identical(r_type_text(list(class = "integer64")), "integer64")
})
