# Prototype: one credential per location, handed to every client.
#
#   st <- store_connect("gs://bucket/store")                       # default
#   st <- store_connect("gs://bucket/store", auth = "key.json")    # key file
#   st <- store_connect("gs://bucket/store", auth = token)         # access token
#   st <- store_connect("gs://bucket/store", auth = function() get_token())
#   st <- store_connect(p, s, auth = list("gs://a/x" = "a.json", "gs://b/y" = "b.json"))
#
# The default is Google's own lookup: GOOGLE_APPLICATION_CREDENTIALS, else
# the login written once by `gcloud auth application-default login`. That
# login holds a refresh token, so nobody signs in again: access tokens are
# renewed in the background before they expire. A plain access token cannot
# be renewed (it lasts about an hour); a function is called again when the
# token it gave expires.
#
# Every client is built from the location's credential:
#
#   client          built as
#   --------------  ---------------------------------------------------------
#   Arrow           GcsFileSystem$create(access_token =, expiration =),
#                   rebuilt with a fresh token before the old one expires
#   JSON API        bearer token (httr2)
#   GDAL /vsigs/    GS_OAUTH2_* (user login) / GOOGLE_APPLICATION_CREDENTIALS
#                   (key file) / GDAL_HTTP_HEADERS bearer (token), set as
#                   GDAL options only while a call runs
#   DuckDB native   CREATE SECRET (TYPE gcs, BEARER_TOKEN, SCOPE 'gs://bucket')
#                   on that DuckDB connection only
#
# Credentials and their tokens are cached by source (file or function), so
# connecting again with the same credential reuses the token, and two
# different credentials never share one. No environment variable is changed.
#
# Load after `devtools::load_all()`: `source("dev/prototype/auth.R")`.

the_proto <- new.env(parent = emptyenv())
the_proto$by_source <- list()   # credential objects, by source
the_proto$by_root <- list()     # credential of each GCS location, by root

rcs_auth_gcs <- function(credentials = NULL) {
  if (inherits(credentials, "rcs_auth_gcs")) return(credentials)
  if (is.function(credentials)) {
    kind <- "function"; file <- NA_character_; type <- "token function"
    key <- paste0("fn:", rlang::hash(credentials))
  } else if (is.character(credentials) && length(credentials) == 1 && !file.exists(credentials) &&
             grepl("^ya29\\.|^[A-Za-z0-9._-]{100,}$", credentials)) {
    kind <- "token"; file <- NA_character_; type <- "access token"
    key <- paste0("tok:", rlang::hash(credentials))
  } else {
    file <- credentials %||% {
      env <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
      if (nzchar(env)) env else proto_adc_file()
    }
    if (!file.exists(file)) {
      cli::cli_abort(c(
        "No Google credentials found{if (is.null(credentials)) '' else paste0(' at ', file)}.",
        i = "Sign in once with {.code gcloud auth application-default login}, or pass a key file, a token or a function to {.arg auth}."
      ))
    }
    file <- normalizePath(file, winslash = "/")
    kind <- if (is.null(credentials)) "default" else "file"
    type <- jsonlite::read_json(file)$type
    key <- paste0("file:", file)
  }
  if (!is.null(the_proto$by_source[[key]])) return(the_proto$by_source[[key]])
  auth <- structure(
    list(kind = kind, file = file, type = type, key = key,
         fun = if (is.function(credentials)) credentials,
         token0 = if (kind == "token") credentials,
         cache = new.env(parent = emptyenv())),
    class = "rcs_auth_gcs"
  )
  the_proto$by_source[[key]] <- auth
  auth
}

proto_adc_file <- function() {
  base <- if (.Platform$OS.type == "windows") Sys.getenv("APPDATA") else "~/.config"
  file.path(base, "gcloud", "application_default_credentials.json")
}

print.rcs_auth_gcs <- function(x, ...) {
  c <- x$cache
  left <- if (is.null(c$token)) "none yet" else
    paste0("valid ", round(as.numeric(difftime(c$expires, Sys.time(), units = "mins"))), " min, renewed automatically",
           if (x$kind == "token") " (no: a plain token cannot be renewed)" else "")
  cli::cat_line(c(
    "<rcs_auth_gcs>",
    paste0("Source:   ", switch(x$kind, default = "default lookup (gcloud login or GOOGLE_APPLICATION_CREDENTIALS)",
                                file = "key file", token = "access token", "function")),
    paste0("Type:     ", x$type),
    if (!is.na(x$file)) paste0("File:     ", x$file),
    paste0("Identity: ", c$identity %||% "(known after the first token)"),
    paste0("Token:    ", left)
  ))
  invisible(x)
}

