# Shared helpers: options, messages, argument checks, dataset names, paths,
# MD5, the version hash and timestamps. Internal; every work package may call
# them, none changes a signature without updating the plan.

# Options ---------------------------------------------------------------------

#' Read a package option
#'
#' The only place that knows the defaults; never call `getOption("rcs.*")`
#' with a default of your own.
#'
#' @param name One of `"rcs.quiet"`, `"rcs.trace"`, `"rcs.staging_dir"`,
#'   `"rcs.chunk_size"`, `"rcs.workers"`, `"rcs.lock_timeout"`,
#'   `"rcs.record_writer"`, `"rcs.print_rows"`, `"rcs.duckdb_batch_rows"`,
#'   `"rcs.s2_rebuild_tol"`.
#' @return The option's value, or its default when unset. Aborts (internal
#'   error) on an unknown name.
#' @noRd
rcs_option <- function(name) {
  default <- switch(
    name,
    rcs.quiet = FALSE,
    rcs.trace = FALSE,
    rcs.staging_dir = tempdir(),
    rcs.chunk_size = 1e4,
    rcs.workers = 1,
    rcs.lock_timeout = 600,
    rcs.record_writer = FALSE,
    rcs.print_rows = 10,
    rcs.duckdb_batch_rows = 5e5,
    rcs.s2_rebuild_tol = 1e-3,
    cli::cli_abort("Unknown option {.val {name}}.", .internal = TRUE)
  )
  getOption(name, default)
}

# Messages --------------------------------------------------------------------

#' Informative message that `options(rcs.quiet = TRUE)` silences
#'
#' Use for progress and "reading from secondary" lines. Warnings and errors
#' are never silenced: call `cli::cli_warn()` and `cli::cli_abort()` directly.
#'
#' @param message Passed to [cli::cli_inform()]; glue is evaluated in `.envir`.
#' @param ... Passed to [cli::cli_inform()].
#' @param .envir Environment for glue.
#' @return `NULL`, invisibly.
#' @noRd
rcs_inform <- function(message, ..., .envir = parent.frame()) {
  if (!isTRUE(rcs_option("rcs.quiet"))) {
    cli::cli_inform(message, ..., .envir = .envir)
  }
  invisible()
}

#' Abort because a function is a wave 0 stub
#'
#' @param what Name of the function, or of the generic and class.
#' @param package Letter of the work package that implements it.
#' @param call Environment of the stub.
#' @return Never returns. Condition class `rcs_error_not_implemented`.
#' @noRd
abort_not_implemented <- function(what, package = NULL, call = caller_env()) {
  cli::cli_abort(
    c(
      "{.fn {what}} is not implemented yet.",
      i = if (!is.null(package)) "It is part of work package {package}."
    ),
    class = "rcs_error_not_implemented",
    call = call
  )
}

# Argument checks -------------------------------------------------------------

