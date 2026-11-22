# A store's datasets as DuckDB views: store_duckdb() and store_tables().
#
# Every dataset of the primary catalog except rasters becomes a view
# `<schema>.<table>` (`duckdb_view_name()`). A view holds query text only:
# DuckDB reads the Parquet files when a query runs. The connection records
# what it holds in two tables of schema `rcs`: `rcs.views` (one row per view)
# and `rcs.store` (the locations of the one store the connection serves).

# Names --------------------------------------------------------------------------

#' The DuckDB view name of a dataset
#'
#' Schema = first part of the name, table = the other parts joined with
#' `__`; a one-part name goes to schema `main`. Index tables keep their
#' `__h3` suffix. Contract of plan 0002 (D12), used by T2, T3 and U.
#'
#' @param dataset One full dataset name.
#' @return `c(schema = , table = )`.
#' @noRd
duckdb_view_name <- function(dataset) {
  parts <- strsplit(dataset, "/", fixed = TRUE)[[1]]
  if (length(parts) == 1) {
    parts <- c("main", parts)
  }
  c(schema = parts[[1]], table = paste(parts[-1], collapse = "__"))
}

# `schema.table` of datasets, for messages and `rcs.views`.
duckdb_view_label <- function(dataset) {
  vapply(dataset, function(d) paste(duckdb_view_name(d), collapse = "."), character(1), USE.NAMES = FALSE)
}

# A quoted identifier, and a quoted `schema.table`.
duckdb_id <- function(con, x) {
  as.character(DBI::dbQuoteIdentifier(con, x))
}

duckdb_qualified <- function(con, name) {
  paste0(duckdb_id(con, name[["schema"]]), ".", duckdb_id(con, name[["table"]]))
}

# store_duckdb() ------------------------------------------------------------------

