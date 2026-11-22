# Keeping the locations of a store in step: `store_sync()` (from any
# location to the others), `store_copy()` (one dataset between any two locations),
# `store_delete()` and `store_rebuild()`.
#
# Sync and copy land versions with the write pipeline's `land_location()`
# (R/write.R): only the files a location lacks are sent, every upload is
# verified by MD5, the manifests follow, and the catalogs are switched last
# under the write guard. A version landed this way gets its manifest written
# anew with the time of the landing (entry and file rows unchanged), so that
# in every location the latest manifest is the one landed last, which is
# what `store_rebuild()` takes as current.
#
# A "unit" is one dataset with its index table: `dataset`, `sets` (version
# sources, see R/write.R), `drops` (an index table the target holds but the
# source does not) and `keep_history` (the effective history setting of the
# dataset).

# store_sync() ------------------------------------------------------------------

#' Bring the locations of a store into step
#'
#' Copies datasets from one location, the source (by default the primary),
#' to the other locations of the connection: every dataset whose copy in a
#' target is missing or differs from the source's (another version, or
#' another entry). Only the files a target lacks are sent, each verified by
#' MD5; the catalogs of a target are switched last, so that its readers
#' always see a complete version. A geospatial dataset's index table
#' travels with it.
#'
#' With `from` set to a secondary location, work done there (for example
#' through a connection whose primary was that location, while the primary
#' could not be reached) is brought to the primary and to the other
#' secondaries.
#'
#' @section Conflicts:
#' When a target holds another version of a dataset and its entry was
#' updated later than the source's (the times recorded in the catalogs),
#' the dataset is not copied there: it is a conflict. Every other copy and deletion goes ahead; after the last
#' target the call aborts with class `rcs_error_sync_conflict`, listing the
#' conflicts, and the condition's field `result` holds the result tibble.
#' `force = TRUE` copies the source over the newer version instead. Every
#' version of a target that is replaced by another one is listed in one
#' warning (class `rcs_warning_sync_overwrite`). The times compared are
#' those of the machines that wrote; their clocks may differ.
#'
#' @section Deletions:
#' By default `store_sync()` never deletes a dataset: datasets found only in
#' a target are left alone (see [store_status()], status `"extra"`). With
#' `delete = TRUE` they are deleted from that target, with their index table,
#' after its copies, as [store_delete()] does for one location (the history
#' kept). The primary is a target only when `from` is a secondary; datasets
#' are deleted there only with `force = TRUE`, and are otherwise reported in
#' the result column `kept`. Files of a version a target replaces are
#' deleted when the dataset keeps no history, as in [store_write()].
#'
#' A target that fails is reported as behind with a warning, and the next
#' one is synced; running the call again sends only what is still missing.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place.
#' @param datasets `NULL` for every dataset of the source, or names of
#'   datasets (full names, or last parts that are unique in the source).
#'   With `delete = TRUE` it restricts the deletions too, and a full name
#'   the source does not hold is accepted.
#' @param to `NULL` for every location other than the source, or the
#'   addresses of some of them.
#' @param from `NULL` for the primary, or the address of the location to
#'   copy from.
#' @param delete `TRUE` deletes from each target the datasets the source
#'   does not hold.
#' @param force `TRUE` copies over versions that are newer in a target, and
#'   lets `delete = TRUE` delete datasets from the primary.
#' @param dry_run `TRUE` reports what would be copied, deleted and found in
#'   conflict, and changes nothing.
#' @return A tibble, invisibly, one row per target location: `location`,
#'   `status` (`"synced"`, `"same"` when nothing was copied or deleted,
#'   `"conflict"` when the target holds a newer version of a dataset,
#'   `"behind"` when it failed, `"unavailable"`, or `"to sync"` with
#'   `dry_run = TRUE`), the list columns `datasets` (copied, or to copy),
#'   `deleted` (deleted, or to delete), `kept` (not deleted from the primary
#'   without `force`) and `conflicts`, then `files` (files sent, or to send),
#'   `bytes` and `seconds`.
#' @seealso [store_status()] to compare the locations, [store_copy()] for one
#'   dataset between any two locations; `vignette("locations")` for syncs
#'   from a secondary, conflicts and deletions.
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-sync")
#' store_create(file.path(root, "copy"))
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#'
#' # A connection with a secondary location that missed the write
#' st <- store_connect(file.path(root, "primary"),
#'   secondary = file.path(root, "copy")
#' )
#' store_status(st)
#' store_sync(st, dry_run = TRUE)
#' store_sync(st)
#'
#' # Work done on the secondary alone, brought back to the primary
#' offline <- store_connect(file.path(root, "copy"))
#' store_write(offline, rcs_sim_table(50, seed = 2), "sales/weekly",
#'   title = "Weekly sales", description = "Simulated weekly sales."
#' )
#' store_sync(st, from = file.path(root, "copy"))
#' store_status(st)
#' unlink(root, recursive = TRUE)
store_sync <- function(st, datasets = NULL, to = NULL, from = NULL, delete = FALSE, force = FALSE,
                       dry_run = FALSE) {
  validate_store(st)
  local_trace("store_sync")
  call <- rlang::current_env()
  check_flag(delete, call = call)
  check_flag(force, call = call)
  check_flag(dry_run, call = call)
  if (!is.null(datasets) && (!is.character(datasets) || length(datasets) == 0 || anyNA(datasets))) {
    cli::cli_abort(
      "{.arg datasets} must be {.code NULL} or a character vector of dataset names, not {.obj_type_friendly {datasets}}.",
      class = "rcs_error_argument", call = call
    )
  }
  from_uri <- if (is.null(from)) st$primary$uri else location_arg(st, from, "from", call)
  targets <- sync_targets(st, from_uri, to, call)
  failed <- sync_refresh(st, from_uri, targets, call)
  source <- current_location(st, from_uri)
  names <- sync_dataset_names(st, source, datasets, delete, call)
  held <- names[names %in% source$catalog$dataset]
  units <- lapply(held, function(d) sync_unit(st, source, d))
  now <- now_utc()

  dir <- sync_staging_dir("rcs-sync")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  ctx <- write_context(st, dir)
  ctx$primary <- source$backend
  units <- lapply(units, sync_fresh_manifests, dir = dir, now = now)
  restrict <- if (is.null(datasets)) NULL else names

  widths <- write_widths(store_locations(st))
  sync_header(st, source, held, targets, dry_run)
  results <- list()
  for (uri in targets) {
    role <- location_role(st, uri)
    result <- if (uri %in% names(failed)) {
      sync_result(uri, role, if (identical(failed[[uri]], "unavailable")) "unavailable" else "behind",
        message = failed[[uri]]
      )
    } else {
      plan <- sync_plan(st, source, current_location(st, uri), units, restrict, delete, force)
      if (dry_run) sync_plan_location(st, uri, plan) else sync_location(st, uri, plan, ctx, now)
    }
    sync_line(result, widths)
    results[[length(results) + 1L]] <- result
  }
  out <- vctrs::vec_rbind(sync_empty(), !!!lapply(results, sync_result_row))
  sync_footer(st, out, dry_run)
  if (!dry_run) {
    sync_warn_overwrite(results)
    sync_abort_conflicts(results, out, call)
  }
  invisible(out)
}

