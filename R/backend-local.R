# Backend `local`: a folder on a file system the session can reach.
#
# Methods of the generics in `R/backend.R` for class `rcs_backend_local`.
# `be_init()` uses the default method: parsing in `be_new()` is all a local
# location needs, and the folder may not exist yet. Keep it that way: the
# backend stub of the tests (`helper-backend-stub.R`) mocks
# `be_init.rcs_backend_local`, and a method defined here would be found
# before the mock.
#
#   * Streaming reads: Arrow `LocalFileSystem`.
#   * Transfers: `be_put()` copies to a temporary name in the target folder
#     (`.<name>.tmp-<random>`) and renames, so a reader never sees a partial
#     file; a temporary file left by a crash is an orphan for `store_prune()`.
#   * MD5: hashed from the file on disk (`md5_file()`).
#   * Lock: the folder `_lock` at the location root, created with
#     `dir.create()` (atomic), holding the file `_lock/time` with the time it
#     was taken (`time_to_text()`). `be_list()` reports that file like any
#     other; callers skip root entries whose name starts with `_`.
#   * Credentials: none; the operating system's file permissions apply.

local_path <- function(be, path) {
  if (length(path) == 0) {
    return(character())
  }
  paste0(be$root, "/", path)
}

abort_local <- function(message, ..., parent = NULL, call = caller_env(), .envir = parent.frame()) {
  cli::cli_abort(
    message, ...,
    class = "rcs_error_backend", parent = parent, call = call, .envir = .envir
  )
}

#' @export
be_arrow_fs.rcs_backend_local <- function(be) {
  list(fs = arrow::LocalFileSystem$create(), path = be$root)
}

#' @export
be_gdal_path.rcs_backend_local <- function(be, path) {
  local_path(be, path)
}

