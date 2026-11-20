# A store with every geospatial case of the property test, built once per
# test run: the fixture's partitioned polygons, `geocode = FALSE` polygons,
# points and lines, plus unpartitioned polygons, the same polygons in a
# projected CRS (one file and partitioned), and polygons with the
# antimeridian and pole rows.
spatial_cache <- new.env(parent = emptyenv())

spatial_store <- function() {
  if (is.null(spatial_cache$st)) {
    fx <- local_test_store(geospatial = TRUE, secondaries = 0L, frame = testthat::teardown_env())
    st <- fx$st
    base <- fx$data[["shapes/polygons"]]
    projected <- sf::st_transform(base, 32626)
    special <- rcs_sim_polygons(60, seed = 4, special = TRUE)
    fixture_write(st, base, "plain/polygons", title = "Plain", description = "Polygons in one file.")
    fixture_write(st, projected, "proj/polygons", title = "Projected", description = "Projected polygons.")
    fixture_write(st, projected, "proj/split",
      title = "Projected split", description = "Projected polygons by cell.", partition = "h3"
    )
    fixture_write(st, special, "special/polygons", title = "Special", description = "Antimeridian and pole.")
    spatial_cache$st <- st
    spatial_cache$data <- c(fx$data, list(
      "plain/polygons" = base, "proj/polygons" = projected, "proj/split" = projected,
      "special/polygons" = special
    ))
  }
  list(st = spatial_cache$st, data = spatial_cache$data)
}

local_s2 <- function(on, frame = parent.frame()) {
  old <- suppressMessages(sf::sf_use_s2(on))
  withr::defer(suppressMessages(sf::sf_use_s2(old)), envir = frame)
}

ref_filter <- function(data, q) {
  data <- data[!sf::st_is_empty(data), ]
  suppressMessages(sf::st_filter(data, q))
}

sq <- function(xmin, ymin, xmax, ymax, crs = 4326) {
  sf::st_as_sfc(sf::st_bbox(c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax), crs = sf::st_crs(crs)))
}

# A random query near the simulated data (EPSG:4326): an sf shape or H3
# cells. Returns `list(query, shape, label)`: `query` is given to the
# read, `shape` (an sfc in EPSG:4326) to the reference.
random_query <- function(data, cells_ok = TRUE) {
  anchor <- if (stats::runif(1) < 0.6) {
    xy <- coords_of(data[!sf::st_is_empty(data), ])
    xy[sample.int(nrow(xy), 1), ]
  } else {
    c(X = stats::runif(1, -30, -24), Y = stats::runif(1, 6, 9))
  }
  x <- anchor[["X"]]
  y <- anchor[["Y"]]
  kinds <- c("rect", "strip", "poly", "hole", "point", "line", "bbox", if (cells_ok) c("cell", "cell"))
  kind <- sample(kinds, 1)
  poly <- function(px, py) sf::st_polygon(list(cbind(c(px, px[1]), c(py, py[1]))))
  sfc <- function(g) sf::st_sfc(g, crs = 4326)
  switch(kind,
    rect = {
      w <- exp(stats::runif(1, log(0.005), log(1.5)))
      h <- exp(stats::runif(1, log(0.005), log(1.5)))
      s <- sq(x - w, y - h, x + w, y + h)
      list(query = s, shape = s, label = sprintf("rect %.3f x %.3f at %.3f %.3f", w, h, x, y))
    },
    strip = {
      len <- stats::runif(1, 0.5, 4)
      wid <- stats::runif(1, 0.001, 0.01)
      a <- stats::runif(1, 0, pi)
      dx <- cos(a) * len / 2
      dy <- sin(a) * len / 2
      nx <- -sin(a) * wid / 2
      ny <- cos(a) * wid / 2
      s <- sfc(poly(c(x - dx + nx, x + dx + nx, x + dx - nx, x - dx - nx), c(y - dy + ny, y + dy + ny, y + dy - ny, y - dy - ny)))
      list(query = s, shape = s, label = sprintf("strip %.2f at %.3f %.3f", len, x, y))
    },
    poly = {
      k <- sample(5:9, 1)
      r <- exp(stats::runif(1, log(0.01), log(0.8))) * stats::runif(k, 0.4, 1)
      a <- sort(stats::runif(k, 0, 2 * pi))
      s <- sfc(poly(x + r * cos(a), y + r * sin(a)))
      list(query = s, shape = s, label = sprintf("polygon %d vertices at %.3f %.3f", k, x, y))
    },
    hole = {
      w <- stats::runif(1, 0.05, 1)
      outer <- cbind(c(x - w, x + w, x + w, x - w, x - w), c(y - w, y - w, y + w, y + w, y - w))
      inner <- cbind(c(x - w / 2, x - w / 2, x + w / 2, x + w / 2, x - w / 2), c(y - w / 2, y + w / 2, y + w / 2, y - w / 2, y - w / 2))
      s <- sfc(sf::st_polygon(list(outer, inner)))
      list(query = s, shape = s, label = sprintf("polygon with hole %.2f at %.3f %.3f", w, x, y))
    },
    point = {
      s <- sfc(sf::st_point(c(x, y)))
      list(query = s, shape = s, label = sprintf("point %.4f %.4f", x, y))
    },
    line = {
      k <- sample(2:4, 1)
      s <- sfc(sf::st_linestring(cbind(x + cumsum(c(0, stats::rnorm(k - 1, 0, 0.3))), y + cumsum(c(0, stats::rnorm(k - 1, 0, 0.3))))))
      list(query = s, shape = s, label = sprintf("line %d vertices at %.3f %.3f", k, x, y))
    },
    bbox = {
      w <- stats::runif(1, 0.01, 1)
      b <- sf::st_bbox(c(xmin = x - w, ymin = y - w, xmax = x + w, ymax = y + w), crs = sf::st_crs(4326))
      list(query = b, shape = sf::st_as_sfc(b), label = sprintf("bbox %.2f at %.3f %.3f", w, x, y))
    },
    cell = {
      res <- sample(2:9, 1)
      hex <- as.character(h3o::h3_from_xy(y, x, as.integer(res)))
      if (stats::runif(1) < 0.3) {
        ring <- unlist(lapply(h3o::grid_disk(h3o::h3_from_strings(hex), 1L), as.character))
        hex <- unique(c(hex, sample(ring, 2)))
      }
      form <- sample(c("hex", "int64", "H3"), 1)
      query <- switch(form,
        hex = hex,
        int64 = h3_as_int64(hex),
        H3 = h3o::h3_from_strings(hex)
      )
      shape <- sf::st_set_crs(sf::st_as_sfc(h3o::h3_from_strings(hex)), 4326)
      list(query = query, shape = shape, label = sprintf("%d cell(s) of resolution %d as %s at %.3f %.3f", length(hex), res, form, x, y))
    }
  )
}

