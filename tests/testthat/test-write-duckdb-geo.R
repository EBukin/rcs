# store_write() of a lazy DuckDB table with a WKB geometry column, one file
# (plan 0002, D39, D31/D32 in batches): work package DW1.

# Helpers -----------------------------------------------------------------------

skip_if_no_duckdb_geo <- function() {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("h3o")
}

# An `sf` as a DuckDB table `name` with its geometry as WKB (`BLOB`), and a
# lazy table on it.
dgeo_table <- function(con, x, name) {
  data <- as.data.frame(sf::st_drop_geometry(x))
  wkb <- unclass(sf::st_as_binary(sf::st_geometry(x), EWKB = FALSE))
  attributes(wkb) <- NULL
  data$geometry <- wkb
  DBI::dbWriteTable(con, name, data, overwrite = TRUE)
  dplyr::tbl(con, name)
}

dgeo_store <- function(frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  path <- file.path(root, "primary")
  suppressMessages(store_create(path, history = FALSE))
  list(st = store_connect(path), path = normalizePath(path, winslash = "/"))
}

dgeo_write <- function(st, x, dataset = "geo/shapes", ...) {
  suppressMessages(store_write(st, x, dataset,
    title = "Shapes", description = "Simulated shapes.", ...
  ))
}

# The stored facts of a dataset that must not depend on how it was written:
# the catalog entry without its times, the file rows without `created`, the
# MD5 of every file on disk, and the manifest without its times.
dgeo_facts <- function(s, dataset) {
  st <- s$st
  entry <- st$primary$catalog[st$primary$catalog$dataset == dataset, ]
  files <- st$primary$files[st$primary$files$dataset == dataset, ]
  manifest <- readLines(file.path(s$path, manifest_path(dataset, entry$version)), warn = FALSE)
  list(
    entry = as.list(entry[setdiff(names(entry), c("created", "updated"))]),
    files = tibble::as_tibble(files[setdiff(names(files), "created")]),
    md5_on_disk = unname(tools::md5sum(file.path(s$path, files$path))),
    manifest = gsub("\"(created|updated|written)\": *\"[^\"]*\"", "\"<time>\"", paste(manifest, collapse = "\n"))
  )
}

# The `geo` metadata of every file of a dataset.
dgeo_geo_metadata <- function(s, dataset) {
  files <- s$st$primary$files$path[s$st$primary$files$dataset == dataset]
  vapply(files, function(p) {
    arrow::read_parquet(file.path(s$path, p), as_data_frame = FALSE)$metadata$geo
  }, character(1), USE.NAMES = FALSE)
}

# A spy around the real `duckdb_batches()`: the rows of every batch, per call.
local_batch_spy <- function(frame = parent.frame()) {
  calls <- new.env(parent = emptyenv())
  calls$rows <- list()
  real <- duckdb_batches
  local_mocked_bindings(
    duckdb_batches = function(con, sql, n) {
      it <- real(con, sql, n)
      k <- length(calls$rows) + 1L
      calls$rows[[k]] <- numeric()
      next_batch <- it$next_batch
      it$next_batch <- function() {
        batch <- next_batch()
        if (!is.null(batch)) calls$rows[[k]] <- c(calls$rows[[k]], batch$num_rows)
        batch
      }
      it
    },
    .env = frame
  )
  calls
}

# Data, index, geo metadata and catalog equal the R path --------------------------

