# Catalog I/O: the three catalog files, `_store.json` and the manifests of a
# location, read and written through its backend; the file lookup used by
# every read; the changes a new version makes to the catalog tables; and the
# rebuild of a location's catalogs from its manifests and data files.
#
# Order of writes in a location: `_history.parquet`, `_files.parquet`,
# `_catalog.parquet` (`location_write()`). Order of reads: `_catalog.parquet`,
# `_files.parquet` (`location_read()`); `_history.parquet` is read on demand
# (`history_read()`). Every catalog file read counts one `catalog_read`.
#
# Catalog files are transferred whole with `be_get()` / `be_put()`: they are
# small, and the MD5 of the bytes read is the write guard's token.

# Catalog files ---------------------------------------------------------------

#' Read or write one catalog file of a location
#'
#' `catalog_read()` downloads the file to a temporary file, counts one
#' `catalog_read` (detail = the file name) and converts it with
#' `schema_as_tibble()`. `catalog_write()` converts with `schema_as_arrow()`,
#' writes a temporary Parquet file and uploads it with `be_put()`.
#'
#' @param be A backend object.
#' @param which `"catalog"`, `"files"` or `"history"`.
#' @param x A tibble in the in-memory form of `which`.
#' @param missing_ok `TRUE` returns the empty table when the file does not
#'   exist (checked with `be_exists()`) instead of aborting. Default `TRUE`
#'   for `"history"` only.
#' @return `catalog_read()`: the tibble, with the attribute `md5` (hex MD5 of
#'   the bytes read; `NA` when the file was missing). `catalog_write()`: the
#'   hex MD5 of the file written, invisibly. Both abort with class
#'   `rcs_error_backend` when the transfer fails, and `catalog_read()` with
#'   `rcs_error_schema` when the file is not a valid catalog file.
#' @noRd
catalog_read <- function(be, which = c("catalog", "files", "history"),
                         missing_ok = which == "history") {
  which <- rlang::arg_match(which)
  file <- catalog_files[[which]]
  if (isTRUE(missing_ok) && !be_exists(be, file)) {
    out <- schema_empty(which)
    attr(out, "md5") <- NA_character_
    return(out)
  }
  tmp <- withr::local_tempfile(fileext = ".parquet")
  be_get(be, file, tmp)
  trace_count("catalog_read", 1, location = be$uri, detail = file)
  table <- tryCatch(
    arrow::read_parquet(tmp, as_data_frame = FALSE),
    error = function(e) {
      cli::cli_abort(
        "{.path {file}} of {.path {be$uri}} is not a readable Parquet file.",
        class = "rcs_error_schema", parent = e
      )
    }
  )
  out <- schema_as_tibble(table, which)
  attr(out, "md5") <- md5_file(tmp)
  out
}

#' @rdname catalog_read
#' @noRd
catalog_write <- function(be, x, which = c("catalog", "files", "history")) {
  which <- rlang::arg_match(which)
  x <- strip_md5_attr(x)
  table <- schema_as_arrow(x, which)
  tmp <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(table, tmp, compression = "zstd")
  be_put(be, tmp, catalog_files[[which]])
  invisible(md5_file(tmp))
}

strip_md5_attr <- function(x) {
  attr(x, "md5") <- NULL
  x
}

#' The write guard's token of a location
#'
#' @param be A backend object.
#' @return The hex MD5 of `_catalog.parquet` as stored (`be_md5()`), `NA`
#'   when it does not exist. Equal to `location$token` when nobody wrote the
#'   catalog since it was read.
#' @noRd
catalog_token <- function(be) {
  be_md5(be, catalog_files[["catalog"]])
}

#' Read `_history.parquet` of a location
#'
#' @param be A backend object.
#' @return A tibble of `history_schema()`; empty when the file does not exist.
#' @noRd
history_read <- function(be) {
  strip_md5_attr(catalog_read(be, "history", missing_ok = TRUE))
}

#' File rows of one version found in a history table
#'
#' @param history A tibble of `history_schema()`.
#' @param dataset,version One string each.
#' @return A tibble of `files_schema()`: the rows of that dataset and version
#'   without `replaced`, one per path (a version replaced twice is listed
#'   twice in the history), sorted by path.
#' @noRd
history_version_rows <- function(history, dataset, version) {
  rows <- history[history$dataset == dataset & history$version == version, ]
  rows <- rows[!duplicated(rows$path), names(schema_get("files"))]
  rows[order(rows$path, method = "radix"), ]
}