#' Check that an argument is one non-missing, non-empty string
#' @param x Value. @param allow_null Accept `NULL`.
#' @param arg,call Used in the error message.
#' @return `x`, invisibly. Aborts with class `rcs_error_argument`.
#' @noRd
check_string <- function(x, allow_null = FALSE,
                         arg = rlang::caller_arg(x), call = caller_env()) {
  if (allow_null && is.null(x)) {
    return(invisible(x))
  }
  if (!rlang::is_string(x) || is.na(x) || !nzchar(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be a single non-empty string, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible(x)
}

#' Check that an argument is `TRUE` or `FALSE`
#' @param x Value. @param allow_null Accept `NULL`.
#' @param arg,call Used in the error message.
#' @return `x`, invisibly. Aborts with class `rcs_error_argument`.
#' @noRd
check_flag <- function(x, allow_null = FALSE,
                       arg = rlang::caller_arg(x), call = caller_env()) {
  if (allow_null && is.null(x)) {
    return(invisible(x))
  }
  if (!rlang::is_bool(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be {.code TRUE} or {.code FALSE}, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible(x)
}

# Dataset names ---------------------------------------------------------------

index_suffix <- "__h3"

#' Name of the index table of a dataset, and the reverse
#'
#' @param dataset Character vector of full dataset names.
#' @return `index_name()`: `paste0(dataset, "__h3")`. `is_index_name()`: a
#'   logical vector, `TRUE` where the name ends in `__h3`.
#'   `index_parent()`: the name without the suffix.
#' @noRd
index_name <- function(dataset) {
  paste0(dataset, index_suffix)
}

#' @noRd
is_index_name <- function(dataset) {
  endsWith(dataset, index_suffix)
}

#' @noRd
index_parent <- function(dataset) {
  sub(paste0(index_suffix, "$"), "", dataset)
}

#' Validate a dataset name
#'
#' A name matches `^[a-z0-9_]+(/[a-z0-9_]+)*$`, no path segment starts with
#' `_`, and it does not end in `__h3` (reserved for index tables).
#'
#' @param dataset The name to check.
#' @param allow_index `TRUE` when the package itself names an index table.
#' @param arg,call Used in the error message.
#' @return `dataset`, invisibly. Aborts with class `rcs_error_dataset_name`
#'   and a bullet saying which rule failed.
#' @noRd
check_dataset_name <- function(dataset, allow_index = FALSE,
                               arg = rlang::caller_arg(dataset),
                               call = caller_env()) {
  check_string(dataset, arg = arg, call = call)
  problem <- if (!grepl("^[a-z0-9_]+(/[a-z0-9_]+)*$", dataset, perl = TRUE)) {
    "Use lower-case letters, digits and {.code _}, with {.code /} between folders."
  } else if (any(startsWith(strsplit(dataset, "/", fixed = TRUE)[[1]], "_"))) {
    "No part of the name may start with {.code _}."
  } else if (!allow_index && is_index_name(dataset)) {
    "Names ending in {.code __h3} are reserved for index tables."
  }
  if (!is.null(problem)) {
    cli::cli_abort(
      c("{.arg {arg}} is not a valid dataset name: {.val {dataset}}.", x = problem),
      class = "rcs_error_dataset_name", call = call
    )
  }
  invisible(dataset)
}

# Paths inside a location -----------------------------------------------------

catalog_files <- c(
  catalog = "_catalog.parquet",
  files = "_files.parquet",
  history = "_history.parquet"
)
store_file <- "_store.json"
lock_dir <- "_lock"

# Exact doubles in JSON -------------------------------------------------------

# `jsonlite::toJSON(digits = NA)` writes 15 significant digits, which does not
# round-trip every double. `json_exact_doubles()` replaces each plain double
# vector inside a list (recursively, data frames excepted) by verbatim JSON in
# the shortest of 15, 16 or 17 significant digits that reads back to the same
# double; serialise the result with `json_verbatim = TRUE`. A double that
# round-trips with 15 digits is written exactly as `digits = NA` writes it, so
# such JSON does not change. A length-one vector without `I()` becomes a
# scalar, anything else an array; `NA`, `NaN` and infinite values become null.
json_exact_doubles <- function(x) {
  if (is.double(x) && (!is.object(x) || identical(class(x), "AsIs"))) {
    items <- vapply(x, json_double, character(1))
    if (length(x) == 1 && !inherits(x, "AsIs")) {
      return(structure(items, class = "json"))
    }
    return(structure(paste0("[", paste(items, collapse = ","), "]"), class = "json"))
  }
  if (is.list(x) && !is.data.frame(x)) {
    x[] <- lapply(x, json_exact_doubles)
  }
  x
}

json_double <- function(x) {
  if (!is.finite(x)) {
    return("null")
  }
  for (digits in 15:16) {
    out <- sprintf("%.*g", digits, x)
    if (as.numeric(out) == x) {
      return(out)
    }
  }
  sprintf("%.17g", x)
}

#' Canonical JSON of the partition values of one file
#'
#' The string stored in `_files.parquet$partition_values` and hashed into the
#' version, so it must be the same for the same values on every machine.
#'
#' @param values A named list (or one-row data frame) of scalar partition
#'   values, in the order of the `partition` columns; `NULL` or empty for a
#'   one-file dataset. Factors and dates are written as strings, `integer64`
#'   as strings (an int64 does not fit a JSON number), numbers with full
#'   precision. `NA` is written as `null`; it occurs only in an `h3_p<r>`
#'   partition, for the rows without a cell (empty geometries).
#' @return One string: a JSON object, `"{}"` when there are no values.
#' @noRd
partition_values_json <- function(values = NULL) {
  values <- as.list(values)
  if (length(values) == 0) {
    return("{}")
  }
  if (!rlang::is_named(values) || any(lengths(values) != 1)) {
    cli::cli_abort("{.arg values} must be a named list of scalars.", .internal = TRUE)
  }
  values <- lapply(values, function(v) {
    if (is.factor(v) || inherits(v, c("Date", "POSIXct", "integer64"))) as.character(v) else v
  })
  as.character(jsonlite::toJSON(
    json_exact_doubles(values),
    auto_unbox = TRUE, digits = NA, na = "null", json_verbatim = TRUE
  ))
}

#' Path of a data file, relative to the location root
#'
#' `<dataset>/part-<version>.<ext>` for a one-file dataset,
#' `<dataset>/<col>=<value>[/<col>=<value>]/part-<version>.<ext>` otherwise,
#' values URL-encoded, `NA` written as `null`. Paths are never parsed for
#' values.
#'
#' @param dataset Full dataset name (one string).
#' @param version The dataset version at which the file is created.
#' @param values Partition values as for `partition_values_json()`: a named
#'   list of scalars, or `NULL`.
#' @param ext File extension: `"parquet"` or `"tif"`.
#' @return One string with forward slashes.
#' @noRd
data_file_path <- function(dataset, version, values = NULL, ext = "parquet") {
  values <- as.list(values)
  parts <- if (length(values) > 0) {
    encoded <- vapply(
      values,
      function(v) if (is.na(v)) "null" else utils::URLencode(as.character(v), reserved = TRUE),
      character(1)
    )
    paste0(names(values), "=", encoded, collapse = "/")
  }
  paste(c(dataset, parts, paste0("part-", version, ".", ext)), collapse = "/")
}

#' Path of a manifest, relative to the location root
#' @param dataset,version Character vectors.
#' @return `<dataset>/_manifest-<version>.json`.
#' @noRd
manifest_path <- function(dataset, version) {
  paste0(dataset, "/_manifest-", version, ".json")
}

# MD5 and version -------------------------------------------------------------

#' MD5 of local files, as 32 lower-case hex characters
#' @param path Character vector of local paths.
#' @return Character vector of the same length; aborts when a file is missing.
#' @noRd
md5_file <- function(path) {
  missing <- !file.exists(path)
  if (any(missing)) {
    cli::cli_abort("Cannot hash missing file{?s} {.path {path[missing]}}.")
  }
  vapply(
    path,
    function(p) digest::digest(p, algo = "md5", file = TRUE),
    character(1), USE.NAMES = FALSE
  )
}

#' MD5 of one string (its UTF-8 bytes, no serialisation header)
#' @param x One string.
#' @return 32 lower-case hex characters.
#' @noRd
md5_string <- function(x) {
  digest::digest(enc2utf8(x), algo = "md5", serialize = FALSE)
}

#' Convert MD5 values between hex and base64
#'
#' Object stores report MD5 in base64 (`md5Hash`); catalogs hold hex.
#'
#' @param hex,base64 Character vectors; `NA` stays `NA`.
#' @return Character vector of the same length.
#' @noRd
md5_hex_to_base64 <- function(hex) {
  vapply(hex, function(h) {
    if (is.na(h)) {
      return(NA_character_)
    }
    bytes <- as.raw(strtoi(substring(h, seq(1, 31, 2), seq(2, 32, 2)), 16L))
    jsonlite::base64_enc(bytes)
  }, character(1), USE.NAMES = FALSE)
}

#' @noRd
md5_base64_to_hex <- function(base64) {
  vapply(base64, function(b) {
    if (is.na(b)) {
      return(NA_character_)
    }
    paste(as.character(jsonlite::base64_dec(b)), collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

#' Version of a dataset from its files
#'
#' The first 16 hex characters of the MD5 of the lines
#' `<partition_values>|<file md5>`, one per file, sorted in the C locale and
#' joined with `"\n"` (no trailing newline). File names are not hashed.
#'
#' @param partition_values Character vector, one canonical JSON string per
#'   file (`partition_values_json()`).
#' @param md5 Character vector of the files' MD5 (hex), same length.
#' @return One string of 16 hex characters. A dataset must have at least one
#'   file (a zero-row dataset has one file); zero files abort.
#' @noRd
version_hash <- function(partition_values, md5) {
  if (length(md5) == 0 || length(partition_values) != length(md5) || anyNA(md5)) {
    cli::cli_abort(
      "A version needs one MD5 and one {.field partition_values} per file.",
      .internal = TRUE
    )
  }
  lines <- sort(paste0(partition_values, "|", md5), method = "radix")
  substr(md5_string(paste(lines, collapse = "\n")), 1, 16)
}

# Timestamps ------------------------------------------------------------------

#' Current time in UTC, rounded to whole microseconds
#'
#' Every timestamp the package writes comes from here: Parquet stores
#' microseconds, so a value survives the catalog and the manifest unchanged.
#' @return `POSIXct` of length 1 with `tzone = "UTC"`.
#' @noRd
now_utc <- function() {
  secs <- round(as.numeric(Sys.time()) * 1e6) / 1e6
  as.POSIXct(secs, origin = "1970-01-01", tz = "UTC")
}

#' Timestamps to and from the text form used in JSON
#'
#' ISO 8601 in UTC with six decimals: `2026-01-31T12:00:00.000000Z`.
#'
#' @param x `POSIXct` vector (`time_to_text()`) or character vector
#'   (`time_from_text()`); `NA` stays `NA`.
#' @return Character vector, or `POSIXct` in UTC.
#' @noRd
time_to_text <- function(x) {
  secs <- as.numeric(x)
  micros <- round((secs - floor(secs)) * 1e6)
  whole <- floor(secs) + (micros >= 1e6)
  micros <- micros %% 1e6
  out <- sprintf(
    "%s.%06dZ",
    format(as.POSIXct(whole, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%dT%H:%M:%S"),
    as.integer(micros)
  )
  out[is.na(secs)] <- NA_character_
  out
}

#' @noRd
time_from_text <- function(x) {
  x <- as.character(x)
  whole <- as.POSIXct(substr(x, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  micros <- suppressWarnings(as.numeric(substr(x, 21, 26)))
  micros[is.na(micros)] <- 0
  as.POSIXct(as.numeric(whole) + micros / 1e6, origin = "1970-01-01", tz = "UTC")
}

# Formatting for messages -----------------------------------------------------

#' Format a number of bytes for messages, e.g. `"2.1 GB"`
#' @param bytes Numeric or `integer64` vector.
#' @return Character vector.
#' @noRd
format_bytes <- function(bytes) {
  bytes <- as.numeric(bytes)
  units <- c("B", "kB", "MB", "GB", "TB")
  power <- pmin(floor(log(pmax(bytes, 1), 1000)), length(units) - 1)
  value <- bytes / 1000^power
  out <- ifelse(
    power == 0,
    sprintf("%.0f %s", value, units[power + 1]),
    sprintf("%.1f %s", value, units[power + 1])
  )
  out[is.na(bytes)] <- NA_character_
  out
}

#' Format a count with thousands separators, e.g. `"5,012,334"`
#' @param n Numeric or `integer64` vector.
#' @return Character vector.
#' @noRd
format_count <- function(n) {
  out <- formatC(as.numeric(n), format = "f", digits = 0, big.mark = ",")
  out[is.na(n)] <- NA_character_
  out
}
