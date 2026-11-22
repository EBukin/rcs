# Backend `gcs`: a Google Cloud Storage bucket, `gs://bucket[/prefix]`.
#
# Methods of the generics in `R/backend.R` for class `rcs_backend_gcs`.
#
# Credentials
# -----------
# Every GCS backend holds its credential in the field `auth` (an
# `rcs_auth_gcs` object, `R/auth.R`), set by `be_new(uri, auth)`. Each client
# is built from it:
#   * Arrow `GcsFileSystem` (streaming reads, uploads, downloads, listing,
#     deletes): `auth_arrow_fs()`, made with the credential's access token and
#     its expiry, rebuilt when the token is renewed; ambient credentials use
#     Arrow's own defaults. Needs an Arrow build with GCS
#     (`arrow::arrow_with_gcs()`).
#   * JSON API through httr2 (object metadata: `md5Hash`): bearer token from
#     `auth_token()`, scope `cloud-platform`.
#   * GDAL `/vsigs/` (rasters, `be_gdal_path()`), not yet built from the
#     credential: it does not read the application-default credentials of
#     gcloud on Windows (it tries the metadata server and fails with "Could
#     not resolve host: metadata.google.internal"). Works when
#     `GOOGLE_APPLICATION_CREDENTIALS` points to a service-account key or to
#     the application-default credentials file itself, or with
#     `GS_OAUTH2_REFRESH_TOKEN`, `GS_OAUTH2_CLIENT_ID` and
#     `GS_OAUTH2_CLIENT_SECRET`.
# `gcs_reset_clients()` clears the tokens and file systems cached in every
# credential.
#
# Transfer method (decided in work package A, measured 2026-11-20 on the test
# bucket with arrow 26.0.1, gargle 1.7.0, httr2 1.3.0, GDAL 3.12.1, Windows):
#   * A 3 MB file and a 40 MB file uploaded through Arrow's
#     `GcsFileSystem$OpenOutputStream()` both carried `md5Hash` in their
#     object metadata, read through the JSON API right after the stream was
#     closed, equal to the MD5 of the local file. Arrow uploads are therefore
#     kept: `be_put()` writes through Arrow, `be_md5()` reads `md5Hash`
#     through the JSON API without downloading. No deviation from the plan.
#   * Arrow's `FileInfo` carries no MD5, which is why a second client (the
#     JSON API) is needed at all. Objects without `md5Hash` (composite
#     objects, never written by this package) are downloaded and hashed.
#   * `GOOGLE_APPLICATION_CREDENTIALS` pointing to the application-default
#     credentials file made GDAL read `/vsigs/` on this machine; without it
#     GDAL failed (see above).
#
# No `be_init()` method: the default is used, which contacts nothing and
# checks nothing. `be_new("gs://...")` must work offline (objects and tests are
# built from addresses) and on Arrow builds without GCS; and a method defined
# here would be found before a test's `local_mocked_s3_method()` for the same
# class (`tests/testthat/test-backend.R`). The clients are checked at first
# use instead: `gcs_fs()` and `gcs_token()` abort with class
# `rcs_error_backend` and the bullets of `be_auth_hint()`.

gcs_scope <- "https://www.googleapis.com/auth/cloud-platform"
gcs_api <- "https://storage.googleapis.com/storage/v1"
gcs_chunk <- 8 * 1024^2

# Object name of relative paths inside the bucket, and the same path inside
# Arrow's file system.
gcs_object <- function(be, path) {
  if (length(path) == 0) {
    return(character())
  }
  if (nzchar(be$prefix)) paste0(be$prefix, "/", path) else path
}

gcs_fs_path <- function(be, path) {
  if (length(path) == 0) {
    return(character())
  }
  paste0(be$root, "/", path)
}

abort_gcs <- function(message, be, parent = NULL, auth = FALSE,
                      call = caller_env(), .envir = parent.frame()) {
  message <- c(message, if (auth) be_auth_hint(be))
  cli::cli_abort(
    message,
    class = "rcs_error_backend", parent = parent, call = call, .envir = .envir
  )
}

# Does an error message point at credentials or permissions?
gcs_auth_error <- function(text) {
  grepl(
    "401|403|UNAUTHENTICATED|PERMISSION_DENIED|credential|unauthori[sz]ed|forbidden|oauth|metadata\\.google\\.internal",
    text,
    ignore.case = TRUE
  )
}

# Run Arrow code, turning its errors into `rcs_error_backend`.
gcs_try <- function(expr, be, what, call = caller_env()) {
  tryCatch(expr, error = function(e) {
    if (inherits(e, "rcs_error_backend")) {
      rlang::cnd_signal(e)
    }
    abort_gcs(
      "{what} failed in {.val {be$uri}}.",
      be = be, parent = e, auth = gcs_auth_error(conditionMessage(e)), call = call
    )
  })
}

