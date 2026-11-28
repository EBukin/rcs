# Reading: `store_read()`, `store_sample()`, `store_glimpse()`,
# `store_h3_hex()`, and the choice of what a read reads (`read_target()`).
# Every read uses the catalogs held by the connection (plan, "Connecting",
# freshness) and the file lookup of `files_lookup()`.

#' What a read reads
#'
#' Resolves the dataset name, chooses the location (`choose_location()`,
#' which prints the "reading from secondary" line), and finds the entry and
#' the files of the version.
#'
#' @param st An `rcs_store`.
#' @param dataset Name given by the user (full or short; index tables too).
#' @param version `NULL` or 16 hex characters.
#' @param call Environment for errors.
#' @return A list: `dataset` (full name), `entry` (the current entry, or the
#'   entry of the version's manifest for an earlier version), `location`
#'   (the `rcs_location`, as held by `st` after the file lookup) and `files`
#'   (the file rows of the version).
#' @noRd
read_target <- function(st, dataset, version = NULL, call = caller_env()) {
  check_string(version, allow_null = TRUE, call = call)
  if (!is.null(version) && !grepl("^[0-9a-f]{16}$", version)) {
    cli::cli_abort(
      "{.arg version} must be 16 hex characters, not {.val {version}}.",
      class = "rcs_error_argument", call = call
    )
  }
  name <- resolve_dataset(st, dataset, index = TRUE, call = call)
  location <- choose_location(st, name, version, call = call)
  catalog <- st$primary$catalog
  current <- catalog$version[catalog$dataset == name]
  if (is.null(version) || identical(version, current)) {
    version <- current
    entry <- catalog[catalog$dataset == name, ]
  } else {
    entry <- manifest_read(location$backend, name, version)$entry
  }
  files <- files_lookup(location, name, version, st = st, call = call)
  location <- store_locations(st)[[match(location$uri, store_uris(st))]]
  list(dataset = name, entry = entry, location = location, files = files)
}

# store_read() ----------------------------------------------------------------