# Access token, renewed five minutes before it expires.
auth_token <- function(auth) {
  c <- auth$cache
  if (!is.null(c$token) && difftime(c$expires, Sys.time(), units = "secs") > 300) {
    return(c$token)
  }
  got <- switch(auth$kind,
    token = list(access_token = auth$token0, expires_in = 3600),
    "function" = {
      t <- auth$fun()
      if (is.character(t)) list(access_token = t, expires_in = 3600) else t
    },
    proto_token_from_file(auth)
  )
  c$token <- got$access_token
  c$expires <- Sys.time() + got$expires_in
  if (is.null(c$identity)) {
    who <- tryCatch(
      httr2::request("https://oauth2.googleapis.com/tokeninfo") |>
        httr2::req_url_query(access_token = c$token) |>
        httr2::req_perform() |> httr2::resp_body_json(),
      error = function(e) list()
    )
    c$identity <- who$email %||% NA_character_
  }
  c$token
}

proto_token_from_file <- function(auth) {
  info <- jsonlite::read_json(auth$file)
  if (identical(info$type, "authorized_user")) {
    httr2::request("https://oauth2.googleapis.com/token") |>
      httr2::req_body_form(grant_type = "refresh_token", refresh_token = info$refresh_token,
                           client_id = info$client_id, client_secret = info$client_secret) |>
      httr2::req_perform() |> httr2::resp_body_json()
  } else {
    tok <- gargle::credentials_service_account(scopes = gcs_scope, path = auth$file)
    list(access_token = tok$credentials$access_token, expires_in = tok$credentials$expires_in)
  }
}

# Arrow file system of this credential, rebuilt when the token changes.
auth_arrow_fs <- function(auth) {
  c <- auth$cache
  token <- auth_token(auth)
  if (is.null(c$fs) || !identical(c$fs_token, token)) {
    c$fs <- arrow::GcsFileSystem$create(access_token = token, expiration = c$expires)
    c$fs_token <- token
  }
  c$fs
}

auth_gdal_options <- function(auth) {
  if (auth$kind %in% c("token", "function")) {
    return(c(GDAL_HTTP_HEADERS = paste("Authorization: Bearer", auth_token(auth))))
  }
  if (identical(auth$type, "authorized_user")) {
    info <- jsonlite::read_json(auth$file)
    c(GS_OAUTH2_REFRESH_TOKEN = info$refresh_token, GS_OAUTH2_CLIENT_ID = info$client_id,
      GS_OAUTH2_CLIENT_SECRET = info$client_secret)
  } else {
    c(GOOGLE_APPLICATION_CREDENTIALS = auth$file)
  }
}

# Run `code` with the GDAL options set, then restore the previous values.
with_gdal_auth <- function(auth, code) {
  opts <- auth_gdal_options(auth)
  old <- vapply(names(opts), function(k) terra::getGDALconfig(k), character(1))
  for (k in names(opts)) terra::setGDALconfig(k, opts[[k]])
  on.exit(for (k in names(old)) terra::setGDALconfig(k, old[[k]]), add = TRUE)
  force(code)
}

auth_duckdb_secret <- function(auth, con, bucket) {
  DBI::dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
  name <- paste0("rcs_", gsub("[^A-Za-z0-9]", "_", bucket))
  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE SECRET %s (TYPE gcs, BEARER_TOKEN %s, SCOPE %s)",
    name, DBI::dbQuoteString(con, auth_token(auth)), DBI::dbQuoteString(con, paste0("gs://", bucket))
  ))
  invisible(name)
}

# Wiring into the package ------------------------------------------------------

# Credential of a GCS location (the planned version keeps it in the backend
# object; the prototype looks it up by the location's root).
proto_store_auth <- function(be) {
  the_proto$by_root[[be$root]] %||% rcs_auth_gcs()
}

proto_gcs_fs <- function(be) {
  if (!arrow::arrow_with_gcs()) {
    abort_gcs("This build of Arrow cannot reach Google Cloud Storage.", be = be)
  }
  gcs_try(auth_arrow_fs(proto_store_auth(be)), be, "Creating the Arrow file system")
}
proto_gcs_token <- function(be) {
  tryCatch(auth_token(proto_store_auth(be)), error = function(e) {
    abort_gcs("No credentials found for the Google Cloud Storage JSON API.", be = be, parent = e, auth = TRUE)
  })
}
ns <- asNamespace("rcs")
for (nm in c("gcs_fs", "gcs_token")) {
  unlockBinding(nm, ns)
  assign(nm, get(paste0("proto_", nm)), envir = ns)
  lockBinding(nm, ns)
}