# Locations -------------------------------------------------------------------

#' Read the catalogs of a location
#'
#' Reads `_catalog.parquet`, then `_files.parquet`.
#'
#' @param be A backend object.
#' @return An `rcs_location` with `available = TRUE`, its `catalog` and
#'   `files`, and `token` = the MD5 of `_catalog.parquet` as read. Aborts with
#'   class `rcs_error_backend` when a file cannot be read (also when the
#'   location holds no catalogs: check with `location_exists()` first), and
#'   with `rcs_error_schema` when it is invalid.
#' @noRd
location_read <- function(be) {
  catalog <- catalog_read(be, "catalog", missing_ok = FALSE)
  files <- catalog_read(be, "files", missing_ok = FALSE)
  new_location(
    backend = be,
    catalog = strip_md5_attr(catalog),
    files = strip_md5_attr(files),
    token = attr(catalog, "md5"),
    available = TRUE
  )
}

#' Does a location hold catalogs?
#' @param be A backend object.
#' @return `TRUE` when `_catalog.parquet` exists.
#' @noRd
location_exists <- function(be) {
  isTRUE(be_exists(be, catalog_files[["catalog"]]))
}

#' Write the catalogs of a location
#'
#' Writes `_history.parquet` (when given), `_files.parquet` and
#' `_catalog.parquet`, in that order. Takes no lock and checks no token: the
#' write guard is the caller's.
#'
#' @param location An `rcs_location`.
#' @param catalog,files The new tables, in the in-memory form.
#' @param history The new history table, or `NULL` to leave the file as it is.
#' @return The updated `rcs_location` (new `catalog`, `files` and `token`).
#'   Pass it to `store_set_location()` to update the connection.
#' @noRd
location_write <- function(location, catalog, files, history = NULL) {
  be <- location$backend
  catalog <- strip_md5_attr(catalog)
  files <- strip_md5_attr(files)
  if (!is.null(history)) {
    catalog_write(be, history, "history")
  }
  catalog_write(be, files, "files")
  token <- catalog_write(be, catalog, "catalog")
  location$catalog <- catalog
  location$files <- files
  location$token <- token
  location
}

#' Initialise an empty location
#'
#' Writes `_store.json` with the store's history default, then the three
#' empty catalog files. Used by `store_create()` and `store_connect(create =
#' TRUE)`.
#'
#' @param be A backend object.
#' @param history The store's history default, `TRUE` or `FALSE`.
#' @return The new, empty `rcs_location`.
#' @noRd
location_init <- function(be, history = FALSE) {
  check_flag(history)
  store_json_write(be, history)
  location_write(
    new_location(backend = be),
    catalog_empty(), files_empty(), history_empty()
  )
}

#' Re-read the catalogs of one location of a connection
#'
#' Write functions call it for every location they touch before doing
#' anything else.
#'
#' @param st An `rcs_store`.
#' @param location The `rcs_location` (or its `uri`) to re-read.
#' @return The fresh `rcs_location`; `st` is updated in place.
#' @noRd
location_refresh <- function(st, location) {
  uri <- if (is.character(location)) location else location$uri
  i <- match(uri, store_uris(st))
  if (is.na(i)) {
    cli::cli_abort("{.path {uri}} is not a location of this connection.", class = "rcs_error_object")
  }
  fresh <- location_read(store_locations(st)[[i]]$backend)
  store_set_location(st, fresh)
  fresh
}

# _store.json -----------------------------------------------------------------

#' Read or write the store's settings, `_store.json`
#'
#' `{"history": false}` at the location root.
#'
#' @param be A backend object.
#' @param history `TRUE` or `FALSE`.
#' @return `store_json_read()`: the store's history default, `FALSE` when the
#'   file does not exist. `store_json_write()`: `history`, invisibly.
#' @noRd
store_json_read <- function(be) {
  if (!isTRUE(be_exists(be, store_file))) {
    return(FALSE)
  }
  tmp <- withr::local_tempfile(fileext = ".json")
  be_get(be, store_file, tmp)
  settings <- jsonlite::fromJSON(tmp, simplifyVector = FALSE)
  isTRUE(settings$history)
}

#' @rdname store_json_read
#' @noRd
store_json_write <- function(be, history) {
  check_flag(history)
  tmp <- withr::local_tempfile(fileext = ".json")
  writeLines(to_json(list(history = history)), tmp, useBytes = TRUE)
  be_put(be, tmp, store_file)
  invisible(history)
}