test_that("polygons and points written from DuckDB equal store_write() of the same sf, in batches of 1,000", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 1000)
  cases <- list(
    polygons = list(x = rcs_sim_polygons(5000), key = "id"),
    points = list(x = rcs_sim_points(5000), key = "id"),
    points_keyless = list(x = rcs_sim_points(5000, seed = 2), key = NULL)
  )
  for (name in names(cases)) {
    x <- cases[[name]]$x
    key <- cases[[name]]$key
    # the test input holds integer, double and character attributes only
    types <- vapply(sf::st_drop_geometry(x), function(v) class(v)[[1]], character(1))
    expect_true(all(types %in% c("integer", "numeric", "character")), label = name)
    tbl <- dgeo_table(con, x, name)

    a <- dgeo_store()
    b <- dgeo_store()
    spy <- local_batch_spy()
    out_a <- dgeo_write(a$st, tbl, key = key, crs = 4326, rows_per_group = 1500L)
    out_b <- dgeo_write(b$st, x, key = key, rows_per_group = 1500L)

    # every batch holds at most 1,000 rows; one pass streams every row in
    # at least five batches
    rows <- spy$rows
    expect_gte(length(rows), 1L)
    for (r in rows) expect_true(all(r <= 1000), label = name)
    full <- Filter(function(r) sum(r) == nrow(x), rows)
    expect_gte(length(full), 1L)
    expect_true(all(lengths(full) >= 5L), label = name)

    expect_identical(attr(out_a, "version"), attr(out_b, "version"), label = name)
    expect_identical(dgeo_facts(a, "geo/shapes"), dgeo_facts(b, "geo/shapes"), label = name)
    expect_identical(dgeo_geo_metadata(a, "geo/shapes"), dgeo_geo_metadata(b, "geo/shapes"), label = name)
    idx <- index_name("geo/shapes")
    expect_identical(idx %in% a$st$primary$catalog$dataset, idx %in% b$st$primary$catalog$dataset, label = name)
    if (idx %in% b$st$primary$catalog$dataset) {
      expect_identical(dgeo_facts(a, idx), dgeo_facts(b, idx), label = name)
    }
    entry <- a$st$primary$catalog[a$st$primary$catalog$dataset == "geo/shapes", ]
    expect_identical(entry$kind, "geospatial")
    expect_identical(entry$geocode_engine, "auto")
    expect_identical(as.numeric(entry$n_files), 1)
    expect_store_valid(a$st)
  }
})

test_that("rows read back from a DuckDB write equal the sf in .rcs_id order", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 1000)
  x <- rcs_sim_polygons(2500, seed = 4)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  dgeo_write(a$st, tbl, key = "id", crs = 4326)
  dgeo_write(b$st, x, key = "id")
  ra <- store_read(a$st, "geo/shapes", columns = c(".rcs_id", "id", "h3"))
  rb <- store_read(b$st, "geo/shapes", columns = c(".rcs_id", "id", "h3"))
  expect_identical(ra, rb)
})

# Arguments ---------------------------------------------------------------------

test_that("a DuckDB table with a geometry column needs crs", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  tbl <- dgeo_table(con, rcs_sim_points(20), "pts")
  s <- dgeo_store()
  expect_error(dgeo_write(s$st, tbl, key = "id"), class = "rcs_error_argument")
  withr::local_options(cli.width = 250, width = 250)
  expect_snapshot(dgeo_write(s$st, tbl, key = "id"), error = TRUE)
  expect_false("geo/shapes" %in% s$st$primary$catalog$dataset)
})

test_that("a geometry column of another type aborts naming it", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  DBI::dbExecute(con, "CREATE TABLE bad AS SELECT range::INTEGER AS id, 'POINT (1 2)' AS geometry FROM range(3)")
  s <- dgeo_store()
  withr::local_options(cli.width = 250, width = 250)
  expect_snapshot(dgeo_write(s$st, dplyr::tbl(con, "bad"), key = "id", crs = 4326), error = TRUE)
})

# Geocoding repairs (D32) ----------------------------------------------------------

test_that("the polygons of fact 18 warn with their keys, as store_write() of the sf does", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 7)
  x <- geo_with_invalid()
  tbl <- dgeo_table(con, x, "invalid")
  a <- dgeo_store()
  b <- dgeo_store()
  wa <- expect_warning(dgeo_write(a$st, tbl, key = "id", crs = 4326), class = "rcs_warning_s2_rebuild")
  wb <- expect_warning(dgeo_write(b$st, x, key = "id"), class = "rcs_warning_s2_rebuild")
  expect_identical(conditionMessage(wa), conditionMessage(wb))
  expect_match(conditionMessage(wa), "21")
  expect_match(conditionMessage(wa), "22")
  expect_identical(dgeo_facts(a, "geo/shapes"), dgeo_facts(b, "geo/shapes"))

  # without a key the warning names `.rcs_id`, as for the sf
  c1 <- dgeo_store()
  c2 <- dgeo_store()
  wc1 <- expect_warning(dgeo_write(c1$st, tbl, crs = 4326), class = "rcs_warning_s2_rebuild")
  wc2 <- expect_warning(dgeo_write(c2$st, x), class = "rcs_warning_s2_rebuild")
  expect_identical(conditionMessage(wc1), conditionMessage(wc2))
})

