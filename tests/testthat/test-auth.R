# rcs_auth_gcs(), auth_token(), auth_arrow_fs() and their seams. Every test
# runs offline: the network seams (`auth_http_token()`, `auth_tokeninfo()`)
# and the clock (`auth_now()`) are mocked, and no environment variable is
# left changed.

# Fresh registry of credential objects for one test.
local_auth_registry <- function(env = parent.frame()) {
  old <- the_auth$objects
  the_auth$objects <- list()
  withr::defer(the_auth$objects <- old, envir = env)
}

# Fails the test when an environment variable differs at its end. Call it
# first, so that it runs after every other deferred restore.
local_env_unchanged <- function(env = parent.frame()) {
  before <- as.list(Sys.getenv())
  withr::defer(testthat::expect_identical(as.list(Sys.getenv()), before), envir = env)
}

# Any network call fails the test.
local_no_network <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    auth_http_token = function(body) stop("auth_http_token() must not be called"),
    auth_tokeninfo = function(token) stop("auth_tokeninfo() must not be called"),
    .env = env
  )
}

# A clock that the test moves: `clock$now`.
local_clock <- function(env = parent.frame()) {
  clock <- new.env()
  clock$now <- as.POSIXct("2026-11-21 10:00:00", tz = "UTC")
  testthat::local_mocked_bindings(auth_now = function() clock$now, .env = env)
  clock
}

secrets <- c("FAKE-REFRESH-TOKEN", "FAKE-CLIENT-SECRET", "FAKE-PRIVATE-KEY", "ya29-fake-access")

write_key <- function(path, type = "authorized_user") {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  info <- switch(type,
    authorized_user = list(
      type = type, client_id = "fake-client-id.apps.example.com",
      client_secret = "FAKE-CLIENT-SECRET", refresh_token = "FAKE-REFRESH-TOKEN"
    ),
    service_account = list(
      type = type, client_email = "robot@example.iam.gserviceaccount.com",
      private_key = "FAKE-PRIVATE-KEY"
    ),
    list(type = type, audience = "elsewhere")
  )
  jsonlite::write_json(info, path, auto_unbox = TRUE)
  normalizePath(path, winslash = "/")
}

# No credential file anywhere: the default lookup starts from nothing.
local_clean_lookup <- function(env = parent.frame()) {
  home <- withr::local_tempdir(.local_envir = env)
  withr::local_envvar(
    GOOGLE_APPLICATION_CREDENTIALS = NA, CLOUDSDK_CONFIG = NA,
    APPDATA = home, HOME = home,
    .local_envir = env
  )
  home
}

platform_adc <- function() {
  base <- if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("APPDATA"), "gcloud")
  } else {
    file.path(Sys.getenv("HOME"), ".config", "gcloud")
  }
  file.path(base, "application_default_credentials.json")
}

test_that("the default lookup: GOOGLE_APPLICATION_CREDENTIALS, CLOUDSDK_CONFIG, gcloud folder, ambient", {
  local_env_unchanged()
  local_auth_registry()
  local_no_network()
  local_clean_lookup()

  ambient <- rcs_auth_gcs()
  expect_s3_class(ambient, "rcs_auth_gcs")
  expect_named(ambient, c("source", "type", "file", "cache"))
  expect_identical(ambient$source, "ambient")
  expect_true(is.na(ambient$file))
  expect_true(is.environment(ambient$cache))

  gcloud <- write_key(platform_adc())
  auth <- rcs_auth_gcs()
  expect_identical(auth$source, "gcloud")
  expect_identical(auth$file, gcloud)
  expect_identical(auth$type, "authorized_user")

  cfg <- withr::local_tempdir()
  withr::local_envvar(CLOUDSDK_CONFIG = cfg)
  expect_identical(rcs_auth_gcs()$source, "ambient")
  in_cfg <- write_key(file.path(cfg, "application_default_credentials.json"))
  auth <- rcs_auth_gcs()
  expect_identical(auth$source, "CLOUDSDK_CONFIG")
  expect_identical(auth$file, in_cfg)

  sa <- write_key(file.path(withr::local_tempdir(), "sa.json"), "service_account")
  withr::local_envvar(GOOGLE_APPLICATION_CREDENTIALS = sa)
  auth <- rcs_auth_gcs()
  expect_identical(auth$source, "GOOGLE_APPLICATION_CREDENTIALS")
  expect_identical(auth$file, sa)
  expect_identical(auth$type, "service_account")

  withr::local_envvar(GOOGLE_APPLICATION_CREDENTIALS = file.path(cfg, "none.json"))
  expect_error(rcs_auth_gcs(), "GOOGLE_APPLICATION_CREDENTIALS", class = "rcs_error_backend")
})

