# Dataset names and the choice of location for a read.

# A catalog in memory with the given datasets; index tables get `index_of`.
memory_catalog <- function(datasets, versions = NULL) {
  versions <- versions %||% rep(strrep("a", 16), length(datasets))
  rows <- Map(function(dataset, version) {
    index <- is_index_name(dataset)
    new_entry(
      dataset = dataset, kind = "table", title = "T", description = "D",
      version = version, n_files = 1, rows = 1, bytes = 1, columns = "[]",
      index_of = if (index) index_parent(dataset) else NA_character_
    )
  }, datasets, versions)
  vctrs::vec_rbind(catalog_empty(), !!!unname(rows))
}

# A backend object of a remote type that makes no call while choosing.
fake_remote <- function(uri) {
  structure(
    list(type = "gcs", uri = uri, root = sub("^gs://", "", uri), bucket = "b", prefix = ""),
    class = c("rcs_backend_fake", "rcs_backend")
  )
}

memory_store <- function(primary, secondary = list()) {
  new_store(primary = primary, secondary = secondary)
}

names_store <- function() {
  catalog <- memory_catalog(c(
    "polygons", "shapes/polygons", "shapes/polygons__h3",
    "sales/daily", "sales/weekly", "other/weekly"
  ))
  memory_store(new_location(backend = fake_remote("gs://b/primary"), catalog = catalog))
}

test_that("resolve_dataset() accepts full names and unique short names", {
  st <- names_store()
  expect_identical(resolve_dataset(st, "sales/daily"), "sales/daily")
  expect_identical(resolve_dataset(st, "daily"), "sales/daily")
  # a full name wins over a shared last segment
  expect_identical(resolve_dataset(st, "polygons"), "polygons")
  expect_identical(resolve_dataset(st, "shapes/polygons"), "shapes/polygons")
})

test_that("resolve_dataset() resolves index tables only when asked", {
  st <- names_store()
  expect_error(resolve_dataset(st, "shapes/polygons__h3"), class = "rcs_error_dataset_not_found")
  expect_identical(resolve_dataset(st, "shapes/polygons__h3", index = TRUE), "shapes/polygons__h3")
  expect_identical(resolve_dataset(st, "polygons__h3", index = TRUE), "shapes/polygons__h3")
})

test_that("resolve_dataset() aborts on ambiguous and unknown names", {
  st <- names_store()
  err <- expect_error(resolve_dataset(st, "weekly"), class = "rcs_error_dataset_ambiguous")
  expect_match(conditionMessage(err), "sales/weekly", fixed = TRUE)
  expect_match(conditionMessage(err), "other/weekly", fixed = TRUE)
  err <- expect_error(resolve_dataset(st, "daly"), class = "rcs_error_dataset_not_found")
  expect_match(conditionMessage(err), "sales/daily", fixed = TRUE)
  err <- expect_error(resolve_dataset(st, "zzzzzzzz"), class = "rcs_error_dataset_not_found")
  expect_no_match(conditionMessage(err), "Closest")
  expect_error(resolve_dataset(st, NA_character_), class = "rcs_error_argument")
  expect_error(resolve_dataset(st, c("a", "b")), class = "rcs_error_argument")
  empty <- memory_store(new_location(backend = fake_remote("gs://b/p")))
  expect_error(resolve_dataset(empty, "x"), "no datasets", class = "rcs_error_dataset_not_found")
})

test_that("resolve_dataset() messages are stable", {
  st <- names_store()
  expect_snapshot(error = TRUE, {
    resolve_dataset(st, "weekly")
    resolve_dataset(st, "polygon")
  })
})

locations_store <- function(secondary_versions, local = c(FALSE, TRUE, FALSE)) {
  dataset <- "sales/daily"
  make <- function(i, version) {
    uri <- c("gs://b/primary", "gs://b/second", "gs://b/third")[[i]]
    be <- if (local[[i]]) be_new(file.path(tempdir(), basename(uri))) else fake_remote(uri)
    catalog <- if (is.na(version)) catalog_empty() else memory_catalog(dataset, version)
    new_location(backend = be, catalog = catalog)
  }
  primary <- make(1, strrep("a", 16))
  secondary <- Map(make, 2:3, secondary_versions)
  memory_store(primary, unname(secondary))
}

