# Versions of a dataset: `store_history()` lists them, `store_prune()`
# removes history versions and orphan files.

#' List the versions of a dataset
#'
#' The current version and the earlier versions kept in the primary's
#' history (see "History" in [store_write()]), with the time each was
#' written and replaced, its size, and whether all its files are still
#' stored. Reads `_history.parquet` of the primary and checks that the files
#' exist; no data file is opened.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset The dataset's full name, or its last part when that is
#'   unique. A dataset that was deleted but whose history was kept can be
#'   named by its full name.
#' @return A tibble, one row per version, the current one first and then by
#'   time of replacement, latest first: `version`, `current` (logical),
#'   `written` (when its newest file was written), `replaced` (when a later
#'   version replaced it; `NA` for the current one), `n_files`, `rows`,
#'   `bytes` and `complete` (`TRUE` when every file of the version is still
#'   stored). Times are shown in the session's time zone. Such a version can
#'   be read with `store_read(version = )`.
#' @seealso [store_prune()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-history")
#' store_create(file.path(root, "primary"), history = TRUE)
#' st <- store_connect(file.path(root, "primary"))
#' sales <- rcs_sim_table(100, seed = 1)
#' store_write(st, sales, "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales."
#' )
#' sales$qty <- sales$qty + 1L
#' store_write(st, sales, "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   mode = "replace"
#' )
#' store_history(st, "sales/daily")
#' unlink(root, recursive = TRUE)
store_history <- function(st, dataset) {
  validate_store(st)
  local_trace("store_history")
  call <- rlang::current_env()
  be <- st$primary$backend
  history <- history_read(be)
  name <- resolve_with_history(st, dataset, history, call)

  catalog <- st$primary$catalog
  entry <- catalog_entry(catalog, name)
  versions <- list()
  if (nrow(entry) == 1) {
    files <- st$primary$files[st$primary$files$dataset == name, ]
    versions[[1]] <- list(version = entry$version, current = TRUE, replaced = NA_real_, files = files)
  }
  rows <- history[history$dataset == name, ]
  past <- unique(rows$version)
  past <- setdiff(past, entry$version)
  replaced <- vapply(past, function(v) max(as.numeric(rows$replaced[rows$version == v])), numeric(1))
  past <- past[order(-replaced)]
  for (v in past) {
    versions[[length(versions) + 1L]] <- list(
      version = v, current = FALSE,
      replaced = max(as.numeric(rows$replaced[rows$version == v])),
      files = history_version_rows(history, name, v)
    )
  }
  paths <- unique(unlist(lapply(versions, function(v) v$files$path)))
  present <- if (length(paths) > 0) stats::setNames(be_exists(be, paths), paths) else logical()
  out <- tibble::tibble(
    version = vapply(versions, function(v) v$version, character(1)),
    current = vapply(versions, function(v) v$current, logical(1)),
    written = local_time(as_utc(vapply(versions, function(v) max(as.numeric(v$files$created)), numeric(1)))),
    replaced = local_time(as_utc(vapply(versions, function(v) v$replaced, numeric(1)))),
    n_files = vapply(versions, function(v) nrow(v$files), integer(1)),
    rows = vapply(versions, function(v) sum(as.numeric(v$files$rows)), numeric(1)),
    bytes = vapply(versions, function(v) sum(as.numeric(v$files$bytes)), numeric(1)),
    complete = vapply(versions, function(v) all(present[v$files$path]), logical(1))
  )
  out
}

# A dataset of the primary catalog, or one known only from the history.
resolve_with_history <- function(st, dataset, history, call) {
  found <- tryCatch(
    resolve_dataset(st, dataset, index = TRUE, call = call),
    rcs_error_dataset_not_found = function(e) e
  )
  if (!inherits(found, "error")) {
    return(found)
  }
  if (rlang::is_string(dataset) && dataset %in% history$dataset) {
    return(dataset)
  }
  rlang::cnd_signal(found)
}

