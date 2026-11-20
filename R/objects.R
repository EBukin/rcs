# Contracts of the three objects of the package: `rcs_location`, `rcs_store`
# (the connection) and `rcs_query` (a lazy query). Constructors, validators
# and the few accessors every work package uses. Print methods and the
# functions that fill the objects belong to later work packages.

# rcs_location ----------------------------------------------------------------

#' One location of a store
#'
#' A list of class `rcs_location`:
#'
#' | Field | Content |
#' |---|---|
#' | `uri` | the address as normalised by `be_new()` (`be$uri`) |
#' | `backend` | the backend object, class `rcs_backend`; `backend$type` is `"local"` or `"gcs"` |
#' | `catalog` | `_catalog.parquet` as read, in the in-memory form (see `R/schema.R`) |
#' | `files` | `_files.parquet` as read, in the in-memory form |
#' | `token` | MD5 (hex) of `_catalog.parquet` as read, the write guard's token; `NA` when unavailable |
#' | `available` | `FALSE` for a secondary that could not be reached |
#'
#' `_history.parquet` is never held in the object; it is read on demand. An
#' unavailable location has empty `catalog` and `files`.
#'
#' @param uri One string: a local folder or `gs://bucket[/prefix]`. Ignored
#'   when `backend` is given.
#' @param backend A backend object; default `be_new(uri)`.
#' @param catalog,files Tibbles in the in-memory form; default empty.
#' @param token One string or `NA`.
#' @param available `TRUE` or `FALSE`.
#' @param x Object to validate.
#' @param arg,call Used in the error message.
#' @return `new_location()`: the object, validated. `validate_location()`: `x`,
#'   invisibly; aborts with class `rcs_error_object` when `x` is not a
#'   well-formed `rcs_location`, and with `rcs_error_schema` when its catalog
#'   tables are invalid.
#' @noRd
new_location <- function(uri = NULL, backend = be_new(uri),
                         catalog = catalog_empty(), files = files_empty(),
                         token = NA_character_, available = TRUE) {
  validate_location(structure(
    list(
      uri = backend$uri,
      backend = backend,
      catalog = catalog,
      files = files,
      token = token,
      available = available
    ),
    class = "rcs_location"
  ))
}

location_fields <- c("uri", "backend", "catalog", "files", "token", "available")

#' @noRd
validate_location <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  ok <- inherits(x, "rcs_location") &&
    identical(names(x), location_fields) &&
    rlang::is_string(x$uri) &&
    inherits(x$backend, "rcs_backend") &&
    rlang::is_scalar_character(x$token) &&
    rlang::is_bool(x$available)
  if (!ok) {
    cli::cli_abort(
      "{.arg {arg}} must be a well-formed {.cls rcs_location}.",
      class = "rcs_error_object", call = call
    )
  }
  schema_validate(x$catalog, "catalog", call = call)
  schema_validate(x$files, "files", call = call)
  invisible(x)
}

# rcs_store -------------------------------------------------------------------

#' The connection object
#'
#' An environment of class `rcs_store`, so it has reference semantics: a
#' function that changes a location assigns into it and every holder of the
#' object sees the change. Nothing about it is saved anywhere.
#'
#' | Field | Content |
#' |---|---|
#' | `primary` | an `rcs_location`; always available |
#' | `secondary` | an unnamed list of `rcs_location`, in connection order; `list()` when none |
#' | `history` | the connection's history override: `TRUE`, `FALSE`, or `NULL` to use the store's default |
#' | `store_history` | the store's default, from `_store.json` of the primary; `FALSE` when the file is absent |
#' | `connected_at` | `POSIXct`, UTC; set again by `store_refresh()` |
#'
#' Read fields with `st$primary`; change a location only through
#' `store_set_location()`.
#'
#' @param primary An `rcs_location` with `available = TRUE`.
#' @param secondary A list of `rcs_location` with addresses that differ from
#'   each other and from the primary.
#' @param history `TRUE`, `FALSE` or `NULL`.
#' @param store_history `TRUE` or `FALSE`.
#' @param connected_at `POSIXct`.
#' @param x Object to validate.
#' @param arg,call Used in the error message.
#' @return `new_store()`: the object, validated. `validate_store()`: `x`,
#'   invisibly; aborts with class `rcs_error_object`. Exported functions call
#'   `validate_store(st)` first, so that a wrong first argument gives one
#'   clear message.
#' @noRd
new_store <- function(primary, secondary = list(), history = NULL,
                      store_history = FALSE, connected_at = now_utc()) {
  st <- structure(new.env(parent = emptyenv()), class = "rcs_store")
  st$primary <- primary
  st$secondary <- unname(secondary)
  st$history <- history
  st$store_history <- store_history
  st$connected_at <- connected_at
  validate_store(st)
}

#' @noRd
validate_store <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  fail <- function(problem) {
    cli::cli_abort(
      c("{.arg {arg}} must be a store connection made by {.fn store_connect}.", x = problem),
      class = "rcs_error_object", call = call
    )
  }
  if (!inherits(x, "rcs_store") || !is.environment(x)) {
    fail("It is {.obj_type_friendly {x}}.")
  }
  validate_location(x$primary, arg = "primary", call = call)
  if (!x$primary$available) {
    fail("Its primary location is not available.")
  }
  if (!rlang::is_bare_list(x$secondary)) {
    fail("{.field secondary} must be a list.")
  }
  for (location in x$secondary) {
    validate_location(location, arg = "secondary", call = call)
  }
  uris <- store_uris(x)
  if (anyDuplicated(uris) > 0) {
    fail("The location {.path {uris[duplicated(uris)][[1]]}} is named twice.")
  }
  if (!is.null(x$history) && !rlang::is_bool(x$history)) {
    fail("{.field history} must be {.code TRUE}, {.code FALSE} or {.code NULL}.")
  }
  if (!rlang::is_bool(x$store_history)) {
    fail("{.field store_history} must be {.code TRUE} or {.code FALSE}.")
  }
  if (!inherits(x$connected_at, "POSIXct")) {
    fail("{.field connected_at} must be a time.")
  }
  invisible(x)
}

