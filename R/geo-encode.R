# Geospatial encoding: identifiers, geocodes, bounding boxes, WKB, the written
# order, index-table rows, GeoParquet metadata, decoding, cells touched and
# the covering of a query shape.
#
# Geometry rules (see the plan, "Geospatial encoding"):
#   * Cells are computed on a copy in EPSG:4326, on the sphere (s2): a cell
#     polygon and a geometry intersect when s2 says so.
#   * Inside rows: the four corners of the row's box (EPSG:4326) fall in one
#     cell, and so do the extra points along the box edge nearest the equator
#     that the edge's curvature requires (`geo_edge_points()`); the row lies in
#     that cell. Every other non-empty row is a crossing row.
#   * Rows whose box is at least 180 degrees wide cross the antimeridian or
#     hold a pole (a ring around a pole always spans 180 degrees of longitude
#     or more); their cells are found by descending the H3 hierarchy on the
#     sphere (`geo_touched_sphere()`), which needs no planar part at all.
#   * Inside the package cells travel as 15-character hex strings while they
#     are computed (strings of one resolution sort like the cells' integers)
#     and leave as `integer64`.

# Small helpers ---------------------------------------------------------------

geo_abort <- function(message, call = caller_env(), .envir = parent.frame()) {
  cli::cli_abort(message, class = "rcs_error_geo", call = call, .envir = .envir)
}

check_h3_res <- function(h3_res, call = caller_env()) {
  if (!rlang::is_scalar_integerish(h3_res, finite = TRUE) || h3_res < 0 || h3_res > 15) {
    cli::cli_abort(
      "{.arg h3_res} must be one whole number from 0 to 15, not {.obj_type_friendly {h3_res}}.",
      class = "rcs_error_argument", call = call
    )
  }
  as.integer(h3_res)
}

geo_crs_json <- function(crs) {
  sf::st_crs(crs)$ProjJson
}

geo_crs_from_json <- function(crs, call = caller_env()) {
  out <- tryCatch(sf::st_crs(crs), error = function(e) sf::NA_crs_)
  if (is.na(out)) {
    geo_abort("{.arg crs} must be a coordinate reference system (PROJJSON).", call = call)
  }
  out
}

geo_to_4326 <- function(g) {
  if (sf::st_crs(g) == sf::st_crs(4326)) g else sf::st_transform(g, 4326)
}

# Boxes of the geometries as four double vectors; NA for empty geometries.
geo_envelope <- function(g) {
  env <- unclass(wk::wk_envelope(g))
  out <- lapply(env[bbox_names], as.double)
  empty <- !is.finite(out$xmin) | !is.finite(out$ymin) |
    !is.finite(out$xmax) | !is.finite(out$ymax)
  lapply(out, function(v) {
    v[empty] <- NA_real_
    v
  })
}

geo_bbox_df <- function(g) {
  env <- geo_envelope(g)
  bbox_df(env$xmin, env$ymin, env$xmax, env$ymax)
}

geo_is_special <- function(env) {
  out <- (env$xmax - env$xmin) >= 180
  out[is.na(out)] <- FALSE
  out
}

# Geometries in EPSG:4326 as WKB without CRS, the form every internal cell
# function takes: subsetting it is cheap (subsetting an `sfc` computes every
# bounding box again) and s2 reads it directly.
geo_wkb <- function(g) {
  wk::wk_set_crs(wk::as_wkb(g), NULL)
}

geo_sfc <- function(w) {
  sf::st_set_crs(sf::st_as_sfc(w), 4326)
}

# Geometries on the sphere; an invalid geometry is rebuilt by s2.
geo_as_s2 <- function(g) {
  if (inherits(g, "wk_wkb")) {
    g <- wk::wk_set_geodesic(g, TRUE)
  }
  tryCatch(
    s2::as_s2_geography(g),
    error = function(e) s2::s2_rebuild(s2::as_s2_geography(g, check = FALSE))
  )
}

# Cell polygons on the sphere, from valid hex strings.
geo_cell_s2 <- function(hex) {
  if (length(hex) == 0) {
    return(s2::as_s2_geography(character()))
  }
  geo_as_s2(sf::st_as_sfc(h3_hex_to_h3o(hex)))
}

# Hex strings of a list of `H3` vectors, flattened, with the index of the
# list element of every cell.
geo_flatten_cells <- function(cells) {
  n <- lengths(cells)
  hex <- if (sum(n) == 0) character() else as.character(h3o::flatten_h3(cells))
  list(hex = hex, from = rep(seq_along(cells), n))
}

