# Dataset names given by the user, and the location a read is served from.
# Both work from the catalogs held by the connection.

#' Resolve a dataset name given by the user
#'
#' Implemented by C; called by every function that takes `dataset` for an
#' existing dataset.
#'
#' @param st An `rcs_store`.
#' @param dataset One string: a full name, or the last segment of one when it
#'   is unique among the datasets of the primary catalog that are not index
#'   tables.
#' @param index `TRUE` lets the name of an index table (`...__h3`) resolve.
#' @param call Environment for the error.
#' @return The full name, one string, as it stands in the primary catalog.
#'   Aborts with class `rcs_error_dataset_not_found` for an unknown name and
#'   `rcs_error_dataset_ambiguous` for a short name shared by several
#'   datasets; both list the closest names (`agrep()`).
#' @noRd
resolve_dataset <- function(st, dataset, index = FALSE, call = caller_env()) {
  check_string(dataset, call = call)
  catalog <- st$primary$catalog
  is_index <- is_index_name(catalog$dataset) | !is.na(catalog$index_of)
  candidates <- if (isTRUE(index)) catalog$dataset else catalog$dataset[!is_index]
  if (dataset %in% candidates) {
    return(dataset)
  }
  short <- candidates[dataset_last_segment(candidates) == dataset]
  if (length(short) == 1) {
    return(short)
  }
  if (length(short) > 1) {
    cli::cli_abort(
      c(
        "The name {.val {dataset}} is ambiguous.",
        i = "It is the last part of {.val {short}}; use the full name."
      ),
      class = "rcs_error_dataset_ambiguous", call = call
    )
  }
  close <- closest_names(dataset, candidates)
  cli::cli_abort(
    c(
      "No dataset {.val {dataset}} in the store.",
      i = if (length(close) > 0) "Closest name{?s}: {.val {close}}.",
      i = if (length(close) == 0 && length(candidates) == 0) "The store holds no datasets."
    ),
    class = "rcs_error_dataset_not_found", call = call
  )
}

dataset_last_segment <- function(dataset) {
  sub("^.*/", "", dataset)
}

# Up to five names close to `name`, by full name or by last segment.
closest_names <- function(name, candidates, n = 5L) {
  if (length(candidates) == 0) {
    return(character())
  }
  hits <- unique(c(
    candidates[agrep(name, candidates, max.distance = 0.3)],
    candidates[agrep(name, dataset_last_segment(candidates), max.distance = 0.3)]
  ))
  utils::head(sort(hits, method = "radix"), n)
}

#' Choose the location a read is served from
#'
#' Among the available locations whose catalog holds the dataset at the
#' primary's version: local backends first, then the primary, then the other
#' secondaries in connection order. For an old `version`, a location is
#' eligible only if it still holds every file of that version. Uses the
#' catalogs held by the connection; makes no backend call for the current
#' version. Implemented by C; called by F.
#'
#' For an old version a location's file list comes from its own catalog
#' (when its current version is the one asked for) or from its
#' `_history.parquet`, and its files are checked with `be_exists()`;
#' locations are tried in the order above until one qualifies.
#'
#' @param st An `rcs_store`.
#' @param dataset Full dataset name, already resolved.
#' @param version `NULL` for the current version, or 16 hex characters.
#' @param call Environment for the error.
#' @return The chosen `rcs_location`. Informs
#'   `Reading "<dataset>" from secondary <uri>.` through `rcs_inform()` when
#'   it is not the primary. Aborts with class `rcs_error_dataset_not_found`
#'   when the primary catalog lacks the dataset, and with
#'   `rcs_error_version_not_found` when no location holds the version.
#' @noRd
choose_location <- function(st, dataset, version = NULL, call = caller_env()) {
  check_string(dataset, call = call)
  check_string(version, allow_null = TRUE, call = call)
  primary_entry <- st$primary$catalog[st$primary$catalog$dataset == dataset, ]
  if (nrow(primary_entry) == 0) {
    cli::cli_abort(
      "No dataset {.val {dataset}} in the primary catalog.",
      class = "rcs_error_dataset_not_found", call = call
    )
  }
  current <- primary_entry$version
  target <- version %||% current
  locations <- store_locations(st, available_only = TRUE)
  is_local <- vapply(locations, function(l) identical(l$backend$type, "local"), logical(1))
  is_primary <- seq_along(locations) == 1L
  order <- c(which(is_local), which(!is_local & is_primary), which(!is_local & !is_primary))

  holds_current <- function(location) {
    v <- location$catalog$version[location$catalog$dataset == dataset]
    length(v) == 1 && identical(v, target)
  }
  holds_old <- function(location) {
    if (holds_current(location)) {
      return(TRUE)
    }
    rows <- history_version_rows(history_read(location$backend), dataset, target)
    nrow(rows) > 0 && all(be_exists(location$backend, rows$path))
  }
  eligible <- if (identical(target, current)) holds_current else holds_old

  for (i in order) {
    if (eligible(locations[[i]])) {
      chosen <- locations[[i]]
      if (!is_primary[[i]]) {
        uri <- chosen$uri
        rcs_inform(c(i = "Reading {.val {dataset}} from secondary {uri}."))
      }
      return(chosen)
    }
  }
  cli::cli_abort(
    c(
      "No available location holds version {.val {target}} of {.val {dataset}}.",
      i = if (!identical(target, current)) "Its files may have been pruned; {.fn store_history} lists the versions kept."
    ),
    class = "rcs_error_version_not_found", call = call
  )
}
