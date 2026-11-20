# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: work package B, tests/testthat/helper-geo-reference.R (brute-force
# references) and work package F, tests for covering cells.
#
# These are slow, obviously correct references. They are for tests only: the
# package's own cell search must be compared against them, never built on them.
#
# Changes from the original: no fixed projected CRS (the buffer is given in
# degrees), cells as hex strings from h3jsr, no project-specific columns.

#' Every H3 cell of one resolution that intersects a shape
#'
#' Fills a buffered copy of the shape with cells (centre containment), then
#' keeps the cells whose polygon intersects the shape itself. The buffer must
#' exceed the cell's circumradius, so that cells whose centre lies outside the
#' shape are found.
#'
#' @param shape An `sf` or `sfc` object in EPSG:4326.
#' @param res H3 resolution.
#' @param buffer_deg Buffer in degrees, larger than the cell circumradius.
#'
#' @return An `sf` object with the column `h3` (hex string) and cell polygons.
#' @noRd
ref_cells_intersecting <- function(shape, res, buffer_deg) {
  whole <- sf::st_union(sf::st_geometry(shape))
  buffered <- suppressWarnings(suppressMessages(sf::st_buffer(whole, buffer_deg)))
  cells <- unique(unlist(h3jsr::polygon_to_cells(buffered, res = res)))
  grid <- h3jsr::cell_to_polygon(cells, simple = FALSE)
  names(grid)[names(grid) == "h3_address"] <- "h3"
  # The shape goes first: sf prepares the first geometry, which makes one
  # large shape against many cells fast.
  touches <- unlist(suppressMessages(sf::st_intersects(whole, grid)))
  sf::st_as_sf(tibble::as_tibble(grid[sort(unique(touches)), ]))
}

#' The grid cells each geometry intersects
#'
#' @param geom An `sfc`.
#' @param grid A grid from `ref_cells_intersecting()` covering all of `geom`.
#'
#' @return A list of character vectors, one per geometry.
#' @noRd
ref_cells_per_row <- function(geom, grid) {
  hits <- suppressMessages(sf::st_intersects(geom, grid))
  lapply(hits, \(i) sort(grid$h3[i]))
}

#' The grid cell holding the largest part of each geometry
#'
#' Reference for the column `h3`. Area is measured as sf measures it for the
#' CRS of `geom`.
#'
#' @inheritParams ref_cells_per_row
#'
#' @return A character vector, `NA` for empty geometries.
#' @noRd
ref_cell_largest <- function(geom, grid) {
  hits <- suppressMessages(sf::st_intersects(geom, grid))
  vapply(seq_along(hits), function(i) {
    cand <- hits[[i]]
    if (length(cand) == 0) {
      return(NA_character_)
    }
    if (length(cand) == 1) {
      return(grid$h3[cand])
    }
    piece <- suppressWarnings(suppressMessages(
      sf::st_intersection(sf::st_geometry(grid)[cand], geom[i])
    ))
    size <- if (all(sf::st_dimension(piece) == 2, na.rm = TRUE)) {
      as.numeric(sf::st_area(piece))
    } else {
      as.numeric(sf::st_length(piece))
    }
    grid$h3[cand][which.max(size)]
  }, character(1))
}
