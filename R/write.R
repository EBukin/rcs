# The write pipeline: `store_write()` and the internal steps that work
# package G reuses for `store_sync()`, `store_copy()` and `store_delete()`:
#
#   * `with_retry()`: up to three attempts of a transfer, with increasing
#     waits (`retry_waits()`, mocked to zero in tests);
#   * `land_location()`: brings one location to a set of dataset versions:
#     uploads the files it lacks (compared by path and MD5 with its catalogs,
#     then with the stored MD5 of what is already there), verifies the MD5
#     of every upload, uploads the manifests and switches the catalogs under
#     the write guard;
#   * `write_guard()`: the local lock and the token check of one location;
#   * `switch_catalogs()`: the catalog switch of one location in the fixed
#     order, with the recovery of a switch that failed half-way, and the
#     deletion of unreferenced files when history is off.
#
# A "version source" (`src`) describes one dataset version to land: a list
# with `entry` (one-row catalog tibble), `files` (its file rows),
# `manifest_local` (a local manifest file, or `NULL` to copy the primary's;
# `store_write()` always writes its own, with the time of the call)
# and `changed` (`FALSE` when the primary already holds exactly this entry).
# The local copies of data files are found through a context environment
# (`write_context()`): staged files first, else a download from the primary.

# store_write() ---------------------------------------------------------------

#' Write a dataset to a store
#'
#' Writes a table, an `sf` object or a `terra::SpatRaster` as one dataset of
#' the store, in the primary location and in every available secondary one.
#' The files are staged locally, checked, uploaded where they are missing,
#' verified by MD5, and the catalogs of each location are switched to the
#' new version last, so that readers always see either the old or the new
#' version.
#'
#' @section Kinds:
#' The kind is set by the class of `x`: an `sf` object is `geospatial`, a
#' `SpatRaster` is a `raster`, any other data frame is a `table`.
#'
#' * Geospatial data get the columns `.rcs_id` (row identifier), `h3` (the
#'   H3 cell at `h3_res` holding the largest part of each geometry; not with
#'   `geocode = FALSE`) and `bbox` (bounding box), and are sorted by `h3`.
#'   Rows that cross H3 cells are listed in an index table
#'   `<dataset>__h3`, written, replaced and removed with the dataset.
#' * Prepared geospatial data ([rcs_geo_add()], or rows read back with
#'   `collect()`) may hold these columns already: `.rcs_id` is dropped and
#'   assigned again; `h3` and `bbox` must equal what the write computes
#'   (else the write aborts naming the rows; prepare with the same
#'   `geocode_engine`, or call [rcs_geo_strip()] first), and `h3_res`, when
#'   not given, is taken from the cells. Columns `h3_p<r>` are written as
#'   they are; with `partition = "h3"` one named as the chosen partition
#'   column must hold the same cells, and then serves as it. Raw and
#'   prepared data give the same version.
#' * A raster is written as one Cloud Optimized GeoTIFF; it cannot be
#'   partitioned or updated.
#' * A lazy table on a DuckDB connection is written as a `table` (see
#'   "DuckDB input").
#'
#' @section DuckDB input:
#' `x` may be a lazy table on a DuckDB connection (from [dplyr::tbl()] or
#' `store_open(engine = "duckdb")`). Its query runs once inside DuckDB into a
#' temporary copy, the table `rcs_write_<random>` on the same connection,
#' which every later step reads and which is dropped when the call ends,
#' also after an error; the copy needs room in DuckDB's memory or its
#' temporary folder. The key and the partitions are checked in DuckDB, and
#' the rows are fetched in batches of `getOption("rcs.duckdb_batch_rows")`
#' rows (default `5e5`), so that R holds about one batch at a time; a
#' progress bar shows the batches unless `options(rcs.quiet = TRUE)`. The
#' files equal those written from the same rows collected into R.
#'
#' * Modes `"create"` and `"replace"` only; `"update"` aborts.
#' * Columns `.rcs_id`, `h3`, `bbox` and `geom` are the package's own and
#'   are dropped with a message.
#' * Types: integer, double, `VARCHAR`, `DATE` and `BOOLEAN` are stored as
#'   they are; `BIGINT` is stored as 64-bit integers read back as
#'   `bit64::integer64`; `TIMESTAMP` is stored without time zone (its wall
#'   clock) and `TIMESTAMP WITH TIME ZONE` in UTC. `HUGEINT`, `UHUGEINT`,
#'   `INTERVAL`, `UNION` and `MAP` columns abort; cast them in the query.
#' * Lazy tables on other databases abort: collect them first.
#'
#' @section Modes:
#' * `"create"`: the dataset must not exist yet.
#' * `"replace"`: the whole dataset is replaced by `x`; columns, key,
#'   partitioning and kind may change. A dataset that does not exist yet is
#'   created.
#' * `"update"`: for partitioned datasets only. The partitions whose values
#'   occur in `x` are replaced entirely by the rows of `x`; the other
#'   partitions are kept; new values add partitions. The columns and their
#'   types must equal the stored ones, and the key must stay unique across
#'   the whole dataset. A message lists every replaced partition with its old
#'   and new number of rows: rows of a replaced partition that are missing
#'   from `x` disappear. In this mode `key`, `partition`, `h3_res`,
#'   `geocode` and `geocode_engine` come from the stored dataset; arguments
#'   that disagree abort.
#'   With `partition = "h3"`, an update that would need more than
#'   `max_files` files re-partitions the whole dataset at a coarser H3
#'   resolution.
#'
#' Writing the same data again gives the same version: the call reports the
#' dataset as unchanged, uploads nothing to the primary, and only brings
#' secondary locations that differ up to date.
#'
#' @section History:
#' Whether the replaced version is kept is decided by the dataset's own
#' setting (`history`, recorded in its catalog entry), else by the
#' connection's (`store_connect(history = )`), else by the store's default
#' ([store_create()]). Without history, the files of the replaced version
#' are deleted right after the catalogs are switched; with history, they stay
#' until [store_prune()] removes them.
#'
#' @section Failures:
#' Every transfer is tried up to three times. If the primary fails before
#' its catalog is switched, the call aborts and no catalog has changed;
#' uploaded files are reused when the call is repeated (and removed by
#' [store_prune()] otherwise). If a secondary fails, the call warns,
#' continues with the next location and reports the secondary as behind;
#' `store_sync()` repairs it.
#'
#' @param st A store connection made by [store_connect()]. It is updated in
#'   place, so that it can be used for further writes without refreshing.
#' @param x The data: a data frame, an `sf` object, a `terra::SpatRaster`,
#'   or a lazy table on a DuckDB connection (see "DuckDB input").
#' @param dataset The dataset's full name: lower-case letters, digits and
#'   `_`, with `/` between folders, e.g. `"sales/daily"`.
#' @param title,description Short title and description, required.
#' @param key Columns that identify the rows, or `NULL`. Their values must be
#'   unique together.
#' @param partition `NULL` for one file; column names to write one file per
#'   combination of their values; or `"h3"` (geospatial data) to partition
#'   by the H3 parent cell at the finest resolution that gives at most
#'   `max_files` files.
#' @param mode `"create"`, `"replace"` or `"update"` (see "Modes").
#' @param h3_res H3 resolution of the geocodes, 0 to 15.
#' @param geocode `FALSE` writes geospatial data without H3 cells and
#'   without index table; spatial reads then use bounding boxes only.
#' @param geocode_engine How the H3 cells of geometries that cross cell
#'   edges are computed, recorded with the dataset:
#'   * `"auto"` (default): each such geometry is checked on the sphere; an
#'     invalid one (for example valid in the plane but with a duplicated
#'     vertex) is rebuilt by s2, and when the rebuilt copy does not keep its
#'     area (length for lines) it is geocoded in the plane instead.
#'   * `"s2"`: on the sphere; invalid geometries are rebuilt by s2.
#'   * `"planar"`: in the plane (slower).
#'
#'   Rebuilt geometries are used only for the cells; the stored geometry is
#'   unchanged. One warning names the rows rebuilt or geocoded in the plane.
#'   An update uses the stored engine (a different one aborts); a dataset
#'   written without one geocodes new rows with `"s2"`.
#' @param max_files Most partition files.
#' @param history `TRUE` or `FALSE` sets the dataset's history setting;
#'   `NULL` leaves it as it is.
#' @param source,inputs Optional provenance: where the data come from and
#'   what they were made from.
#' @param columns Named character vector, column (or layer) name to
#'   description. `NULL` keeps the descriptions already stored for columns
#'   that still exist.
#' @param check `TRUE` compares sampled rows of the staged files with `x`
#'   before anything is uploaded (see [store_check()]).
#' @param rows_per_group Rows per Parquet row group.
#' @param crs The coordinate reference system of the WKB column `geometry`
#'   of a lazy DuckDB table (anything [sf::st_crs()] accepts, e.g. `4326`);
#'   required for such a table, ignored otherwise.
#' @return A tibble with one row per location, invisibly: `location`,
#'   `role`, `status` (`"written"`, `"unchanged"`, `"same"` for a secondary
#'   that already held the version, `"behind"` or `"unavailable"`), `files`
#'   (files of the version), `uploaded` (files sent), `bytes` (bytes sent)
#'   and `seconds`. The attribute `version` holds the dataset's version.
#' @seealso [store_check()], [store_history()], [store_prune()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-write")
#' st <- store_connect(
#'   file.path(root, "primary"),
#'   secondary = file.path(root, "copy"),
#'   create = TRUE
#' )
#' sales <- rcs_sim_table(200, seed = 1)
#' store_write(st, sales, "sales/daily",
#'   title = "Daily sales",
#'   description = "Simulated daily sales by shop and product.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#'
#' # The same data again: nothing is uploaded
#' store_write(st, sales, "sales/daily",
#'   title = "Daily sales",
#'   description = "Simulated daily sales by shop and product.",
#'   key = c("shop_id", "date", "product"), partition = "year",
#'   mode = "replace"
#' )
#'
#' # Replace one year
#' year_2024 <- sales[sales$year == 2024, ]
#' year_2024$qty <- year_2024$qty + 1L
#' store_write(st, year_2024, "sales/daily",
#'   title = "Daily sales",
#'   description = "Simulated daily sales by shop and product.",
#'   mode = "update"
#' )
#' st
#' unlink(root, recursive = TRUE)
store_write <- function(st, x, dataset, title, description, key = NULL,
                        partition = NULL,
                        mode = c("create", "replace", "update"),
                        h3_res = 5L, geocode = TRUE,
                        geocode_engine = c("auto", "s2", "planar"),
                        max_files = 50L, history = NULL, source = NULL, inputs = NULL,
                        columns = NULL, check = TRUE, rows_per_group = 50000L,
                        crs = NULL) {
  validate_store(st)
  local_trace("store_write")
  call <- rlang::current_env()
  mode <- rlang::arg_match(mode)
  check_dataset_name(dataset, call = call)
  check_string(title, call = call)
  check_string(description, call = call)
  check_string(source, allow_null = TRUE, call = call)
  check_string(inputs, allow_null = TRUE, call = call)
  check_flag(history, allow_null = TRUE, call = call)
  check_flag(geocode, call = call)
  engine_given <- !missing(geocode_engine)
  geocode_engine <- if (engine_given) check_geocode_engine(geocode_engine, call = call) else "auto"
  check_flag(check, call = call)
  max_files <- check_count(max_files, call = call)
  rows_per_group <- check_count(rows_per_group, call = call)
  kind <- write_kind(x, call)
  if (kind == "duckdb") {
    check_duckdb_mode(mode, call)
  }

  # Step 1: fresh catalogs of every location, then the mode.
  failed <- write_refresh(st, call)
  existing <- catalog_entry(st$primary$catalog, dataset)
  existing_index <- catalog_entry(st$primary$catalog, index_name(dataset))
  check_write_mode(mode, dataset, existing, call)
  dataset_history <- if (!is.null(history)) {
    history
  } else if (nrow(existing) == 1) {
    existing$history
  } else {
    NA
  }
  keep_history <- effective_history(st, dataset_history)
  now <- now_utc()

  dir <- file.path(
    rcs_option("rcs.staging_dir"),
    paste0("rcs-write-", md5_string(paste(dataset, Sys.getpid(), as.numeric(Sys.time()), stats::runif(1))))
  )
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  # Steps 2 to 7: stage the new version (and its index table).
  args <- list(
    x = x, kind = kind, dataset = dataset, title = title,
    description = description, key = key, partition = partition,
    h3_res = h3_res, h3_res_given = !missing(h3_res), geocode = geocode,
    geocode_engine = geocode_engine, engine_given = engine_given, max_files = max_files,
    history = dataset_history, source = source %||% NA_character_,
    inputs = inputs %||% NA_character_, columns = columns,
    rows_per_group = rows_per_group, crs = crs, existing = existing,
    existing_index = existing_index, dir = dir, now = now, mode = mode,
    call = call
  )
  plan <- if (kind == "raster") {
    stage_raster(args)
  } else if (kind == "duckdb") {
    stage_duckdb(args)
  } else if (mode == "update") {
    args$h3_given <- !missing(h3_res) || !missing(geocode)
    stage_update(st, args)
  } else {
    stage_full(args)
  }
  warn_s2_rebuild(dataset, plan$rebuild)

  primary_files <- st$primary$files
  data_src <- resolve_target(plan$data, existing, primary_files, dir, now)
  sets <- list(data_src)
  if (!is.null(plan$index)) {
    sets[[2]] <- resolve_target(plan$index, existing_index, primary_files, dir, now)
  }
  drops <- if (is.null(plan$index)) index_name(dataset) else character()

  # Step 8: serialization check of freshly staged data files.
  new_data <- nrow(existing) == 0 || !identical(data_src$entry$version, existing$version)
  if (check && new_data) {
    check_staged(plan, data_src$entry, call)
  }

  ctx <- write_context(st, dir, sets)
  locations <- store_locations(st)
  widths <- write_widths(locations)
  primary_changed <- any(vapply(sets, function(s) s$changed, logical(1))) ||
    any(drops %in% st$primary$catalog$dataset)
  write_header(dataset, data_src, plan, mode, existing, primary_changed)

  # Step 9: the primary first; a failure aborts with no catalog changed.
  results <- list()
  results[[1]] <- land_primary(st, sets, drops, keep_history, ctx, now, dataset, widths, call)
  write_line(results[[1]], widths)

  # Then every secondary, in connection order; a failure warns.
  for (location in st$secondary) {
    uri <- location$uri
    result <- if (uri %in% names(failed)) {
      write_result(uri, "secondary", if (identical(failed[[uri]], "unavailable")) "unavailable" else "behind",
        message = failed[[uri]])
    } else {
      land_secondary(st, location, sets, drops, keep_history, ctx, now, dataset)
    }
    write_line(result, widths)
    results[[length(results) + 1L]] <- result
  }

  out <- vctrs::vec_rbind(!!!lapply(results, write_result_row))
  write_footer(out, data_src)
  attr(out, "version") <- data_src$entry$version
  invisible(out)
}

