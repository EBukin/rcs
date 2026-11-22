# Catalog I/O, file lookup, version switches and rebuild.

new_test_location <- function(frame = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = frame)
  location_init(be_new(file.path(dir, "loc")))
}

test_that("location_init() writes empty catalogs that location_read() reads back", {
  local_backend_fallback()
  loc <- new_test_location()
  be <- loc$backend
  expect_true(location_exists(be))
  expect_setequal(be_list(be)$path, c(unname(catalog_files), store_file))
  fresh <- location_read(be)
  expect_s3_class(fresh, "rcs_location")
  expect_identical(fresh$catalog, catalog_empty())
  expect_identical(fresh$files, files_empty())
  expect_identical(fresh$token, loc$token)
  expect_identical(fresh$token, catalog_token(be))
  expect_identical(fresh$token, md5_file(file.path(be$root, "_catalog.parquet")))
  expect_identical(history_read(be), history_empty())
  expect_false(store_json_read(be))
  expect_false(location_exists(be_new(withr::local_tempdir())))
})

test_that("catalog files are read in the order catalog, files and counted", {
  local_backend_fallback()
  loc <- new_test_location()
  read <- character()
  get <- be_get
  local_mocked_bindings(be_get = function(be, path, dest) {
    read <<- c(read, path)
    get(be, path, dest)
  })
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  location_read(loc$backend)
  expect_identical(read, c("_catalog.parquet", "_files.parquet"))
  trace <- rcs_trace()
  counted <- trace[trace$counter == "catalog_read", ]
  expect_setequal(counted$detail, c("_catalog.parquet", "_files.parquet"))
  expect_identical(counted$location, rep(loc$uri, 2))
})

test_that("catalog files are written in the order history, files, catalog", {
  local_backend_fallback()
  loc <- new_test_location()
  written <- character()
  put <- be_put
  local_mocked_bindings(be_put = function(be, src, path) {
    written <<- c(written, path)
    put(be, src, path)
  })
  out <- location_write(loc, catalog_empty(), files_empty(), history_empty())
  expect_identical(written, c("_history.parquet", "_files.parquet", "_catalog.parquet"))
  written <- character()
  location_write(loc, catalog_empty(), files_empty())
  expect_identical(written, c("_files.parquet", "_catalog.parquet"))
  expect_identical(out$token, catalog_token(loc$backend))
})

test_that("a missing or broken catalog file aborts", {
  local_backend_fallback()
  be <- be_new(withr::local_tempdir())
  expect_error(location_read(be), class = "rcs_error_backend")
  loc <- new_test_location()
  writeLines("not parquet", file.path(loc$backend$root, "_catalog.parquet"))
  expect_error(location_read(loc$backend), class = "rcs_error_schema")
})

test_that("_store.json holds the store's history default", {
  local_backend_fallback()
  be <- be_new(withr::local_tempdir())
  expect_false(store_json_read(be))
  store_json_write(be, TRUE)
  expect_true(store_json_read(be))
  expect_identical(readLines(file.path(be$root, store_file)), '{"history":true}')
  expect_error(store_json_write(be, NA), class = "rcs_error_argument")
  loc <- location_init(be_new(file.path(be$root, "x")), history = TRUE)
  expect_true(store_json_read(loc$backend))
})

test_that("manifests are written and read through the backend", {
  local_backend_fallback()
  loc <- new_test_location()
  staged <- files_stage(sim_table(), "sales/daily", title = "T", description = "D", dir = withr::local_tempdir())
  path <- manifest_write(loc$backend, staged$manifest)
  expect_identical(path, manifest_path("sales/daily", staged$entry$version))
  back <- manifest_read(loc$backend, "sales/daily", staged$entry$version)
  expect_identical(back, staged$manifest)
  expect_error(manifest_read(loc$backend, "sales/daily", strrep("0", 16)), class = "rcs_error_version_not_found")
})

test_that("history_version_rows() gives one row per path of a version", {
  staged <- files_stage(sim_table(), "sales/daily", title = "T", description = "D",
    partition = "year", dir = withr::local_tempdir())
  rows <- staged$files
  hist <- rows
  hist$replaced <- now_utc()
  hist <- vctrs::vec_rbind(hist, hist)
  out <- history_version_rows(hist, "sales/daily", staged$entry$version)
  expect_identical(out, rows)
  expect_identical(nrow(history_version_rows(hist, "sales/daily", strrep("1", 16))), 0L)
})

