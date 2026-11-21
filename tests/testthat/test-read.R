# Normalisation for round trips: a tibble in key order (or as it is), row
# names reset, and POSIXct without a `tzone` attribute given the session's
# zone `""`, as Arrow returns it.
normalise <- function(x, key = NULL) {
  x <- tibble::as_tibble(x)
  if (length(key) > 0 && nrow(x) > 1) {
    x <- x[do.call(order, c(unname(as.list(x[key])), method = "radix")), ]
  }
  for (name in names(x)) {
    if (inherits(x[[name]], "POSIXct") && is.null(attr(x[[name]], "tzone"))) {
      attr(x[[name]], "tzone") <- ""
    }
  }
  attr(x, "row.names") <- seq_len(nrow(x))
  x
}

# Every column identical.
expect_same_table <- function(got, expected, key = NULL) {
  got <- normalise(got, key)
  expected <- normalise(expected, key)
  expect_identical(names(got), names(expected))
  for (name in names(expected)) {
    expect_identical(got[[name]], expected[[name]], info = name)
  }
}

daily_key <- c("shop_id", "date", "product")

test_that("every type of a table survives a round trip, one file and partitioned", {
  fx <- local_test_store(secondaries = 0L)
  daily <- store_read(fx$st, "sales/daily")
  expect_same_table(daily, fx$data[["sales/daily"]], daily_key)
  summary <- store_read(fx$st, "sales/summary")
  expect_same_table(summary, fx$data[["sales/summary"]])
  expect_type(daily$tags, "list")
  expect_null(attr(daily$tags, "ptype"))
  expect_s3_class(daily$big, "integer64")
  expect_identical(levels(daily$product), sprintf("p%02d", 1:20))
  expect_true(is.ordered(daily$grade))
})

test_that("a zero-row table and small integer64 values survive a round trip", {
  fx <- local_test_store(secondaries = 0L)
  zero <- rcs_sim_table(0)
  fixture_write(fx$st, zero, "sales/none", title = "None", description = "Zero rows.")
  got <- store_read(fx$st, "sales/none")
  expect_same_table(got, zero)
  expect_identical(levels(got$product), levels(zero$product))
  small <- tibble::tibble(id = 1:5, big = bit64::as.integer64(1:5))
  fixture_write(fx$st, small, "sales/small", title = "Small", description = "Small integer64.")
  expect_identical(store_read(fx$st, "sales/small"), small)
})

test_that("geospatial data and every geometry type survive a round trip", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = TRUE, secondaries = 0L)
  st <- fx$st
  for (dataset in c("shapes/polygons", "polygons", "shapes/points", "shapes/lines")) {
    expected <- fx$data[[dataset]]
    got <- store_read(st, dataset)
    expect_s3_class(got, "sf")
    expect_true(sf::st_crs(got) == sf::st_crs(expected), info = dataset)
    expect_false(".rcs_id" %in% names(got))
    expect_true(all(c("bbox", "geometry") %in% names(got)))
    expect_identical("h3" %in% names(got), dataset != "polygons")
    got <- got[order(got$id), ]
    expect_identical(
      sf::st_as_binary(sf::st_geometry(got), EWKB = FALSE),
      sf::st_as_binary(sf::st_geometry(expected[order(expected$id), ]), EWKB = FALSE),
      info = dataset
    )
    attrs <- setdiff(names(expected), "geometry")
    expect_identical(
      normalise(sf::st_drop_geometry(got)[attrs]),
      normalise(sf::st_drop_geometry(expected[order(expected$id), ])[attrs]),
      info = dataset
    )
  }
  expect_true("h3_p4" %in% names(store_read(st, "shapes/polygons")) ||
    any(grepl("^h3_p[0-9]+$", names(store_read(st, "shapes/polygons")))))

  mixed <- sf::st_sf(
    id = 1:6,
    geometry = sf::st_sfc(
      sf::st_point(c(-27, 7)),
      sf::st_linestring(cbind(c(-27, -26.9), c(7, 7.1))),
      sf::st_polygon(list(cbind(c(-26, -25.9, -25.9, -26), c(8, 8, 8.1, 8)))),
      sf::st_multipolygon(list(
        list(cbind(c(-28, -27.95, -27.95, -28), c(6.5, 6.5, 6.55, 6.5))),
        list(cbind(c(-27.9, -27.85, -27.85, -27.9), c(6.5, 6.5, 6.55, 6.5)))
      )),
      sf::st_polygon(),
      sf::st_multipoint(cbind(c(-25, -25.1), c(7, 7.2))),
      crs = 4326
    )
  )
  fixture_write(st, mixed, "mixed/one", title = "Mixed", description = "Mixed types in one file.")
  fixture_write(st, mixed, "mixed/split", title = "Mixed", description = "Mixed types by cell.", partition = "h3")
  for (dataset in c("mixed/one", "mixed/split")) {
    got <- store_read(st, dataset)
    got <- got[order(got$id), ]
    expect_identical(
      sf::st_as_binary(sf::st_geometry(got), EWKB = FALSE),
      sf::st_as_binary(sf::st_geometry(mixed), EWKB = FALSE),
      info = dataset
    )
    expect_identical(got$id, mixed$id)
  }
})

