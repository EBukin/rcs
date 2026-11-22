# store_write() of a lazy table on a DuckDB connection (plan 0002, D36-D38,
# D40): tests a to g of "Tests of V1 and V2".

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

test_that("keys mixing case and NULL give the files of the collected data, in byte order, whatever the locale", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- tibble::tibble(
    code = c("b", "B", "a", "A", NA, "c"),
    grp = c("x", "Y", "z", "x", "Y", "z"), # distinct on case-insensitive file systems
    flag = c(TRUE, NA, FALSE, TRUE, FALSE, NA),
    day = as.Date(c("2024-01-02", NA, "2024-01-01", "2024-01-02", "2023-12-31", NA)),
    qty = 1:6
  )
  tbl <- duck_table(con, x, "mixed")
  cases <- list(
    one_file = list(key = "code", partition = NULL, order = c("A", "B", "a", "b", "c", NA)),
    partitioned = list(key = "code", partition = "grp", order = c("B", NA, "A", "b", "a", "c")),
    logical_date_key = list(key = c("flag", "day", "code"), partition = NULL, order = c(NA, "a", "A", "b", "B", "c"))
  )
  # testthat collates in C; a language locale must not change the files
  works <- function(locale) {
    suppressWarnings(withr::with_collate(locale, identical(Sys.getlocale("LC_COLLATE"), locale)))
  }
  locales <- Filter(works, c("en_US.UTF-8", "English_United States.utf8", "C"))
  withr::local_collate(locales[[1]])
  for (name in names(cases)) {
    args <- cases[[name]]
    a <- duck_store()
    b <- duck_store()
    out_a <- duck_write(a$st, tbl, key = args$key, partition = args$partition)
    out_b <- duck_write(b$st, x, key = args$key, partition = args$partition)
    expect_identical(attr(out_a, "version"), attr(out_b, "version"), label = name)
    expect_identical(duck_facts(a), duck_facts(b), label = name)
    files <- a$st$primary$files$path[a$st$primary$files$dataset == "sales/daily"]
    stored <- unlist(lapply(files, function(p) read_stored(a$st$primary$backend, p)$code))
    expect_identical(stored, args$order, label = name)
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

# a. Batches: memory bounded by one batch ------------------------------------------

test_that("a large DuckDB table is streamed in batches of at most rcs.duckdb_batch_rows rows", {
  skip_if_no_duckdb_write()
  skip_below_level("default")
  con <- local_duckdb()
  n <- 1.2e6
  DBI::dbExecute(con, paste(
    "CREATE TABLE big AS SELECT",
    "range::INTEGER AS id,",
    "(range % 997)::DOUBLE / 7 AS value,",
    "'g' || (range % 13)::VARCHAR AS grp,",
    "DATE '2020-01-01' + (range % 1500)::INTEGER AS day,",
    "range % 3 = 0 AS flag,",
    "range::BIGINT * 4294967296 AS big,",
    "TIMESTAMP '2020-01-01 00:00:00' + to_seconds(range) AS ts",
    "FROM range(", format(n, scientific = FALSE), ")"
  ))
  tbl <- dplyr::tbl(con, "big")
  withr::local_options(rcs.duckdb_batch_rows = 2e5)

  # a spy around the real iterator: the rows of every batch, per call
  calls <- list()
  real <- duckdb_batches
  local_mocked_bindings(duckdb_batches = function(con, sql, n) {
    it <- real(con, sql, n)
    k <- length(calls) + 1L
    calls[[k]] <<- numeric()
    next_batch <- it$next_batch
    it$next_batch <- function() {
      batch <- next_batch()
      if (!is.null(batch)) calls[[k]] <<- c(calls[[k]], batch$num_rows)
      batch
    }
    it
  })
  s <- duck_store()
  duck_write(s$st, tbl, key = "id", partition = "grp")

  expect_gte(length(calls), 1L)
  for (rows in calls) {
    expect_true(all(rows <= 2e5))
    expect_lt(max(rows), n)
  }
  # the pass over the rows streams every row, in enough batches
  pass <- calls[vapply(calls, function(r) sum(r) == n, logical(1))]
  expect_length(pass, 1L)
  expect_gte(length(pass[[1]]), ceiling(n / 2e5))

  stored <- duck_stored_rows(s$st$primary)
  expected <- tibble::as_tibble(dplyr::collect(tbl))
  stored <- stored[order(stored$id), names(expected)]
  expected <- expected[order(expected$id), ]
  expect_identical(nrow(stored), as.integer(n))
  for (col in names(expected)) {
    expect_identical(normalise_values(stored[[col]]), normalise_values(expected[[col]]), label = col)
  }
  expect_s3_class(stored$big, "integer64")
})

# d. Types, mode, backend, package columns ------------------------------------------

test_that("DuckDB types map as D38 says: BIGINT as integer64, TIMESTAMP without and TIMESTAMPTZ with UTC", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  DBI::dbExecute(con, paste(
    "CREATE TABLE typed AS SELECT range::INTEGER AS id,",
    "range::BIGINT * 1000000000000 AS big,",
    "TIMESTAMP '2024-01-01 10:00:00' + to_seconds(range) AS ts,",
    "to_timestamp(1704103200 + range) AS tz",
    "FROM range(5)"
  ))
  tbl <- dplyr::tbl(con, "typed")
  s <- duck_store()
  duck_write(s$st, tbl, key = "id")

  entry <- s$st$primary$catalog
  spec <- columns_from_json(entry$columns)
  expect_identical(spec$r_type[[match("big", spec$name)]], list(class = "integer64"))
  path <- file.path(s$paths[[1]], s$st$primary$files$path)
  schema <- arrow::read_parquet(path, as_data_frame = FALSE)$schema
  expect_identical(schema$ts$type$ToString(), "timestamp[us]")
  expect_identical(schema$tz$type$ToString(), "timestamp[us, tz=UTC]")

  rows <- duck_stored_rows(s$st$primary)
  rows <- rows[order(rows$id), ]
  expect_s3_class(rows$big, "integer64")
  expect_identical(as.character(rows$big), as.character(bit64::as.integer64(0:4) * bit64::as.integer64(1e12)))
  # the wall clock of TIMESTAMP, the instant of TIMESTAMPTZ
  wall <- as.numeric(as.POSIXct("2024-01-01 10:00:00", tz = "UTC")) + 0:4
  expect_identical(as.numeric(rows$ts), wall)
  expect_identical(as.numeric(rows$tz), 1704103200 + 0:4)
  expect_identical(attr(rows$tz, "tzone"), "UTC")

  # the files do not depend on the time zone of the R session
  s2 <- duck_store()
  withr::with_timezone("Etc/GMT-9", duck_write(s2$st, tbl, key = "id"))
  expect_identical(s2$st$primary$catalog$version, entry$version)
})

test_that("DuckDB types Arrow cannot write abort naming the columns", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  DBI::dbExecute(con, paste(
    "CREATE TABLE odd AS SELECT range::INTEGER AS id, range::HUGEINT AS huge,",
    "to_seconds(range) AS span FROM range(3)"
  ))
  s <- duck_store()
  local_snapshot_width()
  expect_snapshot(duck_write(s$st, dplyr::tbl(con, "odd"), key = "id"), error = TRUE)
  expect_error(duck_write(s$st, dplyr::tbl(con, "odd"), key = "id"), class = "rcs_error_argument")
  expect_identical(nrow(s$st$primary$catalog), 0L)
})

