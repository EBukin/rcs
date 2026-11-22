# store_intersects() on a DuckDB table made by store_open(engine = "duckdb")
# (plan 0002, D28, D35): the candidate test in SQL, the exact test in R at
# collect() or in DuckDB (exact = "sql"); the rows equal the Arrow path's.

# 2,000 polygons (with the antimeridian and pole rows) and 20,000 points
# partitioned by cell, written once per test run.
duckdb_spatial_cache <- new.env(parent = emptyenv())

duckdb_spatial_store <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
  skip_if_no_h3()
  if (is.null(duckdb_spatial_cache$st)) {
    root <- withr::local_tempdir(.local_envir = testthat::teardown_env())
    withr::with_options(list(rcs.quiet = TRUE), {
      st <- store_connect(root, create = TRUE)
      store_write(st, rcs_sim_polygons(2000, seed = 7, special = TRUE), "shapes/polygons",
        title = "Polygons", description = "Simulated polygons.", key = "id"
      )
      store_write(st, rcs_sim_points(20000, seed = 7), "shapes/points",
        title = "Points", description = "Simulated points.", key = "id", partition = "h3"
      )
    })
    withr::defer(store_duckdb_close(st), envir = testthat::teardown_env())
    duckdb_spatial_cache$st <- st
  }
  duckdb_spatial_cache$st
}

# A small store: 40 polygons and a key table, quiet for the calling frame.
duckdb_small_store <- function(frame = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
  skip_if_no_h3()
  withr::local_options(rcs.quiet = TRUE, .local_envir = frame)
  root <- withr::local_tempdir(.local_envir = frame)
  st <- store_connect(root, create = TRUE)
  store_write(st, rcs_sim_polygons(40, seed = 1), "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", key = "id"
  )
  store_write(st, rcs_sim_table(50, seed = 1), "sales/daily",
    title = "Daily", description = "Simulated daily table.",
    key = c("shop_id", "date", "product")
  )
  withr::defer(store_duckdb_close(st), envir = frame)
  st
}

dsq <- function(xmin, ymin, xmax, ymax) {
  sf::st_as_sfc(sf::st_bbox(c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax), crs = sf::st_crs(4326)))
}

dpoly <- function(x, y) {
  sf::st_sfc(sf::st_polygon(list(cbind(c(x, x[1]), c(y, y[1])))), crs = 4326)
}

# The queries of the work package, in EPSG:4326 near the simulated data.
duckdb_queries <- function() {
  centre <- h3o::h3_from_xy(7.5, -27.5, 5L)
  ring <- unlist(lapply(h3o::grid_disk(centre, 1L), as.character))
  cells <- unique(c(as.character(centre), ring[2:3]))
  outer <- cbind(c(-28, -26.5, -26.5, -28, -28), c(7, 7, 8.5, 8.5, 7))
  inner <- cbind(c(-27.6, -27.6, -26.9, -26.9, -27.6), c(7.4, 8.1, 8.1, 7.4, 7.4))
  list(
    cells = cells,
    strip = dpoly(c(-29.5, -24.5, -24.495, -29.495), c(6.2, 8.8, 8.81, 6.21)),
    hole = sf::st_sfc(sf::st_polygon(list(outer, inner)), crs = 4326),
    bbox = sf::st_bbox(c(xmin = -27.3, ymin = 7.2, xmax = -26.6, ymax = 7.9), crs = sf::st_crs(4326)),
    antimeridian = dpoly(c(179.6, -179.6, -179.6, 179.6), c(7.2, 7.2, 7.8, 7.8))
  )
}

arrow_rows <- function(st, dataset, q, ...) {
  out <- store_open(st, dataset) |>
    store_intersects(q, ...) |>
    dplyr::collect()
  out[order(out$id), ]
}

duckdb_rows <- function(st, dataset, q, mode = "native", ...) {
  out <- store_open(st, dataset, engine = "duckdb", mode = mode) |>
    store_intersects(q, ...) |>
    dplyr::collect()
  out[order(out$id), ]
}