# Every cell of `hex` with its first ring, as pairs (from, cell): `from`
# indexes `hex`.
geo_ring_pairs <- function(hex) {
  unique_hex <- unique(hex)
  ring <- geo_flatten_cells(h3o::grid_disk(h3_hex_to_h3o(unique_hex), 1L))
  at <- split(seq_along(ring$hex), factor(ring$from, levels = seq_along(unique_hex)))
  slot <- match(hex, unique_hex)
  take <- at[slot]
  list(from = rep(seq_along(hex), lengths(take)), cell = ring$hex[unlist(take, use.names = FALSE)])
}

# Distinct pairs (from, cell), faster than `unique()` on a data frame.
geo_pairs <- function(from, cell) {
  keep <- !duplicated(paste(from, cell))
  data.frame(from = from[keep], cell = cell[keep])
}

# All 122 cells of resolution 0.
geo_res0_hex <- function() {
  h3_hex_build(rep(0L, 122), (0:121) * 2^45 + (2^45 - 1))
}

# Cells touched ---------------------------------------------------------------

# Cells touched by each geometry (`geo_wkb()`, EPSG:4326), as a list of
# sorted, distinct hex vectors. `exact = FALSE` keeps the cells whose centre
# lies inside a polygon without testing them again (they intersect it), which
# saves time for a large query shape; the result is the same up to cells that
# a planar centre test and the spherical test judge differently.
geo_touched_hex <- function(g, h3_res, exact = TRUE) {
  n <- length(g)
  out <- rep(list(character()), n)
  if (n == 0) {
    return(out)
  }
  env <- geo_envelope(g)
  empty <- is.na(env$xmin)
  special <- geo_is_special(env)
  normal <- which(!empty & !special)
  if (length(normal) > 0) {
    out[normal] <- geo_touched_normal(g[normal], h3_res, exact = exact, env = lapply(env, `[`, normal))
  }
  for (i in which(special)) {
    out[[i]] <- geo_touched_sphere(g[i], h3_res)
  }
  out
}

# Rough largest extent of each box in metres.
geo_extent_m <- function(env) {
  lat <- pmax(abs(env$ymin), abs(env$ymax))
  width <- (env$xmax - env$xmin) * 111320 * cos(pmin(lat, 89.9) * pi / 180)
  height <- (env$ymax - env$ymin) * 110574
  pmax(width, height)
}

# Cells touched by geometries that do not cross the antimeridian or hold a
# pole: cells of boundary points taken every third of an edge length (on the
# geodesic), their first ring, and for polygons larger than a cell the cells
# whose centre is inside; every candidate is then tested on the sphere.
geo_touched_normal <- function(g, h3_res, exact = TRUE, env = geo_envelope(g)) {
  n <- length(g)
  spacing <- h3_edge_m[[h3_res + 1L]] / 3
  extent <- geo_extent_m(env)
  geog <- geo_as_s2(g)
  dimension <- s2::s2_dimension(geog)

  # boundary points, densified on the sphere where an edge can be long
  dense <- g
  long <- which(extent > spacing)
  if (length(long) > 0) {
    dense_long <- with_s2(sf::st_segmentize(geo_sfc(g[long]), spacing))
    dense[long] <- geo_wkb(dense_long)
  }
  coords <- wk::wk_coords(dense)
  cells <- h3_hex_of_points(coords$x, coords$y, h3_res)
  boundary <- geo_pairs(coords$feature_id, cells)
  ring <- geo_ring_pairs(boundary$cell)
  candidates <- geo_pairs(boundary$from[ring$from], ring$cell)

  # cells whose centre lies inside polygons that can hold a whole cell
  big <- which(dimension == 2 & extent > h3_edge_m[[h3_res + 1L]])
  interior <- data.frame(from = integer(), cell = character())
  if (length(big) > 0) {
    polygons <- geo_sfc(dense[big])
    types <- as.character(sf::st_geometry_type(polygons))
    if (any(types == "GEOMETRYCOLLECTION")) {
      polygons <- sf::st_collection_extract(polygons, "POLYGON")
    }
    polygons <- sf::st_cast(polygons, "MULTIPOLYGON")
    filled <- geo_flatten_cells(h3o::sfc_to_cells(polygons, h3_res, "centroid"))
    interior <- data.frame(from = big[filled$from], cell = filled$hex)
  }

  vertices <- tabulate(wk::wk_coords(g)$feature_id, nbins = n)
  if (exact) {
    candidates <- geo_pairs(c(candidates$from, interior$from), c(candidates$cell, interior$cell))
    keep <- geo_intersects_pairs(geog, vertices, candidates$from, candidates$cell)
    touched <- candidates[keep, , drop = FALSE]
  } else {
    keep <- geo_intersects_pairs(geog, vertices, candidates$from, candidates$cell)
    touched <- geo_pairs(c(candidates$from[keep], interior$from), c(candidates$cell[keep], interior$cell))
  }
  touched <- touched[order(touched$from, touched$cell, method = "radix"), , drop = FALSE]
  out <- split(touched$cell, factor(touched$from, levels = seq_len(n)))
  names(out) <- NULL
  out
}