test_that("key files of both types are accepted, other types abort", {
  local_env_unchanged()
  local_auth_registry()
  local_no_network()
  dir <- withr::local_tempdir()
  user <- rcs_auth_gcs(key = write_key(file.path(dir, "user.json")))
  expect_identical(user$source, "key")
  expect_identical(user$type, "authorized_user")
  sa <- rcs_auth_gcs(key = write_key(file.path(dir, "sa.json"), "service_account"))
  expect_identical(sa$type, "service_account")

  other <- write_key(file.path(dir, "other.json"), "external_account")
  broken <- file.path(dir, "broken.json")
  writeLines("not json {", broken)
  scrub <- function(x) gsub(normalizePath(dir, winslash = "/"), "<dir>", x, fixed = TRUE)
  withr::local_options(cli.width = 250)
  expect_snapshot(error = TRUE, transform = scrub, {
    rcs_auth_gcs(key = other)
    rcs_auth_gcs(key = broken)
    rcs_auth_gcs(key = file.path(dir, "none.json"))
  })
  expect_error(rcs_auth_gcs(key = other), class = "rcs_error_backend")
  expect_error(rcs_auth_gcs(key = broken), class = "rcs_error_backend")
})

test_that("rcs_auth_gcs() takes at most one argument, each checked", {
  local_env_unchanged()
  local_auth_registry()
  expect_snapshot(error = TRUE, {
    rcs_auth_gcs(key = "a.json", token = "abc")
    rcs_auth_gcs(token = "abc", fun = function() "x")
    rcs_auth_gcs(token = 1)
    rcs_auth_gcs(key = c("a", "b"))
    rcs_auth_gcs(fun = "not a function")
  })
  expect_error(rcs_auth_gcs(token = ""), class = "rcs_error_argument")
})

test_that("the same source gives the identical object", {
  local_env_unchanged()
  local_auth_registry()
  local_no_network()
  key <- write_key(file.path(withr::local_tempdir(), "user.json"))
  expect_identical(rcs_auth_gcs(key = key), rcs_auth_gcs(key = key))
  expect_identical(rcs_auth_gcs(key = key)$cache, rcs_auth_gcs(key = key)$cache)
  expect_identical(rcs_auth_gcs(token = "abc")$cache, rcs_auth_gcs(token = "abc")$cache)
  expect_false(identical(rcs_auth_gcs(token = "abc")$cache, rcs_auth_gcs(token = "abd")$cache))
  f <- function() "abc"
  expect_identical(rcs_auth_gcs(fun = f)$cache, rcs_auth_gcs(fun = f)$cache)
  local_clean_lookup()
  expect_identical(rcs_auth_gcs()$cache, rcs_auth_gcs()$cache)
  expect_identical(rcs_auth_gcs(), rcs_auth_gcs())
})

test_that("a user login is renewed five minutes before it expires", {
  local_env_unchanged()
  local_auth_registry()
  clock <- local_clock()
  key <- write_key(file.path(withr::local_tempdir(), "user.json"))
  bodies <- list()
  who <- 0
  local_mocked_bindings(
    auth_http_token = function(body) {
      bodies[[length(bodies) + 1]] <<- body
      list(access_token = paste0("tok-", length(bodies)), expires_in = 3600)
    },
    auth_tokeninfo = function(token) {
      who <<- who + 1
      "someone@example.com"
    }
  )
  auth <- rcs_auth_gcs(key = key)
  expect_identical(auth_token(auth), "tok-1")
  expect_identical(bodies[[1]], list(
    grant_type = "refresh_token", refresh_token = "FAKE-REFRESH-TOKEN",
    client_id = "fake-client-id.apps.example.com", client_secret = "FAKE-CLIENT-SECRET"
  ))
  clock$now <- clock$now + 54 * 60
  expect_identical(auth_token(auth), "tok-1")
  clock$now <- clock$now + 2 * 60
  expect_identical(auth_token(auth), "tok-2")
  expect_length(bodies, 2)
  expect_identical(who, 1)
  expect_identical(auth$cache$identity, "someone@example.com")
})

