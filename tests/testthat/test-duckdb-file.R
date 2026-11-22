# store_duckdb() with a DuckDB database file: views that persist, reopening
# and refreshing (plan 0002, D16, D17; facts 5, 6).

# A local store: a table partitioned by year (`sales/daily`), a one-file
# table (`summary`) and a geospatial dataset with its index table.
file_test_store <- function(frame = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  withr::local_options(rcs.quiet = TRUE, .local_envir = frame)
  root <- withr::local_tempdir(.local_envir = frame)
  st <- store_connect(file.path(root, "primary"), create = TRUE)
  store_write(st, rcs_sim_table(200, seed = 1), "sales/daily",
    title = "Daily", description = "Simulated daily table.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  store_write(st, rcs_sim_table(50, seed = 2), "summary",
    title = "Summary", description = "Simulated table."
  )
  store_write(st, rcs_sim_polygons(30, seed = 1), "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.",
    partition = "h3", max_files = 5
  )
  st
}

file_test_views <- c("main.summary", "sales.daily", "shapes.polygons", "shapes.polygons__h3")

# A database path outside the store, in its own temporary folder.
file_test_path <- function(name = "work.duckdb", frame = parent.frame()) {
  file.path(withr::local_tempdir(.local_envir = frame), name)
}

# A file database opened with plain DBI, closed when `frame` ends.
file_connect <- function(path, frame = parent.frame()) {
  con <- suppressMessages(DBI::dbConnect(duckdb::duckdb(dbdir = path), bigint = "integer64"))
  withr::defer(if (DBI::dbIsValid(con)) DBI::dbDisconnect(con, shutdown = TRUE), envir = frame)
  con
}

file_close <- function(con) {
  DBI::dbDisconnect(con, shutdown = TRUE)
}

file_views <- function(con) {
  sql <- paste(
    "SELECT schema_name || '.' || view_name AS x FROM duckdb_views()",
    "WHERE NOT internal AND schema_name NOT IN ('information_schema', 'pg_catalog')"
  )
  sort(DBI::dbGetQuery(con, sql)$x, method = "radix")
}

file_count <- function(con, view) {
  parts <- strsplit(view, ".", fixed = TRUE)[[1]]
  sql <- paste0('SELECT count(*) AS n FROM "', parts[[1]], '"."', parts[[2]], '"')
  as.numeric(DBI::dbGetQuery(con, sql)$n)
}

# (a) ----------------------------------------------------------------------------

test_that("views and a user table in a file survive closing and reopening with DBI", {
  st <- file_test_store()
  path <- file_test_path()
  expect_false(file.exists(path))
  con <- store_duckdb(st, path = path)
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))
  expect_true(file.exists(path))
  expect_identical(file_views(con), file_test_views)
  DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
  file_close(con)

  con <- file_connect(path)
  expect_identical(file_views(con), file_test_views)
  expect_identical(DBI::dbReadTable(con, "mine")$a, 1:3)
  expect_identical(file_count(con, "sales.daily"), 200)
  expect_identical(file_count(con, "main.summary"), 50)
  views <- DBI::dbGetQuery(con, "SELECT view, dataset, mode FROM rcs.views ORDER BY view")
  expect_identical(views$view, file_test_views)
  expect_identical(unique(views$mode), "native")
  stored <- DBI::dbGetQuery(con, "SELECT role, uri FROM rcs.store")
  expect_identical(stored$role, "primary")
  expect_identical(stored$uri, st$primary$uri)
  # The macro persists too.
  expect_identical(DBI::dbGetQuery(con, "SELECT rcs_h3_hex(255::BIGINT) AS x")$x, "ff")
})

# (b) ----------------------------------------------------------------------------

