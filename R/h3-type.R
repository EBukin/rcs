# H3 cell class: 64-bit integers printed as hex (plan 0002, D7 to D10).

#' H3 cells as 64-bit integers, printed as hex
#'
#' @description
#' Cells read from a store (`h3`, `h3_main`, `h3_p<r>` and any column written
#' as `rcs_h3`) have class `rcs_h3`: a `bit64::integer64` vector holding the
#' same 64 bits that Parquet stores, sorts and filters, printed (console,
#' tibble, `sf`) as the 15-character lower-case hex string that other H3
#' tools use.
#'
#' * Comparison, arithmetic, sorting and joins are those of `integer64`;
#'   joining an `rcs_h3` column with an `integer64` column works and gives
#'   `rcs_h3` (also with `dplyr::bind_rows()` and `vctrs::vec_c()`).
#' * Subsetting, `c()`, `rep()`, `unique()`, `sort()` and `rev()` keep the
#'   class.
#' * `format()` and printing show `NA` as `NA` and a value that is not a
#'   valid cell as `<invalid>`; they never fail.
#' * `as.character()` gives decimal strings, exactly as for `integer64`; use
#'   [rcs_h3_hex()] for hex strings.
#' * A column of class `rcs_h3` is stored as a 64-bit integer, like an
#'   `integer64` column; `class(x) <- "integer64"` or `bit64::as.integer64()`
#'   drops the class.
#'
#' @name rcs_h3
#' @seealso [rcs_h3_hex()], [store_h3_hex()].
#' @examples
#' cells <- bit64::as.integer64(c("599686042433355775", "599686030622195711"))
#' rcs_h3_hex(cells)
NULL

#' Internal constructor of `rcs_h3`
#'
#' @param x Anything `bit64::as.integer64()` accepts.
#' @return `x` as `integer64` with class `c("rcs_h3", "integer64")`.
#' @noRd
new_rcs_h3 <- function(x = bit64::integer64()) {
  if (!inherits(x, "integer64")) {
    x <- bit64::as.integer64(x)
  }
  class(x) <- c("rcs_h3", "integer64")
  x
}

# The same bits as plain `integer64`.
rcs_h3_strip <- function(x) {
  class(x) <- "integer64"
  x
}

# Hex of each value, never aborting: NA as NA, a value that is not a valid
# cell as "<invalid>".
rcs_h3_format_hex <- function(x) {
  hex <- h3_int64_to_hex_raw(rcs_h3_strip(x))
  missing <- is.na(rcs_h3_strip(x))
  given <- !is.na(hex)
  valid <- rep(FALSE, length(hex))
  valid[given] <- h3_hex_is_cell(hex[given])
  out <- hex
  out[!valid] <- "<invalid>"
  out[missing] <- NA_character_
  out
}

#' Hex strings of H3 cells
#'
#' Converts any vector of H3 cells to the 15-character lower-case hex strings
#' that other H3 tools use. Inside a DuckDB connection prepared by the
#' package, the SQL macro of the same name gives the same strings, so
#' `dplyr::mutate(cell = rcs_h3_hex(h3))` reads the same in both engines.
#'
#' @param x Cells: `rcs_h3`, `bit64::integer64`, hex strings (any case), an
#'   `h3o` `H3` vector, or doubles. A double cannot hold a cell exactly (cells
#'   are above 2^53), so doubles give a warning of class
#'   `rcs_warning_h3_double` and are then validated like any other input; a
#'   cell whose last bits were lost is no longer a valid cell.
#' @return A character vector of the same length; `NA` stays `NA`. Aborts
#'   with class `rcs_error_h3_input` when a value is not a valid cell or `x`
#'   has another type.
#' @seealso [rcs_h3], [store_h3_hex()] for the cell columns of a data frame.
#' @export
#' @examples
#' cells <- bit64::as.integer64(c("599686042433355775", NA))
#' rcs_h3_hex(cells)
#' rcs_h3_hex("85283473FFFFFFF")
#' @examplesIf rlang::is_installed("h3o")
#' rcs_h3_hex(h3o::h3_from_strings("85283473fffffff"))
rcs_h3_hex <- function(x) {
  call <- rlang::current_env()
  if (is.double(x) && !inherits(x, "integer64")) {
    if (any(abs(x) >= 2^53, na.rm = TRUE)) {
      cli::cli_warn(
        c(
          "{.arg x} is a double: cells above 2^53 may have lost their last bits.",
          i = "Read cells as {.cls integer64}, for DuckDB with {.code DBI::dbConnect(duckdb::duckdb(), bigint = \"integer64\")}."
        ),
        class = "rcs_warning_h3_double"
      )
    }
    x <- bit64::as.integer64(x)
  }
  if (inherits(x, "rcs_h3")) {
    x <- rcs_h3_strip(x)
  }
  h3_as_hex(x, arg = "x", call = call)
}

#' SQL of the DuckDB macro `rcs_h3_hex()`
#'
#' Every DuckDB connection the package prepares runs this statement (D10).
#' @return One string.
#' @noRd
h3_duckdb_macro_sql <- function() {
  "CREATE OR REPLACE MACRO rcs_h3_hex(x) AS lower(printf('%x', x))"
}

