test_that("the backend is inferred from the address", {
  expect_identical(backend_type("gs://bucket/store"), "gcs")
  expect_identical(backend_type("GS://bucket"), "gcs")
  expect_identical(backend_type("~/data/store"), "local")
  expect_identical(backend_type("C:/data/store"), "local")
  expect_identical(backend_type("C:\\data\\store"), "local")
  expect_identical(backend_type("/data/store"), "local")
  expect_identical(backend_type("data/store"), "local")
})

test_that("other schemes are not supported yet", {
  for (uri in c("s3://bucket/store", "az://container", "https://host/store", "file:///data")) {
    expect_error(backend_type(uri), "not supported yet", class = "rcs_error_unsupported_location")
    expect_error(be_new(uri), "not supported yet", class = "rcs_error_unsupported_location")
  }
  expect_error(be_new(""), class = "rcs_error_argument")
  expect_error(be_new(NULL), class = "rcs_error_argument")
  expect_error(be_new(c("a", "b")), class = "rcs_error_argument")
})

test_that("be_new() describes a local location", {
  dir <- withr::local_tempdir()
  be <- be_new(file.path(dir, "store"))
  expect_s3_class(be, c("rcs_backend_local", "rcs_backend"), exact = TRUE)
  expect_named(be, c("type", "uri", "root", "bucket", "prefix"))
  expect_identical(be$type, "local")
  expect_identical(be$uri, be$root)
  expect_false(grepl("\\\\", be$uri))
  expect_false(grepl("/$", be$uri))
  expect_identical(basename(be$uri), "store")
  expect_true(is.na(be$bucket))
  expect_true(is.na(be$prefix))
  # nothing is created
  expect_false(dir.exists(be$root))
})

test_that("two spellings of one local folder give one address", {
  dir <- withr::local_tempdir()
  plain <- be_new(file.path(dir, "store"))
  expect_identical(be_new(paste0(file.path(dir, "store"), "/"))$uri, plain$uri)
  expect_identical(be_new(file.path(dir, ".", "store"))$uri, plain$uri)
  withr::local_dir(dir)
  expect_identical(be_new("store")$uri, plain$uri)
  expect_false(startsWith(be_new("~/rcs-store")$uri, "~"))
})

test_that("be_new() describes a bucket with and without a prefix", {
  be <- be_new("gs://my-bucket/some/prefix/")
  expect_s3_class(be, c("rcs_backend_gcs", "rcs_backend"), exact = TRUE)
  expect_identical(be$type, "gcs")
  expect_identical(be$uri, "gs://my-bucket/some/prefix")
  expect_identical(be$root, "my-bucket/some/prefix")
  expect_identical(be$bucket, "my-bucket")
  expect_identical(be$prefix, "some/prefix")

  bare <- be_new("gs://my-bucket")
  expect_identical(bare$uri, "gs://my-bucket")
  expect_identical(bare$bucket, "my-bucket")
  expect_identical(bare$prefix, "")
  expect_identical(be_new("gs://my-bucket//a//b")$uri, "gs://my-bucket/a/b")
  expect_error(be_new("gs://"), "no bucket", class = "rcs_error_argument")
})

test_that("be_new() passes the object through be_init()", {
  local_mocked_s3_method("be_init", "rcs_backend_gcs", function(be) {
    be$checked <- TRUE
    be
  })
  expect_true(be_new("gs://my-bucket")$checked)
  expect_null(be_new(withr::local_tempdir())$checked)
})

test_that("a generic without a method aborts as not implemented", {
  be <- structure(
    list(type = "none", uri = "none", root = "none"),
    class = c("rcs_backend_none", "rcs_backend")
  )
  expect_error(be_arrow_fs(be), "rcs_backend_none", class = "rcs_error_not_implemented")
  expect_error(be_gdal_path(be, "a"), class = "rcs_error_not_implemented")
  expect_error(be_get(be, "a", tempfile()), class = "rcs_error_not_implemented")
  expect_error(be_put(be, tempfile(), "a"), class = "rcs_error_not_implemented")
  expect_error(be_delete(be, "a"), class = "rcs_error_not_implemented")
  expect_error(be_md5(be, "a"), class = "rcs_error_not_implemented")
  expect_error(be_list(be), class = "rcs_error_not_implemented")
  expect_error(be_exists(be, "a"), class = "rcs_error_not_implemented")
  expect_error(be_auth_hint(be), class = "rcs_error_not_implemented")
})

test_that("locking does nothing unless a backend implements it", {
  be <- structure(
    list(type = "none", uri = "none", root = "none"),
    class = c("rcs_backend_none", "rcs_backend")
  )
  expect_true(be_lock(be))
  expect_invisible(be_lock(be))
  expect_true(be_unlock(be))
  expect_invisible(be_unlock(be))
})

test_that("the generics have the signatures of the contract", {
  signatures <- list(
    be_init = "be",
    be_arrow_fs = "be",
    be_gdal_path = c("be", "path"),
    be_get = c("be", "path", "dest"),
    be_put = c("be", "src", "path"),
    be_delete = c("be", "paths"),
    be_md5 = c("be", "paths"),
    be_list = c("be", "prefix"),
    be_exists = c("be", "paths"),
    be_auth_hint = "be",
    be_lock = c("be", "timeout"),
    be_unlock = "be"
  )
  for (name in names(signatures)) {
    expect_identical(names(formals(get(name))), signatures[[name]], info = name)
  }
})