# Arguments and mode ------------------------------------------------------------

# The kind of `x`: "geospatial", "raster", "table", or "duckdb" for a lazy
# table on a DuckDB connection (written as a table, plan 0002, D36).
write_kind <- function(x, call = caller_env()) {
  if (inherits(x, "tbl_lazy")) {
    if (is_duckdb_lazy(x)) {
      return("duckdb")
    }
    abort_lazy_backend(x, call)
  }
  if (inherits(x, "sf")) {
    "geospatial"
  } else if (inherits(x, "SpatRaster")) {
    "raster"
  } else if (is.data.frame(x)) {
    "table"
  } else {
    cli::cli_abort(
      "{.arg x} must be a data frame, an {.cls sf} object or a {.cls SpatRaster}, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
}

# The entry of `dataset` in a catalog: a one-row tibble, or zero rows.
catalog_entry <- function(catalog, dataset) {
  catalog[catalog$dataset == dataset, ]
}

check_write_mode <- function(mode, dataset, existing, call = caller_env()) {
  if (mode == "create" && nrow(existing) == 1) {
    title <- existing$title
    rows <- format_count(existing$rows)
    updated <- format(local_time(existing$updated), "%Y-%m-%d %H:%M:%S")
    cli::cli_abort(
      c(
        "Dataset {.val {dataset}} already exists.",
        i = "{.emph {title}}: {rows} rows, updated {updated}.",
        i = "Use {.code mode = \"replace\"} to replace it, or {.code mode = \"update\"} to replace the partitions that {.arg x} holds."
      ),
      class = "rcs_error_dataset_exists", call = call
    )
  }
  if (mode == "update" && nrow(existing) == 0) {
    cli::cli_abort(
      c(
        "Dataset {.val {dataset}} does not exist, so it cannot be updated.",
        i = "Use {.code mode = \"create\"} to write it."
      ),
      class = "rcs_error_dataset_not_found", call = call
    )
  }
  invisible()
}

# Step 1: re-read the catalogs of every location. The primary must answer;
# a secondary that does not is reported in the result (named by its `uri`:
# the error message, or "unavailable" for a location unavailable since the
# connection).
write_refresh <- function(st, call = caller_env()) {
  be <- st$primary$backend
  reach(location_refresh(st, st$primary), be, "primary", call)
  failed <- list()
  for (location in st$secondary) {
    uri <- location$uri
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
          i = "Run {.fn store_sync} once it can be reached."),
        class = "rcs_warning_secondary_behind", parent = fresh
      )
      failed[[uri]] <- first_line(conditionMessage(fresh))
    }
  }
  failed
}