#' Read a dataset
#'
#' Reads a table, a geospatial dataset or a raster from a store. Filters and
#' column selection are pushed into the scan, so only the needed files, row
#' groups and columns are read.
#'
#' * Filters (`...`) are dplyr filter expressions. A filter whose columns are
#'   all partition columns is first evaluated on the partition values in the
#'   catalog, so only the files of the matching partitions are opened.
#' * `intersects` keeps the rows of a geospatial dataset whose geometry
#'   intersects a query shape or H3 cells (see [store_intersects()] for the
#'   steps). With `exact = FALSE` or `geometry = FALSE` the result is the
#'   candidate set, a superset of the intersecting rows, and a message says
#'   so.
#' * A geospatial dataset is returned as an `sf` object with the catalog's
#'   coordinate reference system, or as a tibble with `geometry = FALSE`. Of
#'   the columns the package adds, the row identifier `.rcs_id` is dropped
#'   (unless named in `columns`); the H3 cell `h3` (`bit64::integer64`, see
#'   [store_h3_hex()]), the bounding box `bbox` and the partition column
#'   `h3_p<r>` are returned.
#' * A raster is returned as a `terra::SpatRaster` opened through GDAL, so
#'   only the tiles needed are read; `intersects` crops it to the query's
#'   bounding box (see "Rasters"). Filters, `columns`, `geometry`, `exact`
#'   and `exact_engine` do not apply to rasters and abort.
#'
#' @section Rasters:
#' A raster is returned as a `terra::SpatRaster` that points to the stored
#' file: at the location itself for a local store, through GDAL's virtual
#' file system for a bucket. No cell is read until it is needed: GDAL
#' fetches only the tiles a calculation or a window needs, from the location
#' read from. The file itself is copied only by a copy to a secondary
#' location (below).
#'
#' A raster is one file, so copying it to a secondary location is all or
#' nothing (see "Copy to secondary locations"). With a primary in a bucket
#' and a local secondary that lacks the raster or holds an older version,
#' the whole file is first copied to the secondary when it is at or under
#' the size limit, and the raster, or its window, is then read from that
#' copy. With `copy = FALSE`, a connection made with `copy_on_read =
#' FALSE`, or a file above the limit, nothing is copied and the read stays
#' on the bucket.
#'
#' * **The whole raster.** `store_read(st, "name")` returns every layer,
#'   with the layer names, the data type and the NoData value of the file.
#'   Cells that hold the NoData value are missing (`NA`).
#' * **A window.** `intersects` returns only the part inside the bounding
#'   box of the query, in the raster's CRS, rounded outwards to whole
#'   cells; a point or a line gives the cells it touches. The cells of the
#'   window are read at once, from the location read from (straight from
#'   the bucket when no local copy holds the version): this is the way to
#'   work with a map too large to read whole.
#'   The query takes the same forms as for geospatial data (an `sf`, `sfc`
#'   or `bbox` object in any CRS, or H3 cells). A query that does not
#'   overlap the raster aborts; one that crosses the antimeridian or holds
#'   a pole returns the raster uncropped.
#' * **Legend.** A layer written with categories (see "Rasters" in
#'   [store_write()]) comes back categorical: `terra::levels()` gives the
#'   codes and labels recorded with the dataset, `terra::freq()` and
#'   `terra::plot()` use the labels, and
#'   `terra::extract(x, cells, raw = TRUE)` gives the codes. The label
#'   column is named as it was when the map was written; the code column
#'   is named `value` (`code` when the label column is itself called
#'   `value`).
#' * **Colours.** A layer written with a colour table has it again:
#'   `terra::has.colors()` is `TRUE`, `terra::coltab()` gives the table,
#'   and `terra::plot()` draws with it.
#'
#' The legend and the colours come from the catalog, not from the file,
#' and nothing is written next to the file. A window and a subset of the
#' layers (`x[["name"]]`) keep both. There is no `columns` for rasters:
#' read the raster and take the layers from it.
#'
#' The location read from is, among the available locations that hold the
#' dataset at the primary's version, a local one first, then the primary,
#' then the other secondaries. Reading from a secondary prints a line
#' saying so (silenced by `options(rcs.quiet = TRUE)`). Reads use the
#' catalogs held by the connection; [store_refresh()] reads them again.
#'
#' @section Copy to secondary locations:
#' When the primary location is not local (a bucket) and a secondary is a
#' local folder, `store_read()` first copies the dataset there, so that
#' this read and the next ones come from the local copy. It copies only:
#'
#' * to secondaries that are available and local, while the primary is
#'   not local: with a local primary, or with secondaries in buckets
#'   only, a read copies nothing;
#' * the current version, to a secondary that lacks the dataset or its
#'   index table, or holds an older version of it. The dataset is copied
#'   from the primary with its index table, and only the files the
#'   secondary lacks are sent, each verified by its MD5;
#' * when the connection's `copy_on_read` is `TRUE` (the default of
#'   [store_connect()]) and `copy` is not `FALSE`;
#' * when the bytes to download, for the secondary that lacks the most,
#'   are at or under the limit `getOption("rcs.copy_on_read_max_bytes")`,
#'   2 GB (`2e9`) by default. Above it nothing is copied and a message
#'   says how to copy (`copy = TRUE`, or [store_sync()] with
#'   `datasets = `).
#'
#' Filters, `columns` and `intersects` do not change the rule: the whole
#' dataset is copied, then read from the copy. A secondary whose version
#' was written later than the primary's is never replaced by a read; a
#' message says so. A secondary that holds the primary's version under
#' another catalog entry (for example a raster written again with another
#' legend or other colours) gets the primary's entry, without any file
#' sent and whatever the limit. A copy that fails gives a warning, and the
#' read goes on from the primary; the next read tries again. Reading an
#' index table never copies; nor do [store_sample()], [store_glimpse()],
#' [store_open()] and [store_duckdb()].
#'
#' Earlier versions (`version = `) are not copied by default. When such a
#' read comes from the primary while an available local secondary could
#' hold a copy, a message says so (unless copying is turned off).
#' `copy = TRUE` adds the version to the history of each of these
#' secondaries, other than the one it is read from, that holds neither it
#' as its current version nor it in its history: its files, its manifest
#' unchanged, and its rows of the history. With no such secondary at all,
#' a message says there is none to copy to. The secondary's current version of the dataset does not
#' change, and a secondary that does not hold the dataset still does not
#' list it. One effect to know: [store_rebuild()] of a secondary that
#' holds only an earlier version of a dataset makes that version its
#' current one.
#'
#' To turn copying off, connect with `store_connect(copy_on_read = FALSE)`,
#' or pass `copy = FALSE` to one read: nothing is copied and no message
#' about copying is printed (a secondary that already holds the version is
#' still read from). Messages are silenced by `options(rcs.quiet = TRUE)`.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset Name of the dataset: the full name, or its last part when
#'   that is unique in the store.
#' @param ... Filter expressions, as in [dplyr::filter()].
#' @param columns Columns to return, as in [dplyr::select()] (tidyselect);
#'   `NULL` for all. The geometry column is controlled by `geometry`. A
#'   raster has no column selection.
#' @param intersects `NULL`, or a query: an `sf`, `sfc` or `bbox` object
#'   with a coordinate reference system, or H3 cells of any resolution as
#'   hex strings, `bit64::integer64` or `h3o` `H3` vectors. A plain number
#'   aborts: it cannot hold an H3 cell. An `sf` or `sfc` query with an
#'   invalid geometry (for example a ring that crosses itself) aborts, with
#'   the reason and advice to use [sf::st_make_valid()]; validity is read on
#'   the sphere or in the plane as in [store_intersects()]. For a raster,
#'   the query's bounding box is the window that is read (see "Rasters").
#' @param geometry `FALSE` drops the geometry before reading and returns a
#'   tibble.
#' @param version `NULL` for the current version, or the 16 hex characters of
#'   an earlier version kept in the history.
#' @param copy Whether to copy the dataset to the local secondary locations
#'   before reading (see "Copy to secondary locations"). `NULL` (the
#'   default) copies the current version when the connection's
#'   `copy_on_read` is `TRUE` and the bytes to download are at or under the
#'   limit. `TRUE` copies whatever the limit and the connection's setting,
#'   and copies an earlier version too, into the secondaries' history.
#'   `FALSE` never copies.
#' @param exact `TRUE` tests the candidate rows of a spatial filter exactly,
#'   on the sphere or in the plane as `exact_engine` says.
#' @param exact_engine How the exact test of a spatial filter reads the
#'   geometries: `NULL` (the default) follows the geocoding engine the
#'   dataset was written with (`"s2"`: on the sphere; `"planar"`: in the
#'   plane; `"auto"`: on the sphere for rows valid on the sphere, in the
#'   plane for the others), and the session's [sf::sf_use_s2()] setting for
#'   a dataset with no recorded engine (written before engines were
#'   recorded, or with `geocode = FALSE`). `"s2"`, `"planar"` or
#'   `"session"` override it. Data in a projected CRS are always tested
#'   in the plane of that CRS. See [store_intersects()].
#' @return A tibble; an `sf` object for geospatial data read with geometry;
#'   a `terra::SpatRaster` for a raster, with the categories and the
#'   colours recorded when it was written.
#' @seealso [store_open()] for lazy queries, [store_sample()],
#'   [store_glimpse()].
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-read")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_table(500), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_read(st, "sales/daily", year == 2023, product == "p07",
#'   columns = c(shop_id, date, qty)
#' )
#'
#' store_write(st, rcs_sim_polygons(200), "shapes/polygons",
#'   title = "Polygons", description = "Simulated polygons in open ocean."
#' )
#' area <- sf::st_as_sfc(sf::st_bbox(
#'   c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
#'   crs = sf::st_crs(4326)
#' ))
#' store_read(st, "polygons", intersects = area)
#' store_read(st, "polygons", geometry = FALSE)
#'
#' # A class map: whole, and a window of it
#' if (requireNamespace("terra", quietly = TRUE)) {
#'   cover <- terra::as.int(rcs_sim_raster(nrow = 60, ncol = 80)[["cover"]])
#'   cover[1:2, ] <- 0L
#'   levels(cover) <- data.frame(
#'     value = 1:5,
#'     label = c("water", "forest", "crop", "grass", "bare")
#'   )
#'   names(cover) <- "cover"
#'   terra::coltab(cover) <- data.frame(
#'     value = 1:5,
#'     col = c("#1F78B4", "#33A02C", "#FFD92F", "#B2DF8A", "#B15928")
#'   )
#'   store_write(st, cover, "grids/cover",
#'     title = "Land cover", description = "A simulated class map.",
#'     nodata = 0
#'   )
#'
#'   map <- store_read(st, "grids/cover")
#'   print(map)
#'   print(terra::levels(map)[[1]]) # the legend
#'   print(terra::has.colors(map))
#'   print(terra::coltab(map)[[1]]) # the colours
#'   print(map[1, 1]) # a cell holding the NoData value is missing
#'
#'   # Only the cells inside the box of `area`, with legend and colours
#'   window <- store_read(st, "grids/cover", intersects = area)
#'   print(dim(window))
#'   print(terra::freq(window))
#'   rm(map, window)
#' }
#' unlink(location, recursive = TRUE)
store_read <- function(st, dataset, ..., columns = NULL, intersects = NULL,
                       geometry = TRUE, version = NULL, copy = NULL, exact = TRUE,
                       exact_engine = NULL) {
  validate_store(st)
  local_trace("store_read")
  call <- rlang::current_env()
  check_flag(geometry)
  check_flag(exact)
  check_flag(copy, allow_null = TRUE)
  check_exact_engine(exact_engine, call = call)
  quos <- rlang::enquos(...)
  columns <- rlang::enquo(columns)
  # `missing()` works only here: the arguments a raster read refuses
  given <- c(
    if (length(quos) > 0) "...",
    if (!rlang::quo_is_null(columns)) "columns",
    if (!missing(geometry)) "geometry",
    if (!missing(exact)) "exact",
    if (!is.null(exact_engine)) "exact_engine"
  )

  # a read of the current version checks the raster arguments on the
  # primary's entry before anything is copied; an old version may be of
  # another kind, so it is checked on its own entry after `read_target()`
  name <- read_name(st, dataset, version, call)
  entry <- catalog_entry(st$primary$catalog, name)
  checked <- NULL
  if (is.null(version) || identical(version, entry$version)) {
    check_raster_read_args(entry, given, call)
    checked <- entry$kind
  }
  copy_before_read(st, name, version, copy, call)
  target <- read_target(st, dataset, version, call = call)
  if (!identical(target$entry$kind, checked)) {
    check_raster_read_args(target$entry, given, call)
  }
  inform_old_version(st, target, version, entry, copy)

  if (identical(target$entry$kind, "raster")) {
    return(raster_open(
      target$location$backend, target$files$path[[1]], intersects,
      columns = columns_from_json(target$entry$columns)
    ))
  }

  # the file pruning of the filters is done on the catalog before any file
  # is opened (`query_new()`); the filters themselves are applied after
  plan <- NULL
  if (!is.null(intersects)) {
    plan <- spatial_plan(c(list(store = st), target[c("entry", "location", "files")]),
      intersects, exact,
      call = call, exact_engine = exact_engine
    )
  }
  q <- query_new(st, target, quos = quos, plan = plan)
  q$geometry <- geometry
  if (length(quos) > 0) {
    q <- query_filter(q, quos)
  }
  if (!is.null(intersects)) {
    q <- query_intersects(q, intersects, exact,
      call = call, plan = plan,
      exact_engine = exact_engine
    )
  }
  keep_id <- FALSE
  if (!rlang::quo_is_null(columns)) {
    selected <- select_columns(q, columns, call)
    keep_id <- ".rcs_id" %in% selected
    if (geometry && identical(target$entry$kind, "geospatial") && "geometry" %in% names(q$query)) {
      selected <- union(selected, "geometry")
    }
    q$query <- dplyr::select(q$query, dplyr::all_of(selected))
  }
  query_collect(q, keep_id = keep_id)
}