# Manifests -------------------------------------------------------------------

#' Write and read manifests
#'
#' `manifest_write_local()` writes the JSON to a local file (the staging
#' folder); `manifest_write()` uploads a manifest to
#' `manifest_path(dataset, version)` of a location; `manifest_read()`
#' downloads and parses one.
#'
#' @param manifest An `rcs_manifest` (`new_manifest()`).
#' @param path Local file to write; its folder is created.
#' @param be A backend object.
#' @param dataset,version One string each.
#' @return `manifest_write_local()`: `path`, invisibly. `manifest_write()`:
#'   the relative path written, invisibly. `manifest_read()`: the
#'   `rcs_manifest`; aborts with class `rcs_error_version_not_found` when the
#'   manifest does not exist, `rcs_error_schema` when it is invalid.
#' @noRd
manifest_write_local <- function(manifest, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  con <- file(path, open = "wb")
  on.exit(close(con))
  writeBin(charToRaw(enc2utf8(manifest_to_json(manifest))), con)
  invisible(path)
}

#' @rdname manifest_write_local
#' @noRd
manifest_write <- function(be, manifest) {
  path <- manifest_path(manifest$entry$dataset, manifest$entry$version)
  tmp <- withr::local_tempfile(fileext = ".json")
  manifest_write_local(manifest, tmp)
  be_put(be, tmp, path)
  invisible(path)
}

#' @rdname manifest_write_local
#' @noRd
manifest_read <- function(be, dataset, version) {
  path <- manifest_path(dataset, version)
  if (!isTRUE(be_exists(be, path))) {
    cli::cli_abort(
      "{.path {be$uri}} holds no manifest of version {.val {version}} of {.val {dataset}}.",
      class = "rcs_error_version_not_found"
    )
  }
  manifest_read_path(be, path)
}

manifest_read_path <- function(be, path) {
  tmp <- withr::local_tempfile(fileext = ".json")
  be_get(be, path, tmp)
  json <- readChar(tmp, file.size(tmp), useBytes = TRUE)
  Encoding(json) <- "UTF-8"
  manifest_from_json(json)
}

# File lookup -----------------------------------------------------------------

#' The files of one version of a dataset in a location
#'
#' The rows of `_files.parquet` (as held in `location$files`) with that
#' dataset and version; if there are none, the rows of `_history.parquet`
#' (read on demand); if there are none either, the location's catalogs are
#' re-read once and both are searched again. This keeps a read correct
#' while another process is between its catalog writes.
#'
#' @param location An `rcs_location`.
#' @param dataset Full dataset name.
#' @param version 16 hex characters.
#' @param st `NULL`, or the `rcs_store` holding `location`; when the
#'   catalogs are re-read, the connection is updated in place.
#' @param call Environment for the error.
#' @return A tibble of `files_schema()`, sorted by path, at least one row.
#'   Aborts with class `rcs_error_version_not_found` when the version is not
#'   found after the re-read.
#' @noRd
files_lookup <- function(location, dataset, version, st = NULL, call = caller_env()) {
  search <- function(location) {
    rows <- location$files[location$files$dataset == dataset & location$files$version == version, ]
    if (nrow(rows) > 0) {
      return(rows[order(rows$path, method = "radix"), ])
    }
    history_version_rows(history_read(location$backend), dataset, version)
  }
  rows <- search(location)
  if (nrow(rows) > 0) {
    return(rows)
  }
  fresh <- location_read(location$backend)
  if (!is.null(st)) {
    store_set_location(st, fresh)
  }
  rows <- search(fresh)
  if (nrow(rows) > 0) {
    return(rows)
  }
  uri <- location$uri
  cli::cli_abort(
    c(
      "{.path {uri}} lists no files of version {.val {version}} of {.val {dataset}}.",
      i = "Another process may have replaced it; run {.fn store_refresh} and read again."
    ),
    class = "rcs_error_version_not_found", call = call
  )
}

# Changes of the catalog tables -----------------------------------------------

