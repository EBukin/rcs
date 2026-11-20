# Work counters. With `options(rcs.trace = TRUE)` the package records what an
# exported function did; tests assert the counts. Internal contract:
#
#   * every exported function that touches a store starts with
#     `local_trace("<its name>")`;
#   * code that does countable work calls `trace_count()`;
#   * backend generics count themselves (see `R/backend.R`).

the_trace <- new.env(parent = emptyenv())
the_trace$depth <- 0L
the_trace$call <- NA_character_
the_trace$records <- list()

trace_counters <- c(
  "backend_call",       # one backend generic called; detail = generic
  "catalog_read",       # one catalog file read; detail = file name
  "file_open",          # one data file opened; detail = path
  "row_groups_total",   # row groups in the opened data files
  "row_groups_overlap", # of those, groups whose statistics overlap the filter
  "rows_candidate",     # rows before the exact spatial test
  "rows_returned",      # rows handed to the user
  "bytes_up",           # bytes uploaded
  "bytes_down"          # bytes downloaded
)

trace_on <- function() {
  isTRUE(getOption("rcs.trace"))
}

#' Mark the start of an exported function for the work counters
#'
#' The outermost call clears the records of the previous one and gives its
#' name to every record made until it returns; calls nested inside it
#' (an exported function calling another) add to the same records. Does
#' nothing when `rcs.trace` is off.
#'
#' @param fn Name of the exported function, e.g. `"store_read"`.
#' @param frame The frame of that function; the trace ends when it exits.
#' @return `NULL`, invisibly.
#' @noRd
local_trace <- function(fn, frame = parent.frame()) {
  if (!trace_on()) {
    return(invisible())
  }
  if (the_trace$depth == 0L) {
    the_trace$records <- list()
    the_trace$call <- fn
  }
  the_trace$depth <- the_trace$depth + 1L
  withr::defer(
    {
      the_trace$depth <- max(the_trace$depth - 1L, 0L)
    },
    envir = frame
  )
  invisible()
}

#' Count work
#'
#' Costs one option lookup when `rcs.trace` is off. Work counted outside any
#' traced call is recorded with `call = NA` and kept until the next traced
#' call or [rcs_trace_reset()].
#'
#' @param counter One of `"backend_call"`, `"catalog_read"`, `"file_open"`,
#'   `"row_groups_total"`, `"row_groups_overlap"`, `"rows_candidate"`,
#'   `"rows_returned"`, `"bytes_up"`, `"bytes_down"`.
#' @param n How much to add: one number; `NA` and zero-length add nothing.
#' @param location Address of the location the work was done in
#'   (`location$uri`), or `NA`.
#' @param detail One string or `NA`: the generic for `backend_call`, the file
#'   name for `catalog_read`, the path for `file_open`.
#' @return `NULL`, invisibly. Aborts (internal error) on an unknown counter.
#' @noRd
trace_count <- function(counter, n = 1, location = NA_character_, detail = NA_character_) {
  if (!trace_on()) {
    return(invisible())
  }
  if (!counter %in% trace_counters) {
    cli::cli_abort("Unknown work counter {.val {counter}}.", .internal = TRUE)
  }
  n <- as.numeric(n)
  if (length(n) != 1 || is.na(n)) {
    return(invisible())
  }
  the_trace$records[[length(the_trace$records) + 1L]] <- list(
    counter = counter,
    detail = as.character(detail),
    location = as.character(location),
    n = n
  )
  invisible()
}

# Count one call of a backend generic.
trace_backend <- function(generic, be) {
  trace_count("backend_call", 1, location = be$uri, detail = generic)
}

#' Work counters of the last call
#'
#' With `options(rcs.trace = TRUE)` the package records the work done by each
#' call of one of its functions: backend calls, catalog files read, data files
#' opened, row groups, candidate and returned rows, and bytes transferred.
#' `rcs_trace()` returns the records of the last call; `rcs_trace_reset()`
#' clears them. Counting is deterministic and costs nothing when the option is
#' off.
#'
#' @return `rcs_trace()` returns a tibble with one row per counter, detail and
#'   location:
#'
#'   * `call`: the function that was called, `NA` for work done outside one;
#'   * `counter`: `backend_call`, `catalog_read`, `file_open`,
#'     `row_groups_total`, `row_groups_overlap`, `rows_candidate`,
#'     `rows_returned`, `bytes_up` or `bytes_down`;
#'   * `detail`: the backend operation, the catalog file or the data file;
#'   * `location`: the address of the location, `NA` when there is none;
#'   * `n`: the count.
#'
#'   It has zero rows when nothing was recorded. `rcs_trace_reset()` returns
#'   `NULL`, invisibly.
#' @export
#' @examples
#' withr::with_options(list(rcs.trace = TRUE), {
#'   rcs_trace_reset()
#'   rcs_trace()
#' })
rcs_trace <- function() {
  records <- the_trace$records
  out <- tibble::tibble(
    call = rep(the_trace$call, length(records)),
    counter = vapply(records, function(r) r$counter, character(1)),
    detail = vapply(records, function(r) r$detail, character(1)),
    location = vapply(records, function(r) r$location, character(1)),
    n = vapply(records, function(r) r$n, numeric(1))
  )
  if (nrow(out) == 0) {
    return(out)
  }
  groups <- vctrs::vec_group_loc(out[c("call", "counter", "detail", "location")])
  out <- groups$key
  out$n <- vapply(groups$loc, function(i) sum(records_n(records)[i]), numeric(1))
  out[order(match(out$counter, trace_counters), out$location, out$detail), ]
}

records_n <- function(records) {
  vapply(records, function(r) r$n, numeric(1))
}

#' @rdname rcs_trace
#' @export
rcs_trace_reset <- function() {
  the_trace$records <- list()
  the_trace$call <- NA_character_
  the_trace$depth <- 0L
  invisible()
}
