# A backend stub for failure tests: it wraps the `local` backend, counts the
# backend calls made through it and, on chosen calls, fails or silently
# corrupts a file. Used by the crash-point matrix, the transient-failure tests
# and the "upload silently alters a file" test (work packages E and G).
#
# Start it inside a test (or a function called by one) with
#
#   stub <- local_backend_stub(
#     uri = NULL,        # local addresses whose `be_new()` returns a stub
#     fail_at = NULL,    # numbers of the matching calls that fail
#     generic = NULL,    # generics that count as matching (NULL: all)
#     path = NULL,       # regular expression on the call's path(s) (NULL: any)
#     mode = "error",    # "error" or "corrupt"
#     when = "before"    # "before" or "after" the real operation (mode "error")
#   )
#
# It registers the stub's methods (class `rcs_backend_stub`) for the rest of
# the calling test, through `testthat::local_mocked_s3_method()`: a method for
# an internal generic defined in a test file is not found by dispatch
# otherwise. With `uri`, `be_new()` (and so `store_connect()`) returns a stub
# for those addresses; `stub_backend(be, stub)` wraps an existing local
# backend object explicitly (e.g. `location$backend`).
#
# The returned `stub` is an environment; its fields can be read and changed
# between calls:
#
#   stub$calls      number of backend calls made through any stub of it
#   stub$matched    number of calls that matched `generic` and `path`
#   stub$log        data frame of the calls: `n`, `generic`, `path`, `failed`
#   stub$fail_at, stub$generic, stub$path, stub$mode, stub$when
#   stub_reset(stub) sets the counters and the log back to zero
#
# A call matches when its generic is in `generic` and, if `path` is given,
# one of its paths matches `path`; matching calls are numbered 1, 2, ...
# A matching call whose number is in `fail_at`:
#   * mode "error", when "before": aborts with class
#     `c("rcs_error_stub", "rcs_error_backend")` without doing anything;
#   * mode "error", when "after": does the operation, then aborts the same way
#     (the work happened, the caller does not know it);
#   * mode "corrupt": does the operation and then flips one byte of the file
#     written: the stored file for `be_put()`, `dest` for `be_get()`. Only
#     these two generics can corrupt.
#
# Counting: the generics count `backend_call` in the work counters
# themselves; the stub's methods never call `trace_count()`, so the counters
# are the same with and without a stub. `be_init()` and `be_auth_hint()` are
# not stubbed and not counted.
#
# Recipes:
#
#   # Crash-point matrix: learn N, then fail at each call.
#   stub <- local_backend_stub(uri = primary)
#   run_operation()
#   n <- stub$calls
#   for (k in seq_len(n)) {
#     reset_fixture()
#     stub_reset(stub); stub$fail_at <- k
#     expect_error(run_operation(), class = "rcs_error_stub")
#     stub$fail_at <- NULL
#     expect_store_valid(st)
#   }
#
#   # Transient failure: the first two uploads of one file fail.
#   local_backend_stub(uri = primary, generic = "be_put", path = "part-", fail_at = 1:2)
#
#   # An upload that silently alters a file.
#   local_backend_stub(uri = primary, generic = "be_put", path = "part-",
#                      fail_at = 1, mode = "corrupt")

stub_generics <- c(
  "be_arrow_fs", "be_gdal_path", "be_get", "be_put", "be_delete", "be_md5",
  "be_list", "be_exists", "be_lock", "be_unlock"
)

