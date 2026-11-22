# store_write() of a lazy table on a DuckDB connection (plan 0002, D36-D38,
# D40): tests b, c and g of "Tests of V1 and V2".

# Helpers -----------------------------------------------------------------------

skip_if_no_duckdb_write <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
}

duck_key <- c("shop_id", "date", "product")

# Simulated sales with the column types of test c: integer, double, varchar,
# date and boolean.
duck_sales_data <- function(n = 300, seed = 1) {
  x <- rcs_sim_table(n, seed = seed)
  x$product <- as.character(x$product)
  x[c("shop_id", "date", "year", "product", "qty", "price", "promo", "delivered", "note")]
}

# The data as a DuckDB table `name`, and a lazy table on it.
duck_table <- function(con, x, name = "sales") {
  DBI::dbWriteTable(con, name, as.data.frame(x), overwrite = TRUE)
  dplyr::tbl(con, name)
}

duck_store <- function(secondaries = 0L, frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  paths <- file.path(root, c("primary", sprintf("secondary%d", seq_len(secondaries))))
  for (p in paths) suppressMessages(store_create(p, history = FALSE))
  st <- store_connect(paths[[1]], secondary = paths[-1])
  list(st = st, root = normalizePath(root, winslash = "/"), paths = normalizePath(paths, winslash = "/"))
}

duck_write <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.",
    mode = mode, ...
  ))
}

# Every stored row of the dataset in a location, R types restored.
duck_stored_rows <- function(location, dataset = "sales/daily") {
  withr::local_options(arrow.int64_downcast = FALSE)
  entry <- location$catalog[location$catalog$dataset == dataset, ]
  paths <- location$files$path[location$files$dataset == dataset]
  rows <- lapply(paths, function(p) read_stored(location$backend, p))
  restore_types(vctrs::vec_rbind(!!!rows), columns_from_json(entry$columns))
}

duck_sorted <- function(x, key = duck_key) {
  x <- tibble::as_tibble(as.data.frame(x))
  x[vctrs::vec_order(key_frame(x, key)), ]
}

# The names of the temporary tables of writes left on the connection.
duck_write_tables <- function(con) {
  DBI::dbGetQuery(con, "SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'rcs_write_%'")$table_name
}

# The stored facts of a dataset in the primary that must not depend on how
# it was written: the catalog entry without its times, the file rows
# without `created`, the MD5 of every file on disk, and the manifest
# without its times.
duck_facts <- function(s, dataset = "sales/daily") {
  st <- s$st
  entry <- st$primary$catalog[st$primary$catalog$dataset == dataset, ]
  files <- st$primary$files[st$primary$files$dataset == dataset, ]
  manifest <- readLines(file.path(s$paths[[1]], manifest_path(dataset, entry$version)), warn = FALSE)
  list(
    entry = as.list(entry[setdiff(names(entry), c("created", "updated"))]),
    files = tibble::as_tibble(files[setdiff(names(files), "created")]),
    md5_on_disk = unname(tools::md5sum(file.path(s$paths[[1]], files$path))),
    manifest = gsub("\"(created|updated|written)\": *\"[^\"]*\"", "\"<time>\"", paste(manifest, collapse = "\n"))
  )
}

local_snapshot_width <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
}

# b. One file and partitions, key, limits ----------------------------------------

test_that("a DuckDB table is written as one file and by partitions, with its key", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(300)
  tbl <- duck_table(con, x)

  s <- duck_store()
  out <- duck_write(s$st, tbl, key = duck_key)
  entry <- s$st$primary$catalog
  expect_identical(entry$kind, "table")
  expect_identical(entry$key[[1]], duck_key)
  expect_identical(as.numeric(entry$n_files), 1)
  expect_identical(as.numeric(entry$rows), 300)
  expect_identical(attr(out, "version"), entry$version)
  expect_equal(duck_sorted(duck_stored_rows(s$st$primary)), duck_sorted(x))
  expect_store_valid(s$st)

  s2 <- duck_store()
  duck_write(s2$st, tbl, key = duck_key, partition = "year")
  entry <- s2$st$primary$catalog
  expect_identical(entry$partition[[1]], "year")
  expect_identical(as.numeric(entry$n_files), as.numeric(length(unique(x$year))))
  files <- s2$st$primary$files
  expect_setequal(files$partition_values, vapply(sort(unique(x$year)), function(y) {
    partition_values_json(list(year = y))
  }, character(1)))
  expect_equal(duck_sorted(duck_stored_rows(s2$st$primary)), duck_sorted(x))
  # rows of each file sorted by the key
  withr::local_options(arrow.int64_downcast = FALSE)
  for (p in files$path) {
    rows <- read_stored(s2$st$primary$backend, p)
    expect_identical(vctrs::vec_order(key_frame(rows, duck_key)), seq_len(nrow(rows)))
  }
  expect_store_valid(s2$st)
})

test_that("more partitions than max_files abort before anything is staged", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(100))
  s <- duck_store()
  written <- 0L
  real <- duckdb_write_files
  local_mocked_bindings(duckdb_write_files = function(...) {
    written <<- written + 1L
    real(...)
  })
  local_snapshot_width()
  expect_snapshot(
    duck_write(s$st, tbl, key = duck_key, partition = "date", max_files = 3),
    error = TRUE
  )
  expect_error(
    duck_write(s$st, tbl, key = duck_key, partition = "date", max_files = 3),
    class = "rcs_error_argument"
  )
  expect_identical(written, 0L)
  expect_identical(nrow(s$st$primary$catalog), 0L)
})