# The line of a default read of an old version served by the primary while a
# secondary could hold a copy (plan 0005, D-B6). `entry` is the primary's
# current entry of the dataset.
inform_old_version <- function(st, target, version, entry, copy) {
  old <- !is.null(version) && !identical(version, entry$version)
  if (!old || !is.null(copy) || !isTRUE(st$copy_on_read) || is_index_entry(entry)) {
    return(invisible())
  }
  uri <- target$location$uri
  if (!identical(uri, st$primary$uri) || length(copy_targets(st)) == 0) {
    return(invisible())
  }
  name <- target$dataset
  rcs_inform(c(
    i = "Read version {version} of {.val {name}} from {.path {uri}}; old versions are not copied to secondary locations.",
    " " = "Use {.code copy = TRUE} to copy it."
  ))
}

# The full name of a dataset given to a read, after the check of `version`
# (the same checks, in the same order, as `read_target()`).
read_name <- function(st, dataset, version, call) {
  check_string(version, allow_null = TRUE, call = call)
  if (!is.null(version) && !grepl("^[0-9a-f]{16}$", version)) {
    cli::cli_abort(
      "{.arg version} must be 16 hex characters, not {.val {version}}.",
      class = "rcs_error_argument", call = call
    )
  }
  resolve_dataset(st, dataset, index = TRUE, call = call)
}