# Check (D40) ------------------------------------------------------------------------

test_that("check = TRUE detects a staged geospatial file altered by the writer", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  tbl <- dgeo_table(con, rcs_sim_points(200), "pts")
  real <- parquet_stream_group
  local_mocked_bindings(parquet_stream_group = function(f, chunk) {
    if ("value" %in% names(chunk)) chunk$value <- chunk$value + 1
    real(f, chunk)
  })
  s <- dgeo_store()
  err <- expect_error(dgeo_write(s$st, tbl, key = "id", crs = 4326), class = "rcs_error_check")
  expect_match(cli::ansi_strip(conditionMessage(err)), "column value differs from x")
  expect_identical(nrow(s$st$primary$catalog), 0L)
})

# Temporary tables -----------------------------------------------------------------

test_that("the temporary DuckDB tables are gone after a geospatial write", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  tbl <- dgeo_table(con, rcs_sim_points(50), "pts")
  s <- dgeo_store()
  dgeo_write(s$st, tbl, key = "id", crs = 4326)
  left <- DBI::dbGetQuery(con, "SELECT table_name FROM duckdb_tables() WHERE table_name LIKE 'rcs_%'")
  expect_identical(nrow(left), 0L)
})

# DW2: partitions, engines, GEOMETRY input ---------------------------------------

# The data, index, geo metadata and version of a write from DuckDB equal
# those of the same write from the sf.
expect_dgeo_same <- function(a, b, out_a, out_b, label = NULL) {
  expect_identical(attr(out_a, "version"), attr(out_b, "version"), label = label)
  expect_identical(dgeo_facts(a, "geo/shapes"), dgeo_facts(b, "geo/shapes"), label = label)
  expect_identical(dgeo_geo_metadata(a, "geo/shapes"), dgeo_geo_metadata(b, "geo/shapes"), label = label)
  idx <- index_name("geo/shapes")
  has_a <- idx %in% a$st$primary$catalog$dataset
  expect_identical(has_a, idx %in% b$st$primary$catalog$dataset, label = label)
  if (has_a) {
    expect_identical(dgeo_facts(a, idx), dgeo_facts(b, idx), label = label)
  }
  invisible()
}

# Polygons with one empty geometry (an `h3_p<r>=null` partition).
dgeo_polygons_empty <- function(n, seed = 1) {
  x <- rcs_sim_polygons(n, seed = seed)
  x$geometry[n] <- sf::st_polygon()
  x
}

test_that("partition = \"h3\" from DuckDB gives the files and version of store_write() of the sf", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 1000)
  cases <- list(
    polygons = list(x = dgeo_polygons_empty(3000), key = "id", max_files = 50L),
    polygons_coarse = list(x = dgeo_polygons_empty(3000), key = "id", max_files = 6L),
    points_keyless = list(x = rcs_sim_points(3000, seed = 2), key = NULL, max_files = 20L)
  )
  for (name in names(cases)) {
    x <- cases[[name]]$x
    types <- vapply(sf::st_drop_geometry(x), function(v) class(v)[[1]], character(1))
    expect_true(all(types %in% c("integer", "numeric", "character")), label = name)
    tbl <- dgeo_table(con, x, name)
    a <- dgeo_store()
    b <- dgeo_store()
    args <- list(
      key = cases[[name]]$key, partition = "h3", max_files = cases[[name]]$max_files,
      rows_per_group = 700L
    )
    out_a <- do.call(dgeo_write, c(list(a$st, tbl, crs = 4326), args))
    out_b <- do.call(dgeo_write, c(list(b$st, x), args))
    expect_dgeo_same(a, b, out_a, out_b, label = name)
    entry <- a$st$primary$catalog[a$st$primary$catalog$dataset == "geo/shapes", ]
    expect_match(unlist(entry$partition), "^h3_p[0-9]$", label = name)
    expect_gt(as.numeric(entry$n_files), 1)
    expect_lte(as.numeric(entry$n_files), cases[[name]]$max_files)
    expect_store_valid(a$st)
  }
})

