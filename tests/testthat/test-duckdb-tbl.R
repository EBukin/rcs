# store_open(engine = "duckdb"): a dataset as a dbplyr table on a DuckDB
# view, and its collect() method (plan 0002, D3, D18, D20; facts 2, 3, 7).

# A local store with a key table and a geospatial dataset (with an empty
# geometry), quiet for the calling frame; the package-level DuckDB
# connection of the store is closed when the frame ends.
duckdb_tbl_store <- function(frame = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
  withr::local_options(rcs.quiet = TRUE, .local_envir = frame)
  root <- withr::local_tempdir(.local_envir = frame)
  st <- store_connect(root, create = TRUE)
  store_write(st, rcs_sim_table(150, seed = 1), "sales/daily",
    title = "Daily", description = "Simulated daily table.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  p <- rcs_sim_polygons(40, seed = 1)
  p$geometry[40] <- sf::st_polygon()
  store_write(st, p, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.",
    key = "id"
  )
  withr::defer(store_duckdb_close(st), envir = frame)
  st
}

sales_key <- c("shop_id", "date", "product")

arrange_by <- function(x, key) {
  out <- x[do.call(order, unname(as.list(sf::st_drop_geometry(x)[key]))), ]
  rownames(out) <- NULL
  out
}

test_that("store_open(engine = 'duckdb') returns a lazy dbplyr table with the rcs field", {
  st <- duckdb_tbl_store()
  x <- store_open(st, "daily", engine = "duckdb")
  expect_s3_class(x, c("rcs_duckdb_tbl", "tbl_duckdb_connection", "tbl_sql", "tbl_lazy"))
  expect_identical(class(x)[[1]], "rcs_duckdb_tbl")
  rcs <- .subset2(x, "rcs")
  expect_identical(names(rcs), c("store", "dataset", "mode", "tests"))
  expect_identical(rcs$store, st)
  expect_identical(rcs$dataset, "sales/daily")
  expect_identical(rcs$mode, "native")
  expect_identical(rcs$tests, list())
  # the view of D12 (fact 2: DBI::Id)
  expect_match(dbplyr::sql_render(x), "FROM sales.daily", fixed = TRUE)
  # D3: dbplyr's own print, not the header of the Arrow engine's queries
  out <- utils::capture.output(print(x))
  expect_true(any(grepl("^# Database: DuckDB", out)))
  expect_false(any(grepl("Dataset:", out, fixed = TRUE)))
})

test_that("store_open(engine = 'duckdb') is quiet and the Arrow engine is unchanged", {
  st <- duckdb_tbl_store()
  withr::local_options(rcs.quiet = FALSE)
  expect_no_message(store_open(st, "daily", engine = "duckdb"))
  expect_s3_class(store_open(st, "daily"), "rcs_query")
  expect_s3_class(store_open(st, "daily", engine = "arrow"), "rcs_query")
  expect_error(store_open(st, "daily", engine = "spark"), class = "rlang_error")
})

test_that("dbplyr verbs keep the rcs field and the class", {
  st <- duckdb_tbl_store()
  x <- store_open(st, "sales/daily", engine = "duckdb")
  y <- x |>
    dplyr::filter(qty > 10) |>
    dplyr::select(shop_id, date, product, qty, wait) |>
    dplyr::mutate(qty2 = qty * 2L) |>
    dplyr::arrange(shop_id)
  expect_identical(class(y)[[1]], "rcs_duckdb_tbl")
  expect_identical(.subset2(y, "rcs"), .subset2(x, "rcs"))
  out <- dplyr::collect(y)
  expect_s3_class(out, "tbl_df")
  expect_s3_class(out$product, "factor")
  expect_s3_class(out$wait, "difftime")
  expect_true(all(out$qty > 10, na.rm = TRUE))
})

test_that("collect() restores the R types and equals the Arrow engine", {
  st <- duckdb_tbl_store()
  arrow_rows <- arrange_by(dplyr::collect(store_open(st, "sales/daily")), sales_key)
  for (mode in c("native", "arrow")) {
    out <- dplyr::collect(store_open(st, "sales/daily", engine = "duckdb", mode = mode))
    expect_identical(.subset2(store_open(st, "sales/daily", engine = "duckdb", mode = mode), "rcs")$mode, mode)
    out <- arrange_by(out, sales_key)
    expect_s3_class(out, "tbl_df")
    expect_identical(names(out), names(arrow_rows))
    expect_identical(levels(out$product), levels(arrow_rows$product))
    expect_true(is.ordered(out$grade))
    expect_identical(units(out$wait), "hours")
    expect_s3_class(out$big, "integer64")
    expect_equal(out, arrow_rows, ignore_attr = c("tzone", "row.names"))
  }
})

test_that("collect() gives sf with the catalog CRS from GEOMETRY and BLOB columns", {
  st <- duckdb_tbl_store()
  arrow_rows <- arrange_by(dplyr::collect(store_open(st, "shapes/polygons")), "id")
  crs <- sf::st_crs(arrow_rows)
  for (mode in c("native", "arrow")) {
    x <- store_open(st, "shapes/polygons", engine = "duckdb", mode = mode)
    # native views hold GEOMETRY (fact 7), arrow views BLOB
    type <- DBI::dbGetQuery(
      dbplyr::remote_con(x),
      paste0("SELECT typeof(geometry) AS t FROM (", dbplyr::sql_render(x), ") LIMIT 1")
    )$t
    expect_identical(startsWith(type, "GEOMETRY"), mode == "native")
    expect_true(".rcs_id" %in% colnames(x))
    out <- arrange_by(dplyr::collect(x), "id")
    expect_s3_class(out, "sf")
    expect_identical(attr(out, "sf_column"), "geometry")
    expect_identical(sf::st_crs(out), crs)
    expect_false(".rcs_id" %in% names(out))
    expect_s3_class(out$h3, "rcs_h3")
    expect_true(sf::st_is_empty(out$geometry[out$id == 40L]))
    expect_equal(out, arrow_rows, ignore_attr = "row.names")
  }
  # without the geometry: a tibble
  plain <- store_open(st, "shapes/polygons", engine = "duckdb") |>
    dplyr::select(id, h3) |>
    dplyr::collect()
  expect_false(inherits(plain, "sf"))
  expect_s3_class(plain$h3, "rcs_h3")
})

test_that("collect() drops the geom column of arrow-mode spatial views", {
  st <- duckdb_tbl_store()
  con <- local_duckdb_spatial()
  x <- store_open(st, "polygons", engine = "duckdb", con = con, mode = "arrow", spatial = TRUE)
  expect_identical(dbplyr::remote_con(x), con)
  expect_true("geom" %in% colnames(x))
  out <- dplyr::collect(x)
  expect_false(any(c("geom", ".rcs_id") %in% names(out)))
  expect_s3_class(out, "sf")
})

test_that("collect() honours pending exact tests of the rcs field", {
  st <- duckdb_tbl_store()
  x <- store_open(st, "shapes/polygons", engine = "duckdb")
  all_rows <- dplyr::collect(x)
  shape <- sf::st_buffer(sf::st_centroid(sf::st_geometry(all_rows)[1]), 0.5)
  set_tests <- function(x, tests) {
    cls <- class(x)
    x <- unclass(x)
    x$rcs$tests <- tests
    class(x) <- cls
    x
  }
  test <- list(exact = TRUE, shape = shape, exact_engine = "planar", geographic = TRUE)
  out <- dplyr::collect(set_tests(x, list(test)))
  keep <- exact_keep(sf::st_geometry(all_rows), shape, "planar", TRUE)
  expect_identical(sort(out$id), sort(all_rows$id[keep]))
  expect_lt(nrow(out), nrow(all_rows))

  candidates <- set_tests(x, list(utils::modifyList(test, list(exact = FALSE))))
  withr::local_options(rcs.quiet = FALSE)
  expect_message(out <- dplyr::collect(candidates), "candidate set")
  expect_identical(nrow(out), nrow(all_rows))
})

test_that("version = aborts with the DuckDB engine", {
  st <- duckdb_tbl_store()
  version <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  expect_snapshot(
    store_open(st, "daily", version = "0123456789abcdef", engine = "duckdb"),
    error = TRUE
  )
  expect_error(store_open(st, "daily", version = version, engine = "duckdb"), class = "rcs_error_argument")
})

test_that("the package-level connection is reused per store and closed by store_duckdb_close()", {
  st <- duckdb_tbl_store()
  a <- store_open(st, "daily", engine = "duckdb")
  b <- store_open(st, "polygons", engine = "duckdb")
  con <- dbplyr::remote_con(a)
  expect_identical(dbplyr::remote_con(b), con)
  expect_true(DBI::dbIsValid(con))
  # both views live on the one connection
  expect_true(all(c("sales.daily", "shapes.polygons") %in% DBI::dbGetQuery(con, "SELECT view FROM rcs.views")$view))

  other <- duckdb_tbl_store()
  expect_false(identical(dbplyr::remote_con(store_open(other, "daily", engine = "duckdb")), con))

  store_duckdb_close(st)
  expect_false(DBI::dbIsValid(con))
  expect_no_error(store_duckdb_close(st))
  fresh <- dbplyr::remote_con(store_open(st, "daily", engine = "duckdb"))
  expect_true(DBI::dbIsValid(fresh))
  expect_false(identical(fresh, con))
})

test_that("a user connection is used, and one without bigint = 'integer64' aborts", {
  st <- duckdb_tbl_store()
  con <- local_duckdb()
  x <- store_open(st, "daily", engine = "duckdb", con = con)
  expect_identical(dbplyr::remote_con(x), con)
  expect_identical(nrow(dplyr::collect(x)), 150L)

  plain <- local_duckdb(bigint = "numeric")
  expect_snapshot(store_open(st, "daily", engine = "duckdb", con = plain), error = TRUE)
  expect_error(store_open(st, "daily", engine = "duckdb", con = plain), class = "rcs_error_duckdb")
})