test_that("exact = TRUE returns the rows of the Arrow path in both modes", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  queries <- duckdb_queries()
  for (dataset in c("polygons", "points")) {
    for (name in names(queries)) {
      want <- arrow_rows(st, dataset, queries[[name]])
      if (dataset == "polygons" && name != "antimeridian") {
        expect_gt(nrow(want), 0)
      }
      for (mode in c("native", "arrow")) {
        got <- duckdb_rows(st, dataset, queries[[name]], mode = mode)
        expect_identical(got$id, want$id, info = paste(dataset, name, mode))
      }
    }
  }
  # the antimeridian query finds the special row through the cells
  expect_identical(arrow_rows(st, "polygons", queries$antimeridian)$id, 2001L)
})

test_that("exact = FALSE returns the Arrow path's candidate set, with its message", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  queries <- duckdb_queries()
  for (dataset in c("polygons", "points")) {
    for (name in names(queries)) {
      want <- arrow_rows(st, dataset, queries[[name]], exact = FALSE)
      for (mode in c("native", "arrow")) {
        got <- duckdb_rows(st, dataset, queries[[name]], mode = mode, exact = FALSE)
        expect_identical(nrow(got), nrow(want), info = paste(dataset, name, mode))
        expect_identical(got$id, want$id, info = paste(dataset, name, mode))
      }
    }
  }
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(
    got <- duckdb_rows(st, "polygons", queries$bbox, exact = FALSE)
  )
})

test_that("exact = 'sql' returns the planar rows of the Arrow path, lazily", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  # the package-level connection of the store, with spatial loaded (or skip)
  x <- store_open(st, "polygons", engine = "duckdb")
  local_duckdb_spatial(dbplyr::remote_con(x))
  queries <- duckdb_queries()
  queries$antimeridian <- NULL
  for (dataset in c("polygons", "points")) {
    for (name in names(queries)) {
      want <- arrow_rows(st, dataset, queries[[name]], exact_engine = "planar")
      for (mode in c("native", "arrow")) {
        q <- store_open(st, dataset, engine = "duckdb", mode = mode) |>
          store_intersects(queries[[name]], exact = "sql")
        expect_match(dbplyr::sql_render(q), "ST_Intersects", fixed = TRUE)
        expect_identical(.subset2(q, "rcs")$tests, list())
        got <- dplyr::collect(q)
        got <- got[order(got$id), ]
        expect_identical(got$id, want$id, info = paste(dataset, name, mode))
      }
    }
  }
})

test_that("the SQL holds the index subquery only when spatial_use_cells() says so", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  entry <- st$primary$catalog[st$primary$catalog$dataset == "shapes/polygons", ]
  queries <- duckdb_queries()
  used <- vapply(queries, function(q) {
    spatial_use_cells(geo_covering(q, entry$h3_res, entry$crs))
  }, logical(1))
  expect_true(used[["strip"]])
  expect_true(used[["antimeridian"]])
  expect_false(used[["bbox"]])
  for (name in names(queries)) {
    sql <- dbplyr::sql_render(
      store_intersects(store_open(st, "polygons", engine = "duckdb"), queries[[name]])
    )
    expect_identical(grepl("polygons__h3", sql, fixed = TRUE), used[[name]], info = name)
    expect_identical(grepl("h3 IN", sql, fixed = TRUE), used[[name]], info = name)
    # the box test, skipped for a query across the antimeridian
    expect_identical(grepl("bbox", sql, fixed = TRUE), name != "antimeridian", info = name)
  }
})

test_that("above 10,000 cells the cells go through a temporary table", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  # a square frame 40 degrees wide whose west band crosses the data
  outer <- cbind(c(-28, 12, 12, -28, -28), c(-20, -20, 20, 20, -20))
  inner <- cbind(c(-26.5, -26.5, 10.5, 10.5, -26.5), c(-18.5, 18.5, 18.5, -18.5, -18.5))
  frame <- sf::st_sfc(sf::st_polygon(list(outer, inner)), crs = 4326)
  entry <- st$primary$catalog[st$primary$catalog$dataset == "shapes/polygons", ]
  covering <- geo_covering(frame, entry$h3_res, entry$crs)
  expect_gt(length(covering$cells), 10000)
  expect_true(spatial_use_cells(covering))
  q <- store_intersects(store_open(st, "polygons", engine = "duckdb"), frame)
  sql <- dbplyr::sql_render(q)
  expect_match(sql, "rcs_cells_", fixed = TRUE)
  expect_false(grepl(as.character(covering$cells[[5000]]), sql, fixed = TRUE))
  got <- dplyr::collect(q)
  want <- arrow_rows(st, "polygons", frame)
  expect_gt(nrow(want), 0)
  expect_identical(got$id[order(got$id)], want$id)
})