test_that("geometry = FALSE and columns choose what is read", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  flat <- store_read(fx$st, "polygons", geometry = FALSE)
  expect_false(inherits(flat, "sf"))
  expect_false("geometry" %in% names(flat))
  few <- store_read(fx$st, "polygons", columns = c(id, area))
  expect_s3_class(few, "sf")
  expect_named(few, c("id", "area", "geometry"))
  ids <- store_read(fx$st, "polygons", columns = c(id, .rcs_id), geometry = FALSE)
  expect_named(ids, c("id", ".rcs_id"))
  expect_s3_class(ids$.rcs_id, "integer64")
  expect_snapshot(store_read(fx$st, "polygons", columns = c(id, nothing)), error = TRUE)
})

test_that("filters and columns of a table read", {
  fx <- local_test_store(secondaries = 0L)
  data <- fx$data[["sales/daily"]]
  got <- store_read(fx$st, "sales/daily", year == 2023, product == "p07", columns = c(shop_id, date, qty))
  expected <- data[data$year == 2023 & data$product == "p07", c("shop_id", "date", "qty")]
  expect_identical(normalise(got, c("shop_id", "date")), normalise(expected, c("shop_id", "date")))
  limit <- 10
  got <- store_read(fx$st, "sales/daily", qty > limit)
  expect_identical(nrow(got), sum(data$qty > limit, na.rm = TRUE))
})

test_that("short names resolve; unknown names and bad versions abort", {
  fx <- local_test_store(secondaries = 0L)
  expect_identical(store_read(fx$st, "summary"), store_read(fx$st, "sales/summary"))
  expect_snapshot(store_read(fx$st, "sales/dialy"), error = TRUE)
  expect_snapshot(store_read(fx$st, "sales/daily", version = "abc"), error = TRUE)
  expect_error(store_read(fx$st, "sales/daily", version = "0123456789abcdef"), class = "rcs_error_version_not_found")
  expect_snapshot(store_read("not a store", "sales/daily"), error = TRUE)
})

test_that("an earlier version is read from the history with that version's entry", {
  fx <- local_test_store(history = TRUE, secondaries = 1L)
  st <- fx$st
  history <- history_read(st$primary$backend)
  old <- unique(history$version[history$dataset == "sales/daily"])
  expect_length(old, 1)
  got <- store_read(st, "sales/daily", version = old)
  expect_same_table(got, fx$old, daily_key)
  current <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  expect_same_table(store_read(st, "sales/daily", version = current), fx$data[["sales/daily"]], daily_key)
  q <- store_open(st, "sales/daily", version = old)
  expect_snapshot(q)
  expect_identical(q$entry$version, old)
  expect_identical(nrow(dplyr::collect(q)), nrow(fx$old))
})

test_that("a read served by a local secondary makes no call to the primary", {
  fx <- local_test_store(secondaries = 2L, partial = TRUE)
  st <- fx$st
  # test-side simulation of a cloud primary: local secondaries come first
  primary <- st$primary
  primary$backend$type <- "gcs"
  st$primary <- primary
  withr::local_options(rcs.trace = TRUE)
  expect_snapshot(
    got <- store_read(st, "sales/daily", year == 2024),
    transform = function(x) gsub("[A-Za-z]:?[^ ]*secondary1", "<secondary1>", x)
  )
  trace <- rcs_trace()
  expect_false(any(trace$location == st$primary$uri, na.rm = TRUE))
  expect_true(all(trace$location[!is.na(trace$location)] == fx$secondary[[1]]))
  expect_identical(nrow(got), sum(fx$data[["sales/daily"]]$year == 2024))
  withr::local_options(rcs.quiet = TRUE)
  expect_silent(store_read(st, "sales/summary"))
})

