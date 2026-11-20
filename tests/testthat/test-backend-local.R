local_be <- function(env = parent.frame()) {
  be_new(file.path(withr::local_tempdir(.local_envir = env), "store"))
}

local_src <- function(text = "some content", env = parent.frame()) {
  src <- withr::local_tempfile(.local_envir = env)
  writeLines(text, src)
  src
}

test_that("be_put() writes a file, creates folders and replaces", {
  be <- local_be()
  src <- local_src("first")
  expect_invisible(out <- be_put(be, src, "sales/daily/year=2024/part-a.parquet"))
  expect_identical(out, "sales/daily/year=2024/part-a.parquet")
  target <- file.path(be$root, "sales/daily/year=2024/part-a.parquet")
  expect_identical(readLines(target), "first")

  writeLines("second", src)
  be_put(be, src, "sales/daily/year=2024/part-a.parquet")
  expect_identical(readLines(target), "second")
  # no temporary file is left behind
  expect_identical(
    list.files(be$root, recursive = TRUE, all.files = TRUE),
    "sales/daily/year=2024/part-a.parquet"
  )
})

test_that("be_put() aborts for a missing source", {
  be <- local_be()
  expect_error(be_put(be, file.path(be$root, "nope"), "a.txt"), class = "rcs_error_backend")
  expect_error(be_put(be, withr::local_tempdir(), "a.txt"), class = "rcs_error_backend")
})

test_that("be_get() copies a file to a new folder and replaces", {
  be <- local_be()
  be_put(be, local_src("stored"), "a/b.txt")
  dest <- file.path(withr::local_tempdir(), "new", "folder", "b.txt")
  expect_invisible(out <- be_get(be, "a/b.txt", dest))
  expect_identical(out, dest)
  expect_identical(readLines(dest), "stored")
  writeLines("old", dest)
  be_get(be, "a/b.txt", dest)
  expect_identical(readLines(dest), "stored")
})

test_that("be_get() aborts for a missing file or a folder", {
  be <- local_be()
  be_put(be, local_src(), "a/b.txt")
  dest <- withr::local_tempfile()
  expect_error(be_get(be, "a/none.txt", dest), "does not exist", class = "rcs_error_backend")
  expect_error(be_get(be, "a", dest), class = "rcs_error_backend")
})

test_that("be_md5() hashes stored files and gives NA for missing ones", {
  be <- local_be()
  src <- local_src("hash me")
  be_put(be, src, "x/one.txt")
  expected <- digest::digest(src, algo = "md5", file = TRUE)
  expect_identical(be_md5(be, c("x/one.txt", "x/none.txt", "x")), c(expected, NA, NA))
  expect_identical(be_md5(be, character()), character())
})

test_that("be_exists() is TRUE for files only", {
  be <- local_be()
  be_put(be, local_src(), "x/one.txt")
  expect_identical(be_exists(be, c("x/one.txt", "x", "y.txt")), c(TRUE, FALSE, FALSE))
  expect_identical(be_exists(be, character()), logical())
})

test_that("be_delete() removes files, skips missing ones and prunes empty folders", {
  be <- local_be()
  src <- local_src()
  be_put(be, src, "d/p=1/part-a.parquet")
  be_put(be, src, "d/p=2/part-a.parquet")
  be_put(be, src, "_catalog.parquet")
  expect_invisible(be_delete(be, c("d/p=1/part-a.parquet", "d/none.parquet", "zz/none")))
  expect_false(dir.exists(file.path(be$root, "d/p=1")))
  expect_true(be_exists(be, "d/p=2/part-a.parquet"))

  be_delete(be, "d/p=2/part-a.parquet")
  expect_false(dir.exists(file.path(be$root, "d")))
  # the root stays, with what else it holds
  expect_true(dir.exists(be$root))
  expect_true(be_exists(be, "_catalog.parquet"))
  be_delete(be, "_catalog.parquet")
  expect_true(dir.exists(be$root))
  expect_identical(be_delete(be, character()), character())
})

