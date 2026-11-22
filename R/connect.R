# Connecting: `store_connect()`, `store_create()` and `store_refresh()`. They
# read the catalogs of every location (`_catalog.parquet`, then
# `_files.parquet`) and build or update the connection object (`rcs_store`,
# `R/objects.R`). After connecting, the inspection functions of `R/inspect.R`
# work from the catalogs held by the object and contact no backend.

#' Connect to a store
#'
#' Reads the catalogs of the primary location and of every secondary one and
#' returns the connection object. Nothing about the connection is saved: each
#' script, or the environment of the session, decides which locations it has.
#'
#' A location is a local folder or a Google Cloud Storage address of the form
#' `gs://bucket/prefix`. When `primary` is `NULL`, the addresses come from the
#' environment variables `<env>_PRIMARY` and `<env>_SECONDARY`; the second may
#' hold several addresses separated by `;`. `<env>_SECONDARY` is read only
#' when both `primary` and `secondary` are `NULL`, so that a primary given in
#' the call is never mixed with secondaries of another store.
#'
#' * A primary that cannot be reached aborts, with the credentials each
#'   client of its backend needs.
#' * A secondary that cannot be reached gives a warning and is marked
#'   unavailable: reads and writes skip it until [store_refresh()] finds it
#'   again.
#' * A location without catalogs aborts, unless `create = TRUE`, which
#'   initialises it with empty catalogs (as [store_create()] does, with the
#'   store's history default off).
#'
#' The object has reference semantics: functions that change a location
#' update it in place, so the same object serves several writes in a row.
#' Read functions use the catalogs held by the object; call [store_refresh()]
#' to see what other sessions wrote since.
#'
#' @param primary Address of the primary location, the source of truth. `NULL`
#'   reads it from the environment variable `<env>_PRIMARY`.
#' @param secondary Addresses of secondary locations, a character vector, in
#'   the order in which writes reach them. `NULL` reads them from
#'   `<env>_SECONDARY` when `primary` is `NULL` too, and means none otherwise.
#' @param env Prefix of the environment variables, `"STORE"` by default.
#' @param history Whether writes of this connection keep earlier versions:
#'   `TRUE` or `FALSE` override the store's default (set by
#'   [store_create()]); `NULL` uses it. A dataset's own setting, given to
#'   `store_write()`, overrides both.
#' @param create `TRUE` initialises locations that hold no catalogs yet.
#' @param auth Credentials for Google Cloud Storage locations (local
#'   folders need none): `NULL` uses [rcs_auth_gcs()], the default lookup;
#'   an object made by [rcs_auth_gcs()] applies to every GCS location; a
#'   string is the path of a key file; a list named by address (as given in
#'   the call) gives each location any of these, and locations left out use
#'   the default.
#' @return An object of class `rcs_store`. Print it to see its locations and
#'   datasets.
#' @seealso [store_create()], [store_refresh()], [store_datasets()],
#'   [store_status()], [rcs_auth_gcs()].
#' @export
#' @examples
#' primary <- file.path(tempdir(), "rcs-example-connect")
#' st <- store_connect(primary, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' st
#'
#' # The same, with the address in the environment
#' withr::with_envvar(c(STORE_PRIMARY = primary), store_connect())
#' unlink(primary, recursive = TRUE)
store_connect <- function(primary = NULL, secondary = NULL, env = "STORE",
                          history = NULL, create = FALSE, auth = NULL) {
  local_trace("store_connect")
  call <- rlang::current_env()
  check_string(env)
  check_flag(history, allow_null = TRUE)
  check_flag(create)
  check_string(primary, allow_null = TRUE)
  check_addresses(secondary)

  if (is.null(primary)) {
    vars <- paste0(env, c("_PRIMARY", "_SECONDARY"))
    primary <- Sys.getenv(vars[[1]], "")
    if (!nzchar(primary)) {
      cli::cli_abort(
        c(
          "No primary location given.",
          i = "Pass {.arg primary}, or set the environment variable {.envvar {vars[[1]]}} (and {.envvar {vars[[2]]}} for secondary locations, separated by {.code ;})."
        ),
        class = "rcs_error_argument", call = call
      )
    }
    if (is.null(secondary)) {
      secondary <- split_addresses(Sys.getenv(vars[[2]], ""))
    }
  }
  secondary <- secondary %||% character()

  auths <- auth_for_addresses(auth, c(primary, secondary), call)
  primary_be <- be_new(primary, auth = auths[[1]])
  secondary_be <- Map(be_new, secondary, auths[-1])
  names(secondary_be) <- NULL
  uris <- c(primary_be$uri, vapply(secondary_be, function(be) be$uri, character(1)))
  if (anyDuplicated(uris) > 0) {
    cli::cli_abort(
      "The location {.path {uris[duplicated(uris)][[1]]}} is named twice.",
      class = "rcs_error_argument", call = call
    )
  }

  primary_location <- connect_primary(primary_be, create, call)
  store_history <- reach(store_json_read(primary_be), primary_be, "primary", call)
  secondary_locations <- lapply(
    secondary_be,
    connect_secondary,
    create = create, store_history = store_history, call = call
  )
  new_store(
    primary = primary_location,
    secondary = secondary_locations,
    history = history,
    store_history = store_history
  )
}

