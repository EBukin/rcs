# `expect_store_valid(st)`: the store invariants of the plan ("Testing"),
# checked for every available location of a connection against what is
# stored (the catalogs are read again through the backend). Call it after
# every step of every integration test.
#
#   expect_store_valid(st, orphans_ok = FALSE, check_connection = TRUE)
#
#   orphans_ok        TRUE after an injected failure: unnamed files are then
#                     allowed (store_prune() must remove them later).
#   check_connection  TRUE: the catalogs held by `st` must equal the stored
#                     ones (token), i.e. the connection was updated in place.
#
# Invariants, per available location:
#   1. every file named by _files.parquet and _history.parquet exists with
#      the recorded bytes and MD5, and its Parquet footer has the recorded
#      rows; a path is never recorded with two different MD5s;
#   2. every entry's version equals the hash of its file rows, every file
#      row carries its entry's version, n_files, rows and bytes equal their
#      sums; no file row without entry; every history version hashes to its
#      version;
#   3. a manifest exists for every version in the catalogs and agrees with
#      them; no path is named by two datasets;
#   4. with history off, no file exists that the catalogs do not name;
#   5. every index table agrees with its dataset: every .rcs_id exists and
#      every h3_main equals the row's h3;
#   6. every secondary dataset with the primary's version has the primary's
#      file rows; when `store_status()` (work package D) is implemented, its
#      verdict (same / missing / differs, or primary only for a dataset the
#      secondary lacks whose primary entry has `primary_only` TRUE) matches
#      the catalogs.
#
# All problems are collected and reported in one failed expectation.

expect_store_valid <- function(st, orphans_ok = FALSE, check_connection = TRUE) {
  local_backend_fallback()
  withr::local_options(arrow.int64_downcast = FALSE, rcs.trace = FALSE)
  problems <- character()
  add <- function(...) problems <<- c(problems, paste0(...))

  locations <- store_locations(st, available_only = TRUE)
  stored <- list()
  for (location in locations) {
    uri <- location$uri
    tag <- function(...) add("[", uri, "] ", ...)
    fresh <- tryCatch(location_read(location$backend), error = function(e) {
      tag("catalogs cannot be read: ", conditionMessage(e))
      NULL
    })
    if (is.null(fresh)) next
    stored[[uri]] <- fresh
    if (check_connection && !identical(fresh$token, location$token)) {
      tag("the connection holds a stale catalog (token differs)")
    }
    invariant_location(st, fresh, history_read(location$backend), tag, orphans_ok)
  }
  if (length(stored) > 0) {
    invariant_secondaries(st, stored, add)
  }
  testthat::expect(
    length(problems) == 0,
    paste(c("The store breaks its invariants:", paste0("* ", problems)), collapse = "\n")
  )
  invisible(st)
}