# Which pairs (geometry `from[i]` of `geog`, cell `cell[i]`) intersect on the
# sphere. Geometries with many vertices are tested against their cells in
# one indexed query each; small ones pairwise in one vectorised call.
geo_intersects_pairs <- function(geog, vertices, from, cell) {
  out <- logical(length(from))
  if (length(from) == 0) {
    return(out)
  }
  unique_cell <- unique(cell)
  cell_geog <- geo_cell_s2(unique_cell)
  slot <- match(cell, unique_cell)
  large <- vertices[from] > 64
  small <- which(!large)
  if (length(small) > 0) {
    out[small] <- s2::s2_intersects(geog[from[small]], cell_geog[slot[small]])
  }
  for (f in unique(from[large])) {
    at <- which(from == f)
    hits <- s2::s2_intersects_matrix(cell_geog[slot[at]], geog[f])
    out[at] <- lengths(hits) > 0
  }
  out
}

# Cells touched by one geometry on the sphere (antimeridian, pole), by
# descending the H3 hierarchy: the children of a cell lie within the cell and
# its first ring, so the cells at resolution r + 1 that intersect the shape
# are among the children of the first ring of those at resolution r.
geo_touched_sphere <- function(g, h3_res) {
  geog <- geo_as_s2(g)
  candidates <- geo_res0_hex()
  for (r in 0:h3_res) {
    hits <- s2::s2_intersects_matrix(geo_cell_s2(candidates), geog)
    found <- candidates[lengths(hits) > 0]
    if (r == h3_res || length(found) == 0) {
      return(sort(found, method = "radix"))
    }
    disk <- unique(geo_ring_pairs(found)$cell)
    children <- geo_flatten_cells(h3o::get_children(h3_hex_to_h3o(disk), r + 1L))
    candidates <- unique(children$hex)
  }
}

#' Cells that geometries touch
#'
#' Every cell at `h3_res` that intersects each geometry: the polygon-to-cells
#' function in the mode that returns all intersecting cells, applied to the
#' geometry itself; for lines and points the cells of the vertices and along
#' every segment. Geometries across the antimeridian or around a pole are
#' handled on the sphere. Implemented by B; called by B and F.
#'
#' Implementation: h3o's `"intersect"` mode misses the cell of a polygon that
#' lies inside one cell, so the plan's fallback is used: cells of boundary
#' points taken every third of an edge length, their first ring, and the cells
#' whose centre lies inside; every candidate is tested with `s2`. A cell
#' touches a geometry when they intersect on the sphere.
#'
#' @param x An `sfc` or `sf` object with a CRS, in any CRS.
#' @param h3_res One integer, 0 to 15.
#' @return A list with one element per geometry: a sorted `integer64` vector
#'   of distinct cells; `integer64(0)` for an empty geometry.
#' @noRd
geo_cells_touched <- function(x, h3_res) {
  h3_res <- check_h3_res(h3_res)
  g <- sf::st_geometry(x)
  if (is.na(sf::st_crs(g))) {
    geo_abort("{.arg x} has no coordinate reference system.")
  }
  check_h3o()
  touched <- geo_touched_hex(geo_wkb(geo_to_4326(g)), h3_res)
  lapply(touched, h3_hex_to_int64_raw)
}

# Geocodes of rows ------------------------------------------------------------

# Extra points along the box edge nearest the equator. A parallel bends
# towards the equator from the geodesic between its ends, by about
# L^2 tan(lat) / (8 R) for an edge of length L, so a box whose four corners
# lie in a cell can reach out of the cell along that edge. Points every
# `step` along the edge leave at most `tolerance_m` between the parallel and
# the geodesics between them.
geo_edge_points <- function(env, tolerance_m = 0.01) {
  lat <- ifelse(env$ymin > 0, env$ymin, ifelse(env$ymax < 0, -env$ymax, 0))
  lat <- pmin(lat, 89.99)
  width_m <- (env$xmax - env$xmin) * 111320 * cos(lat * pi / 180)
  bend_m <- width_m^2 * tan(lat * pi / 180) / (8 * 6371008.8)
  pieces <- ceiling(sqrt(bend_m / tolerance_m))
  pieces[!is.finite(pieces) | pieces < 2] <- 1
  edge_y <- ifelse(env$ymin > 0, env$ymin, ifelse(env$ymax < 0, env$ymax, env$ymin))
  extra <- pieces - 1
  row <- rep(seq_along(pieces), extra)
  k <- sequence(extra)
  x <- env$xmin[row] + (env$xmax[row] - env$xmin[row]) * k / pieces[row]
  list(row = row, x = x, y = edge_y[row])
}

