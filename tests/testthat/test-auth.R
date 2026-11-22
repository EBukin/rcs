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
  out <- expect_output(print(auth), "renewed at the next use")
  expect_invisible(print(auth))
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
  expect_identical(sent$body$data$grant_type, "refresh_token")
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