#' Abort when a raster read is given arguments that do not apply
#'
#' @param dataset The catalog entry (one row) of the version read: the
#'   primary's for the current version, the manifest's for an old one.
#' @param given Names of the arguments given that a raster read refuses
#'   (`"..."`, `"columns"`, `"geometry"`, `"exact"`, `"exact_engine"`),
#'   built by `store_read()`, where `missing()` works.
#' @param call Environment for the error.
#' @return `NULL`, invisibly; aborts with class `rcs_error_argument` when
#'   `dataset` is a raster and `given` is not empty.
#' @noRd
check_raster_read_args <- function(dataset, given, call) {
  if (!identical(dataset$kind, "raster") || length(given) == 0) {
    return(invisible())
  }
  cli::cli_abort(
    c(
      "{.val {dataset$dataset}} is a raster: {.arg {given}} do{?es/} not apply.",
      i = "A raster read takes only {.arg intersects}, which crops it to the query's box."
    ),
    class = "rcs_error_argument", call = call
  )
}

# Copy on read ------------------------------------------------------------------

#' Copy a dataset to the local secondaries before a read
#'
#' Called by `store_read()` just before `read_target()`. Copies the current
#' version of `name` (with its index table) from the primary to each
#' available local secondary of a primary that is not local, when the
#' secondary lacks it, holds an older version, or holds the primary's
#' version with another entry (plan 0005, D-B1 to D-B13). The decision uses
#' the catalogs held by `st`, so a read that needs no copy makes no backend
#' call. When a copy is needed, the primary and each target are refreshed
#' and the decision is taken again on the fresh catalogs before landing.
#' A refresh or a landing that fails with a write-class error warns (class
#' `rcs_warning_secondary_behind`) and the read goes on; other errors
#' propagate.
#'
#' @param st An `rcs_store`; updated in place.
#' @param name The dataset name given to the read.
#' @param version `NULL`, or the version asked for.
#' @param copy `NULL`, `TRUE` or `FALSE`, as in `store_read()`.
#' @param call Environment for errors.
#' @return Nothing (`NULL`, invisibly).
#' @noRd
copy_before_read <- function(st, name, version, copy, call) {
  name <- read_name(st, name, version, call)
  catalog <- st$primary$catalog
  if (isFALSE(copy) || is_index_entry(catalog_entry(catalog, name))) {
    return(invisible())
  }
  if (!is.null(version) && !identical(version, catalog_entry(catalog, name)$version)) {
    if (isTRUE(copy)) {
      copy_history_before_read(st, name, version, call)
    }
    return(invisible())
  }
  if (!isTRUE(copy) && !isTRUE(st$copy_on_read)) {
    return(invisible())
  }
  uris <- copy_targets(st)
  if (length(uris) == 0) {
    if (isTRUE(copy)) {
      rcs_inform(c(i = "No secondary location to copy to. Use {.code store_sync(st, datasets = \"{name}\")}."))
    }
    return(invisible())
  }
  plan <- copy_plan(st, name, uris, copy)
  if (!copy_planned(plan)) {
    copy_plan_inform(st, name, plan)
    return(invisible())
  }

  # a copy is needed: refresh the primary and the targets, then decide again
  fresh <- tryCatch(location_refresh(st, st$primary), error = function(e) e)
  if (inherits(fresh, "error")) {
    copy_failed(fresh, name, NULL)
    return(invisible())
  }
  if (!is.null(version) && !identical(version, catalog_entry(fresh$catalog, name)$version)) {
    return(invisible())
  }
  refreshed <- character()
  for (uri in c(plan$copy, plan$entry_only)) {
    fresh <- tryCatch(location_refresh(st, uri), error = function(e) e)
    if (inherits(fresh, "error")) {
      copy_failed(fresh, name, uri)
    } else {
      refreshed <- c(refreshed, uri)
    }
  }
  plan <- copy_plan(st, name, uris, copy, only = refreshed)
  copy_plan_inform(st, name, plan)
  if (!copy_planned(plan)) {
    return(invisible())
  }

  targets <- uris[uris %in% c(plan$copy, plan$entry_only)]
  version <- plan$unit$sets[[1]]$entry$version
  from <- st$primary$uri
  for (uri in targets) {
    if (uri %in% plan$entry_only) {
      rcs_inform(c(i = "Updating the catalog entry of {.val {name}} in {.path {uri}} to the primary's (version {version}, no file sent)."))
    } else {
      n <- plan$lacking[[uri]]$files
      size <- format_bytes(plan$lacking[[uri]]$bytes)
      rcs_inform(c(i = "Copying {.val {name}} (version {version}, {n} file{?s}, {size}) from {.path {from}} to {.path {uri}} before reading."))
    }
  }
  dir <- sync_staging_dir("rcs-copy")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  landed <- copy_unit(st, st$primary, targets, name, write_context(st, dir))
  for (uri in targets) {
    result <- landed[[uri]]
    if (inherits(result, "error")) {
      copy_failed(result, name, uri)
    } else if (uri %in% plan$copy && identical(result$status, "written")) {
      sent <- result$uploaded
      total <- result$total
      size <- if (result$bytes > 0) paste0(" (", format_bytes(result$bytes), ")") else ""
      secs <- format_seconds(result$seconds)
      rcs_inform(c(v = "{sent}/{total} file{?s} sent to {.path {uri}}{size} in {secs}, MD5 verified."))
    }
  }
  invisible()
}