#' Remove old versions and orphan files
#'
#' In every available location: removes history versions beyond the last
#' `keep` of each dataset, or replaced before `before`, deletes their files
#' and manifests unless a remaining version still names them, and deletes
#' orphan files that no catalog names (left by failed or interrupted
#' writes, found by listing the location). Orphans younger than one hour are
#' kept: they may belong to a write in progress. A file that a kept version
#' names is never deleted.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place.
#' @param dataset `NULL` for every dataset, or one dataset's name (its index
#'   table is pruned with it). A deleted dataset whose history was kept can
#'   be named by its full name.
#' @param keep Number of history versions kept per dataset, not counting the
#'   current version; `0` removes all history.
#' @param before `NULL`, or a time (`POSIXct`, `Date` or a string
#'   `as.POSIXct()` understands, in UTC): history versions replaced before it
#'   are removed as well.
#' @param dry_run `TRUE` reports what would be removed and changes nothing.
#' @return A tibble, invisibly, one row per file removed (or to be removed
#'   with `dry_run = TRUE`): `location`, `dataset`, `version` (`NA` for
#'   orphans), `path`, `reason` (`"history"` or `"orphan"`) and `bytes`.
#' @seealso [store_history()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-prune")
#' store_create(file.path(root, "primary"), history = TRUE)
#' st <- store_connect(file.path(root, "primary"))
#' sales <- rcs_sim_table(100, seed = 1)
#' for (i in 1:3) {
#'   sales$qty <- sales$qty + 1L
#'   store_write(st, sales, "sales/daily",
#'     title = "Daily sales", description = "Simulated daily sales.",
#'     mode = "replace"
#'   )
#' }
#' store_prune(st, keep = 1, dry_run = TRUE)
#' store_prune(st, keep = 0)
#' store_history(st, "sales/daily")
#' unlink(root, recursive = TRUE)
store_prune <- function(st, dataset = NULL, keep = 1, before = NULL, dry_run = FALSE) {
  validate_store(st)
  local_trace("store_prune")
  call <- rlang::current_env()
  if (!rlang::is_scalar_integerish(keep) || is.na(keep) || keep < 0) {
    cli::cli_abort("{.arg keep} must be a whole number of at least 0.", class = "rcs_error_argument", call = call)
  }
  before <- check_before(before, call)
  check_flag(dry_run, call = call)
  failed <- write_refresh(st, call)

  datasets <- NULL
  if (!is.null(dataset)) {
    check_string(dataset, call = call)
    name <- tryCatch(
      resolve_dataset(st, dataset, index = TRUE, call = call),
      rcs_error_dataset_not_found = function(e) {
        check_dataset_name(dataset, call = call)
        dataset
      }
    )
    datasets <- c(name, index_name(name))
  }

  results <- list()
  for (location in store_locations(st, available_only = TRUE)) {
    uri <- location$uri
    if (uri %in% names(failed)) next
    location <- store_locations(st)[[match(uri, store_uris(st))]]
    primary <- identical(uri, st$primary$uri)
    out <- tryCatch(
      prune_location(st, location, datasets, as.integer(keep), before, dry_run),
      error = function(e) e
    )
    if (inherits(out, "error")) {
      if (!inherits(out, write_error_classes)) {
        rlang::cnd_signal(out)
      }
      tryCatch(location_refresh(st, location), error = function(e) NULL)
      if (primary) {
        cli::cli_abort(
          "Pruning the primary location {.path {uri}} failed.",
          class = c("rcs_error_prune", setdiff(class(out), c("rlang_error", "error", "condition"))),
          parent = out, call = call
        )
      }
      cli::cli_warn(
        "Pruning the secondary location {.path {uri}} failed; it is skipped.",
        class = "rcs_warning_secondary_behind", parent = out
      )
      next
    }
    results[[length(results) + 1L]] <- out
  }
  results <- vctrs::vec_rbind(prune_empty(), !!!results)
  prune_report(results, dry_run)
  invisible(results)
}

check_before <- function(before, call) {
  if (is.null(before)) {
    return(NULL)
  }
  out <- tryCatch(
    {
      if (inherits(before, "Date")) {
        as_utc(as.POSIXct(format(before), tz = "UTC"))
      } else if (inherits(before, "POSIXct")) {
        as_utc(before)
      } else if (rlang::is_string(before)) {
        as_utc(as.POSIXct(before, tz = "UTC"))
      } else {
        NA
      }
    },
    error = function(e) NA
  )
  if (length(out) != 1 || is.na(out)) {
    cli::cli_abort("{.arg before} must be one time, a date or a string such as {.val 2026-01-31}.", class = "rcs_error_argument", call = call)
  }
  out
}

prune_empty <- function() {
  tibble::tibble(
    location = character(), dataset = character(), version = character(),
    path = character(), reason = character(), bytes = double()
  )
}

# Orphans younger than this many seconds are kept.
orphan_min_age <- 3600

