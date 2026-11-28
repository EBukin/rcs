# Lazy queries: `store_open()`, the `rcs_query` methods of the dplyr verbs,
# partition pruning, and the conversion of collected rows to R types.
#
# Shape of `q$query` (see `new_query()`): the user's dplyr verbs applied by
# Arrow on top of one "bottom" `arrow_dplyr_query` whose `.data` is the
# source: a `FileSystemDataset` opened from the explicit file list of
# `q$files`, or an `InMemoryDataset` (no file left after pruning, or after
# `compute()`). The bottom query's `filtered_rows` is an Arrow expression in
# terms of the source's columns. Two things are done to the bottom query
# only, and only through `query_bottom_edit()`:
#
#   * the source is replaced by one opened from fewer files (partition and
#     spatial pruning), so that only those files are opened;
#   * the spatial filter's candidate predicate is added to its rows filter,
#     so that it applies to the rows of the dataset, before the other verbs.
#
# `q$files` always lists exactly the files of the source.

# Opening ---------------------------------------------------------------------

#' Open a dataset as a lazy query
#'
#' The usual way to work with a dataset: open it, describe the rows you want
#' with dplyr verbs, and read them into R with `collect()`. Opening reads no
#' data; the query is built from the files the dataset's catalog names (the
#' folder is never listed). The query is transformed with the dplyr verbs
#' `filter()`, `select()`, `mutate()`, `rename()`, `arrange()`, `distinct()`,
#' `head()`, and run with `collect()` (an R data frame), `compute()` (rows
#' kept in memory as Arrow data), `pull()` or `glimpse()`. Arrow pushes
#' filters and column selection into the scan, so only the needed files, row
#' groups and columns are read. [store_read()] is the shortcut for
#' `store_open()`, `filter()`, `select()` and `collect()` in one call.
#'
#' * A filter whose columns are all partition columns is first evaluated on
#'   the partition values recorded in the catalog: only the files of the
#'   matching partitions are opened.
#' * [store_intersects()] adds a spatial filter.
#' * `collect()` returns a tibble, or an `sf` object for a geospatial
#'   dataset whose geometry is read, with the catalog's coordinate reference
#'   system. It restores the R types Arrow does not restore by itself
#'   (difftime units, `bit64::integer64`, factor levels, plain list columns)
#'   and drops the row identifier `.rcs_id` that the package adds to
#'   geospatial data; the columns `h3`, `bbox` and `h3_p<r>` are returned,
#'   the cells as [rcs_h3] vectors.
#'
#' The query reads from the location chosen as for [store_read()], with the
#' catalogs held by the connection. Unlike [store_read()], it never copies
#' the dataset to a secondary location.
#'
#' @section Printing:
#' Printing a query reads its first rows, and only those: `head(n + 1)` of
#' the query, the exact test of a spatial filter included, so that it can
#' tell whether more rows exist without counting them. It opens the data
#' files it needs. The first `n` rows are shown as a tibble under a header:
#'
#' * `Dataset:` the full name, the number of rows and columns, and the kind.
#'   The number of rows comes from the catalog when the query is the dataset
#'   itself, with columns selected, renamed or computed; after a filter, a
#'   spatial filter or any other verb it is shown as `??`. The number of
#'   columns is that of the data frame `collect()` returns.
#' * `Location:` the location read (`primary` or `secondary <n>`, local or
#'   GCS).
#' * `Version:` the first 8 characters of the version, current or earlier.
#' * `Files:` the files kept of the dataset's files, `(pruned)` when a
#'   filter on partition columns or a spatial filter dropped some.
#' * `Spatial:` the spatial filter, when set.
#' * `Filter:` the row filter, or `(with spatial predicate)` when a spatial
#'   filter is set.
#'
#' The footer says how many rows are not shown (`more rows` when the total is
#' not known, `more rows may exist` while an exact spatial test is pending)
#' and reminds that `collect()` reads the rows into R. A table opened with
#' `engine = "duckdb"` prints as any dbplyr table.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset Name of the dataset: the full name, or its last part when
#'   that is unique in the store.
#' @param version `NULL` for the current version, or the 16 hex characters of
#'   an earlier version kept in the history (see `store_history()`).
#'   Only `NULL` with `engine = "duckdb"`.
#' @param engine `"arrow"` (the default) for a lazy Arrow query of class
#'   `rcs_query`; `"duckdb"` for a dbplyr table on the dataset's DuckDB view
#'   (see [store_duckdb()] and `vignette("duckdb")`), of class
#'   `rcs_duckdb_tbl`. Every dbplyr verb works on it; its `collect()`
#'   restores the R types (factor levels, difftime units,
#'   `bit64::integer64`, [rcs_h3] cells) and the geometry as for the Arrow
#'   engine, and drops `.rcs_id`. It needs the packages duckdb, DBI and
#'   dbplyr.
#' @param con With `engine = "duckdb"`: `NULL` for an in-memory connection
#'   that the package keeps, one per store, until the end of the session; or
#'   a DuckDB connection made with `bigint = "integer64"`, on which the view
#'   is created (or refreshed) as by `store_duckdb(st, con = con)`.
#' @param mode,spatial With `engine = "duckdb"`: as in [store_duckdb()].
#' @param x A query made by `store_open()` with `engine = "arrow"`.
#' @param ... Passed to the tibble print method (for example `width`).
#' @param n Number of rows to print; `NULL` uses the option `rcs.print_rows`
#'   (10).
#' @return `store_open()`: a lazy query of class `rcs_query`, or with
#'   `engine = "duckdb"` a lazy dbplyr table of class `rcs_duckdb_tbl`.
#'   `print()`: `x`, invisibly.
#' @seealso [store_read()], [store_intersects()], [rcs_query-dplyr],
#'   [store_duckdb()].
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-open")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_table(500), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' q <- store_open(st, "daily")
#' q
#' print(q, n = 3)
#' q |>
#'   dplyr::filter(year == 2024, qty > 40) |>
#'   dplyr::select(shop_id, date, qty) |>
#'   dplyr::collect()
#' unlink(location, recursive = TRUE)
store_open <- function(st, dataset, version = NULL, engine = c("arrow", "duckdb"),
                       con = NULL, mode = "native", spatial = FALSE) {
  validate_store(st)
  local_trace("store_open")
  call <- rlang::current_env()
  engine <- rlang::arg_match(engine, error_call = call)
  if (engine == "duckdb") {
    mode <- rlang::arg_match(mode, c("native", "arrow"), error_call = call)
    check_flag(spatial, call = call)
    if (!is.null(version)) {
      cli::cli_abort(
        c(
          "{.arg version} must be {.code NULL} with {.code engine = \"duckdb\"}.",
          i = "DuckDB views show the current versions; read an earlier version with {.code engine = \"arrow\"}."
        ),
        class = "rcs_error_argument", call = call
      )
    }
  }
  target <- read_target(st, dataset, version, call = call)
  if (identical(target$entry$kind, "raster")) {
    abort_raster_verb("store_open", call = call)
  }
  if (engine == "duckdb") {
    return(duckdb_tbl_open(st, target$dataset, con, mode, spatial, call = call))
  }
  query_new(st, target)
}

