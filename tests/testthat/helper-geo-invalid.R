# Geometries for the geocoding engines (plan 0002, facts 18 and 20), as WKT in
# EPSG:4326, and small builders around them.

# Two polygons valid in the plane but invalid on the sphere (fact 18): a
# duplicated consecutive vertex, and a spike that almost touches the
# southern edge. Each crosses resolution-5 cell edges.
geo_invalid_wkt <- function() {
  c(
    duplicate = "POLYGON((-27.2 7.1, -26.9 7.1, -26.9 7.1, -26.9 7.4, -27.2 7.4, -27.2 7.1))",
    spike = paste0(
      "POLYGON((-27.2 7.1, -26.9 7.1, -26.9 7.4, -27.05 7.4, -27.05 7.1000000001, ",
      "-27.06 7.4, -27.2 7.4, -27.2 7.1))"
    )
  )
}

# A polygon valid in the plane, invalid on the sphere, whose real
# `s2::s2_rebuild()` returns it unchanged and still invalid (plan 0003, fact
# 5, like row 341's loop 182). Its hole has a long edge along 48N, which
# bulges north on the sphere by about 2e-4 degrees, and two vertices 5e-5
# degrees north of 48N, which lie below that bulge: on the sphere two edges
# of the hole cross (`Loop 1: Edge 1 crosses edge 4`), in the plane none do.
# Wider than a resolution-5 edge.
geo_stays_invalid_wkt <- function() {
  paste0(
    "POLYGON((29.9 47.9, 30.5 47.9, 30.5 48.2, 29.9 48.2, 29.9 47.9), ",
    "(30 48, 30.16 48.00005, 30.2 48.1, 30.24 48.00005, 30.4 48, 30 48))"
  )
}

# A polygon with long edges, valid in both readings (fact 20): its cells on
# the sphere and in the plane differ.
geo_long_edge_wkt <- function() {
  "POLYGON((-40 10, -15 10, -15 12, -40 12, -40 10))"
}

geo_sfc_of_wkt <- function(wkt) {
  sf::st_as_sfc(unname(wkt), crs = 4326)
}

# 20 valid simulated polygons followed by the two invalid ones of fact 18,
# as an `sf` with the column `id` (21 and 22 are the invalid rows).
geo_with_invalid <- function() {
  valid <- sf::st_geometry(rcs_sim_polygons(20, seed = 3))
  sf::st_sf(
    id = seq_len(22),
    geometry = c(valid, geo_sfc_of_wkt(geo_invalid_wkt()))
  )
}

# Session s2 setting for one test.
local_s2 <- function(use, frame = parent.frame()) {
  old <- suppressMessages(sf::sf_use_s2(use))
  withr::defer(suppressMessages(sf::sf_use_s2(old)), envir = frame)
  invisible(old)
}

# Brute-force cells and shares of one geometry (EPSG:4326) among the cells
# `hex`, on the sphere: s2 intersections of the geography with the cell
# polygons, areas or lengths by s2. `geog` is an s2 geography of length 1.
ref_engine_sphere <- function(geog, hex) {
  cells <- s2::as_s2_geography(ref_cell_polygons(hex))
  hit <- s2::s2_intersects(geog, cells)
  hex <- hex[hit]
  cells <- cells[hit]
  dimension <- max(s2::s2_dimension(geog))
  if (dimension == 0) {
    share <- rep(1 / length(hex), length(hex))
  } else {
    measure <- if (dimension == 2) s2::s2_area else s2::s2_length
    share <- measure(s2::s2_intersection(geog, cells)) / measure(geog)
  }
  ref_engine_result(hex, share)
}

# Brute-force cells and shares of one geometry (`sfc`, EPSG:4326) among the
# cells `hex`, in the plane: intersections under `sf_use_s2(FALSE)`, areas or
# lengths in EPSG:6933, normalised to sum to 1.
ref_engine_planar <- function(g, hex) {
  local_s2(FALSE)
  cells <- ref_cell_polygons(hex)
  hit <- lengths(suppressMessages(sf::st_intersects(cells, g))) > 0
  hex <- hex[hit]
  cells <- cells[hit]
  dimension <- max(sf::st_dimension(g))
  if (dimension == 0) {
    share <- rep(1 / length(hex), length(hex))
  } else {
    amount <- vapply(seq_along(cells), function(i) {
      part <- suppressMessages(sf::st_intersection(g, cells[i]))
      if (length(part) == 0) {
        return(0)
      }
      part <- sf::st_transform(part, 6933)
      as.numeric(sum(if (dimension == 2) sf::st_area(part) else sf::st_length(part)))
    }, numeric(1))
    share <- amount / sum(amount)
  }
  ref_engine_result(hex, share)
}