test_that("a refused renewal aborts rcs_error_backend without echoing secrets", {
  local_env_unchanged()
  local_auth_registry()
  local_clock()
  key <- write_key(file.path(withr::local_tempdir(), "user.json"))
  local_mocked_bindings(auth_http_token = function(body) stop("HTTP 400 Bad Request: invalid_grant"))
  err <- expect_error(auth_token(rcs_auth_gcs(key = key)), "access token", class = "rcs_error_backend")
  text <- paste(conditionMessage(err), conditionMessage(err$parent))
  for (s in secrets) expect_no_match(text, s, fixed = TRUE)
})

test_that("a service-account key gets its token from gargle with the cloud-platform scope", {
  skip_if_not_installed("gargle")
  local_env_unchanged()
  local_auth_registry()
  local_clock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  key <- write_key(file.path(withr::local_tempdir(), "sa.json"), "service_account")
  got <- list()
  local_mocked_bindings(
    credentials_service_account = function(scopes = NULL, path = "", ...) {
      got <<- list(scopes = scopes, path = path)
      list(credentials = list(access_token = "sa-token", expires_in = 3599))
    },
    .package = "gargle"
  )
  expect_identical(auth_token(rcs_auth_gcs(key = key)), "sa-token")
  expect_identical(got, list(scopes = "https://www.googleapis.com/auth/cloud-platform", path = key))

  local_auth_registry()
  local_mocked_bindings(credentials_service_account = function(...) NULL, .package = "gargle")
  expect_error(auth_token(rcs_auth_gcs(key = key)), class = "rcs_error_backend")
})

test_that("ambient credentials come from gargle's application default", {
  skip_if_not_installed("gargle")
  local_env_unchanged()
  local_auth_registry()
  local_clock()
  local_clean_lookup()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  scopes <- NULL
  local_mocked_bindings(
    credentials_app_default = function(scopes = NULL, ...) {
      scopes <<- scopes
      list(credentials = list(access_token = "ambient-token", expires_in = 3600))
    },
    .package = "gargle"
  )
  expect_identical(auth_token(rcs_auth_gcs()), "ambient-token")
  expect_identical(scopes, "https://www.googleapis.com/auth/cloud-platform")

  local_auth_registry()
  local_mocked_bindings(credentials_app_default = function(...) NULL, .package = "gargle")
  expect_error(auth_token(rcs_auth_gcs()), "No credentials", class = "rcs_error_backend")
})

test_that("a function is called again when its token is about to expire", {
  local_env_unchanged()
  local_auth_registry()
  clock <- local_clock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  n <- 0
  auth <- rcs_auth_gcs(fun = function() {
    n <<- n + 1
    if (n == 1) "fun-1" else list(access_token = paste0("fun-", n), expires_in = 600)
  })
  expect_identical(auth_token(auth), "fun-1")
  clock$now <- clock$now + 50 * 60
  expect_identical(auth_token(auth), "fun-1")
  clock$now <- clock$now + 6 * 60
  expect_identical(auth_token(auth), "fun-2")
  clock$now <- clock$now + 4 * 60
  expect_identical(auth_token(auth), "fun-2")
  clock$now <- clock$now + 2 * 60
  expect_identical(auth_token(auth), "fun-3")

  bad <- rcs_auth_gcs(fun = function() 42)
  expect_error(auth_token(bad), "function", class = "rcs_error_backend")
  failing <- rcs_auth_gcs(fun = function() stop("no token today"))
  expect_error(auth_token(failing), class = "rcs_error_backend")
})

test_that("a plain token is never renewed", {
  local_env_unchanged()
  local_auth_registry()
  clock <- local_clock()
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    auth_http_token = function(body) stop("must not renew")
  )
  auth <- rcs_auth_gcs(token = "ya29-fake-access")
  expect_identical(auth$source, "token")
  expect_identical(auth_token(auth), "ya29-fake-access")
  clock$now <- clock$now + 3 * 3600
  expect_identical(auth_token(auth), "ya29-fake-access")
  expect_match(paste(capture.output(print(auth)), collapse = "\n"), "not renewed")
})