test_that("unsupported DuckDB types nested in STRUCT, LIST or MAP abort naming the columns", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  DBI::dbExecute(con, paste(
    "CREATE TABLE nested AS SELECT range::INTEGER AS id,",
    "{'a': range::HUGEINT} AS st,",
    "[to_seconds(range)] AS spans,",
    "{'b': [range::UHUGEINT]} AS deep,",
    "{'map': range::INTEGER, 'interval': 1} AS fine,",
    "[{'m': map([range], [range])}] AS maps",
    "FROM range(3)"
  ))
  s <- duck_store()
  local_snapshot_width()
  expect_snapshot(duck_write(s$st, dplyr::tbl(con, "nested"), key = "id"), error = TRUE)
  err <- expect_error(duck_write(s$st, dplyr::tbl(con, "nested"), key = "id"), class = "rcs_error_argument")
  msg <- cli::ansi_strip(conditionMessage(err))
  for (col in c("st", "spans", "deep", "maps")) expect_match(msg, paste0("\\b", col, ": "))
  expect_no_match(msg, "fine")
  expect_identical(nrow(s$st$primary$catalog), 0L)

  # field names that are type names do not abort
  ok <- dplyr::tbl(con, dbplyr::sql("SELECT id, fine FROM nested"))
  expect_no_error(duck_write(s$st, ok, key = "id"))
})

