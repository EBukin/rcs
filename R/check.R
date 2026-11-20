# Checks of stored datasets: `store_check()` with its two modes.
#
#   * Serialization check (`x` given): sampled rows of each file are compared
#     with the matching rows of `x`. Also run by `store_write(check = TRUE)`
#     on the staged files, through `check_serialization()`.
#   * Integrity check (no `x`): the catalogs of each location against what
#     is stored: MD5 from the backend (no download where the backend reports
#     MD5), rows and schema from the Parquet footers, the version hash and
#     totals, and the manifest.
#
# Results are a tibble with one row per location and file: `location`,
# `dataset`, `path`, `status` (`"ok"`, `"failed"`, or `"missing"` for a
# location that does not hold the dataset) and `problem` (`NA` when ok).

#' Check a stored dataset
#'
#' Two checks, chosen by `x`:
#'
#' * With `x`, a serialization check: for each file of the dataset, `n` rows
#'   of one random row group are read and compared, column by column, with
#'   the matching rows of `x`: matched by the key, else by `.rcs_id`, else
#'   (tables without key) by row order. Values are compared exactly, after
#'   normalisation (a tibble and a data frame are alike, geometries are
#'   compared as WKB, times as instants). Geospatial data without key and
#'   without a column `.rcs_id` are geocoded again to find the row
#'   identifiers, which matches only a dataset written in one call (not
#'   after an `update`). For a raster, `n` random cells are compared.
#'   [store_write()] runs this check on the staged files before it uploads
#'   them.
#' * Without `x`, an integrity check of each location: every file of the
#'   current version exists with the MD5 its catalog records (read from the
#'   backend's metadata, so no data file is downloaded where the backend
#'   reports MD5), its Parquet footer has the recorded rows and the columns
#'   of the entry, the version is the hash of the file rows, the totals
#'   match, and the manifest agrees with the catalog. The dataset's index
#'   table is checked with it.
#'
#' The catalogs of the checked locations are read again first, and the
#' connection is updated with them.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset The dataset's full name, or its last part when that is
#'   unique.
#' @param x `NULL` for the integrity check, or the data the dataset was
#'   written from (data frame, `sf` object or `SpatRaster`) for the
#'   serialization check.
#' @param n Rows (or raster cells) compared per file.
#' @param columns `NULL` for all columns that `x` and the files share, or
#'   the names of the columns to compare.
#' @param locations `"all"` for every available location, or addresses of
#'   locations of the connection.
#' @param error `TRUE` aborts when a check fails; `FALSE` only reports.
#' @return A tibble, invisibly, with one row per location and file:
#'   `location`, `dataset`, `path`, `status` (`"ok"`, `"failed"`, or
#'   `"missing"` when the location does not hold the dataset) and `problem`
#'   (a description, `NA` when ok).
#' @seealso [store_write()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-check")
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' sales <- rcs_sim_table(100, seed = 1)
#' store_write(st, sales, "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_check(st, "sales/daily")
#' store_check(st, "sales/daily", x = sales)
#' unlink(root, recursive = TRUE)
store_check <- function(st, dataset, x = NULL, n = 20, columns = NULL,
                        locations = "all", error = TRUE) {
  validate_store(st)
  local_trace("store_check")
  call <- rlang::current_env()
  name <- resolve_dataset(st, dataset, index = TRUE, call = call)
  n <- check_count(n, call = call)
  check_flag(error, call = call)
  if (!is.null(columns) && (!is.character(columns) || anyNA(columns))) {
    cli::cli_abort("{.arg columns} must be column names or {.code NULL}.", class = "rcs_error_argument", call = call)
  }
  targets <- check_locations(st, locations, call)

  results <- list()
  for (location in targets) {
    uri <- location$uri
    fresh <- tryCatch(location_read(location$backend), error = function(e) e)
    if (inherits(fresh, "error")) {
      if (!inherits(fresh, write_error_classes)) {
        rlang::cnd_signal(fresh)
      }
      results[[length(results) + 1L]] <- check_row(
        uri, name, catalog_files[["catalog"]], "failed",
        paste("the catalogs cannot be read:", first_line(conditionMessage(fresh)))
      )
      next
    }
    store_set_location(st, fresh)
    entry <- catalog_entry(fresh$catalog, name)
    if (nrow(entry) == 0) {
      results[[length(results) + 1L]] <- check_row(uri, name, NA_character_, "missing", "the location does not hold the dataset")
      next
    }
    files <- fresh$files[fresh$files$dataset == name, ]
    if (is.null(x)) {
      results[[length(results) + 1L]] <- check_integrity(fresh, entry, files)
      index <- catalog_entry(fresh$catalog, index_name(name))
      if (nrow(index) == 1) {
        results[[length(results) + 1L]] <- check_integrity(
          fresh, index, fresh$files[fresh$files$dataset == index$dataset, ]
        )
      }
    } else {
      out <- check_serialization(location$backend, entry, files, x, n = n, columns = columns)
      out$location <- rep(uri, nrow(out))
      results[[length(results) + 1L]] <- out
    }
  }
  results <- vctrs::vec_rbind(check_empty(), !!!results)
  check_report(results, error, call)
  invisible(results)
}