stage <- function(data, dataset = "sales/daily", ...) {
  files_stage(data, dataset, title = "T", description = "D", ...,
    dir = withr::local_tempdir(.local_envir = parent.frame()))
}

test_that("catalog_set_version() adds a dataset and replaces it with and without history", {
  x <- sim_table()
  v1 <- stage(x, partition = "year")
  first <- catalog_set_version(catalog_empty(), files_empty(), history_empty(), v1$entry, v1$files, FALSE)
  expect_identical(first$catalog, v1$entry)
  expect_identical(first$files, v1$files)
  expect_identical(first$history, history_empty())
  expect_identical(first$delete, character())

  other <- stage(rcs_sim_table(30, seed = 2), "sales/summary")
  both <- catalog_set_version(first$catalog, first$files, first$history, other$entry, other$files, FALSE)
  expect_identical(both$catalog$dataset, c("sales/daily", "sales/summary"))

  y <- x
  y$qty[y$year == min(y$year)][[1]] <- 999L
  v2 <- stage(y, partition = "year")
  shared <- intersect(v1$files$md5, v2$files$md5)
  expect_length(shared, nrow(v1$files) - 1L)

  kept <- catalog_set_version(both$catalog, both$files, both$history, v2$entry, v2$files, TRUE,
    replaced = as.POSIXct("2026-01-01", tz = "UTC"))
  expect_identical(kept$catalog$version[kept$catalog$dataset == "sales/daily"], v2$entry$version)
  expect_identical(nrow(kept$history), nrow(v1$files))
  expect_true(all(kept$history$version == v1$entry$version))
  expect_true(all(kept$history$replaced == as.POSIXct("2026-01-01", tz = "UTC")))
  expect_identical(kept$delete, character())

  dropped <- catalog_set_version(both$catalog, both$files, both$history, v2$entry, v2$files, FALSE)
  expect_identical(dropped$history, history_empty())
  expect_setequal(
    dropped$delete,
    c(setdiff(v1$files$path, v2$files$path), manifest_path("sales/daily", v1$entry$version))
  )
  expect_identical(dropped$files[dropped$files$dataset == "sales/summary", ], other$files)

  # the same version again changes nothing
  same <- catalog_set_version(kept$catalog, kept$files, kept$history, v2$entry, v2$files, TRUE)
  expect_identical(same$history, kept$history)
  expect_identical(same$delete, character())

  # back to a version still in the history: its manifest and files stay
  back <- catalog_set_version(kept$catalog, kept$files, kept$history, v1$entry, v1$files, FALSE)
  expect_identical(
    back$delete,
    c(setdiff(v2$files$path, v1$files$path), manifest_path("sales/daily", v2$entry$version))
  )
})

test_that("catalog_set_version() keeps files shared by an update", {
  x <- sim_table()
  full <- stage(x, partition = "year")
  kept_rows <- full$files[1, ]
  changed <- x[x$year != x$year[x$year == min(x$year)][[1]], ]
  changed$qty <- changed$qty + 1L
  upd <- stage(changed, partition = "year", keep = kept_rows)
  base <- catalog_set_version(catalog_empty(), files_empty(), history_empty(), full$entry, full$files, FALSE)
  out <- catalog_set_version(base$catalog, base$files, base$history, upd$entry, upd$files, FALSE)
  expect_false(kept_rows$path %in% out$delete)
  expect_true(kept_rows$path %in% out$files$path)
  expect_true(all(setdiff(full$files$path, kept_rows$path) %in% out$delete))
})