#' Switch a dataset to a new version in the catalog tables
#'
#' Step 10 of `store_write()`, in memory: the new entry and file rows replace
#' the dataset's; the file list of the replaced version moves to the history
#' when `keep_history` is `TRUE` (nothing moves when the version did not
#' change). `catalog_drop_dataset()` removes a dataset the same way
#' (`store_delete()`, an index table that is no longer needed).
#'
#' @param catalog,files,history The tables of one location, in the in-memory
#'   form.
#' @param entry The new entry, a one-row tibble of `catalog_schema()`.
#' @param file_rows Its file rows, a tibble of `files_schema()` whose rows all
#'   carry the entry's dataset and version.
#' @param dataset Full name of the dataset to drop.
#' @param keep_history The effective history setting of the write
#'   (`effective_history()`).
#' @param replaced `POSIXct`: the `replaced` time of rows moved to history.
#' @return A list with the new `catalog` (sorted by dataset), `files` (sorted
#'   by dataset and path) and `history` (rows appended), and `delete`: the
#'   relative paths that no row of the new tables names any more, among the
#'   replaced files, plus the replaced version's manifest when that version is
#'   named by no row either. Delete them only after the catalogs are written,
#'   and only when `keep_history` is `FALSE` (with history on `delete` holds
#'   only files that the new version dropped and that no version names, which
#'   cannot happen; it is then empty).
#' @noRd
catalog_set_version <- function(catalog, files, history, entry, file_rows,
                                keep_history, replaced = now_utc()) {
  if (nrow(entry) != 1 || !all(file_rows$dataset == entry$dataset) ||
    !all(file_rows$version == entry$version) || nrow(file_rows) == 0) {
    cli::cli_abort("The file rows must carry the entry's dataset and version.", .internal = TRUE)
  }
  dataset <- entry$dataset
  old <- catalog_take(catalog, files, history, dataset, keep_history, entry$version, replaced)
  files <- vctrs::vec_rbind(old$files, file_rows)
  catalog <- vctrs::vec_rbind(old$catalog, strip_md5_attr(entry))
  catalog_finish(catalog, files, old$history, old$candidates, old$old_version, dataset)
}

#' @rdname catalog_set_version
#' @noRd
catalog_drop_dataset <- function(catalog, files, history, dataset, keep_history,
                                 replaced = now_utc()) {
  old <- catalog_take(catalog, files, history, dataset, keep_history, NA_character_, replaced)
  catalog_finish(old$catalog, old$files, old$history, old$candidates, old$old_version, dataset)
}

catalog_take <- function(catalog, files, history, dataset, keep_history, new_version, replaced) {
  check_flag(keep_history)
  catalog <- strip_md5_attr(catalog)
  files <- strip_md5_attr(files)
  history <- strip_md5_attr(history)
  old_version <- catalog$version[catalog$dataset == dataset]
  old_rows <- files[files$dataset == dataset, ]
  if (length(old_version) == 1 && !identical(old_version, new_version) && keep_history &&
    nrow(old_rows) > 0) {
    moved <- old_rows
    moved$replaced <- rep(as_utc(replaced), nrow(moved))
    history <- vctrs::vec_rbind(history, moved)
  }
  list(
    catalog = catalog[catalog$dataset != dataset, ],
    files = files[files$dataset != dataset, ],
    history = history,
    candidates = old_rows$path,
    old_version = if (length(old_version) == 1) old_version else NA_character_
  )
}

catalog_finish <- function(catalog, files, history, candidates, old_version, dataset) {
  catalog <- catalog[order(catalog$dataset, method = "radix"), ]
  files <- files[order(files$dataset, files$path, method = "radix"), ]
  named <- c(files$path, history$path)
  delete <- setdiff(candidates, named)
  if (!is.na(old_version)) {
    still_named <- any(catalog$dataset == dataset & catalog$version == old_version) ||
      any(history$dataset == dataset & history$version == old_version)
    if (!still_named) {
      delete <- c(delete, manifest_path(dataset, old_version))
    }
  }
  list(catalog = catalog, files = files, history = history, delete = delete)
}

#' Paths that no row of the catalog tables names
#'
#' @param paths Character vector of relative paths.
#' @param files,history The tables of one location.
#' @return The elements of `paths` named neither in `files$path` nor in
#'   `history$path`.
#' @noRd
files_unreferenced <- function(paths, files, history) {
  setdiff(paths, c(files$path, history$path))
}

# Rebuild ---------------------------------------------------------------------