test_that("print() shows source, type, file, identity and validity, never a secret", {
  local_env_unchanged()
  local_auth_registry()
  local_no_network()
  clock <- local_clock()
  dir <- withr::local_tempdir()
  key <- write_key(file.path(dir, "user.json"))
  auth <- rcs_auth_gcs(key = key)
  scrub <- function(x) gsub(normalizePath(dir, winslash = "/"), "<dir>", x, fixed = TRUE)
  expect_snapshot(print(auth), transform = scrub)

  local_mocked_bindings(
    auth_http_token = function(body) list(access_token = "ya29-fake-access", expires_in = 3600),
    auth_tokeninfo = function(token) "someone@example.com"
  )
  auth_token(auth)
  local_no_network()
  clock$now <- clock$now + 20 * 60
  expect_snapshot(print(auth), transform = scrub)
  clock$now <- clock$now + 60 * 60
  expect_output(print(auth), "renewed at the next use")
  capture.output(shown <- withVisible(print(auth)))
  expect_false(shown$visible)
  expect_identical(shown$value, auth)
  printed <- paste(capture.output(print(auth)), collapse = "\n")
  for (s in secrets) expect_no_match(printed, s, fixed = TRUE)

  expect_snapshot({
    print(rcs_auth_gcs(token = "ya29-fake-access"))
    print(rcs_auth_gcs(fun = function() "x"))
  })
  local_clean_lookup()
  expect_snapshot(print(rcs_auth_gcs()))
})

test_that("str() of a credential and of a location shows no secret", {
  local_env_unchanged()
  local_auth_registry()
  local_clock()
  key <- write_key(file.path(withr::local_tempdir(), "user.json"))
  local_mocked_bindings(
    auth_http_token = function(body) list(access_token = "ya29-fake-access", expires_in = 3600),
    auth_tokeninfo = function(token) "someone@example.com"
  )
  auth <- rcs_auth_gcs(key = key)
  auth_token(auth)
  be <- be_new("gs://my-bucket/store", auth = auth)
  for (x in list(auth, be, new_location(backend = be))) {
    shown <- paste(capture.output(str(x)), collapse = "\n")
    for (s in secrets) expect_no_match(shown, s, fixed = TRUE)
  }
})

test_that("auth_arrow_fs() builds one file system per token", {
  local_env_unchanged()
  local_auth_registry()
  clock <- local_clock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  made <- list()
  local_mocked_bindings(auth_arrow_fs_create = function(token, expiration) {
    made[[length(made) + 1]] <<- list(token = token, expiration = expiration)
    structure(list(id = length(made)), class = "fake_fs")
  })
  n <- 0
  auth <- rcs_auth_gcs(fun = function() {
    n <<- n + 1
    paste0("fun-", n)
  })
  fs <- auth_arrow_fs(auth)
  expect_identical(auth_arrow_fs(auth), fs)
  expect_identical(made[[1]]$token, "fun-1")
  expect_identical(made[[1]]$expiration, clock$now + 3600)
  clock$now <- clock$now + 56 * 60
  fs2 <- auth_arrow_fs(auth)
  expect_identical(fs2$id, 2L)
  expect_identical(made[[2]]$token, "fun-2")

  other <- auth_arrow_fs(rcs_auth_gcs(token = "abc"))
  expect_identical(other$id, 3L)

  local_clean_lookup()
  ambient <- rcs_auth_gcs()
  fs_a <- auth_arrow_fs(ambient)
  expect_identical(auth_arrow_fs(ambient), fs_a)
  expect_null(made[[4]]$token)
  expect_length(made, 4)
})

test_that("gcs_reset_clients() clears the cached tokens and file systems", {
  local_env_unchanged()
  local_auth_registry()
  local_clock()
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    auth_arrow_fs_create = function(token, expiration) new.env()
  )
  n <- 0
  auth <- rcs_auth_gcs(fun = function() {
    n <<- n + 1
    paste0("fun-", n)
  })
  fs <- auth_arrow_fs(auth)
  expect_identical(auth_token(auth), "fun-1")
  expect_invisible(gcs_reset_clients())
  expect_null(auth$cache$token)
  expect_null(auth$cache$fs)
  expect_identical(auth_token(auth), "fun-2")
  expect_false(identical(auth_arrow_fs(auth), fs))
})

