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
#'   bounding box. Filters, `columns`, `geometry` and `exact` do not apply
#'   to rasters and abort.
#'
#' The location read from is, among the available locations that hold the
#' dataset at the primary's version, a local one first, then the primary,
#' then the other secondaries. Reading from a secondary prints a line
#' saying so (silenced by `options(rcs.quiet = TRUE)`). Reads use the
#' catalogs held by the connection; [store_refresh()] reads them again.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset Name of the dataset: the full name, or its last part when
#'   that is unique in the store.
#' @param ... Filter expressions, as in [dplyr::filter()].
#' @param columns Columns to return, as in [dplyr::select()] (tidyselect);
#'   `NULL` for all. The geometry column is controlled by `geometry`.
#' @param intersects `NULL`, or a query: an `sf`, `sfc` or `bbox` object
#'   with a coordinate reference system, or H3 cells of any resolution as
#'   hex strings, `bit64::integer64` or `h3o` `H3` vectors. A plain number
#'   aborts: it cannot hold an H3 cell. An `sf` or `sfc` query with an
#'   invalid geometry (for example a ring that crosses itself) aborts, with
#'   the reason and advice to use [sf::st_make_valid()]; validity is read on
#'   the sphere or in the plane as in [store_intersects()].
#' @param geometry `FALSE` drops the geometry before reading and returns a
#'   tibble.
#' @param version `NULL` for the current version, or the 16 hex characters of
#'   an earlier version kept in the history.
#' @param exact `TRUE` tests the candidate rows of a spatial filter exactly
#'   with [sf::st_intersects()], under the session's [sf::sf_use_s2()]
#'   setting.
#' @return A tibble; an `sf` object for geospatial data read with geometry;
#'   a `terra::SpatRaster` for a raster.
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
#' unlink(location, recursive = TRUE)
store_read <- function(st, dataset, ..., columns = NULL, intersects = NULL,
                       geometry = TRUE, version = NULL, exact = TRUE) {
  validate_store(st)
  local_trace("store_read")
  call <- rlang::current_env()
  check_flag(geometry)
  check_flag(exact)
  quos <- rlang::enquos(...)
  columns <- rlang::enquo(columns)
  target <- read_target(st, dataset, version, call = call)

  if (identical(target$entry$kind, "raster")) {
    given <- c(
      if (length(quos) > 0) "...",
      if (!rlang::quo_is_null(columns)) "columns",
      if (!missing(geometry)) "geometry",
      if (!missing(exact)) "exact"
    )
    if (length(given) > 0) {
      cli::cli_abort(
        c(
          "{.val {target$dataset}} is a raster: {.arg {given}} do{?es/} not apply.",
          i = "A raster read takes only {.arg intersects}, which crops it to the query's box."
        ),
        class = "rcs_error_argument", call = call
      )
    }
    return(raster_open(target$location$backend, target$files$path[[1]], intersects))
  }

  # the file pruning of the filters is done on the catalog before any file
  # is opened (`query_new()`); the filters themselves are applied after
  plan <- NULL
  if (!is.null(intersects)) {
    plan <- spatial_plan(c(list(store = st), target[c("entry", "location", "files")]),
      intersects, exact,
      call = call
    )
  }
  q <- query_new(st, target, quos = quos, plan = plan)
  q$geometry <- geometry
  if (length(quos) > 0) {
    q <- query_filter(q, quos)
  }
  if (!is.null(intersects)) {
    q <- query_intersects(q, intersects, exact, call = call, plan = plan)
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
#' first file, read from one row group. Opens one file.
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
    r <- raster_open(target$location$backend, target$files$path[[1]])
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
#' that Parquet filters and sorts fast. `store_h3_hex()` converts them to the
#' 15-character hex strings that other H3 tools use.
#'
#' @param x A data frame returned by a read (a tibble or an `sf` object), or
#'   a vector of cells (`bit64::integer64`, hex strings or `h3o` `H3`).
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
    chosen <- names_x[names_x %in% c("h3", "h3_main") | grepl("^h3_p[0-9]+$", names_x)]
  } else {
    plain <- if (inherits(x, "sf")) sf::st_drop_geometry(x) else x
    chosen <- names(tidyselect::eval_select(columns, data = plain, error_call = call))
  }
  for (name in chosen) {
    x[[name]] <- h3_as_hex(x[[name]], arg = name, call = call)
  }
  x
}