check_empty <- function() {
  tibble::tibble(
    location = character(), dataset = character(), path = character(),
    status = character(), problem = character()
  )
}

check_row <- function(location, dataset, path, status, problem = NA_character_) {
  n <- length(path)
  tibble::tibble(
    location = rep(location, n), dataset = rep(dataset, n), path = path,
    status = rep_len(status, n), problem = rep_len(problem, n)
  )
}

# The locations to check: "all" (every available one) or addresses.
check_locations <- function(st, locations, call) {
  available <- store_locations(st, available_only = TRUE)
  if (identical(locations, "all")) {
    return(available)
  }
  if (!is.character(locations) || anyNA(locations) || length(locations) == 0) {
    cli::cli_abort("{.arg locations} must be {.val all} or addresses of locations.", class = "rcs_error_argument", call = call)
  }
  uris <- vapply(locations, function(l) be_new(l)$uri, character(1), USE.NAMES = FALSE)
  known <- vapply(available, function(l) l$uri, character(1))
  unknown <- setdiff(uris, known)
  if (length(unknown) > 0) {
    cli::cli_abort(
      "{.path {unknown}} {?is/are} not {?an available location/available locations} of this connection.",
      class = "rcs_error_argument", call = call
    )
  }
  available[match(uris, known)]
}

check_report <- function(results, error, call) {
  failed <- results[results$status == "failed", ]
  if (nrow(failed) > 0) {
    lines <- escape_braces(paste0(
      ifelse(is.na(failed$path), "", paste0(failed$path, ": ")), failed$problem,
      " [", failed$location, "]"
    ))
    n <- nrow(failed)
    message <- c(
      "{.fn store_check} found {n} problem{?s}.",
      rlang::set_names(lines, rep("x", n))
    )
    if (error) {
      cli::cli_abort(message, class = "rcs_error_check", call = call)
    }
    rcs_inform(message)
    return(invisible())
  }
  checked <- results[results$status == "ok", ]
  n_files <- length(unique(checked$path))
  k <- length(unique(checked$location))
  rcs_inform(c(v = "{n_files} file{?s} checked in {k} location{?s}: no problem found."))
  invisible()
}

# Integrity -------------------------------------------------------------------