# Geocodes of one chunk of rows: `g` is `geo_wkb()` in EPSG:4326. Returns the
# cell of every row (hex, NA when empty) and the index rows of the crossing
# rows (`row` within the chunk, `cell`, `share`). Self-contained, so that it
# can run on a mirai worker.
geo_h3_chunk <- function(g, h3_res) {
  n <- length(g)
  h3 <- rep(NA_character_, n)
  env <- geo_envelope(g)
  empty <- is.na(env$xmin)
  special <- geo_is_special(env)
  normal <- which(!empty & !special)
  inside <- integer()
  if (length(normal) > 0) {
    xmin <- env$xmin[normal]
    ymin <- env$ymin[normal]
    xmax <- env$xmax[normal]
    ymax <- env$ymax[normal]
    first <- h3_hex_of_points(xmin, ymin, h3_res)
    point <- xmin == xmax & ymin == ymax
    third <- first
    third[!point] <- h3_hex_of_points(xmax[!point], ymax[!point], h3_res)
    same <- which(first == third)
    if (length(same) > 0) {
      wide <- same[!point[same]]
      ok <- rep(TRUE, length(same))
      names(ok) <- same
      if (length(wide) > 0) {
        second <- h3_hex_of_points(xmin[wide], ymax[wide], h3_res)
        fourth <- h3_hex_of_points(xmax[wide], ymin[wide], h3_res)
        ok[as.character(wide)] <- second == first[wide] & fourth == first[wide]
        sub <- list(xmin = xmin[wide], ymin = ymin[wide], xmax = xmax[wide], ymax = ymax[wide])
        edge <- geo_edge_points(sub)
        if (length(edge$row) > 0) {
          edge_cell <- h3_hex_of_points(edge$x, edge$y, h3_res)
          off <- unique(edge$row[edge_cell != first[wide][edge$row]])
          ok[as.character(wide[off])] <- FALSE
        }
      }
      inside_local <- same[ok]
      inside <- normal[inside_local]
      h3[inside] <- first[inside_local]
    }
  }
  crossing <- setdiff(which(!empty), inside)
  index <- data.frame(row = integer(), cell = character(), share = double())
  if (length(crossing) > 0) {
    gc <- g[crossing]
    touched <- geo_touched_hex(gc, h3_res)
    pairs <- data.frame(
      from = rep(seq_along(touched), lengths(touched)),
      cell = unlist(touched, use.names = FALSE)
    )
    geog <- geo_as_s2(gc)
    pairs$share <- geo_shares(geog, pairs$from, pairs$cell)
    h3[crossing] <- geo_largest(pairs, length(crossing))
    index <- data.frame(row = crossing[pairs$from], cell = pairs$cell, share = pairs$share)
  }
  list(h3 = h3, index = index)
}

# Share of each geometry's area (polygons) or length (lines) in each cell of
# its pairs; `1 / n` for points.
geo_shares <- function(geog, from, cell) {
  share <- rep(NA_real_, length(from))
  if (length(from) == 0) {
    return(share)
  }
  dimension <- s2::s2_dimension(geog)
  count <- tabulate(from, nbins = length(geog))
  share[] <- 1 / count[from]
  measured <- which(dimension[from] %in% c(1L, 2L))
  if (length(measured) > 0) {
    unique_cell <- unique(cell[measured])
    cell_geog <- geo_cell_s2(unique_cell)
    part <- s2::s2_intersection(geog[from[measured]], cell_geog[match(cell[measured], unique_cell)])
    area <- dimension[from[measured]] == 2L
    amount <- ifelse(area, s2::s2_area(part), s2::s2_length(part))
    total_area <- s2::s2_area(geog)
    total_length <- s2::s2_length(geog)
    total <- ifelse(area, total_area[from[measured]], total_length[from[measured]])
    value <- amount / total
    use <- is.finite(value)
    share[measured[use]] <- value[use]
  }
  share
}

# The cell holding the largest share of each geometry; shares within 1e-9 of
# the largest count as ties, which go to the smallest cell.
geo_largest <- function(pairs, n) {
  best <- rep(NA_character_, n)
  if (nrow(pairs) == 0) {
    return(best)
  }
  top <- stats::ave(pairs$share, pairs$from, FUN = max)
  tied <- pairs$share >= top - 1e-9
  candidates <- pairs[tied, , drop = FALSE]
  candidates <- candidates[order(candidates$from, candidates$cell, method = "radix"), , drop = FALSE]
  first <- !duplicated(candidates$from)
  best[candidates$from[first]] <- candidates$cell[first]
  best
}

