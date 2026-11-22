# Credentials for Google Cloud Storage: `rcs_auth_gcs()`, the access tokens it
# hands out (`auth_token()`) and the Arrow file system built from them
# (`auth_arrow_fs()`).
#
# One credential object per source (a key file found by the default lookup,
# a key file given, a token, a function, or ambient credentials), kept in
# `the_auth$objects`: asking for the same source again gives the identical
# object, so its token and clients are shared. Tokens, refresh tokens, client
# secrets and token functions live only in the object's environment `cache`;
# they are never logged, written to files or catalogs, or put in environment
# variables.
#
# Calls that cannot be mocked directly (the clock, HTTP, Arrow's R6
# constructor) go through the seams `auth_now()`, `auth_http_token()`,
# `auth_tokeninfo()` and `auth_arrow_fs_create()`.

the_auth <- new.env(parent = emptyenv())
the_auth$objects <- list()

auth_renew_margin <- 5 * 60
auth_default_life <- 3600
auth_file_types <- c("service_account", "authorized_user")
auth_adc_name <- "application_default_credentials.json"

#' Credentials for Google Cloud Storage
#'
#' Describes how the package reaches Google Cloud Storage. Pass the result
#' (or a key file path) to the `auth` argument of [store_connect()] or
#' [store_create()]; without `auth`, every Google Cloud Storage location uses
#' `rcs_auth_gcs()`, the default lookup.
#'
#' Give at most one of `key`, `token` and `fun`. With none, the default lookup
#' takes the first of:
#'
#' 1. the file named by the environment variable
#'    `GOOGLE_APPLICATION_CREDENTIALS`;
#' 2. `application_default_credentials.json` in the folder named by
#'    `CLOUDSDK_CONFIG`, when that variable is set;
#' 3. the same file in gcloud's folder (`%APPDATA%/gcloud` on Windows,
#'    `~/.config/gcloud` elsewhere), written once by
#'    `gcloud auth application-default login`;
#' 4. ambient credentials, when no file exists: Arrow and the JSON API then
#'    use Google's own defaults (on Google Cloud, the metadata server).
#'
#' Access tokens of a key file or a function are renewed five minutes before
#' they expire, so a long session never signs in again. A token given with
#' `token` cannot be renewed: it lasts as long as its issuer allows (usually
#' one hour).
#'
#' Asking for the same source again returns the same object, with its token.
#' Printing the object never contacts the network and never shows a secret;
#' the identity (the account's e-mail) is known after the first token.
#'
#' @param key Path to a JSON key file of type `"service_account"` or
#'   `"authorized_user"` (such as the file written by
#'   `gcloud auth application-default login`).
#' @param token An OAuth access token with the scope `cloud-platform`. Not
#'   renewed.
#' @param fun A function of no arguments returning an access token, or a list
#'   with `access_token` and `expires_in` (seconds). Called again when the
#'   token it gave is about to expire.
#' @return An object of class `rcs_auth_gcs`: a list with `source`, `type`
#'   (the key file's type, or `NA`), `file` (or `NA`) and the environment
#'   `cache`. Aborts with class `rcs_error_argument` for invalid arguments and
#'   with `rcs_error_backend` for a missing or unusable key file.
#' @seealso [store_connect()], [store_create()].
#' @export
#' @examples
#' # The default lookup; nothing is contacted until data is read.
#' rcs_auth_gcs()
#'
#' # A token obtained elsewhere (here a placeholder)
#' auth <- rcs_auth_gcs(token = "<access token>")
#' auth
rcs_auth_gcs <- function(key = NULL, token = NULL, fun = NULL) {
  given <- c(key = !is.null(key), token = !is.null(token), fun = !is.null(fun))
  if (sum(given) > 1) {
    cli::cli_abort(
      "Give at most one of {.arg key}, {.arg token} and {.arg fun}, not {.and {.arg {names(given)[given]}}}.",
      class = "rcs_error_argument"
    )
  }
  if (!is.null(key)) {
    check_string(key)
    return(auth_from_file(key, "key"))
  }
  if (!is.null(token)) {
    check_string(token)
    return(auth_object(
      paste0("token:", md5_string(token)), "token",
      init = function(cache) cache$given_token <- token
    ))
  }
  if (!is.null(fun)) {
    if (!is.function(fun)) {
      cli::cli_abort(
        "{.arg fun} must be a function of no arguments, not {.obj_type_friendly {fun}}.",
        class = "rcs_error_argument"
      )
    }
    return(auth_object(
      paste0("function:", rlang::hash(fun)), "function",
      init = function(cache) cache$fun <- fun
    ))
  }
  auth_default()
}