test_that("choose_location() prefers local copies, then the primary", {
  v <- strrep("a", 16)
  st <- locations_store(c(v, v))
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  expect_message(
    chosen <- choose_location(st, "sales/daily"),
    "from secondary"
  )
  expect_identical(chosen$uri, st$secondary[[1]]$uri)
  expect_identical(nrow(rcs_trace()), 0L)

  # a local copy that differs is not used
  st <- locations_store(c(strrep("b", 16), v))
  expect_silent(chosen <- choose_location(st, "sales/daily"))
  expect_identical(chosen$uri, st$primary$uri)

  # a remote secondary only after the primary
  st <- locations_store(c(v, v), local = c(FALSE, FALSE, FALSE))
  expect_identical(choose_location(st, "sales/daily")$uri, st$primary$uri)

  # a local primary comes before a local secondary
  st <- locations_store(c(v, v), local = c(TRUE, TRUE, FALSE))
  expect_silent(chosen <- choose_location(st, "sales/daily"))
  expect_identical(chosen$uri, st$primary$uri)

  # unavailable locations are skipped; a missing copy is not eligible
  st <- locations_store(c(v, v))
  second <- st$secondary[[1]]
  second$available <- FALSE
  store_set_location(st, second)
  st2 <- locations_store(c(NA, v), local = c(FALSE, TRUE, TRUE))
  expect_identical(suppressMessages(choose_location(st2, "sales/daily"))$uri, st2$secondary[[2]]$uri)
  expect_identical(choose_location(st, "sales/daily")$uri, st$primary$uri)
})

test_that("choose_location() is quiet with rcs.quiet and checks the dataset", {
  v <- strrep("a", 16)
  st <- locations_store(c(v, v))
  withr::local_options(rcs.quiet = TRUE)
  expect_silent(choose_location(st, "sales/daily"))
  expect_error(choose_location(st, "nope"), class = "rcs_error_dataset_not_found")
  expect_snapshot({
    withr::with_options(list(rcs.quiet = FALSE), invisible(choose_location(st, "sales/daily")))
  }, transform = function(x) gsub(be_new(tempdir())$uri, "<tempdir>", x, fixed = TRUE))
})

test_that("choose_location() finds an old version where its files still are", {
  skip_below_level("default")
  fx <- local_test_store(history = TRUE)
  st <- fx$st
  old <- unique(history_read(st$primary$backend)$version)
  hist <- history_read(st$primary$backend)
  gone <- setdiff(hist$path, st$primary$files$path)[[1]]
  # all locations are local: the primary first
  expect_silent(chosen <- choose_location(st, "sales/daily", old))
  expect_identical(chosen$uri, st$primary$uri)

  unlink(file.path(fx$primary, gone))
  expect_message(chosen <- choose_location(st, "sales/daily", old), "from secondary")
  expect_identical(chosen$uri, st$secondary[[1]]$uri)

  unlink(file.path(fx$secondary[[1]], gone))
  expect_message(chosen <- choose_location(st, "sales/daily", old), "from secondary")
  expect_identical(chosen$uri, st$secondary[[2]]$uri)

  unlink(file.path(fx$secondary[[2]], gone))
  expect_error(choose_location(st, "sales/daily", old), class = "rcs_error_version_not_found")
  expect_error(choose_location(st, "sales/daily", strrep("0", 16)), class = "rcs_error_version_not_found")

  # the current version given explicitly is the current version
  current <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  expect_identical(choose_location(st, "sales/daily", current)$uri, st$primary$uri)
})

test_that("choose_location() serves an old version from a secondary that is behind", {
  skip_below_level("default")
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  behind <- st$secondary[[2]]$catalog$version
  expect_message(chosen <- choose_location(st, "sales/daily", behind), "from secondary")
  expect_identical(chosen$uri, st$secondary[[2]]$uri)
  expect_identical(choose_location(st, "sales/daily")$uri, st$primary$uri)
})
