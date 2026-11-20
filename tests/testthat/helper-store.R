# A fixture store in three local folders, built from simulated data without
# `store_write()`: the files are staged with `files_stage()`, uploaded with
# `be_put()` and switched in with `catalog_set_version()` and
# `location_write()`, the same internal path a write takes.
#
# Interface (used by work packages C, D, E, F and G):
#
#   fx <- local_test_store(
#     tables = TRUE,          # sales/daily (partitioned by year, key) and
#                             # sales/summary (one file, no key)
#     geospatial = character(),
#                             # any of "polygons" (shapes/polygons, partition
#                             # "h3", with index table shapes/polygons__h3),
#                             # "flat" (polygons: one file, geocode = FALSE),
#                             # "points" (shapes/points, one file),
#                             # "lines" (shapes/lines, one file, index table);
#                             # TRUE means all four
#     secondaries = 2L,       # 0, 1 or 2 secondary folders
#     partial = FALSE,        # TRUE: the second secondary lacks
#                             # sales/summary (and the geospatial datasets)
#                             # and holds an older version of sales/daily
#     history = FALSE,        # TRUE: the store keeps history (_store.json),
#                             # and sales/daily was written twice, so
#                             # _history.parquet holds its first version
#     frame = parent.frame()
#   )
#
#   fx$st          an rcs_store (primary + secondaries), built by
#                  `fixture_connect()` (not `store_connect()`)
#   fx$primary     path of the primary folder
#   fx$secondary   paths of the secondary folders
#   fx$datasets    names of the datasets in the primary
#   fx$data        named list: the data each current dataset was staged from
#                  (a data frame; for geospatial datasets the `sf` object)
#   fx$old         the data of the older version of sales/daily (history /
#                  partial secondary), or NULL
#
#   fixture_connect(primary, secondary = character(), history = NULL)
#                  an rcs_store from existing folders, read with
#                  `location_read()`; the store's history default from
#                  `_store.json`
#   fixture_write(st, data, dataset, ..., locations = NULL, keep_history = NULL)
#                  stage `data` with `files_stage()` (arguments in `...`) and
#                  land it in `locations` (default: all available locations
#                  of `st`); returns the staged result invisibly. For `sf`
#                  data it calls `geo_encode()` and writes the index table.
#
# Everything lives below `withr::local_tempdir()` of `frame`. A template of
# each configuration is built once per test run and copied for every call,
# so a call costs a folder copy. Geospatial datasets need the real hooks of
# work package B (`geo_encode()`, `geo_metadata()`, `h3_parent()`); while
# they are stubs the calling test is skipped.
#
# Before the merge with work package A there are no backend methods for
# local folders; `local_backend_fallback()` then provides test-only methods
# for the calling test. It does nothing once `be_put.rcs_backend_local`
# exists, so the real methods are never shadowed.

# Test-only local backend (only while work package A's methods are missing) ---

fallback_local_methods <- list(
  be_arrow_fs = function(be) {
    list(fs = arrow::LocalFileSystem$create(), path = be$root)
  },
  be_gdal_path = function(be, path) {
    file.path(be$root, path)
  },
  be_get = function(be, path, dest) {
    src <- file.path(be$root, path)
    if (!file.exists(src) || dir.exists(src)) {
      cli::cli_abort("No file {.path {path}} in {.path {be$uri}}.", class = "rcs_error_backend")
    }
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    file.copy(src, dest, overwrite = TRUE)
    invisible(dest)
  },
  be_put = function(be, src, path) {
    target <- file.path(be$root, path)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(target, ".tmp-", basename(tempfile("")))
    if (!file.copy(src, tmp, overwrite = TRUE) || !file.rename(tmp, target)) {
      unlink(tmp)
      cli::cli_abort("Cannot write {.path {path}} in {.path {be$uri}}.", class = "rcs_error_backend")
    }
    invisible(path)
  },
  be_delete = function(be, paths) {
    full <- file.path(be$root, paths)
    unlink(full[file.exists(full)])
    for (d in unique(dirname(full))) {
      while (normalizePath(d, "/", FALSE) != normalizePath(be$root, "/", FALSE) &&
        dir.exists(d) && length(list.files(d, all.files = TRUE, no.. = TRUE)) == 0) {
        unlink(d, recursive = TRUE)
        d <- dirname(d)
      }
    }
    invisible(paths)
  },
  be_md5 = function(be, paths) {
    full <- file.path(be$root, paths)
    out <- rep(NA_character_, length(paths))
    ok <- file.exists(full) & !dir.exists(full)
    out[ok] <- md5_file(full[ok])
    out
  },
  be_list = function(be, prefix = "") {
    base <- if (nzchar(prefix)) file.path(be$root, prefix) else be$root
    paths <- if (dir.exists(base)) list.files(base, recursive = TRUE, all.files = TRUE) else character()
    if (nzchar(prefix)) paths <- file.path(prefix, paths)
    paths <- sort(paths, method = "radix")
    full <- file.path(be$root, paths)
    tibble::tibble(
      path = paths,
      bytes = as.double(file.size(full)),
      modified = as.POSIXct(as.numeric(file.mtime(full)), origin = "1970-01-01", tz = "UTC")
    )
  },
  be_exists = function(be, paths) {
    full <- file.path(be$root, paths)
    file.exists(full) & !dir.exists(full)
  },
  be_auth_hint = function(be) {
    c(i = "A local folder needs read and write permission.")
  }
)