#' Copy an old version to the history of the local secondaries
#'
#' `store_read(version = <old>, copy = TRUE)` (plan 0005, D-B6). The source
#' is the location `choose_location()` reads the version from, found with
#' its "reading from secondary" line silenced: `read_target()` prints it
#' once afterwards. Every other eligible secondary (`copy_targets()`) is
#' refreshed and, unless its current entry is that version, receives the
#' version through `land_history()`, which skips a secondary whose history
#' already has it. The refresh and the landing of each target are one caught
#' region: a write-class error warns (`copy_failed()`) and the read goes on.
#'
#' @param st An `rcs_store`; updated in place.
#' @param name Full name of the dataset (not an index table).
#' @param version The old version.
#' @param call Environment for errors.
#' @return Nothing (`NULL`, invisibly).
#' @noRd
copy_history_before_read <- function(st, name, version, call) {
  uris <- copy_targets(st)
  if (length(uris) == 0) {
    rcs_inform(c(i = "No secondary location to copy to."))
    return(invisible())
  }
  source <- withr::with_options(
    list(rcs.quiet = TRUE),
    choose_location(st, name, version, call = call)
  )
  uris <- setdiff(uris, source$uri)
  if (length(uris) == 0) {
    return(invisible())
  }
  dir <- sync_staging_dir("rcs-copy")
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  ctx <- write_context(st, dir)
  ctx$primary <- source$backend
  for (uri in uris) {
    landed <- tryCatch(
      {
        target <- location_refresh(st, uri)
        if (identical(catalog_entry(target$catalog, name)$version, version)) {
          NULL
        } else {
          land_history(st, source, target, name, version, ctx)
        }
      },
      error = function(e) e
    )
    if (inherits(landed, "error")) {
      copy_failed(landed, name, uri)
    } else if (identical(landed$status, "written")) {
      sent <- landed$uploaded
      total <- landed$total
      size <- if (landed$bytes > 0) paste0(" (", format_bytes(landed$bytes), ")") else ""
      secs <- format_seconds(landed$seconds)
      rcs_inform(c(v = "{sent}/{total} file{?s} sent to the history of {.path {uri}}{size} in {secs}, MD5 verified."))
    }
  }
  invisible()
}