abort_raster_verb <- function(fn, call = caller_env()) {
  cli::cli_abort(
    c(
      "{.fn {fn}} does not apply to rasters.",
      i = "Read a raster with {.fn store_read}, which returns a {.cls SpatRaster}."
    ),
    class = "rcs_error_argument", call = call
  )
}

#' The `rcs_query` of a read target
#'
#' Opening an Arrow dataset costs a request per file on a cloud backend, so
#' a read whose filters are known before the query is built prunes the file
#' list on the catalog first and opens only the files kept: partition
#' filters (`quos`, evaluated on the partition values as in
#' `query_prune_partitions()`) and the file pruning of a spatial filter
#' (`plan`, from `spatial_plan()`). The filters are applied again by the
#' caller, so this only saves work. With one file nothing is pruned here.
#'
#' @param st An `rcs_store`.
#' @param target A read target (`read_target()`).
#' @param quos Filter expressions (quosures) that will be applied.
#' @param plan `NULL`, or the spatial plan that will be applied.
#' @return An `rcs_query` whose `files` are the files kept.
#' @noRd
query_new <- function(st, target, quos = list(), plan = NULL) {
  files <- target$files
  location <- target$location
  schema <- NULL
  if (nrow(files) > 1 && (length(quos) > 0 || !is.null(plan))) {
    keep <- rep(TRUE, nrow(files))
    if (!is.null(plan)) {
      keep <- files$path %in% plan$paths
    }
    partition <- target$entry$partition[[1]]
    if (length(quos) > 0 && length(partition) > 0) {
      schema <- query_open_files(location, files$path[[1]])$schema
      use <- partition_quos(quos, names(schema), partition)
      if (length(use) > 0) {
        kept <- tryCatch(partition_keep(files, partition, schema, use), error = function(e) NULL)
        if (!is.null(kept)) keep <- keep & kept
      }
    }
    if (!any(keep) && is.null(schema)) {
      schema <- query_open_files(location, files$path[[1]])$schema
    }
    files <- files[keep, ]
  }
  source <- query_open_files(location, files$path, schema = schema)
  new_query(
    store = st,
    entry = target$entry,
    location = location,
    files = files,
    query = dplyr::select(source, dplyr::everything())
  )
}

