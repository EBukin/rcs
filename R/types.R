# Restoring R types on data that reached R by another route than
# `collect()` of a store query (plan 0002, D4, D5, D8).

#' Restore the R types of a dataset's columns
#'
#' Data read from a dataset's files by other tools (`arrow::read_parquet()`,
#' DuckDB, ...) carries the storage types: character instead of factor,
#' double instead of difftime, integer or double instead of `integer64`,
#' plain 64-bit integers instead of H3 cells. `store_restore_types()` gives
#' back the R types recorded in the catalog's columns specification of
#' `dataset`. No data file is read.
#'
#' Each column of `x` whose name is in the specification is restored when
#' its type is compatible:
#'
#' * factor and ordered factor from character or factor, with the recorded
#'   levels (also the unused ones). Values outside the levels become `NA`,
#'   with one warning per column giving the count.
#' * difftime from double (taken in the recorded units) or difftime
#'   (converted to them).
#' * `integer64` from integer, `integer64`, or double when every value is
#'   whole and below 2^53 in absolute value; otherwise the column is left as
#'   it is, with a warning.
#' * list from an Arrow list or a list: a bare list.
#' * H3 cells (class [rcs_h3]): the `h3`, `h3_main` and `h3_p<r>` columns of
#'   geospatial datasets and index tables, and every column recorded as
#'   `rcs_h3`.
#'
#' Other columns are left unchanged, silently. Columns are matched by name
#' only: a computed column that reuses the name of a source column is
#' restored as that column.
#'
#' `collect()` of a query from [store_open()], with either engine, already
#' restores the types; this function is for data that reached R another
#' way, such as a DuckDB query of your own on the views of [store_duckdb()].
#'
#' @param x A data frame, tibble or `sf` object.
#' @param st A store connection made by [store_connect()].
#' @param dataset Name of the dataset `x` comes from: the full name, or its
#'   last part when that is unique. Index tables (`<dataset>__h3`) are
#'   accepted.
#' @return `x` with the columns restored, of the same class (data frame,
#'   tibble or `sf`).
#' @seealso [store_describe()] for the recorded types (`r_type`), [rcs_h3].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-restore-types")
#' st <- store_connect(root, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales."
#' )
#' path <- list.files(file.path(root, "sales/daily"),
#'   pattern = "\\.parquet$", full.names = TRUE
#' )
#' raw <- arrow::read_parquet(path[[1]])
#' class(raw$wait)
#' restored <- store_restore_types(raw, st, "sales/daily")
#' class(restored$wait)
#' unlink(root, recursive = TRUE)
store_restore_types <- function(x, st, dataset) {
  validate_store(st)
  call <- rlang::current_env()
  if (!is.data.frame(x)) {
    cli::cli_abort(
      "{.arg x} must be a data frame, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
  name <- resolve_dataset(st, dataset, index = TRUE, call = call)
  catalog <- st$primary$catalog
  entry <- catalog[catalog$dataset == name, ]
  spec <- columns_from_json(entry$columns)
  for (column in intersect(names(x), spec$name)) {
    r_type <- spec$r_type[[match(column, spec$name)]]
    cls <- r_type$class %||% ""
    v <- x[[column]]
    v <- switch(cls,
      factor = restore_factor_checked(v, r_type, column),
      difftime = if (is.double(v) || inherits(v, "difftime")) restore_difftime(v, r_type$units) else v,
      integer64 = ,
      rcs_h3 = restore_integer64_checked(v, column),
      list = if (is.list(v) && !is.data.frame(v)) restore_list(v) else v,
      v
    )
    if (!identical(v, x[[column]])) x[[column]] <- v
  }
  h3_classify(x, entry)
}

# A factor with the recorded levels from character or factor; values outside
# the levels become NA with a warning giving the count.
restore_factor_checked <- function(v, r_type, column) {
  if (!is.character(v) && !is.factor(v)) {
    return(v)
  }
  levels <- r_type$levels %||% character()
  ordered <- isTRUE(r_type$ordered)
  if (is.factor(v) && identical(levels(v), levels) && identical(is.ordered(v), ordered)) {
    return(v)
  }
  values <- as.character(v)
  outside <- sum(!is.na(values) & !values %in% levels)
  if (outside > 0) {
    cli::cli_warn(c(
      "Column {.field {column}}: {outside} value{?s} outside the recorded levels became {.val NA}."
    ))
  }
  factor(values, levels = levels, ordered = ordered)
}

# `integer64` from integer, `integer64`, or double with whole values below
# 2^53; other doubles are left as they are with a warning.
restore_integer64_checked <- function(v, column) {
  if (inherits(v, "integer64")) {
    return(v)
  }
  if (is.integer(v)) {
    return(bit64::as.integer64(v))
  }
  if (!is.double(v) || inherits(v, c("difftime", "Date", "POSIXt"))) {
    return(v)
  }
  bad <- sum(!is.na(v) & (abs(v) >= 2^53 | v != trunc(v)))
  if (bad > 0) {
    cli::cli_warn(c(
      "Column {.field {column}} not converted to {.cls integer64}.",
      i = "{bad} value{?s} {?is/are} not whole or not below 2^53."
    ))
    return(v)
  }
  bit64::as.integer64(v)
}