# Clients ---------------------------------------------------------------------

# Credential of a backend (one made without `be_new()` uses the default).
gcs_auth <- function(be) {
  be$auth %||% rcs_auth_gcs()
}

# Arrow file system of the backend's credential.
gcs_fs <- function(be) {
  if (!arrow::arrow_with_gcs()) {
    abort_gcs(
      c(
        "This build of Arrow cannot reach Google Cloud Storage.",
        i = "Install an Arrow build with GCS support (see {.code arrow::arrow_with_gcs()})."
      ),
      be = be
    )
  }
  tryCatch(auth_arrow_fs(gcs_auth(be)), error = function(e) {
    abort_gcs(
      "Creating the Arrow file system for {.val {be$uri}} failed.",
      be = be, parent = e, auth = TRUE
    )
  })
}

# Access token for the JSON API.
gcs_token <- function(be) {
  if (!gcs_clients_installed()) {
    abort_gcs(
      c(
        "Reading object metadata in Google Cloud Storage needs the packages {.pkg gargle} and {.pkg httr2}.",
        i = "Install them with {.code install.packages(c(\"gargle\", \"httr2\"))}."
      ),
      be = be
    )
  }
  tryCatch(auth_token(gcs_auth(be)), error = function(e) {
    abort_gcs(
      "No access token for the Google Cloud Storage JSON API.",
      be = be, parent = e, auth = TRUE
    )
  })
}

gcs_clients_installed <- function() {
  rlang::is_installed(c("gargle", "httr2"))
}

# Clear the cached clients: the tokens and Arrow file systems of every
# credential.
gcs_reset_clients <- function() {
  auth_reset()
}

# JSON API: metadata of objects. Returns a list per path with `status`
# (HTTP status) and `md5` (hex or NA).
gcs_object_meta <- function(be, paths) {
  token <- gcs_token(be)
  reqs <- lapply(gcs_object(be, paths), function(object) {
    # The object name is one path segment with `/` escaped; built by hand
    # because `httr2::req_url_path_append()` turns `%2F` back into `/`.
    # `repeated = TRUE`: partition values in paths are already URL-encoded
    # (`year=a%20b`), and the object name holds that `%` literally.
    url <- paste0(
      gcs_api, "/b/", be$bucket, "/o/",
      utils::URLencode(object, reserved = TRUE, repeated = TRUE), "?fields=md5Hash"
    )
    httr2::request(url) |>
      httr2::req_auth_bearer_token(token) |>
      httr2::req_error(is_error = function(resp) FALSE)
  })
  resps <- gcs_perform(reqs)
  lapply(seq_along(resps), function(i) {
    resp <- resps[[i]]
    if (inherits(resp, "error")) {
      abort_gcs(
        "Reading the metadata of {.path {paths[[i]]}} failed in {.val {be$uri}}.",
        be = be, parent = resp, auth = gcs_auth_error(conditionMessage(resp))
      )
    }
    status <- httr2::resp_status(resp)
    if (status == 404) {
      return(list(status = status, md5 = NA_character_))
    }
    if (status >= 300) {
      body <- tryCatch(httr2::resp_body_string(resp), error = function(e) "")
      abort_gcs(
        c(
          "Reading the metadata of {.path {paths[[i]]}} failed in {.val {be$uri}} (HTTP {status}).",
          x = "{substr(body, 1, 300)}"
        ),
        be = be, auth = status %in% c(401, 403)
      )
    }
    hash <- httr2::resp_body_json(resp)$md5Hash
    list(status = status, md5 = if (is.null(hash)) NA_character_ else md5_base64_to_hex(hash))
  })
}

gcs_perform <- function(reqs) {
  if (length(reqs) == 1) {
    return(list(tryCatch(httr2::req_perform(reqs[[1]]), error = function(e) e)))
  }
  httr2::req_perform_parallel(reqs, on_error = "continue", progress = FALSE)
}

# Copy between a local file and an Arrow stream in chunks, so that memory
# stays bounded for large files.
stream_to_local <- function(input, dest) {
  con <- file(dest, open = "wb")
  on.exit(close(con))
  repeat {
    buf <- input$Read(gcs_chunk)
    if (buf$size == 0) {
      break
    }
    writeBin(buf$data(), con)
  }
  invisible(dest)
}

local_to_stream <- function(src, output) {
  con <- file(src, open = "rb")
  on.exit(close(con))
  repeat {
    bytes <- readBin(con, "raw", gcs_chunk)
    if (length(bytes) == 0) {
      break
    }
    output$write(arrow::buffer(bytes))
  }
  invisible(src)
}

# Methods ---------------------------------------------------------------------

#' @export
be_arrow_fs.rcs_backend_gcs <- function(be) {
  list(fs = gcs_fs(be), path = be$root)
}

