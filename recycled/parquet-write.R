# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: work package C, R/files.R (staging writer) and B, R/geo-encode.R (geo metadata).
#
# What it shows:
#   * an sf object written as Parquet with geometry as WKB in a binary column;
#   * dataset metadata stored in the Parquet key-value metadata;
#   * a GeoParquet `geo` footer that sf, GDAL, QGIS and DuckDB understand;
#   * column descriptions kept as JSON;
#   * sorting, zstd compression and a fixed number of rows per row group.
#
# What the plan changes (do these when adapting):
#   * one key `rcs` holding one JSON object replaces the flat metadata keys;
#     it must not contain the version, totals or any timestamp (plan, "Writing", step 7);
#   * `geo` becomes GeoParquet 1.1 with PROJJSON `crs` and the `covering` bbox struct;
#   * any CRS is accepted (the original accepted one CRS only);
#   * `bbox` is a struct column, not four flat columns;
#   * the file is written to a staging folder and named after the version;
#   * `key` is optional; duplicates abort with the first five offending values.

#' Write one staged Parquet file with embedded metadata
#'
#' @param x A data frame or an `sf` object, already sorted.
#' @param path File to write.
#' @param meta Named list of metadata values (dataset, title, description, ...).
#' @param columns Named character vector: column name to description.
#' @param rows_per_group Rows per Parquet row group.
#'
#' @return `path`, invisibly.
#' @noRd
files_write_parquet <- function(x, path, meta, columns = character(),
                                rows_per_group = 50000L) {
  if (inherits(x, "sf")) {
    geom <- sf::st_geometry(x)
    table <- arrow::arrow_table(sf::st_drop_geometry(x))
    table[["geometry"]] <- arrow::Array$create(
      unclass(sf::st_as_binary(geom)),
      type = arrow::binary()
    )
    meta$geo <- geo_metadata(geom)
  } else {
    table <- arrow::arrow_table(x)
  }

  meta$columns <- files_columns_json(table, columns)
  table <- table$ReplaceSchemaMetadata(meta)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(
    table, path,
    compression = "zstd",
    chunk_size = rows_per_group
  )
  invisible(path)
}

#' Column names, Arrow types and descriptions as a JSON array
#'
#' Columns without a description get `null`.
#' @noRd
files_columns_json <- function(table, columns = character()) {
  fields <- table$schema$fields
  name <- vapply(fields, \(f) f$name, character(1))
  as.character(jsonlite::toJSON(
    data.frame(
      name = name,
      type = vapply(fields, \(f) f$type$ToString(), character(1)),
      description = unname(columns[name])
    ),
    na = "null"
  ))
}

#' GeoParquet `geo` metadata for a geometry column
#'
#' Extend to version 1.1.0: add `crs` (PROJJSON, parsed, not a string) and
#' `covering` pointing at the `bbox` struct column. `digits = NA` keeps the
#' full precision of the bounding box.
#' @noRd
geo_metadata <- function(geom) {
  types <- sort(unique(as.character(sf::st_geometry_type(geom))))
  as.character(jsonlite::toJSON(
    list(
      version = "1.0.0",
      primary_column = "geometry",
      columns = list(geometry = list(
        encoding = "WKB",
        geometry_types = I(geo_type_names(types)),
        bbox = unname(as.numeric(sf::st_bbox(geom)))
      ))
    ),
    auto_unbox = TRUE, digits = NA
  ))
}

#' sf geometry type names to GeoParquet names
#' @noRd
geo_type_names <- function(types) {
  lookup <- c(
    POINT = "Point", LINESTRING = "LineString", POLYGON = "Polygon",
    MULTIPOINT = "MultiPoint", MULTILINESTRING = "MultiLineString",
    MULTIPOLYGON = "MultiPolygon", GEOMETRYCOLLECTION = "GeometryCollection"
  )
  unname(lookup[types])
}

#' Abort when the key columns do not identify rows
#' @noRd
check_key_unique <- function(x, key, dataset) {
  plain <- if (inherits(x, "sf")) sf::st_drop_geometry(x) else x
  if (anyDuplicated(plain[key]) > 0) {
    cli::cli_abort("{.val {dataset}}: key {.field {key}} is not unique.")
  }
  invisible(TRUE)
}

#' Order rows by one or more columns
#' @noRd
sort_rows <- function(x, by) {
  plain <- if (inherits(x, "sf")) sf::st_drop_geometry(x) else x
  x[do.call(order, unname(as.list(plain[by]))), ]
}