test_that("store_duckdb(st, path) on an existing file adds and drops views and keeps user tables", {
  st <- file_test_store()
  path <- file_test_path()
  con <- store_duckdb(st, path = path)
  DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
  DBI::dbExecute(con, "CREATE VIEW main.my_view AS SELECT * FROM mine")
  file_close(con)
  old <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]

  store_write(st, rcs_sim_table(10, seed = 3), "extra",
    title = "Extra", description = "Simulated table."
  )
  store_write(st, rcs_sim_table(120, seed = 4), "sales/daily",
    title = "Daily", description = "Simulated daily table.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  store_delete(st, "summary", confirm = "summary")
  new <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  expect_false(identical(old, new))

  con <- store_duckdb(st, path = path)
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))
  expected <- sort(c("main.extra", "sales.daily", "shapes.polygons", "shapes.polygons__h3"), method = "radix")
  expect_identical(setdiff(file_views(con), "main.my_view"), expected)
  expect_true("main.my_view" %in% file_views(con))
  expect_identical(DBI::dbReadTable(con, "mine")$a, 1:3)
  expect_identical(file_count(con, "sales.daily"), 120)
  views <- DBI::dbGetQuery(con, "SELECT view, version FROM rcs.views ORDER BY view")
  expect_identical(views$view, expected)
  expect_identical(views$version[views$view == "sales.daily"], new)
  tables <- store_tables(con, st)
  expect_true(all(tables$current[tables$type == "view" & !is.na(tables$dataset)]))
})

# (c) ----------------------------------------------------------------------------

test_that("store_duckdb(path = ) without st reconnects through rcs.store", {
  st <- file_test_store()
  path <- file_test_path()
  con <- store_duckdb(st, path = path)
  file_close(con)
  store_write(st, rcs_sim_table(10, seed = 3), "extra",
    title = "Extra", description = "Simulated table."
  )

  con <- store_duckdb(path = path)
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))
  expect_identical(file_views(con), sort(c(file_test_views, "main.extra"), method = "radix"))
  expect_identical(file_count(con, "main.extra"), 10)
  expect_identical(DBI::dbGetQuery(con, "SELECT uri FROM rcs.store")$uri, st$primary$uri)
})

test_that("store_duckdb(path = ) without st aborts for a file without rcs.store, or no file", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  path <- file_test_path("plain.duckdb")
  con <- file_connect(path)
  DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
  file_close(con)
  expect_snapshot(store_duckdb(path = path), error = TRUE, transform = function(x) gsub("'[^']*plain.duckdb'|<[^>]*plain.duckdb>", "<path>", x))
  expect_error(store_duckdb(path = path), class = "rcs_error_duckdb")
  # The file is left as it was.
  con <- file_connect(path)
  expect_identical(DBI::dbReadTable(con, "mine")$a, 1:3)
  file_close(con)

  missing_path <- file_test_path("none.duckdb")
  expect_error(store_duckdb(path = missing_path), class = "rcs_error_argument")
  expect_false(file.exists(missing_path))
  expect_error(store_duckdb(), class = "rcs_error_argument")
})

# (d) ----------------------------------------------------------------------------

test_that("a path inside a local location aborts", {
  st <- file_test_store()
  inside <- file.path(st$primary$backend$root, "work.duckdb")
  expect_error(store_duckdb(st, path = inside), class = "rcs_error_argument")
  expect_false(file.exists(inside))
  deeper <- file.path(st$primary$backend$root, "sub", "work.duckdb")
  expect_error(store_duckdb(st, path = deeper), class = "rcs_error_argument")
  expect_snapshot(store_duckdb(st, path = inside), error = TRUE, transform = function(x) gsub("<[^>]*>", "<path>", x))
})

test_that("a file stem equal to a used schema aborts and leaves no file", {
  st <- file_test_store()
  path <- file_test_path("sales.duckdb")
  expect_error(store_duckdb(st, path = path), class = "rcs_error_duckdb")
  expect_false(file.exists(path))
  expect_snapshot(store_duckdb(st, path = path), error = TRUE)
})

test_that("a table or an unlisted view with a view's name aborts, naming it", {
  st <- file_test_store()
  path <- file_test_path()
  con <- file_connect(path)
  DBI::dbExecute(con, "CREATE SCHEMA sales")
  DBI::dbExecute(con, "CREATE TABLE sales.daily (a INTEGER)")
  file_close(con)
  expect_snapshot(store_duckdb(st, path = path), error = TRUE)
  expect_error(store_duckdb(st, path = path), class = "rcs_error_duckdb")

  path <- file_test_path()
  con <- file_connect(path)
  DBI::dbExecute(con, "CREATE VIEW main.summary AS SELECT 1 AS a")
  file_close(con)
  expect_error(store_duckdb(st, path = path), "main.summary", class = "rcs_error_duckdb")
  # Nothing was replaced.
  con <- file_connect(path)
  expect_identical(DBI::dbGetQuery(con, "SELECT * FROM main.summary")$a, 1L)
  file_close(con)
})