prune_location <- function(st, location, datasets, keep, before, dry_run) {
  be <- location$backend
  uri <- location$uri
  history <- history_read(be)
  catalog <- location$catalog
  files <- location$files

  # History versions to remove.
  versions <- unique(history[c("dataset", "version")])
  if (!is.null(datasets)) {
    versions <- versions[versions$dataset %in% datasets, ]
  }
  current <- paste(catalog$dataset, catalog$version)
  versions <- versions[!paste(versions$dataset, versions$version) %in% current, ]
  remove <- character()
  if (nrow(versions) > 0) {
    id <- paste(history$dataset, history$version)
    versions$replaced <- vapply(
      paste(versions$dataset, versions$version),
      function(k) max(as.numeric(history$replaced[id == k])), numeric(1)
    )
    for (d in unique(versions$dataset)) {
      v <- versions[versions$dataset == d, ]
      v <- v[order(-v$replaced), ]
      drop <- seq_len(nrow(v)) > keep
      if (!is.null(before)) {
        drop <- drop | v$replaced < as.numeric(before)
      }
      remove <- c(remove, paste(v$dataset[drop], v$version[drop]))
    }
  }
  key <- paste(history$dataset, history$version)
  removed <- history[key %in% remove, ]
  new_history <- history[!key %in% remove, ]
  named_versions <- unique(vctrs::vec_rbind(catalog[c("dataset", "version")], new_history[c("dataset", "version")]))
  named <- c(files$path, new_history$path, manifest_path(named_versions$dataset, named_versions$version))
  removed_versions <- unique(removed[c("dataset", "version")])
  old <- removed[!duplicated(removed$path) & !removed$path %in% named, ]
  out_history <- prune_rows(uri, old$dataset, old$version, old$path, "history", as.numeric(old$bytes))
  manifests <- setdiff(manifest_path(removed_versions$dataset, removed_versions$version), named)

  # Orphans, found by listing.
  listing <- be_list(be, "")
  candidates <- listing[!startsWith(listing$path, "_"), ]
  candidates <- candidates[!candidates$path %in% c(named, old$path), ]
  if (!is.null(datasets)) {
    under <- vapply(candidates$path, function(p) any(startsWith(p, paste0(datasets, "/"))), logical(1))
    candidates <- candidates[under, ]
  }
  age <- as.numeric(difftime(Sys.time(), candidates$modified, units = "secs"))
  orphans <- candidates[age >= orphan_min_age, ]
  manifest_rows <- listing[listing$path %in% manifests, ]
  out_manifests <- prune_rows(
    uri, sub("/_manifest-.*$", "", manifest_rows$path),
    sub("^.*/_manifest-([0-9a-f]{16})\\.json$", "\\1", manifest_rows$path),
    manifest_rows$path, "history", manifest_rows$bytes
  )
  orphan_manifest <- manifests[!manifests %in% manifest_rows$path]
  out_orphans <- prune_rows(uri, prune_owner(orphans$path, c(catalog$dataset, history$dataset)), NA_character_, orphans$path, "orphan", orphans$bytes)

  if (!dry_run) {
    if (length(remove) > 0) {
      write_guard(location)
      written <- with_retry(function() location_write(location, catalog, files, new_history))
      store_set_location(st, written)
      delete_quietly(be, c(old$path, manifests, orphan_manifest))
    }
    delete_quietly(be, orphans$path)
  }
  vctrs::vec_rbind(prune_empty(), out_history, out_manifests, out_orphans)
}

prune_rows <- function(uri, dataset, version, path, reason, bytes) {
  n <- length(path)
  tibble::tibble(
    location = rep(uri, n), dataset = rep_len(as.character(dataset), n),
    version = rep_len(as.character(version), n), path = as.character(path),
    reason = rep(reason, n), bytes = rep_len(as.numeric(bytes), n)
  )
}

# The dataset an orphan file belongs to (longest known prefix), or NA.
prune_owner <- function(paths, known) {
  known <- unique(known)
  vapply(paths, function(p) {
    owner <- known[startsWith(p, paste0(known, "/"))]
    if (length(owner) == 0) NA_character_ else owner[which.max(nchar(owner))]
  }, character(1), USE.NAMES = FALSE)
}

prune_report <- function(results, dry_run) {
  if (nrow(results) == 0) {
    rcs_inform(c(v = "Nothing to prune."))
    return(invisible())
  }
  hist <- results[results$reason == "history" & !grepl("/_manifest-", results$path), ]
  n_versions <- nrow(unique(results[results$reason == "history", c("location", "dataset", "version")]))
  n_files <- nrow(results)
  k <- length(unique(results$location))
  size <- format_bytes(sum(results$bytes, na.rm = TRUE))
  n_orphans <- sum(results$reason == "orphan")
  verb <- if (dry_run) "Would remove" else "Removed"
  rcs_inform(c(
    v = "{verb} {n_versions} history version{?s} and {n_files} file{?s} ({size}) in {k} location{?s}.",
    i = if (n_orphans > 0) "{n_orphans} of the files {?is an orphan/are orphans} that no catalog named."
  ))
  invisible(nrow(hist))
}
