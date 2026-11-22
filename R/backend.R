# Contract of the backends: the object, `be_new()` and the generics. The
# methods are written by work package A (`R/backend-local.R`,
# `R/backend-gcs.R`); a later backend adds one file and one line in
# `backend_type()`.
#
# Rules that hold for every generic:
#   * `path` and `paths` are relative to the location root, with forward
#     slashes and no leading slash (`sales/daily/part-<version>.parquet`).
#   * A failure aborts with class `rcs_error_backend` and the bullets of
#     `be_auth_hint()` when the cause may be authentication. Retries are the
#     caller's business, not the method's.
#   * Every generic counts itself in the work counters before it dispatches
#     (`backend_call`, detail = the generic's name, location = `be$uri`), and
#     `be_put()` / `be_get()` count `bytes_up` / `bytes_down`. Methods do not
#     count again.
#   * A generic without a method for a class aborts with class
#     `rcs_error_not_implemented`.

#' Backend of an address
#'
#' @param uri One string.
#' @return `"gcs"` for `gs://...`, `"local"` for a path without a scheme.
#'   Any other `<scheme>://` aborts with class
#'   `rcs_error_unsupported_location` ("not supported yet").
#' @noRd
backend_type <- function(uri, call = caller_env()) {
  check_string(uri, call = call)
  if (!grepl("^[A-Za-z][A-Za-z0-9+.-]*://", uri)) {
    return("local")
  }
  scheme <- sub("://.*$", "", uri)
  switch(
    tolower(scheme),
    gs = "gcs",
    cli::cli_abort(
      c(
        "Locations of the form {.val {paste0(scheme, '://')}} are not supported yet.",
        i = "Use a local folder or {.val gs://bucket/prefix}."
      ),
      class = "rcs_error_unsupported_location", call = call
    )
  )
}

#' Create the backend object of a location
#'
#' Parses the address, builds the object and passes it to `be_init()`, which
#' lets a backend check its clients or add fields.
#'
#' The object is a list of class `c("rcs_backend_<type>", "rcs_backend")`:
#'
#' | Field | `local` | `gcs` |
#' |---|---|---|
#' | `type` | `"local"` | `"gcs"` |
#' | `uri` | absolute path, `~` expanded, forward slashes, no trailing slash | `gs://bucket[/prefix]`, no trailing slash |
#' | `root` | the same path | `bucket[/prefix]` |
#' | `bucket` | `NA` | the bucket |
#' | `prefix` | `NA` | the prefix without slashes at either end, `""` when none |
#' | `auth` | no field | the credential, an `rcs_auth_gcs` object |
#'
#' Two addresses name the same location exactly when their `uri` are equal.
#' Nothing is created or contacted by the parsing itself (the default
#' credential lookup only reads local files).
#'
#' @param uri One string: a local folder or `gs://bucket[/prefix]`.
#' @param auth Credential of a GCS location: `NULL` (the default lookup,
#'   `rcs_auth_gcs()`), an `rcs_auth_gcs` object or the path of a key file.
#'   Ignored for local folders.
#' @return The backend object. Aborts with class
#'   `rcs_error_unsupported_location` for any other scheme, and with
#'   `rcs_error_argument` for an empty address or a `gs://` address without a
#'   bucket or an invalid `auth`.
#' @noRd
be_new <- function(uri, auth = NULL) {
  type <- backend_type(uri)
  if (type == "local") {
    root <- sub("/+$", "", normalizePath(path.expand(uri), winslash = "/", mustWork = FALSE))
    fields <- list(type = type, uri = root, root = root, bucket = NA_character_, prefix = NA_character_)
  } else {
    root <- gsub("^/+|/+$", "", sub("^[A-Za-z]+://", "", uri))
    root <- gsub("/+", "/", root)
    bucket <- sub("/.*$", "", root)
    if (!nzchar(bucket)) {
      cli::cli_abort(
        "{.val {uri}} names no bucket.",
        class = "rcs_error_argument"
      )
    }
    prefix <- sub("^[^/]*/?", "", root)
    fields <- list(
      type = type, uri = paste0("gs://", root), root = root, bucket = bucket, prefix = prefix,
      auth = auth_resolve(auth)
    )
  }
  be_init(structure(fields, class = c(paste0("rcs_backend_", type), "rcs_backend")))
}

abort_no_method <- function(generic, be, call = caller_env()) {
  cli::cli_abort(
    "{.fn {generic}} is not implemented for {.cls {class(be)[[1]]}} yet.",
    class = "rcs_error_not_implemented", call = call
  )
}

#' Finish a backend object
#'
#' Called once by `be_new()`. A method may add fields (a client, a parsed
#' project) and checks the clients the session needs, aborting with the
#' first that fails and the bullets of `be_auth_hint()`. It must not create
#' the location and must not fail because the location does not exist yet.
#'
#' @param be A backend object.
#' @return The backend object. The default method returns `be` unchanged.
#' @noRd
be_init <- function(be) {
  UseMethod("be_init")
}

#' @export
be_init.default <- function(be) {
  be
}

#' Arrow file system of a location
#'
#' @param be A backend object.
#' @return A list with `fs` (an [arrow::FileSystem]) and `path` (the base
#'   path of the location inside it, no trailing slash). The file `p` of the
#'   location is `paste0(path, "/", p)` in `fs`.
#' @noRd
be_arrow_fs <- function(be) {
  trace_backend("be_arrow_fs", be)
  UseMethod("be_arrow_fs")
}

#' @export
be_arrow_fs.default <- function(be) {
  abort_no_method("be_arrow_fs", be)
}