test_that("partition by an attribute column from DuckDB equals store_write() of the sf", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 400)
  x <- rcs_sim_polygons(1500, seed = 5)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  out_a <- dgeo_write(a$st, tbl, key = "id", partition = "cat", crs = 4326)
  out_b <- dgeo_write(b$st, x, key = "id", partition = "cat")
  expect_dgeo_same(a, b, out_a, out_b)
  expect_gt(as.numeric(a$st$primary$catalog$n_files[a$st$primary$catalog$dataset == "geo/shapes"]), 1)
})

test_that("a user column h3_p<r> with other cells aborts as for the sf, the same cells serve", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  x <- rcs_sim_points(200, seed = 3)
  x$h3_p5 <- seq_len(200)
  s <- dgeo_store()
  tbl <- dgeo_table(con, x, "pts")
  expect_error(
    dgeo_write(s$st, tbl, key = "id", partition = "h3", max_files = 1000L, crs = 4326),
    class = "rcs_error_prepared"
  )
  expect_error(dgeo_write(s$st, x, key = "id", partition = "h3", max_files = 1000L), class = "rcs_error_prepared")
})

test_that("geocode = FALSE from DuckDB equals store_write() of the sf", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 500)
  x <- rcs_sim_polygons(1200, seed = 6)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  out_a <- dgeo_write(a$st, tbl, key = "id", geocode = FALSE, crs = 4326)
  out_b <- dgeo_write(b$st, x, key = "id", geocode = FALSE)
  expect_dgeo_same(a, b, out_a, out_b)
  entry <- a$st$primary$catalog[a$st$primary$catalog$dataset == "geo/shapes", ]
  expect_true(is.na(entry$h3_res))
  expect_true(is.na(entry$geocode_engine))
  expect_false(index_name("geo/shapes") %in% a$st$primary$catalog$dataset)

  # with a partition column
  c1 <- dgeo_store()
  c2 <- dgeo_store()
  out_c1 <- dgeo_write(c1$st, tbl, key = "id", geocode = FALSE, partition = "cat", crs = 4326)
  out_c2 <- dgeo_write(c2$st, x, key = "id", geocode = FALSE, partition = "cat")
  expect_dgeo_same(c1, c2, out_c1, out_c2)
})

test_that("geocode_engine = \"planar\" is stored and gives the files of the sf", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 60)
  x <- rcs_sim_polygons(150, seed = 7)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  out_a <- dgeo_write(a$st, tbl, key = "id", geocode_engine = "planar", crs = 4326)
  out_b <- dgeo_write(b$st, x, key = "id", geocode_engine = "planar")
  expect_dgeo_same(a, b, out_a, out_b)
  entry <- a$st$primary$catalog[a$st$primary$catalog$dataset == "geo/shapes", ]
  expect_identical(entry$geocode_engine, "planar")
})

test_that("a GEOMETRY column gives the files of the sf", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  local_duckdb_spatial(con)
  withr::local_options(rcs.duckdb_batch_rows = 500)
  x <- rcs_sim_polygons(1200, seed = 8)
  dgeo_table(con, x, "shapes_wkb")
  DBI::dbExecute(con, paste(
    "CREATE TABLE shapes AS SELECT * EXCLUDE (geometry), ST_GeomFromWKB(geometry) AS geometry FROM shapes_wkb"
  ))
  tbl <- dplyr::tbl(con, "shapes")
  type <- DBI::dbGetQuery(con, paste(
    "SELECT data_type FROM information_schema.columns",
    "WHERE table_name = 'shapes' AND column_name = 'geometry'"
  ))
  expect_match(type$data_type, "^GEOMETRY")
  for (partition in list(NULL, "h3")) {
    a <- dgeo_store()
    b <- dgeo_store()
    out_a <- dgeo_write(a$st, tbl, key = "id", partition = partition, crs = 4326)
    out_b <- dgeo_write(b$st, x, key = "id", partition = partition)
    expect_dgeo_same(a, b, out_a, out_b, label = paste(c("partition", partition), collapse = " "))
  }
})

