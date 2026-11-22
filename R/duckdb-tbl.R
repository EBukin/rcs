# DuckDB tables from `store_open(engine = "duckdb")` (plan 0002, D3, D18,
# D20): one dataset as a dbplyr table on its DuckDB view, and the collect()
# method that gives back the R types and the geometry.
#
# The table carries the package's fields in the element `rcs` (dbplyr
# reserves `$`, fact 3): `store`, `dataset` (full name), `mode` and `tests`
# (pending exact spatial tests, filled by `store_intersects()`). They are
# read with `.subset2(x, "rcs")` and set by `duckdb_tbl_set()`; dbplyr's
# verbs keep them and the class.

# Package-level connections, one per store (keyed by the primary's uri).
# Each is held in an environment whose finalizer closes it.
the_duckdb <- new.env(parent = emptyenv())

#' Open a dataset as a DuckDB table
#'
#' @param st An `rcs_store`.
#' @param dataset Full dataset name (not a raster).
#' @param con `NULL` for the store's package-level connection, or a DuckDB
#'   connection made with `bigint = "integer64"`.
#' @param mode,spatial As in `store_duckdb()`.
#' @param call The caller's environment, for errors.
#' @return A dbplyr table of class `rcs_duckdb_tbl`.
#' @noRd
duckdb_tbl_open <- function(st, dataset, con, mode, spatial, call = caller_env()) {
  rlang::check_installed(
    c("duckdb", "DBI", "dbplyr"),
    reason = "to open a dataset as a DuckDB table.", call = call
  )
  if (is.null(con)) {
    con <- duckdb_store_con(st)
  } else {
    duckdb_check_con(con, call = call)
  }
  withr::with_options(
    list(rcs.quiet = TRUE),
    store_duckdb(st, con = con, datasets = dataset, mode = mode, spatial = spatial)
  )
  name <- duckdb_view_name(dataset)
  # dbplyr's tbl() on a DBI::Id prints an S4 method note once (fact 2)
  out <- suppressMessages(
    dplyr::tbl(con, DBI::Id(schema = name[["schema"]], table = name[["table"]]))
  )
  class(out) <- c("rcs_duckdb_tbl", class(out))
  duckdb_tbl_set(out, list(store = st, dataset = dataset, mode = mode, tests = list()))
}

# Set the `rcs` field of a dbplyr table (fact 3).
duckdb_tbl_set <- function(x, value) {
  cls <- class(x)
  x <- unclass(x)
  x$rcs <- value
  class(x) <- cls
  x
}

# Connections -----------------------------------------------------------------

#' The package-level DuckDB connection of a store
#'
#' In memory, made with `bigint = "integer64"`, one per store (keyed by the
#' primary's uri) and reused while it is valid. It is closed by
#' `store_duckdb_close()` and by a finalizer at the end of the session.
#'
#' @param st An `rcs_store`.
#' @return A DuckDB connection.
#' @noRd
duckdb_store_con <- function(st) {
  key <- st$primary$uri
  holder <- the_duckdb[[key]]
  if (!is.null(holder) && !is.null(holder$con) && DBI::dbIsValid(holder$con)) {
    return(holder$con)
  }
  holder <- new.env(parent = emptyenv())
  # duckdb's once-per-session note about its storage folder is not ours.
  holder$con <- suppressMessages(DBI::dbConnect(duckdb::duckdb(), bigint = "integer64"))
  reg.finalizer(holder, duckdb_holder_close, onexit = TRUE)
  assign(key, holder, envir = the_duckdb)
  holder$con
}

#' Close the package-level DuckDB connection of a store
#'
#' The connection that `store_open(engine = "duckdb")` makes when `con` is
#' `NULL`. Tables opened on it stop working. Nothing happens when the store
#' has no such connection.
#'
#' @param st An `rcs_store`.
#' @return `TRUE` when a connection was closed, `FALSE` otherwise,
#'   invisibly.
#' @noRd
store_duckdb_close <- function(st) {
  validate_store(st)
  key <- st$primary$uri
  holder <- the_duckdb[[key]]
  if (is.null(holder)) {
    return(invisible(FALSE))
  }
  rm(list = key, envir = the_duckdb)
  invisible(duckdb_holder_close(holder))
}

duckdb_holder_close <- function(holder) {
  con <- holder$con
  holder$con <- NULL
  if (is.null(con) || !DBI::dbIsValid(con)) {
    return(FALSE)
  }
  tryCatch(
    {
      DBI::dbDisconnect(con, shutdown = TRUE)
      TRUE
    },
    error = function(e) FALSE
  )
}

# collect() ---------------------------------------------------------------------

#' Collect a DuckDB table made by store_open()
#'
#' Runs the query in DuckDB and returns R data as a collect() of the Arrow
#' engine does (plan 0002, D20): a `GEOMETRY` column `geometry` is read as
#' WKB (`ST_AsWKB()`, fact 7), `.rcs_id` and `geom` are dropped, the R types
#' recorded in the catalog are restored with [store_restore_types()], pending
#' exact spatial tests run through `exact_keep()` when the geometry is read
#' (otherwise the result is the candidate set, with a message), and the
#' geometry becomes an `sf` column in the catalog's CRS.
#'
#' @param x A table made by `store_open(engine = "duckdb")`.
#' @param ... Passed to dbplyr's `collect()`.
#' @return A tibble, or an `sf` object when the geometry is read.
#' @exportS3Method dplyr::collect
#' @noRd
collect.rcs_duckdb_tbl <- function(x, ...) {
  local_trace("collect")
  rcs <- .subset2(x, "rcs")
  st <- rcs$store
  catalog <- st$primary$catalog
  entry <- catalog[catalog$dataset == rcs$dataset, ]

  present <- colnames(x)
  drop <- intersect(c(".rcs_id", "geom"), present)
  if (length(drop) > 0) {
    x <- dplyr::select(x, -dplyr::all_of(drop))
  }
  if ("geometry" %in% present && duckdb_tbl_is_geometry(x)) {
    x <- dplyr::mutate(x, geometry = dbplyr::sql('ST_AsWKB("geometry")'))
  }
  class(x) <- setdiff(class(x), "rcs_duckdb_tbl")
  data <- tibble::as_tibble(dplyr::collect(x, ...))
  # STRUCT columns (`bbox`) come back as data frames; Arrow gives tibbles
  for (name in names(data)[vapply(data, is.data.frame, logical(1))]) {
    data[[name]] <- tibble::as_tibble(data[[name]])
  }

  data <- store_restore_types(data, st, rcs$dataset)
  if (identical(entry$kind, "geospatial") && "geometry" %in% names(data) && is.list(data$geometry)) {
    data <- geo_decode(data, entry$crs)
  }
  if (length(rcs$tests) > 0) {
    pending <- list(spatial = list(tests = rcs$tests), location = list(uri = st$primary$uri))
    data <- spatial_exact(pending, data)
  }
  trace_count("rows_returned", nrow(data), location = st$primary$uri)
  data
}

# Whether the column `geometry` of a DuckDB table is of type GEOMETRY (native
# views, fact 7) rather than BLOB (arrow views).
duckdb_tbl_is_geometry <- function(x) {
  con <- dbplyr::remote_con(x)
  sql <- dbplyr::sql_render(dplyr::select(x, "geometry"))
  described <- DBI::dbGetQuery(con, paste("DESCRIBE", sql))
  type <- described$column_type[described$column_name == "geometry"]
  length(type) == 1 && startsWith(type, "GEOMETRY")
}
