# Two parts: offline tests, where Arrow's GCS file system is replaced by a
# local folder and the JSON API by fake responses; and tests against the
# bucket in `RCS_TEST_GCS` at level `full`.

# Offline fake ----------------------------------------------------------------

# Replace the clients: `gcs_fs()` gives a file system rooted in a temporary
# folder that holds `<bucket>/<prefix>/...`, and the JSON API answers from the
# files in it. Returns the folder.
local_fake_gcs <- function(md5 = TRUE, status = NULL, env = parent.frame()) {
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  dir <- withr::local_tempdir(.local_envir = env)
  sub_fs <- arrow::SubTreeFileSystem$create(dir, arrow::LocalFileSystem$create())
  # Object stores have no folders; a local file system needs them.
  fake_fs <- list(
    GetFileInfo = function(x) sub_fs$GetFileInfo(x),
    OpenInputStream = function(path) sub_fs$OpenInputStream(path),
    OpenInputFile = function(path) sub_fs$OpenInputFile(path),
    OpenOutputStream = function(path) {
      dir.create(dirname(file.path(dir, path)), recursive = TRUE, showWarnings = FALSE)
      sub_fs$OpenOutputStream(path)
    },
    DeleteFiles = function(paths) sub_fs$DeleteFiles(paths)
  )
  gcs_reset_clients()
  withr::defer(gcs_reset_clients(), envir = env)
  testthat::local_mocked_bindings(
    gcs_fs = function(be) fake_fs,
    gcs_fetch_token = function() "fake-token",
    gcs_perform = function(reqs) {
      lapply(reqs, function(req) {
        bucket <- sub("^.*/b/([^/]+)/o/.*$", "\\1", req$url)
        object <- utils::URLdecode(sub("^.*/o/([^?]+).*$", "\\1", req$url))
        file <- file.path(dir, bucket, object)
        code <- status %||% if (file.exists(file)) 200L else 404L
        body <- if (code == 200L && md5) {
          sprintf('{"md5Hash": "%s"}', md5_hex_to_base64(md5_file(file)))
        } else if (code == 200L) {
          "{}"
        } else {
          '{"error": {"message": "fake"}}'
        }
        httr2::response(
          status_code = code,
          url = req$url,
          headers = list(`Content-Type` = "application/json"),
          body = charToRaw(body)
        )
      })
    },
    .env = env
  )
  dir
}

local_src <- function(text = "some content", env = parent.frame()) {
  src <- withr::local_tempfile(.local_envir = env)
  writeLines(text, src)
  src
}

test_that("be_init() keeps a gcs backend offline and unchanged", {
  be <- be_new("gs://my-bucket/store")
  expect_named(be, c("type", "uri", "root", "bucket", "prefix"))
  expect_identical(be_init(be), be)
})

test_that("be_put(), be_get(), be_exists() and be_delete() go through Arrow", {
  dir <- local_fake_gcs()
  be <- be_new("gs://my-bucket/some/store")
  src <- local_src("remote content")
  expect_invisible(out <- be_put(be, src, "d/year=2024/part-a.parquet"))
  expect_identical(out, "d/year=2024/part-a.parquet")
  expect_true(file.exists(file.path(dir, "my-bucket/some/store/d/year=2024/part-a.parquet")))
  expect_identical(be_exists(be, c("d/year=2024/part-a.parquet", "d", "none")), c(TRUE, FALSE, FALSE))
  expect_identical(be_exists(be, character()), logical())

  dest <- file.path(withr::local_tempdir(), "sub", "a.parquet")
  expect_invisible(be_get(be, "d/year=2024/part-a.parquet", dest))
  expect_identical(readLines(dest), "remote content")
  expect_error(be_get(be, "none", dest), "does not exist", class = "rcs_error_backend")

  expect_invisible(be_delete(be, c("d/year=2024/part-a.parquet", "none")))
  expect_false(be_exists(be, "d/year=2024/part-a.parquet"))
  expect_identical(be_delete(be, character()), character())
  expect_error(be_put(be, file.path(dir, "nope"), "x"), class = "rcs_error_backend")
})

test_that("be_put() and be_get() stream large files in chunks", {
  local_fake_gcs()
  be <- be_new("gs://my-bucket")
  src <- withr::local_tempfile()
  writeBin(as.raw(rep(0:255, length.out = 20 * 1024^2 + 17)), src)
  be_put(be, src, "big.bin")
  dest <- withr::local_tempfile()
  be_get(be, "big.bin", dest)
  expect_identical(md5_file(dest), md5_file(src))
})

