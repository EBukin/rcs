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
