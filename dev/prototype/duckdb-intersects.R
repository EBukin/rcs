# Prototype: store_intersects() on a DuckDB table.
#
#   store_open(st, "regions", engine = "duckdb") |>
#     store_intersects(cells_or_shape) |>
#     dplyr::collect()
#
# The same steps as on an Arrow query (R/intersects.R), written as SQL:
#   1-2. query shape and covering cells: `geo_covering()`, as for Arrow;
#   3.   files: the views already list the files of the version (pruning of
#        files by box and cell range is left to DuckDB's row-group skipping);
#   4.   candidate rows in SQL: `bbox` overlaps the query box, and, when the
#        cell filter pays off (`spatial_use_cells()`), `h3` in the covering
#        cells OR `.rcs_id` in the index view's rows for those cells;
#   5.   exact test:
#          exact = "sphere" (default): in collect(), sf::st_intersects() under
#                  sf_use_s2(), as the Arrow path does: same rows;
#          exact = "plane": ST_Intersects() in DuckDB (GEOS, planar), stays
#                  lazy, can differ from the sphere near long edges;
#          exact = "none": the candidate rows.
#
# Load after duckdb.R: `source("dev/prototype/duckdb-intersects.R")`.

proto_sql_num <- function(x) format(x, digits = 17, scientific = FALSE)

proto_duckdb_intersects <- function(q, y, exact = c("sphere", "plane", "none")) {
  exact <- rlang::arg_match(exact)
  info <- proto_rcs_get(q)
  if (is.null(info)) {
    cli::cli_abort("{.arg q} must be a DuckDB table made by {.code store_open(engine = \"duckdb\")}.")
  }
  st <- info$st
  entry <- catalog_entry(st$primary$catalog, info$dataset)
  covering <- geo_covering(y, entry$h3_res, entry$crs)
  con <- dbplyr::remote_con(q)

  conds <- character()
  if (!is.null(covering$bbox)) {
    b <- covering$bbox
    box <- sprintf("(bbox.xmin <= %s AND bbox.xmax >= %s AND bbox.ymin <= %s AND bbox.ymax >= %s)",
                   proto_sql_num(b[["xmax"]]), proto_sql_num(b[["xmin"]]),
                   proto_sql_num(b[["ymax"]]), proto_sql_num(b[["ymin"]]))
    if (geo_crs_is_longlat(entry$crs)) box <- sprintf("(%s OR bbox.xmax - bbox.xmin >= 180)", box)
    conds <- c(conds, box)
  }
  used_cells <- spatial_use_cells(covering)
  if (used_cells) {
    cells <- paste(as.character(covering$cells), collapse = ", ")
    idx <- index_name(info$dataset)
    cell_cond <- sprintf("h3 IN (%s)", cells)
    if (idx %in% st$primary$catalog$dataset) {
      nm <- proto_view_name(idx)
      cell_cond <- sprintf('(%s OR ".rcs_id" IN (SELECT ".rcs_id" FROM %s.%s WHERE h3 IN (%s)))',
                           cell_cond, proto_qid(con, nm[["schema"]]), proto_qid(con, nm[["table"]]), cells)
    }
    conds <- c(conds, cell_cond)
  }
  if (exact == "plane") {
    DBI::dbExecute(con, "INSTALL spatial; LOAD spatial;")
    geom <- if (identical(info$mode, "native")) "geometry" else "ST_GeomFromWKB(geometry)"
    conds <- c(conds, sprintf("ST_Intersects(%s, ST_GeomFromText(%s))", geom,
                              DBI::dbQuoteString(con, sf::st_as_text(covering$shape))))
  }
  if (length(conds)) q <- dplyr::filter(q, dbplyr::sql(!!paste(conds, collapse = " AND ")))
  info$tests <- c(info$tests, list(list(shape = covering$shape, exact = exact, cells = used_cells)))
  q <- proto_rcs_set(q, info)
  if (exact == "sphere" && !inherits(q, "rcs_duckdb_spatial")) class(q) <- c("rcs_duckdb_spatial", class(q))
  q
}

# collect(): the rows, geometry as sf, then the exact test on the sphere.
collect.rcs_duckdb_spatial <- function(x, ...) {
  info <- proto_rcs_get(x)
  class(x) <- setdiff(class(x), "rcs_duckdb_spatial")
  data <- dplyr::collect(x, ...)
  entry <- catalog_entry(info$st$primary$catalog, info$dataset)
  wkb <- data$geometry
  if (is.null(wkb)) return(data)
  data$geometry <- geo_wkb_to_sfc(lapply(wkb, as.raw), entry$crs)
  data <- sf::st_as_sf(data, sf_column_name = "geometry")
  keep <- rep(TRUE, nrow(data))
  for (t in info$tests) {
    if (t$exact != "sphere") next
    keep[keep] <- lengths(suppressMessages(sf::st_intersects(sf::st_geometry(data)[keep], t$shape))) > 0
  }
  data[keep, ]
}
registerS3method("collect", "rcs_duckdb_spatial", collect.rcs_duckdb_spatial, envir = asNamespace("dplyr"))

proto_store_intersects <- rcs:::store_intersects
store_intersects <- function(q, y, exact = TRUE) {
  if (inherits(q, "tbl_lazy")) {
    if (isTRUE(exact)) exact <- "sphere"
    if (isFALSE(exact)) exact <- "none"
    return(proto_duckdb_intersects(q, y, exact))
  }
  proto_store_intersects(q, y, exact)
}
