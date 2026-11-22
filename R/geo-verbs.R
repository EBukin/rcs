# Geospatial preparation as in-memory verbs (plan 0002, D26): the columns a
# write adds and a read returns, added to or removed from an `sf` object
# without reading or writing a store.

#' Add, index and strip the package's geospatial columns
#'
#' In-memory verbs that prepare an `sf` object the way [store_write()] does,
#' without contacting a store, and take a dataset read from a store back to
#' its raw form. They keep the row order and the column order of `x`; new
#' columns go immediately before the active geometry column.
#'
#' * `rcs_geo_add()` adds `h3` (class [rcs_h3]: the H3 cell at `h3_res`
#'   holding the largest part of each geometry), one `h3_p<r>` per
#'   resolution `r` in `parents` (the parent of `h3` at that resolution, for
#'   grouping and partitioning) and `bbox` (a data-frame column with `xmin`,
#'   `ymin`, `xmax`, `ymax` in the CRS of `x`). The values equal those a
#'   write with the same `h3_res` and `geocode_engine` computes, so prepared
#'   data can be written as they are.
#' * `rcs_geo_index()` gives the cells each geometry touches: one line per
#'   row and cell, as the index table of a dataset holds them, keyed by a
#'   column of `x` instead of the package's row identifier.
#' * `rcs_geo_strip()` removes the package's columns, so that a dataset read
#'   with `collect()` goes back to the form it was written from.
#'
#' Geometries invalid on the sphere are handled as in [store_write()] (see
#' its argument `geocode_engine`); one warning names their row numbers.
#'
#' @section Prepared writes:
#' [store_write()] accepts the result of `rcs_geo_add()`: it drops
#' `.rcs_id`, computes `h3` and `bbox` itself and compares them with the
#' supplied ones. Equal values are accepted silently, so that raw and
#' prepared writes of the same data give the same version; different
#' values abort (class `rcs_error_prepared`) naming the first rows and the
#' engine of the write. `h3_res` is taken from the supplied cells when the
#' write does not give it. The `h3_p<r>` columns are stored as user
#' columns; with `partition = "h3"`, one equal to the partition column the
#' write chooses serves as it.
#'
#' @section Round trip:
#' For `store_write(st, rcs_geo_add(raw), dataset, key = k)`,
#' `rcs_geo_strip(collect(store_open(st, dataset)))` ordered by `k` equals
#' `raw` ordered by `k`: the same attributes, identical WKB geometries and
#' the same CRS.
#'
#' @param x An `sf` object with a CRS.
#' @param h3_res H3 resolution of the cells, 0 to 15. For `rcs_geo_add()`,
#'   `NULL` adds no cell column.
#' @param bbox `TRUE` adds the column `bbox`.
#' @param parents Resolutions below `h3_res` to add as `h3_p<r>` columns, or
#'   `NULL`.
#' @param geocode_engine How the cells of geometries that cross cell edges
#'   are computed: `"auto"`, `"s2"` or `"planar"`, as in [store_write()].
#' @param replace A column that is already in `x` with other values aborts
#'   unless `replace = TRUE`, which recomputes it; one with equal values is
#'   kept.
#' @param id Name of the column of `x` that identifies its rows.
#' @param crossing_only `TRUE` lists only the rows that touch more than one
#'   cell (as a dataset's index table does); `FALSE` adds one line per other
#'   row, with its cell and `share = 1`.
#' @param columns Names of the columns to drop; `NULL` drops `.rcs_id`,
#'   `h3`, `h3_main`, `bbox`, every `h3_p<r>`, and `geom` unless it is the
#'   active geometry column.
#'
#' @return `rcs_geo_add()` and `rcs_geo_strip()`: `x` with the columns added
#'   or removed. `rcs_geo_index()`: a tibble with the column `id`, then `h3`
#'   (a cell the row touches), `h3_main` (the row's own cell; both
#'   [rcs_h3]) and `share` (the fraction of the row's area or length in that
#'   cell; `1 / n` for points), ordered by row of `x`, then cell.
#' @seealso [store_write()], which accepts prepared data and checks them;
#'   `vignette("geospatial")`.
#' @export
#' @examplesIf rlang::is_installed("h3o")
#' raw <- rcs_sim_polygons(20, seed = 1)
#'
#' prepared <- rcs_geo_add(raw, h3_res = 5, parents = 3)
#' prepared
#'
#' rcs_geo_index(raw, "id", h3_res = 5)
#'
#' identical(rcs_geo_strip(prepared), raw)
rcs_geo_add <- function(x, h3_res = 5L, bbox = TRUE, parents = NULL,
                        geocode_engine = c("auto", "s2", "planar"), replace = FALSE) {
  geo_verb_check_x(x)
  check_flag(bbox)
  check_flag(replace)
  geocode_engine <- if (missing(geocode_engine)) "auto" else check_geocode_engine(geocode_engine)
  if (!is.null(h3_res)) {
    h3_res <- check_h3_res(h3_res)
  }
  parents <- geo_verb_parents(parents, h3_res)

  g <- sf::st_geometry(x)
  added <- list()
  if (!is.null(h3_res)) {
    check_h3o()
    encoded <- geo_h3_rows(geo_to_4326(g), h3_res, geocode_engine)
    warn_geo_rebuild("{.arg x}", geo_verb_rows(encoded))
    h3 <- h3_hex_to_int64_raw(encoded$h3)
    added$h3 <- new_rcs_h3(h3)
    for (r in parents) {
      added[[paste0("h3_p", r)]] <- new_rcs_h3(h3_parent(h3, r))
    }
  }
  if (bbox) {
    added$bbox <- geo_bbox_df(g)
  }
  if (!replace) {
    for (name in intersect(names(added), names(x))) {
      if (!geo_same_values(x[[name]], added[[name]])) {
        cli::cli_abort(
          c(
            "{.arg x} already has a column {.field {name}} with other values.",
            i = "Use {.code replace = TRUE} to recompute it, or {.fn rcs_geo_strip} to remove it first."
          ),
          class = "rcs_error_prepared"
        )
      }
      added[[name]] <- NULL
    }
  }
  geo_put_columns(x, added)
}