test_that("duplicate keys abort naming the first duplicates, nothing staged", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(100)
  # seven key values repeat; the first repeated rows are 3, 5, 10, 20, 30, 40, 50
  dup <- x[c(3, 5, 10, 20, 30, 40, 50, 3), ]
  dup$qty <- dup$qty + 1L
  tbl <- duck_table(con, vctrs::vec_rbind(x, dup))
  s <- duck_store()
  written <- 0L
  real <- duckdb_write_files
  local_mocked_bindings(duckdb_write_files = function(...) {
    written <<- written + 1L
    real(...)
  })
  staging <- withr::local_tempdir()
  withr::local_options(rcs.staging_dir = staging)
  local_snapshot_width()
  expect_snapshot(duck_write(s$st, tbl, key = duck_key), error = TRUE)
  err <- expect_error(duck_write(s$st, tbl, key = duck_key), class = "rcs_error_key")
  # the first five, in the order of their first rows
  msg <- cli::ansi_strip(conditionMessage(err))
  first <- format_key_values(x[c(3, 5, 10, 20, 30), duck_key])
  positions <- vapply(first, function(f) regexpr(f, msg, fixed = TRUE), integer(1))
  expect_true(all(positions > 0))
  expect_identical(order(positions), 1:5)
  expect_match(msg, "7 key values repeat")
  expect_match(msg, "And 2 more")
  expect_identical(written, 0L)
  expect_identical(nrow(s$st$primary$catalog), 0L)
  expect_identical(list.files(staging, pattern = "parquet$", recursive = TRUE), character())
})

test_that("a keyless DuckDB table written twice gives the same version", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(200))
  s <- duck_store()
  first <- duck_write(s$st, tbl)
  second <- duck_write(s$st, tbl, mode = "replace")
  expect_identical(attr(second, "version"), attr(first, "version"))
  expect_identical(second$status[[1]], "unchanged")

  s2 <- duck_store()
  first <- duck_write(s2$st, tbl, partition = "year")
  second <- duck_write(s2$st, tbl, partition = "year", mode = "replace")
  expect_identical(attr(second, "version"), attr(first, "version"))
  expect_identical(second$status[[1]], "unchanged")
})

# c. Byte identity with store_write() of the collected data -----------------------

test_that("files, catalog rows, manifest and version equal those of the collected data", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(1200, seed = 3)
  tbl <- duck_table(con, x)
  collected <- tibble::as_tibble(dplyr::collect(tbl))
  # batches that cut row groups and partitions anywhere
  withr::local_options(rcs.duckdb_batch_rows = 170)

  cases <- list(
    one_file = list(key = duck_key, partition = NULL),
    partitioned = list(key = duck_key, partition = "year"),
    two_columns = list(key = duck_key, partition = c("year", "shop_id")),
    keyless = list(key = NULL, partition = NULL),
    keyless_partitioned = list(key = NULL, partition = "year")
  )
  for (name in names(cases)) {
    args <- cases[[name]]
    a <- duck_store()
    b <- duck_store()
    out_a <- duck_write(a$st, tbl, key = args$key, partition = args$partition, rows_per_group = 250L)
    out_b <- duck_write(b$st, collected, key = args$key, partition = args$partition, rows_per_group = 250L)
    expect_identical(attr(out_a, "version"), attr(out_b, "version"), label = name)
    expect_identical(duck_facts(a), duck_facts(b), label = name)
  }
})

# g. Landing, and the temporary table -----------------------------------------------

test_that("a DuckDB write lands in a local primary and secondary with MD5 verification", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(200)
  tbl <- duck_table(con, x)
  s <- duck_store(secondaries = 1L)
  verified <- character()
  during <- NULL
  real_verify <- verify_md5
  real_land <- land_primary
  local_mocked_bindings(
    verify_md5 = function(be, paths, md5) {
      verified <<- c(verified, be$uri)
      real_verify(be, paths, md5)
    },
    land_primary = function(...) {
      during <<- duck_write_tables(con)
      real_land(...)
    }
  )
  out <- duck_write(s$st, tbl, key = duck_key, partition = "year")
  expect_identical(out$status, c("written", "written"))
  expect_true(all(c(s$st$primary$uri, s$st$secondary[[1]]$uri) %in% verified))
  expect_identical(s$st$secondary[[1]]$catalog$version, s$st$primary$catalog$version)
  expect_equal(duck_sorted(duck_stored_rows(s$st$secondary[[1]])), duck_sorted(x))
  expect_store_valid(s$st)
  # the temporary table existed while landing, and is gone afterwards
  expect_length(during, 1L)
  expect_identical(duck_write_tables(con), character())
  # the user's table is untouched
  expect_identical(as.numeric(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM sales")$n), 200)
})

test_that("the temporary DuckDB table is dropped after an error", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(100)
  tbl <- duck_table(con, x)
  s <- duck_store()

  # an error while landing
  local_mocked_bindings(land_primary = function(...) {
    cli::cli_abort("Landing failed.", class = "rcs_error_backend")
  })
  expect_error(duck_write(s$st, tbl, key = duck_key), class = "rcs_error_backend")
  expect_identical(duck_write_tables(con), character())

  # an error of the key check
  dup <- duck_table(con, vctrs::vec_rbind(x, x[1, ]), name = "sales_dup")
  expect_error(duck_write(s$st, dup, key = duck_key), class = "rcs_error_key")
  expect_identical(duck_write_tables(con), character())

  # an error while streaming the files
  local_mocked_bindings(duckdb_write_files = function(...) cli::cli_abort("Streaming failed."))
  expect_error(duck_write(s$st, tbl, key = duck_key), "Streaming failed")
  expect_identical(duck_write_tables(con), character())
  expect_identical(nrow(s$st$primary$catalog), 0L)
})
