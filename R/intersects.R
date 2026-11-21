# The spatial filter of reads (plan, "Reading", spatial filter), in five
# steps:
#
#   1. query shape: `geo_covering()` normalises it (sf, sfc, bbox, or H3
#      cells of any resolution), densified before any change of CRS;
#   2. covering cells at the dataset's `h3_res` plus their first ring
#      (`geo_covering()`);
#   3. file pruning: files whose `bbox` overlaps the query box and, when the
#      cell filter is used, whose `h3_min`-`h3_max` range holds a covering
#      cell or the `h3_main` of a matching index row;
#   4. candidate rows, pushed down to Arrow: `bbox` overlapping the query
#      box, and, when the cell filter is used, (`h3` in the covering cells,
#      or `.rcs_id` among the index rows whose `h3` is in the covering
#      cells);
#   5. exact test in `collect()`: `sf::st_intersects()` with the query shape
#      in the data CRS, under the user's `sf::sf_use_s2()` setting.
#
# The cell filter (with the index table) is used only where it pays off
# (`spatial_use_cells()`): when the query has no box (across the antimeridian
# or around a pole), and when the query's box is much larger than the query
# (a thin diagonal strip, a line). For compact queries the box test alone
# leaves as few candidate rows, and reading the index table costs more than
# it saves (work package M, `vignettes/articles/benchmark-spatial.Rmd`).
#
# Completeness: the box of a row holds the row, so the box test drops no
# intersecting row; the exception is a row across the antimeridian or around
# a pole, whose plain box of coordinates does not hold the shape read on the
# sphere: in a geographic CRS a row (or file) whose box spans 180 degrees of
# longitude or more always passes the box test. A query of that kind has no
# box (`geo_covering()`), and the box test is skipped. When the cell filter
# is used: an inside row lies in its `h3` cell, so it can only intersect the
# query when that cell does, and the cell is then in the covering; a crossing
# row has an index row for every cell it touches.

#' Add a spatial filter to a lazy query
#'
#' Keeps the rows of a geospatial dataset whose geometry intersects `y`. The
#' filter first prunes files by their extent, then pushes a candidate test
#' on the stored bounding boxes (`bbox`) into the scan, and finally, in
#' `collect()`, tests the candidate rows exactly with [sf::st_intersects()]
#' under the session's [sf::sf_use_s2()] setting. When the box of `y` is
#' much larger than `y` itself (a thin diagonal strip, a line), or `y`
#' crosses the antimeridian or holds a pole, files are also pruned by their
#' H3 cell range and the candidate test also requires the stored H3 cell
#' (`h3`, and the dataset's index table for rows that cross cell edges) to
#' touch `y`.
#'
#' The filter applies to the rows of the dataset, before the other verbs of
#' the query. Several calls combine: a row must intersect every query.
#'
#' @param q A query made by [store_open()] on a geospatial dataset.
#' @param y The query: an `sf`, `sfc` or `bbox` object with a coordinate
#'   reference system (in any CRS; several geometries are combined), or H3
#'   cells of any resolution as hex strings, `bit64::integer64` or `h3o`
#'   `H3` vectors, which stand for their cell polygons. A plain number
#'   aborts: it cannot hold an H3 cell. The geometries of an `sf` or `sfc`
#'   query must be valid, or the call aborts with the reason and advice to
#'   repair them with [sf::st_make_valid()] (only the query is checked). The
#'   check reads them as the exact test does: on the sphere (s2) when the
#'   query is in the data's geographic CRS and [sf::sf_use_s2()] is on, in
#'   the plane otherwise.
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
#' @param plan `NULL`, or the result of `spatial_plan()` for `y` and
#'   `exact`, computed on the files of the read target before the query was
#'   built (`query_new()`).
#' @return The query.
#' @noRd
query_intersects <- function(q, y, exact = TRUE, call = caller_env(), plan = NULL) {
  if (is.null(plan)) {
    plan <- spatial_plan(q, y, exact, call = call)
  }
  test <- plan$test
  q <- query_set_files(q, q$files[q$files$path %in% plan$paths, ])
  predicate <- spatial_predicate(test)
  if (!is.null(predicate)) {
    q <- query_bottom_filter(q, predicate)
  }
  previous <- q$spatial
  q$spatial <- list(
    tests = c(previous$tests, list(test)),
    cells = sum(previous$cells, length(test$cells)),
    index = isTRUE(previous$index) || length(test$ids) > 0
  )
  q
}