test_that("a partition filter opens only the files of the matching partitions", {
  fx <- local_test_store(secondaries = 0L)
  withr::local_options(rcs.trace = TRUE)
  store_read(fx$st, "sales/daily", year == 2024)
  trace <- rcs_trace()
  opened <- trace$detail[trace$counter == "file_open"]
  files <- fx$st$primary$files
  expect_identical(opened, files$path[files$dataset == "sales/daily" & grepl("2024", files$partition_values)])
  store_read(fx$st, "sales/daily", qty > 3)
  trace <- rcs_trace()
  expect_identical(sum(trace$counter == "file_open"), sum(files$dataset == "sales/daily"))
})

test_that("store_sample() reads row groups, applies filters, and is reproducible", {
  fx <- local_test_store(secondaries = 0L)
  data <- fx$data[["sales/daily"]]
  set.seed(1)
  before <- .Random.seed
  a <- store_sample(fx$st, "sales/daily", n = 20, qty > 10, seed = 42)
  expect_identical(.Random.seed, before)
  b <- store_sample(fx$st, "sales/daily", n = 20, qty > 10, seed = 42)
  expect_identical(a, b)
  expect_identical(nrow(a), 20L)
  expect_true(all(a$qty > 10))
  expect_s3_class(a$big, "integer64")
  expect_identical(levels(a$product), levels(data$product))
  key <- paste(data$shop_id, data$date, data$product)
  expect_true(all(paste(a$shop_id, a$date, a$product) %in% key))
  few <- store_sample(fx$st, "sales/daily", n = 5, year == 2024, columns = c(shop_id, year), seed = 1)
  expect_named(few, c("shop_id", "year"))
  expect_true(all(few$year == 2024))
  expect_snapshot(all <- store_sample(fx$st, "sales/summary", n = 1000, seed = 1))
  expect_identical(nrow(all), nrow(fx$data[["sales/summary"]]))
  expect_snapshot(store_sample(fx$st, "sales/daily", n = 0), error = TRUE)
})

test_that("store_sample() opens only the row groups it reads", {
  fx <- local_test_store(secondaries = 0L)
  withr::local_options(rcs.trace = TRUE)
  store_sample(fx$st, "sales/daily", n = 5, year == 2024, seed = 3)
  trace <- rcs_trace()
  opened <- unique(trace$detail[trace$counter == "file_open"])
  files <- fx$st$primary$files
  expect_identical(opened, files$path[files$dataset == "sales/daily" & grepl("2024", files$partition_values)])
})

test_that("store_sample() on geospatial data returns sf, or a tibble without geometry", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  s <- store_sample(fx$st, "polygons", n = 10, seed = 2)
  expect_s3_class(s, "sf")
  expect_identical(nrow(s), 10L)
  expect_false(".rcs_id" %in% names(s))
  flat <- store_sample(fx$st, "polygons", n = 10, seed = 2, geometry = FALSE)
  expect_false(inherits(flat, "sf"))
})

test_that("store_glimpse() shows the catalog facts and opens one file", {
  fx <- local_test_store(secondaries = 0L)
  items <- tibble::tibble(
    id = 1:30, year = rep(c(2023L, 2024L), 15), value = seq(0.5, 15, by = 0.5),
    cat = factor(rep(c("a", "b", "c"), 10))
  )
  fixture_write(fx$st, items, "demo/items",
    title = "Items", description = "A small table.", key = "id", partition = "year"
  )
  withr::local_options(rcs.trace = TRUE)
  expect_snapshot(
    store_glimpse(fx$st, "items"),
    transform = function(x) sub("^(Version: +)[0-9a-f]{16}$", "\\1<version>", x)
  )
  trace <- rcs_trace()
  expect_identical(sum(trace$n[trace$counter == "file_open"]), 1)
  out <- withr::with_output_sink(tempfile(), store_glimpse(fx$st, "daily"))
  expect_identical(sum(rcs_trace()$n[rcs_trace()$counter == "file_open"]), 1)
  expect_s3_class(out$big, "integer64")
  zero <- rcs_sim_table(0)
  fixture_write(fx$st, zero, "sales/none", title = "None", description = "Zero rows.")
  shown <- withr::with_output_sink(tempfile(), store_glimpse(fx$st, "sales/none"))
  expect_identical(nrow(shown), 0L)
  expect_identical(levels(shown$product), levels(zero$product))
})

test_that("store_glimpse() of geospatial data", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "points", secondaries = 0L)
  out <- withr::with_output_sink(tempfile(), store_glimpse(fx$st, "points"))
  expect_s3_class(out, "sf")
  expect_false(".rcs_id" %in% names(out))
})