# Geocodes of all rows, in chunks of `rcs.chunk_size`, on mirai workers when
# `rcs.workers` is above 1 and mirai is installed.
geo_h3_rows <- function(g, h3_res) {
  g <- geo_wkb(g)
  n <- length(g)
  size <- max(1, as.integer(rcs_option("rcs.chunk_size")))
  starts <- seq(1, max(n, 1), by = size)
  chunks <- lapply(starts, function(s) seq.int(s, min(n, s + size - 1)))
  if (n == 0) {
    chunks <- list()
  }
  workers <- as.integer(rcs_option("rcs.workers"))
  pieces <- if (workers > 1 && length(chunks) > 1 && rlang::is_installed("mirai")) {
    geo_map_mirai(lapply(chunks, function(at) g[at]), h3_res, workers)
  } else {
    lapply(chunks, function(at) geo_h3_chunk(g[at], h3_res))
  }
  h3 <- rep(NA_character_, n)
  index <- vector("list", length(chunks))
  for (i in seq_along(chunks)) {
    h3[chunks[[i]]] <- pieces[[i]]$h3
    part <- pieces[[i]]$index
    part$row <- chunks[[i]][part$row]
    index[[i]] <- part
  }
  index <- do.call(rbind, c(list(data.frame(row = integer(), cell = character(), share = double())), index))
  list(h3 = h3, index = index)
}

# Runs `geo_h3_chunk()` over chunks on the mirai compute profile `rcs`. Uses
# daemons already set for that profile; otherwise starts `workers` local
# daemons for this call. The workers must be able to load rcs.
geo_map_mirai <- function(chunks, h3_res, workers) {
  if (!mirai::daemons_set(.compute = "rcs")) {
    mirai::daemons(workers, .compute = "rcs")
    on.exit(mirai::daemons(0, .compute = "rcs"), add = TRUE)
  }
  m <- mirai::mirai_map(
    chunks,
    function(g, h3_res, chunk_fn) chunk_fn(g, h3_res),
    .args = list(h3_res = h3_res, chunk_fn = geo_h3_chunk),
    .compute = "rcs"
  )
  m[mirai::.stop]
}

# Encoding --------------------------------------------------------------------