test_that("spatial reads equal sf::st_filter() for random queries (property test)", {
  skip_below_level("default")
  skip_if_no_h3()
  sp <- spatial_store()
  st <- sp$st
  cases <- property_cases(default = 200L, full = 2000L, cran = 10L)
  datasets <- c(
    "shapes/polygons", "plain/polygons", "polygons", "proj/polygons", "proj/split",
    "shapes/points", "shapes/lines"
  )
  failures <- character()
  withr::local_options(rcs.quiet = TRUE)
  withr::with_seed(20261120, {
    for (i in seq_len(cases)) {
      dataset <- datasets[[(i - 1) %% length(datasets) + 1]]
      data <- sp$data[[dataset]]
      projected <- !isTRUE(sf::st_is_longlat(data))
      data_4326 <- if (projected) sf::st_transform(data, 4326) else data
      s2 <- stats::runif(1) < 0.5
      local_s2(s2)
      rq <- random_query(data_4326, cells_ok = !projected)
      query <- rq$query
      shape <- rq$shape
      if (projected) {
        # the query is given in the data CRS, so the reference sees the same shape
        query <- if (inherits(query, "bbox")) sf::st_bbox(sf::st_transform(sf::st_as_sfc(query), 32626)) else sf::st_transform(query, 32626)
        shape <- if (inherits(query, "bbox")) sf::st_as_sfc(query) else query
      }
      expected <- sort(ref_filter(data, shape)$id)
      got <- sort(suppressMessages(store_read(st, dataset, intersects = query))$id)
      label <- sprintf("case %d, %s, s2 %s: %s", i, dataset, if (s2) "on" else "off", rq$label)
      if (!identical(got, expected)) {
        failures <- c(failures, paste0(label, ": got ", paste(got, collapse = " "), "; expected ", paste(expected, collapse = " ")))
      }
      if (i %% 4 == 0) {
        candidates <- suppressMessages(store_read(st, dataset, intersects = query, exact = FALSE))$id
        if (!all(expected %in% candidates)) {
          failures <- c(failures, paste0(label, ": exact = FALSE misses ", paste(setdiff(expected, candidates), collapse = " ")))
        }
      }
    }
  })
  expect(length(failures) == 0, paste(c("Spatial reads differ from sf::st_filter():", utils::head(failures, 10)), collapse = "\n"))
})