#' Integrity of one dataset version in one location
#'
#' @param location An `rcs_location` with fresh catalogs.
#' @param entry The dataset's entry.
#' @param files Its file rows.
#' @return Check results (see the header of this file): one row per file,
#'   plus rows for `_files.parquet` (version and totals) and the manifest
#'   when they fail.
#' @noRd
check_integrity <- function(location, entry, files) {
  be <- location$backend
  uri <- location$uri
  dataset <- entry$dataset
  problems <- stats::setNames(rep(list(character()), nrow(files)), files$path)
  add <- function(path, text) problems[[path]] <<- c(problems[[path]], text)
  extra <- list()
  fail <- function(path, text) {
    extra[[length(extra) + 1L]] <<- check_row(uri, dataset, path, "failed", text)
  }

  if (nrow(files) == 0) {
    fail(catalog_files[["files"]], paste0("lists no file of ", dataset))
  } else {
    if (!identical(version_hash(files$partition_values, files$md5), entry$version) ||
      !all(files$version == entry$version)) {
      fail(catalog_files[["files"]], paste0("the version of ", dataset, " is not the hash of its file rows"))
    }
    if (as.numeric(entry$n_files) != nrow(files) || as.numeric(entry$rows) != sum(as.numeric(files$rows)) ||
      as.numeric(entry$bytes) != sum(as.numeric(files$bytes))) {
      fail(catalog_files[["catalog"]], paste0("the totals of ", dataset, " differ from its file rows"))
    }
  }

  md5 <- if (nrow(files) > 0) be_md5(be, files$path) else character()
  for (i in seq_len(nrow(files))) {
    path <- files$path[[i]]
    if (is.na(md5[[i]])) {
      add(path, "the file is missing")
    } else if (md5[[i]] != files$md5[[i]]) {
      add(path, paste0("its MD5 ", md5[[i]], " differs from the catalog's ", files$md5[[i]]))
    }
  }

  parquet <- which(!is.na(md5) & grepl("\\.parquet$", files$path))
  if (length(parquet) > 0) {
    spec <- columns_from_json(entry$columns)
    fs <- be_arrow_fs(be)
    for (i in parquet) {
      path <- files$path[[i]]
      footer <- tryCatch(
        with_parquet_reader(fs, path, be, function(reader) {
          schema <- reader$GetSchema()
          list(
            rows = as.numeric(reader$num_rows),
            names = names(schema),
            types = vapply(schema$fields, function(f) f$type$ToString(), character(1))
          )
        }),
        error = function(e) NULL
      )
      if (is.null(footer)) {
        add(path, "it is not a readable Parquet file")
        next
      }
      if (footer$rows != as.numeric(files$rows[[i]])) {
        add(path, paste0("its footer has ", footer$rows, " rows, the catalog ", as.numeric(files$rows[[i]])))
      }
      # Parquet names the field of a list `element`, Arrow in memory `item`.
      plain <- function(type) gsub("list<[^:<>]+: ", "list<", type)
      if (!identical(footer$names, spec$name) || !identical(plain(unname(footer$types)), plain(spec$type))) {
        add(path, "its columns differ from those of the entry")
      }
    }
  }

  mpath <- manifest_path(dataset, entry$version)
  manifest <- tryCatch(manifest_read(be, dataset, entry$version), error = function(e) e)
  if (inherits(manifest, "error")) {
    fail(mpath, paste("the manifest cannot be read:", first_line(conditionMessage(manifest))))
  } else {
    file_kinds <- schema_kinds("files")
    rows_key <- function(r) {
      r <- r[order(r$path, method = "radix"), names(file_kinds)]
      vapply(seq_len(nrow(r)), function(i) to_json(row_to_list(r[i, ], file_kinds)), character(1))
    }
    if (!identical(entry_key(manifest$entry), entry_key(entry)) ||
      !identical(rows_key(manifest$files), rows_key(files))) {
      fail(mpath, "the manifest differs from the catalog")
    }
  }

  rows <- lapply(names(problems), function(path) {
    p <- problems[[path]]
    if (length(p) == 0) {
      check_row(uri, dataset, path, "ok")
    } else {
      check_row(uri, dataset, path, "failed", paste(p, collapse = "; "))
    }
  })
  vctrs::vec_rbind(check_empty(), !!!rows, !!!extra)
}

# Serialization ---------------------------------------------------------------