#' Prepare an `sf` object for writing
#'
#' Step 4 and, for geospatial data, step 6 of `store_write()`: identifiers,
#' geocodes, bounding boxes, WKB, the written order and the index-table rows.
#' Implemented by B; called by E.
#'
#' @param x An `sf` object with a CRS, in any CRS; zero rows are allowed. A
#'   column named `.rcs_id`, `h3` or `bbox`, or a geometry column not named
#'   `geometry` next to another column named `geometry`, aborts.
#' @param h3_res One integer, 0 to 15: the geocode resolution.
#' @param geocode `FALSE` skips geocoding: no `h3` column, `index` is `NULL`.
#' @param key Character vector of key columns, or `NULL`; used for the row
#'   order only (uniqueness is checked by the caller).
#' @param id_start `integer64` of length 1: the first `.rcs_id` to assign
#'   (`update` passes the dataset's current maximum plus one).
#'
#' @return A list:
#'
#'   * `data`: a tibble (not `sf`) with the columns of `x` without its
#'     geometry, then `.rcs_id` (`integer64`), `h3` (`integer64`, the cell at
#'     `h3_res` holding the largest part of the geometry; absent when
#'     `geocode = FALSE`), `bbox` (a `bbox_df()` in the CRS of `x`) and
#'     `geometry` (WKB, a bare list of raw vectors). Rows are in written
#'     order: by `h3`, then the key columns, ties in the order of `x`; with
#'     `geocode = FALSE` by the key columns, or as in `x` without a key.
#'     `.rcs_id` is `id_start`, `id_start + 1`, ... in that order. An empty
#'     geometry has `h3 = NA`, an all-`NA` `bbox`, and sorts last; with
#'     `partition = "h3"` such rows form one partition of their own, whose
#'     value is `NA` (`null` in `partition_values` and in the path).
#'   * `index`: the rows of the index table for the crossing rows, a tibble
#'     with `.rcs_id`, `h3` (every cell the row touches), `h3_main` (the
#'     row's `h3`) (all `integer64`) and `share` (double: fraction of the
#'     row's area or length in that cell; `1 / n` for points), sorted by
#'     `h3`, then `.rcs_id`. Zero rows when no row crosses; `NULL` when
#'     `geocode = FALSE`.
#'   * `crs`: the CRS of `x` as one PROJJSON string.
#'   * `bbox`: the extent of all rows, named double
#'     `c(xmin, ymin, xmax, ymax)` in the CRS of `x`; all `NA` when there is
#'     no non-empty geometry.
#'
#'   Aborts with class `rcs_error_geo` when `x` has no CRS or a reserved
#'   column name, and with the install hint (`rlang::check_installed()`) when
#'   the H3 package is missing and `geocode = TRUE`.
#' @noRd
geo_encode <- function(x, h3_res = 5L, geocode = TRUE, key = NULL,
                       id_start = bit64::as.integer64(1)) {
  if (!inherits(x, "sf")) {
    geo_abort("{.arg x} must be an {.cls sf} object, not {.obj_type_friendly {x}}.")
  }
  if (is.na(sf::st_crs(x))) {
    geo_abort("{.arg x} has no coordinate reference system.")
  }
  geometry_column <- attr(x, "sf_column")
  reserved <- intersect(c(".rcs_id", "h3", "bbox"), names(x))
  if (length(reserved) > 0) {
    geo_abort(c(
      "{.arg x} has {cli::qty(reserved)}{?a column/columns} with {?a/} reserved name{?s}: {.field {reserved}}.",
      i = "Rename {cli::qty(reserved)}{?it/them}; the package adds {.field .rcs_id}, {.field h3} and {.field bbox} itself."
    ))
  }
  if (geometry_column != "geometry" && "geometry" %in% names(x)) {
    geo_abort(
      "{.arg x} has a column {.field geometry} that is not its geometry column ({.field {geometry_column}})."
    )
  }
  h3_res <- check_h3_res(h3_res)
  check_flag(geocode)
  if (!is.null(key) && (!is.character(key) || !all(key %in% names(x)) || geometry_column %in% key)) {
    cli::cli_abort(
      "{.arg key} must name columns of {.arg x}.",
      class = "rcs_error_argument"
    )
  }
  if (!inherits(id_start, "integer64")) {
    if (!rlang::is_scalar_integerish(id_start, finite = TRUE)) {
      cli::cli_abort("{.arg id_start} must be one {.cls integer64}.", class = "rcs_error_argument")
    }
    id_start <- bit64::as.integer64(id_start)
  }
  if (length(id_start) != 1 || is.na(id_start)) {
    cli::cli_abort("{.arg id_start} must be one {.cls integer64}.", class = "rcs_error_argument")
  }
  if (geocode) {
    check_h3o()
  }

  geometry <- sf::st_geometry(x)
  attrs <- tibble::as_tibble(sf::st_drop_geometry(x))
  n <- length(geometry)
  bbox <- geo_bbox_df(geometry)

  encoded <- if (geocode) geo_h3_rows(geo_to_4326(geometry), h3_res)

  keys <- list()
  if (geocode) {
    keys$h3 <- encoded$h3
  }
  for (i in seq_along(key)) {
    keys[[paste0("key", i)]] <- attrs[[key[[i]]]]
  }
  keys$row <- seq_len(n)
  order <- vctrs::vec_order(tibble::new_tibble(keys, nrow = n), na_value = "largest")
  position <- integer(n)
  position[order] <- seq_len(n)
  ids <- id_start + bit64::as.integer64(seq_len(n) - 1L)

  data <- attrs[order, , drop = FALSE]
  data$.rcs_id <- ids
  if (geocode) {
    data$h3 <- h3_hex_to_int64_raw(encoded$h3[order])
  }
  data$bbox <- bbox[order, , drop = FALSE]
  wkb <- sf::st_as_binary(geometry, EWKB = FALSE)
  wkb <- unclass(wkb)[order]
  attributes(wkb) <- NULL
  data$geometry <- wkb

  index <- NULL
  if (geocode) {
    rows <- encoded$index
    at <- position[rows$row]
    sorted <- order(rows$cell, at, method = "radix")
    index <- tibble::tibble(
      .rcs_id = ids[at[sorted]],
      h3 = h3_hex_to_int64_raw(rows$cell[sorted]),
      h3_main = h3_hex_to_int64_raw(encoded$h3[rows$row[sorted]]),
      share = as.double(rows$share[sorted])
    )
  }

  extent <- c(
    xmin = geo_min(bbox$xmin), ymin = geo_min(bbox$ymin),
    xmax = geo_max(bbox$xmax), ymax = geo_max(bbox$ymax)
  )
  list(data = data, index = index, crs = geo_crs_json(x), bbox = extent)
}

geo_min <- function(v) {
  if (all(is.na(v))) NA_real_ else min(v, na.rm = TRUE)
}

geo_max <- function(v) {
  if (all(is.na(v))) NA_real_ else max(v, na.rm = TRUE)
}

# Decoding --------------------------------------------------------------------

