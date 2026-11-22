# The spatial filter on a DuckDB table made by `store_open(engine = "duckdb")`
# (plan 0002, D28, D35). The steps of the Arrow path (`R/intersects.R`),
# written as SQL:
#
#   1-2. query shape and covering cells: `geo_covering()`, as for Arrow;
#   3.   files: the view lists the files of the catalog's version; pruning
#        is left to DuckDB's row-group statistics;
#   4.   candidate rows, a `WHERE` clause on the view: `bbox` overlapping the
#        query box (rows whose box spans 180 degrees or more always pass in
#        a geographic CRS; skipped for a query without box), and, when the
#        cell filter pays off (`spatial_use_cells()`), `h3` in the covering
#        cells OR `.rcs_id` among the rows of the index view whose `h3` is in
#        them. The cells are integer literals up to `duckdb_cells_max`, and a
#        temporary table above;
#   5.   exact test: `exact = TRUE` in R at `collect()` (`exact_keep()` with
#        the engine of D35, as the Arrow path: the same rows);
#        `exact = "sql"` with `ST_Intersects()` in DuckDB (planar, stays
#        lazy); `exact = FALSE` none (the candidate set, with a message at
#        `collect()`).
#
# The same candidate predicate as the Arrow path gives the same candidate
# rows: file pruning there drops no candidate row.

# Above this number of covering cells the cells go through a temporary table.
duckdb_cells_max <- 10000

# Counter for the names of the temporary cell tables.
the_duckdb_cells <- new.env(parent = emptyenv())