test_that("store_read(intersects = cells) of a DuckDB write equals that of the sf write", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  withr::local_options(rcs.duckdb_batch_rows = 1000)
  x <- rcs_sim_polygons(2500, seed = 9)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  dgeo_write(a$st, tbl, key = "id", partition = "h3", crs = 4326)
  dgeo_write(b$st, x, key = "id", partition = "h3")
  h3 <- store_read(b$st, "geo/shapes", columns = "h3")$h3
  cells <- vctrs::vec_unique(bit64::as.integer64(h3))[c(1, 5, 9)]
  ra <- store_read(a$st, "geo/shapes", intersects = cells)
  rb <- store_read(b$st, "geo/shapes", intersects = cells)
  expect_gt(nrow(rb), 0)
  expect_identical(ra, rb)
})

test_that("an index above rows_per_group * 100 rows is streamed per H3 partition, never collected", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  n <- 300
  withr::local_options(rcs.duckdb_batch_rows = n)
  x <- rcs_sim_polygons(1500, seed = 10)
  tbl <- dgeo_table(con, x, "shapes")
  a <- dgeo_store()
  b <- dgeo_store()
  spy <- local_batch_spy()
  frames <- new.env(parent = emptyenv())
  frames$rows <- list()
  real_frame <- duckdb_frame
  local_mocked_bindings(duckdb_frame = function(con, sql, table = FALSE) {
    out <- real_frame(con, sql, table = table)
    frames$rows[[length(frames$rows) + 1L]] <- list(names = names(out), rows = nrow(out))
    out
  })
  out_a <- dgeo_write(a$st, tbl, key = "id", crs = 4326, rows_per_group = 5L)
  out_b <- dgeo_write(b$st, x, key = "id", rows_per_group = 5L)
  expect_dgeo_same(a, b, out_a, out_b)

  idx <- index_name("geo/shapes")
  entry <- a$st$primary$catalog[a$st$primary$catalog$dataset == idx, ]
  expect_gt(entry$rows, 5 * 100)
  expect_match(unlist(entry$partition), "^h3_p[0-9]$")
  expect_gt(as.numeric(entry$n_files), 1)
  for (r in spy$rows) expect_true(all(r <= n))
  # no fetch of rows (data or index) larger than one batch
  row_fetches <- Filter(function(f) ".rcs_id" %in% f$names || "share" %in% f$names, frames$rows)
  expect_true(all(vapply(row_fetches, function(f) f$rows <= n, logical(1))))
})

# Aborts ---------------------------------------------------------------------------

test_that("an invalid crs and partitions that cannot apply abort", {
  skip_if_no_duckdb_geo()
  con <- local_duckdb()
  tbl <- dgeo_table(con, rcs_sim_points(20), "pts")
  s <- dgeo_store()
  withr::local_options(cli.width = 250, width = 250)
  expect_error(dgeo_write(s$st, tbl, key = "id", crs = "not a crs"), class = "rcs_error_argument")
  expect_snapshot(dgeo_write(s$st, tbl, key = "id", crs = "not a crs"), error = TRUE)
  expect_snapshot(dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "h3", geocode = FALSE), error = TRUE)
  expect_snapshot(dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = c("h3", "id")), error = TRUE)
  expect_snapshot(dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "nowhere"), error = TRUE)
  expect_snapshot(
    dgeo_write(s$st, tbl, key = "id", crs = 4326, partition = "h3", max_files = 1L, h3_res = 9L),
    error = TRUE
  )
  expect_false("geo/shapes" %in% s$st$primary$catalog$dataset)
})