#' Query a store's datasets in DuckDB
#'
#' Creates one DuckDB view per dataset of the store's primary catalog
#' (rasters excluded, the H3 index tables of geospatial datasets included),
#' so that the datasets can be queried with SQL or with dbplyr. A view stores
#' no data: DuckDB reads the Parquet files when a query runs, and only the
#' columns and row groups the query needs. The file list comes from the
#' catalog held by the connection `st`, so the views show the versions it
#' knows: after [store_refresh()] call `store_duckdb()` again.
#'
#' * View names: the first part of the dataset name is the schema, the other
#'   parts joined with `__` are the view; a one-part name goes to schema
#'   `main`. `"sales/daily"` is the view `sales.daily`, `"a/b/c"` is
#'   `a.b__c`. Two datasets with the same view name, a first part `rcs`, or a
#'   first part equal to the name of an attached database (such as `memory`
#'   or `system`) abort.
#' * `mode = "native"` (the default): DuckDB reads the files itself with
#'   `read_parquet()`, from the location a read would use. For locations on
#'   Google Cloud Storage a temporary DuckDB secret is created from the
#'   location's credential (see [rcs_auth_gcs()]). Its access token is valid
#'   for about an hour: call `store_duckdb()` again to renew it. The
#'   `geometry` column of geospatial datasets is of DuckDB type `GEOMETRY`.
#' * `mode = "arrow"`: the Arrow dataset the package opens for reads is
#'   registered in DuckDB and the view selects from it, so DuckDB needs no
#'   credential of its own; filters are pushed into the Arrow scan. The
#'   `geometry` column is WKB (`BLOB`).
#' * `spatial = TRUE` installs and loads DuckDB's `spatial` extension and, in
#'   arrow mode, adds a column `geom` (`GEOMETRY`) to geospatial views.
#' * The macro `rcs_h3_hex(x)` turns H3 cells (`BIGINT`) into hex strings in
#'   SQL.
#'
#' The connection records its views in the table `rcs.views` (`view`,
#' `dataset`, `version`, `location`, `mode`, `refreshed` in UTC) and the
#' store's locations in `rcs.store` (`role`, `uri`); neither holds a
#' credential. A connection serves one store. With `datasets = NULL` both
#' tables are rewritten and the views of datasets no longer in the catalog
#' are dropped; with `datasets` given only those views and rows are
#' replaced. [store_tables()] lists what a connection holds.
#'
#' @section Database files:
#' With `path`, the views, the `rcs` tables and the tables you create live in
#' a DuckDB file, created when missing. A file `work.duckdb` is attached as
#' the database `work`, so no dataset may have the first part `work`. The
#' file must lie outside every local location of the store, which a sync
#' would carry it to.
#'
#' Calling `store_duckdb(st, path)` again on the same file refreshes it:
#' views are replaced to show the versions in `st`'s catalog, views of
#' deleted datasets are dropped, secrets are recreated, and your own tables
#' and views are left untouched (a table or a view not made by
#' `store_duckdb()` with a view's name aborts). `store_duckdb(path = )`
#' without `st` reconnects to the store recorded in `rcs.store`, with default
#' credentials, and refreshes the same way.
#'
#' A plain `DBI::dbConnect(duckdb::duckdb(dbdir = path))` also opens the
#' file: your tables work, and native views work while their files exist,
#' but they show the versions of the last refresh, views on Google Cloud
#' Storage need a secret first, and views in arrow mode do not work until
#' `store_duckdb()` is called again.
#'
#' @param st A store connection made by [store_connect()]. It may be left
#'   out only with `path`, to reopen a file prepared earlier.
#' @param path `NULL` for an in-memory database, or the path of a DuckDB
#'   database file (see "Database files").
#' @param datasets `NULL` for every dataset, or full or short dataset names;
#'   their index tables are added.
#' @param mode `"native"` or `"arrow"`, see above.
#' @param spatial `TRUE` loads the DuckDB `spatial` extension (downloaded on
#'   first use).
#' @param con `NULL` to create a new connection, or an existing
#'   DuckDB connection made with `bigint = "integer64"` (H3 cells do not fit
#'   a double); `path` must then be `NULL`.
#' @return The DuckDB connection, invisibly. Close it with
#'   `DBI::dbDisconnect(con, shutdown = TRUE)`.
#' @seealso [store_tables()], [store_open()].
#' @export
#' @examplesIf rlang::is_installed(c("duckdb", "DBI"))
#' root <- file.path(tempdir(), "rcs-example-duckdb")
#' st <- store_connect(root, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' con <- store_duckdb(st)
#' DBI::dbGetQuery(con, "SELECT year, sum(qty) AS qty FROM sales.daily GROUP BY year")
#' store_tables(con, st)
#' DBI::dbDisconnect(con, shutdown = TRUE)
#' unlink(root, recursive = TRUE)
store_duckdb <- function(st, path = NULL, datasets = NULL, mode = c("native", "arrow"),
                         spatial = FALSE, con = NULL) {
  local_trace("store_duckdb")
  call <- rlang::current_env()
  if (!is.null(path) && !is.null(con)) {
    cli::cli_abort(
      "Give {.arg path} or {.arg con}, not both.",
      class = "rcs_error_argument", call = call
    )
  }
  check_string(path, allow_null = TRUE, call = call)
  if (missing(st)) {
    if (is.null(path)) {
      cli::cli_abort(
        "{.arg st} is missing; it may be left out only with {.arg path}.",
        class = "rcs_error_argument", call = call
      )
    }
    st <- NULL
  } else {
    validate_store(st, call = call)
  }
  mode <- rlang::arg_match(mode, error_call = call)
  check_flag(spatial, call = call)
  if (!is.null(datasets) && (!is.character(datasets) || anyNA(datasets))) {
    cli::cli_abort(
      "{.arg datasets} must be {.code NULL} or dataset names, not {.obj_type_friendly {datasets}}.",
      class = "rcs_error_argument", call = call
    )
  }
  rlang::check_installed(c("duckdb", "DBI"), reason = "to query a store in DuckDB.", call = call)
  if (!is.null(con)) {
    duckdb_check_con(con, call = call)
  }
  if (!is.null(path)) {
    path <- duckdb_file_path(path)
    if (is.null(st) && !file.exists(path)) {
      cli::cli_abort(
        c(
          "{.arg st} is missing and the DuckDB file {.path {path}} does not exist.",
          i = "Give {.arg st} to create the file."
        ),
        class = "rcs_error_argument", call = call
      )
    }
    if (!is.null(st)) {
      duckdb_check_path(st, path, call = call)
    }
  }

  made <- is.null(con)
  if (made) {
    created <- !is.null(path) && !file.exists(path)
    con <- duckdb_connect(path, call = call)
    done <- FALSE
    on.exit(
      if (!done) {
        DBI::dbDisconnect(con, shutdown = TRUE)
        # A file this call created and could not fill is removed.
        if (created) unlink(paste0(path, c("", ".wal")))
      },
      add = TRUE
    )
  }
  if (is.null(st)) {
    st <- duckdb_reopen_store(con, path, call = call)
    duckdb_check_path(st, path, call = call)
  }

  chosen <- duckdb_datasets(st, datasets, call = call)
  duckdb_check_store(con, st, call = call)
  duckdb_check_names(con, st, chosen, call = call)
  duckdb_check_objects(con, chosen, call = call)

  if (spatial) {
    duckdb_run(con, "INSTALL spatial", "Installing the DuckDB extension {.val spatial} failed.", call = call)
    duckdb_run(con, "LOAD spatial", "Loading the DuckDB extension {.val spatial} failed.", call = call)
  }
  duckdb_run(con, h3_duckdb_macro_sql(), "Creating the macro {.fn rcs_h3_hex} failed.", call = call)

  targets <- lapply(chosen, function(dataset) read_target(st, dataset, call = call))
  if (mode == "native") {
    duckdb_secrets(con, targets, call = call)
  }
  refreshed <- format(Sys.time(), "%Y-%m-%d %H:%M:%OS6", tz = "UTC")
  rows <- vector("list", length(targets))
  for (i in seq_along(targets)) {
    rows[[i]] <- duckdb_make_view(con, targets[[i]], mode, spatial, call = call)
  }
  rows <- vctrs::vec_rbind(!!!rows, .ptype = duckdb_views_ptype())
  rows$refreshed <- rep(refreshed, nrow(rows))
  duckdb_record(con, st, rows, all = is.null(datasets), call = call)

  views <- rows$view
  if (length(views) == 0) {
    rcs_inform(c(i = "No dataset to show in DuckDB."))
  } else {
    rcs_inform(c(v = "DuckDB {cli::qty(length(views))}view{?s} ({mode} mode, nothing read yet): {.code {views}}."))
    if (!is.null(path) && mode == "arrow") {
      rcs_inform(c(
        i = "Views in arrow mode do not work after the file is closed: call {.fn store_duckdb} again after reopening it."
      ))
    }
  }
  if (made) {
    done <- TRUE
  }
  invisible(con)
}

