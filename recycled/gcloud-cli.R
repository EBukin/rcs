# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: work package A, R/backend-gcs.R, ONLY if transfers to Google Cloud
# Storage have to fall back to the `gcloud` command line tool. Otherwise drop.
#
# What it shows: running an external CLI with stdout and stderr captured
# apart, per-call environment variables, and a cli error that quotes the
# tool's own message. `processx` would be a Suggests dependency.
#
# Facts worth keeping:
#   * `gcloud storage cp` needs `CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False`,
#     otherwise large uploads become composite objects without an MD5;
#   * without `--content-type` Parquet is stored as application/octet-stream;
#   * zero-byte objects whose name ends in "/" are folder placeholders.

#' Run gcloud and return its output
#'
#' @param args Character vector of arguments, unquoted.
#' @param env Named character vector of environment variables for this call.
#'
#' @return A list with `stdout`, `stderr` and `status`. A non-zero exit
#'   status aborts with the standard error.
#' @noRd
gcloud_run <- function(args, env = character()) {
  gcloud <- gcloud_path()
  res <- processx::run(
    gcloud, args,
    env = c("current", env), error_on_status = FALSE,
    encoding = "UTF-8"
  )
  if (!identical(as.integer(res$status), 0L)) {
    stderr <- strsplit(res$stderr, "\r?\n")[[1]]
    stderr <- stderr[nzchar(trimws(stderr))]
    # Braces are doubled so cli prints the text as it is.
    stderr <- gsub("}", "}}", gsub("{", "{{", stderr, fixed = TRUE), fixed = TRUE)
    cli::cli_abort(c(
      "gcloud failed with status {res$status}.",
      "i" = "Command: {.code {paste(c('gcloud', args), collapse = ' ')}}",
      stats::setNames(stderr, rep("x", length(stderr)))
    ), .envir = environment())
  }
  list(stdout = res$stdout, stderr = res$stderr, status = res$status)
}

#' Locate the gcloud executable
#'
#' Looks at the environment variable `RCS_GCLOUD`, then the search path, then
#' the default install folder in the user's home.
#' @noRd
gcloud_path <- function() {
  windows <- .Platform$OS.type == "windows"
  name <- if (windows) "gcloud.cmd" else "gcloud"
  home <- if (windows) Sys.getenv("USERPROFILE") else path.expand("~")
  candidates <- c(
    Sys.getenv("RCS_GCLOUD", unset = ""),
    unname(Sys.which(name)),
    file.path(home, "google-cloud-sdk", "bin", name)
  )
  found <- candidates[nzchar(candidates) & file.exists(candidates)]
  if (length(found) == 0) {
    cli::cli_abort(c(
      "Cannot find the {.code gcloud} command line tool.",
      "i" = "Install the Google Cloud SDK or set {.envvar RCS_GCLOUD} to its path."
    ))
  }
  found[[1]]
}

#' Objects under a bucket prefix, with size and base64 MD5
#'
#' `md5_hash` is missing for composite objects; it comes back as `NA`.
#' @noRd
gcloud_list <- function(uri) {
  out <- gcloud_run(c(
    "storage", "objects", "list", paste0(sub("/+$", "", uri), "/**"),
    "--format=json(name,size,md5_hash)"
  ))
  objects <- jsonlite::fromJSON(out$stdout, simplifyVector = FALSE)
  objects <- Filter(\(o) !grepl("/$", o$name), objects)
  tibble::tibble(
    path = vapply(objects, \(o) o$name, character(1)),
    bytes = vapply(objects, \(o) as.numeric(o$size), numeric(1)),
    md5 = vapply(objects, \(o) o$md5_hash %||% NA_character_, character(1))
  )
}