#' Steps 1 to 3 of the spatial filter
#'
#' @param q An `rcs_query`, or a list with its fields `store`, `entry`,
#'   `location` and `files` (a read target before its query is built).
#' @inheritParams query_intersects
#' @return A list: `test` (the element of `q$spatial$tests`) and `paths`
#'   (the paths of the files of `q$files` kept by the file pruning).
#' @noRd
spatial_plan <- function(q, y, exact = TRUE, call = caller_env()) {
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
  check_query_valid(y, entry$crs, call = call)
  covering <- rlang::try_fetch(
    geo_covering(y, entry$h3_res, entry$crs),
    rcs_error_h3_input = function(e) {
      cli::cli_abort(
        "{.arg intersects} must be an {.cls sf}, {.cls sfc} or {.cls bbox} object, or H3 cells.",
        class = c("rcs_error_h3_input", "rcs_error_argument"), parent = e, call = call
      )
    }
  )
  geographic <- geo_crs_is_longlat(entry$crs)
  cells <- if (spatial_use_cells(covering)) covering$cells
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

  keep <- spatial_keep_files(q$files, test, ids$h3_main)
  list(test = test, paths = q$files$path[keep])
}

#' Abort when the query shape is not a valid geometry
#'
#' Checks the geometries of an `sf` or `sfc` query (never the data) in the
#' notion of validity the exact test uses: on the sphere (s2) when the query
#' is in the data CRS, that CRS is geographic and [sf::sf_use_s2()] is on;
#' in the plane otherwise (a query in another CRS is densified along its
#' straight edges before its change of CRS, `geo_covering()`, so its edges
#' are read in the plane). A `bbox` is a rectangle and H3 cells are cell
#' polygons: neither is checked. Empty geometries are valid.
#'
#' @param y The query.
#' @param crs The data CRS (`entry$crs`).
#' @param call Environment for errors.
#' @return `NULL`, invisibly; aborts with class `rcs_error_argument`.
#' @noRd
check_query_valid <- function(y, crs, call = caller_env()) {
  if (!inherits(y, c("sf", "sfc"))) {
    return(invisible(NULL))
  }
  g <- sf::st_geometry(y)
  if (length(g) == 0 || is.na(sf::st_crs(g))) {
    # left to `geo_covering()`, which aborts for an empty shape or no CRS
    return(invisible(NULL))
  }
  target <- geo_crs_from_json(crs)
  sphere <- sf::st_crs(g) == target && isTRUE(sf::st_is_longlat(g)) &&
    suppressMessages(sf::sf_use_s2())
  reason <- if (sphere) {
    s2::s2_is_valid_detail(g)$reason
  } else {
    sf::st_is_valid(sf::st_set_crs(g, sf::NA_crs_), reason = TRUE)
  }
  bad <- which(!is.na(reason) & reason != "Valid Geometry")
  if (length(bad) == 0) {
    return(invisible(NULL))
  }
  where <- if (length(g) > 1) paste0(" (geometry ", bad[[1]], ")") else ""
  notion <- if (sphere) "on the sphere (s2)" else "in the plane"
  cli::cli_abort(
    c(
      "The query geometry is not valid {notion}.",
      x = "{reason[[bad[[1]]]]}{where}.",
      i = "Repair it with {.fn sf::st_make_valid}."
    ),
    class = "rcs_error_argument", call = call
  )
}

#' Whether the cell filter pays off for a query
#'
#' The cell filter (the covering cells and the rows of the index table) is
#' used when the query has cells and no box (the box test is then skipped),
#' and when the area of the query's box is more than `spatial_cell_ratio`
#' times the area of the query: the box test alone would then leave many
#' rows that lie in the box but far from the query. A query without area
#' (a line) has a box of positive area and uses it; a point or a box-shaped
#' query does not.
#'
#' @param covering The result of `geo_covering()`.
#' @return `TRUE` or `FALSE`.
#' @noRd
spatial_use_cells <- function(covering) {
  if (is.null(covering$cells)) {
    return(FALSE)
  }
  if (is.null(covering$bbox)) {
    return(TRUE)
  }
  b <- covering$bbox
  if (!(b[["xmax"]] > b[["xmin"]] && b[["ymax"]] > b[["ymin"]])) {
    return(FALSE)
  }
  # areas in the plane of the data CRS coordinates (degrees in a geographic
  # CRS): only their ratio matters, and the plane is fast
  box_area <- (b[["xmax"]] - b[["xmin"]]) * (b[["ymax"]] - b[["ymin"]])
  shape_area <- sum(as.numeric(sf::st_area(sf::st_set_crs(covering$shape, NA))))
  !(shape_area * spatial_cell_ratio >= box_area)
}

# Above this ratio of box area to query area the cell filter is used.
spatial_cell_ratio <- 4

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
    group_box <- bbox_extent(box)
    wide <- test$geographic && any(box$xmax - box$xmin >= 180, na.rm = TRUE)
    ok <- wide || box_overlaps(group_box, test$bbox, test$geographic)
  }
  if (ok && !is.null(test$cells)) {
    h3 <- cell_range(stats$h3)
    id <- cell_range(stats$.rcs_id)
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