test_that("be_md5() reads md5Hash from the JSON API without downloading", {
  local_fake_gcs()
  be <- be_new("gs://my-bucket/store")
  src <- local_src("hash me")
  be_put(be, src, "a/one.txt")
  be_put(be, src, "a/year=a%20b/two three.txt")
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  expect_identical(
    be_md5(be, c("a/one.txt", "a/none.txt", "a/year=a%20b/two three.txt")),
    c(md5_file(src), NA, md5_file(src))
  )
  expect_identical(be_md5(be, "a/one.txt"), md5_file(src))
  tr <- rcs_trace()
  expect_false(any(tr$detail %in% "be_get"))
  expect_false(any(tr$counter == "bytes_down"))
  expect_identical(be_md5(be, character()), character())
})

test_that("be_md5() downloads and hashes objects without md5Hash", {
  local_fake_gcs(md5 = FALSE)
  be <- be_new("gs://my-bucket/store")
  src <- local_src("composite")
  be_put(be, src, "a.txt")
  expect_identical(be_md5(be, c("a.txt", "none")), c(md5_file(src), NA))
})

test_that("be_md5() aborts with the authentication hint on 401 and 403", {
  local_fake_gcs(status = 403L)
  be <- be_new("gs://my-bucket/store")
  err <- expect_error(be_md5(be, "a.txt"), "HTTP 403", class = "rcs_error_backend")
  expect_match(conditionMessage(err), "GOOGLE_APPLICATION_CREDENTIALS")
})

test_that("be_md5() aborts on other HTTP errors without the hint", {
  local_fake_gcs(status = 500L)
  be <- be_new("gs://my-bucket/store")
  err <- expect_error(be_md5(be, "a.txt"), "HTTP 500", class = "rcs_error_backend")
  expect_no_match(conditionMessage(err), "GOOGLE_APPLICATION_CREDENTIALS")
})

test_that("be_md5() aborts when the request itself fails", {
  local_fake_gcs()
  local_mocked_bindings(gcs_perform = function(reqs) {
    lapply(reqs, function(r) simpleError("Could not resolve host"))
  })
  be <- be_new("gs://my-bucket/store")
  expect_error(be_md5(be, c("a", "b")), "metadata", class = "rcs_error_backend")
})

test_that("be_list() lists files below a prefix, sorted, in UTC", {
  dir <- local_fake_gcs()
  be <- be_new("gs://my-bucket/store")
  be_put(be, local_src("bb"), "b/two.txt")
  be_put(be, local_src("a"), "a/one.txt")
  be_put(be, local_src("ccc"), "a/sub/three.txt")
  # a file of another location in the same bucket
  be_put(be_new("gs://my-bucket/other"), local_src(), "x.txt")

  all <- be_list(be)
  expect_named(all, c("path", "bytes", "modified"))
  expect_identical(all$path, c("a/one.txt", "a/sub/three.txt", "b/two.txt"))
  expect_identical(all$bytes, file.size(file.path(dir, "my-bucket/store", all$path)))
  expect_identical(attr(all$modified, "tzone"), "UTC")
  expect_true(all(abs(difftime(all$modified, Sys.time(), units = "mins")) < 5))
  expect_identical(be_list(be, "a/")$path, c("a/one.txt", "a/sub/three.txt"))
  expect_identical(be_list(be_new("gs://my-bucket"))$path[1:2], c("other/x.txt", "store/a/one.txt"))

  none <- be_list(be_new("gs://my-bucket/nothing"))
  expect_identical(nrow(none), 0L)
  expect_named(none, c("path", "bytes", "modified"))
  expect_s3_class(none$modified, "POSIXct")
})

test_that("be_arrow_fs() and be_gdal_path() address the location", {
  local_fake_gcs()
  be <- be_new("gs://my-bucket/some/store")
  afs <- be_arrow_fs(be)
  expect_identical(afs$path, "my-bucket/some/store")
  file <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(data.frame(x = 1:3), file)
  be_put(be, file, "t/part-a.parquet")
  input <- afs$fs$OpenInputFile(paste0(afs$path, "/t/part-a.parquet"))
  withr::defer(input$close())
  expect_identical(as.data.frame(arrow::read_parquet(input))$x, 1:3)

  expect_identical(
    be_gdal_path(be, c("r/part-a.tif", "b.tif")),
    c("/vsigs/my-bucket/some/store/r/part-a.tif", "/vsigs/my-bucket/some/store/b.tif")
  )
  expect_identical(be_gdal_path(be_new("gs://my-bucket"), "a.tif"), "/vsigs/my-bucket/a.tif")
  expect_identical(be_gdal_path(be, character()), character())
})