#' Compare sampled rows of stored files with the data they were written from
#'
#' Used by `store_check()` and, on the staged files, by `store_write()`.
#'
#' @param be The backend holding the files (for staged files a local backend
#'   on the staging folder).
#' @param entry The dataset's entry.
#' @param files The file rows to check.
#' @param x The reference: a data frame, an `sf` object, or for a raster a
#'   `SpatRaster`.
#' @param n Rows (cells) per file.
#' @param columns Columns to compare, or `NULL` for all shared ones.
#' @return Check results (see the header of this file), `location` = the
#'   backend's `uri`. Sampling does not change the session's random stream.
#' @noRd
check_serialization <- function(be, entry, files, x, n = 20L, columns = NULL) {
  dataset <- entry$dataset
  uri <- be$uri
  if (entry$kind == "raster") {
    return(check_raster_values(be, entry, files, x, n))
  }
  withr::local_options(arrow.int64_downcast = FALSE)
  ref <- serialization_reference(x, entry)
  key <- entry$key[[1]]
  match_by <- if (length(key) > 0 && all(key %in% names(ref))) {
    "key"
  } else if (".rcs_id" %in% names(ref)) {
    "id"
  } else {
    "order"
  }
  ref_keys <- switch(match_by,
    key = key_frame(ref, key),
    id = key_frame(ref, ".rcs_id"),
    order = NULL
  )
  by_partition <- NULL
  partition <- entry$partition[[1]]
  if (match_by == "order" && length(partition) > 0 && all(partition %in% names(ref))) {
    groups <- vctrs::vec_group_loc(tibble::as_tibble(as.list(ref)[partition]))
    pv <- vapply(seq_len(nrow(groups)), function(i) {
      partition_values_json(as.list(ref[groups$loc[[i]][[1]], partition]))
    }, character(1))
    by_partition <- stats::setNames(groups$loc, pv)
  }

  rows <- lapply(seq_len(nrow(files)), function(i) {
    path <- files$path[[i]]
    problem <- tryCatch(
      check_file_rows(be, path, files$partition_values[[i]], ref, ref_keys, match_by, key, by_partition, n, columns),
      rcs_error_backend = function(e) paste("it cannot be read:", first_line(conditionMessage(e)))
    )
    if (is.na(problem)) {
      check_row(uri, dataset, path, "ok")
    } else {
      check_row(uri, dataset, path, "failed", problem)
    }
  })
  vctrs::vec_rbind(check_empty(), !!!rows)
}

# The reference rows of a serialization check: a tibble with geometry as WKB.
serialization_reference <- function(x, entry) {
  if (!inherits(x, "sf")) {
    if (!is.data.frame(x)) {
      cli::cli_abort(
        "{.arg x} must be a data frame or an {.cls sf} object for a {entry$kind} dataset.",
        class = "rcs_error_argument", call = NULL
      )
    }
    return(tibble::as_tibble(x))
  }
  key <- entry$key[[1]]
  if (length(key) == 0 && !".rcs_id" %in% names(x)) {
    geocode <- !is.na(entry$h3_res)
    enc <- geo_encode(x, h3_res = if (geocode) entry$h3_res else 5L, geocode = geocode)
    return(enc$data)
  }
  wkb <- unclass(sf::st_as_binary(sf::st_geometry(x), EWKB = FALSE))
  attributes(wkb) <- NULL
  out <- tibble::as_tibble(sf::st_drop_geometry(x))
  out$geometry <- wkb
  out
}