test_that("catalog_drop_dataset() removes a dataset", {
  v1 <- stage(sim_table(), partition = "year")
  other <- stage(rcs_sim_table(30, seed = 2), "sales/summary")
  a <- catalog_set_version(catalog_empty(), files_empty(), history_empty(), v1$entry, v1$files, FALSE)
  a <- catalog_set_version(a$catalog, a$files, a$history, other$entry, other$files, FALSE)
  gone <- catalog_drop_dataset(a$catalog, a$files, a$history, "sales/daily", FALSE)
  expect_identical(gone$catalog$dataset, "sales/summary")
  expect_false(any(gone$files$dataset == "sales/daily"))
  expect_setequal(gone$delete, c(v1$files$path, manifest_path("sales/daily", v1$entry$version)))
  kept <- catalog_drop_dataset(a$catalog, a$files, a$history, "sales/daily", TRUE)
  expect_identical(kept$delete, character())
  expect_identical(nrow(kept$history), nrow(v1$files))
  expect_identical(catalog_drop_dataset(a$catalog, a$files, a$history, "nope", FALSE)$delete, character())
  expect_identical(files_unreferenced(c(v1$files$path, "x"), gone$files, gone$history), c(v1$files$path, "x"))
})

test_that("the fixture store is valid in every configuration", {
  skip_below_level("default")
  fx <- local_test_store()
  expect_identical(fx$datasets, c("sales/daily", "sales/summary"))
  expect_length(fx$st$secondary, 2)
  expect_store_valid(fx$st)
  fx <- local_test_store(partial = TRUE, history = TRUE)
  expect_store_valid(fx$st)
  expect_identical(fx$st$secondary[[2]]$catalog$dataset, "sales/daily")
  old_version <- fx$st$secondary[[2]]$catalog$version
  hist <- history_read(fx$st$primary$backend)
  expect_identical(unique(hist$version), old_version)
  fx <- local_test_store(secondaries = 0)
  expect_length(fx$st$secondary, 0)
  expect_store_valid(fx$st)
})

test_that("expect_store_valid() catches broken stores", {
  skip_below_level("default")
  fx <- local_test_store(secondaries = 1)
  path <- fx$st$primary$files$path[[1]]
  full <- file.path(fx$primary, path)
  bytes <- readBin(full, "raw", file.size(full))
  bytes[100] <- as.raw((as.integer(bytes[100]) + 1L) %% 256L)
  writeBin(bytes, full)
  expect_failure(expect_store_valid(fx$st), "MD5 differs")

  fx <- local_test_store(secondaries = 1)
  unlink(file.path(fx$primary, fx$st$primary$files$path[[1]]))
  expect_failure(expect_store_valid(fx$st), "missing files")

  fx <- local_test_store(secondaries = 1)
  writeLines("x", file.path(fx$primary, "sales/daily/stray.parquet"))
  expect_failure(expect_store_valid(fx$st), "named by no catalog")
  expect_success(expect_store_valid(fx$st, orphans_ok = TRUE))

  fx <- local_test_store(secondaries = 1)
  m <- fx$st$primary$catalog
  unlink(file.path(fx$primary, manifest_path(m$dataset[[1]], m$version[[1]])))
  expect_failure(expect_store_valid(fx$st), "no readable manifest")

  fx <- local_test_store(secondaries = 1)
  st <- fx$st
  loc <- st$primary
  catalog <- loc$catalog
  catalog$rows[[1]] <- catalog$rows[[1]] + 1
  loc <- location_write(loc, catalog, loc$files)
  store_set_location(st, loc)
  expect_failure(expect_store_valid(st), "rows differ")

  fx <- local_test_store(secondaries = 1)
  stale <- fx$st$primary
  catalog <- stale$catalog
  catalog$title[[1]] <- "Another title"
  location_write(stale, catalog, stale$files)
  expect_failure(expect_store_valid(fx$st), "stale")
})

test_that("files_lookup() finds current files, history files, and re-reads once", {
  skip_below_level("default")
  fx <- local_test_store(history = TRUE, secondaries = 0)
  st <- fx$st
  loc <- st$primary
  current <- loc$catalog$version[loc$catalog$dataset == "sales/daily"]
  rows <- files_lookup(loc, "sales/daily", current)
  expect_identical(rows, loc$files[loc$files$dataset == "sales/daily", ])

  old <- unique(history_read(loc$backend)$version)
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  old_rows <- files_lookup(loc, "sales/daily", old)
  expect_true(all(old_rows$version == old))
  expect_identical(names(old_rows), names(files_schema()))
  reads <- rcs_trace()
  expect_identical(reads$detail[reads$counter == "catalog_read"], "_history.parquet")

  # a version written after the connection read its catalogs
  stale <- loc
  y <- rcs_sim_table(60, seed = 9)
  fixture_write(st, y, "sales/daily", title = "T", description = "D", partition = "year")
  newer <- st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]
  store_set_location(st, stale)
  found <- files_lookup(stale, "sales/daily", newer, st = st)
  expect_true(all(found$version == newer))
  expect_identical(st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"], newer)

  expect_error(
    files_lookup(st$primary, "sales/daily", strrep("0", 16)),
    "store_refresh", class = "rcs_error_version_not_found"
  )
})