test_that("auth_http_token() posts the form and auth_tokeninfo() reads the e-mail", {
  skip_if_not_installed("httr2")
  local_env_unchanged()
  sent <- NULL
  local_mocked_bindings(
    req_perform = function(req, ...) {
      sent <<- req
      body <- if (grepl("tokeninfo", req$url)) '{"email": "someone@example.com"}' else '{"access_token": "t", "expires_in": 3599}'
      httr2::response(
        status_code = 200L, url = req$url,
        headers = list(`Content-Type` = "application/json"), body = charToRaw(body)
      )
    },
    .package = "httr2"
  )
  got <- auth_http_token(list(grant_type = "refresh_token", refresh_token = "r"))
  expect_identical(got, list(access_token = "t", expires_in = 3599L))
  expect_identical(sent$url, "https://oauth2.googleapis.com/token")
  expect_identical(unclass(sent$body$data$grant_type), "refresh_token")
  expect_identical(auth_tokeninfo("abc"), "someone@example.com")
  expect_match(sent$url, "^https://oauth2.googleapis.com/tokeninfo\\?access_token=abc$")

  local_mocked_bindings(req_perform = function(req, ...) stop("offline"), .package = "httr2")
  expect_identical(auth_tokeninfo("abc"), NA_character_)
  expect_error(auth_http_token(list(a = 1)), "offline")
})

test_that("auth_arrow_fs_create() and auth_now() call Arrow and the clock", {
  expect_s3_class(auth_now(), "POSIXct")
  skip_if_not(arrow::arrow_with_gcs())
  expect_s3_class(auth_arrow_fs_create("abc", Sys.time() + 3600), "GcsFileSystem")
  expect_s3_class(auth_arrow_fs_create(NULL, NULL), "GcsFileSystem")
})

# GDAL ------------------------------------------------------------------------

# Fresh record of the credential GDAL holds, restored afterwards.
local_gdal_state <- function(env = parent.frame()) {
  fields <- c("gdal_id", "gdal_header", "gdal_warned")
  old <- mget(fields, envir = the_auth, ifnotfound = list(NULL))
  rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
  withr::defer(
    {
      rm(list = intersect(fields, ls(the_auth)), envir = the_auth)
      for (f in names(old)) if (!is.null(old[[f]])) assign(f, old[[f]], envir = the_auth)
    },
    envir = env
  )
}

# `gdal_config()` replaced by a recorder: `log$calls` (one `c(option, value)`
# per call).
local_gdal_mock <- function(env = parent.frame()) {
  local_gdal_state(env)
  log <- new.env()
  log$calls <- list()
  testthat::local_mocked_bindings(
    gdal_config = function(option, value) {
      log$calls[[length(log$calls) + 1]] <- c(option, value)
      invisible()
    },
    .env = env
  )
  log
}

# Values set since the last look, as a named character vector (last value per
# option, sorted by option); empties the record.
gdal_set <- function(log) {
  calls <- log$calls
  log$calls <- list()
  if (length(calls) == 0) {
    return(character())
  }
  out <- vapply(calls, `[[`, character(1), 2)
  names(out) <- vapply(calls, `[[`, character(1), 1)
  out <- out[!duplicated(names(out), fromLast = TRUE)]
  out[order(names(out))]
}

gdal_cleared <- function(...) {
  all <- c(
    "GDAL_HTTP_HEADERS", "GOOGLE_APPLICATION_CREDENTIALS", "GS_OAUTH2_CLIENT_ID",
    "GS_OAUTH2_CLIENT_SECRET", "GS_OAUTH2_REFRESH_TOKEN"
  )
  out <- stats::setNames(rep("", length(all)), all)
  given <- c(...)
  out[names(given)] <- given
  out[order(names(out))]
}