test_that("path and con together abort", {
  st <- file_test_store()
  con <- local_duckdb()
  expect_error(store_duckdb(st, path = file_test_path(), con = con), class = "rcs_error_argument")
})

# (e) ----------------------------------------------------------------------------

test_that("arrow mode with a path informs that views must be refreshed after reopening", {
  st <- file_test_store()
  path <- file_test_path()
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot({
    con <- store_duckdb(st, path = path, datasets = "summary", mode = "arrow")
  })
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))
  expect_identical(file_count(con, "main.summary"), 50)
  file_close(con)

  # Reopened, the arrow views are refreshed by store_duckdb().
  withr::local_options(rcs.quiet = TRUE)
  con <- store_duckdb(st, path = path, datasets = "summary", mode = "arrow")
  expect_identical(file_count(con, "main.summary"), 50)
  file_close(con)
})

test_that("native mode with a path does not inform about refreshing", {
  st <- file_test_store()
  withr::local_options(rcs.quiet = FALSE)
  msgs <- testthat::capture_messages(con <- store_duckdb(st, path = file_test_path(), datasets = "summary"))
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))
  expect_length(msgs, 1)
  expect_false(any(grepl("refresh", msgs)))
})

# (f) ----------------------------------------------------------------------------

test_that("the local-first workflow never asks for cloud credentials", {
  st <- file_test_store()
  calls <- 0L
  local_mocked_bindings(
    auth_token = function(...) {
      calls <<- calls + 1L
      cli::cli_abort("no credentials in this test")
    },
    auth_arrow_fs = function(...) {
      calls <<- calls + 1L
      cli::cli_abort("no credentials in this test")
    }
  )
  path <- file_test_path()
  con <- store_duckdb(st, path = path)
  withr::defer(if (DBI::dbIsValid(con)) file_close(con))

  DBI::dbExecute(con, paste(
    "CREATE TABLE year_qty AS SELECT year, sum(qty) AS qty, count(*) AS n",
    "FROM sales.daily GROUP BY year ORDER BY year"
  ))
  DBI::dbExecute(con, paste(
    "CREATE TABLE cell_area AS SELECT i.h3, count(*) AS n",
    "FROM shapes.polygons p JOIN shapes.polygons__h3 i ON p.\".rcs_id\" = i.\".rcs_id\"",
    "GROUP BY i.h3"
  ))
  year_qty <- tibble::as_tibble(DBI::dbReadTable(con, "year_qty"))
  expect_identical(sum(as.numeric(year_qty$n)), 200)
  cells <- DBI::dbReadTable(con, "cell_area")
  expect_true(inherits(cells$h3, "integer64"))
  expect_gt(nrow(cells), 0)

  year_qty$year <- as.integer(year_qty$year)
  year_qty$qty <- as.numeric(year_qty$qty)
  year_qty$n <- as.numeric(year_qty$n)
  store_write(st, year_qty, "results/year_qty",
    title = "Quantity by year", description = "Aggregated in DuckDB.", key = "year"
  )
  file_close(con)

  con <- store_duckdb(st, path = path)
  expect_true("results.year_qty" %in% file_views(con))
  expect_identical(file_count(con, "results.year_qty"), as.numeric(nrow(year_qty)))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM cell_area")$n > 0, TRUE)
  file_close(con)
  expect_identical(calls, 0L)
})

# (g) ----------------------------------------------------------------------------

test_that("the database file stays small: views store query text only", {
  skip_below_level("default")
  st <- file_test_store()
  store_write(st, rcs_sim_table(1e5, seed = 5), "big/table",
    title = "Big", description = "Simulated large table.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  path <- file_test_path()
  con <- store_duckdb(st, path = path)
  file_close(con)
  expect_lt(file.size(path), 1024^2)
})