#' Rebuild the catalogs of a location from its manifests and data files
#'
#' The logic of `store_rebuild()` (work package G), which writes the result
#' with `location_write()`. Lists the location with `be_list()`.
#'
#' * For each dataset with manifests: the manifest with the latest `written`
#'   whose files all exist is the current version; earlier manifests whose
#'   files all exist are history, each with `replaced` = the `written` of
#'   the next of them.
#' * A dataset without any manifest is rebuilt from the `rcs` metadata of its
#'   Parquet files (grouped by the `dataset` of that metadata) when all of
#'   them carry one file version (the version in the file name). Partition
#'   values are read from the partition columns inside the files; `rows`
#'   from the footers; `bytes` from the listing; `md5` from `be_md5()`;
#'   `bbox`, `h3_min` and `h3_max` from the `bbox` and `h3` columns of
#'   geospatial files; `created` and `updated` from the files' modification
#'   times; `history` is `NA`.
#' * Everything else is reported in `skipped`: a dataset whose manifests all
#'   name missing files, a dataset without manifest whose files carry several
#'   file versions, data files without `rcs` metadata, rasters without
#'   manifest. Data files of a dataset that has a usable manifest but that no
#'   manifest names are orphans for `store_prune()` and are not reported.
#'
#' @param be A backend object.
#' @return A list with `catalog`, `files`, `history` (the in-memory tables)
#'   and `skipped`, a tibble with `dataset` (character, `NA` when unknown),
#'   `reason` (character) and `paths` (list of character vectors).
#' @noRd
catalog_rebuild <- function(be) {
  listing <- be_list(be, "")
  listing <- listing[grepl("/", listing$path, fixed = TRUE), ]
  is_manifest <- grepl("(^|/)_manifest-[0-9a-f]{16}\\.json$", listing$path)
  manifests <- lapply(listing$path[is_manifest], function(p) manifest_read_path(be, p))

  catalog <- catalog_empty()
  files <- files_empty()
  history <- history_empty()
  skipped <- list()
  skip <- function(dataset, reason, paths) {
    skipped[[length(skipped) + 1L]] <<- tibble::tibble(
      dataset = dataset, reason = reason, paths = list(as.character(paths))
    )
  }

  by_dataset <- split(manifests, vapply(manifests, function(m) m$entry$dataset, character(1)))
  for (dataset in sort(names(by_dataset), method = "radix")) {
    group <- by_dataset[[dataset]]
    complete <- vapply(group, function(m) all(m$files$path %in% listing$path), logical(1))
    if (!any(complete)) {
      skip(dataset, "Every manifest names missing files.",
        manifest_path(dataset, vapply(group, function(m) m$entry$version, character(1))))
      next
    }
    group <- group[complete]
    written <- vapply(group, function(m) as.numeric(m$written), numeric(1))
    group <- group[order(written)]
    current <- group[[length(group)]]
    catalog <- vctrs::vec_rbind(catalog, current$entry)
    files <- vctrs::vec_rbind(files, current$files)
    for (i in seq_len(length(group) - 1L)) {
      rows <- group[[i]]$files
      rows$replaced <- rep(group[[i + 1L]]$written, nrow(rows))
      history <- vctrs::vec_rbind(history, rows)
    }
  }
  with_manifest <- unique(catalog$dataset)

  data_paths <- listing$path[!is_manifest & !startsWith(basename(listing$path), "_")]
  rasters <- data_paths[grepl("\\.tif$", data_paths)]
  named <- c(files$path, history$path)
  for (p in setdiff(rasters, named)) {
    skip(NA_character_, "A raster file without manifest.", p)
  }
  parquet <- setdiff(data_paths[grepl("\\.parquet$", data_paths)], named)
  if (length(parquet) > 0) {
    meta <- rebuild_file_metadata(be, parquet)
    no_meta <- is.na(meta$dataset)
    if (any(no_meta)) {
      skip(NA_character_, "Parquet files without {.field rcs} metadata.", parquet[no_meta])
    }
    meta <- meta[!no_meta & !meta$dataset %in% with_manifest, ]
    for (dataset in sort(unique(meta$dataset), method = "radix")) {
      group <- meta[meta$dataset == dataset, ]
      file_versions <- unique(sub("^part-(.*)\\.parquet$", "\\1", basename(group$path)))
      if (length(file_versions) != 1) {
        skip(dataset, "Its files carry several file versions and it has no manifest.", group$path)
        next
      }
      rebuilt <- rebuild_from_files(be, group, listing)
      catalog <- vctrs::vec_rbind(catalog, rebuilt$entry)
      files <- vctrs::vec_rbind(files, rebuilt$files)
    }
  }

  skipped <- vctrs::vec_rbind(
    tibble::tibble(dataset = character(), reason = character(), paths = list()),
    !!!skipped
  )
  catalog <- catalog[order(catalog$dataset, method = "radix"), ]
  files <- files[order(files$dataset, files$path, method = "radix"), ]
  schema_validate(catalog, "catalog")
  schema_validate(files, "files")
  schema_validate(history, "history")
  list(catalog = catalog, files = files, history = history, skipped = skipped)
}