#' @rdname rcs_geo_add
#' @export
rcs_geo_index <- function(x, id, h3_res = 5L, geocode_engine = c("auto", "s2", "planar"),
                          crossing_only = TRUE) {
  geo_verb_check_x(x)
  if (!rlang::is_string(id) || !id %in% names(x) || identical(id, attr(x, "sf_column"))) {
    cli::cli_abort(
      "{.arg id} must name one column of {.arg x} other than its geometry.",
      class = "rcs_error_argument"
    )
  }
  h3_res <- check_h3_res(h3_res)
  check_flag(crossing_only)
  geocode_engine <- if (missing(geocode_engine)) "auto" else check_geocode_engine(geocode_engine)
  check_h3o()
  encoded <- geo_h3_rows(geo_to_4326(sf::st_geometry(x)), h3_res, geocode_engine)
  warn_geo_rebuild("{.arg x}", geo_verb_rows(encoded))
  rows <- encoded$index
  row <- rows$row
  cell <- rows$cell
  share <- as.double(rows$share)
  if (!crossing_only) {
    inside <- setdiff(which(!is.na(encoded$h3)), row)
    row <- c(row, inside)
    cell <- c(cell, encoded$h3[inside])
    share <- c(share, rep(1, length(inside)))
  }
  sorted <- order(row, cell, method = "radix")
  row <- row[sorted]
  ids <- sf::st_drop_geometry(x)[[id]]
  out <- tibble::tibble(
    id = vctrs::vec_slice(ids, row),
    h3 = new_rcs_h3(h3_hex_to_int64_raw(cell[sorted])),
    h3_main = new_rcs_h3(h3_hex_to_int64_raw(encoded$h3[row])),
    share = share[sorted]
  )
  names(out)[[1]] <- id
  out
}

#' @rdname rcs_geo_add
#' @export
rcs_geo_strip <- function(x, columns = NULL) {
  if (!is.data.frame(x)) {
    cli::cli_abort(
      "{.arg x} must be a data frame or an {.cls sf} object, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument"
    )
  }
  active <- attr(x, "sf_column")
  if (is.null(columns)) {
    nm <- names(x)
    columns <- nm[nm %in% c(".rcs_id", "h3", "h3_main", "bbox") | grepl("^h3_p[0-9]+$", nm)]
    if ("geom" %in% nm && !identical(active, "geom")) {
      columns <- c(columns, "geom")
    }
  } else {
    if (!is.character(columns) || anyNA(columns)) {
      cli::cli_abort("{.arg columns} must be column names.", class = "rcs_error_argument")
    }
    unknown <- setdiff(columns, names(x))
    if (length(unknown) > 0) {
      cli::cli_abort(
        "{.arg x} has no column{?s} {.field {unknown}}.",
        class = "rcs_error_argument"
      )
    }
    if (!is.null(active) && active %in% columns) {
      cli::cli_abort(
        c(
          "{.field {active}} is the active geometry column of {.arg x}; it cannot be dropped.",
          i = "Use {.fn sf::st_drop_geometry} for that."
        ),
        class = "rcs_error_argument"
      )
    }
  }
  geo_drop_columns(x, columns)
}