#' Turn rows read from a geospatial dataset into `sf`
#'
#' Implemented by B; called by F (`collect()`) and E (`store_check()`).
#'
#' @param data A data frame with a WKB column `geometry` (a list of raw
#'   vectors, as written by `geo_encode()` and as Arrow returns a `binary`
#'   column). All other columns are kept as they are, including `.rcs_id`,
#'   `h3` and `bbox` when present. A read drops `.rcs_id` (unless asked for)
#'   and returns `h3`, `bbox` and `h3_p<r>`; that is the caller's business.
#' @param crs The dataset's CRS: one PROJJSON string (`entry$crs`).
#' @return An `sf` object (a tibble) with the same rows in the same order
#'   and the geometry column `geometry` as its last column, in `crs`. Aborts
#'   with class `rcs_error_geo` when `data` has no `geometry` column.
#' @noRd
geo_decode <- function(data, crs) {
  if (!is.data.frame(data) || !"geometry" %in% names(data)) {
    geo_abort("{.arg data} has no {.field geometry} column.")
  }
  crs <- geo_crs_from_json(crs)
  wkb <- data[["geometry"]]
  attributes(wkb) <- NULL
  if (!is.list(wkb)) {
    geo_abort("The {.field geometry} column must hold WKB (a list of raw vectors).")
  }
  missing <- vapply(wkb, is.null, logical(1))
  if (any(missing)) {
    wkb[missing] <- list(geo_empty_wkb)
  }
  geometry <- sf::st_as_sfc(structure(wkb, class = "WKB"), EWKB = FALSE, crs = crs)
  rest <- data[setdiff(names(data), "geometry")]
  rest <- tibble::as_tibble(rest)
  if (ncol(rest) == 0) {
    rest <- tibble::new_tibble(list(), nrow = length(geometry))
  }
  sf::st_sf(rest, geometry = geometry)
}

# WKB of GEOMETRYCOLLECTION EMPTY (little endian), for missing geometries.
geo_empty_wkb <- as.raw(c(0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))

# GeoParquet metadata ---------------------------------------------------------

geo_type_names <- c(
  "Point", "LineString", "Polygon", "MultiPoint", "MultiLineString",
  "MultiPolygon", "GeometryCollection"
)

#' GeoParquet 1.1 `geo` metadata of one data file
#'
#' Implemented by B; called by C when it writes a file.
#'
#' @param data The rows of one file, as in `geo_encode()$data` (needs the
#'   columns `bbox` and `geometry`).
#' @param crs One PROJJSON string.
#' @return One JSON string for the key `geo`: `version "1.1.0"`,
#'   `primary_column "geometry"`, and for the column `encoding "WKB"`,
#'   `geometry_types` of the rows (sorted), `crs` (the PROJJSON as an object,
#'   not a string), `bbox` of the rows and `covering` pointing at the `bbox`
#'   struct column. The same rows give the same string. The `bbox` key is
#'   left out when no row has a geometry.
#' @noRd
geo_metadata <- function(data, crs) {
  if (!is.data.frame(data) || !all(c("bbox", "geometry") %in% names(data))) {
    geo_abort("{.arg data} needs the columns {.field bbox} and {.field geometry}.")
  }
  check_string(crs)
  wkb <- data[["geometry"]]
  attributes(wkb) <- NULL
  wkb <- wkb[!vapply(wkb, is.null, logical(1))]
  types <- character()
  if (length(wkb) > 0) {
    meta <- wk::wk_meta(wk::new_wk_wkb(wkb))
    suffix <- ifelse(meta$has_z & meta$has_m, " ZM", ifelse(meta$has_z, " Z", ifelse(meta$has_m, " M", "")))
    types <- unique(paste0(geo_type_names[meta$geometry_type], suffix))
    types <- sort(types, method = "radix")
  }
  column <- list(
    encoding = "WKB",
    geometry_types = I(types),
    crs = jsonlite::fromJSON(crs, simplifyVector = FALSE)
  )
  box <- data[["bbox"]]
  extent <- c(geo_min(box$xmin), geo_min(box$ymin), geo_max(box$xmax), geo_max(box$ymax))
  if (!anyNA(extent)) {
    column$bbox <- extent
  }
  column$covering <- list(bbox = list(
    xmin = c("bbox", "xmin"), ymin = c("bbox", "ymin"),
    xmax = c("bbox", "xmax"), ymax = c("bbox", "ymax")
  ))
  geo <- list(version = "1.1.0", primary_column = "geometry", columns = list(geometry = column))
  as.character(jsonlite::toJSON(geo, auto_unbox = TRUE, digits = NA, null = "null"))
}

# Covering --------------------------------------------------------------------

# Densify an `sfc` with straight edges in its own coordinates (planar), so
# that its shape survives a change of CRS or a reading on the sphere.
geo_densify_planar <- function(g, max_length) {
  crs <- sf::st_crs(g)
  plain <- sf::st_set_crs(g, sf::NA_crs_)
  sf::st_set_crs(sf::st_segmentize(plain, max_length), crs)
}

