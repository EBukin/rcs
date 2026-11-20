# Simulated data for tests. Each object is generated once per test run and
# reused.

sim_cache <- new.env(parent = emptyenv())

sim_cached <- function(name, code) {
  if (is.null(sim_cache[[name]])) {
    sim_cache[[name]] <- code
  }
  sim_cache[[name]]
}

skip_if_no_h3 <- function() {
  testthat::skip_if_not_installed("h3o")
}

# The box of the simulated geometries, as the plan states it. Written out
# here, not taken from the package, so that the tests check the package
# against the plan.
plan_box <- c(xmin = -30, ymin = 6, xmax = -24, ymax = 9)

sim_table <- function() {
  sim_cached("table", rcs_sim_table(500, seed = 1))
}

sim_polygons <- function(special = FALSE) {
  skip_if_no_h3()
  all <- sim_cached("polygons", rcs_sim_polygons(500, seed = 1, special = TRUE))
  if (special) all else all[seq_len(500), ]
}

# The same polygons in a projected CRS.
sim_polygons_projected <- function() {
  sim_cached("polygons_projected", sf::st_transform(sim_polygons(), 32626))
}

sim_points <- function() {
  sim_cached("points", rcs_sim_points(500, seed = 1))
}

sim_lines <- function() {
  sim_cached("lines", rcs_sim_lines(500, seed = 1))
}

sim_raster <- function() {
  testthat::skip_if_not_installed("terra")
  rcs_sim_raster(seed = 1, nrow = 100, ncol = 100)
}

# The cell of points as hex strings, by h3o alone: longitude first here,
# latitude first in h3o.
ref_cell_hex <- function(lon, lat, res) {
  as.character(h3o::h3_from_xy(lat, lon, as.integer(res)))
}

# Coordinates of all vertices as a matrix with the columns X and Y; unlike
# `sf::st_coordinates()` it takes a column of mixed geometry types.
coords_of <- function(x) {
  coords <- wk::wk_coords(sf::st_geometry(x))
  cbind(X = coords$x, Y = coords$y)
}

expect_in_box <- function(coords, box = plan_box) {
  testthat::expect_gte(min(coords[, "X"]), box[["xmin"]])
  testthat::expect_lte(max(coords[, "X"]), box[["xmax"]])
  testthat::expect_gte(min(coords[, "Y"]), box[["ymin"]])
  testthat::expect_lte(max(coords[, "Y"]), box[["ymax"]])
}