test_that("Arrow errors become rcs_error_backend, with the hint when it may be auth", {
  local_fake_gcs()
  be <- be_new("gs://my-bucket/store")
  failing <- function(...) stop("PERMISSION_DENIED: no access")
  fake <- list(
    GetFileInfo = failing, OpenInputStream = failing,
    OpenOutputStream = failing, DeleteFiles = failing
  )
  local_mocked_bindings(gcs_fs = function(be) fake)
  err <- expect_error(be_exists(be, "a"), "Looking up files", class = "rcs_error_backend")
  expect_match(conditionMessage(err), "gcloud auth application-default login")
  expect_error(be_put(be, local_src(), "a"), "Uploading", class = "rcs_error_backend")
  expect_error(be_list(be), "Listing", class = "rcs_error_backend")

  fake$GetFileInfo <- function(...) stop("connection reset")
  err <- expect_error(be_exists(be, "a"), class = "rcs_error_backend")
  expect_no_match(conditionMessage(err), "gcloud auth")
})

test_that("be_lock() and be_unlock() do nothing on gcs", {
  be <- be_new("gs://my-bucket/store")
  expect_true(be_lock(be))
  expect_true(be_unlock(be))
})

test_that("be_auth_hint() names each client", {
  hint <- be_auth_hint(be_new("gs://my-bucket/store"))
  expect_length(hint, 3)
  expect_named(hint, rep("i", 3))
  expect_match(hint[[1]], "Arrow")
  expect_match(hint[[2]], "JSON API")
  expect_match(hint[[3]], "GDAL")
  withr::local_options(cli.width = 1000)
  expect_snapshot(cli::cli_abort(c("Cannot reach the location.", hint)), error = TRUE)
})

test_that("gcs_fs() aborts when Arrow lacks GCS and caches the file system", {
  gcs_reset_clients()
  withr::defer(gcs_reset_clients())
  be <- be_new("gs://my-bucket")
  local_mocked_bindings(arrow_with_gcs = function() FALSE, .package = "arrow")
  expect_error(gcs_fs(be), "cannot reach Google Cloud Storage", class = "rcs_error_backend")
})

test_that("gcs_fs() creates the Arrow file system once", {
  skip_if_not(arrow::arrow_with_gcs())
  gcs_reset_clients()
  withr::defer(gcs_reset_clients())
  be <- be_new("gs://my-bucket")
  fs <- gcs_fs(be)
  expect_s3_class(fs, "GcsFileSystem")
  expect_identical(gcs_fs(be), fs)
})

test_that("gcs_token() fetches once, renews and aborts without credentials", {
  gcs_reset_clients()
  withr::defer(gcs_reset_clients())
  be <- be_new("gs://my-bucket")
  n <- 0
  local_mocked_bindings(gcs_fetch_token = function() {
    n <<- n + 1
    paste0("token-", n)
  })
  expect_identical(gcs_token(be), "token-1")
  expect_identical(gcs_token(be), "token-1")
  the_gcs$token_time <- Sys.time() - 3600
  expect_identical(gcs_token(be), "token-2")

  gcs_reset_clients()
  local_mocked_bindings(gcs_fetch_token = function() NULL)
  err <- expect_error(gcs_token(be), "No credentials", class = "rcs_error_backend")
  expect_match(conditionMessage(err), "GOOGLE_APPLICATION_CREDENTIALS")
  local_mocked_bindings(gcs_fetch_token = function() stop("refresh failed"))
  expect_error(gcs_token(be), "No credentials", class = "rcs_error_backend")

  local_mocked_bindings(gcs_clients_installed = function() FALSE)
  expect_error(gcs_token(be), "gargle", class = "rcs_error_backend")
})

test_that("gcs_fetch_token() asks gargle for the cloud-platform scope", {
  skip_if_not_installed("gargle")
  scopes <- NULL
  local_mocked_bindings(
    credentials_app_default = function(scopes, ...) {
      scopes <<- scopes
      NULL
    },
    .package = "gargle"
  )
  expect_null(gcs_fetch_token())
  expect_identical(scopes, "https://www.googleapis.com/auth/cloud-platform")
  local_mocked_bindings(
    credentials_app_default = function(scopes, ...) list(credentials = list(access_token = "abc")),
    .package = "gargle"
  )
  expect_identical(gcs_fetch_token(), "abc")
})