local_backend_stub <- function(uri = NULL, fail_at = NULL, generic = NULL, path = NULL,
                               mode = c("error", "corrupt"), when = c("before", "after"),
                               .local_envir = parent.frame()) {
  mode <- match.arg(mode)
  when <- match.arg(when)
  generic <- generic %||% stub_generics
  stopifnot(all(generic %in% stub_generics))
  if (mode == "corrupt" && !all(generic %in% c("be_put", "be_get"))) {
    stop("mode = \"corrupt\" needs `generic` to be \"be_put\" and/or \"be_get\".", call. = FALSE)
  }
  stub <- new.env(parent = emptyenv())
  stub$fail_at <- fail_at
  stub$generic <- generic
  stub$path <- path
  stub$mode <- mode
  stub$when <- when
  stub$uris <- if (length(uri) > 0) vapply(uri, function(u) be_new(u)$uri, character(1)) else character()
  stub_reset(stub)

  for (g in stub_generics) {
    testthat::local_mocked_s3_method(g, "rcs_backend_stub", stub_method(g), frame = .local_envir)
  }
  if (length(stub$uris) > 0) {
    testthat::local_mocked_s3_method(
      "be_init", "rcs_backend_local",
      function(be) if (be$uri %in% stub$uris) stub_backend(be, stub) else be,
      frame = .local_envir
    )
  }
  stub
}

stub_reset <- function(stub) {
  stub$calls <- 0L
  stub$matched <- 0L
  stub$log <- data.frame(n = integer(), generic = character(), path = character(), failed = logical())
  invisible(stub)
}

# Wrap a local backend object.
stub_backend <- function(be, stub) {
  stopifnot(inherits(be, "rcs_backend_local"), !inherits(be, "rcs_backend_stub"))
  be$stub <- stub
  class(be) <- c("rcs_backend_stub", class(be))
  be
}

stub_inner <- function(be) {
  be$stub <- NULL
  class(be) <- setdiff(class(be), "rcs_backend_stub")
  be
}

# A method with the generic's formals that hands over to `stub_call()`.
stub_method <- function(generic) {
  switch(generic,
    be_arrow_fs = function(be) stub_call(be, generic, list()),
    be_gdal_path = function(be, path) stub_call(be, generic, list(path = path), path),
    be_get = function(be, path, dest) stub_call(be, generic, list(path = path, dest = dest), path),
    be_put = function(be, src, path) stub_call(be, generic, list(src = src, path = path), path),
    be_delete = function(be, paths) stub_call(be, generic, list(paths = paths), paths),
    be_md5 = function(be, paths) stub_call(be, generic, list(paths = paths), paths),
    be_list = function(be, prefix = "") stub_call(be, generic, list(prefix = prefix), prefix),
    be_exists = function(be, paths) stub_call(be, generic, list(paths = paths), paths),
    be_lock = function(be, timeout = rcs_option("rcs.lock_timeout")) {
      stub_call(be, generic, list(timeout = timeout))
    },
    be_unlock = function(be) stub_call(be, generic, list())
  )
}

stub_call <- function(be, generic, args, paths = character()) {
  stub <- be$stub
  stub$calls <- stub$calls + 1L
  matches <- generic %in% stub$generic &&
    (is.null(stub$path) || any(grepl(stub$path, paths)))
  fail <- FALSE
  if (matches) {
    stub$matched <- stub$matched + 1L
    fail <- stub$matched %in% stub$fail_at
  }
  stub$log[nrow(stub$log) + 1L, ] <- list(
    stub$calls, generic, paste(paths, collapse = ";"), fail
  )
  abort_stub <- function() {
    cli::cli_abort(
      "Injected failure at backend call {stub$calls} ({generic}).",
      class = c("rcs_error_stub", "rcs_error_backend")
    )
  }
  if (fail && stub$mode == "error" && stub$when == "before") {
    abort_stub()
  }
  inner <- stub_inner(be)
  method <- utils::getS3method(generic, "rcs_backend_local", envir = environment(be_put))
  out <- do.call(method, c(list(inner), args))
  if (fail && stub$mode == "corrupt") {
    target <- if (generic == "be_put") paste0(inner$root, "/", args$path) else args$dest
    stub_flip_byte(target)
  } else if (fail) {
    abort_stub()
  }
  out
}

# Flip the bits of the middle byte of a file (or append one to an empty file).
stub_flip_byte <- function(file) {
  bytes <- readBin(file, "raw", file.size(file))
  if (length(bytes) == 0) {
    bytes <- as.raw(0)
  } else {
    i <- (length(bytes) + 1L) %/% 2L
    bytes[i] <- xor(bytes[i], as.raw(0xff))
  }
  writeBin(bytes, file)
  invisible(file)
}