#' Covering of a query shape
#'
#' Steps 1 and 2 of the spatial filter: normalise the query shape and find
#' the cells that can hold matching rows. Implemented by B; called by F and I.
#'
#' The cells are those touched by the shape read on the sphere and by the
#' shape densified along its straight (planar) edges, so the covering holds
#' for both readings of `sf::sf_use_s2()`; then their first ring.
#'
#' @param shape The query: an `sf`, `sfc` or `bbox` object with a CRS (several
#'   geometries are combined), or H3 cells of any resolution (hex strings,
#'   `integer64` or `H3`), which stand for their cell polygons. A plain
#'   numeric aborts with class `rcs_error_h3_input`.
#' @param h3_res The dataset's geocode resolution (`entry$h3_res`), or `NA`
#'   for a dataset written with `geocode = FALSE` or a raster; `cells` is
#'   then `NULL`.
#' @param crs The data CRS: one PROJJSON string (`entry$crs`).
#' @return A list:
#'
#'   * `shape`: an `sfc` of length 1 in the data CRS: the query shape,
#'     densified before the change of CRS; used for the exact test;
#'   * `bbox`: the box of that shape, named double
#'     `c(xmin, ymin, xmax, ymax)` in the data CRS; `NULL` when the shape
#'     crosses the antimeridian or holds a pole, and bounding-box tests must
#'     be skipped;
#'   * `cells`: sorted `integer64` vector of distinct cells at `h3_res`: every
#'     cell that intersects the shape plus their first ring; `NULL` when
#'     `h3_res` is `NA`.
#'
#'   Informs (through `rcs_inform()`) when a query cell is finer than
#'   `h3_res`. Aborts with class `rcs_error_geo` for a shape without CRS or an
#'   empty shape.
#' @noRd
geo_covering <- function(shape, h3_res, crs) {
  geocoded <- !(length(h3_res) == 1 && is.na(h3_res))
  if (geocoded) {
    h3_res <- check_h3_res(h3_res)
  }
  target <- geo_crs_from_json(crs)

  if (inherits(shape, c("sf", "sfc", "bbox"))) {
    g <- if (inherits(shape, "bbox")) sf::st_as_sfc(shape) else sf::st_geometry(shape)
    if (is.na(sf::st_crs(g))) {
      geo_abort("The query shape has no coordinate reference system.")
    }
  } else {
    hex <- h3_as_hex(shape, arg = "intersects")
    hex <- unique(hex[!is.na(hex)])
    if (length(hex) == 0) {
      geo_abort("The query holds no H3 cell.")
    }
    check_h3o()
    finer <- h3_hex_res(hex) > h3_res
    if (geocoded && any(finer)) {
      rcs_inform(c(
        i = "The query holds cells finer than the stored resolution {h3_res}; the cell filter works at resolution {h3_res}."
      ))
    }
    g <- sf::st_set_crs(sf::st_as_sfc(h3_hex_to_h3o(hex)), 4326)
  }
  g <- g[!sf::st_is_empty(g)]
  if (length(g) == 0) {
    geo_abort("The query shape is empty.")
  }
  if (length(g) > 1) {
    g <- sf::st_union(g)
  }
  g <- sf::st_sfc(g[[1]], crs = sf::st_crs(g))

  # densify before any change of CRS, in the shape's own coordinates
  transformed <- sf::st_crs(g) != target
  densified <- g
  if (transformed) {
    env <- geo_envelope(g)
    diagonal <- sqrt((env$xmax - env$xmin)^2 + (env$ymax - env$ymin)^2)
    if (is.finite(diagonal) && diagonal > 0) {
      densified <- geo_densify_planar(g, diagonal / 256)
    }
  }
  shape_data <- if (transformed) sf::st_transform(densified, target) else g

  shape_4326 <- geo_to_4326(densified)
  special <- geo_is_special(geo_envelope(shape_4326))

  bbox <- NULL
  if (!special) {
    env <- geo_envelope(shape_data)
    bbox <- c(xmin = env$xmin, ymin = env$ymin, xmax = env$xmax, ymax = env$ymax)
  }

  cells <- NULL
  if (geocoded) {
    check_h3o()
    hex <- geo_touched_hex(geo_wkb(shape_4326), h3_res, exact = FALSE)[[1]]
    if (!special) {
      degrees <- h3_edge_m[[h3_res + 1L]] / 3 / 111320
      planar <- geo_densify_planar(shape_4326, degrees)
      hex <- c(hex, geo_touched_hex(geo_wkb(planar), h3_res, exact = FALSE)[[1]])
    }
    hex <- unique(hex)
    if (length(hex) > 0) {
      hex <- unique(geo_ring_pairs(hex)$cell)
    }
    cells <- h3_hex_to_int64_raw(sort(hex, method = "radix"))
  }
  list(shape = shape_data, bbox = bbox, cells = cells)
}