# Addresses of the secondaries a read may copy to: available and local,
# while the primary is not local (the backend test of `choose_location()`).
copy_targets <- function(st) {
  if (identical(st$primary$backend$type, "local")) {
    return(character())
  }
  keep <- Filter(function(l) l$available && identical(l$backend$type, "local"), st$secondary)
  vapply(keep, function(l) l$uri, character(1))
}

#' What a copy on read would do, from the catalogs held by the connection
#'
#' @param st An `rcs_store`.
#' @param name Full name of the dataset (not an index table).
#' @param uris Addresses of the eligible secondaries (`copy_targets()`).
#' @param copy As in `store_read()`.
#' @param only `NULL`, or the addresses that may be landed: a secondary that
#'   needs the copy but is not among them is left out.
#' @return A list: `unit` (`sync_unit()` of the primary), `copy` (addresses
#'   that need files or a version), `entry_only` (addresses that hold the
#'   primary's version and its files under another entry, D-B13), `newer`
#'   (addresses holding another version updated later than the primary's),
#'   `lacking` (`files_lacking()` per address of `copy` and `entry_only`),
#'   `bytes` (the most bytes any of them lacks), `limit`, and `over` (the
#'   bytes exceed the limit and `copy` is not `TRUE`).
#' @noRd
copy_plan <- function(st, name, uris, copy, only = NULL) {
  unit <- sync_unit(st, st$primary, name)
  entry <- unit$sets[[1]]$entry
  plan <- list(
    unit = unit, copy = character(), entry_only = character(), newer = character(),
    lacking = list(), bytes = 0
  )
  for (uri in uris) {
    target <- current_location(st, uri)
    if (!unit_needed(target, unit)) next
    held <- catalog_entry(target$catalog, name)
    same_version <- nrow(held) == 1 && identical(held$version, entry$version)
    if (nrow(held) == 1 && isTRUE(held$updated > entry$updated)) {
      # never replaced by a read: another version is named, the same
      # version with a later entry is left silently (D-B1, D-B13)
      if (!same_version) plan$newer <- c(plan$newer, uri)
      next
    }
    if (!is.null(only) && !uri %in% only) next
    lacking <- files_lacking(list(unit), target)
    plan$lacking[[uri]] <- lacking
    if (same_version && lacking$files == 0) {
      plan$entry_only <- c(plan$entry_only, uri)
    } else {
      plan$copy <- c(plan$copy, uri)
    }
    plan$bytes <- max(plan$bytes, as.numeric(lacking$bytes))
  }
  plan$limit <- as.numeric(rcs_option("rcs.copy_on_read_max_bytes"))
  plan$over <- plan$bytes > plan$limit && !isTRUE(copy)
  plan
}

copy_planned <- function(plan) {
  length(plan$copy) + length(plan$entry_only) > 0 && !plan$over
}

# The lines of a plan about what is not copied: a newer secondary left as
# it is, and a copy above the limit.
copy_plan_inform <- function(st, name, plan) {
  for (uri in plan$newer) {
    rcs_inform(c("!" = "{.path {uri}} holds a newer version of {.val {name}}; it is not replaced. See {.fn store_sync}."))
  }
  if (plan$over) {
    need <- format_bytes(plan$bytes)
    limit <- format_bytes(plan$limit)
    from <- st$primary$uri
    rcs_inform(c(
      i = "{.val {name}} needs {need}, above the {limit} limit for copying on read ({.code rcs.copy_on_read_max_bytes}). Reading from {.path {from}}.",
      " " = "Use {.code copy = TRUE}, or {.code store_sync(st, datasets = \"{name}\")}, to copy it."
    ))
  }
  invisible()
}

# A failed copy on read: a write-class error warns and the read goes on;
# any other error propagates. `uri` is `NULL` when the primary failed.
copy_failed <- function(error, name, uri) {
  if (!inherits(error, write_error_classes)) {
    rlang::cnd_signal(error)
  }
  text <- if (is.null(uri)) {
    "Cannot read the catalogs of the primary location; {.val {name}} is not copied to the secondary locations."
  } else {
    "Copying {.val {name}} to {.path {uri}} before reading failed; the read goes on without that copy."
  }
  cli::cli_warn(
    c(
      text,
      i = "The next read tries again. Run {.code store_sync(st, datasets = \"{name}\")} to copy it now, or connect with {.code copy_on_read = FALSE} to stop copying."
    ),
    class = "rcs_warning_secondary_behind", parent = error
  )
}