test_that("antimeridian and pole rows are found from either side and not from the main box", {
  skip_below_level("default")
  skip_if_no_h3()
  sp <- spatial_store()
  data <- sp$data[["special/polygons"]]
  ids <- data$id[c(nrow(data) - 1, nrow(data))]
  local_s2(TRUE)
  withr::local_options(rcs.quiet = TRUE)
  ring <- function(lat) {
    lon <- seq(-180, 150, by = 30)
    sf::st_sfc(sf::st_polygon(list(cbind(c(lon, lon[1]), c(rep(lat, length(lon)), lat)))), crs = 4326)
  }
  queries <- list(
    west_of_180 = list(q = sq(179.3, 7.3, 179.7, 7.7), expect = ids[[1]]),
    east_of_180 = list(q = sq(-179.7, 7.3, -179.3, 7.7), expect = ids[[1]]),
    across_180 = list(
      q = sf::st_sfc(sf::st_polygon(list(cbind(c(179.6, -179.6, -179.6, 179.6, 179.6), c(7.2, 7.2, 7.8, 7.8, 7.2)))), crs = 4326),
      expect = ids[[1]]
    ),
    pole = list(q = ring(89.5), expect = ids[[2]]),
    cell_at_180 = list(q = as.character(h3o::h3_from_xy(7.5, 179.5, 4L)), expect = ids[[1]]),
    main_box = list(q = sq(-30, 6, -24, 9), expect = integer())
  )
  for (name in names(queries)) {
    q <- queries[[name]]$q
    shape <- if (is.character(q)) sf::st_set_crs(sf::st_as_sfc(h3o::h3_from_strings(q)), 4326) else q
    got <- store_read(sp$st, "special/polygons", intersects = q)$id
    expect_setequal(got, ref_filter(data, shape)$id)
    special_got <- intersect(got, ids)
    expect_identical(sort(special_got), sort(queries[[name]]$expect), info = name)
  }
})

test_that("H3 cells as hex, integer64 and H3 give the same rows; a plain number aborts", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  withr::local_options(rcs.quiet = TRUE)
  hex <- as.character(h3o::h3_from_xy(7.5, -27.5, 4L))
  a <- store_read(fx$st, "polygons", intersects = hex)
  b <- store_read(fx$st, "polygons", intersects = h3_as_int64(hex))
  d <- store_read(fx$st, "polygons", intersects = h3o::h3_from_strings(hex))
  expect_gt(nrow(a), 0)
  expect_identical(a, b)
  expect_identical(a, d)
  expect_snapshot(store_read(fx$st, "polygons", intersects = 599686042433355775), error = TRUE)
  expect_error(store_read(fx$st, "polygons", intersects = 1), class = "rcs_error_h3_input")
  expect_snapshot(store_read(fx$st, "polygons", intersects = "not a cell"), error = TRUE)
})

test_that("a cell finer than the stored resolution informs, and gives the exact rows", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  data <- fx$data[["shapes/polygons"]]
  xy <- coords_of(data[1, ])[1, ]
  hex <- as.character(h3o::h3_from_xy(xy[["Y"]], xy[["X"]], 8L))
  expect_snapshot(got <- store_read(fx$st, "polygons", intersects = hex))
  shape <- sf::st_set_crs(sf::st_as_sfc(h3o::h3_from_strings(hex)), 4326)
  expect_setequal(got$id, ref_filter(data, shape)$id)
})

test_that("exact = FALSE and geometry = FALSE return the candidate set with a message", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  q <- sq(-28, 7, -27, 8)
  exact <- store_read(fx$st, "polygons", intersects = q)
  expect_snapshot(loose <- store_read(fx$st, "polygons", intersects = q, exact = FALSE))
  expect_snapshot(flat <- store_read(fx$st, "polygons", intersects = q, geometry = FALSE))
  expect_true(all(exact$id %in% loose$id))
  expect_setequal(flat$id, loose$id)
  expect_false(inherits(flat, "sf"))
  expect_s3_class(loose, "sf")
})

test_that("a spatial filter on a table aborts", {
  fx <- local_test_store(secondaries = 0L)
  expect_snapshot(store_read(fx$st, "sales/daily", intersects = sq(-28, 7, -27, 8)), error = TRUE)
  expect_error(
    store_intersects(store_open(fx$st, "sales/daily"), sq(-28, 7, -27, 8)),
    class = "rcs_error_argument"
  )
  expect_snapshot(store_intersects(store_open(fx$st, "sales/daily"), sq(-28, 7, -27, 8), exact = NA), error = TRUE)
})

