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