# The `rcs` metadata of Parquet files: one row per path with `path`,
# `dataset` (NA without metadata), `json` and `rows`.
rebuild_file_metadata <- function(be, paths) {
  fs <- be_arrow_fs(be)
  rows <- lapply(paths, function(p) {
    footer <- with_parquet_reader(fs, p, be, function(reader) {
      list(json = reader$GetSchema()$metadata$rcs, rows = reader$num_rows)
    })
    json <- footer$json
    dataset <- NA_character_
    if (!is.null(json)) {
      dataset <- tryCatch(
        as.character(jsonlite::fromJSON(json, simplifyVector = FALSE)$dataset %||% NA),
        error = function(e) NA_character_
      )
    }
    tibble::tibble(path = p, dataset = dataset, json = json %||% NA_character_, rows = as.double(footer$rows))
  })
  vctrs::vec_rbind(!!!rows)
}

rebuild_from_files <- function(be, group, listing) {
  group <- group[order(group$path, method = "radix"), ]
  entry0 <- entry_from_metadata_json(group$json[[1]])
  partition <- entry0$partition[[1]]
  geospatial <- identical(entry0$kind, "geospatial")
  fs <- be_arrow_fs(be)
  withr::local_options(arrow.int64_downcast = FALSE)
  info <- lapply(group$path, function(p) {
    data <- with_parquet_reader(fs, p, be, function(reader) {
      schema <- reader$GetSchema()
      wanted <- intersect(c(partition, if (geospatial) c("bbox", "h3")), names(schema))
      if (length(wanted) > 0) {
        as.data.frame(reader$ReadTable(parquet_leaf_indices(schema, wanted)))
      }
    })
    wanted <- names(data)
    values <- if (length(partition) > 0) {
      lapply(stats::setNames(partition, partition), function(col) data[[col]][1])
    }
    list(
      partition_values = partition_values_json(values),
      bbox = if (geospatial && "bbox" %in% wanted) bbox_extent(data$bbox) else NULL,
      h3 = if (geospatial && "h3" %in% wanted) cell_range(data$h3) else NULL
    )
  })
  idx <- match(group$path, listing$path)
  md5 <- be_md5(be, group$path)
  pv <- vapply(info, function(i) i$partition_values, character(1))
  version <- version_hash(pv, md5)
  modified <- as_utc(round(as.numeric(listing$modified[idx]) * 1e6) / 1e6)
  bbox <- if (geospatial) {
    boxes <- lapply(info, function(i) i$bbox %||% bbox_na(1L))
    vctrs::vec_rbind(!!!boxes)
  }
  h3_min <- h3_max <- NULL
  if (geospatial && !is.null(info[[1]]$h3)) {
    h3_min <- do.call(c, lapply(info, function(i) i$h3[[1]]))
    h3_max <- do.call(c, lapply(info, function(i) i$h3[[2]]))
  }
  files <- new_file_rows(
    dataset = entry0$dataset, version = version, path = group$path,
    partition_values = pv, rows = group$rows, bytes = listing$bytes[idx], md5 = md5,
    bbox = bbox, h3_min = h3_min, h3_max = h3_max, created = 0
  )
  files$created <- modified
  entry <- new_entry(
    dataset = entry0$dataset, kind = entry0$kind, title = entry0$title,
    description = entry0$description, version = version,
    n_files = nrow(files), rows = sum(group$rows), bytes = sum(listing$bytes[idx]),
    columns = entry0$columns, key = entry0$key[[1]], sorted_by = entry0$sorted_by[[1]],
    partition = partition, partition_auto = entry0$partition_auto,
    source = entry0$source, inputs = entry0$inputs, crs = entry0$crs, bbox = if (geospatial) bbox_extent(files$bbox) else NULL,
    h3_res = entry0$h3_res, geocode_engine = entry0$geocode_engine,
    index_of = entry0$index_of, history = NA,
    created = min(modified), updated = max(modified)
  )
  list(entry = entry, files = files)
}