test_that("a spatial query opens only the files whose box and cell range match", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  withr::local_options(rcs.trace = TRUE, rcs.quiet = TRUE)
  st <- fx$st
  q <- sq(-28, 7, -27.5, 7.5)
  got <- store_read(st, "polygons", intersects = q)
  trace <- rcs_trace()
  files <- st$primary$files
  data_files <- files[files$dataset == "shapes/polygons", ]
  index_files <- files$path[files$dataset == "shapes/polygons__h3"]
  opened <- trace$detail[trace$counter == "file_open"]
  opened_data <- setdiff(opened, index_files)
  expect_lt(length(opened_data), nrow(data_files))
  box <- data_files$bbox[match(opened_data, data_files$path), ]
  expect_true(all(box$xmin <= -27.5 & box$xmax >= -28 & box$ymin <= 7.5 & box$ymax >= 7))
  # every file holding a result row is opened
  full <- store_read(st, "polygons", geometry = FALSE)
  wanted <- unique(as.character(full$h3_p4[full$id %in% got$id]))
  holding <- data_files$path[vapply(data_files$partition_values, function(v) {
    any(vapply(wanted, function(w) grepl(w, v, fixed = TRUE), logical(1)))
  }, logical(1))]
  expect_true(all(holding %in% opened_data))
  # candidate and row-group counters
  store_read(st, "polygons", intersects = q)
  trace <- rcs_trace()
  n <- function(counter) sum(trace$n[trace$counter == counter])
  expect_equal(n("rows_returned"), nrow(got))
  expect_gte(n("rows_candidate"), n("rows_returned"))
  expect_lte(n("rows_candidate"), 3 * max(1, n("rows_returned")))
  expect_lte(n("row_groups_overlap"), n("row_groups_total"))
  expect_gt(n("row_groups_total"), 0)
})

test_that("candidate rows per returned row stay small for cells of resolutions 5 to 9", {
  skip_below_level("default")
  skip_if_no_h3()
  sp <- spatial_store()
  data <- sp$data[["plain/polygons"]]
  withr::local_options(rcs.trace = TRUE, rcs.quiet = TRUE)
  xy <- coords_of(data[!sf::st_is_empty(data), ])
  ratios <- c()
  withr::with_seed(7, {
    for (res in 5:9) {
      for (k in 1:4) {
        p <- xy[sample.int(nrow(xy), 1), ]
        hex <- as.character(h3o::h3_from_xy(p[["Y"]], p[["X"]], res))
        got <- store_read(sp$st, "plain/polygons", intersects = hex)
        trace <- rcs_trace()
        candidates <- sum(trace$n[trace$counter == "rows_candidate"])
        ratios <- c(ratios, candidates / max(1, nrow(got)))
      }
    }
  })
  # stated bound on the simulated data: at most 10 candidates per returned row
  expect_true(all(ratios <= 10))
})

test_that("store_intersects() combines with other verbs and with a second query", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = c("polygons", "flat"), secondaries = 0L)
  data <- fx$data[["shapes/polygons"]]
  a <- sq(-29, 6, -26, 9)
  b <- sq(-27, 6, -24, 9)
  q <- store_open(fx$st, "shapes/polygons") |>
    dplyr::select(id, area) |>
    store_intersects(a) |>
    store_intersects(b)
  expect_snapshot(q)
  got <- dplyr::collect(q)
  expected <- ref_filter(ref_filter(data, a), b)
  expect_setequal(got$id, expected$id)
  expect_named(got, c("id", "area"))
  # geocode = FALSE: the box test alone
  q2 <- store_intersects(store_open(fx$st, "polygons"), a, exact = FALSE)
  expect_snapshot(q2)
  expect_snapshot(loose <- dplyr::collect(q2))
  expect_true(all(ref_filter(fx$data[["polygons"]], a)$id %in% loose$id))
})

test_that("a spatial read of an earlier version uses the box test and is exact", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L, history = TRUE)
  st <- fx$st
  old <- fx$data[["shapes/polygons"]]
  new <- rcs_sim_polygons(40, seed = 9)
  fixture_write(st, new, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons in open ocean.", partition = "h3"
  )
  history <- history_read(st$primary$backend)
  version <- unique(history$version[history$dataset == "shapes/polygons"])
  expect_length(version, 1)
  q <- sq(-29, 6.5, -26, 8.5)
  withr::local_options(rcs.quiet = TRUE)
  got <- store_read(st, "polygons", intersects = q, version = version)
  expect_setequal(got$id, ref_filter(old, q)$id)
  current <- store_read(st, "polygons", intersects = q)
  expect_setequal(current$id, ref_filter(new, q)$id)
})