# store_connect(auth = ): one credential for every GCS location, or a list
# named by address.
proto_store_connect <- rcs:::store_connect
store_connect <- function(primary = NULL, secondary = NULL, ..., auth = NULL) {
  addresses <- c(primary, secondary)
  for (a in addresses[grepl("^gs://", addresses)]) {
    root <- be_new(a)$root
    cred <- if (is.list(auth) && !inherits(auth, "rcs_auth_gcs")) auth[[a]] else auth
    the_proto$by_root[[root]] <- rcs_auth_gcs(cred)
  }
  proto_store_connect(primary, secondary, ...)
}

# Which client reaches which location: one row per location and client.
store_auth_check <- function(st) {
  rows <- list()
  for (loc in c(list(st$primary), st$secondary)) {
    be <- loc$backend
    if (!inherits(be, "rcs_backend_gcs")) {
      rows[[length(rows) + 1]] <- tibble::tibble(location = loc$uri, client = "all", ok = TRUE,
                                                 note = "local folder: no credentials needed")
      next
    }
    auth <- proto_store_auth(be)
    probe <- function(client, expr) {
      t0 <- Sys.time()
      res <- tryCatch({ force(expr); NA_character_ }, error = function(e) conditionMessage(e))
      tibble::tibble(location = loc$uri, client = client, ok = is.na(res),
                     note = if (is.na(res)) sprintf("ok (%.1fs)", difftime(Sys.time(), t0, units = "secs")) else substr(res, 1, 120))
    }
    path <- paste0(be$root, "/_catalog.parquet")
    rows <- c(rows, list(
      probe("arrow", stopifnot(auth_arrow_fs(auth)$GetFileInfo(path)[[1]]$type == arrow::FileType$File)),
      probe("json_api", be_md5(be, "_catalog.parquet")),
      probe("gdal", {
        tif <- loc$files$path[grepl("\\.tif$", loc$files$path)]
        if (length(tif) == 0) stop("no raster in this location to test with")
        with_gdal_auth(auth, terra::rast(paste0("/vsigs/", be$root, "/", tif[[1]])))
      }),
      probe("duckdb", {
        con <- DBI::dbConnect(duckdb::duckdb()); on.exit(DBI::dbDisconnect(con))
        auth_duckdb_secret(auth, con, be$bucket)
        DBI::dbGetQuery(con, sprintf("SELECT count(*) FROM read_parquet('gs://%s')", path))
      })
    ))
  }
  do.call(rbind, rows)
}

# GDAL ---------------------------------------------------------------------
# A raster opened through GDAL is read lazily (tiles on demand), so its
# credential must stay set while the raster is in use; scoping it to one
# call fails on the next read. GDAL options are process-wide: the first GCS
# raster read sets the credential of its location, and a raster read from a
# location with a different credential replaces it with a warning.
proto_gdal_use <- function(auth) {
  if (identical(the_proto$gdal_key, auth$key)) return(invisible())
  if (!is.null(the_proto$gdal_key)) {
    cli::cli_warn(c(
      "GDAL now uses another credential for Google Cloud Storage.",
      i = "Rasters opened earlier with the previous credential may fail to read further tiles."
    ))
  }
  opts <- auth_gdal_options(auth)
  for (k in setdiff(c("GS_OAUTH2_REFRESH_TOKEN", "GS_OAUTH2_CLIENT_ID", "GS_OAUTH2_CLIENT_SECRET",
                      "GOOGLE_APPLICATION_CREDENTIALS", "GDAL_HTTP_HEADERS"), names(opts))) {
    terra::setGDALconfig(k, "")
  }
  for (k in names(opts)) terra::setGDALconfig(k, opts[[k]])
  the_proto$gdal_key <- auth$key
  invisible()
}
local({
  ns <- asNamespace("rcs")
  unlockBinding("be_gdal_path.rcs_backend_gcs", ns)
  assign("be_gdal_path.rcs_backend_gcs", function(be, path) {
    if (length(path) == 0) return(character())
    proto_gdal_use(proto_store_auth(be))
    paste0("/vsigs/", gcs_fs_path(be, path))
  }, envir = ns)
  lockBinding("be_gdal_path.rcs_backend_gcs", ns)
})
