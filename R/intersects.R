# The spatial filter of reads (plan, "Reading", spatial filter), in five
# steps:
#
#   1. query shape: `geo_covering()` normalises it (sf, sfc, bbox, or H3
#      cells of any resolution), densified before any change of CRS;
#   2. covering cells at the dataset's `h3_res` plus their first ring
#      (`geo_covering()`);
#   3. file pruning: files whose `bbox` overlaps the query box and whose
#      `h3_min`-`h3_max` range holds a covering cell or the `h3_main` of a
#      matching index row;
#   4. candidate rows, pushed down to Arrow: (`h3` in the covering cells, or
#      `.rcs_id` among the index rows whose `h3` is in the covering cells)
#      and `bbox` overlapping the query box; the box test alone for data
#      written with `geocode = FALSE`;
#   5. exact test in `collect()`: `sf::st_intersects()` with the query shape
#      in the data CRS, under the user's `sf::sf_use_s2()` setting.
#
# Completeness: an inside row lies in its `h3` cell, so it can only intersect
# the query when that cell does, and the cell is then in the covering. A
# crossing row has an index row for every cell it touches. The box of a row
# holds the row, so the box test drops no intersecting row; the exception is
# a row across the antimeridian or around a pole, whose plain box of
# coordinates does not hold the shape read on the sphere: in a geographic
# CRS a row (or file) whose box spans 180 degrees of longitude or more always
# passes the box test. A query of that kind has no box (`geo_covering()`),
# and the box test is skipped.

#' Add a spatial filter to a lazy query
#'
#' Keeps the rows of a geospatial dataset whose geometry intersects `y`. The
#' filter first prunes files by their extent and H3 cell range, then pushes a
#' candidate test on the stored H3 cells (`h3`, and the dataset's index
#' table for rows that cross cell edges) and bounding boxes (`bbox`) into the
#' scan, and finally, in `collect()`, tests the candidate rows exactly with
#' [sf::st_intersects()] under the session's [sf::sf_use_s2()] setting.
#'
#' The filter applies to the rows of the dataset, before the other verbs of
#' the query. Several calls combine: a row must intersect every query.
#'
#' @param q A query made by [store_open()] on a geospatial dataset.
#' @param y The query: an `sf`, `sfc` or `bbox` object with a coordinate
#'   reference system (in any CRS; several geometries are combined), or H3
#'   cells of any resolution as hex strings, `bit64::integer64` or `h3o`
#'   `H3` vectors, which stand for their cell polygons. A plain number
#'   aborts: it cannot hold an H3 cell.
#' @param exact `TRUE` runs the exact test in `collect()`. `FALSE` returns
#'   the candidate rows, a superset of the intersecting rows, with a
#'   message saying so. The candidate set is also returned, with the same
#'   message, when the geometry is not collected.
#' @return The query with the filter added.
#' @seealso [store_read()], whose `intersects` argument does the same.
#' @export
#' @examples
#' location <- file.path(tempdir(), "rcs-example-intersects")
#' st <- store_connect(location, create = TRUE)
#' store_write(st, rcs_sim_polygons(200), "shapes/polygons",
#'   title = "Polygons", description = "Simulated polygons in open ocean."
#' )
#' area <- sf::st_as_sfc(sf::st_bbox(
#'   c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
#'   crs = sf::st_crs(4326)
#' ))
#' store_open(st, "polygons") |>
#'   store_intersects(area) |>
#'   dplyr::collect()
#' unlink(location, recursive = TRUE)
store_intersects <- function(q, y, exact = TRUE) {
  local_trace("store_intersects")
  validate_query(q)
  check_flag(exact)
  query_intersects(q, y, exact, call = rlang::current_env())
}