test_that("be_gdal_path() gives GDAL the options of each credential type", {
  local_env_unchanged()
  local_auth_registry()
  log <- local_gdal_mock()
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    auth_http_token = function(body) stop("GDAL options need no token for a user login")
  )
  dir <- withr::local_tempdir()
  user <- write_key(file.path(dir, "user.json"))
  robot <- write_key(file.path(dir, "robot.json"), "service_account")
  path <- "r/part-a.tif"

  be <- be_new("gs://bucket/store", auth = rcs_auth_gcs(key = user))
  expect_identical(be_gdal_path(be, path), "/vsigs/bucket/store/r/part-a.tif")
  expect_identical(gdal_set(log), gdal_cleared(
    GS_OAUTH2_REFRESH_TOKEN = "FAKE-REFRESH-TOKEN",
    GS_OAUTH2_CLIENT_ID = "fake-client-id.apps.example.com",
    GS_OAUTH2_CLIENT_SECRET = "FAKE-CLIENT-SECRET"
  ))
  # The same credential again: nothing to change.
  expect_identical(be_gdal_path(be, c(path, "b.tif")), c(
    "/vsigs/bucket/store/r/part-a.tif", "/vsigs/bucket/store/b.tif"
  ))
  expect_identical(gdal_set(log), character())
  expect_identical(be_gdal_path(be, character()), character())
  expect_identical(gdal_set(log), character())

  suppressWarnings({
    be_gdal_path(be_new("gs://bucket/store", auth = rcs_auth_gcs(key = robot)), path)
    expect_identical(gdal_set(log), gdal_cleared(GOOGLE_APPLICATION_CREDENTIALS = robot))

    be_gdal_path(be_new("gs://bucket", auth = rcs_auth_gcs(token = "ya29-fake-access")), path)
    expect_identical(gdal_set(log), gdal_cleared(GDAL_HTTP_HEADERS = "Authorization: Bearer ya29-fake-access"))

    be_gdal_path(be_new("gs://bucket", auth = rcs_auth_gcs(fun = function() "fun-token")), path)
    expect_identical(gdal_set(log), gdal_cleared(GDAL_HTTP_HEADERS = "Authorization: Bearer fun-token"))

    local_clean_lookup()
    be_gdal_path(be_new("gs://bucket", auth = rcs_auth_gcs()), path)
    expect_identical(gdal_set(log), gdal_cleared())
  })
})

test_that("a renewed token of the same credential updates the header silently", {
  local_env_unchanged()
  local_auth_registry()
  log <- local_gdal_mock()
  clock <- local_clock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  n <- 0
  auth <- rcs_auth_gcs(fun = function() {
    n <<- n + 1
    list(access_token = paste0("token-", n), expires_in = 3600)
  })
  be <- be_new("gs://bucket", auth = auth)
  be_gdal_path(be, "a.tif")
  expect_identical(gdal_set(log)[["GDAL_HTTP_HEADERS"]], "Authorization: Bearer token-1")
  be_gdal_path(be, "a.tif")
  expect_identical(gdal_set(log), character())

  clock$now <- clock$now + 3400
  expect_no_warning(be_gdal_path(be, "a.tif"))
  expect_identical(gdal_set(log), c(GDAL_HTTP_HEADERS = "Authorization: Bearer token-2"))
})

test_that("a switch to another credential warns once per session", {
  local_env_unchanged()
  local_auth_registry()
  log <- local_gdal_mock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  a <- be_new("gs://bucket-a", auth = rcs_auth_gcs(token = "token-a"))
  b <- be_new("gs://bucket-b", auth = rcs_auth_gcs(token = "token-b"))
  expect_no_warning(be_gdal_path(a, "x.tif"))
  expect_snapshot(be_gdal_path(b, "x.tif"))
  gdal_set(log)
  expect_no_warning(be_gdal_path(a, "x.tif"))
  expect_identical(gdal_set(log), gdal_cleared(GDAL_HTTP_HEADERS = "Authorization: Bearer token-a"))
  expect_no_warning(be_gdal_path(b, "x.tif"))
})

test_that("the warning on a switch has its class", {
  local_auth_registry()
  local_gdal_mock()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  be_gdal_path(be_new("gs://bucket-a", auth = rcs_auth_gcs(token = "token-a")), "x.tif")
  expect_warning(
    be_gdal_path(be_new("gs://bucket-b", auth = rcs_auth_gcs(token = "token-b")), "x.tif"),
    class = "rcs_warning_gdal_credential"
  )
})

test_that("gdal_config() sets and clears a GDAL option through terra", {
  skip_if_not_installed("terra")
  withr::defer(terra::setGDALconfig("RCS_TEST_OPTION", ""))
  gdal_config("RCS_TEST_OPTION", "some value")
  expect_identical(terra::getGDALconfig("RCS_TEST_OPTION"), "some value")
  gdal_config("RCS_TEST_OPTION", "")
  expect_identical(terra::getGDALconfig("RCS_TEST_OPTION"), "")
})