#' @export
print.rcs_auth_gcs <- function(x, ...) {
  cache <- x$cache
  lines <- c(
    "<rcs_auth_gcs>",
    paste0("Source:   ", auth_source_label(x)),
    if (!is.na(x$type)) paste0("Type:     ", x$type),
    if (!is.na(x$file)) paste0("File:     ", x$file),
    paste0("Identity: ", auth_identity_label(cache)),
    paste0("Token:    ", auth_validity_label(x))
  )
  cli::cat_line(lines)
  invisible(x)
}

# Building the object ---------------------------------------------------------

# The registered object of `id`, made by `init()` the first time.
auth_object <- function(id, source, type = NA_character_, file = NA_character_,
                        init = function(cache) NULL) {
  found <- the_auth$objects[[id]]
  if (!is.null(found)) {
    return(found)
  }
  cache <- new.env(parent = emptyenv())
  cache$id <- id
  init(cache)
  auth <- structure(
    list(source = source, type = type, file = file, cache = cache),
    class = "rcs_auth_gcs"
  )
  the_auth$objects[[id]] <- auth
  auth
}

auth_default <- function(call = caller_env()) {
  gac <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
  if (nzchar(gac)) {
    if (!file.exists(gac)) {
      cli::cli_abort(
        c(
          "{.envvar GOOGLE_APPLICATION_CREDENTIALS} names a file that does not exist: {.path {gac}}.",
          i = "Point it at a key file, unset it, or pass credentials to {.arg auth}."
        ),
        class = "rcs_error_backend", call = call
      )
    }
    return(auth_from_file(gac, "GOOGLE_APPLICATION_CREDENTIALS", call = call))
  }
  cfg <- Sys.getenv("CLOUDSDK_CONFIG", "")
  if (nzchar(cfg)) {
    file <- file.path(cfg, auth_adc_name)
    source <- "CLOUDSDK_CONFIG"
  } else {
    file <- auth_gcloud_file()
    source <- "gcloud"
  }
  if (file.exists(file)) {
    return(auth_from_file(file, source, call = call))
  }
  auth_object("ambient", "ambient")
}

auth_gcloud_file <- function() {
  base <- if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("APPDATA"), "gcloud")
  } else {
    file.path(path.expand("~"), ".config", "gcloud")
  }
  file.path(base, auth_adc_name)
}

auth_from_file <- function(path, source, call = caller_env()) {
  if (!file.exists(path) || dir.exists(path)) {
    shown <- normalizePath(path, winslash = "/", mustWork = FALSE)
    cli::cli_abort(
      "No credential file at {.path {shown}}.",
      class = "rcs_error_backend", call = call
    )
  }
  file <- normalizePath(path, winslash = "/")
  id <- paste0(source, ":", file)
  found <- the_auth$objects[[id]]
  if (!is.null(found)) {
    return(found)
  }
  type <- auth_file_type(file, call)
  auth_object(id, source, type = type, file = file)
}

auth_file_type <- function(file, call) {
  info <- tryCatch(jsonlite::read_json(file), error = function(e) NULL)
  if (!is.list(info)) {
    cli::cli_abort(
      "{.path {file}} is not a JSON credential file.",
      class = "rcs_error_backend", call = call
    )
  }
  type <- info$type
  if (!rlang::is_string(type) || !type %in% auth_file_types) {
    shown <- if (rlang::is_string(type)) type else "none"
    cli::cli_abort(
      c(
        "{.path {file}} holds credentials of type {.val {shown}}.",
        i = "Use a key file of type {.or {.val {auth_file_types}}}, a token or a function."
      ),
      class = "rcs_error_backend", call = call
    )
  }
  type
}

# Tokens ----------------------------------------------------------------------

#' Access token of a credential
#'
#' Returns the cached token while it is valid for more than five minutes,
#' else fetches a new one (key files, functions, ambient credentials). A
#' token given by the caller is returned as it is. The first token also fills
#' the identity shown by `print()` (`auth_tokeninfo()`).
#'
#' @param auth An `rcs_auth_gcs` object.
#' @return The access token, one string. Aborts with class
#'   `rcs_error_backend` when no token can be obtained.
#' @noRd
auth_token <- function(auth) {
  cache <- auth$cache
  if (!is.null(cache$token) && auth_fresh(auth)) {
    return(cache$token)
  }
  got <- auth_fetch(auth)
  cache$token <- got$access_token
  cache$expires <- auth_now() + got$expires_in
  if (is.null(cache$identity)) {
    cache$identity <- auth_tokeninfo(cache$token)
  }
  cache$token
}

