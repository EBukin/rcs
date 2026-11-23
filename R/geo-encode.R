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
  out <- tryCatch(geo_crs_cached(crs), error = function(e) sf::NA_crs_)
  if (is.na(out)) {
    geo_abort("{.arg crs} must be a coordinate reference system (PROJJSON).", call = call)
  }
  out
}

# `sf::st_crs()` of a CRS string, kept for the session: parsing a PROJJSON
# string takes tens of milliseconds, and every spatial read parses the
# catalog's CRS several times. Other inputs are parsed each time.
geo_crs_cache <- new.env(parent = emptyenv())

geo_crs_cached <- function(crs) {
  if (!rlang::is_string(crs) || is.na(crs)) {
    return(sf::st_crs(crs))
  }
  key <- md5_string(crs)
  out <- geo_crs_cache[[key]]
  if (is.null(out)) {
    out <- sf::st_crs(crs)
    if (length(geo_crs_cache) >= 32) {
      rm(list = ls(geo_crs_cache), envir = geo_crs_cache)
    }
    geo_crs_cache[[key]] <- out
  }
  out
}

# Whether a CRS string is geographic, kept for the session as above
# (`sf::st_is_longlat()` parses the CRS again on every call).
geo_crs_is_longlat <- function(crs) {
  if (!rlang::is_string(crs) || is.na(crs)) {
    return(isTRUE(sf::st_is_longlat(sf::st_crs(crs))))
  }
  key <- paste0("longlat-", md5_string(crs))
  out <- geo_crs_cache[[key]]
  if (is.null(out)) {
    out <- isTRUE(sf::st_is_longlat(geo_crs_cached(crs)))
    geo_crs_cache[[key]] <- out
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
#
# `geog` (optional) gives the geographies of `g` on the sphere, for example
# with invalid rows rebuilt; by default they are made from `g`.
geo_touched_hex <- function(g, h3_res, exact = TRUE, geog = NULL) {
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
    out[normal] <- geo_touched_normal(
      g[normal], h3_res,
      exact = exact, env = lapply(env, `[`, normal),
      geog = if (is.null(geog)) geo_as_s2(g[normal]) else geog[normal]
    )
  }
  for (i in which(special)) {
    out[[i]] <- geo_touched_sphere(g[i], h3_res, geog = if (is.null(geog)) geo_as_s2(g[i]) else geog[i])
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
geo_touched_normal <- function(g, h3_res, exact = TRUE, env = geo_envelope(g),
                               geog = geo_as_s2(g)) {
  n <- length(g)
  spacing <- h3_edge_m[[h3_res + 1L]] / 3
  extent <- geo_extent_m(env)
  dimension <- s2::s2_dimension(geog)

  # boundary points, densified on the sphere where an edge can be long: for
  # lon/lat, sf::st_segmentize() densifies along the geodesic with lwgeom
  # whatever sf::sf_use_s2() says
  dense <- g
  long <- which(extent > spacing)
  if (length(long) > 0) {
    dense_long <- sf::st_segmentize(geo_sfc(g[long]), spacing)
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
    polygons <- sf::st_cast(geo_drop_short_rings(polygons), "MULTIPOLYGON")
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

# Polygons (`sfc` of POLYGON or MULTIPOLYGON) without their rings of fewer
# than 4 points; a polygon whose outer ring is that short is dropped whole.
# Densifying with `sf::st_segmentize()` (lwgeom, geodesic) removes repeated
# vertices, so a degenerate ring (a hole of identical points, a spike) can
# come back with 1 to 3 points, which `sf::st_cast()` and
# `h3o::sfc_to_cells()` reject. Such a ring holds no area, so it cannot hold
# a cell centre and dropping it changes no interior cell.
#
# The scan is vectorised: `wk::wk_coords()` numbers the rings of the whole
# `sfc` in order and `wk::wk_count()` gives the rings of each element, so a
# ring with no point at all counts as short too. An `sfc` without short rings
# is returned as it came (same bounding box and precision).
geo_drop_short_rings <- function(polygons) {
  count <- wk::wk_count(polygons)
  points <- tabulate(wk::wk_coords(polygons)$ring_id, nbins = sum(count$n_ring))
  short <- unique(rep(seq_along(polygons), count$n_ring)[points < 4L])
  if (length(short) == 0) {
    return(polygons)
  }
  keep_rings <- function(rings) {
    if (length(rings) == 0 || nrow(rings[[1]]) < 4L) {
      return(NULL)
    }
    rings[vapply(rings, nrow, integer(1)) >= 4L]
  }
  # element by element: `[[<-` on an sfc is cheap, `[<-` rebuilds every
  # element's type
  for (i in short) {
    p <- polygons[[i]]
    dim <- class(p)[[1]]
    if (inherits(p, "POLYGON")) {
      rings <- keep_rings(unclass(p))
      polygons[[i]] <- if (is.null(rings)) {
        sf::st_polygon(dim = dim)
      } else {
        sf::st_polygon(rings, dim = dim)
      }
    } else {
      parts <- Filter(Negate(is.null), lapply(unclass(p), keep_rings))
      polygons[[i]] <- sf::st_multipolygon(parts, dim = dim)
    }
  }
  polygons
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
geo_touched_sphere <- function(g, h3_res, geog = geo_as_s2(g)) {
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
# cell of every row (hex, NA when empty), the index rows of the crossing
# rows (`row` within the chunk, `cell`, `share`) and the rows rebuilt or
# fallen back to the plane (`geo_crossing_rows()`). Self-contained, so that
# it can run on a mirai worker.
geo_h3_chunk <- function(g, h3_res, geocode_engine = "auto", tol = 1e-3) {
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
  rebuilt <- integer()
  fallback <- integer()
  if (length(crossing) > 0) {
    rows <- geo_crossing_rows(g[crossing], h3_res, geocode_engine, tol, special[crossing])
    h3[crossing] <- rows$h3
    index <- data.frame(row = crossing[rows$pairs$from], cell = rows$pairs$cell, share = rows$pairs$share)
    rebuilt <- crossing[rows$rebuilt]
    fallback <- crossing[rows$fallback]
  }
  list(h3 = h3, index = index, rebuilt = rebuilt, fallback = fallback)
}

# Geocodes of crossing rows (`g`, `geo_wkb()` in EPSG:4326) by the engine
# (plan 0002, D31). Every row is validated alone on the sphere, so one
# invalid row changes nothing for the others. Rows valid on the sphere are
# geocoded there (engines "auto" and "s2"); invalid rows are rebuilt by
# `geo_rebuild()` ("s2"), or rebuilt and checked ("auto"), falling back to
# the plane when the rebuilt copy is not faithful; engine "planar" geocodes
# every row in the plane. Rows whose box spans 180 degrees or more
# (`special`) are geocoded on the sphere whatever the engine. Returns the
# cell of every row (hex), the pairs (from, cell, share) and the rows that
# were rebuilt or fell back (indices into `g`).
geo_crossing_rows <- function(g, h3_res, geocode_engine, tol, special) {
  n <- length(g)
  geog <- s2::as_s2_geography(wk::wk_set_geodesic(g, TRUE), check = FALSE)
  valid <- s2::s2_is_valid(geog)
  valid[is.na(valid)] <- FALSE

  planar <- if (geocode_engine == "planar") !special else rep(FALSE, n)
  rebuilt <- integer()
  fallback <- integer()
  for (i in which(!valid & !planar)) {
    copy <- tryCatch(geo_rebuild(geog[i]), error = function(e) NULL)
    ok <- !is.null(copy) && length(copy) == 1
    if (ok && geocode_engine == "auto" && !special[[i]]) {
      ok <- geo_rebuild_faithful(g[i], copy, tol)
    }
    if (ok) {
      geog[i] <- copy
      g[i] <- wk::wk_set_geodesic(geo_wkb(copy), FALSE)
      rebuilt <- c(rebuilt, i)
    } else if (special[[i]]) {
      # rows without a planar reading keep the plain rebuild
      geog[i] <- s2::s2_rebuild(geog[i])
      g[i] <- wk::wk_set_geodesic(geo_wkb(geog[i]), FALSE)
      rebuilt <- c(rebuilt, i)
    } else {
      planar[[i]] <- TRUE
      fallback <- c(fallback, i)
    }
  }

  pairs <- data.frame(from = integer(), cell = character(), share = double())
  sphere <- which(!planar)
  if (length(sphere) > 0) {
    touched <- geo_touched_hex(g[sphere], h3_res, geog = geog[sphere])
    from <- rep(seq_along(touched), lengths(touched))
    cell <- unlist(touched, use.names = FALSE)
    share <- geo_shares(geog[sphere], from, cell)
    pairs <- rbind(pairs, data.frame(from = sphere[from], cell = as.character(cell), share = share))
  }
  flat <- which(planar)
  if (length(flat) > 0) {
    part <- geo_planar_rows(g[flat], h3_res)
    pairs <- rbind(pairs, data.frame(from = flat[part$from], cell = part$cell, share = part$share))
  }
  pairs <- pairs[order(pairs$from, pairs$cell, method = "radix"), , drop = FALSE]
  rownames(pairs) <- NULL
  list(
    h3 = geo_largest(pairs, n), pairs = pairs,
    rebuilt = sort(rebuilt), fallback = sort(fallback)
  )
}

#' Rebuild geographies on the sphere
#'
#' A wrapper of `s2::s2_rebuild()`, so that tests can replace it.
#'
#' @param geog An `s2_geography` vector.
#' @return The rebuilt `s2_geography`, one element per element of `geog`.
#' @noRd
geo_rebuild <- function(geog) {
  s2::s2_rebuild(geog)
}

# Whether the rebuilt copy of one invalid row is faithful (D31, fact 19):
# not empty, valid on the sphere, and its measure (area, length or number of
# points) as WKB in EPSG:6933 under `sf_use_s2(FALSE)` within `tol` of the
# original's. A copy that `s2::s2_is_valid()` still judges invalid (or NA)
# is not faithful (plan 0003, B1): `s2_rebuild()` can return the same
# vertices unchanged, so the measure alone would pass it. A polygon whose
# rebuilt copy covers more than a hemisphere has turned inside out (its WKB
# has the same planar area as the original, so the measure alone cannot
# tell); it is not faithful either. Any error or non-finite measure gives
# FALSE. Only engine "auto" calls this, and not for rows whose box spans 180
# degrees or more; engine "s2" uses the rebuilt copy as it is (D31).
geo_rebuild_faithful <- function(original, copy, tol) {
  tryCatch(
    {
      if (isTRUE(s2::s2_is_empty(copy)) || !isTRUE(s2::s2_is_valid(copy))) {
        return(FALSE)
      }
      original <- geo_sfc(original)
      dimension <- max(sf::st_dimension(original), na.rm = TRUE)
      if (dimension == 2 && s2::s2_area(copy) > 2 * pi * s2::s2_earth_radius_meters()^2) {
        return(FALSE)
      }
      wkb <- s2::s2_as_binary(copy)
      rebuilt <- geo_sfc(wk::new_wk_wkb(unclass(wkb)))
      before <- geo_planar_measure(original, dimension)
      after <- geo_planar_measure(rebuilt, dimension)
      is.finite(before) && before > 0 && is.finite(after) && abs(after / before - 1) <= tol
    },
    error = function(e) FALSE
  )
}

# Area (dimension 2), length (1) or number of points (0) of an `sfc` in
# EPSG:4326, measured in EPSG:6933 in the plane.
geo_planar_measure <- function(x, dimension) {
  if (dimension == 0) {
    return(nrow(wk::wk_coords(x)))
  }
  without_s2({
    projected <- sf::st_transform(x, 6933)
    amount <- if (dimension == 2) sf::st_area(projected) else sf::st_length(projected)
    sum(as.numeric(amount))
  })
}

# Planar computations, whatever the session's s2 setting.
without_s2 <- function(code) {
  old <- suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(old)))
  suppressMessages(code)
}

# Cell polygons in EPSG:4326 as `sfc`, from valid hex strings.
geo_cell_sfc <- function(hex) {
  sf::st_set_crs(sf::st_as_sfc(h3_hex_to_h3o(hex)), 4326)
}

# Cells and shares of rows (`g`, `geo_wkb()` in EPSG:4326, none across the
# antimeridian or around a pole) in the plane (D31, fact 20). Candidate
# cells: the cells of boundary points of the shape densified along its
# straight edges every third of an edge length, their first ring, and the
# cells whose centre lies inside. A candidate touches the row when
# `sf::st_intersects()` says so under `sf_use_s2(FALSE)`. Shares: one
# `sf::st_intersection()` per row with its touched cells, in EPSG:4326 in
# the plane, the parts measured in EPSG:6933 (areas, or lengths for lines)
# and normalised to sum to 1; `1 / n` for points. Returns pairs (from,
# cell, share), `from` indexing `g`.
#
# Rows invalid in the plane (a bowtie hole, a figure-eight ring, a ring of
# fewer than 4 points from WKB) would make GEOS abort, so they are repaired
# first by `geo_planar_valid()` (plan 0003, C1). The repaired copy gives the
# candidates, the touch test and the shares; the stored geometry is never
# changed. The repair is silent: under engine "auto" such rows are already
# reported as fallbacks (D32), under explicit "planar" it is documented in
# `store_write()` (C2).
geo_planar_rows <- function(g, h3_res) {
  n <- length(g)
  sfc <- geo_planar_valid(geo_sfc(g))
  edge <- h3_edge_m[[h3_res + 1L]]
  dense <- geo_densify_planar(sfc, edge / 3 / 111320)
  coords <- wk::wk_coords(dense)
  boundary <- geo_pairs(coords$feature_id, h3_hex_of_points(coords$x, coords$y, h3_res))
  ring <- geo_ring_pairs(boundary$cell)
  candidates <- geo_pairs(boundary$from[ring$from], ring$cell)

  dimension <- sf::st_dimension(sfc)
  dimension[is.na(dimension)] <- 0L
  extent <- geo_extent_m(geo_envelope(g))
  big <- which(dimension == 2 & extent > edge)
  if (length(big) > 0) {
    polygons <- dense[big]
    types <- as.character(sf::st_geometry_type(polygons))
    if (any(types == "GEOMETRYCOLLECTION")) {
      polygons <- sf::st_collection_extract(polygons, "POLYGON")
    }
    polygons <- sf::st_cast(geo_drop_short_rings(polygons), "MULTIPOLYGON")
    filled <- geo_flatten_cells(h3o::sfc_to_cells(polygons, h3_res, "centroid"))
    candidates <- geo_pairs(c(candidates$from, big[filled$from]), c(candidates$cell, filled$hex))
  }

  out <- vector("list", n)
  without_s2({
    for (i in seq_len(n)) {
      hex <- sort(unique(candidates$cell[candidates$from == i]), method = "radix")
      cells <- geo_cell_sfc(hex)
      hit <- lengths(sf::st_intersects(cells, sfc[i])) > 0
      hex <- hex[hit]
      cells <- cells[hit]
      share <- rep(1 / length(hex), length(hex))
      if (dimension[[i]] > 0 && length(hex) > 1) {
        amount <- geo_planar_parts(sfc[i], cells, dimension[[i]])
        if (is.finite(sum(amount)) && sum(amount) > 0) {
          share <- amount / sum(amount)
        }
      }
      out[[i]] <- data.frame(from = rep(i, length(hex)), cell = hex, share = share)
    }
  })
  do.call(rbind, c(list(data.frame(from = integer(), cell = character(), share = double())), out))
}

# Geometries (`sfc`, EPSG:4326) made valid in the plane for the planar engine
# (plan 0003, C1). Rows that `sf::st_is_valid()` judges valid under
# `sf_use_s2(FALSE)` are returned as they are, so valid rows pay one
# validity check. Rows judged invalid or NA (or on which the check errors)
# are repaired one by one by `geo_planar_repair()`.
geo_planar_valid <- function(sfc) {
  valid <- without_s2(tryCatch(sf::st_is_valid(sfc), error = function(e) NULL))
  if (is.null(valid)) {
    valid <- vapply(seq_along(sfc), function(i) {
      without_s2(tryCatch(isTRUE(sf::st_is_valid(sfc[i])), error = function(e) FALSE))
    }, logical(1))
  }
  repair <- which(!(valid %in% TRUE))
  if (length(repair) == 0) {
    return(sfc)
  }
  # a repair can change the geometry type, which `[[<-` on an sfc does not
  # record, so the sfc is built again
  geoms <- lapply(sfc, identity)
  for (i in repair) {
    geoms[[i]] <- geo_planar_repair(sfc[i])
  }
  sf::st_sfc(geoms, crs = sf::st_crs(sfc))
}

# One geometry (`sfc` of length 1) invalid in the plane, repaired by
# `sf::st_make_valid()` (GEOS, default method), as an `sfg` of the original
# dimension. When GEOS cannot read the polygon (a ring of fewer than 4
# points), its short rings are dropped first (they hold no area, as in
# `geo_drop_short_rings()`). A repair that changes the dimension keeps the
# parts of the original dimension (`sf::st_collection_extract()`); a repair
# that leaves none, or that fails, gives an empty geometry: no cells.
geo_planar_repair <- function(x) {
  empty <- sf::st_geometrycollection()
  dimension <- suppressWarnings(max(sf::st_dimension(x), na.rm = TRUE))
  if (!is.finite(dimension)) {
    return(empty)
  }
  type <- c("POINT", "LINESTRING", "POLYGON")[[dimension + 1L]]
  make_valid <- function(y) tryCatch(without_s2(sf::st_make_valid(y)), error = function(e) NULL)
  fixed <- make_valid(x)
  if (is.null(fixed) && inherits(x, c("sfc_POLYGON", "sfc_MULTIPOLYGON"))) {
    fixed <- make_valid(geo_drop_short_rings(x))
  }
  if (is.null(fixed) || length(fixed) != 1 || sf::st_is_empty(fixed)) {
    return(empty)
  }
  if (!inherits(fixed[[1]], "GEOMETRYCOLLECTION")) {
    return(if (isTRUE(sf::st_dimension(fixed) == dimension)) fixed[[1]] else empty)
  }
  # one element per part of that dimension, possibly none; all of them are
  # kept, split into single parts and combined into one multi-geometry
  parts <- sf::st_collection_extract(fixed, type, warn = FALSE)
  parts <- parts[!sf::st_is_empty(parts) & sf::st_dimension(parts) %in% dimension]
  if (length(parts) == 0) {
    return(empty)
  }
  if (length(parts) == 1) {
    return(parts[[1]])
  }
  sf::st_combine(sf::st_cast(parts, type))[[1]]
}

# Area (dimension 2) or length (1) in EPSG:6933 of the part of the geometry
# `x` (`sfc` of length 1, EPSG:4326) in each of `cells`: one intersection
# call in the plane. Called under `sf_use_s2(FALSE)`.
geo_planar_parts <- function(x, cells, dimension) {
  parts <- sf::st_intersection(x, cells)
  amount <- numeric(length(cells))
  if (length(parts) == 0) {
    return(amount)
  }
  which_cell <- attr(parts, "idx")[, 2]
  projected <- sf::st_transform(parts, 6933)
  measure <- as.numeric(if (dimension == 2) sf::st_area(projected) else sf::st_length(projected))
  measure[!is.finite(measure)] <- 0
  sums <- rowsum(measure, which_cell)
  amount[as.integer(rownames(sums))] <- sums[, 1]
  amount
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

#' Geocodes of rows by an engine
#'
#' Geocodes of all rows, in chunks of `rcs.chunk_size`, on mirai workers when
#' `rcs.workers` is above 1 and mirai is installed. With more than one
#' chunk a cli progress bar shows rows and chunks done, unless `rcs.quiet`
#' is set. The engine applies to crossing rows whose cells come from s2
#' (plan 0002, D31); inside rows keep the cell of their box corners.
#'
#' @param g Geometries in EPSG:4326 (`sfc`, or anything `wk` reads).
#' @param h3_res One integer, 0 to 15.
#' @param geocode_engine `"auto"`, `"s2"` or `"planar"`.
#' @param tol Largest relative change of area (length, number of points) of
#'   a rebuilt row that `"auto"` accepts.
#' @return A list: `h3` (hex string per row, `NA` when empty), `index` (a
#'   data frame with `row`, `cell` (hex) and `share`, sorted by row then
#'   cell), `rebuilt` and `fallback` (sorted row numbers of the rows rebuilt
#'   on the sphere and of the rows geocoded in the plane after a rejected
#'   rebuild).
#' @noRd
geo_h3_rows <- function(g, h3_res, geocode_engine = "auto", tol = rcs_option("rcs.s2_rebuild_tol")) {
  geocode_engine <- check_geocode_engine(geocode_engine)
  tol <- check_rebuild_tol(tol)
  g <- geo_wkb(g)
  n <- length(g)
  size <- max(1, as.integer(rcs_option("rcs.chunk_size")))
  starts <- seq(1, max(n, 1), by = size)
  chunks <- lapply(starts, function(s) seq.int(s, min(n, s + size - 1)))
  if (n == 0) {
    chunks <- list()
  }
  workers <- as.integer(rcs_option("rcs.workers"))
  progress <- length(chunks) > 1 && !isTRUE(rcs_option("rcs.quiet"))
  pieces <- if (workers > 1 && length(chunks) > 1 && rlang::is_installed("mirai")) {
    geo_map_mirai(lapply(chunks, function(at) g[at]), h3_res, workers, geocode_engine, tol, progress)
  } else {
    bar <- NULL
    if (progress) {
      bar <- cli::cli_progress_bar(
        format = paste(
          "Geocoding H3 res {h3_res} {cli::pb_bar} {cli::pb_current}/{cli::pb_total} rows",
          "| chunk {cli::pb_extra$chunk}/{length(chunks)} | ETA {cli::pb_eta}"
        ),
        total = n, clear = TRUE, extra = list(chunk = 0L)
      )
    }
    lapply(seq_along(chunks), function(i) {
      at <- chunks[[i]]
      piece <- geo_h3_chunk(g[at], h3_res, geocode_engine, tol)
      if (!is.null(bar)) {
        cli::cli_progress_update(id = bar, set = max(at), extra = list(chunk = i))
      }
      piece
    })
  }
  h3 <- rep(NA_character_, n)
  index <- vector("list", length(chunks))
  rebuilt <- vector("list", length(chunks))
  fallback <- vector("list", length(chunks))
  for (i in seq_along(chunks)) {
    h3[chunks[[i]]] <- pieces[[i]]$h3
    part <- pieces[[i]]$index
    part$row <- chunks[[i]][part$row]
    index[[i]] <- part
    rebuilt[[i]] <- chunks[[i]][pieces[[i]]$rebuilt]
    fallback[[i]] <- chunks[[i]][pieces[[i]]$fallback]
  }
  index <- do.call(rbind, c(list(data.frame(row = integer(), cell = character(), share = double())), index))
  rownames(index) <- NULL
  list(
    h3 = h3, index = index,
    rebuilt = as.integer(unlist(rebuilt)), fallback = as.integer(unlist(fallback))
  )
}

check_geocode_engine <- function(geocode_engine, call = caller_env()) {
  engines <- c("auto", "s2", "planar")
  if (!rlang::is_string(geocode_engine) || !geocode_engine %in% engines) {
    given <- if (rlang::is_string(geocode_engine)) {
      cli::format_inline("{.val {geocode_engine}}")
    } else {
      cli::format_inline("{.obj_type_friendly {geocode_engine}}")
    }
    cli::cli_abort(
      "{.arg geocode_engine} must be one of {.or {.val {engines}}}, not {given}.",
      class = "rcs_error_argument", call = call
    )
  }
  geocode_engine
}

check_rebuild_tol <- function(tol, call = caller_env()) {
  if (!rlang::is_scalar_double(tol) && !rlang::is_scalar_integer(tol) || is.na(tol) || !is.finite(tol) || tol < 0) {
    cli::cli_abort(
      "{.arg tol} must be one finite number not below 0.",
      class = "rcs_error_argument", call = call
    )
  }
  as.double(tol)
}

# Runs `geo_h3_chunk()` over chunks on the mirai compute profile `rcs`. Uses
# daemons already set for that profile; otherwise starts `workers` local
# daemons for this call. The workers must be able to load rcs.
geo_map_mirai <- function(chunks, h3_res, workers, geocode_engine = "auto", tol = 1e-3,
                          progress = FALSE) {
  if (!mirai::daemons_set(.compute = "rcs")) {
    mirai::daemons(workers, .compute = "rcs")
    on.exit(mirai::daemons(0, .compute = "rcs"), add = TRUE)
  }
  m <- mirai::mirai_map(
    chunks,
    function(g, h3_res, geocode_engine, tol, chunk_fn) chunk_fn(g, h3_res, geocode_engine, tol),
    .args = list(h3_res = h3_res, geocode_engine = geocode_engine, tol = tol, chunk_fn = geo_h3_chunk),
    .compute = "rcs"
  )
  if (progress) m[mirai::.progress, mirai::.stop] else m[mirai::.stop]
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
#' @param geocode_engine `"auto"` (default), `"s2"` or `"planar"`: how
#'   crossing rows are geocoded (plan 0002, D31). Projected data are
#'   geocoded on their EPSG:4326 copy by the same rule (D34).
#' @param tol Largest relative change of area (length, number of points) of
#'   a rebuilt row that `"auto"` accepts; above it the row is geocoded in
#'   the plane.
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
#'   * `order`: integer, the row of `x` of each row of `data`.
#'   * `rebuilt`, `fallback`: sorted integer row numbers of `x`: rows
#'     invalid on the sphere that were rebuilt there, and rows whose rebuild
#'     was rejected and that were geocoded in the plane (empty when
#'     `geocode = FALSE`).
#'
#'   Aborts with class `rcs_error_geo` when `x` has no CRS or a reserved
#'   column name, and with the install hint (`rlang::check_installed()`) when
#'   the H3 package is missing and `geocode = TRUE`.
#' @noRd
geo_encode <- function(x, h3_res = 5L, geocode = TRUE, key = NULL,
                       id_start = bit64::as.integer64(1), geocode_engine = "auto",
                       tol = rcs_option("rcs.s2_rebuild_tol")) {
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
  geocode_engine <- check_geocode_engine(geocode_engine)
  tol <- check_rebuild_tol(tol)
  if (geocode) {
    check_h3o()
  }

  geometry <- sf::st_geometry(x)
  attrs <- tibble::as_tibble(sf::st_drop_geometry(x))
  n <- length(geometry)
  bbox <- geo_bbox_df(geometry)

  encoded <- if (geocode) geo_h3_rows(geo_to_4326(geometry), h3_res, geocode_engine, tol)

  keys <- list()
  if (geocode) {
    keys$h3 <- encoded$h3
  }
  for (i in seq_along(key)) {
    keys[[paste0("key", i)]] <- attrs[[key[[i]]]]
  }
  keys$row <- seq_len(n)
  # byte order whatever the locale, as tables and DuckDB `ORDER BY` (plan 0002)
  order <- order_radix(tibble::new_tibble(keys, nrow = n))
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
  list(
    data = data, index = index, crs = geo_crs_json(x), bbox = extent, order = order,
    rebuilt = if (geocode) encoded$rebuilt else integer(),
    fallback = if (geocode) encoded$fallback else integer()
  )
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
  geometry <- geo_wkb_to_sfc(wkb, crs)
  rest <- data[setdiff(names(data), "geometry")]
  rest <- tibble::as_tibble(rest)
  if (ncol(rest) == 0) {
    rest <- tibble::new_tibble(list(), nrow = length(geometry))
  }
  sf::st_sf(rest, geometry = geometry)
}

# WKB (a bare list of raw vectors, none NULL) to `sfc` in `crs`. wk's sfc
# writer is about ten times faster than `sf::st_as_sfc()` and gives the
# identical `sfc` (class, bounding box, precision, empty count, geometry
# classes), except for zero geometries and columns of empty geometries
# only, whose bounding box differs in its attributes; those take sf's path.
geo_wkb_to_sfc <- function(wkb, crs) {
  if (length(wkb) > 0) {
    geometry <- wk::wk_handle(wk::new_wk_wkb(wkb), wk::sfc_writer())
    if (attr(geometry, "n_empty") < length(geometry)) {
      sf::st_crs(geometry) <- crs
      return(geometry)
    }
  }
  sf::st_as_sfc(structure(wkb, class = "WKB"), EWKB = FALSE, crs = crs)
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
  types <- geo_type_strings(data[["geometry"]])
  box <- data[["bbox"]]
  extent <- c(geo_min(box$xmin), geo_min(box$ymin), geo_max(box$xmax), geo_max(box$ymax))
  geo_metadata_of(types, extent, crs)
}

#' GeoParquet `geo` metadata from geometry types and extent
#'
#' The variant of `geo_metadata()` for files whose rows are not in R (the
#' writer of DuckDB tables, plan 0002, D39): the same string for the same
#' types and extent.
#'
#' @param types Character: the geometry types of the rows, as
#'   `geo_type_strings()` gives them (any order; repeats and `NA` allowed).
#' @param extent Double `c(xmin, ymin, xmax, ymax)` of the rows; any `NA`
#'   leaves the `bbox` key out.
#' @param crs One PROJJSON string.
#' @return One JSON string, as `geo_metadata()`.
#' @noRd
geo_metadata_of <- function(types, extent, crs) {
  check_string(crs)
  types <- as.character(types)
  types <- sort(unique(types[!is.na(types)]), method = "radix")
  column <- list(
    encoding = "WKB",
    geometry_types = I(types),
    crs = jsonlite::fromJSON(crs, simplifyVector = FALSE)
  )
  extent <- unname(as.double(extent))
  if (!anyNA(extent)) {
    column$bbox <- extent
  }
  column$covering <- list(bbox = list(
    xmin = c("bbox", "xmin"), ymin = c("bbox", "ymin"),
    xmax = c("bbox", "xmax"), ymax = c("bbox", "ymax")
  ))
  geo <- list(version = "1.1.0", primary_column = "geometry", columns = list(geometry = column))
  as.character(jsonlite::toJSON(
    json_exact_doubles(geo),
    auto_unbox = TRUE, digits = NA, null = "null", json_verbatim = TRUE
  ))
}

# The GeoParquet geometry type of each WKB geometry ("Polygon", "Point Z",
# ...); `NA` for a missing one (`NULL`).
geo_type_strings <- function(wkb) {
  attributes(wkb) <- NULL
  present <- !vapply(wkb, is.null, logical(1))
  out <- rep(NA_character_, length(wkb))
  if (any(present)) {
    meta <- wk::wk_meta(wk::new_wk_wkb(wkb[present]))
    suffix <- ifelse(meta$has_z & meta$has_m, " ZM", ifelse(meta$has_z, " Z", ifelse(meta$has_m, " M", "")))
    out[present] <- paste0(geo_type_names[meta$geometry_type], suffix)
  }
  out
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