# Errors of a location that a write survives for a secondary (and reports
# as "behind"); anything else is a bug and propagates.
write_error_classes <- c("rcs_error_backend", "rcs_error_conflict", "rcs_error_locked", "rcs_error_schema")

first_line <- function(x) {
  x <- cli::ansi_strip(x)
  sub("\n.*$", "", x)
}

# Descriptions of the columns of a stored entry, as a named character vector
# (columns without a description left out), or `NULL`.
stored_descriptions <- function(entry, names) {
  if (nrow(entry) == 0) {
    return(NULL)
  }
  spec <- columns_from_json(entry$columns)
  keep <- !is.na(spec$description) & spec$name %in% names
  if (!any(keep)) {
    return(NULL)
  }
  stats::setNames(spec$description[keep], spec$name[keep])
}

created_of <- function(entry, now) {
  if (nrow(entry) == 1) entry$created else now
}

# Staging -----------------------------------------------------------------------

# A version source from the result of `files_stage()`.
staged_src <- function(staged) {
  list(
    entry = staged$entry,
    files = staged$files,
    manifest_local = staged$manifest_local,
    local = stats::setNames(staged$staged$local, staged$staged$path),
    changed = TRUE
  )
}

# create and replace of tables and geospatial data.
stage_full <- function(a) {
  data_dir <- file.path(a$dir, "data")
  if (a$kind == "table") {
    data <- tibble::as_tibble(a$x)
    descriptions <- a$columns %||% stored_descriptions(a$existing, names(data))
    staged <- files_stage(
      data, a$dataset, a$title, a$description,
      kind = "table", key = a$key, partition = a$partition,
      source = a$source, inputs = a$inputs, columns = descriptions,
      history = a$history, max_files = a$max_files,
      rows_per_group = a$rows_per_group, created = created_of(a$existing, a$now),
      dir = data_dir, call = a$call
    )
    return(list(data = staged_src(staged), index = NULL, reference = data, data_dir = data_dir))
  }
  prepared <- prepared_split(a$x, a$h3_res, a$h3_res_given, a$geocode, a$call)
  a$x <- prepared$x
  a$h3_res <- prepared$h3_res
  enc <- geo_encode(
    a$x, h3_res = a$h3_res, geocode = a$geocode, key = a$key,
    geocode_engine = a$geocode_engine
  )
  prepared_compare(prepared, enc, a$x, a$key, a$geocode_engine, a$call)
  descriptions <- a$columns %||% stored_descriptions(a$existing, names(enc$data))
  staged <- files_stage(
    enc$data, a$dataset, a$title, a$description,
    kind = "geospatial", key = a$key, partition = a$partition,
    crs = enc$crs, h3_res = if (a$geocode) as.integer(a$h3_res) else NA_integer_,
    geocode_engine = if (a$geocode) a$geocode_engine else NA_character_,
    source = a$source, inputs = a$inputs, columns = descriptions,
    history = a$history, max_files = a$max_files,
    rows_per_group = a$rows_per_group, created = created_of(a$existing, a$now),
    dir = data_dir, call = a$call
  )
  index <- NULL
  if (a$geocode && nrow(enc$index) > 0) {
    index <- stage_index(enc$index, a, as.integer(a$h3_res))
  }
  list(
    data = staged_src(staged), index = index, reference = enc$data,
    data_dir = data_dir, rebuild = rebuild_keys(enc, a$x, a$key)
  )
}

# The index table of a geospatial dataset: one file, or partitioned by H3
# when it exceeds `rows_per_group * 100` rows.
stage_index <- function(index, a, h3_res) {
  index <- index[c(".rcs_id", "h3", "h3_main", "share")]
  index <- index[order_radix(tibble::tibble(h3 = index$h3, id = index$.rcs_id)), ]
  large <- nrow(index) > a$rows_per_group * 100
  staged <- files_stage(
    index, index_name(a$dataset),
    title = paste("H3 index of", a$dataset),
    description = paste0("Rows of ", a$dataset, " that cross H3 cells at resolution ", h3_res, "."),
    kind = "table", partition = if (large) "h3", sorted_by = c("h3", ".rcs_id"),
    h3_max_res = h3_res, index_of = a$dataset, history = a$history,
    max_files = a$max_files, rows_per_group = a$rows_per_group,
    created = created_of(a$existing_index, a$now),
    dir = file.path(a$dir, "index"), call = a$call
  )
  staged_src(staged)
}

stage_raster <- function(a) {
  if (identical(a$mode, "update")) {
    cli::cli_abort(
      c("A raster cannot be updated.", i = "Use {.code mode = \"replace\"}."),
      class = "rcs_error_argument", call = a$call
    )
  }
  if (length(a$partition) > 0 || length(a$key) > 0) {
    cli::cli_abort(
      "A raster is stored as one file: {.arg partition} and {.arg key} do not apply.",
      class = "rcs_error_argument", call = a$call
    )
  }
  data_dir <- file.path(a$dir, "data")
  layers <- names(a$x)
  descriptions <- a$columns %||% stored_descriptions(a$existing, layers)
  staged <- raster_stage(
    a$x, a$dataset, a$title, a$description,
    source = a$source, inputs = a$inputs, columns = descriptions,
    history = a$history, dir = data_dir
  )
  entry <- staged$entry
  entry$created <- created_of(a$existing, a$now)
  entry$updated <- a$now
  manifest <- new_manifest(entry, staged$files, written = a$now)
  manifest_local <- file.path(data_dir, manifest_path(a$dataset, entry$version))
  manifest_write_local(manifest, manifest_local)
  src <- list(
    entry = entry, files = staged$files, manifest_local = manifest_local,
    local = stats::setNames(staged$staged, staged$files$path), changed = TRUE
  )
  list(data = src, index = NULL, reference = a$x, data_dir = data_dir)
}

# Update ------------------------------------------------------------------------