test_that("mode update and lazy tables on other databases abort", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(50))
  s <- duck_store()
  duck_write(s$st, tbl, key = duck_key)
  local_snapshot_width()
  expect_snapshot(duck_write(s$st, tbl, mode = "update", key = duck_key), error = TRUE)
  expect_error(duck_write(s$st, tbl, mode = "update", key = duck_key), class = "rcs_error_argument")

  other <- dbplyr::lazy_frame(a = 1L, b = "x")
  expect_snapshot(duck_write(s$st, other), error = TRUE)
  expect_error(duck_write(s$st, other), class = "rcs_error_argument")
})

test_that("package columns in x are dropped with one message", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  x <- duck_sales_data(40)
  x$h3 <- 1L
  x$.rcs_id <- seq_len(nrow(x))
  tbl <- duck_table(con, x)
  s <- duck_store()
  local_snapshot_width()
  msgs <- character()
  withCallingHandlers(
    store_write(s$st, tbl, "sales/daily", title = "Daily sales", description = "Simulated daily sales.", key = duck_key),
    message = function(m) {
      msgs <<- c(msgs, cli::ansi_strip(conditionMessage(m)))
      invokeRestart("muffleMessage")
    }
  )
  dropped <- grep("package's own", msgs, value = TRUE)
  expect_length(dropped, 1L)
  expect_snapshot(cat(dropped))
  stored <- duck_stored_rows(s$st$primary)
  expect_false(any(c("h3", ".rcs_id") %in% names(stored)))
  expect_equal(duck_sorted(stored), duck_sorted(x[setdiff(names(x), c("h3", ".rcs_id"))]))
})

# e. Progress -------------------------------------------------------------------------

test_that("progress is created once and updated per batch, not under rcs.quiet", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(500))
  withr::local_options(rcs.duckdb_batch_rows = 120)
  log <- list()
  local_mocked_bindings(write_progress = function(bar = NULL, phase = NULL, total = NULL, batches = NULL,
                                                  rows = 0, batch = 0L, done = FALSE, .envir = parent.frame()) {
    event <- if (is.null(bar)) "create" else if (isTRUE(done)) "done" else "update"
    log[[length(log) + 1L]] <<- list(event = event, total = total, batches = batches, rows = rows, batch = batch)
    invisible(list(id = "bar"))
  })
  s <- duck_store()
  duck_write(s$st, tbl, key = duck_key, partition = "year")
  events <- vapply(log, function(e) e$event, character(1))
  expect_identical(events, c("create", rep("update", 5), "done"))
  expect_identical(as.numeric(log[[1]]$total), 500)
  expect_identical(as.numeric(log[[1]]$batches), 5)
  updates <- log[events == "update"]
  expect_identical(vapply(updates, function(e) as.numeric(e$rows), numeric(1)), c(120, 240, 360, 480, 500))
  expect_identical(vapply(updates, function(e) as.integer(e$batch), integer(1)), 1:5)

  log <- list()
  withr::local_options(rcs.quiet = TRUE)
  s2 <- duck_store()
  duck_write(s2$st, tbl, key = duck_key, partition = "year")
  expect_length(log, 0L)
})

# f. Check ----------------------------------------------------------------------------

test_that("check = TRUE detects a staged file altered by the writer", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(300))
  # the writer changes one column of every row it writes
  real <- parquet_stream_group
  local_mocked_bindings(parquet_stream_group = function(f, chunk) {
    chunk$qty <- chunk$qty + 1L
    real(f, chunk)
  })
  s <- duck_store()
  err <- expect_error(duck_write(s$st, tbl, key = duck_key, partition = "year"), class = "rcs_error_check")
  expect_match(cli::ansi_strip(conditionMessage(err)), "column qty differs from x")
  expect_identical(nrow(s$st$primary$catalog), 0L)
  expect_identical(duck_write_tables(con), character())

  # without the check, the altered files are written
  s2 <- duck_store()
  duck_write(s2$st, tbl, key = duck_key, partition = "year", check = FALSE)
  expect_identical(nrow(s2$st$primary$catalog), 1L)
})

test_that("check = TRUE detects a footer that does not hold the rows streamed", {
  skip_if_no_duckdb_write()
  con <- local_duckdb()
  tbl <- duck_table(con, duck_sales_data(300))
  real <- parquet_stream_close
  local_mocked_bindings(parquet_stream_close = function(f) {
    facts <- real(f)
    facts$rows <- facts$rows + 1
    facts
  })
  s <- duck_store()
  err <- expect_error(duck_write(s$st, tbl, key = duck_key), class = "rcs_error_check")
  expect_match(cli::ansi_strip(conditionMessage(err)), "were streamed")
})