#' @export
be_get.rcs_backend_local <- function(be, path, dest) {
  src <- local_path(be, path)
  if (!file.exists(src) || dir.exists(src)) {
    abort_local("Cannot download {.path {path}}: it does not exist in {.path {be$uri}}.")
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  ok <- suppressWarnings(file.copy(src, dest, overwrite = TRUE, copy.date = TRUE))
  if (!ok) {
    abort_local("Cannot copy {.path {src}} to {.path {dest}}.")
  }
  invisible(dest)
}

#' @export
be_put.rcs_backend_local <- function(be, src, path) {
  if (!rlang::is_string(src) || !file.exists(src) || dir.exists(src)) {
    abort_local("Cannot upload {.path {src}}: no such file.")
  }
  target <- local_path(be, path)
  folder <- dirname(target)
  dir.create(folder, recursive = TRUE, showWarnings = FALSE)
  tmp <- file.path(
    folder,
    paste0(".", basename(target), ".tmp-", paste(sample(c(letters, 0:9), 10, TRUE), collapse = ""))
  )
  withr::defer(if (file.exists(tmp)) unlink(tmp))
  if (!suppressWarnings(file.copy(src, tmp, overwrite = TRUE))) {
    abort_local("Cannot write {.path {path}} in {.path {be$uri}}.")
  }
  if (!suppressWarnings(file.rename(tmp, target))) {
    abort_local("Cannot rename the temporary copy of {.path {path}} in {.path {be$uri}}.")
  }
  invisible(path)
}

#' @export
be_delete.rcs_backend_local <- function(be, paths) {
  full <- local_path(be, paths)
  existing <- full[file.exists(full) & !dir.exists(full)]
  unlink(existing)
  left <- existing[file.exists(existing)]
  if (length(left) > 0) {
    abort_local("Cannot delete {length(left)} file{?s} in {.path {be$uri}}: {.path {left}}.")
  }
  remove_empty_folders(be$root, dirname(existing))
  invisible(paths)
}

# Remove folders left empty, walking up to (not including) the root.
remove_empty_folders <- function(root, folders) {
  folders <- unique(folders)
  while (length(folders) > 0) {
    folders <- folders[startsWith(folders, paste0(root, "/")) & dir.exists(folders)]
    empty <- folders[vapply(
      folders,
      function(f) length(list.files(f, all.files = TRUE, no.. = TRUE)) == 0,
      logical(1)
    )]
    unlink(empty, recursive = TRUE)
    folders <- unique(dirname(empty))
  }
  invisible()
}

#' @export
be_md5.rcs_backend_local <- function(be, paths) {
  full <- local_path(be, paths)
  out <- rep(NA_character_, length(paths))
  present <- file.exists(full) & !dir.exists(full)
  out[present] <- md5_file(full[present])
  out
}

#' @export
be_list.rcs_backend_local <- function(be, prefix = "") {
  folder <- if (nzchar(prefix)) local_path(be, sub("/+$", "", prefix)) else be$root
  files <- if (dir.exists(folder)) {
    list.files(folder, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  } else {
    character()
  }
  files <- sort(files, method = "radix")
  full <- file.path(folder, files)
  rel <- if (nzchar(prefix)) paste0(sub("/+$", "", prefix), "/", files) else files
  modified <- file.mtime(full)
  attr(modified, "tzone") <- "UTC"
  tibble::tibble(
    path = as.character(rel),
    bytes = as.double(file.size(full)),
    modified = as.POSIXct(modified, tz = "UTC")
  )
}

#' @export
be_exists.rcs_backend_local <- function(be, paths) {
  full <- local_path(be, paths)
  file.exists(full) & !dir.exists(full)
}

#' @export
be_auth_hint.rcs_backend_local <- function(be) {
  # The bullets are glue templates evaluated by the caller's `cli_abort()`,
  # so the address goes in as literal text with its braces escaped.
  uri <- gsub("([{}])", "\\1\\1", be$uri)
  c(i = paste0("Local folder '", uri, "': the session needs read and write permission on it."))
}

# Lock ------------------------------------------------------------------------

lock_time_file <- "time"

#' @export
be_lock.rcs_backend_local <- function(be, timeout = rcs_option("rcs.lock_timeout")) {
  if (!is.numeric(timeout) || length(timeout) != 1 || is.na(timeout) || timeout < 0) {
    cli::cli_abort(
      "{.arg timeout} must be a non-negative number of seconds.",
      class = "rcs_error_argument"
    )
  }
  if (!dir.exists(be$root)) {
    abort_local("Cannot lock {.path {be$uri}}: the folder does not exist.")
  }
  lock <- local_path(be, lock_dir)
  if (!dir.create(lock, showWarnings = FALSE)) {
    if (!dir.exists(lock)) {
      abort_local("Cannot create the lock folder {.path {lock}}.")
    }
    taken <- lock_taken_at(lock)
    age <- as.numeric(difftime(Sys.time(), taken, units = "secs"))
    if (age <= timeout) {
      cli::cli_abort(
        c(
          "Another writer holds the lock of {.path {be$uri}}.",
          i = "The lock was taken {round(age)} second{?s} ago; it is taken over after {timeout} second{?s}.",
          i = "If no other writer is running, delete the folder {.path {lock}}."
        ),
        class = "rcs_error_locked"
      )
    }
    cli::cli_warn(
      c(
        "Taking over a stale lock of {.path {be$uri}}.",
        i = "It was taken {round(age)} second{?s} ago, longer than the timeout of {timeout} second{?s}."
      ),
      class = "rcs_warning_lock_stale"
    )
  }
  writeLines(time_to_text(now_utc()), file.path(lock, lock_time_file))
  invisible(TRUE)
}

# Time a lock was taken: the time written in it, else the folder's mtime (a
# writer between `dir.create()` and `writeLines()`).
lock_taken_at <- function(lock) {
  file <- file.path(lock, lock_time_file)
  text <- if (file.exists(file)) suppressWarnings(readLines(file, n = 1, warn = FALSE)) else character()
  taken <- if (length(text) == 1) time_from_text(text) else NA
  if (is.na(taken)) file.mtime(lock) else taken
}

#' @export
be_unlock.rcs_backend_local <- function(be) {
  unlink(local_path(be, lock_dir), recursive = TRUE)
  invisible(TRUE)
}