# Names of the columns chosen by a tidyselect expression among the columns
# of the query.
select_columns <- function(q, columns, call) {
  available <- names(q$query)
  template <- stats::setNames(as.list(seq_along(available)), available)
  names(tidyselect::eval_select(columns, data = template, error_call = call))
}

# store_sample() --------------------------------------------------------------

#' Sample rows of a dataset
#'
#' Reads a random sample of about `n` rows without reading the whole
#' dataset. Row groups (blocks of rows inside the files) are picked at
#' random across files, with probability proportional to their rows, and
#' only those are read; the filters are applied, and `n` rows are drawn from
#' the rows found. When the filters leave fewer than `n` rows, further row
#' groups are read until `n` rows are found or the dataset is exhausted.
#'
#' This is a cluster sample, not a simple random sample: rows are stored
#' sorted (by key, or spatially by H3 cell), so the rows of one row group
#' are alike, and the sample covers only as many clusters as row groups
#' were read. Use it to look at data, not to estimate.
#'
#' Unlike [store_read()], it never copies the dataset to a secondary
#' location.
#'
#' @inheritParams store_read
#' @param n Number of rows wanted.
#' @param seed `NULL`, or a number that makes the sample reproducible. The
#'   global random stream is left as it was ([withr::with_seed()]).
#' @return A tibble, or an `sf` object for geospatial data read with
#'   geometry, with at most `n` rows.
#' @seealso [store_read()].
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-sample")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_table(2000), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_sample(st, "sales/daily", n = 5, qty > 10, seed = 42)
#' unlink(location, recursive = TRUE)
store_sample <- function(st, dataset, n = 1000, ..., columns = NULL, seed = NULL,
                         geometry = TRUE, version = NULL) {
  validate_store(st)
  local_trace("store_sample")
  call <- rlang::current_env()
  n <- check_count(n, call = call)
  check_flag(geometry)
  if (!is.null(seed) && !rlang::is_scalar_integerish(seed, finite = TRUE)) {
    cli::cli_abort("{.arg seed} must be {.code NULL} or one whole number.",
      class = "rcs_error_argument", call = call
    )
  }
  quos <- rlang::enquos(...)
  columns <- rlang::enquo(columns)
  target <- read_target(st, dataset, version, call = call)
  if (identical(target$entry$kind, "raster")) {
    abort_raster_verb("store_sample", call = call)
  }
  q <- query_prune_partitions(query_new(st, target, quos = quos), quos)
  selected <- names(q$query)
  keep_id <- FALSE
  if (!rlang::quo_is_null(columns)) {
    selected <- select_columns(q, columns, call)
    keep_id <- ".rcs_id" %in% selected
    if (geometry && "geometry" %in% names(q$query)) {
      selected <- union(selected, "geometry")
    }
  }
  selected <- setdiff(selected, c(if (!keep_id) ".rcs_id", if (!geometry) "geometry"))

  run <- function() sample_rows(q, n, quos, selected)
  data <- if (is.null(seed)) run() else withr::with_seed(seed, run())
  data <- rows_finish(data, q$entry)
  if (nrow(data) < n) {
    rcs_inform(c(i = "Only {nrow(data)} row{?s} match; all are returned."))
  }
  trace_count("rows_returned", nrow(data), location = q$location$uri)
  data
}

# Read row groups in random order (weighted by rows, without replacement)
# until `n` rows pass the filters, then draw `n` of them. Returns a data
# frame collected from Arrow.
sample_rows <- function(q, n, quos, selected) {
  withr::local_options(arrow.int64_downcast = FALSE)
  be <- q$location$backend
  groups <- files_row_groups(be, q$files$path)
  groups <- groups[groups$rows > 0, ]
  key <- stats::runif(nrow(groups))^(1 / groups$rows)
  groups <- groups[order(-key), ]
  tables <- list()
  found <- 0
  for (i in seq_len(nrow(groups))) {
    table <- files_read_row_groups(be, groups$path[[i]], groups$row_group[[i]])
    if (length(quos) > 0) {
      table <- dplyr::compute(dplyr::filter(table, !!!quos))
    }
    if (table$num_rows > 0) {
      tables[[length(tables) + 1L]] <- table
      found <- found + table$num_rows
    }
    if (found >= n) {
      break
    }
  }
  if (length(tables) == 0) {
    source <- query_source(q$query)
    empty <- arrow::Table$create(schema = source$schema)
    return(dplyr::collect(dplyr::select(empty, dplyr::all_of(selected))))
  }
  data <- dplyr::collect(dplyr::select(
    arrow::concat_tables(!!!tables),
    dplyr::all_of(selected)
  ))
  if (nrow(data) > n) {
    data <- data[sort(sample.int(nrow(data), n)), , drop = FALSE]
  }
  data
}