# Problems of one file, or NA.
check_file_rows <- function(be, path, pv, ref, ref_keys, match_by, key, by_partition, n, columns) {
  groups <- files_row_groups(be, path)
  if (nrow(groups) == 0 || sum(groups$rows) == 0) {
    return(NA_character_)
  }
  pick <- withr::with_preserve_seed({
    g <- sample.int(nrow(groups), 1L)
    take <- sort(sample.int(groups$rows[[g]], min(n, groups$rows[[g]])))
    list(g = g, take = take)
  })
  offset <- sum(groups$rows[seq_len(pick$g - 1L)])
  data <- tibble::as_tibble(as.data.frame(files_read_row_groups(be, path, groups$row_group[[pick$g]])))
  data <- data[pick$take, ]
  idx <- switch(match_by,
    key = vctrs::vec_match(key_frame(data, key), ref_keys),
    id = vctrs::vec_match(key_frame(data, ".rcs_id"), ref_keys),
    order = {
      rows <- if (is.null(by_partition)) seq_len(nrow(ref)) else by_partition[[pv]]
      rows[offset + pick$take]
    }
  )
  if (anyNA(idx)) {
    return(paste0(sum(is.na(idx)), " sampled row", if (sum(is.na(idx)) > 1) "s are" else " is", " not in x"))
  }
  shared <- intersect(names(data), names(ref))
  if (!is.null(columns)) {
    shared <- intersect(shared, columns)
  }
  differ <- shared[!vapply(shared, function(col) {
    identical(normalise_values(data[[col]]), normalise_values(vctrs::vec_slice(ref[[col]], idx)))
  }, logical(1))]
  if (length(differ) > 0) {
    return(paste0(
      "column", if (length(differ) > 1) "s", " ", paste(differ, collapse = ", "),
      " differ", if (length(differ) == 1) "s", " from x"
    ))
  }
  NA_character_
}

# Values of a column in a form that compares equal across a round trip.
normalise_values <- function(v) {
  if (is.data.frame(v)) {
    return(lapply(as.list(v), normalise_values))
  }
  if (inherits(v, "integer64")) {
    return(as.character(v))
  }
  if (inherits(v, "difftime")) {
    return(as.numeric(v, units = "secs"))
  }
  if (inherits(v, c("POSIXct", "Date"))) {
    return(as.numeric(v))
  }
  if (is.factor(v)) {
    return(list(as.character(v), levels(v), is.ordered(v)))
  }
  if (is.list(v)) {
    v <- as.list(v)
    attributes(v) <- NULL
    return(lapply(v, function(e) {
      if (is.null(e)) {
        return(NULL)
      }
      attributes(e) <- NULL
      if (is.character(e)) enc2utf8(e) else e
    }))
  }
  attributes(v) <- NULL
  if (is.character(v)) enc2utf8(v) else v
}

check_raster_values <- function(be, entry, files, x, n) {
  check_terra()
  uri <- be$uri
  if (!inherits(x, "SpatRaster")) {
    cli::cli_abort("{.arg x} must be a {.cls SpatRaster} for a raster dataset.", class = "rcs_error_argument", call = NULL)
  }
  rows <- lapply(files$path, function(path) {
    r <- tryCatch(terra::rast(be_gdal_path(be, path)), error = function(e) NULL)
    if (is.null(r)) {
      return(check_row(uri, entry$dataset, path, "failed", "GDAL cannot open it"))
    }
    on.exit(rm(r), add = TRUE)
    problem <- NA_character_
    if (!identical(names(r), names(x)) || terra::ncell(r) != terra::ncell(x)) {
      problem <- "its layers or cells differ from x"
    } else {
      cells <- withr::with_preserve_seed(sample.int(terra::ncell(x), min(n, terra::ncell(x))))
      a <- terra::extract(r, cells)
      b <- terra::extract(x, cells)
      same <- vapply(seq_along(a), function(j) {
        va <- as.numeric(a[[j]])
        vb <- as.numeric(b[[j]])
        identical(is.na(va), is.na(vb)) && all(va[!is.na(va)] == vb[!is.na(vb)])
      }, logical(1))
      if (!all(same)) {
        problem <- paste0("layer", if (sum(!same) > 1) "s", " ", paste(names(r)[!same], collapse = ", "), " differ from x")
      }
    }
    check_row(uri, entry$dataset, path, if (is.na(problem)) "ok" else "failed", problem)
  })
  vctrs::vec_rbind(check_empty(), !!!rows)
}