location_role <- function(st, uri) {
  if (identical(uri, st$primary$uri)) "primary" else "secondary"
}

# Addresses of the locations a sync goes to: every location but the source,
# or those named by `to`, in connection order.
sync_targets <- function(st, from_uri, to, call) {
  uris <- store_uris(st)
  if (is.null(to)) {
    return(setdiff(uris, from_uri))
  }
  if (!is.character(to) || length(to) == 0 || anyNA(to)) {
    cli::cli_abort(
      "{.arg to} must be {.code NULL} or addresses of locations of this connection, not {.obj_type_friendly {to}}.",
      class = "rcs_error_argument", call = call
    )
  }
  chosen <- vapply(to, function(x) location_arg(st, x, "to", call), character(1), USE.NAMES = FALSE)
  if (from_uri %in% chosen) {
    cli::cli_abort(
      c(
        "{.arg to} names the source location {.path {from_uri}}.",
        i = "{.fn store_sync} copies from {.arg from} (by default the primary) to the other locations."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  uris[uris %in% chosen]
}

#' The address of a location of the connection
#'
#' @param st An `rcs_store`.
#' @param x One string: an address as given by the user.
#' @param arg,call Used in the error message.
#' @return The location's `uri` (as `be_new()` normalises it). Aborts with
#'   class `rcs_error_argument` when `x` names no location of `st`.
#' @noRd
location_arg <- function(st, x, arg, call) {
  check_string(x, arg = arg, call = call)
  uri <- tryCatch(be_new(x)$uri, error = function(e) x)
  uris <- store_uris(st)
  if (!uri %in% uris) {
    uri <- x
  }
  if (!uri %in% uris) {
    cli::cli_abort(
      c(
        "{.arg {arg}} must be the address of a location of this connection, not {.val {x}}.",
        i = "Its locations: {.path {uris}}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  uri
}

# Re-read the catalogs of the source and of the targets. The source must
# answer; a target that does not is returned by name (its `uri`) with the
# error message, or "unavailable" for a location unavailable since the
# connection.
sync_refresh <- function(st, from_uri, targets, call) {
  source <- current_location(st, from_uri)
  reach(location_refresh(st, source), source$backend, location_role(st, from_uri), call)
  failed <- list()
  for (location in store_locations(st)) {
    uri <- location$uri
    if (!uri %in% targets) next
    if (!location$available) {
      failed[[uri]] <- "unavailable"
      next
    }
    fresh <- tryCatch(location_refresh(st, location), error = function(e) e)
    if (inherits(fresh, "error")) {
      if (!inherits(fresh, write_error_classes)) {
        rlang::cnd_signal(fresh)
      }
      role <- location_role(st, uri)
      cli::cli_warn(
        c("Cannot read the catalogs of the {role} location {.path {uri}}; it is skipped.",
          i = "Run the call again once it can be reached."),
        class = "rcs_warning_secondary_behind", parent = fresh
      )
      failed[[uri]] <- first_line(conditionMessage(fresh))
    }
  }
  failed
}

# Full names of the datasets to sync; index tables travel with their dataset.
# With `delete`, a valid full name the source does not hold is kept (it
# names a dataset to delete from the targets).
sync_dataset_names <- function(st, source, datasets, delete, call) {
  catalog <- source$catalog
  if (is.null(datasets)) {
    return(catalog$dataset[!is_index_entry(catalog)])
  }
  primary <- identical(source$uri, st$primary$uri)
  resolve <- function(d) {
    found <- tryCatch(
      if (primary) resolve_dataset(st, d, index = FALSE, call = call) else resolve_in_location(source, d, call),
      rcs_error_dataset_not_found = function(e) e
    )
    if (!inherits(found, "error")) {
      return(found)
    }
    valid <- tryCatch(
      {
        check_dataset_name(d, call = call)
        TRUE
      },
      error = function(e) FALSE
    )
    if (delete && valid && !is_index_name(d)) {
      return(d)
    }
    rlang::cnd_signal(found)
  }
  unique(vapply(datasets, resolve, character(1), USE.NAMES = FALSE))
}

# One dataset of a source location, with its index table.
sync_unit <- function(st, source, dataset) {
  entry <- catalog_entry(source$catalog, dataset)
  sets <- list(sync_src(source, entry))
  index <- catalog_entry(source$catalog, index_name(dataset))
  if (nrow(index) == 1) {
    sets[[2]] <- sync_src(source, index)
  }
  list(
    dataset = dataset,
    sets = sets,
    drops = if (nrow(index) == 0) index_name(dataset) else character(),
    keep_history = effective_history(st, entry$history)
  )
}

sync_src <- function(source, entry) {
  files <- source$files[source$files$dataset == entry$dataset, ]
  list(entry = entry, files = files, manifest_local = NULL, local = NULL, changed = TRUE)
}

# Manifests written anew with the time of the landing (see the header).
sync_fresh_manifests <- function(unit, dir, now) {
  unit$sets <- lapply(unit$sets, function(s) {
    path <- file.path(dir, "manifest", manifest_path(s$entry$dataset, s$entry$version))
    manifest_write_local(new_manifest(s$entry, s$files, written = now), path)
    s$manifest_local <- path
    s
  })
  unit
}

sync_staging_dir <- function(prefix) {
  dir <- file.path(
    rcs_option("rcs.staging_dir"),
    paste0(prefix, "-", md5_string(paste(Sys.getpid(), as.numeric(Sys.time()), stats::runif(1))))
  )
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dir
}

# Does a location lack anything of a unit?
unit_needed <- function(location, unit) {
  any(!vapply(unit$sets, function(s) holds_entry(location$catalog, s$entry), logical(1))) ||
    any(unit$drops %in% location$catalog$dataset)
}

current_location <- function(st, uri) {
  store_locations(st)[[match(uri, store_uris(st))]]
}

# After a failed landing: re-read the location; when its catalogs hold every
# version and none of `drops` (the error came after the catalog switch), the
# landing counts as done and the
# error becomes a warning. Returns a landing result, or the error.
landed_anyway <- function(st, location, sets, drops, error) {
  fresh <- tryCatch(location_refresh(st, location), error = function(e) NULL)
  if (is.null(fresh) || !inherits(error, write_error_classes)) {
    return(error)
  }
  done <- all(vapply(sets, function(s) holds_entry(fresh$catalog, s$entry), logical(1))) &&
    !any(drops %in% fresh$catalog$dataset)
  if (!done) {
    return(error)
  }
  uri <- location$uri
  cli::cli_warn(
    "The catalogs of {.path {uri}} were switched, but the call failed afterwards.",
    class = "rcs_warning_after_switch", parent = error
  )
  total <- sum(vapply(sets, function(s) nrow(s$files), numeric(1)))
  list(status = "written", total = total, uploaded = 0, bytes = 0, seconds = 0)
}

#' What a sync does in one target
#'
#' @param st An `rcs_store`.
#' @param source,target The source and target `rcs_location`s, as read at
#'   the start of the call.
#' @param units The units of the source to sync.
#' @param restrict `NULL`, or the dataset names deletions are restricted to.
#' @param delete,force As in `store_sync()`.
#' @return A list: `copy` (units to land), `conflicts` and `overwritten`
#'   (lists of version records: `dataset`, `target_version`,
#'   `target_updated`, `source_version`, `source_updated`), `delete` and
#'   `kept` (dataset names).
#' @noRd
sync_plan <- function(st, source, target, units, restrict, delete, force) {
  copy <- list()
  conflicts <- list()
  overwritten <- list()
  for (unit in units) {
    if (!unit_needed(target, unit)) next
    entry <- unit$sets[[1]]$entry
    current <- catalog_entry(target$catalog, unit$dataset)
    if (nrow(current) == 1 && !identical(current$version, entry$version)) {
      record <- list(
        dataset = unit$dataset,
        target_version = current$version, target_updated = current$updated,
        source_version = entry$version, source_updated = entry$updated
      )
      if (current$updated > entry$updated && !force) {
        conflicts[[length(conflicts) + 1L]] <- record
        next
      }
      overwritten[[length(overwritten) + 1L]] <- record
    }
    copy[[length(copy) + 1L]] <- unit
  }
  gone <- character()
  if (delete) {
    catalog <- target$catalog
    gone <- setdiff(catalog$dataset[!is_index_entry(catalog)], source$catalog$dataset)
    if (!is.null(restrict)) {
      gone <- intersect(gone, restrict)
    }
  }
  keep <- identical(target$uri, st$primary$uri) && !force
  list(
    copy = copy, conflicts = conflicts, overwritten = overwritten,
    delete = if (keep) character() else gone,
    kept = if (keep) gone else character()
  )
}

unit_names <- function(units) {
  vapply(units, function(u) u$dataset, character(1))
}

record_names <- function(records) {
  vapply(records, function(r) r$dataset, character(1))
}

# Run the plan of one target: the copies (one catalog switch per history
# setting), then the deletions (one catalog switch, then the files).
sync_location <- function(st, uri, plan, ctx, now) {
  start <- Sys.time()
  role <- location_role(st, uri)
  result <- function(status, ...) {
    sync_result(uri, role, status,
      datasets = done, deleted = deleted, kept = plan$kept, conflicts = plan$conflicts,
      overwritten = Filter(function(r) r$dataset %in% done, plan$overwritten),
      files = sent, total = total, bytes = bytes,
      seconds = as.numeric(difftime(Sys.time(), start, units = "secs")), ...
    )
  }
  behind <- function(error, text) {
    if (!inherits(error, write_error_classes)) {
      rlang::cnd_signal(error)
    }
    cli::cli_warn(
      c(text, i = "Run {.fn store_sync} again: files already sent are reused."),
      class = "rcs_warning_secondary_behind", parent = error
    )
    result("behind", message = first_line(conditionMessage(error)))
  }
  done <- character()
  deleted <- character()
  total <- 0
  sent <- 0
  bytes <- 0

  if (length(plan$copy) > 0) {
    groups <- split(plan$copy, vapply(plan$copy, function(u) u$keep_history, logical(1)))
    for (group in groups) {
      sets <- do.call(c, lapply(group, function(u) u$sets))
      drops <- unlist(lapply(group, function(u) u$drops))
      location <- current_location(st, uri)
      landed <- tryCatch(
        land_location(st, location, sets, drops, group[[1]]$keep_history, ctx, now),
        error = function(e) e
      )
      if (inherits(landed, "error")) {
        landed <- landed_anyway(st, location, sets, drops, landed)
      }
      if (inherits(landed, "error")) {
        return(behind(landed, "Syncing the {role} location {.path {uri}} failed; it is behind."))
      }
      done <- c(done, unit_names(group))
      total <- total + landed$total
      sent <- sent + landed$uploaded
      bytes <- bytes + landed$bytes
    }
  }

  if (length(plan$delete) > 0) {
    location <- current_location(st, uri)
    names <- intersect(c(plan$delete, index_name(plan$delete)), location$catalog$dataset)
    sink <- new.env(parent = emptyenv())
    switched <- tryCatch(
      delete_switch(st, location, names, FALSE, NULL, now, sink),
      error = function(e) e
    )
    if (inherits(switched, "error")) {
      switched <- deleted_anyway(st, uri, names, FALSE, sink, switched)
    }
    if (inherits(switched, "error")) {
      return(behind(switched, "Deleting datasets from the {role} location {.path {uri}} failed; it still lists them."))
    }
    deleted <- plan$delete
    delete_files(st, uri, switched)
  }

  status <- if (length(plan$conflicts) > 0) {
    "conflict"
  } else if (length(done) + length(deleted) > 0) {
    "synced"
  } else {
    "same"
  }
  result(status)
}

# What a dry run reports: the plan of a target and the files it would be
# sent (compared by path and MD5 with its catalogs, then with what is
# stored).
sync_plan_location <- function(st, uri, plan) {
  role <- location_role(st, uri)
  location <- current_location(st, uri)
  todo <- files_empty()
  rows <- files_empty()
  if (length(plan$copy) > 0) {
    be <- location$backend
    sets <- do.call(c, lapply(plan$copy, function(u) u$sets))
    sets <- Filter(function(s) !holds_entry(location$catalog, s$entry), sets)
    rows <- vctrs::vec_rbind(files_empty(), !!!lapply(sets, function(s) s$files))
    todo <- rows[!duplicated(rows$path), ]
    if (nrow(todo) > 0) {
      history <- history_read(be)
      held <- paste(c(location$files$path, history$path), c(location$files$md5, history$md5))
      todo <- todo[!paste(todo$path, todo$md5) %in% held, ]
    }
    if (nrow(todo) > 0) {
      stored <- be_md5(be, todo$path)
      todo <- todo[is.na(stored) | stored != todo$md5, ]
    }
  }
  busy <- length(plan$copy) + length(plan$delete) + length(plan$conflicts) > 0
  sync_result(uri, role, if (busy) "to sync" else "same",
    datasets = unit_names(plan$copy), deleted = plan$delete, kept = plan$kept,
    conflicts = plan$conflicts, overwritten = plan$overwritten,
    files = nrow(todo), total = nrow(rows), bytes = sum(as.numeric(todo$bytes))
  )
}

sync_result <- function(uri, role, status, datasets = character(), deleted = character(),
                        kept = character(), conflicts = list(), overwritten = list(), files = 0,
                        total = NA_real_, bytes = 0, seconds = 0, message = NA_character_) {
  list(
    location = uri, role = role, status = status, datasets = datasets, deleted = deleted,
    kept = kept, conflicts = conflicts, overwritten = overwritten, files = files, total = total,
    bytes = bytes, seconds = seconds, message = message
  )
}

sync_empty <- function() {
  tibble::tibble(
    location = character(), status = character(), datasets = list(), deleted = list(),
    kept = list(), conflicts = list(), files = double(), bytes = double(), seconds = double()
  )
}

sync_result_row <- function(r) {
  tibble::tibble(
    location = r$location, status = r$status, datasets = list(r$datasets),
    deleted = list(r$deleted), kept = list(r$kept), conflicts = list(record_names(r$conflicts)),
    files = as.numeric(r$files), bytes = as.numeric(r$bytes), seconds = as.numeric(r$seconds)
  )
}

# "secondary location" when every target is a secondary, else "location".
target_noun <- function(st, targets) {
  if (st$primary$uri %in% targets) "location" else "secondary location"
}

sync_header <- function(st, source, names, targets, dry_run) {
  n <- length(names)
  k <- length(targets)
  uri <- source$uri
  role <- location_role(st, uri)
  noun <- paste0(target_noun(st, targets), if (k == 1) "" else "s")
  if (dry_run) {
    rcs_inform(c(i = "Dry run: nothing is changed."))
  }
  rcs_inform(c(i = "Syncing {n} dataset{?s} from the {role} {.path {uri}} to {k} {noun}."))
}

dataset_list_text <- function(datasets, max = 5L) {
  shown <- utils::head(datasets, max)
  text <- paste0("\"", shown, "\"", collapse = ", ")
  if (length(datasets) > max) {
    text <- paste0(text, ", and ", length(datasets) - max, " more")
  }
  text
}

sync_line <- function(r, widths) {
  gap <- strrep(nbsp, 2)
  head <- paste0(pad_right(r$role, widths$role), gap, pad_right(r$location, widths$uri))
  count <- function(n, what) paste0(n, " ", what, if (n == 1) "" else "s")
  n <- length(r$datasets)
  parts <- character()
  if (r$status == "to sync") {
    if (n > 0) {
      parts <- c(parts, paste0(
        "would copy ", count(n, "dataset"), ", ", count(r$files, "file"),
        if (r$bytes > 0) paste0(" (", format_bytes(r$bytes), ")"), ": ", dataset_list_text(r$datasets)
      ))
    }
    if (length(r$deleted) > 0) {
      parts <- c(parts, paste0("would delete ", count(length(r$deleted), "dataset"), ": ", dataset_list_text(r$deleted)))
    }
  } else if (r$status %in% c("synced", "conflict", "same")) {
    if (n > 0) {
      parts <- c(parts, paste0(
        count(n, "dataset"), ", ", format(r$files), "/", format(r$total), " files sent",
        if (r$bytes > 0) paste0(gap, format_bytes(r$bytes)), gap, format_seconds(r$seconds)
      ))
    }
    if (length(r$deleted) > 0) {
      parts <- c(parts, paste0(count(length(r$deleted), "dataset"), " deleted: ", dataset_list_text(r$deleted)))
    }
  }
  if (length(r$conflicts) > 0) {
    names <- record_names(r$conflicts)
    parts <- c(parts, paste0(count(length(names), "conflict"), ", newer here: ", dataset_list_text(names)))
  }
  if (length(r$kept) > 0) {
    parts <- c(parts, paste0(
      count(length(r$kept), "dataset"), " kept, delete on primary needs force: ", dataset_list_text(r$kept)
    ))
  }
  detail <- switch(
    r$status,
    behind = paste0("behind: ", r$message),
    unavailable = "unavailable, skipped",
    if (length(parts) == 0) "up to date" else paste(parts, collapse = "; ")
  )
  bullet <- switch(r$status, behind = "x", conflict = "x", unavailable = "!", `to sync` = "*",
    if (length(r$kept) > 0) "!" else "v"
  )
  rcs_inform(stats::setNames(escape_braces(paste0(head, gap, detail)), bullet))
}

sync_footer <- function(st, out, dry_run) {
  if (dry_run || nrow(out) == 0) {
    return(invisible())
  }
  noun <- target_noun(st, out$location)
  copied <- out[lengths(out$datasets) > 0, ]
  if (nrow(copied) > 0) {
    n <- sum(copied$files)
    k <- nrow(copied)
    rcs_inform(c(v = "MD5 identical for {n} file{?s} sent to {k} location{?s}. Catalogs updated."))
  }
  n_deleted <- sum(lengths(out$deleted))
  if (n_deleted > 0) {
    k <- sum(lengths(out$deleted) > 0)
    rcs_inform(c(v = "{n_deleted} dataset{?s} deleted in {k} location{?s}."))
  }
  if (all(out$status == "same") && sum(lengths(out$kept)) == 0) {
    rcs_inform(c(v = paste0("Every ", noun, " is up to date.")))
  }
  n_kept <- sum(lengths(out$kept))
  if (n_kept > 0) {
    rcs_inform(c("!" = "{n_kept} dataset{?s} kept in the primary: delete on primary needs force ({.code force = TRUE})."))
  }
  n_behind <- sum(out$status %in% c("behind", "unavailable"))
  if (n_behind > 0) {
    nouns <- paste0(noun, if (n_behind == 1) "" else "s")
    rcs_inform(c("!" = "{n_behind} {nouns} {cli::qty(n_behind)}{?is/are} behind; run {.fn store_sync} again once {?it/they} can be reached."))
  }
  invisible()
}

# One line per version record.
record_lines <- function(records, uri, what) {
  stamp <- function(x) format(local_time(x), "%Y-%m-%d %H:%M:%S")
  vapply(records, function(r) {
    escape_braces(sprintf(
      what, uri, r$dataset, r$target_version, stamp(r$target_updated),
      r$source_version, stamp(r$source_updated)
    ))
  }, character(1))
}

# One warning per call: every version of a target replaced by another one.
sync_warn_overwrite <- function(results) {
  lines <- unlist(lapply(results, function(r) {
    record_lines(r$overwritten, r$location, "'%s': \"%s\" version %s (updated %s) replaced by version %s (updated %s).")
  }))
  if (length(lines) == 0) {
    return(invisible())
  }
  n <- length(lines)
  cli::cli_warn(
    c(
      "{.fn store_sync} replaced {n} version{?s} held by the target locations:",
      rlang::set_names(lines, rep("*", n))
    ),
    class = "rcs_warning_sync_overwrite"
  )
}

# After every target: abort when any target holds a newer version.
sync_abort_conflicts <- function(results, out, call) {
  lines <- unlist(lapply(results, function(r) {
    record_lines(r$conflicts, r$location, "'%s': \"%s\" version %s (updated %s) is newer than the source's version %s (updated %s).")
  }))
  if (length(lines) == 0) {
    return(invisible())
  }
  n <- length(lines)
  cli::cli_abort(
    c(
      "{n} dataset{?s} {?was/were} not copied: the target holds a newer version.",
      rlang::set_names(lines, rep("x", n)),
      i = "The other copies and deletions were made.",
      i = "Run with {.code force = TRUE} to copy the source over {cli::qty(n)}{?it/them}, or sync from the location that holds the newer version."
    ),
    class = "rcs_error_sync_conflict", result = out, call = call
  )
}

# store_copy() ------------------------------------------------------------------

#' Copy one dataset between two locations
#'
#' Copies the current version of a dataset, as one location's catalog
#' records it, to another location of the connection: the primary, or any
#' secondary, in either direction. Only the files the target lacks are sent,
#' each verified by MD5, and the target's catalogs are switched last. A
#' geospatial dataset's index table travels with it.
#'
#' Copying into the primary changes the store's current version of the
#' dataset; [store_sync()] then brings the other secondaries to it. Files of
#' the version the target replaces are deleted when the dataset keeps no
#' history, as in [store_write()].
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place.
#' @param dataset The dataset's full name, or its last part when that is
#'   unique among the datasets of `from`.
#' @param from,to Addresses of two locations of the connection.
#' @return A one-row tibble, invisibly: `dataset`, `from`, `to`, `version`,
#'   `status` (`"copied"`, or `"same"` when `to` already held this version),
#'   `files` (files of the version), `uploaded` (files sent), `bytes` and
#'   `seconds`.
#' @seealso [store_sync()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-copy")
#' store_create(file.path(root, "copy"))
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' st <- store_connect(file.path(root, "primary"),
#'   secondary = file.path(root, "copy")
#' )
#' store_copy(st, "sales/daily",
#'   from = file.path(root, "primary"), to = file.path(root, "copy")
#' )
#' store_status(st)
#' unlink(root, recursive = TRUE)
store_copy <- function(st, dataset, from, to) {
  validate_store(st)
  local_trace("store_copy")
  call <- rlang::current_env()
  check_string(dataset, call = call)
  from_uri <- location_arg(st, from, "from", call)
  to_uri <- location_arg(st, to, "to", call)
  if (identical(from_uri, to_uri)) {
    cli::cli_abort(
      "{.arg from} and {.arg to} name the same location {.path {from_uri}}.",
      class = "rcs_error_argument", call = call
    )
  }
  for (uri in c(from_uri, to_uri)) {
    location <- current_location(st, uri)
    role <- if (identical(uri, st$primary$uri)) "primary" else "secondary"
    reach(location_refresh(st, location), location$backend, role, call)
  }
  source <- current_location(st, from_uri)
  name <- resolve_in_location(source, dataset, call)
  now <- now_utc()
  dir <- sync_staging_dir("rcs-copy")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  unit <- sync_fresh_manifests(sync_unit(st, source, name), dir, now)
  ctx <- write_context(st, dir)
  ctx$primary <- source$backend
  entry <- unit$sets[[1]]$entry
  version <- entry$version
  n_files <- as.numeric(entry$n_files)
  rcs_inform(c(i = "Copying {.val {name}} (version {version}, {n_files} file{?s}) from {.path {from_uri}} to {.path {to_uri}}."))

  target <- current_location(st, to_uri)
  landed <- tryCatch(
    land_location(st, target, unit$sets, unit$drops, unit$keep_history, ctx, now),
    error = function(e) e
  )
  if (inherits(landed, "error")) {
    landed <- landed_anyway(st, target, unit$sets, unit$drops, landed)
  }
  if (inherits(landed, "error")) {
    if (!inherits(landed, write_error_classes)) {
      rlang::cnd_signal(landed)
    }
    cli::cli_abort(
      c(
        "Copying {.val {name}} to {.path {to_uri}} failed.",
        i = "No catalog of {.path {to_uri}} was changed. Run the call again: files already sent are reused."
      ),
      class = c("rcs_error_write", setdiff(class(landed), c("rlang_error", "error", "condition"))),
      parent = landed, call = call
    )
  }
  status <- if (identical(landed$status, "same")) "same" else "copied"
  if (status == "same") {
    rcs_inform(c(v = "{.path {to_uri}} already holds this version of {.val {name}}."))
  } else {
    sent <- landed$uploaded
    total <- landed$total
    size <- if (landed$bytes > 0) paste0(" (", format_bytes(landed$bytes), ")") else ""
    secs <- format_seconds(landed$seconds)
    rcs_inform(c(v = "{sent}/{total} file{?s} sent{size} in {secs}, MD5 verified. Catalogs of {.path {to_uri}} updated."))
  }
  invisible(tibble::tibble(
    dataset = name, from = from_uri, to = to_uri, version = version, status = status,
    files = as.numeric(landed$total), uploaded = as.numeric(landed$uploaded),
    bytes = as.numeric(landed$bytes), seconds = as.numeric(landed$seconds)
  ))
}

# A dataset name resolved in the catalog of one location: the full name, or
# a last part that is unique among its datasets that are not index tables.
resolve_in_location <- function(location, dataset, call) {
  catalog <- location$catalog
  candidates <- catalog$dataset[!is_index_entry(catalog)]
  if (dataset %in% candidates) {
    return(dataset)
  }
  short <- candidates[dataset_last_segment(candidates) == dataset]
  if (length(short) == 1) {
    return(short)
  }
  uri <- location$uri
  if (length(short) > 1) {
    cli::cli_abort(
      c(
        "The name {.val {dataset}} is ambiguous in {.path {uri}}.",
        i = "It is the last part of {.val {short}}; use the full name."
      ),
      class = "rcs_error_dataset_ambiguous", call = call
    )
  }
  close <- closest_names(dataset, candidates)
  cli::cli_abort(
    c(
      "No dataset {.val {dataset}} in {.path {uri}}.",
      i = if (length(close) > 0) "Closest name{?s}: {.val {close}}."
    ),
    class = "rcs_error_dataset_not_found", call = call
  )
}

# store_delete() ----------------------------------------------------------------

#' Delete a dataset
#'
#' Removes a dataset, and its index table, from every available location:
#' first its entry from the catalogs of every location (the primary first),
#' then the files of its current version. The earlier versions kept in the
#' history stay readable with `store_read(version = )` unless `history =
#' TRUE`, which removes them, their files and their manifests as well.
#'
#' As a guard against slips, `confirm` must repeat the dataset's full name.
#'
#' If the primary fails, nothing is changed and the call aborts. If a
#' secondary fails, the call warns and goes on; run it again to remove the
#' dataset there. Files that could not be deleted are no longer named by
#' any catalog; [store_prune()] removes them. Deleting a dataset that no
#' location lists informs and changes nothing.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place.
#' @param dataset The dataset's full name, or its last part when that is
#'   unique.
#' @param confirm The dataset's full name, typed again.
#' @param history `TRUE` also removes the dataset's history versions.
#' @return A tibble, invisibly, one row per location: `location`, `role`,
#'   `status` (`"deleted"`, `"absent"` when the location did not list the
#'   dataset, `"behind"` when it failed, `"unavailable"`), `files` (files
#'   deleted) and `bytes`.
#' @seealso [store_prune()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-delete")
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales."
#' )
#' store_delete(st, "daily", confirm = "sales/daily")
#' st
#' unlink(root, recursive = TRUE)
store_delete <- function(st, dataset, confirm, history = FALSE) {
  validate_store(st)
  local_trace("store_delete")
  call <- rlang::current_env()
  check_string(dataset, call = call)
  check_flag(history, call = call)
  confirm <- if (missing(confirm)) NULL else confirm
  failed <- write_refresh(st, call)
  name <- delete_resolve(st, dataset, call)
  if (!identical(confirm, name)) {
    cli::cli_abort(
      c(
        "{.arg confirm} must repeat the full name of the dataset to delete.",
        i = "To delete {.val {name}}, call {.code store_delete(st, \"{name}\", confirm = \"{name}\")}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  names <- c(name, index_name(name))
  now <- now_utc()

  # Which locations list it (in the catalog, or in the history to remove).
  locations <- store_locations(st)
  listed <- vapply(locations, function(location) {
    location$available && !location$uri %in% names(failed) &&
      any(names %in% location$catalog$dataset)
  }, logical(1))
  histories <- list()
  if (history) {
    for (i in seq_along(locations)) {
      location <- locations[[i]]
      if (!location$available || location$uri %in% names(failed)) next
      if (i == 1) {
        histories[[location$uri]] <- reach(history_read(location$backend), location$backend, "primary", call)
        listed[[i]] <- listed[[i]] || any(histories[[location$uri]]$dataset %in% names)
        next
      }
      h <- tryCatch(history_read(location$backend), rcs_error_backend = function(e) e)
      if (inherits(h, "error")) {
        uri <- location$uri
        cli::cli_warn(
          "Cannot read the history of the secondary location {.path {uri}}; it is skipped.",
          class = "rcs_warning_secondary_behind", parent = h
        )
        failed[[uri]] <- first_line(conditionMessage(h))
        listed[[i]] <- FALSE
        next
      }
      histories[[location$uri]] <- h
      listed[[i]] <- listed[[i]] || any(h$dataset %in% names)
    }
  }
  if (!any(listed) && length(failed) == 0) {
    rcs_inform(c(i = "No location lists {.val {name}}; nothing to delete."))
    return(invisible(vctrs::vec_rbind(!!!lapply(seq_along(locations), function(i) {
      delete_result_row(delete_result(locations[[i]]$uri, if (i == 1) "primary" else "secondary", "absent"))
    }))))
  } else {
    what <- if (history) "with its history" else "keeping its history"
    rcs_inform(c(i = "Deleting {.val {name}} and its index table from every location, {what}."))
  }

  # Phase 1: the catalogs, primary first.
  results <- list()
  pending <- list()
  for (i in seq_along(locations)) {
    location <- locations[[i]]
    uri <- location$uri
    role <- if (i == 1) "primary" else "secondary"
    if (uri %in% names(failed) || !location$available) {
      status <- if (!location$available || identical(failed[[uri]], "unavailable")) "unavailable" else "behind"
      results[[uri]] <- delete_result(uri, role, status, message = failed[[uri]] %||% NA_character_)
      next
    }
    if (!listed[[i]]) {
      results[[uri]] <- delete_result(uri, role, "absent")
      next
    }
    sink <- new.env(parent = emptyenv())
    switched <- tryCatch(
      delete_switch(st, current_location(st, uri), names, history, histories[[uri]], now, sink),
      error = function(e) e
    )
    if (inherits(switched, "error")) {
      switched <- deleted_anyway(st, uri, names, history, sink, switched)
    }
    if (inherits(switched, "error")) {
      if (!inherits(switched, write_error_classes)) {
        rlang::cnd_signal(switched)
      }
      if (i == 1) {
        cli::cli_abort(
          c(
            "Deleting {.val {name}} from the primary location {.path {uri}} failed.",
            i = "No catalog was changed. Run the call again."
          ),
          class = c("rcs_error_write", setdiff(class(switched), c("rlang_error", "error", "condition"))),
          parent = switched, call = call
        )
      }
      cli::cli_warn(
        c(
          "Deleting {.val {name}} from the secondary location {.path {uri}} failed; it still lists it.",
          i = "Run {.fn store_delete} again."
        ),
        class = "rcs_warning_secondary_behind", parent = switched
      )
      results[[uri]] <- delete_result(uri, role, "behind", message = first_line(conditionMessage(switched)))
      next
    }
    pending[[uri]] <- switched
    results[[uri]] <- delete_result(uri, role, "deleted")
  }

  # Phase 2: the files, in every location whose catalogs were switched.
  for (uri in names(pending)) {
    gone <- delete_files(st, uri, pending[[uri]])
    results[[uri]]$files <- gone$files
    results[[uri]]$bytes <- gone$bytes
  }

  widths <- write_widths(locations)
  for (r in results) delete_line(r, widths)
  out <- vctrs::vec_rbind(!!!lapply(unname(results), delete_result_row))
  n_deleted <- sum(out$status == "deleted")
  if (n_deleted > 0) {
    rcs_inform(c(v = "{.val {name}} is removed from {n_deleted} location{?s}."))
  }
  n_behind <- sum(out$status %in% c("behind", "unavailable"))
  if (n_behind > 0) {
    rcs_inform(c("!" = "{n_behind} secondary location{?s} could not be checked or changed; run {.fn store_delete} again once {?it/they} can be reached."))
  }
  invisible(out)
}

# The full name of the dataset to delete: as the primary catalog resolves
# it, else the name as given when it is a valid full name (a dataset listed
# only by a secondary, only in the history, or by no location at all).
delete_resolve <- function(st, dataset, call) {
  found <- tryCatch(
    resolve_dataset(st, dataset, index = FALSE, call = call),
    rcs_error_dataset_not_found = function(e) e
  )
  if (!inherits(found, "error")) {
    return(found)
  }
  if (is_index_name(dataset) || dataset %in% st$primary$catalog$dataset) {
    parent <- index_parent(dataset)
    cli::cli_abort(
      c(
        "{.val {dataset}} is an index table; it is deleted with its dataset.",
        i = "Delete {.val {parent}} instead."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  check_dataset_name(dataset, call = call)
  dataset
}

#' Remove datasets from the catalogs of one location
#'
#' Under the write guard: drops the entries and current file rows of
#' `names` (`catalog_drop_dataset()` without history) and, with `purge`, the
#' rows of `names` in the history; writes the catalogs (`_history.parquet`
#' only when it changed); a failed switch is recovered as in
#' `switch_catalogs()`. Deletes nothing.
#'
#' @return A list: `delete` (relative paths no row names any more: data
#'   files first, then manifests) and `bytes` (named by path, from the rows
#'   removed).
#' @noRd
delete_switch <- function(st, location, names, purge, history, replaced, sink = new.env()) {
  be <- location$backend
  guard <- write_guard(location)
  history <- history %||% history_read(be)
  catalog <- location$catalog
  files <- location$files
  hist <- history
  removed <- files[files$dataset %in% names, ]
  delete <- character()
  if (purge) {
    dropped <- hist[hist$dataset %in% names, ]
    hist <- hist[!hist$dataset %in% names, ]
    versions <- unique(dropped[c("dataset", "version")])
    delete <- c(dropped$path, manifest_path(versions$dataset, versions$version))
    removed <- vctrs::vec_rbind(removed, dropped[names(removed)])
  }
  for (d in names) {
    new <- catalog_drop_dataset(catalog, files, hist, d, keep_history = FALSE, replaced = replaced)
    catalog <- new$catalog
    files <- new$files
    hist <- new$history
    delete <- c(delete, new$delete)
  }
  history_changed <- nrow(hist) != nrow(history)
  written <- tryCatch(
    with_retry(function() location_write(location, catalog, files, if (history_changed) hist)),
    error = function(e) e
  )
  if (inherits(written, "error")) {
    written <- recover_switch(location, history, history_changed, written, list(), names)
  }
  guard$switched <- TRUE
  store_set_location(st, written)
  delete <- setdiff(unique(delete), c(written$files$path, hist$path))
  is_manifest <- grepl("/_manifest-[0-9a-f]{16}\\.json$", delete)
  bytes <- as.numeric(removed$bytes)[match(delete, removed$path)]
  sink$result <- list(delete = c(delete[!is_manifest], delete[is_manifest]), bytes = stats::setNames(bytes, delete))
  sink$result
}

# After a failed catalog switch of a deletion: re-read the location; when it
# no longer lists the datasets (the error came after the switch), the switch
# counts as done.
deleted_anyway <- function(st, uri, names, purge, sink, error) {
  fresh <- tryCatch(location_refresh(st, uri), error = function(e) NULL)
  if (is.null(fresh) || is.null(sink$result) || !inherits(error, write_error_classes) ||
    any(names %in% fresh$catalog$dataset)) {
    return(error)
  }
  if (purge) {
    history <- tryCatch(history_read(fresh$backend), error = function(e) NULL)
    if (is.null(history) || any(history$dataset %in% names)) {
      return(error)
    }
  }
  cli::cli_warn(
    "The catalogs of {.path {uri}} were switched, but the call failed afterwards.",
    class = "rcs_warning_after_switch", parent = error
  )
  sink$result
}

# Delete the files a catalog switch left unnamed, under the write guard of
# the location as switched. A failure warns: the files are orphans for
# `store_prune()`.
delete_files <- function(st, uri, switched) {
  paths <- switched$delete
  if (length(paths) == 0) {
    return(list(files = 0, bytes = 0))
  }
  location <- current_location(st, uri)
  be <- location$backend
  guarded <- function() {
    # The catalogs were switched in phase 1.
    guard <- write_guard(location)
    guard$switched <- TRUE
    data <- paths[!grepl("/_manifest-[0-9a-f]{16}\\.json$", paths)]
    if (length(data) > 0) be_delete(be, data)
    manifests <- setdiff(paths, data)
    if (length(manifests) > 0) be_delete(be, manifests)
    TRUE
  }
  done <- tryCatch(guarded(), error = function(e) e)
  if (inherits(done, "error")) {
    if (!inherits(done, write_error_classes)) {
      rlang::cnd_signal(done)
    }
    n <- length(paths)
    cli::cli_warn(
      c(
        "Cannot delete {n} file{?s} of the dataset in {.path {uri}}.",
        i = "No catalog names them any more; {.fn store_prune} removes them later."
      ),
      class = "rcs_warning_delete", parent = done
    )
    return(list(files = 0, bytes = 0))
  }
  data_bytes <- switched$bytes[paths]
  list(files = length(paths), bytes = sum(data_bytes, na.rm = TRUE))
}

delete_result <- function(uri, role, status, files = 0, bytes = 0, message = NA_character_) {
  list(location = uri, role = role, status = status, files = files, bytes = bytes, message = message)
}

delete_result_row <- function(r) {
  tibble::tibble(
    location = r$location, role = r$role, status = r$status,
    files = as.numeric(r$files), bytes = as.numeric(r$bytes)
  )
}

delete_line <- function(r, widths) {
  gap <- strrep(nbsp, 2)
  head <- paste0(pad_right(r$role, widths$role), gap, pad_right(r$location, widths$uri))
  detail <- switch(
    r$status,
    deleted = paste0(
      format(r$files), if (r$files == 1) " file" else " files", " deleted",
      if (r$bytes > 0) paste0(gap, format_bytes(r$bytes))
    ),
    absent = "not listed",
    behind = paste0("behind: ", r$message),
    unavailable = "unavailable, skipped"
  )
  bullet <- switch(r$status, behind = "x", unavailable = "!", "v")
  rcs_inform(stats::setNames(escape_braces(paste0(head, gap, detail)), bullet))
}

# store_rebuild() ---------------------------------------------------------------

#' Rebuild the catalogs of a location
#'
#' Writes the three catalog files of a location again from what it stores,
#' for a location whose catalogs were lost or damaged. For each dataset, the
#' manifest with the latest time of writing whose files all exist gives the
#' current version; earlier complete manifests become its history. A
#' dataset without any manifest is rebuilt from the metadata embedded in its
#' Parquet files, when they all belong to one version. Everything else is
#' reported as skipped: datasets whose manifests all name missing files,
#' files of several versions without manifest, data files without metadata,
#' rasters without manifest.
#'
#' A rebuild knows only what is stored: a dataset deleted with its history
#' kept (`store_delete(history = FALSE)`) is listed again with its latest
#' kept version, and the manifest of a write that failed after its files and
#' manifest were uploaded counts as that write's version; [store_prune()]
#' removes such orphans first.
#'
#' The location is listed, so the call reads every manifest and the footer
#' of every data file without manifest; it takes the location's write guard
#' before it writes.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place, and a secondary that was unavailable becomes available.
#' @param location The address of a location of the connection.
#' @return A tibble, invisibly, one row per dataset rebuilt and per item
#'   skipped: `dataset` (`NA` for files of no known dataset), `status`
#'   (`"rebuilt"` or `"skipped"`), `version`, `n_files`, `history` (number of
#'   earlier versions), `reason` (why it was skipped) and `paths` (a list
#'   column: the files concerned).
#' @seealso [store_check()] to find damaged files, [store_prune()].
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-rebuild")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' # The catalogs are lost
#' unlink(file.path(location, "_catalog.parquet"))
#' store_rebuild(st, location)
#' st
#' unlink(location, recursive = TRUE)
store_rebuild <- function(st, location) {
  validate_store(st)
  local_trace("store_rebuild")
  call <- rlang::current_env()
  uri <- location_arg(st, location, "location", call)
  current <- current_location(st, uri)
  be <- current$backend
  role <- if (identical(uri, st$primary$uri)) "primary" else "secondary"
  fresh <- tryCatch(location_read(be), rcs_error_backend = function(e) NULL, rcs_error_schema = function(e) NULL)
  if (is.null(fresh)) {
    token <- reach(catalog_token(be), be, role, call)
    fresh <- new_location(backend = be, token = token)
  }
  rebuilt <- reach(catalog_rebuild(be), be, role, call)
  guarded <- function() {
    guard <- write_guard(fresh)
    written <- with_retry(function() location_write(fresh, rebuilt$catalog, rebuilt$files, rebuilt$history))
    guard$switched <- TRUE
    written
  }
  written <- reach(guarded(), be, role, call)
  store_set_location(st, written)
  out <- rebuild_result(rebuilt)
  rebuild_report(uri, rebuilt, out)
  invisible(out)
}

rebuild_result <- function(rebuilt) {
  catalog <- rebuilt$catalog
  history <- rebuilt$history
  n_history <- vapply(catalog$dataset, function(d) {
    length(unique(history$version[history$dataset == d]))
  }, integer(1), USE.NAMES = FALSE)
  done <- tibble::tibble(
    dataset = catalog$dataset, status = rep("rebuilt", nrow(catalog)),
    version = catalog$version, n_files = as.numeric(catalog$n_files), history = n_history,
    reason = NA_character_, paths = rep(list(character()), nrow(catalog))
  )
  skipped <- rebuilt$skipped
  reasons <- vapply(skipped$reason, function(r) cli::ansi_strip(cli::format_inline(r)), character(1),
    USE.NAMES = FALSE
  )
  skipped <- tibble::tibble(
    dataset = skipped$dataset, status = rep("skipped", nrow(skipped)),
    version = NA_character_, n_files = NA_real_, history = NA_integer_,
    reason = reasons, paths = skipped$paths
  )
  vctrs::vec_rbind(done, skipped)
}

rebuild_report <- function(uri, rebuilt, out) {
  done <- out[out$status == "rebuilt", ]
  n <- nrow(done)
  n_files <- sum(done$n_files)
  n_history <- sum(done$history)
  rcs_inform(c(v = "Rebuilt the catalogs of {.path {uri}}: {n} dataset{?s} in {n_files} file{?s}, {n_history} earlier version{?s}."))
  skipped <- out[out$status == "skipped", ]
  if (nrow(skipped) == 0) {
    return(invisible())
  }
  k <- nrow(skipped)
  lines <- vapply(seq_len(k), function(i) {
    paths <- skipped$paths[[i]]
    shown <- paste(utils::head(paths, 3), collapse = ", ")
    if (length(paths) > 3) shown <- paste0(shown, ", and ", length(paths) - 3, " more")
    who <- if (is.na(skipped$dataset[[i]])) "" else paste0("\"", skipped$dataset[[i]], "\": ")
    escape_braces(paste0(who, skipped$reason[[i]], " (", shown, ")"))
  }, character(1))
  rcs_inform(c("!" = "Skipped {k} item{?s}:", rlang::set_names(lines, rep("x", k))))
  invisible()
}