#' Apply the spatial filter to a query
#'
#' Steps 1 to 4, and the state for step 5 in `q$spatial`:
#' `list(tests = list(list(shape, exact, bbox, cells, ids, geographic)),
#' cells = <number of covering cells>, index = <TRUE when index rows were
#' used>)`, one element of `tests` per call.
#'
#' @param q An `rcs_query`.
#' @param y The query shape.
#' @param exact `TRUE` or `FALSE`.
#' @param call Environment for errors.
#' @return The query.
#' @noRd
query_intersects <- function(q, y, exact = TRUE, call = caller_env()) {
  entry <- q$entry
  if (!identical(entry$kind, "geospatial")) {
    cli::cli_abort(
      c(
        "A spatial filter needs a geospatial dataset.",
        x = "{.val {entry$dataset}} is a {entry$kind}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (is.null(y)) {
    cli::cli_abort("{.arg intersects} must be a query shape or H3 cells, not {.code NULL}.",
      class = "rcs_error_argument", call = call
    )
  }
  covering <- rlang::try_fetch(
    geo_covering(y, entry$h3_res, entry$crs),
    rcs_error_h3_input = function(e) {
      cli::cli_abort(
        "{.arg intersects} must be an {.cls sf}, {.cls sfc} or {.cls bbox} object, or H3 cells.",
        class = c("rcs_error_h3_input", "rcs_error_argument"), parent = e, call = call
      )
    }
  )
  geographic <- isTRUE(sf::st_is_longlat(sf::st_crs(entry$crs)))
  cells <- covering$cells
  ids <- NULL
  if (!is.null(cells)) {
    index <- spatial_index_rows(q, cells)
    if (is.null(index)) {
      # no index table usable for this version: the box test alone is complete
      cells <- NULL
    } else {
      ids <- index
    }
  }
  test <- list(
    shape = covering$shape, exact = exact, bbox = covering$bbox,
    cells = cells, ids = ids$.rcs_id, geographic = geographic
  )

  q <- query_set_files(q, q$files[spatial_keep_files(q$files, test, ids$h3_main), ])
  predicate <- spatial_predicate(test)
  if (!is.null(predicate)) {
    q <- query_bottom_filter(q, predicate)
  }
  previous <- q$spatial
  q$spatial <- list(
    tests = c(previous$tests, list(test)),
    cells = sum(previous$cells, length(cells)),
    index = isTRUE(previous$index) || length(test$ids) > 0
  )
  q
}

#' Rows of the index table matching the covering cells
#'
#' @param q An `rcs_query` on a geocoded dataset.
#' @param cells `integer64` covering cells.
#' @return A tibble with `.rcs_id` and `h3_main` (`integer64`) of the index
#'   rows whose `h3` is in `cells`, zero rows when the dataset has no index
#'   table (no row crosses a cell edge); `NULL` when the query reads an
#'   earlier version, whose index table cannot be matched to it (the caller
#'   then uses the box test alone).
#' @noRd
spatial_index_rows <- function(q, cells) {
  location <- q$location
  catalog <- location$catalog
  dataset <- q$entry$dataset
  current <- catalog$version[catalog$dataset == dataset]
  if (length(current) != 1 || !identical(current, q$entry$version)) {
    return(NULL)
  }
  none <- tibble::tibble(.rcs_id = bit64::integer64(), h3_main = bit64::integer64())
  index <- catalog[catalog$dataset == index_name(dataset), ]
  if (nrow(index) == 0) {
    return(none)
  }
  files <- files_lookup(location, index$dataset, index$version, st = q$store)
  files <- files[cells_in_ranges(cells, files$h3_min, files$h3_max), ]
  if (nrow(files) == 0) {
    return(none)
  }
  withr::local_options(arrow.int64_downcast = FALSE)
  for (path in files$path) {
    trace_count("file_open", 1, location = location$uri, detail = path)
  }
  source <- query_open_files(location, files$path)
  in_cells <- spatial_predicate(list(cells = cells))
  rows <- dplyr::collect(dplyr::select(dplyr::filter(source, !!in_cells), ".rcs_id", "h3_main"))
  rows <- tibble::as_tibble(rows)
  rows[!duplicated(as.character(rows$.rcs_id)), ]
}

# For each range [lo, hi] (integer64, NA for none), whether any of `values`
# lies in it.
cells_in_ranges <- function(values, lo, hi) {
  if (length(values) == 0) {
    return(rep(FALSE, length(lo)))
  }
  values <- sort(values)
  vapply(seq_along(lo), function(i) {
    if (is.na(lo[[i]]) || is.na(hi[[i]])) {
      return(FALSE)
    }
    any(values >= lo[[i]] & values <= hi[[i]])
  }, logical(1))
}

# Step 3: which file rows can hold rows matching `test`.
spatial_keep_files <- function(files, test, h3_main = NULL) {
  keep <- rep(TRUE, nrow(files))
  if (!is.null(test$bbox)) {
    keep <- keep & box_overlaps(files$bbox, test$bbox, test$geographic)
  }
  if (!is.null(test$cells)) {
    by_cell <- cells_in_ranges(test$cells, files$h3_min, files$h3_max)
    by_index <- cells_in_ranges(h3_main, files$h3_min, files$h3_max)
    keep <- keep & (by_cell | by_index)
  }
  keep
}

# Boxes (a `bbox_df()`) overlapping the query box `q` (named double); boxes
# 180 degrees wide or more always pass in a geographic CRS; `NA` boxes
# (empty geometries only) never do.
box_overlaps <- function(box, q, geographic) {
  overlap <- box$xmin <= q[["xmax"]] & box$xmax >= q[["xmin"]] &
    box$ymin <= q[["ymax"]] & box$ymax >= q[["ymin"]]
  if (geographic) {
    overlap <- overlap | (box$xmax - box$xmin >= 180)
  }
  overlap[is.na(overlap)] <- FALSE
  overlap
}

# Step 4: the candidate predicate as an Arrow expression on the stored
# columns, or `NULL` when there is nothing to test (no cells and no box).
# Built directly as an expression: translating the same test from R code
# costs tens of milliseconds per call.
spatial_predicate <- function(test) {
  E <- arrow::Expression
  call <- function(fn, ...) E$create(fn, ...)
  is_in <- function(column, values) {
    call("is_in", E$field_ref(column),
      options = list(value_set = arrow::Array$create(values), skip_nulls = TRUE)
    )
  }
  field <- function(name) {
    call("struct_field", E$field_ref("bbox"), options = list(field_ref = E$field_ref(name)))
  }
  cell_test <- NULL
  if (!is.null(test$cells)) {
    cell_test <- is_in("h3", test$cells)
    if (length(test$ids) > 0) {
      cell_test <- call("or_kleene", cell_test, is_in(".rcs_id", test$ids))
    }
  }
  box_test <- NULL
  if (!is.null(test$bbox)) {
    b <- test$bbox
    box_test <- call(
      "and_kleene",
      call(
        "and_kleene",
        call("less_equal", field("xmin"), E$scalar(b[["xmax"]])),
        call("greater_equal", field("xmax"), E$scalar(b[["xmin"]]))
      ),
      call(
        "and_kleene",
        call("less_equal", field("ymin"), E$scalar(b[["ymax"]])),
        call("greater_equal", field("ymax"), E$scalar(b[["ymin"]]))
      )
    )
    if (test$geographic) {
      wide <- call("greater_equal", call("subtract", field("xmax"), field("xmin")), E$scalar(180))
      box_test <- call("or_kleene", wide, box_test)
    }
  }
  if (!is.null(cell_test) && !is.null(box_test)) {
    return(call("and_kleene", cell_test, box_test))
  }
  cell_test %||% box_test
}

#' Step 5: the exact test on collected rows
#'
#' Counts `rows_candidate`. With every test exact and the geometry read,
#' keeps the rows that intersect every query shape; otherwise returns the
#' candidate rows and informs that they are a candidate set.
#'
#' @param q The `rcs_query`.
#' @param data The rows, after `rows_finish()`.
#' @return `data`, filtered.
#' @noRd
spatial_exact <- function(q, data) {
  if (is.null(q$spatial)) {
    return(data)
  }
  trace_count("rows_candidate", nrow(data), location = q$location$uri)
  tests <- q$spatial$tests
  exact <- all(vapply(tests, function(t) isTRUE(t$exact), logical(1)))
  has_geometry <- inherits(data, "sf") && identical(attr(data, "sf_column"), "geometry")
  if (!exact || !has_geometry) {
    why <- if (!exact) "{.code exact = FALSE}" else "the geometry is not read"
    rcs_inform(c(
      i = paste0("Spatial filter: ", why, ", so the result is the candidate set."),
      " " = "It holds every intersecting row and may hold rows that do not intersect the query."
    ))
    return(data)
  }
  geometry <- sf::st_geometry(data)
  keep <- rep(TRUE, nrow(data))
  for (test in tests) {
    if (!any(keep)) {
      break
    }
    hits <- suppressMessages(sf::st_intersects(geometry[keep], test$shape))
    keep[keep] <- lengths(hits) > 0
  }
  data[keep, ]
}

# Whether collecting `q` runs an exact test, which needs the geometry.
spatial_needs_geometry <- function(q) {
  !is.null(q$spatial) && isTRUE(q$geometry) &&
    all(vapply(q$spatial$tests, function(t) isTRUE(t$exact), logical(1)))
}

# Put the stored geometry back into a query that selected it away, when the
# query is a single select-and-filter step over the source; otherwise return
# it unchanged (the exact test is then not possible).
query_borrow_geometry <- function(query) {
  if (!inherits(query, "arrow_dplyr_query") || inherits(query$.data, "arrow_dplyr_query") ||
    !"geometry" %in% names(query$.data$schema)) {
    return(query)
  }
  query$selected_columns$geometry <- arrow::Expression$field_ref("geometry")
  query
}

# Row groups of the scanned files whose minimum and maximum of `h3`,
# `.rcs_id` and `bbox` overlap the candidate predicate of every test: the
# row groups that statistics-based pruning has to read. Arrow's R interface
# does not expose Parquet row-group statistics, so they are computed here
# from the columns themselves (only when tracing).
spatial_row_groups_overlap <- function(q) {
  be <- q$location$backend
  fs <- be_arrow_fs(be)
  tests <- q$spatial$tests
  wanted <- c("h3", ".rcs_id", "bbox")
  total <- 0
  for (path in q$files$path) {
    file <- fs$fs$OpenInputFile(paste0(fs$path, "/", path))
    reader <- arrow::ParquetFileReader$create(file)
    schema <- reader$GetSchema()
    columns <- intersect(wanted, names(schema))
    leaves <- parquet_leaf_indices(schema, columns)
    for (g in seq_len(reader$num_row_groups) - 1L) {
      stats <- withr::with_options(
        list(arrow.int64_downcast = FALSE),
        as.data.frame(reader$ReadRowGroup(g, leaves))
      )
      if (all(vapply(tests, row_group_overlaps, logical(1), stats = stats))) {
        total <- total + 1
      }
    }
    file$close()
  }
  total
}

row_group_overlaps <- function(test, stats) {
  ok <- TRUE
  if (!is.null(test$bbox) && "bbox" %in% names(stats)) {
    box <- stats$bbox
    if (all(is.na(box$xmin))) {
      return(FALSE)
    }
    group_box <- bbox_df(
      min(box$xmin, na.rm = TRUE), min(box$ymin, na.rm = TRUE),
      max(box$xmax, na.rm = TRUE), max(box$ymax, na.rm = TRUE)
    )
    wide <- test$geographic && any(box$xmax - box$xmin >= 180, na.rm = TRUE)
    ok <- wide || box_overlaps(group_box, test$bbox, test$geographic)
  }
  if (ok && !is.null(test$cells)) {
    range_of <- function(x) {
      x <- x[!is.na(x)]
      if (length(x) == 0) list(bit64::NA_integer64_, bit64::NA_integer64_) else list(min(x), max(x))
    }
    h3 <- range_of(stats$h3)
    id <- range_of(stats$.rcs_id)
    ok <- cells_in_ranges(test$cells, h3[[1]], h3[[2]]) ||
      cells_in_ranges(test$ids, id[[1]], id[[2]])
  }
  ok
}

spatial_describe <- function(spatial) {
  tests <- spatial$tests
  n <- length(tests)
  exact <- all(vapply(tests, function(t) isTRUE(t$exact), logical(1)))
  cells <- vapply(tests, function(t) !is.null(t$cells), logical(1))
  boxes <- vapply(tests, function(t) !is.null(t$bbox), logical(1))
  parts <- c(
    paste0(n, if (n == 1) " query" else " queries"),
    if (any(cells)) "cell filter" else "no cell filter",
    if (any(boxes)) "box test",
    if (exact) "exact test in collect()" else "candidate set (exact = FALSE)"
  )
  paste(parts, collapse = ", ")
}