test_that("store_h3_hex() converts cells to hex strings", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  data <- store_read(fx$st, "polygons", geometry = FALSE)
  hex <- store_h3_hex(data)
  partition <- grep("^h3_p[0-9]+$", names(data), value = TRUE)
  expect_type(hex$h3, "character")
  expect_type(hex[[partition]], "character")
  expect_identical(hex$h3, h3_as_hex(data$h3))
  expect_identical(hex$id, data$id)
  only <- store_h3_hex(data, columns = h3)
  expect_s3_class(only[[partition]], "integer64")
  expect_identical(store_h3_hex(data$h3[1:3]), h3_as_hex(data$h3[1:3]))
  sf_data <- store_h3_hex(store_read(fx$st, "polygons"))
  expect_s3_class(sf_data, "sf")
  expect_type(sf_data$h3, "character")
  expect_snapshot(store_h3_hex(5.99686042433355e17), error = TRUE)
})

# Land a raster in every location of a fixture store, as a write would.
fixture_raster <- function(st, r, dataset) {
  dir <- withr::local_tempdir()
  staged <- raster_stage(r, dataset, title = "Grid", description = "A simulated raster.", dir = dir)
  version <- list(
    entry = staged$entry,
    files = staged$files,
    staged = tibble::tibble(path = staged$files$path, local = staged$staged),
    manifest = new_manifest(staged$entry, staged$files)
  )
  for (location in store_locations(st, available_only = TRUE)) {
    fixture_land(st, location, version, keep_history = FALSE)
  }
  invisible(version)
}

test_that("rasters are read as SpatRaster, cropped by intersects, and refuse table arguments", {
  r <- sim_raster()
  fx <- local_test_store(tables = FALSE, secondaries = 0L)
  fixture_raster(fx$st, r, "grids/sim")
  got <- store_read(fx$st, "grids/sim")
  expect_s4_class(got, "SpatRaster")
  expect_identical(names(got), names(r))
  expect_equal(terra::values(got), terra::values(r))
  box <- sf::st_as_sfc(sf::st_bbox(c(xmin = -28, ymin = 7, xmax = -27, ymax = 8), crs = sf::st_crs(4326)))
  cropped <- store_read(fx$st, "grids/sim", intersects = box)
  expect_lt(terra::ncell(cropped), terra::ncell(r))
  e <- as.vector(terra::ext(cropped))
  expect_true(e[["xmin"]] <= -28 && e[["xmax"]] >= -27 && e[["ymin"]] <= 7 && e[["ymax"]] >= 8)
  expect_snapshot(store_read(fx$st, "grids/sim", layer > 1, geometry = FALSE), error = TRUE)
  expect_snapshot(store_read(fx$st, "grids/sim", columns = 1, exact = FALSE), error = TRUE)
  expect_snapshot(store_open(fx$st, "grids/sim"), error = TRUE)
  expect_snapshot(store_sample(fx$st, "grids/sim"), error = TRUE)
  withr::local_options(rcs.trace = TRUE)
  out <- utils::capture.output(shown <- store_glimpse(fx$st, "grids/sim"))
  expect_s4_class(shown, "SpatRaster")
  expect_identical(sum(rcs_trace()$counter == "file_open"), 1L)
  expect_match(out[[1]], "grids/sim (raster)", fixed = TRUE)
})

# Through the public functions only --------------------------------------------

test_that("filters on a difftime column compare in the column's own units", {
  root <- withr::local_tempdir()
  st <- suppressMessages(store_connect(file.path(root, "primary"), create = TRUE))
  values <- c(0.5, 2, NA, 12, 36, 100)
  x <- tibble::tibble(
    id = seq_along(values),
    wait_hours = as.difftime(values, units = "hours"),
    wait_mins = as.difftime(values, units = "mins")
  )
  suppressMessages(store_write(st, x, "waits", title = "Waits", description = "Difftimes.", key = "id"))
  # `wait_hours > 10` means more than 10 hours; `wait_mins > 10` more than 10 minutes.
  expected <- x[!is.na(values) & values > 10 & values <= 50, ]
  expect_identical(store_read(st, "waits", wait_hours > 10, wait_hours <= 50), expected)
  expect_identical(store_read(st, "waits", wait_mins > 10, wait_mins <= 50), expected)
  got <- store_open(st, "waits") |>
    dplyr::filter(wait_hours > 10, wait_hours <= 50) |>
    dplyr::collect()
  expect_identical(got, expected)
  got <- store_open(st, "waits") |>
    dplyr::filter(is.na(wait_mins) | wait_mins < 1) |>
    dplyr::arrange(id) |>
    dplyr::collect()
  expect_identical(got, x[is.na(values) | values < 1, ])
})