test_that("gcs_perform() sends one request alone and several in parallel", {
  skip_if_not_installed("httr2")
  local_mocked_bindings(
    req_perform = function(req, ...) "one",
    req_perform_parallel = function(reqs, ...) as.list(rep("many", length(reqs))),
    .package = "httr2"
  )
  expect_identical(gcs_perform(list(1)), list("one"))
  expect_identical(gcs_perform(list(1, 2)), list("many", "many"))
  local_mocked_bindings(req_perform = function(req, ...) stop("offline"), .package = "httr2")
  expect_s3_class(gcs_perform(list(1))[[1]], "error")
})

# Against the test bucket -----------------------------------------------------

# A backend under a random prefix of `RCS_TEST_GCS`, removed afterwards.
local_test_bucket <- function(env = parent.frame()) {
  skip_below_level("full")
  uri <- Sys.getenv("RCS_TEST_GCS")
  skip_if(!nzchar(uri), "RCS_TEST_GCS is not set.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  gcs_reset_clients()
  prefix <- paste0("rcs-test-", paste(sample(c(letters, 0:9), 12, TRUE), collapse = ""))
  be <- be_new(paste0(sub("/+$", "", uri), "/", prefix))
  withr::defer(
    {
      left <- be_list(be)$path
      if (length(left) > 0) be_delete(be, left)
    },
    envir = env
  )
  be
}

test_that("a file uploaded to the bucket reports its MD5 without a download", {
  be <- local_test_bucket()
  src <- withr::local_tempfile()
  writeBin(as.raw(sample(0:255, 3e5, TRUE)), src)
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  be_put(be, src, "d/year=2024/part-a.parquet")
  be_put(be, src, "d/year=a%20b/part b.parquet")
  expect_identical(
    be_md5(be, c("d/year=2024/part-a.parquet", "d/none", "d/year=a%20b/part b.parquet")),
    c(md5_file(src), NA, md5_file(src))
  )
  tr <- rcs_trace()
  expect_false(any(tr$detail %in% "be_get"))
  expect_false(any(tr$counter == "bytes_down"))

  expect_identical(be_exists(be, c("d/year=2024/part-a.parquet", "d", "none")), c(TRUE, FALSE, FALSE))
  listed <- be_list(be)
  expect_identical(listed$path, c("d/year=2024/part-a.parquet", "d/year=a%20b/part b.parquet"))
  expect_identical(listed$bytes, rep(as.numeric(file.size(src)), 2))

  dest <- withr::local_tempfile()
  be_get(be, "d/year=a%20b/part b.parquet", dest)
  expect_identical(md5_file(dest), md5_file(src))
  expect_error(be_get(be, "none", dest), class = "rcs_error_backend")

  be_delete(be, c("d/year=2024/part-a.parquet", "none"))
  expect_identical(be_list(be)$path, "d/year=a%20b/part b.parquet")
})

test_that("Arrow streams a Parquet file from the bucket", {
  be <- local_test_bucket()
  file <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(data.frame(x = 1:5), file)
  be_put(be, file, "t/part-a.parquet")
  afs <- be_arrow_fs(be)
  input <- afs$fs$OpenInputFile(paste0(afs$path, "/t/part-a.parquet"))
  withr::defer(input$close())
  expect_identical(as.data.frame(arrow::read_parquet(input))$x, 1:5)
})

test_that("GDAL reads a file from the bucket through /vsigs/", {
  be <- local_test_bucket()
  skip_if_not_installed("terra")
  # GDAL does not find gcloud's application-default credentials by itself
  # (see R/backend-gcs.R); point it at them as be_auth_hint() says.
  if (!nzchar(Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS"))) {
    adc <- file.path(
      if (.Platform$OS.type == "windows") Sys.getenv("APPDATA") else "~/.config",
      "gcloud", "application_default_credentials.json"
    )
    skip_if_not(file.exists(adc), "No credentials for GDAL.")
    withr::local_envvar(GOOGLE_APPLICATION_CREDENTIALS = adc)
  }
  tif <- withr::local_tempfile(fileext = ".tif")
  terra::writeRaster(terra::rast(nrows = 10, ncols = 10, vals = 1:100), tif)
  be_put(be, tif, "r/part-a.tif")
  r <- terra::rast(be_gdal_path(be, "r/part-a.tif"))
  expect_equal(sum(terra::values(r)), 5050)
})