# Helpers -------------------------------------------------------------------------

geo_verb_check_x <- function(x, call = caller_env()) {
  if (!inherits(x, "sf")) {
    cli::cli_abort(
      "{.arg x} must be an {.cls sf} object, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument", call = call
    )
  }
  if (is.na(sf::st_crs(x))) {
    geo_abort("{.arg x} has no coordinate reference system.", call = call)
  }
  invisible(x)
}

geo_verb_parents <- function(parents, h3_res, call = caller_env()) {
  if (length(parents) == 0) {
    return(integer())
  }
  if (is.null(h3_res)) {
    cli::cli_abort(
      "{.arg parents} needs cells: {.arg h3_res} must not be {.code NULL}.",
      class = "rcs_error_argument", call = call
    )
  }
  ok <- rlang::is_integerish(parents, finite = TRUE) && !anyNA(parents)
  if (!ok || any(parents < 0) || any(parents >= h3_res)) {
    bad <- if (ok) parents[parents < 0 | parents >= h3_res] else parents
    cli::cli_abort(
      c(
        "{.arg parents} must be whole numbers from 0 to {h3_res - 1} (below {.arg h3_res} = {h3_res}).",
        x = if (ok) "Not below {.arg h3_res}: {bad}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  unique(as.integer(parents))
}

# Row numbers rebuilt or geocoded in the plane, as the D32 warning names them.
geo_verb_rows <- function(encoded) {
  list(
    rebuilt = if (length(encoded$rebuilt)) paste("row", encoded$rebuilt) else character(),
    fallback = if (length(encoded$fallback)) paste("row", encoded$fallback) else character()
  )
}

# Equal values: cells as the same 64 bits (NA equal to NA), boxes as the same
# doubles.
geo_same_values <- function(old, new) {
  if (inherits(new, "integer64")) {
    return(inherits(old, "integer64") && geo_same_cells(old, new))
  }
  if (is.data.frame(new)) {
    return(is.data.frame(old) && identical(names(old), names(new)) && nrow(old) == nrow(new) &&
      all(vapply(names(new), function(n) {
        is.numeric(old[[n]]) && identical(as.double(old[[n]]), new[[n]])
      }, logical(1))))
  }
  identical(old, new)
}

# Element-wise: TRUE where two cell vectors hold the same cell or both NA.
geo_cells_equal <- function(a, b) {
  a <- rcs_h3_strip(a)
  b <- rcs_h3_strip(b)
  eq <- bit64::as.integer64(a) == bit64::as.integer64(b)
  both_na <- is.na(a) & is.na(b)
  out <- as.logical(eq)
  out[both_na] <- TRUE
  out[is.na(out)] <- FALSE
  out
}

geo_same_cells <- function(a, b) {
  length(a) == length(b) && all(geo_cells_equal(a, b))
}

# Puts named columns into an `sf` object, keeping its attributes: a column
# already there is replaced in place, a new one goes immediately before the
# active geometry column.
geo_put_columns <- function(x, columns) {
  if (length(columns) == 0) {
    return(x)
  }
  at <- attributes(x)
  values <- unclass(x)
  attributes(values) <- NULL
  names(values) <- at$names
  new <- setdiff(names(columns), at$names)
  for (name in intersect(names(columns), at$names)) {
    values[[name]] <- columns[[name]]
  }
  active <- at$sf_column
  pos <- match(active, at$names)
  nm <- c(at$names[seq_len(pos - 1L)], new, at$names[seq.int(pos, length(at$names))])
  values <- c(values, columns[new])[nm]
  at$names <- nm
  if (!is.null(at$agr)) {
    agr_names <- setdiff(nm, active)
    agr <- at$agr[match(agr_names, names(at$agr))]
    names(agr) <- agr_names
    at$agr <- agr
  }
  attributes(values) <- at
  values
}

# Drops columns of a data frame or `sf` object, keeping its attributes.
geo_drop_columns <- function(x, columns) {
  if (length(columns) == 0) {
    return(x)
  }
  at <- attributes(x)
  values <- unclass(x)
  attributes(values) <- NULL
  keep <- !at$names %in% columns
  values <- values[keep]
  at$names <- at$names[keep]
  if (!is.null(at$agr)) {
    at$agr <- at$agr[!names(at$agr) %in% columns]
  }
  attributes(values) <- at
  values
}