# DuckDB secret -----------------------------------------------------------------

test_that("auth_duckdb_secret() creates a temporary secret for the scope", {
  local_env_unchanged()
  local_auth_registry()
  local_mocked_bindings(auth_tokeninfo = function(token) NA_character_)
  sent <- character()
  local_mocked_bindings(duckdb_exec = function(con, sql) {
    sent <<- c(sent, sql)
    0
  })
  auth <- rcs_auth_gcs(token = "ya29-it's-fake")
  name <- withVisible(auth_duckdb_secret(auth, "con", "gs://bucket/some/prefix"))
  expect_false(name$visible)
  expect_identical(name$value, paste0("rcs_", md5_string("gs://bucket/some/prefix")))
  expect_identical(sent, paste0(
    "CREATE OR REPLACE TEMPORARY SECRET ", name$value,
    " (TYPE gcs, BEARER_TOKEN 'ya29-it''s-fake', SCOPE 'gs://bucket/some/prefix')"
  ))
  # A trailing slash names the same scope.
  expect_identical(auth_duckdb_secret(auth, "con", "gs://bucket/some/prefix/"), name$value)
  expect_identical(sent[[2]], sent[[1]])
})

test_that("a failing secret aborts rcs_error_duckdb without echoing the token", {
  local_env_unchanged()
  local_auth_registry()
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    duckdb_exec = function(con, sql) stop(paste("Parser Error near", sql))
  )
  auth <- rcs_auth_gcs(token = "ya29-fake-access")
  err <- expect_error(auth_duckdb_secret(auth, "con", "gs://bucket"), class = "rcs_error_duckdb")
  shown <- paste(conditionMessage(err), format(err), collapse = "\n")
  expect_false(grepl("ya29-fake-access", shown, fixed = TRUE))
  expect_null(err$parent)
  expect_snapshot(auth_duckdb_secret(auth, "con", "gs://bucket"), error = TRUE)
  expect_snapshot(auth_duckdb_secret(auth, "con", "bucket/prefix"), error = TRUE)
})

test_that("auth_duckdb_secret() refuses ambient credentials", {
  local_env_unchanged()
  local_auth_registry()
  local_clean_lookup()
  local_mocked_bindings(duckdb_exec = function(con, sql) stop("must not be called"))
  expect_error(auth_duckdb_secret(rcs_auth_gcs(), "con", "gs://bucket"), class = "rcs_error_backend")
})

test_that("duckdb_exec() runs a statement", {
  con <- local_duckdb()
  expect_equal(duckdb_exec(con, "CREATE TABLE t AS SELECT 1 AS x"), 1)
})

# store_auth_check() ----------------------------------------------------------------

test_that("store_auth_check() gives one row per local location", {
  withr::local_options(rcs.quiet = TRUE)
  dir <- withr::local_tempdir()
  a <- file.path(dir, "a")
  b <- file.path(dir, "b")
  store_create(a)
  st <- store_connect(a, b, create = TRUE)
  got <- store_auth_check(st)
  expect_identical(got, tibble::tibble(
    location = c(st$primary$uri, st$secondary[[1]]$uri),
    client = "all",
    ok = TRUE,
    note = "local folder: no credentials needed"
  ))
})

# A store object with one GCS location, built offline.
gcs_store <- function(auth, catalog = catalog_empty(), files = files_empty()) {
  be <- be_new("gs://bucket/store", auth = auth)
  new_store(primary = new_location(backend = be, catalog = catalog, files = files))
}

test_that("store_auth_check() reports each failing client without aborting", {
  local_env_unchanged()
  local_auth_registry()
  local_gdal_mock()
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    auth_check_arrow = function(be, auth) stop("arrow refused ya29-fake-access"),
    auth_check_json_api = function(be, auth) stop("403 forbidden"),
    auth_check_gdal = function(be, auth, path) stop("GDAL cannot open"),
    auth_check_duckdb = function(be, auth) stop("DuckDB failed")
  )
  st <- gcs_store(rcs_auth_gcs(token = "ya29-fake-access"))
  got <- expect_no_error(store_auth_check(st))
  expect_identical(got$location, rep("gs://bucket/store", 4))
  expect_identical(got$client, c("arrow", "json_api", "gdal", "duckdb"))
  ok_duckdb <- if (rlang::is_installed(c("duckdb", "DBI"))) FALSE else NA
  expect_identical(got$ok, c(FALSE, FALSE, NA, ok_duckdb))
  expect_identical(got$note[[3]], "no raster to test with")
  expect_match(got$note[[1]], "arrow refused")
  expect_false(any(grepl("ya29-fake-access", got$note, fixed = TRUE)))
  expect_identical(got$note[[2]], "403 forbidden")
})