local_backend_fallback <- function(frame = parent.frame()) {
  real <- utils::getS3method("be_put", "rcs_backend_local", optional = TRUE, envir = asNamespace("rcs"))
  if (!is.null(real)) {
    return(invisible(FALSE))
  }
  for (generic in names(fallback_local_methods)) {
    testthat::local_mocked_s3_method(
      generic, "rcs_backend_local", fallback_local_methods[[generic]],
      frame = frame
    )
  }
  invisible(TRUE)
}

# End of the test-only local backend ------------------------------------------

fixture_connect <- function(primary, secondary = character(), history = NULL) {
  read <- function(path) location_read(be_new(path))
  primary_be <- be_new(primary)
  new_store(
    primary = read(primary),
    secondary = lapply(secondary, read),
    history = history,
    store_history = store_json_read(primary_be)
  )
}

# Land a staged version (from `files_stage()`) in one location of `st`.
fixture_land <- function(st, location, staged, keep_history) {
  be <- location$backend
  present <- c(location$files$path, history_read(be)$path)
  todo <- staged$staged[!staged$staged$path %in% present, ]
  for (i in seq_len(nrow(todo))) {
    be_put(be, todo$local[[i]], todo$path[[i]])
  }
  manifest_write(be, staged$manifest)
  location <- location_refresh(st, location)
  history <- history_read(be)
  keep <- keep_history %||% effective_history(st, staged$entry$history)
  new <- catalog_set_version(
    location$catalog, location$files, history,
    staged$entry, staged$files, keep_history = keep
  )
  location <- location_write(location, new$catalog, new$files, new$history)
  store_set_location(st, location)
  if (!keep && length(new$delete) > 0) {
    be_delete(be, new$delete)
  }
  invisible(location)
}

fixture_write <- function(st, data, dataset, ..., locations = NULL, keep_history = NULL,
                          h3_res = 5L, geocode = TRUE) {
  locations <- locations %||% store_locations(st, available_only = TRUE)
  dir <- withr::local_tempdir()
  args <- list(...)
  index <- NULL
  if (inherits(data, "sf")) {
    enc <- geo_encode(data, h3_res = h3_res, geocode = geocode, key = args$key)
    staged <- do.call(files_stage, c(
      list(enc$data, dataset, kind = "geospatial", crs = enc$crs,
        h3_res = if (geocode) h3_res else NA_integer_, dir = dir),
      args
    ))
    if (geocode && nrow(enc$index) > 0) {
      index <- files_stage(
        enc$index, index_name(dataset),
        title = paste("Index of", dataset), description = paste("H3 index table of", dataset),
        kind = "table", index_of = dataset, sorted_by = c("h3", ".rcs_id"),
        dir = file.path(dir, "index")
      )
    }
  } else {
    staged <- do.call(files_stage, c(list(data, dataset, kind = "table", dir = dir), args))
  }
  for (location in locations) {
    fixture_land(st, location, staged, keep_history)
    if (!is.null(index)) {
      location <- store_locations(st)[[match(location$uri, store_uris(st))]]
      fixture_land(st, location, index, keep_history)
    }
  }
  invisible(staged)
}

fixture_cache <- new.env(parent = emptyenv())

