# Keeping the locations of a store in step: `store_sync()` (primary to
# secondaries), `store_copy()` (one dataset between any two locations),
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

#' Bring secondary locations up to date
#'
#' Copies datasets from the primary location to the secondary ones: every
#' dataset whose copy in a secondary is missing or differs from the
#' primary's (another version, or another entry). Only the files the
#' secondary lacks are sent, each verified by MD5; the catalogs of the
#' secondary are switched last, so that its readers always see a complete
#' version. A geospatial dataset's index table travels with it.
#'
#' `store_sync()` never deletes a dataset: datasets found only in a secondary
#' are left alone (see [store_status()], status `"extra"`). Files of a
#' version the secondary replaces are deleted when the dataset keeps no
#' history, as in [store_write()].
#'
#' A secondary that fails is reported as behind with a warning, and the next
#' one is synced; running the call again sends only what is still missing.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place.
#' @param datasets `NULL` for every dataset of the primary, or names of
#'   datasets (full names, or last parts that are unique).
#' @param to `NULL` for every secondary location, or the addresses of some
#'   of them.
#' @param dry_run `TRUE` reports what would be copied and changes nothing.
#' @return A tibble, invisibly, one row per secondary location: `location`,
#'   `status` (`"synced"`, `"same"` when nothing was missing, `"behind"`
#'   when it failed, `"unavailable"`, or `"to sync"` with `dry_run = TRUE`),
#'   `datasets` (a list column: the datasets copied, or to copy), `files`
#'   (files sent, or to send), `bytes` and `seconds`.
#' @seealso [store_status()] to compare the locations, [store_copy()] for one
#'   dataset between any two locations.
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
#' store_status(st)
#' unlink(root, recursive = TRUE)
store_sync <- function(st, datasets = NULL, to = NULL, dry_run = FALSE) {
  validate_store(st)
  local_trace("store_sync")
  call <- rlang::current_env()
  check_flag(dry_run, call = call)
  if (!is.null(datasets) && (!is.character(datasets) || length(datasets) == 0 || anyNA(datasets))) {
    cli::cli_abort(
      "{.arg datasets} must be {.code NULL} or a character vector of dataset names, not {.obj_type_friendly {datasets}}.",
      class = "rcs_error_argument", call = call
    )
  }
  targets <- sync_targets(st, to, call)
  failed <- sync_refresh(st, targets, call)
  names <- sync_dataset_names(st, datasets, call)
  units <- lapply(names, function(d) sync_unit(st, st$primary, d))
  now <- now_utc()

  dir <- sync_staging_dir("rcs-sync")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  ctx <- write_context(st, dir)
  units <- lapply(units, sync_fresh_manifests, dir = dir, now = now)

  widths <- write_widths(store_locations(st))
  sync_header(st, names, targets, dry_run)
  results <- list()
  for (uri in targets) {
    result <- if (uri %in% names(failed)) {
      sync_result(uri, if (identical(failed[[uri]], "unavailable")) "unavailable" else "behind",
        message = failed[[uri]]
      )
    } else if (dry_run) {
      sync_plan_location(st, uri, units)
    } else {
      sync_location(st, uri, units, ctx, now)
    }
    sync_line(result, widths)
    results[[length(results) + 1L]] <- result
  }
  out <- vctrs::vec_rbind(sync_empty(), !!!lapply(results, sync_result_row))
  sync_footer(out, dry_run)
  invisible(out)
}