#' Add a spatial filter to a DuckDB table
#'
#' @param q An `rcs_duckdb_tbl`.
#' @param y The query shape (as for `store_intersects()`).
#' @param exact `TRUE`, `FALSE` or `"sql"`.
#' @param exact_engine `NULL`, or one of `exact_engines`.
#' @param call Environment for errors.
#' @return `q` with the candidate test added to its SQL and, unless `exact`
#'   is `"sql"`, the test appended to the `tests` of its `rcs` field.
#' @noRd
duckdb_intersects <- function(q, y, exact = TRUE, exact_engine = NULL, call = caller_env()) {
  check_duckdb_exact(exact, call = call)
  check_exact_engine(exact_engine, call = call)
  rcs <- .subset2(q, "rcs")
  st <- rcs$store
  catalog <- st$primary$catalog
  entry <- catalog[catalog$dataset == rcs$dataset, ]
  if (!identical(entry$kind, "geospatial")) {
    cli::cli_abort(
      c(
        "A spatial filter needs a geospatial dataset.",
        x = "{.val {entry$dataset}} is a {entry$kind}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (is.null(y)) {
    cli::cli_abort("{.arg y} must be a query shape or H3 cells, not {.code NULL}.",
      class = "rcs_error_argument", call = call
    )
  }
  columns <- colnames(q)
  duckdb_check_columns(columns, "bbox", call = call)
  sql_exact <- identical(exact, "sql")
  if (sql_exact) {
    duckdb_check_columns(columns, "geometry", call = call)
  }

  exact_engine <- exact_engine_of(exact_engine, entry)
  check_query_valid(y, entry$crs, if (sql_exact) "planar" else exact_engine, call = call)
  covering <- rlang::try_fetch(
    geo_covering(y, entry$h3_res, entry$crs),
    rcs_error_h3_input = function(e) {
      cli::cli_abort(
        "{.arg y} must be an {.cls sf}, {.cls sfc} or {.cls bbox} object, or H3 cells.",
        class = c("rcs_error_h3_input", "rcs_error_argument"), parent = e, call = call
      )
    }
  )
  geographic <- geo_crs_is_longlat(entry$crs)
  con <- dbplyr::remote_con(q)

  conditions <- character()
  if (!is.null(covering$bbox)) {
    conditions <- c(conditions, duckdb_box_sql(covering$bbox, geographic))
  }
  cells <- NULL
  if (spatial_use_cells(covering)) {
    duckdb_check_columns(columns, c("h3", ".rcs_id"), call = call)
    cells <- covering$cells
    index <- index_name(entry$dataset)
    view <- if (index %in% catalog$dataset) duckdb_qualified(con, duckdb_view_name(index))
    conditions <- c(conditions, duckdb_cells_sql(con, cells, view, subquery = identical(rcs$mode, "arrow")))
  }
  if (sql_exact) {
    duckdb_load_spatial(con, call = call)
    geometry <- if (duckdb_tbl_is_geometry(q)) '"geometry"' else 'ST_GeomFromWKB("geometry")'
    conditions <- c(conditions, paste0(
      "ST_Intersects(", geometry, ", ST_GeomFromText(",
      DBI::dbQuoteString(con, duckdb_wkt(covering$shape)), "))"
    ))
  }
  if (length(conditions) > 0) {
    where <- paste(conditions, collapse = " AND ")
    q <- dplyr::filter(q, dbplyr::sql(!!where))
  }
  if (!sql_exact) {
    test <- list(
      shape = covering$shape, exact = exact, bbox = covering$bbox,
      cells = cells, geographic = geographic, exact_engine = exact_engine
    )
    rcs <- .subset2(q, "rcs")
    rcs$tests <- c(rcs$tests, list(test))
    q <- duckdb_tbl_set(q, rcs)
  }
  q
}

# `exact` of a DuckDB spatial filter: `TRUE`, `FALSE` or `"sql"`.
check_duckdb_exact <- function(exact, call = caller_env()) {
  if (rlang::is_bool(exact) || identical(exact, "sql")) {
    return(invisible(exact))
  }
  given <- if (rlang::is_string(exact)) {
    cli::format_inline("{.val {exact}}")
  } else {
    cli::format_inline("{.obj_type_friendly {exact}}")
  }
  cli::cli_abort(
    c(
      "{.arg exact} must be {.code TRUE}, {.code FALSE} or {.val sql} on a DuckDB table.",
      x = "It is {given}."
    ),
    class = "rcs_error_argument", call = call
  )
}

# Abort when the table lacks columns the spatial filter needs.
duckdb_check_columns <- function(columns, needed, call = caller_env()) {
  missing <- setdiff(needed, columns)
  if (length(missing) == 0) {
    return(invisible(NULL))
  }
  cli::cli_abort(
    c(
      "A spatial filter on a DuckDB table needs {cli::qty(missing)}the column{?s} {.field {missing}}.",
      i = "Call {.fn store_intersects} before {.fn dplyr::select} drops {cli::qty(missing)}{?it/them}."
    ),
    class = "rcs_error_argument", call = call
  )
}

# A double as an SQL literal that reads back as the same double.
duckdb_num <- function(x) {
  sprintf("%.17g", x)
}

# The box test of step 4 on the `bbox` struct.
duckdb_box_sql <- function(b, geographic) {
  field <- function(name) paste0("struct_extract(\"bbox\", '", name, "')")
  box <- paste0(
    "(", field("xmin"), " <= ", duckdb_num(b[["xmax"]]),
    " AND ", field("xmax"), " >= ", duckdb_num(b[["xmin"]]),
    " AND ", field("ymin"), " <= ", duckdb_num(b[["ymax"]]),
    " AND ", field("ymax"), " >= ", duckdb_num(b[["ymin"]]), ")"
  )
  if (geographic) {
    box <- paste0("(", field("xmax"), " - ", field("xmin"), " >= 180 OR ", box, ")")
  }
  box
}

#' The cell test of step 4
#'
#' @param con The DuckDB connection.
#' @param cells `integer64` covering cells.
#' @param view `NULL`, or the quoted `schema.table` of the index view.
#' @param subquery `TRUE` gives the literals as a subquery
#'   (`SELECT unnest([...]::BIGINT[])`) instead of a list. Views in arrow
#'   mode need it: DuckDB pushes a comparison of a `BIGINT` column with
#'   literals into the Arrow scan with the literals as doubles, and Arrow
#'   then fails to cast the column (cells are above 2^53); a semi-join is
#'   not pushed that way.
#' @return SQL: `"h3" IN (...)`, with `OR ".rcs_id" IN (SELECT ...)` over the
#'   index view when there is one. Above `duckdb_cells_max` cells, `(...)`
#'   selects from a temporary table written on `con`.
#' @noRd
duckdb_cells_sql <- function(con, cells, view = NULL, subquery = FALSE) {
  if (length(cells) > duckdb_cells_max) {
    the_duckdb_cells$n <- (the_duckdb_cells$n %||% 0L) + 1L
    name <- paste0("rcs_cells_", Sys.getpid(), "_", the_duckdb_cells$n)
    DBI::dbWriteTable(con, name, data.frame(h3 = cells), temporary = TRUE)
    set <- paste0("SELECT \"h3\" FROM temp.main.", duckdb_id(con, name))
  } else {
    set <- paste(as.character(cells), collapse = ", ")
    if (subquery) {
      set <- paste0("SELECT unnest([", set, "]::BIGINT[])")
    }
  }
  out <- paste0("\"h3\" IN (", set, ")")
  if (!is.null(view)) {
    out <- paste0(
      "(", out, " OR \".rcs_id\" IN (SELECT \".rcs_id\" FROM ", view,
      " WHERE \"h3\" IN (", set, ")))"
    )
  }
  out
}

# Load DuckDB's spatial extension, installing it when it is missing.
duckdb_load_spatial <- function(con, call = caller_env()) {
  loaded <- tryCatch(
    {
      duckdb_exec(con, "LOAD spatial")
      TRUE
    },
    error = function(e) FALSE
  )
  if (!loaded) {
    duckdb_run(con, "INSTALL spatial", "Installing the DuckDB extension {.val spatial} failed.", call = call)
    duckdb_run(con, "LOAD spatial", "Loading the DuckDB extension {.val spatial} failed.", call = call)
  }
  invisible(con)
}

# WKT of an `sfc` of length 1 with coordinates that read back exactly.
duckdb_wkt <- function(shape) {
  wkt <- wk::wk_handle(geo_wkb(shape), wk::wkt_writer(precision = 17, trim = TRUE))
  as.character(unclass(wkt))
}