# Builds the primary (and, when `partial`, the partial second secondary) by
# writes; full secondaries are copies of the primary folder.
fixture_build <- function(root, tables, geospatial, partial, history) {
  paths <- file.path(root, c("primary", if (partial) "secondary2"))
  for (p in paths) location_init(be_new(p), history = history)
  st <- fixture_connect(paths[[1]], paths[-1])
  data <- list()
  old <- NULL
  locs <- function() store_locations(st)
  full <- function() locs()[1]

  if (tables) {
    daily_args <- list(
      title = "Daily sales", description = "Simulated daily sales by shop and product.",
      key = c("shop_id", "date", "product"), partition = "year"
    )
    if (history || partial) {
      old <- rcs_sim_table(120, seed = 3)
      targets <- if (history) locs() else locs()[-1]
      do.call(fixture_write, c(list(st, old, "sales/daily", locations = targets), daily_args))
    }
    data[["sales/daily"]] <- rcs_sim_table(240, seed = 1)
    do.call(fixture_write, c(list(st, data[["sales/daily"]], "sales/daily", locations = full()), daily_args))
    data[["sales/summary"]] <- rcs_sim_table(40, seed = 2)
    fixture_write(st, data[["sales/summary"]], "sales/summary",
      title = "Sales summary", description = "A small simulated table in one file.",
      locations = full()
    )
  }

  if (length(geospatial) > 0) {
    polygons <- rcs_sim_polygons(60, seed = 1)
    if ("polygons" %in% geospatial) {
      data[["shapes/polygons"]] <- polygons
      fixture_write(st, polygons, "shapes/polygons",
        title = "Polygons", description = "Simulated polygons in open ocean.",
        partition = "h3", locations = full()
      )
    }
    if ("flat" %in% geospatial) {
      data[["polygons"]] <- polygons
      fixture_write(st, polygons, "polygons",
        title = "Polygons without geocodes", description = "Simulated polygons, geocode = FALSE.",
        geocode = FALSE, locations = full()
      )
    }
    if ("points" %in% geospatial) {
      data[["shapes/points"]] <- rcs_sim_points(80, seed = 1)
      fixture_write(st, data[["shapes/points"]], "shapes/points",
        title = "Points", description = "Simulated points in open ocean.", locations = full()
      )
    }
    if ("lines" %in% geospatial) {
      data[["shapes/lines"]] <- rcs_sim_lines(40, seed = 1)
      fixture_write(st, data[["shapes/lines"]], "shapes/lines",
        title = "Lines", description = "Simulated lines in open ocean.", locations = full()
      )
    }
  }
  copies <- c("secondary1", if (!partial) "secondary2")
  for (copy in copies) {
    dir.create(file.path(root, copy))
    file.copy(list.files(paths[[1]], full.names = TRUE, all.files = TRUE, no.. = TRUE),
      file.path(root, copy), recursive = TRUE)
  }
  list(data = data, old = old)
}

local_test_store <- function(tables = TRUE, geospatial = character(), secondaries = 2L,
                             partial = FALSE, history = FALSE, frame = parent.frame()) {
  local_backend_fallback(frame)
  if (isTRUE(geospatial)) geospatial <- c("polygons", "flat", "points", "lines")
  if (isFALSE(geospatial)) geospatial <- character()
  stopifnot(all(geospatial %in% c("polygons", "flat", "points", "lines")))
  if (length(geospatial) > 0) {
    testthat::skip_if_not_installed("h3o")
    for (hook in c("geo_encode", "geo_metadata", "h3_parent")) {
      body <- deparse(body(get(hook, envir = asNamespace("rcs"))))
      if (any(grepl("abort_not_implemented", body, fixed = TRUE))) {
        testthat::skip(paste0("Geospatial hook ", hook, "() of work package B is a stub."))
      }
    }
  }
  stopifnot(secondaries %in% 0:2, !(partial && secondaries < 2))
  key <- paste(tables, paste(sort(geospatial), collapse = "+"), partial, history, sep = "|")
  template <- fixture_cache[[key]]
  if (is.null(template)) {
    root <- tempfile("rcs-fixture-")
    dir.create(root)
    built <- tryCatch(
      fixture_build(root, tables, geospatial, partial, history),
      rcs_error_not_implemented = function(e) {
        unlink(root, recursive = TRUE)
        testthat::skip(paste("Geospatial hooks are not implemented yet:", conditionMessage(e)))
      }
    )
    template <- c(list(root = root), built)
    fixture_cache[[key]] <- template
  }
  dir <- withr::local_tempdir(.local_envir = frame)
  names <- c("primary", sprintf("secondary%d", seq_len(secondaries)))
  for (n in names) {
    file.copy(file.path(template$root, n), dir, recursive = TRUE)
  }
  paths <- normalizePath(file.path(dir, names), winslash = "/")
  st <- fixture_connect(paths[[1]], paths[-1])
  list(
    st = st,
    primary = paths[[1]],
    secondary = paths[-1],
    datasets = st$primary$catalog$dataset,
    data = template$data,
    old = template$old
  )
}