stage_update <- function(st, a) {
  call <- a$call
  existing <- a$existing
  dataset <- a$dataset
  if (a$kind == "raster" || existing$kind == "raster") {
    cli::cli_abort(
      c("A raster cannot be updated.", i = "Use {.code mode = \"replace\"}."),
      class = "rcs_error_argument", call = call
    )
  }
  if (a$kind != existing$kind) {
    cli::cli_abort(
      c(
        "{.val {dataset}} is a {existing$kind} dataset; {.arg x} would make it {a$kind}.",
        i = "Use {.code mode = \"replace\"} to change its kind."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  old_partition <- existing$partition[[1]]
  if (length(old_partition) == 0) {
    cli::cli_abort(
      c(
        "{.val {dataset}} is stored as one file, so it cannot be updated by partitions.",
        i = "Use {.code mode = \"replace\"}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  key <- existing$key[[1]]
  if (!is.null(a$key) && !identical(as.character(a$key), key)) {
    cli::cli_abort(
      c(
        "An update keeps the key of {.val {dataset}}.",
        i = "Stored key: {.field {key}}; given: {.field {a$key}}. Use {.code mode = \"replace\"} to change it."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  is_h3 <- length(old_partition) == 1 && grepl("^h3_p[0-9]+$", old_partition)
  given_partition <- if (is_h3) "h3" else old_partition
  if (!is.null(a$partition) && !identical(as.character(a$partition), given_partition)) {
    cli::cli_abort(
      c(
        "An update keeps the partitioning of {.val {dataset}}.",
        i = "Stored partition: {.field {given_partition}}. Use {.code mode = \"replace\"} to change it."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  res_old <- if (is_h3) as.integer(sub("^h3_p", "", old_partition)) else NA_integer_
  geocode <- a$kind == "geospatial" && !is.na(existing$h3_res)
  h3_res <- existing$h3_res
  if (a$kind == "geospatial" && isTRUE(a$h3_given) &&
    (!identical(a$geocode, geocode) || (geocode && !identical(as.integer(a$h3_res), h3_res)))) {
    cli::cli_abort(
      c(
        "An update keeps the geocodes of {.val {dataset}}.",
        i = "Stored: {if (geocode) paste0('h3_res = ', h3_res) else 'geocode = FALSE'}. Use {.code mode = \"replace\"} to change them."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  # D30: the stored engine; a dataset without one geocodes new rows per row
  # on the sphere ("s2") and keeps no engine.
  stored_engine <- existing$geocode_engine
  if (a$kind == "geospatial" && isTRUE(a$engine_given)) {
    check_update_engine(a$geocode_engine, stored_engine, dataset, geocode, call)
  }
  encode_engine <- if (is.na(stored_engine)) "s2" else stored_engine

  withr::local_options(arrow.int64_downcast = FALSE)
  be <- st$primary$backend
  old_files <- st$primary$files[st$primary$files$dataset == dataset, ]
  spec_old <- columns_from_json(existing$columns)

  ids <- NULL
  enc <- NULL
  if (a$kind == "geospatial") {
    ids <- lapply(old_files$path, function(p) read_stored(be, p, ".rcs_id")$.rcs_id)
    names(ids) <- old_files$path
    all_ids <- do.call(c, c(list(bit64::integer64()), unname(ids)))
    id_start <- if (length(all_ids) > 0) max(all_ids) + bit64::as.integer64(1) else bit64::as.integer64(1)
    prepared <- prepared_split(a$x, h3_res, TRUE, geocode, call)
    a$x <- prepared$x
    enc <- geo_encode(
      a$x, h3_res = if (geocode) h3_res else 5L, geocode = geocode,
      key = if (length(key)) key, id_start = id_start, geocode_engine = encode_engine
    )
    prepared_compare(prepared, enc, a$x, if (length(key)) key, encode_engine, call)
    data <- enc$data
  } else {
    data <- tibble::as_tibble(a$x)
  }
  check_key(data, key, call = call)
  # D27: a supplied partition column is checked by `partition_plan()`.
  supplied_partition <- if (is_h3 && old_partition %in% names(data)) data[[old_partition]]
  data <- check_update_columns(
    data[setdiff(names(data), if (is_h3) old_partition)], spec_old,
    exclude = if (is_h3) old_partition, dataset, call
  )
  if (!is.null(supplied_partition)) {
    data[[old_partition]] <- supplied_partition
  }

  plan_new <- partition_plan(
    data, given_partition, max_files = .Machine$integer.max,
    h3_max_res = res_old, call = call
  )
  new_pv <- vapply(plan_new$groups, function(g) {
    partition_values_json(as.list(plan_new$data[g[[1]], plan_new$partition]))
  }, character(1))
  new_rows <- lengths(plan_new$groups)
  replaced <- old_files[old_files$partition_values %in% new_pv, ]
  kept <- old_files[!old_files$partition_values %in% new_pv, ]
  if (length(key) > 0 && nrow(kept) > 0) {
    check_key_across(be, kept, data, key, call)
  }
  update_message(dataset, replaced, new_pv, new_rows, nrow(kept))

  n_total <- nrow(kept) + length(new_pv)
  repartition <- n_total > a$max_files
  if (repartition && !is_h3) {
    cli::cli_abort(
      c(
        "Partitioning by {.field {old_partition}} would give {n_total} files, more than {.arg max_files} = {a$max_files}.",
        i = "Raise {.arg max_files}, or replace the dataset with a coarser partition."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (repartition && res_old == 0) {
    cli::cli_abort(
      c(
        "Even H3 resolution 0 gives more than {.arg max_files} = {a$max_files} partitions.",
        i = "Raise {.arg max_files}."
      ),
      class = "rcs_error_argument", call = call
    )
  }

  descriptions <- a$columns %||% stored_descriptions(existing, names(data))
  data_dir <- file.path(a$dir, "data")
  stage <- function(data, keep, h3_max_res) {
    files_stage(
      data, dataset, a$title, a$description,
      kind = a$kind, key = key, partition = given_partition,
      crs = if (a$kind == "geospatial") enc$crs else NA_character_,
      h3_res = if (geocode) h3_res else NA_integer_, h3_max_res = h3_max_res,
      geocode_engine = if (geocode) stored_engine else NA_character_,
      source = a$source, inputs = a$inputs, columns = descriptions,
      history = a$history, max_files = a$max_files,
      rows_per_group = a$rows_per_group, keep = keep,
      created = existing$created, dir = data_dir, call = call
    )
  }
  reference <- data
  if (!repartition) {
    staged <- stage(data, kept, res_old)
  } else {
    old_data <- lapply(kept$path, function(p) {
      restore_types(read_stored(be, p), spec_old)
    })
    new_data <- data[setdiff(names(data), old_partition)]
    all <- if (length(old_data) == 0) {
      # every old file is replaced: only the new rows remain
      new_data
    } else {
      old_data <- vctrs::vec_rbind(!!!old_data)
      old_data <- old_data[setdiff(names(old_data), old_partition)]
      vctrs::vec_rbind(old_data, new_data[names(old_data)])
    }
    order_cols <- c(list(h3 = all$h3), lapply(stats::setNames(key, key), function(k) all[[k]]), list(id = all$.rcs_id))
    all <- all[order_radix(tibble::new_tibble(order_cols, nrow = nrow(all))), ]
    staged <- stage(all, NULL, res_old - 1L)
    reference <- all
    cli::cli_inform(c(
      i = "Partition {.field {old_partition}} would give {n_total} files, more than {.arg max_files} = {a$max_files}.",
      i = "The whole dataset is re-partitioned as {.field {staged$partition}}."
    ))
  }

  index <- NULL
  if (geocode) {
    kept_ids <- do.call(c, c(list(bit64::integer64()), unname(ids[kept$path])))
    index_rows <- enc$index
    if (nrow(a$existing_index) == 1) {
      index_files <- st$primary$files$path[st$primary$files$dataset == index_name(dataset)]
      old_index <- lapply(index_files, function(p) {
        read_stored(be, p, c(".rcs_id", "h3", "h3_main", "share"))
      })
      old_index <- vctrs::vec_rbind(!!!old_index)
      if (!is.null(old_index) && nrow(old_index) > 0) {
        old_index <- old_index[bit64::`%in%`(old_index$.rcs_id, kept_ids), ]
        index_rows <- vctrs::vec_rbind(old_index, index_rows)
      }
    }
    if (nrow(index_rows) > 0) {
      index <- stage_index(index_rows, a, h3_res)
    }
  }
  list(
    data = staged_src(staged), index = index, reference = reference,
    data_dir = data_dir, check_paths = staged$staged$path,
    rebuild = if (!is.null(enc)) rebuild_keys(enc, a$x, if (length(key)) key)
  )
}

check_update_engine <- function(given, stored, dataset, geocode, call) {
  if (!geocode) {
    cli::cli_abort(
      c(
        "{.val {dataset}} is stored with {.code geocode = FALSE}, so it has no geocoding engine.",
        i = "Leave out {.arg geocode_engine}, or use {.code mode = \"replace\"} to geocode it."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (is.na(stored)) {
    cli::cli_abort(
      c(
        "{.val {dataset}} has no geocoding engine recorded; an update geocodes its new rows with {.val s2}.",
        i = "Leave out {.arg geocode_engine}, or use {.code mode = \"replace\"} to set one."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (!identical(given, stored)) {
    cli::cli_abort(
      c(
        "An update keeps the geocoding engine of {.val {dataset}}.",
        i = "Stored: {.val {stored}}; given: {.val {given}}. Use {.code mode = \"replace\"} to change it."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  invisible()
}

# Prepared data (D27) ------------------------------------------------------------

# The package's columns of a prepared `sf`: `.rcs_id` is dropped; `h3` and
# `bbox` are set aside, to be compared with what the write computes. With
# cells, `h3_res` comes from them when not given; mixed resolutions, a given
# `h3_res` that differs, and cells with `geocode = FALSE` abort.
# Returns `x` without those columns, the supplied `h3` (hex, input order) and
# `bbox`, and the resolution to geocode at.
prepared_split <- function(x, h3_res, h3_res_given, geocode, call) {
  out <- list(x = x, h3 = NULL, bbox = NULL, h3_res = h3_res)
  present <- intersect(c(".rcs_id", "h3", "bbox"), names(x))
  if (length(present) == 0) {
    return(out)
  }
  if ("h3" %in% present) {
    if (!geocode) {
      cli::cli_abort(
        c(
          "{.arg x} has a column {.field h3}, but {.code geocode = FALSE} writes no cells.",
          i = "Remove it with {.code rcs_geo_strip(x, \"h3\")}, or leave out {.code geocode = FALSE}."
        ),
        class = "rcs_error_prepared", call = call
      )
    }
    hex <- h3_input_hex(x[["h3"]], arg = "x$h3", call = call)
    res <- sort(unique(h3_hex_res(hex[!is.na(hex)])))
    if (length(res) > 1) {
      cli::cli_abort(
        c(
          "The column {.field h3} of {.arg x} holds cells of several resolutions: {res}.",
          i = "Prepare {.arg x} with {.fn rcs_geo_add} at one {.arg h3_res}, or call {.fn rcs_geo_strip} first."
        ),
        class = "rcs_error_prepared", call = call
      )
    }
    if (length(res) == 1) {
      if (isTRUE(h3_res_given) && !identical(as.integer(res), as.integer(h3_res))) {
        cli::cli_abort(
          c(
            "The column {.field h3} of {.arg x} holds cells of resolution {res}, but the write uses {.code h3_res = {h3_res}}.",
            i = "Leave out {.arg h3_res} to write at resolution {res}, or call {.fn rcs_geo_strip} first."
          ),
          class = "rcs_error_prepared", call = call
        )
      }
      out$h3_res <- as.integer(res)
    }
    out$h3 <- hex
  }
  if ("bbox" %in% present) {
    out$bbox <- x[["bbox"]]
  }
  out$x <- geo_drop_columns(x, present)
  out
}

# Compares the supplied `h3` and `bbox` with those of `geo_encode()`, row by
# row of `x`; any difference aborts naming the first five keys (or rows).
prepared_compare <- function(prepared, enc, x, key, geocode_engine, call) {
  if (is.null(prepared$h3) && is.null(prepared$bbox)) {
    return(invisible())
  }
  n <- length(enc$order)
  differs <- rep(FALSE, n)
  columns <- character()
  if (!is.null(prepared$h3)) {
    computed <- character(n)
    computed[enc$order] <- h3_int64_to_hex_raw(enc$data$h3)
    bad <- !((computed == prepared$h3) %in% TRUE | (is.na(computed) & is.na(prepared$h3)))
    if (any(bad)) columns <- c(columns, "h3")
    differs <- differs | bad
  }
  if (!is.null(prepared$bbox)) {
    computed <- enc$data$bbox
    computed[enc$order, ] <- enc$data$bbox
    supplied <- prepared$bbox
    bad <- if (!is.data.frame(supplied) || !all(bbox_names %in% names(supplied))) {
      rep(TRUE, n)
    } else {
      Reduce(`|`, lapply(bbox_names, function(b) {
        s <- supplied[[b]]
        if (!is.numeric(s)) {
          return(rep(TRUE, n))
        }
        s <- as.double(s)
        !((s == computed[[b]]) %in% TRUE | (is.na(s) & is.na(computed[[b]])))
      }))
    }
    if (any(bad)) columns <- c(columns, "bbox")
    differs <- differs | bad
  }
  if (!any(differs)) {
    return(invisible())
  }
  rows <- which(differs)
  shown <- utils::head(rows, 5L)
  keys <- if (length(key) > 0) {
    format_key_values(tibble::as_tibble(sf::st_drop_geometry(x))[shown, key, drop = FALSE])
  } else {
    paste("row", shown)
  }
  more <- if (length(rows) > 5) paste0("; and ", length(rows) - 5, " more") else ""
  first <- paste0(paste(keys, collapse = "; "), more, ".")
  cli::cli_abort(
    c(
      "{length(rows)} row{?s} of {.arg x} {?has/have} {.field {columns}} values that differ from those the write computes.",
      x = paste("First:", first),
      i = "The write geocodes with {.code geocode_engine = \"{geocode_engine}\"}.",
      i = "Prepare {.arg x} with {.fn rcs_geo_add} and the same {.arg geocode_engine}, or call {.fn rcs_geo_strip} first."
    ),
    class = "rcs_error_prepared", call = call
  )
}

# Geocoding repairs (D32) ----------------------------------------------------------

# Keys of the rows of `x` that `geo_encode()` rebuilt on the sphere or
# geocoded in the plane after a failed rebuild: the key columns, else
# `.rcs_id`. A list of two character vectors, in input row order.
rebuild_keys <- function(enc, x, key) {
  keys_of <- function(rows) {
    if (length(rows) == 0) {
      return(character())
    }
    if (length(key) > 0) {
      values <- tibble::as_tibble(sf::st_drop_geometry(x))[rows, key, drop = FALSE]
    } else {
      values <- tibble::tibble(.rcs_id = enc$data$.rcs_id[match(rows, enc$order)])
    }
    format_key_values(values)
  }
  list(rebuilt = keys_of(enc$rebuilt), fallback = keys_of(enc$fallback))
}

# One warning per write when any row was rebuilt or fell back to the plane:
# counts, and the first five keys of each group. Signalled with `warn = 1`
# (unless the caller set `warn >= 1`), so that a top-level call prints it at
# once, before the upload lines, instead of deferring it to the end.
warn_s2_rebuild <- function(dataset, rebuild) {
  warn_geo_rebuild("{.val {dataset}}", rebuild, list(dataset = dataset))
}

# The same warning for any subject: `subject` is cli text interpolated in
# `env` (a list), e.g. "{.arg x}" for the geospatial verbs, whose keys are
# row numbers.
warn_geo_rebuild <- function(subject, rebuild, env = list()) {
  n_rebuilt <- length(rebuild$rebuilt)
  n_fallback <- length(rebuild$fallback)
  if (n_rebuilt + n_fallback == 0) {
    return(invisible())
  }
  shown <- function(keys) {
    n <- length(keys)
    more <- if (n > 5) paste0("; and ", n - 5, " more") else ""
    paste0(paste(utils::head(keys, 5L), collapse = "; "), more, ".")
  }
  if (getOption("warn", 0) < 1) {
    withr::local_options(warn = 1)
  }
  cli::cli_warn(
    c(
      paste0("Geocoding ", subject, ": {n_rebuilt + n_fallback} row{?s} {?is/are} invalid on the sphere."),
      i = "{n_rebuilt} rebuilt by s2, {n_fallback} geocoded in the plane after a failed rebuild check.",
      "*" = if (n_rebuilt > 0) paste("Rebuilt:", shown(rebuild$rebuilt)),
      "*" = if (n_fallback > 0) paste("In the plane:", shown(rebuild$fallback))
    ),
    class = "rcs_warning_s2_rebuild",
    .envir = list2env(env, parent = rlang::current_env())
  )
  invisible()
}

# Read stored rows (all row groups) of one Parquet file, as a tibble.
read_stored <- function(be, path, columns = NULL) {
  withr::local_options(arrow.int64_downcast = FALSE)
  groups <- files_row_groups(be, path)
  if (nrow(groups) == 0) {
    return(NULL)
  }
  table <- files_read_row_groups(be, path, groups$row_group, columns)
  tibble::as_tibble(as.data.frame(table))
}

# Columns and types of the rows of an update must equal the stored ones.
# Returns `data` with its columns in the stored order.
check_update_columns <- function(data, spec_old, exclude, dataset, call) {
  spec_old <- spec_old[!spec_old$name %in% exclude, ]
  spec_new <- files_columns_spec(data, files_arrow_schema(data))
  missing <- setdiff(spec_old$name, spec_new$name)
  extra <- setdiff(spec_new$name, spec_old$name)
  common <- intersect(spec_old$name, spec_new$name)
  type_of <- function(spec, name) {
    i <- match(name, spec$name)
    paste0(spec$type[[i]], if (!is.null(spec$r_type[[i]])) paste0(" ", to_json(spec$r_type[[i]])))
  }
  differ <- common[vapply(common, function(n) !identical(type_of(spec_old, n), type_of(spec_new, n)), logical(1))]
  if (length(missing) + length(extra) + length(differ) > 0) {
    shown <- vapply(differ, function(n) {
      gsub("([{}])", "\\1\\1", paste0(n, ": stored ", type_of(spec_old, n), ", given ", type_of(spec_new, n)))
    }, character(1))
    cli::cli_abort(
      c(
        "The columns of {.arg x} differ from those of {.val {dataset}}.",
        x = if (length(missing) > 0) "Missing: {.field {missing}}.",
        x = if (length(extra) > 0) "Not stored: {.field {extra}}.",
        rlang::set_names(unname(shown), rep("x", length(shown))),
        i = "An update keeps the columns and types; use {.code mode = \"replace\"} to change them."
      ),
      class = "rcs_error_schema", call = call
    )
  }
  data[spec_old$name]
}

# Normalised key columns, comparable across files and data frames.
key_frame <- function(data, key) {
  cols <- lapply(key, function(k) normalise_key(data[[k]]))
  tibble::new_tibble(stats::setNames(cols, key), nrow = nrow(data))
}

normalise_key <- function(v) {
  if (is.factor(v) || inherits(v, "integer64")) {
    as.character(v)
  } else if (inherits(v, c("POSIXct", "Date", "difftime"))) {
    as.numeric(v)
  } else {
    attributes(v) <- NULL
    v
  }
}

# The key must stay unique across the whole dataset after an update.
check_key_across <- function(be, kept, data, key, call) {
  parts <- lapply(seq_len(nrow(kept)), function(i) {
    rows <- read_stored(be, kept$path[[i]], key)
    if (is.null(rows)) {
      return(NULL)
    }
    out <- key_frame(rows, key)
    out$.partition <- rep(kept$partition_values[[i]], nrow(out))
    out
  })
  stored <- vctrs::vec_rbind(!!!parts)
  if (is.null(stored) || nrow(stored) == 0) {
    return(invisible())
  }
  at <- vctrs::vec_match(key_frame(data, key), stored[key])
  dup <- which(!is.na(at))
  if (length(dup) == 0) {
    return(invisible())
  }
  n <- length(dup)
  shown <- utils::head(dup, 5L)
  lines <- paste0(
    format_key_values(tibble::as_tibble(as.list(data)[key])[shown, ]),
    " (kept partition ", vapply(stored$.partition[at[shown]], format_partition, character(1)), ")"
  )
  cli::cli_abort(
    c(
      "The key {.field {key}} would repeat across partitions: {n} key value{?s} of {.arg x} {?is/are} already in partitions that are kept.",
      rlang::set_names(lines, rep("x", length(lines))),
      i = if (n > 5) "And {n - 5} more."
    ),
    class = c("rcs_error_key", "rcs_error_argument"), call = call
  )
}

# `{"year":2024}` as `year = 2024`, braces escaped for cli.
format_partition <- function(pv) {
  values <- jsonlite::fromJSON(pv, simplifyVector = FALSE)
  if (length(values) == 0) {
    return("all rows")
  }
  shown <- vapply(names(values), function(name) {
    v <- values[[name]]
    if (is.null(v)) {
      "null"
    } else if (grepl("^h3_p[0-9]+$", name)) {
      h3_as_hex(bit64::as.integer64(as.character(v)))
    } else {
      as.character(v)
    }
  }, character(1))
  text <- paste0(names(values), " = ", shown, collapse = ", ")
  gsub("([{}])", "\\1\\1", text)
}

rows_text <- function(n) {
  paste0(format_count(n), if (n == 1) " row" else " rows")
}

update_message <- function(dataset, replaced, new_pv, new_rows, n_kept) {
  old_rows <- as.numeric(replaced$rows)[match(new_pv, replaced$partition_values)]
  lines <- vapply(seq_along(new_pv), function(i) {
    if (is.na(old_rows[[i]])) {
      paste0(format_partition(new_pv[[i]]), ": new, ", rows_text(new_rows[[i]]))
    } else {
      paste0(format_partition(new_pv[[i]]), ": ", rows_text(old_rows[[i]]), " -> ", rows_text(new_rows[[i]]))
    }
  }, character(1))
  n_rep <- sum(!is.na(old_rows))
  n_add <- sum(is.na(old_rows))
  cli::cli_inform(c(
    i = "Updating {.val {dataset}}: {n_rep} partition{?s} replaced, {n_add} added, {n_kept} kept.",
    rlang::set_names(lines, rep("*", length(lines)))
  ))
}

# Unchanged versions -------------------------------------------------------------

# Compare a staged version with the entry the primary holds. The same
# version with the same entry (apart from times and provenance of the
# session) is unchanged: the primary's entry and files are kept. The same
# version with another entry (a raster's title, the history setting) is a
# change of the entry only: the primary's files with a new manifest.
resolve_target <- function(src, existing, primary_files, dir, now) {
  if (nrow(existing) == 0 || !identical(src$entry$version, existing$version)) {
    return(src)
  }
  files <- primary_files[primary_files$dataset == existing$dataset, ]
  probe <- src$entry
  for (field in c("created", "updated", "writer", "r_version", "rcs_version")) {
    probe[[field]] <- existing[[field]]
  }
  if (identical(entry_key(probe), entry_key(existing))) {
    # A secondary brought up to date gets the manifest written anew with
    # the time of the landing, as by store_sync(), so that its latest
    # manifest is the current version for store_rebuild().
    manifest_local <- file.path(dir, "manifest", manifest_path(existing$dataset, existing$version))
    manifest_write_local(new_manifest(existing, files, written = now), manifest_local)
    return(list(entry = existing, files = files, manifest_local = manifest_local, local = src$local, changed = FALSE))
  }
  entry <- src$entry
  entry$created <- existing$created
  entry$updated <- now
  manifest <- new_manifest(entry, files, written = now)
  manifest_local <- file.path(dir, "manifest", manifest_path(entry$dataset, entry$version))
  manifest_write_local(manifest, manifest_local)
  list(entry = entry, files = files, manifest_local = manifest_local, local = src$local, changed = TRUE)
}

entry_key <- function(entry) {
  to_json(row_to_list(strip_md5_attr(entry), schema_kinds("catalog")))
}

# Does a catalog hold exactly this entry?
holds_entry <- function(catalog, entry) {
  current <- catalog_entry(catalog, entry$dataset)
  nrow(current) == 1 && identical(entry_key(current), entry_key(entry))
}

# Serialization check of the staged files ------------------------------------------

check_staged <- function(plan, entry, call) {
  be <- be_new(plan$data_dir)
  files <- plan$data$files
  if (!is.null(plan$check_paths)) {
    files <- files[files$path %in% plan$check_paths, ]
  }
  if (nrow(files) == 0) {
    return(invisible())
  }
  # DuckDB input: the plan carries its own check (plan 0002, D40)
  results <- if (!is.null(plan[["check"]])) {
    plan[["check"]](be, files, entry)
  } else {
    check_serialization(be, entry, files, plan$reference, n = 20L, columns = NULL)
  }
  bad <- results[results$status == "failed", ]
  if (nrow(bad) > 0) {
    lines <- gsub("([{}])", "\\1\\1", paste0(bad$path, ": ", bad$problem))
    cli::cli_abort(
      c(
        "The serialization check of the staged files failed; nothing was uploaded.",
        rlang::set_names(lines, rep("x", length(lines)))
      ),
      class = "rcs_error_check", call = call
    )
  }
  invisible()
}

# Landing a version in a location --------------------------------------------------

#' Context of a write: where local copies of data files and manifests come
#' from
#'
#' @param st An `rcs_store`.
#' @param dir A local folder for downloads.
#' @param sets A list of version sources.
#' @return An environment: `dir`, `primary` (the primary's backend), `local`
#'   (named character vector, relative path to local file).
#' @noRd
write_context <- function(st, dir, sets = list()) {
  ctx <- new.env(parent = emptyenv())
  ctx$dir <- dir
  ctx$primary <- st$primary$backend
  local <- unlist(lapply(sets, function(s) s$local))
  ctx$local <- if (is.null(local)) character() else local
  ctx
}

# A local copy of a data file of the version: the staged file, else a
# download from the primary (MD5-checked), kept for the next location.
source_file <- function(ctx, path, md5) {
  local <- unname(ctx$local[path])
  if (length(local) == 1 && !is.na(local) && file.exists(local)) {
    return(local)
  }
  dest <- file.path(ctx$dir, "from-primary", path)
  with_retry(function() be_get(ctx$primary, path, dest))
  if (!is.na(md5) && !identical(md5_file(dest), md5)) {
    uri <- ctx$primary$uri
    cli::cli_abort(
      "The copy of {.path {path}} downloaded from {.path {uri}} does not have the MD5 its catalog records.",
      class = c("rcs_error_md5", "rcs_error_backend"), call = NULL
    )
  }
  ctx$local[[path]] <- dest
  dest
}

# The local manifest of a version source: its own, else the primary's.
source_manifest <- function(ctx, src) {
  if (!is.null(src$manifest_local)) {
    return(src$manifest_local)
  }
  source_file(ctx, manifest_path(src$entry$dataset, src$entry$version), NA_character_)
}

#' Up to three attempts of a transfer
#'
#' @param fn A function without arguments doing one transfer.
#' @param waits Seconds to wait after the first and the second failure.
#' @return The value of `fn()`. Errors of class `rcs_error_backend` are
#'   retried; the third one is signalled again. Other errors propagate at
#'   once.
#' @noRd
with_retry <- function(fn, waits = retry_waits()) {
  for (attempt in 1:3) {
    result <- tryCatch(list(value = fn()), rcs_error_backend = function(e) e)
    if (!inherits(result, "condition")) {
      return(result$value)
    }
    if (attempt == 3) {
      rlang::cnd_signal(result)
    }
    Sys.sleep(waits[[attempt]])
  }
}

# Waits between attempts, in seconds. Tests mock this function.
retry_waits <- function() {
  c(1, 4)
}

#' Upload files to a location and verify them
#'
#' @param be The backend of the location.
#' @param todo A tibble with `path` and `md5` of the files to upload.
#' @param ctx The write context (`write_context()`).
#' @param label Text of the progress line.
#' @return The number of bytes uploaded. Every file is uploaded with
#'   `with_retry()`; afterwards the stored MD5 of every file is compared with
#'   `md5`; files that differ are deleted and the call aborts with class
#'   `c("rcs_error_md5", "rcs_error_backend")`.
#' @noRd
upload_verified <- function(be, todo, ctx, label = be$uri) {
  if (nrow(todo) == 0) {
    return(0)
  }
  bar <- NULL
  if (!isTRUE(rcs_option("rcs.quiet"))) {
    bar <- cli::cli_progress_bar(
      format = "{label} {cli::pb_bar} {cli::pb_current}/{cli::pb_total} files",
      total = nrow(todo), clear = TRUE
    )
  }
  bytes <- 0
  for (i in seq_len(nrow(todo))) {
    path <- todo$path[[i]]
    local <- source_file(ctx, path, todo$md5[[i]])
    with_retry(function() be_put(be, local, path))
    bytes <- bytes + file.size(local)
    if (!is.null(bar)) cli::cli_progress_update(id = bar)
  }
  if (!is.null(bar)) cli::cli_progress_done(id = bar)
  verify_md5(be, todo$path, todo$md5)
  bytes
}

verify_md5 <- function(be, paths, md5) {
  got <- be_md5(be, paths)
  bad <- is.na(got) | got != md5
  if (any(bad)) {
    tryCatch(be_delete(be, paths[bad & !is.na(got)]), rcs_error_backend = function(e) NULL)
    uri <- be$uri
    n <- sum(bad)
    cli::cli_abort(
      c(
        "MD5 verification failed for {n} file{?s} uploaded to {.path {uri}}.",
        rlang::set_names(gsub("([{}])", "\\1\\1", paths[bad]), rep("x", n))
      ),
      class = c("rcs_error_md5", "rcs_error_backend"), call = NULL
    )
  }
  invisible(TRUE)
}

#' Bring one location to a set of dataset versions
#'
#' Uploads the files of the versions that the location lacks, verifies
#' them, uploads the manifests and switches the catalogs under the write
#' guard (`switch_catalogs()`).
#'
#' @param st An `rcs_store`; the location is updated in place.
#' @param location The `rcs_location`, with its catalogs as read at the start
#'   of the operation (its `token` is the write guard's).
#' @param sets A list of version sources to land.
#' @param drops Datasets to remove from the location's catalogs.
#' @param keep_history The effective history setting.
#' @param ctx The write context.
#' @param replaced `POSIXct`: the `replaced` time of rows moved to history.
#' @return A list: `status` (`"written"`, or `"same"` when the location held
#'   every version and none of `drops`), `total` (files of the versions),
#'   `uploaded`, `bytes`, `seconds`. Aborts on failure; nothing of the
#'   location's catalogs has then changed.
#' @noRd
land_location <- function(st, location, sets, drops, keep_history, ctx, replaced) {
  start <- Sys.time()
  be <- location$backend
  needed <- Filter(function(s) !holds_entry(location$catalog, s$entry), sets)
  drops <- intersect(drops, location$catalog$dataset)
  total <- sum(vapply(sets, function(s) nrow(s$files), numeric(1)))
  if (length(needed) == 0 && length(drops) == 0) {
    return(list(status = "same", total = total, uploaded = 0, bytes = 0, seconds = 0))
  }
  history <- history_read(be)
  rows <- vctrs::vec_rbind(files_empty(), !!!lapply(needed, function(s) s$files))
  held <- paste(c(location$files$path, history$path), c(location$files$md5, history$md5))
  todo <- rows[!paste(rows$path, rows$md5) %in% held, c("path", "md5")]
  todo <- todo[!duplicated(todo$path), ]
  if (nrow(todo) > 0) {
    stored <- be_md5(be, todo$path)
    todo <- todo[is.na(stored) | stored != todo$md5, ]
  }
  bytes <- upload_verified(be, todo, ctx)
  for (s in needed) {
    local <- source_manifest(ctx, s)
    path <- manifest_path(s$entry$dataset, s$entry$version)
    with_retry(function() be_put(be, local, path))
    verify_md5(be, path, md5_file(local))
  }
  switch_catalogs(st, location, needed, drops, history, keep_history, replaced)
  list(
    status = "written", total = total, uploaded = nrow(todo), bytes = bytes,
    seconds = as.numeric(difftime(Sys.time(), start, units = "secs"))
  )
}

#' The write guard of one location
#'
#' Takes the location's lock (`be_lock()`; a no-op on cloud backends),
#' released when `frame` exits, and compares the MD5 of the stored
#' `_catalog.parquet` with the token read at the start of the operation.
#'
#' The caller sets `guard$switched <- TRUE` once the location's catalogs are
#' switched. A failing `be_unlock()` before that point is an error, as any
#' failure of the operation; after it, the switch stands, so the failure
#' only warns (class `rcs_warning_unlock`): the lock stays until it is older
#' than `getOption("rcs.lock_timeout")` and the next writer takes it over.
#'
#' @param location The `rcs_location` as read at the start.
#' @param frame The frame that holds the lock.
#' @return The guard, invisibly: an environment with the logical field
#'   `switched` (`FALSE`). Aborts with class `rcs_error_locked` when
#'   another writer holds a fresh lock, and with `rcs_error_conflict` when
#'   the catalog changed since it was read.
#' @noRd
write_guard <- function(location, frame = parent.frame()) {
  be <- location$backend
  be_lock(be)
  guard <- new.env(parent = emptyenv())
  guard$switched <- FALSE
  withr::defer(guard_release(be, guard), envir = frame)
  token <- catalog_token(be)
  if (!identical(token, location$token)) {
    uri <- location$uri
    cli::cli_abort(
      c(
        "Another writer changed {.path {uri}} since this call read its catalog.",
        i = "Nothing was changed there; run the call again."
      ),
      class = "rcs_error_conflict", call = NULL
    )
  }
  invisible(guard)
}

# Release the lock of a write guard; see `write_guard()`.
guard_release <- function(be, guard) {
  done <- tryCatch(be_unlock(be), error = function(e) e)
  if (!inherits(done, "error")) {
    return(invisible())
  }
  if (!isTRUE(guard$switched)) {
    rlang::cnd_signal(done)
  }
  uri <- be$uri
  timeout <- rcs_option("rcs.lock_timeout")
  cli::cli_warn(
    c(
      "The catalogs of {.path {uri}} were switched, but its lock could not be released.",
      i = "The lock stays until it is older than {timeout} second{?s}; the next writer then takes it over."
    ),
    class = "rcs_warning_unlock", parent = done
  )
  invisible()
}

#' Switch the catalogs of one location
#'
#' Under the write guard: applies the new versions (`catalog_set_version()`)
#' and removals (`catalog_drop_dataset()`) to the location's tables, writes
#' `_history.parquet` (when it changed), `_files.parquet` and
#' `_catalog.parquet` with `with_retry()`, updates the connection, and with
#' history off deletes the files no row names any more.
#'
#' A switch that fails is checked: when `_catalog.parquet` is still the one
#' read, `_files.parquet` and `_history.parquet` are written back as they
#' were and the error is signalled again; when the new catalog landed
#' despite the error, the switch counts as done.
#'
#' @param st An `rcs_store`.
#' @param location The `rcs_location` as read at the start.
#' @param sets A list of version sources (each with `entry` and `files`).
#' @param drops Dataset names to remove.
#' @param history The location's history table as read.
#' @param keep_history The effective history setting.
#' @param replaced `POSIXct`.
#' @return The new `rcs_location`, invisibly.
#' @noRd
switch_catalogs <- function(st, location, sets, drops, history, keep_history, replaced) {
  be <- location$backend
  guard <- write_guard(location)
  catalog <- location$catalog
  files <- location$files
  hist <- history
  delete <- character()
  for (s in sets) {
    new <- catalog_set_version(catalog, files, hist, s$entry, s$files, keep_history, replaced)
    catalog <- new$catalog
    files <- new$files
    hist <- new$history
    delete <- c(delete, new$delete)
  }
  for (d in drops) {
    new <- catalog_drop_dataset(catalog, files, hist, d, keep_history, replaced)
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
    written <- recover_switch(location, history, history_changed, written, sets, drops)
  }
  guard$switched <- TRUE
  store_set_location(st, written)
  if (!keep_history) {
    delete <- setdiff(unique(delete), c(written$files$path, hist$path))
    delete_quietly(be, delete)
  }
  invisible(written)
}

recover_switch <- function(location, history, history_changed, error, sets, drops) {
  be <- location$backend
  token <- tryCatch(catalog_token(be), error = function(e) NA_character_)
  if (identical(token, location$token)) {
    tryCatch(
      {
        if (history_changed) catalog_write(be, history, "history")
        catalog_write(be, location$files, "files")
      },
      error = function(e) NULL
    )
    rlang::cnd_signal(error)
  }
  fresh <- tryCatch(location_read(be), error = function(e) NULL)
  landed <- !is.null(fresh) &&
    all(vapply(sets, function(s) holds_entry(fresh$catalog, s$entry), logical(1))) &&
    !any(drops %in% fresh$catalog$dataset)
  if (!landed) {
    rlang::cnd_signal(error)
  }
  fresh
}

# Delete files after a catalog switch; a failure leaves orphans for
# `store_prune()` and warns.
delete_quietly <- function(be, paths) {
  if (length(paths) == 0) {
    return(invisible())
  }
  done <- tryCatch(be_delete(be, paths), rcs_error_backend = function(e) e)
  if (inherits(done, "error")) {
    uri <- be$uri
    cli::cli_warn(
      c(
        "Cannot delete {length(paths)} replaced file{?s} in {.path {uri}}.",
        i = "They are no longer named by the catalogs; {.fn store_prune} removes them later."
      ),
      class = "rcs_warning_delete", parent = done
    )
  }
  invisible()
}

# The primary: a failure aborts, with the connection refreshed.
land_primary <- function(st, sets, drops, keep_history, ctx, replaced, dataset, widths, call) {
  location <- st$primary
  result <- tryCatch(
    land_location(st, location, sets, drops, keep_history, ctx, replaced),
    error = function(e) e
  )
  if (inherits(result, "error")) {
    tryCatch(location_refresh(st, location), error = function(e) NULL)
    if (!inherits(result, write_error_classes)) {
      rlang::cnd_signal(result)
    }
    uri <- location$uri
    cli::cli_abort(
      c(
        "Writing {.val {dataset}} to the primary location {.path {uri}} failed.",
        i = "No catalog was changed. Run the call again: files already uploaded are reused."
      ),
      class = c("rcs_error_write", setdiff(class(result), c("rlang_error", "error", "condition"))),
      parent = result, call = call
    )
  }
  if (result$status == "same") result$status <- "unchanged"
  write_result(location$uri, "primary", result$status, result)
}

# A secondary: a failure warns, and the location is reported as behind.
land_secondary <- function(st, location, sets, drops, keep_history, ctx, replaced, dataset) {
  uri <- location$uri
  location <- store_locations(st)[[match(uri, store_uris(st))]]
  result <- tryCatch(
    land_location(st, location, sets, drops, keep_history, ctx, replaced),
    error = function(e) e
  )
  if (inherits(result, "error")) {
    if (!inherits(result, write_error_classes)) {
      rlang::cnd_signal(result)
    }
    tryCatch(location_refresh(st, location), error = function(e) NULL)
    cli::cli_warn(
      c(
        "Writing {.val {dataset}} to the secondary location {.path {uri}} failed; it is behind.",
        i = "Run {.fn store_sync} to bring it up to date."
      ),
      class = "rcs_warning_secondary_behind", parent = result
    )
    return(write_result(uri, "secondary", "behind", message = first_line(conditionMessage(result))))
  }
  write_result(uri, "secondary", result$status, result)
}

# Summary ---------------------------------------------------------------------

write_result <- function(uri, role, status, result = NULL, message = NA_character_) {
  list(
    location = uri, role = role, status = status,
    files = result$total %||% NA_real_, uploaded = result$uploaded %||% 0,
    bytes = result$bytes %||% 0, seconds = result$seconds %||% 0,
    message = message
  )
}

write_result_row <- function(r) {
  tibble::tibble(
    location = r$location, role = r$role, status = r$status,
    files = as.numeric(r$files), uploaded = as.numeric(r$uploaded),
    bytes = as.numeric(r$bytes), seconds = as.numeric(r$seconds)
  )
}

write_widths <- function(locations) {
  roles <- c("primary", rep("secondary", length(locations) - 1L))
  uris <- vapply(locations, function(l) l$uri, character(1))
  list(role = max(nchar(roles)), uri = max(cli::ansi_nchar(uris, type = "width")))
}

escape_braces <- function(x) {
  gsub("([{}])", "\\1\\1", x)
}

format_seconds <- function(s) {
  s <- as.numeric(s)
  if (s < 60) {
    sprintf("%.1fs", s)
  } else {
    sprintf("%dm %02ds", as.integer(s %/% 60), as.integer(round(s %% 60)))
  }
}

# cli collapses runs of spaces in messages; columns are padded with
# non-breaking spaces, which cli prints as spaces.
nbsp <- "\u00a0"

pad_right <- function(x, width) {
  paste0(x, strrep(nbsp, max(width - cli::ansi_nchar(x, type = "width"), 0)))
}

write_line <- function(r, widths) {
  gap <- strrep(nbsp, 2)
  head <- paste0(pad_right(r$role, widths$role), gap, pad_right(r$location, widths$uri))
  detail <- switch(
    r$status,
    written = paste0(
      format(r$uploaded), "/", format(r$files), " files sent",
      if (r$bytes > 0) paste0(gap, format_bytes(r$bytes)), gap, format_seconds(r$seconds)
    ),
    unchanged = "unchanged",
    same = "up to date",
    behind = paste0("behind: ", r$message),
    unavailable = "unavailable, skipped"
  )
  bullet <- switch(r$status, behind = "x", unavailable = "!", "v")
  rcs_inform(stats::setNames(escape_braces(paste0(head, gap, detail)), bullet))
}

write_header <- function(dataset, src, plan, mode, existing, changed) {
  entry <- src$entry
  rows <- format_count(entry$rows)
  # A raster's rows are its cells.
  unit <- if (identical(entry$kind, "raster")) "cells" else "rows"
  n <- as.numeric(entry$n_files)
  partition <- entry$partition[[1]]
  part <- if (length(partition) > 0) paste0(" (partition ", paste(partition, collapse = ", "), ")") else ""
  # The index table's files count among the files sent to each location.
  n_index <- if (is.null(plan$index)) 0 else as.numeric(plan$index$entry$n_files)
  index <- if (n_index > 0) cli::format_inline(", and its index table in {n_index} file{?s}") else ""
  if (!changed) {
    version <- entry$version
    rcs_inform(c(i = "{.val {dataset}} is unchanged (version {version}): {rows} {unit} in {n} file{?s}{part}{index}."))
    return(invisible())
  }
  verb <- if (nrow(existing) == 0 || mode == "update") "Writing" else "Replacing"
  rcs_inform(c(i = "{verb} {.val {dataset}}: {rows} {unit} in {n} file{?s}{part}{index}."))
}

write_footer <- function(out, src) {
  ok <- out$status %in% c("written", "unchanged", "same")
  behind <- out[!ok, ]
  n_files <- max(c(as.numeric(src$entry$n_files), out$files), na.rm = TRUE)
  k <- sum(ok)
  if (any(out$status == "written")) {
    rcs_inform(c(v = "MD5 identical for {n_files} file{?s} in {k} location{?s}. Catalogs updated."))
  } else if (k > 1) {
    rcs_inform(c(v = "All {k} locations hold this version."))
  }
  if (nrow(behind) > 0) {
    n <- nrow(behind)
    rcs_inform(c("!" = "{n} secondary location{?s} {?is/are} behind; run {.fn store_sync} to bring {?it/them} up to date."))
  }
  invisible()
}