test_that("catalog_rebuild() restores catalogs from manifests", {
  skip_below_level("default")
  fx <- local_test_store(history = TRUE, secondaries = 0)
  be <- fx$st$primary$backend
  stored <- location_read(be)
  hist <- history_read(be)
  out <- catalog_rebuild(be)
  expect_identical(out$catalog, stored$catalog)
  expect_identical(out$files, stored$files)
  drop_replaced <- function(h) h[order(h$dataset, h$path, method = "radix"), names(files_schema())]
  expect_identical(drop_replaced(out$history), drop_replaced(hist))
  expect_identical(nrow(out$skipped), 0L)

  # written back, the store is valid again
  unlink(file.path(be$root, unname(catalog_files)))
  loc <- location_write(new_location(backend = be), out$catalog, out$files, out$history)
  store_set_location(fx$st, loc)
  expect_store_valid(fx$st)
})

test_that("catalog_rebuild() falls back to an earlier complete manifest", {
  skip_below_level("default")
  fx <- local_test_store(history = TRUE, secondaries = 0)
  be <- fx$st$primary$backend
  current <- fx$st$primary$files
  daily <- current[current$dataset == "sales/daily", ]
  hist <- history_read(be)
  lost <- setdiff(daily$path, hist$path)[[1]]
  unlink(file.path(be$root, lost))
  out <- catalog_rebuild(be)
  expect_identical(out$catalog$version[out$catalog$dataset == "sales/daily"], unique(hist$version))
  expect_identical(nrow(out$history), 0L)
})

test_that("catalog_rebuild() uses the rcs metadata of datasets without manifest", {
  skip_below_level("default")
  fx <- local_test_store(secondaries = 0)
  be <- fx$st$primary$backend
  stored <- fx$st$primary
  for (i in seq_len(nrow(stored$catalog))) {
    unlink(file.path(be$root, manifest_path(stored$catalog$dataset[[i]], stored$catalog$version[[i]])))
  }
  out <- catalog_rebuild(be)
  expect_identical(out$catalog$dataset, stored$catalog$dataset)
  expect_identical(out$catalog$version, stored$catalog$version)
  same <- c("kind", "title", "description", "key", "sorted_by", "partition", "columns",
    "n_files", "rows", "bytes", "crs", "h3_res", "index_of")
  expect_identical(out$catalog[same], stored$catalog[same])
  cols <- setdiff(names(files_schema()), "created")
  expect_identical(out$files[cols], stored$files[cols])
  expect_true(all(is.na(out$catalog$history)))
  expect_identical(nrow(out$skipped), 0L)
})

test_that("catalog_rebuild() reports what it cannot rebuild", {
  skip_below_level("default")
  fx <- local_test_store(secondaries = 0)
  be <- fx$st$primary$backend
  stored <- fx$st$primary
  daily <- stored$catalog[stored$catalog$dataset == "sales/daily", ]
  unlink(file.path(be$root, manifest_path("sales/daily", daily$version)))
  one <- stored$files$path[stored$files$dataset == "sales/daily"][[1]]
  file.copy(file.path(be$root, one), file.path(be$root, sub("part-[0-9a-f]+", paste0("part-", strrep("a", 16)), one)))
  dir.create(file.path(be$root, "other"))
  writeLines("x", file.path(be$root, "other", "a.tif"))
  plain <- file.path(be$root, "plain", "part-0.parquet")
  dir.create(dirname(plain))
  arrow::write_parquet(data.frame(a = 1), plain)
  m <- stored$catalog[stored$catalog$dataset == "sales/summary", ]
  summary_file <- stored$files$path[stored$files$dataset == "sales/summary"]
  unlink(file.path(be$root, summary_file))

  out <- catalog_rebuild(be)
  expect_identical(nrow(out$catalog), 0L)
  reasons <- stats::setNames(out$skipped$reason, ifelse(is.na(out$skipped$dataset), "-", out$skipped$dataset))
  expect_match(reasons[["sales/daily"]], "several file versions")
  expect_match(reasons[["sales/summary"]], "missing files")
  expect_true(any(grepl("raster", out$skipped$reason)))
  expect_true(any(grepl("metadata", out$skipped$reason)))
  expect_true("plain/part-0.parquet" %in% unlist(out$skipped$paths))
})