#' Initialise an empty store
#'
#' Writes the store's settings (`_store.json`) and three empty catalog files
#' at the root of a location. Use it once for the first location of a new
#' store; connect to it with [store_connect()] afterwards. A location that
#' already holds catalogs is left unchanged and the call aborts.
#'
#' @param location Address of the location: a local folder (created when
#'   missing) or `gs://bucket/prefix`.
#' @param history The store's default for keeping earlier versions of
#'   datasets, `FALSE` unless switched on. A connection
#'   (`store_connect(history = )`) and a dataset (`store_write(history = )`)
#'   can override it.
#' @param auth Credentials when `location` is on Google Cloud Storage: `NULL`
#'   uses [rcs_auth_gcs()], the default lookup; else an object made by
#'   [rcs_auth_gcs()] or the path of a key file.
#' @return The normalised address of the location, invisibly.
#' @seealso [store_connect()].
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-create")
#' store_create(location, history = TRUE)
#' st <- store_connect(location)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' st
#' unlink(location, recursive = TRUE)
store_create <- function(location, history = FALSE, auth = NULL) {
  local_trace("store_create")
  call <- rlang::current_env()
  check_string(location)
  check_flag(history)
  be <- be_new(location, auth = auth_check_one(auth, "auth", call))
  uri <- be$uri
  if (reach(location_exists(be), be, "", call)) {
    cli::cli_abort(
      c(
        "{.path {uri}} already holds a store.",
        i = "Connect to it with {.fn store_connect}."
      ),
      class = "rcs_error_store_exists", call = call
    )
  }
  reach(location_init(be, history = history), be, "", call)
  rcs_inform(c(v = "Created an empty store in {.path {uri}}."))
  invisible(uri)
}

#' Re-read the catalogs of a connection
#'
#' Reads the catalogs of every location again, so that the connection sees
#' what other sessions wrote since it connected. A secondary that could not be
#' reached before is tried again; one that cannot be reached now gives a
#' warning and is marked unavailable. Write functions refresh the locations
#' they touch by themselves.
#'
#' @param st A store connection made by [store_connect()].
#' @return `st`, invisibly. The object is updated in place.
#' @seealso [store_connect()].
#' @export
#' @examples
#' primary <- file.path(tempdir(), "rcs-example-refresh")
#' st <- store_connect(primary, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_refresh(st)
#' unlink(primary, recursive = TRUE)
store_refresh <- function(st) {
  validate_store(st)
  local_trace("store_refresh")
  call <- rlang::current_env()
  be <- st$primary$backend
  fresh <- reach(location_read(be), be, "primary", call)
  store_history <- reach(store_json_read(be), be, "primary", call)
  store_set_location(st, fresh)
  for (location in st$secondary) {
    store_set_location(st, refresh_secondary(location$backend))
  }
  st$store_history <- store_history
  st$connected_at <- now_utc()
  invisible(st)
}

# Helpers ---------------------------------------------------------------------