test_that("a difftime of any units and fractional value survives store_write() and store_read()", {
  root <- withr::local_tempdir()
  st <- suppressMessages(store_connect(file.path(root, "primary"), create = TRUE))
  values <- c(66.85, 0.125, NA, -3.333333333333, 1e-9, 12345.678901234)
  x <- tibble::tibble(id = seq_along(values))
  for (units in c("secs", "mins", "hours", "days", "weeks")) {
    x[[paste0("wait_", units)]] <- as.difftime(values, units = units)
  }
  suppressMessages(store_write(st, x, "waits", title = "Waits", description = "Fractional difftimes.", key = "id"))
  expect_identical(store_read(st, "waits"), x)
  suppressMessages(store_write(st, x[0, ], "waits_none", title = "None", description = "Zero rows."))
  expect_identical(store_read(st, "waits_none"), x[0, ])
  suppressMessages(store_check(st, "waits", x = x))
  expect_store_valid(st)
})

test_that("tables, geospatial data and rasters go through the public functions end to end", {
  skip_below_level("default")
  skip_if_no_h3()
  skip_if_not_installed("terra")
  root <- withr::local_tempdir()
  paths <- file.path(root, c("primary", "copy1", "copy2"))
  st <- suppressMessages(store_connect(paths[[1]], secondary = paths[-1], create = TRUE, history = TRUE))
  expect_store_valid(st)
  write <- function(x, dataset, ...) {
    suppressMessages(store_write(st, x, dataset, title = "Simulated", description = "Simulated data.", ...))
  }
  read <- function(...) suppressMessages(store_read(st, ...))

  # a partitioned table with a key
  sales <- rcs_sim_table(300, seed = 3)
  write(sales, "sales/daily", key = daily_key, partition = "year")
  expect_store_valid(st)
  expect_same_table(read("sales/daily"), sales, daily_key)

  # polygons, with the antimeridian and pole rows, partitioned by cell
  pol <- rcs_sim_polygons(40, seed = 2, special = TRUE)
  write(pol, "shapes/polygons", partition = "h3")
  expect_store_valid(st)
  got <- read("shapes/polygons")
  expect_s3_class(got, "sf")
  expect_true(sf::st_crs(got) == sf::st_crs(pol))
  expect_true(all(c("h3", "bbox") %in% names(got)))
  expect_true(any(grepl("^h3_p[0-9]+$", names(got))))
  expect_false(".rcs_id" %in% names(got))
  got <- got[order(got$id), ]
  ref <- pol[order(pol$id), ]
  expect_identical(
    sf::st_as_binary(sf::st_geometry(got), EWKB = FALSE),
    sf::st_as_binary(sf::st_geometry(ref), EWKB = FALSE)
  )
  attrs <- setdiff(names(pol), "geometry")
  expect_identical(
    normalise(sf::st_drop_geometry(got)[attrs]),
    normalise(sf::st_drop_geometry(ref)[attrs])
  )

  # a small raster
  r <- rcs_sim_raster(seed = 4, nrow = 30, ncol = 40)
  write(r, "grids/small")
  expect_store_valid(st)
  grid <- read("grids/small")
  expect_s4_class(grid, "SpatRaster")
  expect_identical(names(grid), names(r))
  expect_equal(terra::values(grid), terra::values(r))

  # an update of one partition; the old version stays readable
  old <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  y <- sales[sales$year == max(sales$year), ]
  y$qty <- y$qty + 1L
  write(y, "sales/daily", mode = "update")
  expect_store_valid(st)
  current <- rbind(sales[sales$year != max(sales$year), ], y)
  expect_same_table(read("sales/daily"), current, daily_key)
  expect_false(identical(st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"], old))
  expect_same_table(read("sales/daily", version = old), sales, daily_key)
  expect_store_valid(st)

  # both checks, in every location
  integrity <- suppressMessages(store_check(st, "sales/daily"))
  expect_true(all(integrity$status == "ok"))
  expect_setequal(unique(integrity$location), store_uris(st))
  serial <- suppressMessages(store_check(st, "sales/daily", x = current))
  expect_true(all(serial$status == "ok"))
  expect_true(all(suppressMessages(store_check(st, "shapes/polygons", x = pol))$status == "ok"))
  expect_true(all(suppressMessages(store_check(st, "shapes/polygons"))$status == "ok"))
  expect_true(all(suppressMessages(store_check(st, "grids/small", x = r))$status == "ok"))
  expect_store_valid(st)
})