invariant_location <- function(st, location, history, tag, orphans_ok) {
  be <- location$backend
  catalog <- location$catalog
  files <- location$files
  cols <- c("dataset", "version", "path", "md5", "rows", "bytes")
  named <- vctrs::vec_rbind(files[cols], history[cols])

  # 1. files exist with bytes, MD5 and rows
  paths <- unique(named$path)
  md5_by_path <- tapply(named$md5, named$path, function(m) length(unique(m)))
  if (any(md5_by_path > 1)) {
    tag("paths recorded with two MD5s: ", paste(names(md5_by_path)[md5_by_path > 1], collapse = ", "))
  }
  listing <- be_list(be, "")
  if (length(paths) > 0) {
    exists <- be_exists(be, paths)
    if (!all(exists)) tag("missing files: ", paste(paths[!exists], collapse = ", "))
    present <- paths[exists]
    rec <- named[match(present, named$path), ]
    md5 <- be_md5(be, present)
    bad <- present[md5 != rec$md5]
    if (length(bad) > 0) tag("MD5 differs from the catalog: ", paste(bad, collapse = ", "))
    bytes <- listing$bytes[match(present, listing$path)]
    bad <- present[bytes != as.numeric(rec$bytes)]
    if (length(bad) > 0) tag("bytes differ from the catalog: ", paste(bad, collapse = ", "))
    pq <- present[grepl("\\.parquet$", present)]
    if (length(pq) > 0) {
      groups <- files_row_groups(be, pq)
      footer <- vapply(pq, function(p) sum(groups$rows[groups$path == p]), numeric(1))
      bad <- pq[footer != as.numeric(rec$rows[match(pq, rec$path)])]
      if (length(bad) > 0) tag("footer rows differ from the catalog: ", paste(bad, collapse = ", "))
    }
  }

  # 2. versions and totals
  orphan_rows <- setdiff(files$dataset, catalog$dataset)
  if (length(orphan_rows) > 0) tag("file rows without entry: ", paste(orphan_rows, collapse = ", "))
  for (i in seq_len(nrow(catalog))) {
    entry <- catalog[i, ]
    rows <- files[files$dataset == entry$dataset, ]
    ds <- entry$dataset
    if (nrow(rows) == 0) {
      tag(ds, ": no file rows")
      next
    }
    if (!all(rows$version == entry$version)) tag(ds, ": file rows carry another version")
    if (!identical(version_hash(rows$partition_values, rows$md5), entry$version)) {
      tag(ds, ": version is not the hash of its files")
    }
    if (as.numeric(entry$n_files) != nrow(rows)) tag(ds, ": n_files differs from its files")
    if (as.numeric(entry$rows) != sum(as.numeric(rows$rows))) tag(ds, ": rows differ from its files")
    if (as.numeric(entry$bytes) != sum(as.numeric(rows$bytes))) tag(ds, ": bytes differ from its files")
  }
  hist_versions <- unique(history[c("dataset", "version")])
  for (i in seq_len(nrow(hist_versions))) {
    rows <- history_version_rows(history, hist_versions$dataset[[i]], hist_versions$version[[i]])
    if (!identical(version_hash(rows$partition_values, rows$md5), hist_versions$version[[i]])) {
      tag(hist_versions$dataset[[i]], ": history version ", hist_versions$version[[i]], " is not the hash of its files")
    }
  }

  # 3. manifests, and no path named by two datasets
  entry_kinds <- schema_field_kinds(catalog_schema())
  file_kinds <- schema_field_kinds(files_schema())
  entry_json <- function(e) to_json(row_to_list(e, entry_kinds))
  rows_json <- function(r) {
    r <- r[order(r$path, method = "radix"), names(file_kinds)]
    kinds <- file_kinds
    vapply(seq_len(nrow(r)), function(i) to_json(row_to_list(r[i, ], kinds)), character(1))
  }
  versions <- unique(vctrs::vec_rbind(catalog[c("dataset", "version")], hist_versions))
  for (i in seq_len(nrow(versions))) {
    ds <- versions$dataset[[i]]
    v <- versions$version[[i]]
    m <- invariant_manifest(be, ds, v)
    if (is.null(m)) {
      tag(ds, ": no readable manifest of version ", v)
      next
    }
    current <- catalog[catalog$dataset == ds & catalog$version == v, ]
    if (nrow(current) == 1) {
      if (!identical(entry_json(m$entry), entry_json(current))) tag(ds, ": manifest entry differs from the catalog")
      if (!identical(rows_json(m$files), rows_json(files[files$dataset == ds, ]))) {
        tag(ds, ": manifest files differ from the catalog")
      }
    } else {
      old <- history_version_rows(history, ds, v)
      if (!identical(sort(paste(m$files$path, m$files$md5)), sort(paste(old$path, old$md5)))) {
        tag(ds, ": manifest of history version ", v, " differs from the history")
      }
    }
  }
  owners <- tapply(named$dataset, named$path, function(d) length(unique(d)))
  if (any(owners > 1)) tag("paths named by two datasets: ", paste(names(owners)[owners > 1], collapse = ", "))

  # 4. no unnamed file with history off
  if (!orphans_ok) {
    allowed <- c(
      catalog_files, store_file, named$path,
      manifest_path(versions$dataset, versions$version)
    )
    extra <- setdiff(listing$path, allowed)
    extra <- extra[!startsWith(extra, paste0(lock_dir, "/"))]
    known <- unique(c(catalog$dataset, history$dataset))
    for (p in extra) {
      owner <- known[startsWith(p, paste0(known, "/"))]
      owner <- if (length(owner) > 0) owner[which.max(nchar(owner))] else NA_character_
      setting <- if (!is.na(owner) && owner %in% catalog$dataset) catalog$history[catalog$dataset == owner] else NA
      if (!effective_history(st, setting)) tag("file named by no catalog, with history off: ", p)
    }
  }

  # 5. index tables
  indexes <- catalog[!is.na(catalog$index_of), ]
  for (i in seq_len(nrow(indexes))) {
    parent <- indexes$index_of[[i]]
    if (!parent %in% catalog$dataset) {
      tag(indexes$dataset[[i]], ": indexes the missing dataset ", parent)
      next
    }
    read_cols <- function(ds, columns) {
      paths <- files$path[files$dataset == ds]
      tables <- lapply(paths, function(p) {
        groups <- files_row_groups(be, p)
        if (nrow(groups) == 0) return(NULL)
        as.data.frame(files_read_row_groups(be, p, groups$row_group, columns))
      })
      vctrs::vec_rbind(!!!tables)
    }
    index <- read_cols(indexes$dataset[[i]], c(".rcs_id", "h3_main"))
    rows <- read_cols(parent, c(".rcs_id", "h3"))
    at <- match(as.character(index$.rcs_id), as.character(rows$.rcs_id))
    if (anyNA(at)) {
      tag(indexes$dataset[[i]], ": .rcs_id values missing from ", parent)
    } else if (!identical(as.character(index$h3_main), as.character(rows$h3[at]))) {
      tag(indexes$dataset[[i]], ": h3_main differs from the h3 of ", parent)
    }
  }
}

