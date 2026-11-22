# Prototype: a store in DuckDB with one call.
#
#   con <- store_duckdb(st)                # every dataset as a lazy view
#   dplyr::tbl(con, I("sales.daily"))      # dbplyr from there
#   store_open(st, "daily", engine = "duckdb")   # one dataset, same thing
#
# Every dataset becomes a VIEW named `<first part>.<rest>` (schema = first
# part of the dataset name, `/` in the rest replaced by `__`). A view stores
# no data: DuckDB reads the Parquet files when a query runs, and only the
# columns and row groups the query needs. The file list comes from the
# catalog held by the connection, so the folder or bucket is never listed and
# the views show the version the connection knows; `store_duckdb()` again
# after `store_refresh()` rebuilds them.
#
# Two ways for DuckDB to reach the files:
#   * mode = "arrow"  (default): the Arrow dataset the package already opens
#     is registered in DuckDB. DuckDB scans through Arrow's file system, so a
#     GCS location works with the credentials Arrow already uses; DuckDB
#     needs no credentials of its own. Filters and columns are pushed into
#     the Arrow scan.
#   * mode = "native": the view is `read_parquet([file list])` and DuckDB
#     reads the files itself. Fastest on a local folder; on GCS it needs a
#     DuckDB secret (see dev/prototype/auth.R).
#
# spatial = TRUE loads DuckDB's spatial extension and adds `geom`
# (GEOMETRY, from the WKB column) to the views of geospatial datasets.
#
# Load after `devtools::load_all()`: `source("dev/prototype/duckdb.R")`.

proto_view_name <- function(dataset) {
  parts <- strsplit(dataset, "/", fixed = TRUE)[[1]]
  if (length(parts) == 1) parts <- c("main", parts)
  c(schema = parts[[1]], table = paste(parts[-1], collapse = "__"))
}

proto_qid <- function(con, x) as.character(DBI::dbQuoteIdentifier(con, x))

proto_file_urls <- function(location, paths) {
  be <- location$backend
  if (inherits(be, "rcs_backend_gcs")) paste0("gs://", be$root, "/", paths) else file.path(be$root, paths)
}

store_duckdb <- function(st, con = NULL, datasets = NULL,
                         mode = c("arrow", "native"), spatial = FALSE) {
  validate_store(st)
  rlang::check_installed(c("duckdb", "DBI"), reason = "to query a store in DuckDB.")
  mode <- rlang::arg_match(mode)
  # BIGINT as integer64: H3 cells do not fit a double exactly.
  con <- con %||% DBI::dbConnect(duckdb::duckdb(), bigint = "integer64")
  if (spatial) DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")
  if (exists("proto_duckdb_h3")) proto_duckdb_h3(con)
  # Native mode on GCS: a bucket-scoped secret from the store's credential.
  if (mode == "native" && exists("proto_store_auth")) {
    for (loc in c(list(st$primary), st$secondary)) {
      be <- loc$backend
      if (inherits(be, "rcs_backend_gcs")) auth_duckdb_secret(proto_store_auth(be), con, be$bucket)
    }
  }
  catalog <- st$primary$catalog
  catalog <- catalog[catalog$kind != "raster", ]
  if (!is.null(datasets)) catalog <- catalog[catalog$dataset %in% datasets, ]

  made <- character()
  for (i in seq_len(nrow(catalog))) {
    dataset <- catalog$dataset[[i]]
    target <- read_target(st, dataset, NULL)
    name <- proto_view_name(dataset)
    schema <- proto_qid(con, name[["schema"]])
    view <- paste0(schema, ".", proto_qid(con, name[["table"]]))
    DBI::dbExecute(con, paste("CREATE SCHEMA IF NOT EXISTS", schema))

    source <- if (mode == "arrow") {
      ds <- query_open_files(target$location, target$files$path)
      reg <- paste0("rcs_arrow_", gsub("[^A-Za-z0-9]", "_", dataset))
      # Again on the same connection (refresh): replace the registration.
      try(duckdb::duckdb_unregister_arrow(con, reg), silent = TRUE)
      duckdb::duckdb_register_arrow(con, reg, ds)
      proto_qid(con, reg)
    } else {
      urls <- proto_file_urls(target$location, target$files$path)
      paste0("read_parquet([", paste(DBI::dbQuoteString(con, urls), collapse = ", "), "])")
    }
    geo <- spatial && identical(target$entry$kind, "geospatial")
    # In native mode with spatial loaded DuckDB already reads the GeoParquet
    # geometry column as GEOMETRY; in arrow mode it stays WKB (BLOB).
    select <- if (geo && mode == "arrow") "*, ST_GeomFromWKB(geometry) AS geom" else "*"
    DBI::dbExecute(con, paste0("CREATE OR REPLACE VIEW ", view, " AS SELECT ", select, " FROM ", source))
    made <- c(made, paste0(name[["schema"]], ".", name[["table"]]))
  }
  cli::cli_inform(c(
    v = "{length(made)} dataset{?s} available in DuckDB as view{?s} ({mode} mode, nothing read yet):",
    stats::setNames(paste0("{.code ", made, "}"), rep("*", length(made)))
  ))
  invisible(con)
}

# `store_open(engine = "duckdb")`: the dataset as a dbplyr table.
proto_store_open <- rcs:::store_open
store_open <- function(st, dataset, version = NULL, engine = c("arrow", "duckdb"),
                       con = NULL, mode = "arrow", spatial = FALSE) {
  engine <- rlang::arg_match(engine)
  if (engine == "arrow") return(proto_store_open(st, dataset, version))
  rlang::check_installed("dbplyr", reason = "to use a DuckDB table with dplyr verbs.")
  full <- resolve_dataset(st, dataset)
  con <- store_duckdb(st, con = con, datasets = c(full, index_name(full)), mode = mode, spatial = spatial) |>
    suppressMessages()
  name <- proto_view_name(full)
  out <- dplyr::tbl(con, DBI::Id(schema = name[["schema"]], table = name[["table"]]))
  # What store_intersects() needs to find the catalog entry again.
  proto_rcs_set(out, list(st = st, dataset = full, mode = mode))
}

# Package fields on a dbplyr table (dbplyr reserves `$`).
proto_rcs_get <- function(q) .subset2(q, "rcs")
proto_rcs_set <- function(q, value) {
  cls <- class(q); q <- unclass(q); q$rcs <- value; class(q) <- cls; q
}