# Of the filter expressions `quos`, those whose column symbols (among
# `columns`) are all partition columns.
partition_quos <- function(quos, columns, partition) {
  Filter(function(quo) {
    refs <- intersect(all.vars(rlang::quo_get_expr(quo)), columns)
    length(refs) > 0 && all(refs %in% partition)
  }, quos)
}

#' An Arrow dataset from an explicit file list
#'
#' @param location The `rcs_location` the files are read from.
#' @param paths Relative paths of Parquet files (at least one, unless
#'   `schema` is given).
#' @param schema `NULL`, or the Arrow schema of the files; given, the files
#'   are not inspected when the dataset is built, and zero paths give an
#'   empty in-memory dataset with that schema.
#' @return An Arrow `Dataset`. Aborts with class
#'   `rcs_error_version_not_found` when files of the list no longer exist
#'   (the version was replaced since the connection read the catalogs, and
#'   history is off), and with `rcs_error_backend` and the authentication
#'   hint when the files cannot be opened otherwise.
#' @noRd
query_open_files <- function(location, paths, schema = NULL) {
  if (length(paths) == 0) {
    return(arrow::InMemoryDataset$create(arrow::Table$create(schema = schema)))
  }
  fs <- be_arrow_fs(location$backend)
  full <- paste0(fs$path, "/", paths)
  tryCatch(
    if (is.null(schema)) {
      arrow::open_dataset(full, filesystem = fs$fs, format = "parquet")
    } else {
      arrow::open_dataset(full, schema = schema, filesystem = fs$fs, format = "parquet")
    },
    error = function(e) {
      abort_open_files(location, paths, e)
    }
  )
}

# The error of a file list that cannot be opened: files that no longer
# exist mean a stale connection, anything else access.
abort_open_files <- function(location, paths, error) {
  uri <- location$uri
  exists <- tryCatch(be_exists(location$backend, paths), error = function(e) NULL)
  if (!is.null(exists) && !all(exists)) {
    n <- sum(!exists)
    cli::cli_abort(
      c(
        "{n} data file{?s} of the version this connection knows {?is/are} gone from {.path {uri}}.",
        i = "The dataset was changed since the connection read the catalogs, and no history keeps the old files.",
        i = "Run {.fn store_refresh} and read again."
      ),
      class = "rcs_error_version_not_found", parent = error, call = NULL
    )
  }
  cli::cli_abort(
    c("Cannot open the data files in {.path {uri}}.", be_auth_hint_safe(location$backend)),
    class = "rcs_error_backend", parent = error, call = NULL
  )
}

# Shape of the Arrow query ----------------------------------------------------

# The source at the bottom of an Arrow query.
query_source <- function(query) {
  while (inherits(query, "arrow_dplyr_query")) {
    query <- query$.data
  }
  query
}

# Apply `fn` to the bottom `arrow_dplyr_query` (the one whose `.data` is the
# source) and put the result back in place.
query_bottom_edit <- function(query, fn) {
  if (inherits(query$.data, "arrow_dplyr_query")) {
    query$.data <- query_bottom_edit(query$.data, fn)
    return(query)
  }
  fn(query)
}