test_that("be_list() lists files recursively, sorted, with sizes and UTC times", {
  be <- local_be()
  be_put(be, local_src("bb"), "b/two.txt")
  be_put(be, local_src("a"), "a/one.txt")
  be_put(be, local_src("ccc"), "a/sub/three.txt")
  be_put(be, local_src(), "_catalog.parquet")

  all <- be_list(be)
  expect_s3_class(all, "tbl_df")
  expect_named(all, c("path", "bytes", "modified"))
  expect_identical(all$path, c("_catalog.parquet", "a/one.txt", "a/sub/three.txt", "b/two.txt"))
  expect_type(all$bytes, "double")
  expect_identical(all$bytes[2:4], file.size(file.path(be$root, all$path[2:4])))
  expect_s3_class(all$modified, "POSIXct")
  expect_identical(attr(all$modified, "tzone"), "UTC")
  expect_true(all(abs(difftime(all$modified, Sys.time(), units = "mins")) < 5))

  expect_identical(be_list(be, "a")$path, c("a/one.txt", "a/sub/three.txt"))
  expect_identical(be_list(be, "a/")$path, c("a/one.txt", "a/sub/three.txt"))
  expect_identical(nrow(be_list(be, "none")), 0L)
})

test_that("be_list() gives zero rows for a location that does not exist", {
  be <- local_be()
  out <- be_list(be)
  expect_identical(nrow(out), 0L)
  expect_named(out, c("path", "bytes", "modified"))
  expect_s3_class(out$modified, "POSIXct")
})

test_that("be_arrow_fs() opens files of the location", {
  be <- local_be()
  file <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(data.frame(x = 1:3), file)
  be_put(be, file, "t/part-a.parquet")
  afs <- be_arrow_fs(be)
  expect_s3_class(afs$fs, "FileSystem")
  expect_identical(afs$path, be$root)
  input <- afs$fs$OpenInputFile(paste0(afs$path, "/t/part-a.parquet"))
  withr::defer(input$close())
  expect_identical(as.data.frame(arrow::read_parquet(input))$x, 1:3)
})

test_that("be_gdal_path() gives local paths", {
  be <- local_be()
  expect_identical(be_gdal_path(be, c("r/part-a.tif", "b.tif")), paste0(be$root, c("/r/part-a.tif", "/b.tif")))
  expect_identical(be_gdal_path(be, character()), character())
})

test_that("be_auth_hint() gives one bullet", {
  be <- local_be()
  hint <- be_auth_hint(be)
  expect_type(hint, "character")
  expect_named(hint, "i")
  expect_match(hint, "permission")
  # ready for cli_abort(), also for an address with braces
  odd <- be_new(file.path(withr::local_tempdir(), "a{b}"))
  err <- expect_error(cli::cli_abort(c("Failed.", be_auth_hint(odd))))
  expect_match(conditionMessage(err), "a{b}", fixed = TRUE)
})

test_that("the generics count calls and bytes", {
  be <- local_be()
  src <- local_src("count these bytes")
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  be_put(be, src, "a.txt")
  be_get(be, "a.txt", withr::local_tempfile())
  be_md5(be, "a.txt")
  tr <- rcs_trace()
  calls <- tr[tr$counter == "backend_call", ]
  expect_setequal(calls$detail, c("be_put", "be_get", "be_md5"))
  expect_true(all(calls$n == 1))
  expect_true(all(calls$location == be$uri))
  expect_identical(tr$n[tr$counter == "bytes_up"], as.numeric(file.size(src)))
  expect_identical(tr$n[tr$counter == "bytes_down"], as.numeric(file.size(src)))
})

# Lock ------------------------------------------------------------------------

test_that("be_lock() takes the lock and be_unlock() releases it", {
  be <- local_be()
  dir.create(be$root)
  expect_invisible(expect_true(be_lock(be)))
  lock <- file.path(be$root, "_lock")
  expect_true(dir.exists(lock))
  taken <- time_from_text(readLines(file.path(lock, "time")))
  expect_lt(abs(as.numeric(difftime(taken, Sys.time(), units = "secs"))), 60)

  expect_invisible(expect_true(be_unlock(be)))
  expect_false(dir.exists(lock))
  # safe without a lock
  expect_true(be_unlock(be))
  expect_true(be_lock(be))
  be_unlock(be)
})