check_addresses <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  if (is.null(x)) {
    return(invisible(x))
  }
  if (!is.character(x) || anyNA(x) || !all(nzchar(x))) {
    cli::cli_abort(
      "{.arg {arg}} must be a character vector of addresses without missing or empty values, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible(x)
}

# Credential of each address (`NULL` for the default), from `auth =` of
# `store_connect()`: one value for all, or a list named by address.
auth_for_addresses <- function(auth, addresses, call) {
  if (!is.list(auth) || inherits(auth, "rcs_auth_gcs")) {
    one <- auth_check_one(auth, "auth", call)
    return(rep(list(one), length(addresses)))
  }
  given <- names(auth)
  if (length(auth) > 0 && (is.null(given) || anyNA(given) || !all(nzchar(given)))) {
    cli::cli_abort(
      "A list given to {.arg auth} must be named by address.",
      class = "rcs_error_argument", call = call
    )
  }
  unknown <- setdiff(given, addresses)
  if (length(unknown) > 0) {
    cli::cli_abort(
      c(
        "{.arg auth} names {?an address/addresses} not given in the call: {.val {unknown}}.",
        i = "Name each credential by its address exactly as given to {.arg primary} or {.arg secondary}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  lapply(addresses, function(a) {
    auth_check_one(auth[[a]], paste0("auth[[\"", a, "\"]]"), call)
  })
}

auth_check_one <- function(auth, arg, call) {
  ok <- is.null(auth) || inherits(auth, "rcs_auth_gcs") ||
    (rlang::is_string(auth) && !is.na(auth) && nzchar(auth))
  if (!ok) {
    cli::cli_abort(
      "{.arg {arg}} must be {.code NULL}, an object made by {.fn rcs_auth_gcs} or the path of a key file, not {.obj_type_friendly {auth}}.",
      class = "rcs_error_argument", call = call
    )
  }
  auth
}

# Addresses of an environment variable: separated by `;`, blanks trimmed,
# empty parts dropped.
split_addresses <- function(text) {
  parts <- trimws(strsplit(text, ";", fixed = TRUE)[[1]])
  parts[nzchar(parts)]
}

# Evaluate `expr`; a backend failure aborts with the backend's credential
# hint. `role` is "primary", "secondary" or "" (a location being created).
reach <- function(expr, be, role, call = caller_env()) {
  tryCatch(expr, rcs_error_backend = function(e) abort_unreachable(be, role, e, call))
}

abort_unreachable <- function(be, role, parent, call) {
  uri <- be$uri
  what <- if (nzchar(role)) paste(role, "location") else "location"
  hint <- be_auth_hint(be)
  shown <- conditionMessage(parent)
  hint <- hint[!vapply(
    hint,
    function(h) grepl(cli::format_inline(h), shown, fixed = TRUE),
    logical(1)
  )]
  cli::cli_abort(
    c("Cannot reach the {what} {.path {uri}}.", hint),
    class = "rcs_error_backend", parent = parent, call = call
  )
}

abort_no_catalog <- function(be, role, call) {
  uri <- be$uri
  cli::cli_abort(
    c(
      "The {role} location {.path {uri}} holds no store catalogs.",
      i = "Initialise it with {.code store_create()} or connect with {.code create = TRUE}."
    ),
    class = "rcs_error_no_catalog", call = call
  )
}

connect_primary <- function(be, create, call) {
  if (!reach(location_exists(be), be, "primary", call)) {
    if (!create) {
      abort_no_catalog(be, "primary", call)
    }
    reach(location_init(be, history = FALSE), be, "primary", call)
  }
  reach(location_read(be), be, "primary", call)
}

connect_secondary <- function(be, create, store_history, call) {
  exists <- tryCatch(location_exists(be), rcs_error_backend = function(e) e)
  if (inherits(exists, "error")) {
    return(unavailable_location(be, exists))
  }
  if (!exists) {
    if (!create) {
      abort_no_catalog(be, "secondary", call)
    }
    init <- tryCatch(location_init(be, history = store_history), rcs_error_backend = function(e) e)
    if (inherits(init, "error")) {
      return(unavailable_location(be, init))
    }
  }
  read_secondary(be)
}

# A secondary read again by `store_refresh()`: unreachable or without
# catalogs, it becomes unavailable with a warning.
refresh_secondary <- function(be) {
  exists <- tryCatch(location_exists(be), rcs_error_backend = function(e) e)
  if (inherits(exists, "error")) {
    return(unavailable_location(be, exists))
  }
  if (!exists) {
    return(unavailable_location(be, NULL))
  }
  read_secondary(be)
}

read_secondary <- function(be) {
  location <- tryCatch(location_read(be), rcs_error_backend = function(e) e)
  if (inherits(location, "error")) {
    return(unavailable_location(be, location))
  }
  location
}

unavailable_location <- function(be, parent) {
  uri <- be$uri
  cli::cli_warn(
    c(
      "The secondary location {.path {uri}} is not available; it is skipped.",
      i = if (is.null(parent)) "It holds no store catalogs.",
      i = "Run {.fn store_refresh} to try it again."
    ),
    class = "rcs_warning_unavailable", parent = parent
  )
  new_location(backend = be, available = FALSE)
}