# store_glimpse() -------------------------------------------------------------

#' A first look at a dataset
#'
#' Prints what the catalog says about a dataset (kind, rows, files, version,
#' key, partition, coordinate reference system) and the first rows of its
#' first file, read from one row group. Opens one file. For a raster, the
#' `terra::SpatRaster` is printed instead, with its categories and colours
#' as [store_read()] returns them.
#'
#' Unlike [store_read()], it never copies the dataset to a secondary
#' location.
#'
#' @inheritParams store_read
#' @return The rows shown (a tibble, or an `sf` object for geospatial data),
#'   invisibly; for a raster, the `terra::SpatRaster`, invisibly.
#' @seealso [store_read()], `store_describe()`.
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-glimpse")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_table(500), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_glimpse(st, "daily")
#' unlink(location, recursive = TRUE)
store_glimpse <- function(st, dataset) {
  validate_store(st)
  local_trace("store_glimpse")
  call <- rlang::current_env()
  target <- read_target(st, dataset, call = call)
  entry <- target$entry
  none <- "none"
  text <- function(v) if (length(v) == 0 || all(is.na(v))) none else paste(v, collapse = ", ")
  facts <- c(
    paste0("Dataset:   ", target$dataset, " (", entry$kind, ")"),
    paste0("Rows:      ", format_count(entry$rows)),
    paste0("Files:     ", format_count(entry$n_files)),
    paste0("Version:   ", entry$version),
    paste0("Key:       ", text(entry$key[[1]])),
    paste0("Partition: ", text(entry$partition[[1]]))
  )
  if (entry$kind %in% c("geospatial", "raster")) {
    facts <- c(facts, paste0("CRS:       ", text(crs_text(entry$crs))))
  }
  cli::cat_line(facts)
  if (identical(entry$kind, "raster")) {
    r <- raster_open(
      target$location$backend, target$files$path[[1]],
      columns = columns_from_json(entry$columns)
    )
    cli::cat_line()
    print(r)
    return(invisible(r))
  }
  data <- glimpse_first_rows(target)
  data <- rows_finish(data, entry)
  shown <- data
  if (inherits(shown, "sf")) {
    shown <- tibble::as_tibble(shown)
  }
  cli::cat_line()
  dplyr::glimpse(shown)
  invisible(data)
}

# The first row group of the first file (one file opened), without `.rcs_id`.
glimpse_first_rows <- function(target) {
  location <- target$location
  be <- location$backend
  fs <- be_arrow_fs(be)
  withr::local_options(arrow.int64_downcast = FALSE)
  table <- with_parquet_reader(fs, target$files$path[[1]], be, function(reader) {
    if (reader$num_row_groups > 0) {
      trace_count("row_groups_total", reader$num_row_groups, location = location$uri)
      reader$ReadRowGroup(0L)
    } else {
      reader$ReadTable()
    }
  })
  data <- dplyr::collect(table)
  data[setdiff(names(data), ".rcs_id")]
}

# store_h3_hex() --------------------------------------------------------------

#' H3 cells as hex strings
#'
#' Cells are stored as 64-bit integers (`bit64::integer64`), the compact form
#' that Parquet filters and sorts fast, and a read returns them as [rcs_h3]
#' (`integer64` printed as hex). `store_h3_hex()` converts them to the
#' 15-character hex strings that other H3 tools use.
#'
#' @param x A data frame returned by a read (a tibble or an `sf` object), or
#'   a vector of cells ([rcs_h3], `bit64::integer64`, hex strings or `h3o`
#'   `H3`).
#' @param columns For a data frame, the columns to convert (tidyselect);
#'   `NULL` converts the cell columns the package adds that are present:
#'   `h3`, `h3_main` and `h3_p<r>`.
#' @return For a data frame, `x` with those columns as character; for a
#'   vector, a character vector of the same length. `NA` stays `NA`. A plain
#'   number aborts: it cannot hold an H3 cell.
#' @export
#' @examples
#' cells <- bit64::as.integer64("599686042433355775")
#' store_h3_hex(cells)
#'
#' x <- data.frame(id = 1, h3 = cells)
#' store_h3_hex(x)
store_h3_hex <- function(x, columns = NULL) {
  local_trace("store_h3_hex")
  call <- rlang::current_env()
  if (!is.data.frame(x)) {
    return(h3_as_hex(x, arg = "x", call = call))
  }
  columns <- rlang::enquo(columns)
  names_x <- names(x)
  if (rlang::quo_is_null(columns)) {
    chosen <- h3_cell_names(names_x)
  } else {
    plain <- if (inherits(x, "sf")) sf::st_drop_geometry(x) else x
    chosen <- names(tidyselect::eval_select(columns, data = plain, error_call = call))
  }
  for (name in chosen) {
    x[[name]] <- h3_as_hex(x[[name]], arg = name, call = call)
  }
  x
}