# Database files ------------------------------------------------------------------

# Absolute path of a database file, with forward slashes.
duckdb_file_path <- function(path) {
  path <- path.expand(path)
  dir <- normalizePath(dirname(path), winslash = "/", mustWork = FALSE)
  paste0(sub("/+$", "", dir), "/", basename(path))
}

# A new connection, in memory (`path` NULL) or to a file created when missing.
duckdb_connect <- function(path = NULL, call = caller_env()) {
  dbdir <- path %||% ":memory:"
  tryCatch(
    # duckdb's once-per-session note about its storage folder is not ours.
    suppressMessages(DBI::dbConnect(duckdb::duckdb(dbdir = dbdir), bigint = "integer64")),
    error = function(e) {
      cli::cli_abort(
        "Opening the DuckDB database file {.path {path}} failed.",
        class = "rcs_error_duckdb", parent = e, call = call
      )
    }
  )
}

# D17: a file inside a local location would be carried by a sync.
duckdb_check_path <- function(st, path, call = caller_env()) {
  locations <- c(list(st$primary), st$secondary)
  locals <- Filter(function(l) inherits(l$backend, "rcs_backend_local"), locations)
  fold <- if (.Platform$OS.type == "windows") tolower else identity
  file <- fold(path)
  for (location in locals) {
    root <- sub("/+$", "", normalizePath(location$backend$root, winslash = "/", mustWork = FALSE))
    if (startsWith(file, paste0(fold(root), "/"))) {
      uri <- location$uri
      cli::cli_abort(
        c(
          "The DuckDB file {.path {path}} is inside the store location {.path {uri}}.",
          i = "A sync would copy it; put it outside every location of the store."
        ),
        class = "rcs_error_argument", call = call
      )
    }
  }
  invisible()
}