test_that("several calls combine", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  queries <- duckdb_queries()
  want <- store_open(st, "polygons") |>
    store_intersects(queries$hole) |>
    store_intersects(queries$strip) |>
    dplyr::collect()
  q <- store_open(st, "polygons", engine = "duckdb") |>
    store_intersects(queries$hole) |>
    store_intersects(queries$strip)
  expect_length(.subset2(q, "rcs")$tests, 2)
  got <- dplyr::collect(q)
  expect_gt(nrow(want), 0)
  expect_setequal(got$id, want$id)
  expect_lt(nrow(got), nrow(arrow_rows(st, "polygons", queries$hole)))
})

test_that("round trip: a dataset written from sf reads back as the Arrow read", {
  skip_below_level("default")
  st <- duckdb_spatial_store()
  withr::local_options(rcs.quiet = TRUE)
  cells <- duckdb_queries()$cells
  want <- store_read(st, "polygons", intersects = cells)
  got <- store_open(st, "polygons", engine = "duckdb") |>
    store_intersects(cells) |>
    dplyr::collect()
  expect_s3_class(got, "sf")
  want <- want[order(want$id), ]
  got <- got[order(got$id), ]
  rownames(want) <- NULL
  rownames(got) <- NULL
  expect_equal(got, want)
})

test_that("exact_engine NULL follows the dataset, and an explicit engine overrides it", {
  st <- duckdb_small_store()
  q <- duckdb_queries()$bbox
  x <- store_intersects(store_open(st, "polygons", engine = "duckdb"), q)
  expect_identical(.subset2(x, "rcs")$tests[[1]]$exact_engine, "auto")
  y <- store_intersects(store_open(st, "polygons", engine = "duckdb"), q, exact_engine = "planar")
  expect_identical(.subset2(y, "rcs")$tests[[1]]$exact_engine, "planar")
  expect_identical(
    sort(dplyr::collect(y)$id),
    sort(dplyr::collect(store_intersects(store_open(st, "polygons"), q, exact_engine = "planar"))$id)
  )
})

test_that("a table without bbox, a table that is not geospatial and a bad exact abort", {
  st <- duckdb_small_store()
  q <- duckdb_queries()$bbox
  x <- store_open(st, "polygons", engine = "duckdb")
  expect_snapshot(
    store_intersects(dplyr::select(x, -bbox), q),
    error = TRUE
  )
  expect_error(store_intersects(dplyr::select(x, -bbox), q), class = "rcs_error_argument")
  # cells needed: a strip uses them
  strip <- duckdb_queries()$strip
  expect_snapshot(
    store_intersects(dplyr::select(x, -h3), strip),
    error = TRUE
  )
  expect_no_error(store_intersects(dplyr::select(x, -h3, -.rcs_id), q))
  expect_snapshot(
    store_intersects(store_open(st, "daily", engine = "duckdb"), q),
    error = TRUE
  )
  expect_snapshot(store_intersects(x, q, exact = "sphere"), error = TRUE)
  expect_error(store_intersects(x, q, exact = NA), class = "rcs_error_argument")
  expect_error(store_intersects(x, q, exact_engine = "auto"), class = "rcs_error_argument")
})

test_that("an aggregate after a pending exact test informs about the candidate set", {
  st <- duckdb_small_store()
  q <- duckdb_queries()$bbox
  x <- store_open(st, "polygons", engine = "duckdb") |>
    store_intersects(q)
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(n <- dplyr::collect(dplyr::count(x)))
  candidates <- dplyr::collect(store_intersects(store_open(st, "polygons"), q, exact = FALSE))
  withr::local_options(rcs.quiet = TRUE)
  expect_equal(as.numeric(n$n), nrow(candidates))
})