auth_fresh <- function(auth) {
  if (identical(auth$source, "token")) {
    return(TRUE)
  }
  expires <- auth$cache$expires
  !is.null(expires) &&
    as.numeric(difftime(expires, auth_now(), units = "secs")) > auth_renew_margin
}

# A new token: list(access_token, expires_in).
auth_fetch <- function(auth, call = caller_env()) {
  cache <- auth$cache
  if (identical(auth$source, "token")) {
    return(list(access_token = cache$given_token, expires_in = auth_default_life))
  }
  got <- tryCatch(
    switch(auth_kind(auth),
      "function" = auth_fetch_function(cache$fun),
      ambient = auth_fetch_ambient(),
      authorized_user = auth_fetch_user(auth),
      service_account = auth_fetch_service_account(auth)
    ),
    error = function(e) {
      cli::cli_abort(
        "Getting an access token from {auth_source_label(auth)} failed.",
        class = "rcs_error_backend", parent = e, call = call
      )
    }
  )
  if (!auth_token_valid(got)) {
    what <- if (identical(auth$source, "function")) {
      "The function given to {.code rcs_auth_gcs(fun = )} must return a token (one string) or a list with {.field access_token} and {.field expires_in}."
    } else {
      "No credentials found: {auth_source_label(auth)} gave no access token."
    }
    cli::cli_abort(what, class = "rcs_error_backend", call = call)
  }
  got$expires_in <- as.numeric(got$expires_in %||% auth_default_life)
  got
}

auth_kind <- function(auth) {
  switch(auth$source,
    "function" = "function",
    ambient = "ambient",
    auth$type
  )
}

auth_token_valid <- function(got) {
  is.list(got) && rlang::is_string(got$access_token) && nzchar(got$access_token) &&
    (is.null(got$expires_in) || (is.numeric(got$expires_in) && length(got$expires_in) == 1))
}

auth_fetch_function <- function(fun) {
  out <- fun()
  if (rlang::is_string(out)) {
    return(list(access_token = out, expires_in = auth_default_life))
  }
  if (is.list(out)) out else NULL
}

auth_fetch_ambient <- function() {
  rlang::check_installed("gargle", "to get credentials from Google's application default.")
  token <- gargle::credentials_app_default(scopes = gcs_scope)
  if (is.null(token)) {
    return(NULL)
  }
  list(
    access_token = token$credentials$access_token,
    expires_in = token$credentials$expires_in
  )
}

auth_fetch_service_account <- function(auth) {
  rlang::check_installed("gargle", "to use a service-account key.")
  token <- gargle::credentials_service_account(scopes = gcs_scope, path = auth$file)
  if (is.null(token)) {
    return(NULL)
  }
  list(
    access_token = token$credentials$access_token,
    expires_in = token$credentials$expires_in
  )
}

# A user login (`authorized_user`): its refresh token, read once into the
# cache, is exchanged for an access token.
auth_fetch_user <- function(auth) {
  cache <- auth$cache
  if (is.null(cache$refresh_token)) {
    info <- jsonlite::read_json(auth$file)
    cache$refresh_token <- info$refresh_token
    cache$client_id <- info$client_id
    cache$client_secret <- info$client_secret
  }
  auth_http_token(list(
    grant_type = "refresh_token",
    refresh_token = cache$refresh_token,
    client_id = cache$client_id,
    client_secret = cache$client_secret
  ))
}

# Seams -------------------------------------------------------------------------

#' Seams of the credential code
#'
#' `auth_now()` is the clock; `auth_http_token(body)` posts the form `body` to
#' Google's token endpoint and returns the parsed answer
#' (`access_token`, `expires_in`); `auth_tokeninfo(token)` returns the e-mail
#' of the account behind a token, or `NA` (never an error);
#' `auth_arrow_fs_create(token, expiration)` builds Arrow's `GcsFileSystem`
#' (Google's defaults when `token` is `NULL`). Tests mock them.
#' @noRd
auth_now <- function() {
  Sys.time()
}

auth_http_token <- function(body) {
  rlang::check_installed("httr2", "to renew Google access tokens.")
  req <- httr2::request("https://oauth2.googleapis.com/token")
  req <- httr2::req_body_form(req, !!!body)
  httr2::resp_body_json(httr2::req_perform(req))
}