#' @export
be_gdal_path.rcs_backend_gcs <- function(be, path) {
  if (length(path) == 0) {
    return(character())
  }
  paste0("/vsigs/", gcs_fs_path(be, path))
}

#' @export
be_get.rcs_backend_gcs <- function(be, path, dest) {
  fs <- gcs_fs(be)
  if (!gcs_exists(be, fs, path)) {
    abort_gcs("Cannot download {.path {path}}: it does not exist in {.val {be$uri}}.", be = be)
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  what <- paste0("Downloading ", path)
  input <- gcs_try(fs$OpenInputStream(gcs_fs_path(be, path)), be, what)
  on.exit(input$close(), add = TRUE)
  gcs_try(stream_to_local(input, dest), be, what)
  invisible(dest)
}

#' @export
be_put.rcs_backend_gcs <- function(be, src, path) {
  if (!rlang::is_string(src) || !file.exists(src) || dir.exists(src)) {
    abort_gcs("Cannot upload {.path {src}}: no such file.", be = be)
  }
  fs <- gcs_fs(be)
  what <- paste0("Uploading ", path)
  output <- gcs_try(fs$OpenOutputStream(gcs_fs_path(be, path)), be, what)
  gcs_try(local_to_stream(src, output), be, what)
  # Closing finalises the object; only then does it exist with its MD5.
  gcs_try(output$close(), be, what)
  invisible(path)
}

#' @export
be_delete.rcs_backend_gcs <- function(be, paths) {
  if (length(paths) == 0) {
    return(invisible(paths))
  }
  fs <- gcs_fs(be)
  existing <- gcs_fs_path(be, paths)[gcs_exists(be, fs, paths)]
  if (length(existing) > 0) {
    gcs_try(fs$DeleteFiles(existing), be, "Deleting files")
  }
  invisible(paths)
}

#' @export
be_md5.rcs_backend_gcs <- function(be, paths) {
  if (length(paths) == 0) {
    return(character())
  }
  meta <- gcs_object_meta(be, paths)
  out <- vapply(meta, function(m) m$md5, character(1))
  # Objects that exist but report no MD5 (composite objects): hash a copy.
  for (i in which(is.na(out) & vapply(meta, function(m) m$status, numeric(1)) < 300)) {
    tmp <- withr::local_tempfile()
    be_get(be, paths[[i]], tmp)
    out[[i]] <- md5_file(tmp)
  }
  out
}

#' @export
be_list.rcs_backend_gcs <- function(be, prefix = "") {
  fs <- gcs_fs(be)
  prefix <- sub("/+$", "", prefix)
  base <- if (nzchar(prefix)) gcs_fs_path(be, prefix) else be$root
  infos <- gcs_try(
    fs$GetFileInfo(arrow::FileSelector$create(base, recursive = TRUE, allow_not_found = TRUE)),
    be, "Listing files"
  )
  infos <- Filter(function(i) i$type == arrow::FileType$File, infos)
  path <- vapply(infos, function(i) i$path, character(1))
  path <- substring(path, nchar(be$root) + 2)
  modified <- as.POSIXct(
    vapply(infos, function(i) as.numeric(i$mtime), numeric(1)),
    origin = "1970-01-01", tz = "UTC"
  )
  out <- tibble::tibble(
    path = path,
    bytes = vapply(infos, function(i) as.double(i$size), numeric(1)),
    modified = modified
  )
  out[order(out$path, method = "radix"), ]
}

#' @export
be_exists.rcs_backend_gcs <- function(be, paths) {
  gcs_exists(be, gcs_fs(be), paths)
}

# Uncounted helper behind `be_exists()`, also used by other methods.
gcs_exists <- function(be, fs, paths) {
  if (length(paths) == 0) {
    return(logical())
  }
  infos <- gcs_try(fs$GetFileInfo(gcs_fs_path(be, paths)), be, "Looking up files")
  vapply(infos, function(i) i$type == arrow::FileType$File, logical(1))
}

#' @export
be_auth_hint.rcs_backend_gcs <- function(be) {
  in_use <- cli_escape(auth_describe(gcs_auth(be)))
  c(
    i = paste0("Credentials in use: ", in_use, "."),
    i = "Pass other credentials with {.arg auth} of {.fn store_connect} or {.fn store_create}: a key file path, {.code rcs_auth_gcs(key = )}, {.code rcs_auth_gcs(token = )} or {.code rcs_auth_gcs(fun = )}.",
    i = "Without {.arg auth}, the default lookup uses {.envvar GOOGLE_APPLICATION_CREDENTIALS}, else the login of {.code gcloud auth application-default login}; see {.fn rcs_auth_gcs}."
  )
}

# Text shown literally inside a cli message.
cli_escape <- function(x) {
  gsub("([{}])", "\\1\\1", x)
}
