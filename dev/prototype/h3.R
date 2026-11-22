# Prototype: H3 cells stored as 64-bit integers, printed as hex.
#
#   * Class `rcs_h3` on top of `integer64`: the same bits Parquet stores and
#     filters, printed (console, tibble, sf) as the 15-character hex string
#     other H3 tools use. Arithmetic, sorting, joins and `==` are those of
#     `integer64`.
#   * `collect()` gives `h3`, `h3_main` and `h3_p<r>` this class.
#   * `rcs_h3_hex(x)`: any cell vector (integer64, rcs_h3, hex, h3o, or a
#     double that still holds the exact value) to hex strings. The same name
#     works inside a DuckDB query (`store_duckdb()` registers a macro), so
#     `mutate(cell = rcs_h3_hex(h3))` reads the same in both engines.
#
# DuckDB returns BIGINT as double by default, which cannot hold an H3 cell
# exactly (cells are above 2^53); `store_duckdb()` therefore connects with
# `bigint = "integer64"`.
#
# Load after `devtools::load_all()`: `source("dev/prototype/h3.R")`.

new_rcs_h3 <- function(x = bit64::integer64()) {
  x <- bit64::as.integer64(x)
  class(x) <- c("rcs_h3", "integer64")
  x
}

rcs_h3_hex <- function(x) {
  if (is.double(x) && !inherits(x, "integer64")) {
    if (any(abs(x) >= 2^53, na.rm = TRUE)) {
      cli::cli_warn(c(
        "{.arg x} is a double: cells above 2^53 may have lost their last bits.",
        i = "Read cells as {.cls integer64} (DuckDB: {.code dbConnect(duckdb(), bigint = \"integer64\")})."
      ))
    }
    x <- bit64::as.integer64(x)
  }
  if (inherits(x, "rcs_h3")) x <- structure(unclass(x), class = "integer64")
  h3_as_hex(x)
}

format.rcs_h3 <- function(x, ...) {
  out <- rcs_h3_hex(x)
  out[is.na(out)] <- "NA"
  out
}
print.rcs_h3 <- function(x, ...) {
  cat("<rcs_h3[", length(x), "]>\n", sep = "")
  if (length(x)) print(format(x), quote = FALSE)
  invisible(x)
}
as.character.rcs_h3 <- function(x, ...) rcs_h3_hex(x)
`[.rcs_h3` <- function(x, i, ...) new_rcs_h3(NextMethod())
pillar_shaft.rcs_h3 <- function(x, ...) pillar::new_pillar_shaft_simple(format(x), align = "left")
type_sum.rcs_h3 <- function(x) "h3"

for (m in c("format", "print", "as.character", "[")) {
  registerS3method(m, "rcs_h3", get(paste0(m, ".rcs_h3")))
}
registerS3method("pillar_shaft", "rcs_h3", pillar_shaft.rcs_h3, envir = asNamespace("pillar"))
registerS3method("type_sum", "rcs_h3", type_sum.rcs_h3, envir = asNamespace("pillar"))

proto_h3_classify <- function(df) {
  for (nm in names(df)[names(df) %in% c("h3", "h3_main") | grepl("^h3_p[0-9]+$", names(df))]) {
    if (inherits(df[[nm]], "integer64")) df[[nm]] <- new_rcs_h3(df[[nm]])
  }
  df
}

# collect() of an rcs_query: as the package, then cell columns classed.
proto_collect <- utils::getS3method("collect", "rcs_query", envir = asNamespace("dplyr"))
registerS3method("collect", "rcs_query", function(x, ...) proto_h3_classify(proto_collect(x, ...)),
                 envir = asNamespace("dplyr"))

# DuckDB side: same function name as a SQL macro (lower-case hex).
proto_duckdb_h3 <- function(con) {
  DBI::dbExecute(con, "CREATE OR REPLACE MACRO rcs_h3_hex(x) AS lower(printf('%x', x))")
  invisible(con)
}