# Replace the source of `q` by the files of `files` (a subset of `q$files`).
query_set_files <- function(q, files) {
  source <- query_source(q$query)
  if (!inherits(source, "FileSystemDataset") || identical(files$path, q$files$path)) {
    return(q)
  }
  new_source <- query_open_files(q$location, files$path, schema = source$schema)
  q$query <- query_bottom_edit(q$query, function(bottom) {
    bottom$.data <- new_source
    bottom
  })
  q$files <- files
  q
}

# Add a rows filter, an Arrow expression on the source's columns, to the
# bottom query: it applies to the rows of the dataset, before the other
# verbs.
query_bottom_filter <- function(q, predicate) {
  q$query <- query_bottom_edit(q$query, function(bottom) {
    bottom$filtered_rows <- if (isTRUE(bottom$filtered_rows)) {
      predicate
    } else {
      bottom$filtered_rows & predicate
    }
    bottom
  })
  q
}

# Partition pruning -----------------------------------------------------------

#' Partition pruning
#'
#' Of the filter expressions `quos`, those whose column symbols are all
#' partition columns are evaluated by Arrow on a small table of the
#' partition values recorded in `q$files$partition_values` (cast to the
#' types of the data), and the source is replaced by the files whose values
#' pass. The expressions are still applied to the rows afterwards, so the
#' pruning only saves work: whenever it cannot be done safely (the query is
#' no longer a single filter-and-select step over the source, a partition
#' column was renamed or recomputed, a value cannot be cast), no file is
#' dropped.
#'
#' @param q An `rcs_query`.
#' @param quos A list of quosures, as given to `filter()`.
#' @return `q`, with fewer files when some were pruned.
#' @noRd
query_prune_partitions <- function(q, quos) {
  partition <- q$entry$partition[[1]]
  query <- q$query
  if (length(partition) == 0 || length(quos) == 0 || nrow(q$files) == 0 ||
    !inherits(query, "arrow_dplyr_query") || inherits(query$.data, "arrow_dplyr_query") ||
    !inherits(query$.data, "FileSystemDataset")) {
    return(q)
  }
  selected <- query$selected_columns
  plain <- function(column) {
    expr <- selected[[column]]
    !is.null(expr) && isTRUE(tryCatch(expr$field_name == column, error = function(e) FALSE))
  }
  use <- Filter(function(quo) {
    refs <- intersect(all.vars(rlang::quo_get_expr(quo)), names(selected))
    length(refs) > 0 && all(refs %in% partition) && all(vapply(refs, plain, logical(1)))
  }, quos)
  if (length(use) == 0) {
    return(q)
  }
  keep <- tryCatch(
    partition_keep(q$files, partition, query$.data$schema, use),
    error = function(e) NULL
  )
  if (is.null(keep) || all(keep)) {
    return(q)
  }
  query_set_files(q, q$files[keep, ])
}

# Which file rows pass the partition-only filters `quos`.
partition_keep <- function(files, partition, schema, quos) {
  values <- lapply(files$partition_values, jsonlite::fromJSON, simplifyVector = FALSE)
  columns <- lapply(stats::setNames(partition, partition), function(p) {
    v <- lapply(values, function(x) x[[p]] %||% NA)
    v <- unlist(v, use.names = FALSE)
    array <- arrow::Array$create(v)
    type <- schema[[p]]$type
    if (inherits(type, "DictionaryType")) {
      type <- type$value_type
    }
    if (!array$type$Equals(type)) {
      array <- array$cast(type)
    }
    array
  })
  table <- arrow::arrow_table(!!!columns, .rcs_file = seq_len(nrow(files)))
  kept <- dplyr::collect(dplyr::select(dplyr::filter(table, !!!quos), ".rcs_file"))
  seq_len(nrow(files)) %in% kept$.rcs_file
}

# Filtering -------------------------------------------------------------------

query_filter <- function(q, quos) {
  q <- query_prune_partitions(q, quos)
  q$query <- dplyr::filter(q$query, !!!quos)
  q
}

# Collecting ------------------------------------------------------------------