# Addresses of the secondary locations a sync goes to.
sync_targets <- function(st, to, call) {
  secondaries <- vapply(st$secondary, function(l) l$uri, character(1))
  if (is.null(to)) {
    return(secondaries)
  }
  if (!is.character(to) || length(to) == 0 || anyNA(to)) {
    cli::cli_abort(
      "{.arg to} must be {.code NULL} or addresses of secondary locations, not {.obj_type_friendly {to}}.",
      class = "rcs_error_argument", call = call
    )
  }
  uris <- vapply(to, function(x) location_arg(st, x, "to", call), character(1), USE.NAMES = FALSE)
  if (st$primary$uri %in% uris) {
    uri <- st$primary$uri
    cli::cli_abort(
      c(
        "{.arg to} names the primary location {.path {uri}}.",
        i = "{.fn store_sync} copies from the primary to secondary locations; use {.fn store_copy} to copy into the primary."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  secondaries[secondaries %in% uris]
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

# Re-read the catalogs of the primary and of the given secondaries. The
# primary must answer; a secondary that does not is returned by name (its
# `uri`) with the error message, or "unavailable" for a location unavailable
# since the connection.
sync_refresh <- function(st, uris, call) {
  be <- st$primary$backend
  reach(location_refresh(st, st$primary), be, "primary", call)
  failed <- list()
  for (location in st$secondary) {
    uri <- location$uri
    if (!uri %in% uris) next
    if (!location$available) {
      failed[[uri]] <- "unavailable"
      next
    }
    fresh <- tryCatch(location_refresh(st, location), error = function(e) e)
    if (inherits(fresh, "error")) {
      if (!inherits(fresh, write_error_classes)) {
        rlang::cnd_signal(fresh)
      }
      cli::cli_warn(
        c("Cannot read the catalogs of the secondary location {.path {uri}}; it is skipped.",
          i = "Run the call again once it can be reached."),
        class = "rcs_warning_secondary_behind", parent = fresh
      )
      failed[[uri]] <- first_line(conditionMessage(fresh))
    }
  }
  failed
}

# Full names of the datasets to sync; index tables travel with their dataset.
sync_dataset_names <- function(st, datasets, call) {
  catalog <- st$primary$catalog
  if (is.null(datasets)) {
    return(catalog$dataset[!is_index_entry(catalog)])
  }
  unique(vapply(datasets, function(d) resolve_dataset(st, d, index = FALSE, call = call), character(1),
    USE.NAMES = FALSE
  ))
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
# version and none of `drops` (the error came after the catalog switch, e.g.
# when the lock could not be released), the landing counts as done and the
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

# Land the units a secondary lacks: one catalog switch per history setting.
sync_location <- function(st, uri, units, ctx, now) {
  start <- Sys.time()
  location <- current_location(st, uri)
  needed <- Filter(function(u) unit_needed(location, u), units)
  if (length(needed) == 0) {
    return(sync_result(uri, "same"))
  }
  groups <- split(needed, vapply(needed, function(u) u$keep_history, logical(1)))
  done <- character()
  total <- 0
  sent <- 0
  bytes <- 0
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
      if (!inherits(landed, write_error_classes)) {
        rlang::cnd_signal(landed)
      }
      cli::cli_warn(
        c(
          "Syncing the secondary location {.path {uri}} failed; it is behind.",
          i = "Run {.fn store_sync} again: files already sent are reused."
        ),
        class = "rcs_warning_secondary_behind", parent = landed
      )
      return(sync_result(uri, "behind",
        datasets = done, files = sent, bytes = bytes,
        message = first_line(conditionMessage(landed))
      ))
    }
    done <- c(done, vapply(group, function(u) u$dataset, character(1)))
    total <- total + landed$total
    sent <- sent + landed$uploaded
    bytes <- bytes + landed$bytes
  }
  sync_result(uri, "synced",
    datasets = done, files = sent, total = total, bytes = bytes,
    seconds = as.numeric(difftime(Sys.time(), start, units = "secs"))
  )
}

# What a dry run reports: the units a secondary lacks and the files it would
# be sent (compared by path and MD5 with its catalogs, then with what is
# stored).
sync_plan_location <- function(st, uri, units) {
  location <- current_location(st, uri)
  needed <- Filter(function(u) unit_needed(location, u), units)
  if (length(needed) == 0) {
    return(sync_result(uri, "same"))
  }
  be <- location$backend
  sets <- do.call(c, lapply(needed, function(u) u$sets))
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
  sync_result(uri, "to sync",
    datasets = vapply(needed, function(u) u$dataset, character(1)),
    files = nrow(todo), total = nrow(rows), bytes = sum(as.numeric(todo$bytes))
  )
}

sync_result <- function(uri, status, datasets = character(), files = 0, total = NA_real_,
                        bytes = 0, seconds = 0, message = NA_character_) {
  list(
    location = uri, status = status, datasets = datasets, files = files,
    total = total, bytes = bytes, seconds = seconds, message = message
  )
}

sync_empty <- function() {
  tibble::tibble(
    location = character(), status = character(), datasets = list(),
    files = double(), bytes = double(), seconds = double()
  )
}

sync_result_row <- function(r) {
  tibble::tibble(
    location = r$location, status = r$status, datasets = list(r$datasets),
    files = as.numeric(r$files), bytes = as.numeric(r$bytes), seconds = as.numeric(r$seconds)
  )
}

sync_header <- function(st, names, targets, dry_run) {
  n <- length(names)
  k <- length(targets)
  uri <- st$primary$uri
  if (dry_run) {
    rcs_inform(c(i = "Dry run: nothing is changed."))
  }
  rcs_inform(c(i = "Syncing {n} dataset{?s} from the primary {.path {uri}} to {k} secondary location{?s}."))
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
  head <- paste0(pad_right("secondary", widths$role), gap, pad_right(r$location, widths$uri))
  n <- length(r$datasets)
  ds <- paste0(n, if (n == 1) " dataset" else " datasets")
  detail <- switch(
    r$status,
    synced = paste0(
      ds, ", ", format(r$files), "/", format(r$total), " files sent",
      if (r$bytes > 0) paste0(gap, format_bytes(r$bytes)), gap, format_seconds(r$seconds)
    ),
    same = "up to date",
    behind = paste0("behind: ", r$message),
    unavailable = "unavailable, skipped",
    `to sync` = paste0(
      "would copy ", ds, ", ", format(r$files), " file", if (r$files == 1) "" else "s",
      if (r$bytes > 0) paste0(" (", format_bytes(r$bytes), ")"), ": ", dataset_list_text(r$datasets)
    )
  )
  bullet <- switch(r$status, behind = "x", unavailable = "!", `to sync` = "*", "v")
  rcs_inform(stats::setNames(escape_braces(paste0(head, gap, detail)), bullet))
}

sync_footer <- function(out, dry_run) {
  if (dry_run || nrow(out) == 0) {
    return(invisible())
  }
  synced <- out[out$status == "synced", ]
  if (nrow(synced) > 0) {
    n <- sum(synced$files)
    k <- nrow(synced)
    rcs_inform(c(v = "MD5 identical for {n} file{?s} sent to {k} location{?s}. Catalogs updated."))
  } else if (all(out$status == "same")) {
    rcs_inform(c(v = "Every secondary location is up to date."))
  }
  n_behind <- sum(out$status %in% c("behind", "unavailable"))
  if (n_behind > 0) {
    rcs_inform(c("!" = "{n_behind} secondary location{?s} {?is/are} behind; run {.fn store_sync} again once {?it/they} can be reached."))
  }
  invisible()
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
  write_guard(location)
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
  store_set_location(st, written)
  delete <- setdiff(unique(delete), c(written$files$path, hist$path))
  is_manifest <- grepl("/_manifest-[0-9a-f]{16}\\.json$", delete)
  bytes <- as.numeric(removed$bytes)[match(delete, removed$path)]
  sink$result <- list(delete = c(delete[!is_manifest], delete[is_manifest]), bytes = stats::setNames(bytes, delete))
  sink$result
}

# After a failed catalog switch of a deletion: re-read the location; when it
# no longer lists the datasets (the error came after the switch, e.g. when
# the lock could not be released), the switch counts as done.
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
    write_guard(location)
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
    write_guard(fresh)
    with_retry(function() location_write(fresh, rebuilt$catalog, rebuilt$files, rebuilt$history))
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