#' The locations of a connection
#'
#' @param st An `rcs_store`.
#' @param available_only Drop locations with `available = FALSE`.
#' @return `store_locations()`: an unnamed list of `rcs_location`, the primary
#'   first, then the secondaries in connection order. `store_uris()`: their
#'   addresses, a character vector in the same order (all locations).
#' @noRd
store_locations <- function(st, available_only = FALSE) {
  locations <- c(list(st$primary), st$secondary)
  if (available_only) {
    locations <- locations[vapply(locations, function(l) l$available, logical(1))]
  }
  locations
}

#' @noRd
store_uris <- function(st) {
  vapply(c(list(st$primary), st$secondary), function(l) l$uri, character(1))
}

#' Replace one location of a connection, in place
#'
#' The one way to update the connection after catalogs were read or written.
#'
#' @param st An `rcs_store`.
#' @param location The new `rcs_location`; it replaces the location of `st`
#'   that has the same `uri`.
#' @return `st`, invisibly (the object itself is changed). Aborts with class
#'   `rcs_error_object` when no location of `st` has that address.
#' @noRd
store_set_location <- function(st, location) {
  validate_location(location)
  i <- match(location$uri, store_uris(st))
  if (is.na(i)) {
    cli::cli_abort(
      "{.path {location$uri}} is not a location of this connection.",
      class = "rcs_error_object"
    )
  }
  if (i == 1) {
    st$primary <- location
  } else {
    st$secondary[[i - 1]] <- location
  }
  invisible(st)
}

#' The history setting that applies to a write
#'
#' The dataset's setting if set, else the connection's if given, else the
#' store's.
#'
#' @param st An `rcs_store`.
#' @param dataset_history The `history` value of the dataset's entry after the
#'   `history` argument of the write was applied: `TRUE`, `FALSE` or `NA`.
#' @return `TRUE` or `FALSE`.
#' @noRd
effective_history <- function(st, dataset_history = NA) {
  if (!is.na(dataset_history)) {
    return(isTRUE(dataset_history))
  }
  st$history %||% st$store_history
}

# rcs_query -------------------------------------------------------------------

#' A lazy query on one dataset
#'
#' A list of class `rcs_query`, returned by `store_open()` and transformed by
#' the dplyr methods of work package F:
#'
#' | Field | Content |
#' |---|---|
#' | `store` | the `rcs_store` it came from |
#' | `entry` | the dataset's entry, a one-row tibble of `catalog_schema()`; for an old version, the entry of that version's manifest |
#' | `location` | the `rcs_location` the files are read from |
#' | `files` | the file rows of the version (`files_schema()`), after partition and spatial pruning |
#' | `query` | the Arrow object the dplyr verbs act on: an `arrow::Dataset` or an `arrow_dplyr_query` built from the explicit file list |
#' | `spatial` | `NULL`, or the state of a pending spatial filter (owned by `R/intersects.R`) |
#' | `geometry` | `FALSE` when the WKB column is dropped before collecting |
#'
#' @param store An `rcs_store`.
#' @param entry A one-row tibble of `catalog_schema()`.
#' @param location An `rcs_location`.
#' @param files A tibble of `files_schema()`.
#' @param query An Arrow `Dataset`, `Table` or `arrow_dplyr_query`.
#' @param spatial `NULL` or a list.
#' @param geometry `TRUE` or `FALSE`.
#' @param x Object to validate.
#' @param arg,call Used in the error message.
#' @return `new_query()`: the object, validated. `validate_query()`: `x`,
#'   invisibly; aborts with class `rcs_error_object`.
#' @noRd
new_query <- function(store, entry, location, files, query,
                      spatial = NULL, geometry = TRUE) {
  validate_query(structure(
    list(
      store = store,
      entry = entry,
      location = location,
      files = files,
      query = query,
      spatial = spatial,
      geometry = geometry
    ),
    class = "rcs_query"
  ))
}

query_fields <- c("store", "entry", "location", "files", "query", "spatial", "geometry")

#' @noRd
validate_query <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  ok <- inherits(x, "rcs_query") &&
    identical(names(x), query_fields) &&
    inherits(x$store, "rcs_store") &&
    inherits(x$location, "rcs_location") &&
    is.data.frame(x$entry) && nrow(x$entry) == 1 &&
    inherits(x$query, c("Dataset", "arrow_dplyr_query", "ArrowTabular")) &&
    (is.null(x$spatial) || is.list(x$spatial)) &&
    rlang::is_bool(x$geometry)
  if (!ok) {
    cli::cli_abort(
      "{.arg {arg}} must be a query made by {.fn store_open}.",
      class = "rcs_error_object", call = call
    )
  }
  schema_validate(x$entry, "catalog", call = call)
  schema_validate(x$files, "files", call = call)
  invisible(x)
}