#' Paths GDAL can open
#'
#' @param be A backend object.
#' @param path Character vector of relative paths.
#' @return Character vector of the same length: a local path, or
#'   `/vsigs/bucket/prefix/path`.
#' @noRd
be_gdal_path <- function(be, path) {
  trace_backend("be_gdal_path", be)
  UseMethod("be_gdal_path")
}

#' @export
be_gdal_path.default <- function(be, path) {
  abort_no_method("be_gdal_path", be)
}

#' Download one file
#'
#' @param be A backend object.
#' @param path One relative path.
#' @param dest Local path to write; its folder is created, an existing file
#'   is replaced.
#' @return `dest`, invisibly. Aborts with class `rcs_error_backend` when the
#'   file does not exist or cannot be read.
#' @noRd
be_get <- function(be, path, dest) {
  trace_backend("be_get", be)
  on.exit(trace_count("bytes_down", file.size(dest), location = be$uri))
  UseMethod("be_get")
}

#' @export
be_get.default <- function(be, path, dest) {
  abort_no_method("be_get", be)
}

#' Upload one local file
#'
#' Replaces an existing file. A reader never sees a partial file: `local`
#' writes under a temporary name in the target folder and renames. After the
#' call returns, `be_md5()` gives the file's MD5 without downloading it.
#'
#' @param be A backend object.
#' @param src One local file.
#' @param path One relative path; missing folders are created.
#' @return `path`, invisibly. Aborts with class `rcs_error_backend`.
#' @noRd
be_put <- function(be, src, path) {
  trace_backend("be_put", be)
  trace_count("bytes_up", file.size(src), location = be$uri)
  UseMethod("be_put")
}

#' @export
be_put.default <- function(be, src, path) {
  abort_no_method("be_put", be)
}

#' Delete files
#'
#' @param be A backend object.
#' @param paths Character vector of relative paths; a file that does not
#'   exist is skipped silently. Folders left empty are removed on `local`.
#' @return `paths`, invisibly. Aborts with class `rcs_error_backend` when an
#'   existing file cannot be deleted.
#' @noRd
be_delete <- function(be, paths) {
  trace_backend("be_delete", be)
  UseMethod("be_delete")
}

#' @export
be_delete.default <- function(be, paths) {
  abort_no_method("be_delete", be)
}

#' MD5 of stored files
#'
#' From backend metadata when available (`gcs`: `md5Hash`), else by hashing
#' (`local`: the file on disk).
#'
#' @param be A backend object.
#' @param paths Character vector of relative paths.
#' @return Character vector of the same length: 32 lower-case hex characters,
#'   `NA` for a file that does not exist.
#' @noRd
be_md5 <- function(be, paths) {
  trace_backend("be_md5", be)
  UseMethod("be_md5")
}

#' @export
be_md5.default <- function(be, paths) {
  abort_no_method("be_md5", be)
}

#' List the files of a location
#'
#' Used only by `store_prune()`, `store_rebuild()` and tests.
#'
#' @param be A backend object.
#' @param prefix One relative folder; `""` lists the whole location.
#' @return A tibble, one row per file below `prefix` (recursive, no
#'   folders), sorted by `path`: `path` (character, relative to the location
#'   root), `bytes` (double), `modified` (`POSIXct`, UTC). Zero rows when
#'   nothing is there, including when the location does not exist.
#' @noRd
be_list <- function(be, prefix = "") {
  trace_backend("be_list", be)
  UseMethod("be_list")
}

#' @export
be_list.default <- function(be, prefix = "") {
  abort_no_method("be_list", be)
}

#' Do files exist?
#'
#' @param be A backend object.
#' @param paths Character vector of relative paths.
#' @return Logical vector of the same length.
#' @noRd
be_exists <- function(be, paths) {
  trace_backend("be_exists", be)
  UseMethod("be_exists")
}

#' @export
be_exists.default <- function(be, paths) {
  abort_no_method("be_exists", be)
}

#' Text shown when access to a location fails
#'
#' Not counted in the work counters.
#'
#' @param be A backend object.
#' @return A named character vector of cli bullets (names `"i"`), one per
#'   client of the backend (Arrow, GDAL, API client), saying which
#'   credentials that client needs. Ready to append to the message of
#'   `cli::cli_abort()`.
#' @noRd
be_auth_hint <- function(be) {
  UseMethod("be_auth_hint")
}

#' @export
be_auth_hint.default <- function(be) {
  abort_no_method("be_auth_hint", be)
}

#' Take and release the write lock of a location
#'
#' `local`: `be_lock()` creates the folder `_lock` at the location root with
#' `dir.create()` and writes the current time into it; a lock older than
#' `timeout` seconds is taken over with a warning; a younger one aborts.
#' `be_unlock()` removes it and is safe to call when no lock is held.
#' The default methods do nothing, which is the behaviour of cloud backends.
#' The caller releases the lock with `on.exit()` or `withr::defer()`.
#'
#' @param be A backend object.
#' @param timeout Seconds after which a lock is stale.
#' @return `TRUE`, invisibly. `be_lock()` aborts with class `rcs_error_locked`
#'   when another writer holds a fresh lock.
#' @noRd
be_lock <- function(be, timeout = rcs_option("rcs.lock_timeout")) {
  trace_backend("be_lock", be)
  UseMethod("be_lock")
}

#' @export
be_lock.default <- function(be, timeout = rcs_option("rcs.lock_timeout")) {
  invisible(TRUE)
}

#' @noRd
be_unlock <- function(be) {
  trace_backend("be_unlock", be)
  UseMethod("be_unlock")
}

#' @export
be_unlock.default <- function(be) {
  invisible(TRUE)
}
