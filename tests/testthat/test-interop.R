# Interoperability (plan, "Testing"): files written by store_write() are
# read by other tools. DuckDB with its spatial extension reads a GeoParquet
# file as geometry with its CRS and filters on the `bbox` covering columns;
# GDAL reads it when its Parquet driver is present (common Windows builds
# lack it, so that test usually skips there).

skip_below_level("default")

# A store with a geospatial dataset, in EPSG:4326 and in a projected CRS.
interop_store <- function(frame = parent.frame()) {
  skip_if_no_h3()
  path <- file.path(withr::local_tempdir(.local_envir = frame), "store")
  st <- suppressMessages(store_connect(path, create = TRUE))
  pol <- rcs_sim_polygons(40, seed = 1)
  suppressMessages(store_write(st, pol, "shapes/polygons", title = "Polygons", description = "d"))
  suppressMessages(store_write(st, sf::st_transform(pol, 32626), "shapes/projected",
    title = "Projected polygons", description = "d", partition = "h3", max_files = 3
  ))
  files <- st$primary$files
  list(
    st = st,
    files = function(dataset) {
      normalizePath(file.path(path, files$path[files$dataset == dataset]), winslash = "/")
    }
  )
}

# A DuckDB connection with the spatial extension loaded, or a skip.
local_duckdb_spatial <- function(frame = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  con <- suppressMessages(DBI::dbConnect(duckdb::duckdb()))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = frame)
  load <- function(sql) {
    tryCatch(
      {
        DBI::dbExecute(con, sql)
        TRUE
      },
      error = function(e) FALSE
    )
  }
  if (!load("LOAD spatial")) {
    skip_if_offline()
    if (!load("INSTALL spatial") || !load("LOAD spatial")) {
      skip("The DuckDB spatial extension cannot be installed or loaded.")
    }
  }
  con
}

parquet_list <- function(paths) {
  paste0("['", paste(paths, collapse = "', '"), "']")
}

test_that("DuckDB reads the geometry with its CRS", {
  con <- local_duckdb_spatial()
  s <- interop_store()
  for (case in list(c("shapes/polygons", "4326"), c("shapes/projected", "32626"))) {
    files <- parquet_list(s$files(case[[1]]))
    described <- DBI::dbGetQuery(con, paste0("DESCRIBE SELECT * FROM read_parquet(", files, ")"))
    type <- described$column_type[described$column_name == "geometry"]
    expect_match(type, "^GEOMETRY", label = case[[1]])
    crs <- tryCatch(
      DBI::dbGetQuery(con, paste0("SELECT ST_CRS(geometry) AS crs FROM read_parquet(", files, ") LIMIT 1"))$crs,
      error = function(e) NA_character_
    )
    expect_true(grepl(case[[2]], type, fixed = TRUE) || grepl(case[[2]], crs, fixed = TRUE),
      label = paste(case[[1]], "reports EPSG", case[[2]])
    )
    rows <- DBI::dbGetQuery(con, paste0("SELECT count(*) AS n FROM read_parquet(", files, ")"))$n
    expect_equal(rows, 40)
  }
})

test_that("a DuckDB filter on the bbox struct returns the rows of the same filter in R", {
  con <- local_duckdb_spatial()
  s <- interop_store()
  q <- c(xmin = -27, ymin = 7, xmax = -25.5, ymax = 8.5)
  sql <- paste0(
    "SELECT id FROM read_parquet(", parquet_list(s$files("shapes/polygons")), ") ",
    "WHERE bbox.xmin <= ", q[["xmax"]], " AND bbox.xmax >= ", q[["xmin"]],
    " AND bbox.ymin <= ", q[["ymax"]], " AND bbox.ymax >= ", q[["ymin"]]
  )
  got <- sort(DBI::dbGetQuery(con, sql)$id)
  x <- suppressMessages(store_read(s$st, "shapes/polygons", geometry = FALSE))
  b <- x$bbox
  keep <- b$xmin <= q[["xmax"]] & b$xmax >= q[["xmin"]] & b$ymin <= q[["ymax"]] & b$ymax >= q[["ymin"]]
  expected <- sort(x$id[!is.na(keep) & keep])
  expect_gt(length(expected), 0)
  expect_lt(length(expected), nrow(x))
  expect_identical(got, expected)
})

test_that("GDAL reads the file when its Parquet driver is present", {
  skip_if_not("Parquet" %in% sf::st_drivers()$name, "sf's GDAL has no Parquet driver.")
  s <- interop_store()
  got <- sf::st_read(s$files("shapes/polygons"), quiet = TRUE)
  expected <- suppressMessages(store_read(s$st, "shapes/polygons"))
  expect_s3_class(got, "sf")
  expect_identical(nrow(got), nrow(expected))
  expect_true(sf::st_crs(got) == sf::st_crs(expected))
  expect_setequal(got$id, expected$id)
})
