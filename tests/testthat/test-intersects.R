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

# Whether an sfc in EPSG:4326 is valid both on the sphere and in the plane.
shape_is_valid <- function(s) {
  all(s2::s2_is_valid(s)) && all(sf::st_is_valid(sf::st_set_crs(s, NA)))
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
      label <- sprintf("polygon %d vertices at %.3f %.3f", k, x, y)
      # a gap of more than 180 degrees between consecutive angles can make the
      # ring cross itself: then take the convex hull of the same vertices
      # (no further random draws, so the other cases keep their draws)
      if (!shape_is_valid(s)) {
        s <- sf::st_set_crs(sf::st_convex_hull(sf::st_set_crs(s, NA)), 4326)
        label <- paste(label, "(convex hull)")
      }
      list(query = s, shape = s, label = label)
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
      if (!all(s2::s2_is_valid(shape))) {
        failures <- c(failures, sprintf("case %d: the generated query is not valid on the sphere: %s", i, rq$label))
        next
      }
      if (projected) {
        # the query is given in the data CRS, so the reference sees the same shape
        query <- if (inherits(query, "bbox")) sf::st_bbox(sf::st_transform(sf::st_as_sfc(query), 32626)) else sf::st_transform(query, 32626)
        shape <- if (inherits(query, "bbox")) sf::st_as_sfc(query) else query
      }
      expected <- sort(ref_filter(data, shape)$id)
      got <- sort(suppressMessages(store_read(st, dataset, intersects = query, exact_engine = "session"))$id)
      label <- sprintf("case %d, %s, s2 %s: %s", i, dataset, if (s2) "on" else "off", rq$label)
      if (!identical(got, expected)) {
        failures <- c(failures, paste0(label, ": got ", paste(got, collapse = " "), "; expected ", paste(expected, collapse = " ")))
      }
      if (i %% 4 == 0) {
        candidates <- suppressMessages(store_read(st, dataset, intersects = query, exact = FALSE, exact_engine = "session"))$id
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

test_that("an invalid query geometry aborts before any file is read", {
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  st <- fx$st
  withr::local_options(rcs.quiet = TRUE)
  ring <- function(x, y) sf::st_sfc(sf::st_polygon(list(cbind(c(x, x[1]), c(y, y[1])))), crs = 4326)
  bow_tie <- ring(c(-28, -27, -27, -28), c(7, 8, 7, 8))
  # two of the self-intersecting rings drawn by the property test's old generator
  drawn <- list(
    ring(
      c(-29.6089, -29.5536, -29.5958, -29.5955, -29.5308),
      c(8.86745, 8.83942, 8.7811, 8.74439, 8.77457)
    ),
    ring(
      c(-28.2011, -28.2048, -28.2096, -28.2072, -28.2155, -28.204),
      c(6.42608, 6.43488, 6.43413, 6.43896, 6.41472, 6.41422)
    )
  )
  for (s2 in c(TRUE, FALSE)) {
    local_s2(s2)
    for (shape in c(list(bow_tie), drawn)) {
      expect_error(store_read(st, "polygons", intersects = shape), class = "rcs_error_argument")
      expect_error(
        store_intersects(store_open(st, "polygons"), shape),
        class = "rcs_error_argument"
      )
    }
    # one invalid geometry among valid ones, and an sf query
    several <- c(sq(-29, 6, -28, 7), bow_tie)
    expect_error(store_read(st, "polygons", intersects = several), class = "rcs_error_argument")
    expect_error(
      store_read(st, "polygons", intersects = sf::st_sf(id = 1, geometry = bow_tie)),
      class = "rcs_error_argument"
    )
  }
  local_s2(TRUE)
  expect_snapshot(store_read(st, "polygons", intersects = bow_tie), error = TRUE)
  local_s2(FALSE)
  expect_snapshot(store_intersects(store_open(st, "polygons"), bow_tie), error = TRUE)
})

test_that("valid query geometries of every kind pass the validity check", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  st <- fx$st
  data <- fx$data[["shapes/polygons"]]
  withr::local_options(rcs.quiet = TRUE)
  pole <- local({
    lon <- seq(-180, 150, by = 30)
    sf::st_sfc(sf::st_polygon(list(cbind(c(lon, lon[1]), rep(89.5, length(lon) + 1)))), crs = 4326)
  })
  across_180 <- sf::st_sfc(sf::st_polygon(list(cbind(
    c(179.6, -179.6, -179.6, 179.6, 179.6), c(7.2, 7.2, 7.8, 7.8, 7.2)
  ))), crs = 4326)
  hull <- sf::st_set_crs(sf::st_convex_hull(sf::st_sfc(sf::st_polygon(list(cbind(
    c(-28, -27, -27, -28, -28), c(7, 8, 7, 8, 7)
  ))))), 4326)
  with_empty <- c(sq(-28, 7, -27, 8), sf::st_sfc(sf::st_polygon(), crs = 4326))
  line <- sf::st_sfc(sf::st_linestring(cbind(c(-28, -27, -27.5, -27.5), c(7, 8, 8, 6.5))), crs = 4326)
  queries <- list(
    box = sf::st_bbox(sq(-28, 7, -27, 8)),
    several = c(sq(-29, 6, -28, 7), sq(-27, 8, -26, 9)),
    sf = sf::st_sf(id = 1:2, geometry = c(sq(-29, 6, -28, 7), sq(-27, 8, -26, 9))),
    hull = hull,
    with_empty = with_empty,
    crossing_line = line
  )
  for (s2 in c(TRUE, FALSE)) {
    local_s2(s2)
    for (name in names(queries)) {
      q <- queries[[name]]
      got <- store_read(st, "polygons", intersects = q)
      shape <- if (inherits(q, "bbox")) sf::st_as_sfc(q) else sf::st_geometry(q)
      shape <- sf::st_transform(shape[!sf::st_is_empty(shape)], 4326)
      expect_setequal(got$id, ref_filter(data, shape)$id)
    }
    # a query in another CRS is checked in the plane of its own CRS
    expect_no_error(store_read(st, "polygons", intersects = sf::st_transform(sq(-28, 7, -27, 8), 32626)))
  }
  local_s2(TRUE)
  expect_no_error(store_read(st, "polygons", intersects = pole))
  expect_no_error(store_read(st, "polygons", intersects = across_180))
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
  expect_snapshot(print(dplyr::arrange(q, id)))
  got <- dplyr::collect(q)
  expected <- ref_filter(ref_filter(data, a), b)
  expect_setequal(got$id, expected$id)
  expect_named(got, c("id", "area"))
  # geocode = FALSE: the box test alone
  q2 <- store_intersects(store_open(fx$st, "polygons"), a, exact = FALSE)
  expect_snapshot(print(dplyr::arrange(q2, id)))
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

# Exact test engines (plan 0002, D34, D35) ------------------------------------

# 20 valid polygons, the two polygons of fact 18 (ids 21, 22, invalid on the
# sphere) and the long-edge polygon of fact 20 (id 23), in EPSG:4326.
engine_data <- function() {
  x <- geo_with_invalid()
  x$id <- as.integer(x$id)
  long <- sf::st_sf(id = 23L, geometry = geo_sfc_of_wkt(geo_long_edge_wkt()))
  rbind(x, long)
}

# Inside the long-edge polygon in the plane, outside on the sphere (its
# southern edge bulges north to about 10.24 degrees at this longitude).
engine_point <- function(crs = 4326) {
  p <- sf::st_sfc(sf::st_point(c(-27.5, 10.1)), crs = 4326)
  if (crs == 4326) p else sf::st_transform(p, crs)
}

# Overlaps the southern edge of both fact-18 polygons by 1e-5 degrees in the
# plane, and misses them on the sphere (their edge bulges about 2e-5 north).
engine_box <- function() sq(-27.15, 7.09, -27.1, 7.10001)

engine_cache <- new.env(parent = emptyenv())

# A store with the engine data written by store_write() with each engine
# ("eng/auto", "eng/s2", "eng/planar"), before plan 0002 (engine NA,
# "eng/old"), and projected in EPSG:3857 with engine "s2" ("eng/proj").
engine_store <- function() {
  if (is.null(engine_cache$st)) {
    dir <- withr::local_tempdir(.local_envir = testthat::teardown_env())
    st <- store_connect(file.path(dir, "store"), create = TRUE)
    data <- engine_data()
    quiet_write <- function(x, dataset, ...) {
      withCallingHandlers(
        store_write(st, x, dataset, title = dataset, description = "Engine test data.", ...),
        rcs_warning_s2_rebuild = function(w) invokeRestart("muffleWarning")
      )
    }
    withr::with_options(list(rcs.quiet = TRUE), {
      for (engine in c("auto", "s2", "planar")) {
        quiet_write(data, paste0("eng/", engine), geocode_engine = engine)
      }
      quiet_write(sf::st_transform(data, 3857), "eng/proj", geocode_engine = "s2")
      fixture_write(st, data, "eng/old", title = "Old", description = "Written before plan 0002.")
    })
    engine_cache$st <- store_connect(file.path(dir, "store"))
    engine_cache$data <- data
  }
  list(st = engine_cache$st, data = engine_cache$data)
}

engine_ids <- function(st, dataset, query, ...) {
  sort(suppressMessages(store_read(st, dataset, intersects = query, ...))$id)
}

test_that("the engine store records the engines", {
  es <- engine_store()
  catalog <- es$st$primary$catalog
  engines <- catalog$geocode_engine[match(
    c("eng/auto", "eng/s2", "eng/planar", "eng/proj", "eng/old"), catalog$dataset
  )]
  expect_identical(engines, c("auto", "s2", "planar", "s2", NA))
})

test_that("(a) a dataset written with planar is tested in the plane with s2 on", {
  es <- engine_store()
  local_s2(TRUE)
  expect_true(23L %in% engine_ids(es$st, "eng/planar", engine_point()))
  expect_true(all(c(21L, 22L) %in% engine_ids(es$st, "eng/planar", engine_box())))
  q <- store_intersects(store_open(es$st, "eng/planar"), engine_point())
  expect_true(23L %in% suppressMessages(dplyr::collect(q))$id)
})

test_that("(b) a dataset written with s2 is tested on the sphere with s2 off", {
  es <- engine_store()
  local_s2(FALSE)
  expect_false(23L %in% engine_ids(es$st, "eng/s2", engine_point()))
  # the invalid rows are rebuilt on the sphere, as the write did; no error
  expect_no_error(got <- engine_ids(es$st, "eng/s2", engine_box()))
  expect_false(any(c(21L, 22L) %in% got))
  wide <- sq(-30, 6, -24, 9)
  expect_true(all(c(21L, 22L) %in% engine_ids(es$st, "eng/s2", wide)))
})

test_that("(c) auto: invalid rows in the plane, valid rows on the sphere, no s2 error", {
  es <- engine_store()
  data <- es$data
  for (s2 in c(TRUE, FALSE)) {
    local_s2(s2)
    expect_no_error(got <- engine_ids(es$st, "eng/auto", engine_box()))
    expect_true(all(c(21L, 22L) %in% got))
    expect_false(23L %in% engine_ids(es$st, "eng/auto", engine_point()))
  }
  # the whole answer for a wide query against the per-row reference
  local_s2(TRUE)
  wide <- suppressMessages(sf::st_union(c(sq(-30, 6, -24, 9), sq(-27.6, 10.05, -27.4, 10.15))))
  geog <- s2::as_s2_geography(sf::st_as_binary(sf::st_geometry(data)), check = FALSE)
  valid <- s2::s2_is_valid(geog)
  sphere <- s2::s2_intersects(geog[valid], s2::as_s2_geography(sf::st_as_binary(wide)))
  plane <- without_s2(lengths(sf::st_intersects(data[!valid, ], wide)) > 0)
  expected <- sort(c(data$id[valid][sphere], data$id[!valid][plane]))
  expect_identical(engine_ids(es$st, "eng/auto", wide), expected)
  expect_true(all(c(21L, 22L) %in% expected))
})

test_that("(d) a dataset written before plan 0002 follows the session's s2 setting", {
  es <- engine_store()
  local_s2(FALSE)
  expect_true(23L %in% engine_ids(es$st, "eng/old", engine_point()))
  expect_true(all(c(21L, 22L) %in% engine_ids(es$st, "eng/old", engine_box())))
  local_s2(TRUE)
  expect_false(23L %in% engine_ids(es$st, "eng/old", engine_point()))
})

test_that("(e) an explicit exact_engine overrides the dataset's engine", {
  es <- engine_store()
  st <- es$st
  local_s2(TRUE)
  expect_false(23L %in% engine_ids(st, "eng/planar", engine_point(), exact_engine = "s2"))
  expect_true(23L %in% engine_ids(st, "eng/s2", engine_point(), exact_engine = "planar"))
  expect_false(23L %in% engine_ids(st, "eng/auto", engine_point(), exact_engine = "session"))
  local_s2(FALSE)
  expect_true(23L %in% engine_ids(st, "eng/auto", engine_point(), exact_engine = "session"))
  expect_true(23L %in% engine_ids(st, "eng/planar", engine_point(), exact_engine = "session"))
  q <- store_intersects(store_open(st, "eng/planar"), engine_point(), exact_engine = "s2")
  expect_false(23L %in% suppressMessages(dplyr::collect(q))$id)
  expect_snapshot(store_read(st, "eng/auto", intersects = engine_point(), exact_engine = "sphere"), error = TRUE)
  expect_snapshot(store_intersects(store_open(st, "eng/auto"), engine_point(), exact_engine = NA), error = TRUE)
})

test_that("(f) auto read in the plane equals planar st_intersects() for bbox, sf and cells", {
  skip_if_no_h3()
  es <- engine_store()
  data <- es$data
  local_s2(TRUE)
  cell <- as.character(h3o::h3_from_xy(7.1, -27.12, 7L))
  queries <- list(
    bbox = list(query = sf::st_bbox(engine_box()), shape = engine_box()),
    sf = list(query = sf::st_sf(id = 1, geometry = engine_box()), shape = engine_box()),
    wide = list(query = sq(-27.3, 7, -26.95, 7.25), shape = sq(-27.3, 7, -26.95, 7.25)),
    cells = list(query = cell, shape = sf::st_set_crs(sf::st_as_sfc(h3o::h3_from_strings(cell)), 4326))
  )
  for (name in names(queries)) {
    got <- engine_ids(es$st, "eng/auto", queries[[name]]$query, exact_engine = "planar")
    expected <- without_s2(sort(data$id[lengths(sf::st_intersects(data, queries[[name]]$shape)) > 0]))
    expect_identical(got, expected, info = name)
  }
  expect_true(all(c(21L, 22L) %in% engine_ids(es$st, "eng/auto", engine_box(), exact_engine = "planar")))
})

test_that("(g) projected data are tested in the plane of the data CRS whatever the engine", {
  es <- engine_store()
  p <- engine_point(3857)
  for (s2 in c(TRUE, FALSE)) {
    local_s2(s2)
    expect_true(23L %in% engine_ids(es$st, "eng/proj", p))
    for (engine in c("s2", "planar", "session")) {
      expect_true(23L %in% engine_ids(es$st, "eng/proj", p, exact_engine = engine), info = engine)
    }
  }
  long <- sf::st_transform(geo_sfc_of_wkt(geo_long_edge_wkt()), 3857)
  for (engine in c("s2", "auto", "planar", "session")) {
    expect_identical(exact_keep(long, p, engine, geographic = FALSE), TRUE, info = engine)
  }
})

test_that("exact_keep() follows the engine for geographic data", {
  g <- c(geo_sfc_of_wkt(geo_long_edge_wkt()), geo_sfc_of_wkt(geo_invalid_wkt()))
  shape <- suppressMessages(sf::st_union(c(engine_point(), engine_box())))
  local_s2(FALSE)
  expect_identical(exact_keep(g, shape, "planar", TRUE), c(TRUE, TRUE, TRUE))
  expect_identical(exact_keep(g, shape, "s2", TRUE), c(FALSE, FALSE, FALSE))
  expect_identical(exact_keep(g, shape, "auto", TRUE), c(FALSE, TRUE, TRUE))
  expect_identical(exact_keep(g, shape, "session", TRUE), c(TRUE, TRUE, TRUE))
  local_s2(TRUE)
  expect_identical(exact_keep(g[1], shape, "session", TRUE), FALSE)
  expect_identical(exact_keep(g[0], shape, "auto", TRUE), logical())
  empty <- sf::st_sfc(sf::st_polygon(), crs = 4326)
  for (engine in c("s2", "auto", "planar", "session")) {
    expect_identical(exact_keep(empty, shape, engine, TRUE), FALSE, info = engine)
  }
})

test_that("(h) the query validity check follows the engine, and advises planar", {
  es <- engine_store()
  st <- es$st
  dup <- geo_sfc_of_wkt(geo_invalid_wkt()[["duplicate"]])
  for (s2 in c(TRUE, FALSE)) {
    local_s2(s2)
    for (dataset in c("eng/auto", "eng/s2")) {
      expect_error(store_read(st, dataset, intersects = dup), class = "rcs_error_argument")
      expect_error(store_intersects(store_open(st, dataset), dup), class = "rcs_error_argument")
      expect_true(all(c(21L, 22L) %in% engine_ids(st, dataset, dup, exact_engine = "planar")))
    }
    expect_true(all(c(21L, 22L) %in% engine_ids(st, "eng/planar", dup)))
    expect_true(all(c(21L, 22L) %in% engine_ids(st, "eng/proj", sf::st_transform(dup, 3857))))
  }
  local_s2(TRUE)
  expect_error(store_read(st, "eng/old", intersects = dup), class = "rcs_error_argument")
  expect_error(store_read(st, "eng/planar", intersects = dup, exact_engine = "session"), class = "rcs_error_argument")
  local_s2(FALSE)
  expect_true(all(c(21L, 22L) %in% engine_ids(st, "eng/old", dup)))
  local_s2(TRUE)
  expect_snapshot(store_read(st, "eng/auto", intersects = dup), error = TRUE)
  expect_snapshot(store_intersects(store_open(st, "eng/s2"), dup), error = TRUE)
  expect_snapshot(store_read(st, "eng/old", intersects = dup), error = TRUE)
})
