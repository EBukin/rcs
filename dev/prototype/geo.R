# Prototype: geospatial preparation as transformations, without reading or
# writing a store.
#
#   prepared <- raw |> geo_add(h3_res = 7, parents = 3)   # adds h3, bbox, h3_p3
#   index    <- geo_index(prepared, id = "id")             # rows x cells crossed
#   back     <- geo_strip(prepared)                        # identical to raw
#
# The added columns are exactly the ones a write adds and a read returns, so
# the same data can travel either way:
#   raw --geo_add()--> deploy-ready --store_write()--> store
#   store --store_open() |> collect()--> deploy-ready --geo_strip()--> raw
#
# Row order is kept (a write sorts rows by h3; these verbs do not).
#
# Load after `devtools::load_all()`: `source("dev/prototype/geo.R")`.

proto_geo_columns <- function(x) {
  nm <- names(x)
  nm[nm %in% c(".rcs_id", "h3", "h3_main", "bbox", "geom") | grepl("^h3_p[0-9]+$", nm)]
}

#' Add the package's geospatial columns to an sf object
#'
#' @param x An `sf` object with a CRS.
#' @param h3_res Resolution of the `h3` cell (the cell holding the largest
#'   part of each geometry), 0 to 15. `NULL` adds no `h3`.
#' @param bbox `TRUE` adds `bbox`: a data-frame column with `xmin`, `ymin`,
#'   `xmax`, `ymax` in the CRS of `x`.
#' @param parents Resolutions coarser than `h3_res` to add as `h3_p<r>`
#'   (the parent of `h3`, for grouping and partitioning).
#' @param replace `TRUE` recomputes columns that are already there; `FALSE`
#'   (default) aborts when one is there with other values.
geo_add <- function(x, h3_res = 5L, bbox = TRUE, parents = NULL, replace = FALSE) {
  stopifnot(inherits(x, "sf"), !is.na(sf::st_crs(x)))
  g <- sf::st_geometry(x)
  if (!is.null(h3_res)) {
    check_h3o()
    h3 <- h3_hex_to_int64_raw(geo_h3_rows(geo_to_4326(g), check_h3_res(h3_res))$h3)
    cls <- if (exists("new_rcs_h3")) new_rcs_h3 else identity
    x <- proto_put(x, "h3", cls(h3), replace)
    for (r in parents) {
      x <- proto_put(x, paste0("h3_p", r), cls(h3_parent(h3, r)), replace)
    }
  }
  if (bbox) x <- proto_put(x, "bbox", geo_bbox_df(g), replace)
  sf::st_set_geometry(x[, c(setdiff(names(x), attr(x, "sf_column")), attr(x, "sf_column"))], attr(x, "sf_column"))
}

proto_put <- function(x, name, value, replace) {
  if (name %in% names(x) && !replace && !identical(unclass(x[[name]]), unclass(value))) {
    cli::cli_abort(c(
      "{.field {name}} is already in {.arg x}, with other values.",
      i = "Use {.code replace = TRUE} to recompute it, or {.fn geo_strip} first."
    ))
  }
  x[[name]] <- value
  x
}

#' Cells each row touches: the index table, keyed by a column of x
#'
#' @param id Column of `x` that identifies rows.
#' @param h3_res Resolution of the cells.
#' @param crossing_only `TRUE` (as written to a store) keeps only rows
#'   that touch more than one cell.
geo_index <- function(x, id, h3_res = 5L, crossing_only = TRUE) {
  stopifnot(inherits(x, "sf"), id %in% names(x))
  encoded <- geo_h3_rows(geo_to_4326(sf::st_geometry(x)), check_h3_res(h3_res))
  rows <- encoded$index
  out <- tibble::tibble(
    !!id := x[[id]][rows$row],
    h3 = h3_hex_to_int64_raw(rows$cell),
    h3_main = h3_hex_to_int64_raw(encoded$h3[rows$row]),
    share = rows$share
  )
  if (!crossing_only) {
    # rows inside one cell: one line, share 1
    inside <- setdiff(seq_len(nrow(x)), rows$row)
    out <- rbind(out, tibble::tibble(
      !!id := x[[id]][inside],
      h3 = h3_hex_to_int64_raw(encoded$h3[inside]),
      h3_main = h3_hex_to_int64_raw(encoded$h3[inside]), share = 1
    ))
  }
  out
}

#' Remove the package's geospatial columns
#'
#' Drops `.rcs_id`, `h3`, `h3_main`, `bbox`, `geom` and `h3_p<r>`, so a
#' dataset read from a store goes back to its raw form.
geo_strip <- function(x, columns = NULL) {
  drop <- columns %||% proto_geo_columns(x)
  x[, setdiff(names(x), drop), drop = FALSE]
}

# Writing prepared data. The released `store_write()` aborts on a column
# named `h3` or `bbox`. Prototype: check the columns against a recompute,
# drop them and let the write add them again; the plan would let the write
# reuse them instead of recomputing.
proto_store_write <- rcs:::store_write
store_write <- function(st, x, dataset, ..., h3_res = NULL) {
  if (inherits(x, "sf") && length(proto_geo_columns(x)) > 0) {
    if ("h3" %in% names(x)) {
      res <- unique(stats::na.omit(as.integer(substr(h3_int64_to_hex_raw(x$h3), 2, 2))))
      h3_res <- h3_res %||% strtoi(as.character(res), 16L)
    }
    cli::cli_inform("Prepared columns found ({.field {proto_geo_columns(x)}}); written as computed by the package.")
    # Parent columns h3_p<r> are kept and written; h3, bbox and .rcs_id are
    # recomputed by the write.
    x <- geo_strip(x, columns = intersect(c(".rcs_id", "h3", "h3_main", "bbox", "geom"), names(x)))
  }
  proto_store_write(st, x, dataset, ..., h3_res = h3_res %||% 5L)
}