test_that("expect_store_valid() checks index tables against their dataset", {
  skip_below_level("default")
  local_mocked_bindings(geo_metadata = function(data, crs) '{"version":"1.1.0"}')
  fx <- local_test_store(tables = FALSE, secondaries = 1)
  st <- fx$st
  n <- 6
  geoms <- lapply(seq_len(n), function(i) sf::st_point(c(-29 + i / 10, 7)))
  data <- tibble::tibble(
    id = seq_len(n),
    .rcs_id = bit64::as.integer64(seq_len(n)),
    h3 = bit64::as.integer64(600000L + c(1L, 1L, 2L, 2L, 3L, 3L)),
    bbox = bbox_df(-29 + 1:n / 10, 7, -29 + 1:n / 10, 7),
    geometry = unclass(sf::st_as_binary(sf::st_sfc(geoms)))
  )
  index <- tibble::tibble(
    .rcs_id = bit64::as.integer64(c(2L, 2L, 5L)),
    h3 = bit64::as.integer64(600000L + c(1L, 2L, 3L)),
    h3_main = bit64::as.integer64(600000L + c(1L, 1L, 3L)),
    share = c(0.5, 0.5, 1)
  )
  land <- function(index) {
    staged <- files_stage(data, "shapes/points", title = "P", description = "P.",
      kind = "geospatial", crs = "x", h3_res = 5L, dir = withr::local_tempdir(.local_envir = parent.frame()))
    staged_index <- files_stage(index, "shapes/points__h3", title = "I", description = "I.",
      index_of = "shapes/points", sorted_by = c("h3", ".rcs_id"),
      dir = withr::local_tempdir(.local_envir = parent.frame()))
    for (i in seq_along(store_locations(st))) {
      fixture_land(st, store_locations(st)[[i]], staged, FALSE)
      fixture_land(st, store_locations(st)[[i]], staged_index, FALSE)
    }
  }
  land(index)
  expect_identical(st$primary$catalog$index_of, c(NA, "shapes/points"))
  expect_store_valid(st)

  bad <- index
  bad$h3_main[[3]] <- bit64::as.integer64(600002L)
  land(bad)
  expect_failure(expect_store_valid(st), "h3_main differs")
  bad <- index
  bad$.rcs_id[[3]] <- bit64::as.integer64(99L)
  land(bad)
  expect_failure(expect_store_valid(st), ".rcs_id values missing")
})

test_that("the geospatial fixture is valid and rebuilds", {
  skip_below_level("default")
  fx <- local_test_store(geospatial = TRUE, secondaries = 1)
  st <- fx$st
  expect_true(all(c("shapes/polygons", "shapes/polygons__h3", "polygons", "shapes/points", "shapes/lines") %in%
    st$primary$catalog$dataset))
  expect_true(is.na(st$primary$catalog$h3_res[st$primary$catalog$dataset == "polygons"]))
  expect_store_valid(st)
  out <- catalog_rebuild(st$primary$backend)
  expect_identical(out$catalog, st$primary$catalog)
  expect_identical(out$files, st$primary$files)
})

# Geocoding engine column (plan 0002, D30) ------------------------------------

# Rewrites `_catalog.parquet` of a location folder as the schema before plan
# 0002 had it: without the column `geocode_engine`.
# Read from memory: a memory-mapped file cannot be overwritten on Windows.
read_catalog_file <- function(root, as_data_frame = FALSE) {
  path <- file.path(root, "_catalog.parquet")
  arrow::read_parquet(readBin(path, "raw", file.size(path)), as_data_frame = as_data_frame)
}

drop_engine_column <- function(root) {
  path <- file.path(root, "_catalog.parquet")
  table <- read_catalog_file(root)
  arrow::write_parquet(table[, setdiff(names(table), "geocode_engine")], path, compression = "zstd")
}

