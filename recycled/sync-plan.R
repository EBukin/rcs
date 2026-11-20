# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: work package G, R/sync.R (store_sync(), store_copy()); the state
# vocabulary also serves store_status() in work package D, R/inspect.R.
#
# What it shows: the pattern
#   1. compare two sides file by file (MD5, size as fallback),
#   2. build a plan with one action per file,
#   3. order the plan so that catalog files go last,
#   4. run it, then compare again and abort when a transferred file differs.
#
# What the plan changes:
#   * both sides are described by their catalogs (`_files.parquet`), not by
#     listing; listing is reserved for prune and rebuild;
#   * transfers go through `be_get()` / `be_put()`; nothing is deleted by sync;
#   * verification compares the catalog MD5 with `be_md5()` of the target.

#' Compare the files of two sides
#'
#' @param from,to Data frames with `path`, `bytes`, `md5`, one row per file.
#'
#' @return A tibble, one row per path on either side, with `state`: `same`,
#'   `from_only`, `to_only` or `differs`. A file without MD5 on one side is
#'   compared by size.
#' @noRd
sync_compare <- function(from, to) {
  names(from)[match(c("bytes", "md5"), names(from))] <- c("from_bytes", "from_md5")
  names(to)[match(c("bytes", "md5"), names(to))] <- c("to_bytes", "to_md5")
  status <- dplyr::full_join(from, to, by = "path")
  status <- status[order(status$path), ]

  on_both <- !is.na(status$from_bytes) & !is.na(status$to_bytes)
  has_md5 <- !is.na(status$from_md5) & !is.na(status$to_md5)
  equal <- ifelse(
    has_md5,
    status$from_md5 == status$to_md5,
    status$from_bytes == status$to_bytes
  )
  status$state <- ifelse(
    !on_both,
    ifelse(is.na(status$to_bytes), "from_only", "to_only"),
    ifelse(equal, "same", "differs")
  )
  status
}

#' Turn a comparison into an ordered plan
#'
#' @param status Result of `sync_compare()`.
#' @param last Paths that must be transferred after all others (catalogs).
#'
#' @return `status` with an `action` column, `copy` or `skip`, in the order
#'   of execution.
#' @noRd
sync_plan <- function(status, last = character()) {
  plan <- status
  plan$action <- "skip"
  plan$action[plan$state %in% c("from_only", "differs")] <- "copy"
  plan[order(plan$path %in% last, plan$action != "copy"), ]
}

#' Report a plan
#' @noRd
sync_report <- function(plan, dry_run) {
  n <- table(factor(plan$action, c("copy", "skip")))
  cli::cli_inform(c(
    "i" = "{if (dry_run) 'Dry run: ' else ''}{n[[1]]} to copy, {n[[2]]} to skip."
  ))
  extra <- plan$path[plan$state == "to_only"]
  if (length(extra) > 0) {
    cli::cli_inform(c("!" = "Only at the target, left in place: {.path {extra}}."))
  }
  invisible(plan)
}

#' Abort when a copied file is not the same on both sides after the run
#'
#' @param plan The executed plan.
#' @param after Result of `sync_compare()` read after the run.
#' @noRd
sync_verify <- function(plan, after) {
  moved <- plan$path[plan$action == "copy"]
  not_same <- after$path[after$path %in% moved & after$state != "same"]
  if (length(not_same) > 0) {
    cli::cli_abort(c(
      "The two locations do not match after the run.",
      "x" = "Not the same on both sides: {.path {not_same}}."
    ))
  }
  cli::cli_inform(c(
    "v" = "Verified: {length(moved)} file{?s} copied, the same on both sides."
  ))
  invisible(TRUE)
}