test_that("a fresh lock blocks another writer", {
  be <- local_be()
  dir.create(be$root)
  be_lock(be)
  withr::defer(be_unlock(be))
  expect_error(be_lock(be), "Another writer", class = "rcs_error_locked")
  expect_error(be_lock(be, timeout = 3600), class = "rcs_error_locked")
  withr::local_options(cli.width = 1000)
  expect_snapshot(be_lock(be), error = TRUE, transform = function(x) {
    x <- gsub(be$root, "<root>", x, fixed = TRUE)
    gsub("taken [0-9]+ seconds? ago", "taken <n> seconds ago", x)
  })
})

test_that("a stale lock is taken over with a warning", {
  be <- local_be()
  dir.create(file.path(be$root, "_lock"), recursive = TRUE)
  writeLines(time_to_text(now_utc() - 1000), file.path(be$root, "_lock", "time"))
  expect_warning(be_lock(be, timeout = 600), "stale lock", class = "rcs_warning_lock_stale")
  # the lock now carries the new time and blocks
  taken <- time_from_text(readLines(file.path(be$root, "_lock", "time")))
  expect_lt(abs(as.numeric(difftime(taken, Sys.time(), units = "secs"))), 60)
  expect_error(be_lock(be, timeout = 600), class = "rcs_error_locked")
  be_unlock(be)
})

test_that("the lock timeout comes from the option rcs.lock_timeout", {
  be <- local_be()
  dir.create(file.path(be$root, "_lock"), recursive = TRUE)
  writeLines(time_to_text(now_utc() - 100), file.path(be$root, "_lock", "time"))
  expect_error(be_lock(be), class = "rcs_error_locked")
  withr::local_options(rcs.lock_timeout = 10)
  expect_warning(be_lock(be), class = "rcs_warning_lock_stale")
  be_unlock(be)
})

test_that("a lock without its time file is aged by the folder", {
  be <- local_be()
  dir.create(file.path(be$root, "_lock"), recursive = TRUE)
  expect_error(be_lock(be), class = "rcs_error_locked")
  Sys.setFileTime(file.path(be$root, "_lock"), Sys.time() - 2000)
  expect_warning(be_lock(be, timeout = 600), class = "rcs_warning_lock_stale")
  be_unlock(be)
})

test_that("be_lock() checks its arguments and the folder", {
  be <- local_be()
  expect_error(be_lock(be), "does not exist", class = "rcs_error_backend")
  dir.create(be$root)
  expect_error(be_lock(be, timeout = -1), class = "rcs_error_argument")
  expect_error(be_lock(be, timeout = "a"), class = "rcs_error_argument")
  expect_error(be_lock(be, timeout = c(1, 2)), class = "rcs_error_argument")
  expect_false(dir.exists(file.path(be$root, "_lock")))
})

# Backend stub (tests/testthat/helper-backend-stub.R) ------------------------

test_that("the stub counts calls and passes them to the local backend", {
  be <- local_be()
  stub <- local_backend_stub()
  sb <- stub_backend(be, stub)
  expect_s3_class(sb, c("rcs_backend_stub", "rcs_backend_local", "rcs_backend"), exact = TRUE)
  src <- local_src("through the stub")
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  be_put(sb, src, "a/b.txt")
  expect_identical(be_md5(sb, "a/b.txt"), md5_file(src))
  expect_true(be_exists(sb, "a/b.txt"))
  expect_identical(be_list(sb)$path, "a/b.txt")
  dest <- withr::local_tempfile()
  be_get(sb, "a/b.txt", dest)
  expect_identical(readLines(dest), "through the stub")
  expect_identical(be_gdal_path(sb, "a/b.txt"), paste0(be$root, "/a/b.txt"))
  expect_identical(be_arrow_fs(sb)$path, be$root)
  expect_true(be_lock(sb))
  expect_true(be_unlock(sb))
  be_delete(sb, "a/b.txt")
  expect_false(be_exists(be, "a/b.txt"))

  expect_identical(stub$calls, 10L)
  expect_identical(stub$log$generic[1:3], c("be_put", "be_md5", "be_exists"))
  expect_identical(stub$log$path[1], "a/b.txt")
  expect_false(any(stub$log$failed))
  # the work counters count each call once, as without a stub (10 through
  # the stub, one more on the plain backend)
  tr <- rcs_trace()
  expect_identical(sum(tr$n[tr$counter == "backend_call"]), 11)

  stub_reset(stub)
  expect_identical(stub$calls, 0L)
  expect_identical(nrow(stub$log), 0L)
})