test_that("store_auth_check() probes the first raster and passes when every client works", {
  local_env_unchanged()
  local_auth_registry()
  local_gdal_mock()
  probed <- NULL
  local_mocked_bindings(
    auth_tokeninfo = function(token) NA_character_,
    auth_check_arrow = function(be, auth) invisible(),
    auth_check_json_api = function(be, auth) invisible(),
    auth_check_gdal = function(be, auth, path) probed <<- path,
    auth_check_duckdb = function(be, auth) invisible()
  )
  catalog <- catalog_empty()[rep(NA_integer_, 3), ]
  catalog$dataset <- c("t", "grid", "grid2")
  catalog$kind <- c("table", "raster", "raster")
  files <- files_empty()[rep(NA_integer_, 3), ]
  files$dataset <- c("t", "grid", "grid2")
  files$path <- c("t/part-a.parquet", "grid/part-a.tif", "grid2/part-a.tif")
  st <- gcs_store(rcs_auth_gcs(token = "ya29-fake-access"), catalog, files)
  got <- store_auth_check(st)
  expect_identical(probed, "grid/part-a.tif")
  expect_identical(got$ok[1:3], c(TRUE, TRUE, TRUE))
  expect_identical(got$note[1:3], rep("ok", 3))
})

test_that("store_auth_check() does not try GDAL and DuckDB with ambient credentials", {
  local_env_unchanged()
  local_auth_registry()
  local_gdal_mock()
  local_clean_lookup()
  local_mocked_bindings(
    auth_check_arrow = function(be, auth) invisible(),
    auth_check_json_api = function(be, auth) invisible(),
    auth_check_gdal = function(be, auth, path) stop("must not be called"),
    auth_check_duckdb = function(be, auth) stop("must not be called")
  )
  got <- store_auth_check(gcs_store(rcs_auth_gcs()))
  expect_identical(got$ok, c(TRUE, TRUE, NA, NA))
  expect_identical(got$note[3:4], rep("not supported for ambient credentials", 2))
})

# Against the test bucket ------------------------------------------------------------

test_that("a store on the bucket passes store_auth_check() and reads a raster through GDAL", {
  skip_below_level("full")
  uri <- Sys.getenv("RCS_TEST_GCS")
  skip_if(!nzchar(uri), "RCS_TEST_GCS is not set.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  skip_if_not_installed("terra")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  local_env_unchanged()
  gdal_options <- names(gdal_cleared())
  old <- vapply(gdal_options, terra::getGDALconfig, character(1))
  withr::defer(for (k in gdal_options) terra::setGDALconfig(k, old[[k]]))
  local_gdal_state()
  withr::local_options(rcs.quiet = TRUE)
  gcs_reset_clients()
  prefix <- paste0("rcs-test-", paste(sample(c(letters, 0:9), 12, TRUE), collapse = ""))
  be <- be_new(paste0(sub("/+$", "", uri), "/", prefix))
  withr::defer({
    left <- be_list(be)$path
    if (length(left) > 0) be_delete(be, left)
    expect_identical(be_list(be)$path, character())
  })

  store_create(be$uri)
  st <- store_connect(be$uri)
  store_write(st, rcs_sim_table(100, seed = 1), "t", title = "Table", description = "Simulated table.")
  x <- rcs_sim_raster(nrow = 50, ncol = 50)
  store_write(st, x, "grid", title = "Grid", description = "Simulated raster.")

  got <- store_auth_check(st)
  expect_identical(got$client, c("arrow", "json_api", "gdal", "duckdb"))
  expect_true(all(got$ok), info = paste(got$client, got$note, collapse = "; "))

  r <- store_read(st, "grid")
  first <- terra::global(r, "mean", na.rm = TRUE)
  second <- terra::global(r, "mean", na.rm = TRUE)
  expect_identical(first, second)
  expect_equal(first[[1]], terra::global(x, "mean", na.rm = TRUE)[[1]])
})