#' Give the cell columns of a read their class
#'
#' Classes as `rcs_h3` every `integer64` column that is `h3`, `h3_main` or
#' `h3_p<r>` of a geospatial dataset or an index table, and every column
#' whose recorded `r_type` is `rcs_h3`. Other columns are left unchanged.
#'
#' @param data A data frame (tibble, data frame or `sf`).
#' @param entry A catalog entry: `kind`, `index_of` and `columns` (JSON) are
#'   used; missing fields are treated as `NA`.
#' @return `data` with the same class.
#' @noRd
h3_classify <- function(data, entry) {
  names_data <- names(data)
  chosen <- character()
  kind <- entry[["kind"]] %||% NA_character_
  index_of <- entry[["index_of"]] %||% NA_character_
  cells_by_name <- isTRUE(kind == "geospatial") ||
    (length(index_of) == 1 && !is.na(index_of))
  if (cells_by_name) {
    chosen <- names_data[names_data %in% c("h3", "h3_main") | grepl("^h3_p[0-9]+$", names_data)]
  }
  json <- entry[["columns"]]
  if (is.character(json) && length(json) == 1 && !is.na(json) && nzchar(json)) {
    spec <- columns_from_json(json)
    recorded <- vapply(spec$r_type, function(r) identical(r$class, "rcs_h3"), logical(1))
    chosen <- union(chosen, intersect(spec$name[recorded], names_data))
  }
  for (name in chosen) {
    v <- data[[name]]
    if (inherits(v, "integer64") && !inherits(v, "rcs_h3")) {
      data[[name]] <- new_rcs_h3(v)
    }
  }
  data
}

# Base methods ---------------------------------------------------------------------

#' @export
format.rcs_h3 <- function(x, ...) {
  out <- rcs_h3_format_hex(x)
  out[is.na(out)] <- "NA"
  names(out) <- names(x)
  out
}

#' @export
print.rcs_h3 <- function(x, ...) {
  cat("<rcs_h3[", length(x), "]>\n", sep = "")
  if (length(x) > 0) {
    print(format(x), quote = FALSE)
  }
  invisible(x)
}

#' @export
`[.rcs_h3` <- function(x, ...) {
  new_rcs_h3(NextMethod())
}

#' @export
`[[.rcs_h3` <- function(x, ...) {
  new_rcs_h3(NextMethod())
}

#' @export
`[<-.rcs_h3` <- function(x, ..., value) {
  if (inherits(value, "rcs_h3")) {
    value <- rcs_h3_strip(value)
  }
  new_rcs_h3(NextMethod())
}

#' @export
c.rcs_h3 <- function(...) {
  new_rcs_h3(NextMethod())
}

#' @export
rep.rcs_h3 <- function(x, ...) {
  new_rcs_h3(NextMethod())
}

#' @export
unique.rcs_h3 <- function(x, incomparables = FALSE, ...) {
  new_rcs_h3(NextMethod())
}

#' @export
sort.rcs_h3 <- function(x, decreasing = FALSE, ...) {
  new_rcs_h3(NextMethod())
}

#' @export
rev.rcs_h3 <- function(x) {
  x[rev(seq_along(x))]
}

# pillar ---------------------------------------------------------------------------

#' @exportS3Method pillar::pillar_shaft
pillar_shaft.rcs_h3 <- function(x, ...) {
  out <- rcs_h3_format_hex(x)
  pillar::new_pillar_shaft_simple(out, align = "left", na = pillar::style_na("NA"))
}

#' @exportS3Method pillar::type_sum
type_sum.rcs_h3 <- function(x) {
  "h3"
}

# vctrs ----------------------------------------------------------------------------

# The proxy is the bare double vector that holds the 64 bits; equality and
# order keep the integer64 proxies of vctrs (`vec_proxy_equal()` dispatches to
# the integer64 method by inheritance).

#' @exportS3Method vctrs::vec_proxy
vec_proxy.rcs_h3 <- function(x, ...) {
  unclass(x)
}

#' @exportS3Method vctrs::vec_restore
vec_restore.rcs_h3 <- function(x, to, ...) {
  class(x) <- c("rcs_h3", "integer64")
  x
}

#' @exportS3Method vctrs::vec_ptype2
vec_ptype2.rcs_h3.rcs_h3 <- function(x, y, ...) {
  new_rcs_h3()
}

#' @exportS3Method vctrs::vec_ptype2
vec_ptype2.rcs_h3.integer64 <- function(x, y, ...) {
  new_rcs_h3()
}

#' @exportS3Method vctrs::vec_ptype2
vec_ptype2.integer64.rcs_h3 <- function(x, y, ...) {
  new_rcs_h3()
}

#' @exportS3Method vctrs::vec_cast
vec_cast.rcs_h3.rcs_h3 <- function(x, to, ...) {
  x
}

#' @exportS3Method vctrs::vec_cast
vec_cast.rcs_h3.integer64 <- function(x, to, ...) {
  new_rcs_h3(x)
}

#' @exportS3Method vctrs::vec_cast
vec_cast.integer64.rcs_h3 <- function(x, to, ...) {
  rcs_h3_strip(x)
}