auth_tokeninfo <- function(token) {
  if (!rlang::is_installed("httr2")) {
    return(NA_character_)
  }
  tryCatch(
    {
      req <- httr2::request("https://oauth2.googleapis.com/tokeninfo")
      req <- httr2::req_url_query(req, access_token = token)
      email <- httr2::resp_body_json(httr2::req_perform(req))$email
      if (rlang::is_string(email)) email else NA_character_
    },
    error = function(e) NA_character_
  )
}

auth_arrow_fs_create <- function(token, expiration) {
  if (is.null(token)) {
    return(arrow::GcsFileSystem$create())
  }
  arrow::GcsFileSystem$create(access_token = token, expiration = expiration)
}

# Clients -----------------------------------------------------------------------

#' Arrow file system of a credential
#'
#' Built through `auth_arrow_fs_create()` with the credential's current token
#' and rebuilt when the token changes; ambient credentials use Arrow's
#' defaults, built once. Cached in the credential's `cache`.
#'
#' @param auth An `rcs_auth_gcs` object.
#' @return A `GcsFileSystem`.
#' @noRd
auth_arrow_fs <- function(auth) {
  cache <- auth$cache
  if (identical(auth$source, "ambient")) {
    if (is.null(cache$fs)) {
      cache$fs <- auth_arrow_fs_create(NULL, NULL)
    }
    return(cache$fs)
  }
  token <- auth_token(auth)
  if (is.null(cache$fs) || !identical(cache$fs_token, token)) {
    cache$fs <- auth_arrow_fs_create(token, cache$expires)
    cache$fs_token <- token
  }
  cache$fs
}

# Clear the tokens and clients of every credential (the secrets they need to
# get new ones stay).
auth_reset <- function() {
  for (auth in the_auth$objects) {
    cache <- auth$cache
    rm(list = intersect(c("token", "expires", "fs", "fs_token"), ls(cache)), envir = cache)
  }
  invisible()
}

# The credential of `auth =` for one GCS location: `NULL` (default lookup),
# an `rcs_auth_gcs` object, or a key file path.
auth_resolve <- function(auth, arg = "auth", call = caller_env()) {
  if (is.null(auth)) {
    return(rcs_auth_gcs())
  }
  if (inherits(auth, "rcs_auth_gcs")) {
    return(auth)
  }
  if (rlang::is_string(auth) && !is.na(auth) && nzchar(auth)) {
    return(auth_from_file(auth, "key", call = call))
  }
  cli::cli_abort(
    "{.arg {arg}} must be {.code NULL}, an object made by {.fn rcs_auth_gcs} or the path of a key file, not {.obj_type_friendly {auth}}.",
    class = "rcs_error_argument", call = call
  )
}

# Text ------------------------------------------------------------------------

auth_source_label <- function(auth) {
  switch(auth$source,
    GOOGLE_APPLICATION_CREDENTIALS = "the key file named by GOOGLE_APPLICATION_CREDENTIALS (default lookup)",
    CLOUDSDK_CONFIG = "the application-default login in CLOUDSDK_CONFIG (default lookup)",
    gcloud = "the application-default login of gcloud (default lookup)",
    ambient = "ambient credentials (default lookup, no credential file found)",
    key = "a key file",
    token = "an access token given to rcs_auth_gcs(token = )",
    "function" = "a function given to rcs_auth_gcs(fun = )"
  )
}

# One line naming the credential in use, for messages (plain text).
auth_describe <- function(auth) {
  label <- auth_source_label(auth)
  if (!is.na(auth$file)) {
    label <- paste0(label, ", ", auth$file, " (", auth$type, ")")
  }
  if (identical(auth$source, "token")) {
    label <- paste0(label, ", not renewed")
  }
  label
}

auth_identity_label <- function(cache) {
  identity <- cache$identity
  if (is.null(identity)) {
    return("known after the first token")
  }
  if (is.na(identity)) "unknown" else identity
}

auth_validity_label <- function(auth) {
  cache <- auth$cache
  if (identical(auth$source, "token")) {
    return("given by the caller, not renewed")
  }
  if (is.null(cache$token)) {
    return("none yet")
  }
  left <- as.numeric(difftime(cache$expires, auth_now(), units = "mins"))
  if (left <= auth_renew_margin / 60) {
    return("expired or about to expire, renewed at the next use")
  }
  paste0("valid for about ", floor(left), " min, renewed automatically")
}