#' Run a query and return R data
#'
#' Drops `.rcs_id` (unless `keep_id`) and, with `q$geometry = FALSE`, the
#' WKB column before the scan; counts the files and row groups scanned;
#' collects with `arrow.int64_downcast = FALSE`; applies the exact test of a
#' pending spatial filter; restores R types and decodes the geometry.
#'
#' @param q An `rcs_query`.
#' @param keep_id Keep `.rcs_id`.
#' @return A tibble, or an `sf` object for geospatial rows with geometry.
#' @noRd
query_collect <- function(q, keep_id = FALSE) {
  withr::local_options(arrow.int64_downcast = FALSE)
  query <- q$query
  present <- names(query)
  drop <- c(
    if (!keep_id && ".rcs_id" %in% present) ".rcs_id",
    if (!q$geometry && "geometry" %in% present) "geometry"
  )
  if (length(drop) > 0) {
    query <- dplyr::select(query, -dplyr::all_of(drop))
  }
  # a pending exact test needs the geometry, even when the query selected it
  # away; it is dropped again after the test
  borrowed <- FALSE
  if (spatial_needs_geometry(q) && !"geometry" %in% names(query)) {
    query <- query_borrow_geometry(query)
    borrowed <- "geometry" %in% names(query)
  }
  query_count_scan(q)
  data <- dplyr::collect(query)
  data <- rows_finish(data, q$entry)
  data <- spatial_exact(q, data)
  if (borrowed) {
    data <- tibble::as_tibble(sf::st_drop_geometry(data))
  }
  trace_count("rows_returned", nrow(data), location = q$location$uri)
  data
}

# Count the files and row groups a scan of `q` reads (when tracing).
query_count_scan <- function(q) {
  if (!trace_on()) {
    return(invisible())
  }
  source <- query_source(q$query)
  if (!inherits(source, "FileSystemDataset") || nrow(q$files) == 0) {
    return(invisible())
  }
  uri <- q$location$uri
  for (path in q$files$path) {
    trace_count("file_open", 1, location = uri, detail = path)
  }
  groups <- files_row_group_counts(q$location$backend, q$files$path)
  trace_count("row_groups_total", sum(groups), location = uri)
  if (!is.null(q$spatial)) {
    trace_count("row_groups_overlap", spatial_row_groups_overlap(q), location = uri)
  }
  invisible()
}

# Number of row groups of each file, from the footers, without counting the
# files as opened (they are counted by the scan that reads them).
files_row_group_counts <- function(be, paths) {
  fs <- be_arrow_fs(be)
  vapply(paths, function(p) {
    file <- fs$fs$OpenInputFile(paste0(fs$path, "/", p))
    on.exit(file$close())
    as.double(arrow::ParquetFileReader$create(file)$num_row_groups)
  }, numeric(1), USE.NAMES = FALSE)
}

#' Turn collected rows into the R data a read returns
#'
#' Restores the R types recorded in the entry's `columns` (`r_type`) for the
#' columns that still carry their stored name and a compatible type, gives
#' the cell columns class `rcs_h3` (`h3_classify()`, D8), and decodes a WKB `geometry` column of a geospatial dataset into `sf` with
#' the entry's CRS.
#'
#' @param data A data frame collected from Arrow (with
#'   `arrow.int64_downcast = FALSE`).
#' @param entry The dataset's entry.
#' @return A tibble or an `sf` object.
#' @noRd
rows_finish <- function(data, entry) {
  data <- tibble::as_tibble(data)
  data <- restore_types(data, columns_from_json(entry$columns))
  data <- h3_classify(data, entry)
  if (identical(entry$kind, "geospatial") && "geometry" %in% names(data) && is.list(data$geometry)) {
    data <- geo_decode(data, entry$crs)
  }
  data
}

# dplyr methods ---------------------------------------------------------------