# Parsed manifests by MD5: copies of a store hold the same manifests, and
# parsing one costs more than hashing it.
invariant_manifest_cache <- new.env(parent = emptyenv())

invariant_manifest <- function(be, dataset, version) {
  md5 <- be_md5(be, manifest_path(dataset, version))
  if (is.na(md5)) return(NULL)
  cached <- invariant_manifest_cache[[md5]]
  if (is.null(cached)) {
    cached <- tryCatch(manifest_read(be, dataset, version), error = function(e) NULL)
    if (!is.null(cached)) invariant_manifest_cache[[md5]] <- cached
  }
  cached
}

invariant_secondaries <- function(st, stored, add) {
  primary <- stored[[st$primary$uri]]
  if (is.null(primary)) return(invisible())
  key_cols <- c("path", "partition_values", "md5", "rows", "bytes")
  rows_of <- function(location, ds) {
    r <- location$files[location$files$dataset == ds, key_cols]
    r <- r[order(r$path, method = "radix"), ]
    paste(r$path, r$partition_values, r$md5, as.character(r$rows), as.character(r$bytes))
  }
  expected <- list()
  for (uri in setdiff(names(stored), st$primary$uri)) {
    secondary <- stored[[uri]]
    for (ds in primary$catalog$dataset) {
      v <- primary$catalog$version[primary$catalog$dataset == ds]
      sv <- secondary$catalog$version[secondary$catalog$dataset == ds]
      primary_only <- isTRUE(primary$catalog[["primary_only"]][primary$catalog$dataset == ds])
      state <- if (length(sv) == 0 && primary_only) {
        "primary only"
      } else if (length(sv) == 0) {
        "missing"
      } else if (identical(sv, v)) {
        "same"
      } else {
        "differs"
      }
      if (state == "same" && !identical(rows_of(primary, ds), rows_of(secondary, ds))) {
        add("[", uri, "] ", ds, ": same version as the primary but other file rows")
      }
      expected[[length(expected) + 1L]] <- tibble::tibble(dataset = ds, location = uri, expected = state)
    }
  }
  status_fn <- get0("store_status", envir = asNamespace("rcs"), inherits = FALSE)
  if (is.null(status_fn) || length(expected) == 0) return(invisible())
  status <- tryCatch(status_fn(st), rcs_error_not_implemented = function(e) NULL)
  if (is.null(status)) return(invisible())
  if (!all(c("dataset", "location", "status") %in% names(status))) {
    add("store_status() has no columns dataset, location and status; update helper-invariants.R")
    return(invisible())
  }
  expected <- vctrs::vec_rbind(!!!expected)
  got <- status$status[match(paste(expected$dataset, expected$location), paste(status$dataset, status$location))]
  bad <- which(is.na(got) | got != expected$expected)
  for (i in bad) {
    add("store_status() says ", got[[i]], " for ", expected$dataset[[i]], " in ", expected$location[[i]],
      "; the catalogs say ", expected$expected[[i]])
  }
}