test_that("the stub fails on a chosen call, before or after the operation", {
  be <- local_be()
  stub <- local_backend_stub(fail_at = 2)
  sb <- stub_backend(be, stub)
  src <- local_src()
  be_put(sb, src, "one.txt")
  expect_error(be_put(sb, src, "two.txt"), "call 2", class = "rcs_error_stub")
  expect_error(be_put(sb, src, "two.txt"), NA)
  expect_identical(be_list(be)$path, c("one.txt", "two.txt"))

  stub_reset(stub)
  stub$when <- "after"
  be_delete(sb, "one.txt")
  expect_error(be_delete(sb, "two.txt"), class = "rcs_error_backend")
  expect_false(be_exists(be, "two.txt"))
  expect_identical(stub$log$failed, c(FALSE, TRUE))
})

test_that("the stub fails the first attempts of one file only", {
  be <- local_be()
  stub <- local_backend_stub(generic = "be_put", path = "part-b", fail_at = 1:2)
  sb <- stub_backend(be, stub)
  src <- local_src()
  be_put(sb, src, "d/part-a.parquet")
  expect_error(be_put(sb, src, "d/part-b.parquet"), class = "rcs_error_stub")
  be_md5(sb, "d/part-b.parquet")
  expect_error(be_put(sb, src, "d/part-b.parquet"), class = "rcs_error_stub")
  expect_error(be_put(sb, src, "d/part-b.parquet"), NA)
  expect_identical(stub$calls, 5L)
  expect_identical(stub$matched, 3L)
})

test_that("the stub can corrupt an upload or a download silently", {
  be <- local_be()
  stub <- local_backend_stub(generic = "be_put", fail_at = 1, mode = "corrupt")
  sb <- stub_backend(be, stub)
  src <- local_src("payload")
  expect_error(be_put(sb, src, "a.txt"), NA)
  expect_false(identical(be_md5(be, "a.txt"), md5_file(src)))
  be_put(sb, src, "a.txt")
  expect_identical(be_md5(be, "a.txt"), md5_file(src))

  stub2 <- local_backend_stub(generic = "be_get", fail_at = 1, mode = "corrupt")
  sb2 <- stub_backend(be, stub2)
  dest <- withr::local_tempfile()
  be_get(sb2, "a.txt", dest)
  expect_false(identical(md5_file(dest), md5_file(src)))

  empty <- withr::local_tempfile()
  file.create(empty)
  stub_flip_byte(empty)
  expect_identical(file.size(empty), 1)
  expect_error(local_backend_stub(mode = "corrupt"), "corrupt")
})

test_that("with uri, be_new() returns stubs for those addresses only", {
  dir <- withr::local_tempdir()
  primary <- file.path(dir, "primary")
  other <- file.path(dir, "other")
  stub <- local_backend_stub(uri = primary)
  expect_s3_class(be_new(primary), "rcs_backend_stub")
  expect_s3_class(be_new(paste0(primary, "/")), "rcs_backend_stub")
  expect_false(inherits(be_new(other), "rcs_backend_stub"))
  loc <- new_location(primary)
  be_put(loc$backend, local_src(), "x.txt")
  expect_identical(stub$calls, 1L)
})
