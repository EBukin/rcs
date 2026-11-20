local_tracing <- function(frame = parent.frame()) {
  withr::local_options(rcs.trace = TRUE, .local_envir = frame)
  rcs_trace_reset()
  withr::defer(rcs_trace_reset(), envir = frame)
}

traced <- function(fn, code) {
  local_trace(fn)
  code
}

test_that("nothing is recorded when tracing is off", {
  withr::local_options(rcs.trace = NULL)
  rcs_trace_reset()
  traced("store_read", trace_count("file_open", detail = "a.parquet"))
  expect_equal(nrow(rcs_trace()), 0)
  expect_identical(the_trace$depth, 0L)
  # not even the counter name is looked at
  expect_no_error(trace_count("no_such_counter"))
})

test_that("rcs_trace() has its columns when empty", {
  local_tracing()
  out <- rcs_trace()
  expect_s3_class(out, "tbl_df")
  expect_named(out, c("call", "counter", "detail", "location", "n"))
  expect_equal(nrow(out), 0)
  expect_identical(
    vapply(out, typeof, character(1)),
    c(call = "character", counter = "character", detail = "character", location = "character", n = "double")
  )
})

test_that("counts add up per counter, detail and location", {
  local_tracing()
  traced("store_read", {
    trace_count("file_open", location = "loc-a", detail = "a.parquet")
    trace_count("file_open", location = "loc-a", detail = "a.parquet")
    trace_count("file_open", location = "loc-b", detail = "a.parquet")
    trace_count("rows_returned", 40)
    trace_count("rows_returned", 2)
    trace_count("bytes_down", bit64::as.integer64(1000), location = "loc-a")
  })
  out <- rcs_trace()
  expect_identical(unique(out$call), "store_read")
  expect_identical(out$counter, c("file_open", "file_open", "rows_returned", "bytes_down"))
  expect_identical(out$location, c("loc-a", "loc-b", NA, "loc-a"))
  expect_identical(out$n, c(2, 1, 42, 1000))
  expect_identical(out$detail, c("a.parquet", "a.parquet", NA, NA))
})

test_that("rows come in the order of the counters", {
  local_tracing()
  traced("store_write", {
    trace_count("bytes_up", 5)
    trace_count("rows_candidate", 5)
    trace_count("catalog_read", detail = "_catalog.parquet")
    trace_count("backend_call", detail = "be_put")
  })
  expect_identical(
    rcs_trace()$counter,
    c("backend_call", "catalog_read", "rows_candidate", "bytes_up")
  )
})

test_that("a new call replaces the records of the previous one", {
  local_tracing()
  traced("store_read", trace_count("file_open", detail = "a"))
  traced("store_datasets", trace_count("catalog_read", detail = "_catalog.parquet"))
  out <- rcs_trace()
  expect_identical(out$call, "store_datasets")
  expect_identical(out$counter, "catalog_read")

  traced("print", NULL)
  expect_equal(nrow(rcs_trace()), 0)
})

test_that("nested calls add to the outermost call", {
  local_tracing()
  inner <- function() {
    local_trace("store_check")
    trace_count("file_open", detail = "b")
  }
  outer <- function() {
    local_trace("store_write")
    trace_count("file_open", detail = "a")
    inner()
    expect_identical(the_trace$depth, 1L)
    trace_count("bytes_up", 10)
  }
  outer()
  out <- rcs_trace()
  expect_identical(unique(out$call), "store_write")
  expect_identical(out$n[out$counter == "file_open"], c(1, 1))
  expect_identical(out$n[out$counter == "bytes_up"], 10)
  expect_identical(the_trace$depth, 0L)
})

test_that("the trace ends when the call fails", {
  local_tracing()
  failing <- function() {
    local_trace("store_write")
    trace_count("bytes_up", 3)
    cli::cli_abort("stop here")
  }
  expect_error(failing(), "stop here")
  expect_identical(the_trace$depth, 0L)
  expect_identical(rcs_trace()$n, 3)
  traced("store_read", NULL)
  expect_equal(nrow(rcs_trace()), 0)
})

test_that("work outside a call is recorded without a call name", {
  local_tracing()
  trace_count("file_open", detail = "a")
  out <- rcs_trace()
  expect_true(is.na(out$call))
  expect_identical(out$n, 1)
})

test_that("missing and empty counts add nothing; unknown counters abort", {
  local_tracing()
  trace_count("bytes_down", NA)
  trace_count("bytes_down", numeric())
  expect_equal(nrow(rcs_trace()), 0)
  expect_error(trace_count("no_such_counter"), "Unknown work counter")
})

test_that("rcs_trace_reset() clears everything", {
  local_tracing()
  traced("store_read", trace_count("file_open", detail = "a"))
  expect_null(rcs_trace_reset())
  expect_invisible(rcs_trace_reset())
  expect_equal(nrow(rcs_trace()), 0)
  trace_count("file_open", detail = "a")
  expect_true(is.na(rcs_trace()$call))
})

test_that("backend generics count themselves and the bytes they move", {
  local_tracing()
  be <- structure(
    list(type = "test", uri = "test://store", root = "store"),
    class = c("rcs_backend_test", "rcs_backend")
  )
  local_mocked_s3_method("be_exists", "rcs_backend_test", function(be, paths) rep(TRUE, length(paths)))
  local_mocked_s3_method("be_put", "rcs_backend_test", function(be, src, path) invisible(path))
  local_mocked_s3_method("be_get", "rcs_backend_test", function(be, path, dest) {
    writeBin(as.raw(1:7), dest)
    invisible(dest)
  })
  src <- withr::local_tempfile()
  writeBin(as.raw(1:10), src)
  dest <- withr::local_tempfile()

  traced("store_write", {
    expect_identical(be_exists(be, c("a", "b")), c(TRUE, TRUE))
    be_exists(be, "c")
    be_put(be, src, "a")
    be_get(be, "a", dest)
    be_lock(be)
    be_unlock(be)
  })
  out <- rcs_trace()
  calls <- out[out$counter == "backend_call", ]
  expect_identical(calls$detail, c("be_exists", "be_get", "be_lock", "be_put", "be_unlock"))
  expect_identical(calls$n, c(2, 1, 1, 1, 1))
  expect_identical(unique(out$location), "test://store")
  expect_identical(out$n[out$counter == "bytes_up"], 10)
  expect_identical(out$n[out$counter == "bytes_down"], 7)
})

test_that("a failed download counts the call and no bytes", {
  local_tracing()
  be <- structure(list(type = "local", uri = "x", root = "x"), class = c("rcs_backend_none", "rcs_backend"))
  dest <- file.path(withr::local_tempdir(), "missing")
  expect_error(be_get(be, "a", dest), class = "rcs_error_not_implemented")
  out <- rcs_trace()
  expect_identical(out$counter, "backend_call")
})