#' dplyr verbs for lazy queries
#'
#' Methods of the dplyr generics for queries made by [store_open()]. The
#' verbs are applied by Arrow when the query runs; `collect()` returns R
#' data (see [store_open()]), `compute()` keeps the rows in memory as Arrow
#' data and returns a query on them, `pull()` collects one column, and
#' `glimpse()` collects the first rows and shows them.
#'
#' A filter on partition columns opens only the files of the matching
#' partitions when it comes before any other verb that changes those
#' columns. A pending spatial filter ([store_intersects()]) applies to the
#' rows of the dataset; its exact test runs in `collect()` on the rows the
#' query returns, so a `head()` before `collect()` may give fewer rows than
#' asked for.
#'
#' @param .data,x A query made by [store_open()].
#' @param ... Arguments of the dplyr verb.
#' @param .by,.preserve,.by_group,.keep_all,width,var,name,n As in dplyr.
#' @return `collect()`: a tibble or an `sf` object. `pull()`: a vector.
#'   `glimpse()`: `x`, invisibly. Every other verb: an `rcs_query`.
#' @name rcs_query-dplyr
NULL

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::filter
filter.rcs_query <- function(.data, ..., .by = NULL, .preserve = FALSE) {
  if (!rlang::quo_is_null(rlang::enquo(.by))) {
    cli::cli_abort("{.arg .by} is not supported for {.cls rcs_query}.", class = "rcs_error_argument")
  }
  query_filter(.data, rlang::enquos(...))
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::select
select.rcs_query <- function(.data, ...) {
  .data$query <- dplyr::select(.data$query, ...)
  .data
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::mutate
mutate.rcs_query <- function(.data, ...) {
  .data$query <- dplyr::mutate(.data$query, ...)
  .data
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::rename
rename.rcs_query <- function(.data, ...) {
  .data$query <- dplyr::rename(.data$query, ...)
  .data
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::arrange
arrange.rcs_query <- function(.data, ..., .by_group = FALSE) {
  .data$query <- dplyr::arrange(.data$query, ..., .by_group = .by_group)
  .data
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::distinct
distinct.rcs_query <- function(.data, ..., .keep_all = FALSE) {
  .data$query <- dplyr::distinct(.data$query, ..., .keep_all = .keep_all)
  .data
}

#' @rdname rcs_query-dplyr
#' @exportS3Method utils::head
head.rcs_query <- function(x, n = 6L, ...) {
  x$query <- utils::head(x$query, n)
  x
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::collect
collect.rcs_query <- function(x, ...) {
  local_trace("collect")
  query_collect(x)
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::compute
compute.rcs_query <- function(x, ...) {
  local_trace("compute")
  withr::local_options(arrow.int64_downcast = FALSE)
  query_count_scan(x)
  table <- dplyr::compute(x$query)
  x$query <- dplyr::select(arrow::InMemoryDataset$create(table), dplyr::everything())
  x
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::pull
pull.rcs_query <- function(.data, var = -1, name = NULL, ...) {
  local_trace("pull")
  data <- query_collect(.data)
  if (inherits(data, "sf")) {
    data <- tibble::as_tibble(data)
  }
  dplyr::pull(data, {{ var }}, {{ name }})
}

#' @rdname rcs_query-dplyr
#' @exportS3Method dplyr::glimpse
glimpse.rcs_query <- function(x, width = NULL, ...) {
  local_trace("glimpse")
  data <- query_collect(head.rcs_query(x, 10L))
  if (inherits(data, "sf")) {
    data <- tibble::as_tibble(data)
  }
  dplyr::glimpse(data, width = width)
  invisible(x)
}

# Printing --------------------------------------------------------------------

#' @rdname store_open
#' @export
print.rcs_query <- function(x, ..., n = NULL) {
  local_trace("print")
  n <- n %||% rcs_option("rcs.print_rows")
  if (!rlang::is_scalar_integerish(n, finite = TRUE) || n < 1) {
    cli::cli_abort(
      "{.arg n} must be a whole number of at least 1.",
      class = "rcs_error_argument"
    )
  }
  n <- as.integer(n)
  # the footer says what the messages of collect() would say
  withr::local_options(rcs.quiet = TRUE)
  data <- query_collect(head.rcs_query(x, n + 1L))
  more <- nrow(data) > n
  data <- utils::head(data, n)
  width <- list(...)$width
  preview <- new_rcs_preview(
    data,
    header = query_header(x, ncol(data), width),
    footer = query_footer(x, nrow(data), more)
  )
  print(preview, n = n, ...)
  invisible(x)
}

# Header lines of a printed query (named; pillar aligns the names).
query_header <- function(x, ncol, width) {
  entry <- x$entry
  rows <- if (query_rows_known(x)) format_count(as.numeric(entry$rows)) else "??"
  total <- as.numeric(entry$n_files)
  current <- x$location$catalog$version[x$location$catalog$dataset == entry$dataset]
  version <- if (length(current) == 1 && identical(current, entry$version)) "current" else "earlier"
  files <- paste0(nrow(x$files), " of ", format_count(total))
  if (nrow(x$files) < total) {
    files <- paste0(files, " (pruned)")
  }
  out <- c(
    Dataset = paste0(entry$dataset, " [", rows, " x ", ncol, "] (", entry$kind, ")"),
    Location = paste0(query_location_role(x), " (", x$location$backend$type, ")"),
    Version = paste0(substr(entry$version, 1, 8), " (", version, ")"),
    Files = files
  )
  if (!is.null(x$spatial)) {
    out[["Spatial"]] <- spatial_describe(x$spatial)
    out[["Filter"]] <- "(with spatial predicate)"
  } else {
    filter <- query_filter_text(x$query)
    if (!is.null(filter)) {
      # pillar wraps each header line "# <name>: <text>" (names aligned,
      # padded to the longest) at header_width(); only a line shorter than
      # that stays on one line. Arrow's text holds newlines and indents,
      # which pillar squashes to one space: squash before counting.
      filter <- gsub("\\s+", " ", filter)
      prefix <- nchar("# ") + max(nchar(c(names(out), "Filter"))) + nchar(": ")
      out[["Filter"]] <- truncate_text(filter, header_width(width) - prefix - 1L)
    }
  }
  out
}

# The width at which pillar wraps the header lines of a printed tibble:
# format_comment() wraps at min(setup$width, cli::console_width()), where
# setup$width is the `width` argument of print() or pillar's width option.
header_width <- function(width = NULL) {
  width <- width %||% getOption("pillar.width", getOption("width"))
  min(width, cli::console_width())
}

# Footer lines of a printed query, after pillar's own.
query_footer <- function(x, shown, more) {
  hint <- "Use `collect()` to read the rows into R."
  if (spatial_needs_geometry(x)) {
    return(c("more rows may exist", hint))
  }
  if (shown == 0) {
    return("0 rows")
  }
  left <- if (query_rows_known(x)) as.numeric(x$entry$rows) - shown else NA
  rows <- if (!is.na(left)) {
    if (left > 0) paste0(format_count(left), if (left == 1) " more row" else " more rows")
  } else if (more) {
    "more rows"
  }
  c(rows, hint)
}

# Whether the query returns every row of the dataset: one Arrow step over
# the files (columns selected, renamed or computed), no filter, no order,
# no aggregation, no head, no spatial filter, every file kept.
query_rows_known <- function(x) {
  query <- x$query
  inherits(query, "arrow_dplyr_query") &&
    inherits(query$.data, "FileSystemDataset") &&
    isTRUE(query$filtered_rows) &&
    length(query$arrange_vars) == 0 &&
    length(query$group_by_vars) == 0 &&
    is.null(query$aggregations) &&
    is.null(query$head) && is.null(query$tail) && is.null(query$join) &&
    is.null(x$spatial) &&
    nrow(x$files) == as.numeric(x$entry$n_files)
}

# The rows filters of an Arrow query as text (bottom step first), or NULL.
query_filter_text <- function(query) {
  parts <- character()
  while (inherits(query, "arrow_dplyr_query")) {
    if (!isTRUE(query$filtered_rows)) {
      parts <- c(query$filtered_rows$ToString(), parts)
    }
    query <- query$.data
  }
  if (length(parts) == 0) {
    return(NULL)
  }
  paste(parts, collapse = " & ")
}

# Cut `text` to at most `width` characters, ending with "...".
truncate_text <- function(text, width) {
  width <- max(width, 4L)
  if (nchar(text) <= width) {
    return(text)
  }
  paste0(substr(text, 1, width - 3L), "...")
}

query_location_role <- function(q) {
  i <- match(q$location$uri, store_uris(q$store))
  if (identical(i, 1L)) "primary" else paste0("secondary ", i - 1L)
}