# D16: the store a database file serves, connected from its rcs.store with
# default credentials.
duckdb_reopen_store <- function(con, path, call = caller_env()) {
  if (!duckdb_has_table(con, "rcs", "store")) {
    cli::cli_abort(
      c(
        "The DuckDB file {.path {path}} holds no table {.code rcs.store}.",
        i = "Only a file prepared by {.fn store_duckdb} can be reopened without {.arg st}."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  stored <- DBI::dbGetQuery(con, "SELECT role, uri FROM rcs.store")
  primary <- stored$uri[stored$role == "primary"]
  if (length(primary) != 1) {
    cli::cli_abort(
      "The table {.code rcs.store} of {.path {path}} names {length(primary)} primary locations, not one.",
      class = "rcs_error_duckdb", call = call
    )
  }
  store_connect(primary, stored$uri[stored$role == "secondary"])
}

# Connections ---------------------------------------------------------------------

# A connection passed in: DuckDB, open, and BIGINT as integer64 (fact 1).
duckdb_check_con <- function(con, call = caller_env()) {
  if (!inherits(con, "duckdb_connection")) {
    cli::cli_abort(
      "{.arg con} must be a DuckDB connection, not {.obj_type_friendly {con}}.",
      class = "rcs_error_argument", call = call
    )
  }
  if (!DBI::dbIsValid(con)) {
    cli::cli_abort("{.arg con} is closed.", class = "rcs_error_duckdb", call = call)
  }
  x <- DBI::dbGetQuery(con, "SELECT 9007199254740993::BIGINT AS x")$x
  if (!inherits(x, "integer64")) {
    cli::cli_abort(
      c(
        "{.arg con} returns {.code BIGINT} as {.cls {class(x)[[1]]}}, which cannot hold H3 cells exactly.",
        i = "Connect with {.code DBI::dbConnect(duckdb::duckdb(), bigint = \"integer64\")}."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  invisible(con)
}

# Full names of the datasets to show: every dataset of the primary catalog
# that is not a raster, or the ones named plus their index tables.
duckdb_datasets <- function(st, datasets, call = caller_env()) {
  catalog <- st$primary$catalog
  catalog <- catalog[catalog$kind != "raster", ]
  if (is.null(datasets)) {
    return(sort(catalog$dataset, method = "radix"))
  }
  full <- vapply(datasets, function(d) resolve_dataset(st, d, index = TRUE, call = call), character(1))
  kind <- catalog$kind[match(full, catalog$dataset)]
  if (anyNA(kind)) {
    rasters <- full[is.na(kind)]
    cli::cli_abort(
      c(
        "Rasters cannot be shown in DuckDB.",
        x = "{.val {rasters}} {cli::qty(length(rasters))}{?is a raster/are rasters}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  index <- index_name(full)
  full <- c(full, index[index %in% catalog$dataset])
  sort(unique(full), method = "radix")
}

# One store per connection (D15).
duckdb_check_store <- function(con, st, call = caller_env()) {
  if (!duckdb_has_table(con, "rcs", "store")) {
    return(invisible())
  }
  stored <- DBI::dbGetQuery(con, "SELECT role, uri FROM rcs.store")
  primary <- stored$uri[stored$role == "primary"]
  if (length(primary) > 0 && !identical(primary[[1]], st$primary$uri)) {
    uri <- st$primary$uri
    held <- primary[[1]]
    cli::cli_abort(
      c(
        "This DuckDB connection serves another store.",
        i = "Its primary location is {.path {held}}, not {.path {uri}}.",
        i = "Use a new connection for each store."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  invisible()
}

# Guards of D12 on view names: collisions (among the datasets shown and with
# views of other datasets the connection already holds), schema `rcs`, and a
# schema equal to a database name (fact 5).
duckdb_check_names <- function(con, st, datasets, call = caller_env()) {
  if (length(datasets) == 0) {
    return(invisible())
  }
  views <- duckdb_view_label(datasets)
  held <- duckdb_held_views(con)
  held <- held[!held$dataset %in% datasets & held$dataset %in% st$primary$catalog$dataset, ]
  all_views <- c(views, held$view)
  all_datasets <- c(datasets, held$dataset)
  twice <- unique(all_views[duplicated(all_views)])
  if (length(twice) > 0) {
    clash <- all_datasets[all_views %in% twice]
    cli::cli_abort(
      c(
        "Datasets {.val {clash}} map to the same DuckDB view name {.code {twice}}.",
        i = "The first part of a name is the schema; the other parts are joined with {.code __}."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  schemas <- vapply(datasets, function(d) duckdb_view_name(d)[["schema"]], character(1), USE.NAMES = FALSE)
  bad <- datasets[schemas == "rcs"]
  if (length(bad) > 0) {
    cli::cli_abort(
      c(
        "{cli::qty(length(bad))}Dataset{?s} {.val {bad}} would be shown in schema {.code rcs}.",
        i = "Schema {.code rcs} holds the package's own tables; rename {cli::qty(length(bad))}the dataset{?s}."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  databases <- unique(c(
    DBI::dbGetQuery(con, "SELECT current_database() AS d")$d,
    DBI::dbGetQuery(con, "SELECT database_name FROM duckdb_databases()")$database_name
  ))
  bad <- datasets[schemas %in% databases]
  if (length(bad) > 0) {
    clash <- unique(schemas[schemas %in% databases])
    cli::cli_abort(
      c(
        "{cli::qty(length(bad))}Dataset{?s} {.val {bad}} would be shown in a schema named like a database: {.code {clash}}.",
        i = "DuckDB could not tell the schema from the database; rename {cli::qty(length(bad))}the dataset{?s}."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  invisible()
}

# An existing table, or a view the connection did not make, with a view's
# name is never replaced.
duckdb_check_objects <- function(con, datasets, call = caller_env()) {
  if (length(datasets) == 0) {
    return(invisible())
  }
  objects <- duckdb_objects_current(con)
  views <- duckdb_view_label(datasets)
  held <- duckdb_held_views(con)$view
  label <- paste(objects$schema, objects$name, sep = ".")
  taken <- label %in% views & (objects$type == "table" | !label %in% held)
  if (any(taken)) {
    clash <- label[taken]
    cli::cli_abort(
      c(
        "The DuckDB connection already holds {.code {clash}}, which {.fn store_duckdb} did not make.",
        i = "Rename or drop {cli::qty(length(clash))}{?it/them} first."
      ),
      class = "rcs_error_duckdb", call = call
    )
  }
  invisible()
}

# One statement through `duckdb_exec()`; a failure aborts `rcs_error_duckdb`.
duckdb_run <- function(con, sql, message, call = caller_env(), .envir = parent.frame()) {
  tryCatch(
    duckdb_exec(con, sql),
    error = function(e) {
      cli::cli_abort(message, class = "rcs_error_duckdb", parent = e, call = call, .envir = .envir)
    }
  )
}

# A secret for every GCS location the views read from (D13, D22).
duckdb_secrets <- function(con, targets, call = caller_env()) {
  seen <- character()
  for (target in targets) {
    be <- target$location$backend
    if (!inherits(be, "rcs_backend_gcs") || be$uri %in% seen) {
      next
    }
    auth_duckdb_secret(gcs_auth(be), con, be$uri, call = call)
    seen <- c(seen, be$uri)
  }
  invisible(seen)
}

# Addresses DuckDB reads the files of a location from.
duckdb_file_urls <- function(location, paths) {
  be <- location$backend
  if (inherits(be, "rcs_backend_gcs")) {
    return(paste0(sub("/+$", "", be$uri), "/", paths))
  }
  root <- normalizePath(be$root, winslash = "/", mustWork = FALSE)
  paste0(root, "/", paths)
}

# Name of the Arrow registration behind a view in arrow mode.
duckdb_arrow_name <- function(name) {
  paste0("rcs_arrow_", name[["schema"]], "__", name[["table"]])
}

duckdb_unregister <- function(con, name) {
  tryCatch(duckdb::duckdb_unregister_arrow(con, duckdb_arrow_name(name)), error = function(e) NULL)
  invisible()
}

# Create or replace the view of one read target; returns its `rcs.views` row
# (without `refreshed`).
duckdb_make_view <- function(con, target, mode, spatial, call = caller_env()) {
  dataset <- target$dataset
  name <- duckdb_view_name(dataset)
  view <- duckdb_qualified(con, name)
  duckdb_run(con, paste("CREATE SCHEMA IF NOT EXISTS", duckdb_id(con, name[["schema"]])),
    "Creating the DuckDB schema {.code {name[['schema']]}} failed.",
    call = call
  )
  duckdb_unregister(con, name)
  paths <- target$files$path
  # Every dataset has at least one file (a write of zero rows writes one).
  if (mode == "native") {
    urls <- duckdb_file_urls(target$location, paths)
    files <- paste(DBI::dbQuoteString(con, urls), collapse = ", ")
    source <- paste0("read_parquet([", files, "], hive_partitioning = false)")
    select <- "*"
  } else {
    ds <- query_open_files(target$location, paths)
    registration <- duckdb_arrow_name(name)
    duckdb::duckdb_register_arrow(con, registration, ds)
    source <- duckdb_id(con, registration)
    geo <- spatial && identical(target$entry$kind, "geospatial")
    select <- if (geo) "*, ST_GeomFromWKB(geometry) AS geom" else "*"
  }
  label <- paste(name, collapse = ".")
  duckdb_run(con, paste0("CREATE OR REPLACE VIEW ", view, " AS SELECT ", select, " FROM ", source),
    "Creating the DuckDB view {.code {label}} of {.val {dataset}} failed.",
    call = call
  )
  tibble::tibble(
    view = label,
    dataset = dataset,
    version = target$entry$version,
    location = target$location$uri,
    mode = mode
  )
}

duckdb_views_ptype <- function() {
  tibble::tibble(
    view = character(), dataset = character(), version = character(),
    location = character(), mode = character()
  )
}

# rcs.views and rcs.store -----------------------------------------------------------

duckdb_has_table <- function(con, schema, table) {
  sql <- paste0(
    "SELECT count(*) AS n FROM duckdb_tables() WHERE database_name = current_database()",
    " AND schema_name = ", sql_string(schema), " AND table_name = ", sql_string(table)
  )
  DBI::dbGetQuery(con, sql)$n > 0
}

# The rows of rcs.views, or none.
duckdb_held_views <- function(con) {
  if (!duckdb_has_table(con, "rcs", "views")) {
    return(tibble::tibble(view = character(), dataset = character(), version = character()))
  }
  tibble::as_tibble(DBI::dbGetQuery(con, "SELECT view, dataset, version FROM rcs.views"))
}

# Record the views made: all = TRUE rewrites both tables and drops the views
# of datasets no longer listed; otherwise the rows of these views are
# replaced (and rcs.store written when missing).
duckdb_record <- function(con, st, rows, all, call = caller_env()) {
  run <- function(sql) duckdb_run(con, sql, "Updating the tables of schema {.code rcs} failed.", call = call)
  run("CREATE SCHEMA IF NOT EXISTS rcs")
  run(paste(
    "CREATE TABLE IF NOT EXISTS rcs.views (view VARCHAR, dataset VARCHAR, version VARCHAR,",
    "location VARCHAR, mode VARCHAR, refreshed TIMESTAMP)"
  ))
  has_store <- duckdb_has_table(con, "rcs", "store")
  run("CREATE TABLE IF NOT EXISTS rcs.store (role VARCHAR, uri VARCHAR)")
  if (all) {
    held <- duckdb_held_views(con)
    gone <- held$view[!held$view %in% rows$view]
    for (label in unique(gone)) {
      parts <- strsplit(label, ".", fixed = TRUE)[[1]]
      name <- c(schema = parts[[1]], table = paste(parts[-1], collapse = "."))
      run(paste("DROP VIEW IF EXISTS", duckdb_qualified(con, name)))
      duckdb_unregister(con, name)
    }
    run("DELETE FROM rcs.views")
  } else if (nrow(rows) > 0) {
    run(paste0("DELETE FROM rcs.views WHERE view IN (", paste(sql_string(rows$view), collapse = ", "), ")"))
  }
  if (nrow(rows) > 0) {
    values <- paste0(
      "(", sql_string(rows$view), ", ", sql_string(rows$dataset), ", ",
      sql_string(rows$version), ", ", sql_string(rows$location), ", ",
      sql_string(rows$mode), ", CAST(", sql_string(rows$refreshed), " AS TIMESTAMP))"
    )
    run(paste("INSERT INTO rcs.views VALUES", paste(values, collapse = ", ")))
  }
  if (all || !has_store) {
    uris <- store_uris(st)
    roles <- c("primary", rep("secondary", length(uris) - 1))
    run("DELETE FROM rcs.store")
    values <- paste0("(", sql_string(roles), ", ", sql_string(uris), ")")
    run(paste("INSERT INTO rcs.store VALUES", paste(values, collapse = ", ")))
  }
  invisible()
}

# Tables and views of the current database outside the internal schemas.
duckdb_objects_current <- function(con) {
  skip <- "('information_schema', 'pg_catalog', 'rcs')"
  sql <- paste0(
    "SELECT schema_name AS schema, table_name AS name, 'table' AS type FROM duckdb_tables() ",
    "WHERE NOT internal AND database_name = current_database() AND schema_name NOT IN ", skip,
    " UNION ALL ",
    "SELECT schema_name AS schema, view_name AS name, 'view' AS type FROM duckdb_views() ",
    "WHERE NOT internal AND database_name = current_database() AND schema_name NOT IN ", skip
  )
  out <- tibble::as_tibble(DBI::dbGetQuery(con, sql))
  out[order(out$schema, out$name, method = "radix"), ]
}

# store_tables() ------------------------------------------------------------------

#' List a store's datasets or a DuckDB connection's tables
#'
#' For a store: [store_datasets()] plus the column `duckdb_view`, the name of
#' the view [store_duckdb()] gives each dataset (`NA` for rasters, which have
#' none). For a DuckDB connection: its tables and views outside the schemas
#' `information_schema`, `pg_catalog` and `rcs`, with the dataset and version
#' of the views made by [store_duckdb()].
#'
#' @param x A store connection made by [store_connect()], or a DuckDB
#'   connection.
#' @param st `NULL`, or, with a DuckDB connection, the store connection to
#'   compare the views' versions with.
#' @return A tibble. For a store, see [store_datasets()]. For a connection,
#'   one row per table or view, sorted: `schema`, `name`, `type` (`"table"` or
#'   `"view"`), `dataset` and `version` (`NA` for objects not made by
#'   [store_duckdb()]), and with `st` a column `current`: `TRUE` when the
#'   view shows the version in `st`'s catalog, `FALSE` when not (call
#'   [store_duckdb()] again), `NA` for other objects.
#' @seealso [store_duckdb()], [store_datasets()].
#' @export
#' @examplesIf rlang::is_installed(c("duckdb", "DBI"))
#' root <- file.path(tempdir(), "rcs-example-tables")
#' st <- store_connect(root, create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales."
#' )
#' store_tables(st)
#' con <- store_duckdb(st)
#' DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
#' store_tables(con, st)
#' DBI::dbDisconnect(con, shutdown = TRUE)
#' unlink(root, recursive = TRUE)
store_tables <- function(x, st = NULL) {
  local_trace("store_tables")
  call <- rlang::current_env()
  if (inherits(x, "rcs_store")) {
    if (!is.null(st)) {
      cli::cli_abort(
        "{.arg st} applies only when {.arg x} is a DuckDB connection.",
        class = "rcs_error_argument", call = call
      )
    }
    out <- store_datasets(x)
    view <- duckdb_view_label(out$dataset)
    view[out$kind == "raster"] <- NA_character_
    out$duckdb_view <- view
    return(out)
  }
  if (!inherits(x, "duckdb_connection")) {
    cli::cli_abort(
      c(
        "{.arg x} must be a store connection or a DuckDB connection.",
        x = "It is {.obj_type_friendly {x}}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (!is.null(st)) {
    if (!inherits(st, "rcs_store")) {
      cli::cli_abort(
        c(
          "{.arg st} must be {.code NULL} or a store connection made by {.fn store_connect}.",
          x = "It is {.obj_type_friendly {st}}."
        ),
        class = "rcs_error_argument", call = call
      )
    }
    validate_store(st, call = call)
  }
  if (!DBI::dbIsValid(x)) {
    cli::cli_abort("{.arg x} is closed.", class = "rcs_error_duckdb", call = call)
  }
  out <- duckdb_objects_current(x)
  held <- duckdb_held_views(x)
  label <- paste(out$schema, out$name, sep = ".")
  at <- match(label, held$view)
  at[out$type != "view"] <- NA_integer_
  out$dataset <- held$dataset[at]
  out$version <- held$version[at]
  if (!is.null(st)) {
    catalog <- st$primary$catalog
    current <- catalog$version[match(out$dataset, catalog$dataset)]
    out$current <- ifelse(is.na(out$dataset), NA, !is.na(current) & out$version == current)
  }
  attr(out, "row.names") <- seq_len(nrow(out))
  out
}