catalog_file_columns <- function(root) {
  names(read_catalog_file(root))
}

catalog_file_engines <- function(root) {
  catalog <- read_catalog_file(root, as_data_frame = TRUE)
  stats::setNames(catalog$geocode_engine, catalog$dataset)
}

test_that("a catalog file of the old schema is read, validated and rewritten with the column", {
  fx <- local_test_store(secondaries = 0)
  drop_engine_column(fx$primary)
  expect_false("geocode_engine" %in% catalog_file_columns(fx$primary))
  be <- be_new(fx$primary)
  loc <- location_read(be)
  expect_identical(names(loc$catalog), names(catalog_schema()))
  expect_true(all(is.na(loc$catalog$geocode_engine)))
  expect_no_error(schema_validate(loc$catalog, "catalog"))
  written <- location_write(loc, loc$catalog, loc$files)
  expect_true("geocode_engine" %in% catalog_file_columns(fx$primary))
  expect_identical(location_read(be)$catalog, loc$catalog)
  expect_identical(written$token, catalog_token(be))
})

local_engine_store <- function(frame = parent.frame()) {
  fx <- local_test_store(tables = TRUE, geospatial = "points", secondaries = 1, frame = frame)
  fixture_write(fx$st, rcs_sim_points(30, seed = 7), "shapes/engine",
    title = "Points with engine", description = "Simulated points written with an engine.",
    geocode_engine = "auto", locations = store_locations(fx$st)[1]
  )
  fx$st <- fixture_connect(fx$primary, fx$secondary)
  fx
}

test_that("store_rebuild() keeps the geocoding engine from manifests and from file metadata", {
  skip_below_level("default")
  withr::local_options(rcs.quiet = TRUE)
  fx <- local_engine_store()
  st <- fx$st
  stored <- st$primary$catalog
  expect_identical(stored$geocode_engine[stored$dataset == "shapes/engine"], "auto")
  expect_true(all(is.na(stored$geocode_engine[stored$dataset != "shapes/engine"])))

  store_rebuild(st, fx$primary)
  expect_identical(catalog_file_engines(fx$primary)[stored$dataset], stats::setNames(stored$geocode_engine, stored$dataset))

  be <- st$primary$backend
  for (i in seq_len(nrow(stored))) {
    unlink(file.path(be$root, manifest_path(stored$dataset[[i]], stored$version[[i]])))
  }
  store_rebuild(st, fx$primary)
  rebuilt <- st$primary$catalog
  expect_identical(rebuilt$version, stored$version)
  expect_identical(rebuilt$geocode_engine, stored$geocode_engine)
})

test_that("store_sync() and store_copy() work between an old-format location and a new one", {
  skip_below_level("default")
  withr::local_options(rcs.quiet = TRUE)
  fx <- local_engine_store()
  secondary <- fx$secondary[[1]]
  # a table only in the secondary, then the secondary goes back to the old schema
  fixture_write(fx$st, rcs_sim_table(30, seed = 9), "sales/extra",
    title = "Extra sales", description = "A table only in the secondary.",
    locations = store_locations(fx$st)[2]
  )
  drop_engine_column(secondary)
  st <- fixture_connect(fx$primary, fx$secondary)
  expect_true(all(is.na(st$secondary[[1]]$catalog$geocode_engine)))

  # new primary -> old secondary
  out <- store_sync(st)
  expect_true("shapes/engine" %in% unlist(out$datasets))
  expect_true("geocode_engine" %in% catalog_file_columns(secondary))
  engines <- catalog_file_engines(secondary)
  expect_identical(engines[["shapes/engine"]], "auto")
  expect_true(all(is.na(engines[names(engines) != "shapes/engine"])))

  # old secondary -> new primary
  drop_engine_column(secondary)
  st <- fixture_connect(fx$primary, fx$secondary)
  store_copy(st, "sales/extra", from = secondary, to = fx$primary)
  engines <- catalog_file_engines(fx$primary)
  expect_true("sales/extra" %in% names(engines))
  expect_true(is.na(engines[["sales/extra"]]))
  expect_identical(engines[["shapes/engine"]], "auto")
  expect_true("geocode_engine" %in% catalog_file_columns(fx$primary))
})