ref_engine_result <- function(hex, share) {
  o <- order(hex, method = "radix")
  hex <- hex[o]
  share <- share[o]
  best <- hex[share >= max(share) - 1e-9]
  list(h3 = sort(best, method = "radix")[[1]], cells = hex, share = share)
}

# Cells and shares of row `i` from a `geo_h3_rows()` result, sorted by cell.
engine_row <- function(encoded, i) {
  index <- encoded$index[encoded$index$row == i, , drop = FALSE]
  o <- order(index$cell, method = "radix")
  list(h3 = encoded$h3[[i]], cells = index$cell[o], share = index$share[o])
}

# Polygons invalid in the plane and on the sphere (plan 0003, fix C), as WKT
# in EPSG:4326, each wider than a resolution-5 edge: a box with a bowtie hole
# (GEOS: self-intersection at 30.1 48.05), and a figure-eight outer ring.
geo_plane_invalid_wkt <- function() {
  c(
    bowtie_hole = paste0(
      "POLYGON((29.9 47.9, 30.5 47.9, 30.5 48.2, 29.9 48.2, 29.9 47.9), ",
      "(30 48, 30.2 48.1, 30.2 48, 30 48.1, 30 48))"
    ),
    figure_eight = "POLYGON((29.9 47.9, 30.5 48.2, 30.5 47.9, 29.9 48.2, 29.9 47.9))"
  )
}

# Polygons whose repair in the plane (`sf::st_make_valid()`, GEOS) loses
# dimension, wider than a resolution-5 edge: a zero-area polygon (repaired to
# a line), a multipolygon with a zero-area part (repaired to a
# GEOMETRYCOLLECTION of a polygon and lines), and the same with a figure
# eight (two polygons and lines).
geo_plane_collapse_wkt <- function() {
  c(
    flat = "POLYGON((29.9 47.9, 30.5 47.9, 30.2 48.2, 30.5 47.9, 29.9 47.9))",
    flat_part = paste0(
      "MULTIPOLYGON(((30 48, 30.3 48, 30.3 48.2, 30 48.2, 30 48)), ",
      "((31 48, 31.5 48, 31.2 48, 31 48)))"
    ),
    # a figure eight beside a zero-area part: a collection of two polygons
    # and lines
    two_parts = paste0(
      "MULTIPOLYGON(((29.9 47.9, 30.5 48.2, 30.5 47.9, 29.9 48.2, 29.9 47.9)), ",
      "((31 48, 31.5 48, 31.2 48, 31 48)))"
    )
  )
}

# A 0.6 x 0.3 degree box with one hole of `k` points (1 to 3), as an `sfc`
# in EPSG:4326 built from little-endian WKB: neither sf nor GEOS would build
# such a ring from coordinates.
geo_short_ring_sfc <- function(k) {
  outer <- cbind(c(29.9, 30.5, 30.5, 29.9, 29.9), c(47.9, 47.9, 48.2, 48.2, 47.9))
  hole <- rbind(c(30.1, 48.05), c(30.2, 48.06), c(30.1, 48.05))[seq_len(k), , drop = FALSE]
  le_int <- function(v) writeBin(as.integer(v), raw(), size = 4, endian = "little")
  le_double <- function(v) writeBin(as.vector(v), raw(), size = 8, endian = "little")
  ring <- function(m) c(le_int(nrow(m)), le_double(t(m)))
  wkb <- c(as.raw(1), le_int(3), le_int(2), ring(outer), ring(hole))
  sf::st_as_sfc(structure(list(wkb), class = "WKB"), crs = 4326)
}

# The box of `geo_short_ring_sfc()` without its hole.
geo_short_ring_box <- function() {
  outer <- cbind(c(29.9, 30.5, 30.5, 29.9, 29.9), c(47.9, 47.9, 48.2, 48.2, 47.9))
  sf::st_sfc(sf::st_polygon(list(outer)), crs = 4326)
}
