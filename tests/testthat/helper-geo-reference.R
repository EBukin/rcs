# Slow brute-force references for the geospatial encoding. They share no code
# with the package: cells come from h3o and dense point grids, intersections
# and measures from sf on the sphere (s2), cell ids are compared as hex
# strings (one resolution: string order is numeric order).

ref_s2 <- function(code) {
  old <- suppressMessages(sf::sf_use_s2(TRUE))
  on.exit(suppressMessages(sf::sf_use_s2(old)))
  code
}

ref_hex_list <- function(cells) {
  unlist(lapply(cells, as.character), use.names = FALSE)
}

# Every cell at `res` near a lon/lat window: the cells of a dense grid of
# points (spacing well below the cell size) and their first ring. `lon` may
# hold several windows, given as a list of ranges.
ref_grid_cells <- function(lon, lat, res, step = NULL) {
  if (is.null(step)) {
    edge_deg <- c(
      11.5, 4.3, 1.6, 0.62, 0.23, 0.088, 0.033, 0.0126, 0.0048, 0.0018
    )[res + 1]
    step <- edge_deg / 3
  }
  if (!is.list(lon)) {
    lon <- list(lon)
  }
  hex <- character()
  for (window in lon) {
    xs <- seq(window[[1]], window[[2]], by = step)
    ys <- seq(lat[[1]], lat[[2]], by = step)
    grid <- expand.grid(x = xs, y = ys)
    hex <- c(hex, unique(as.character(h3o::h3_from_xy(grid$y, grid$x, as.integer(res)))))
  }
  hex <- unique(hex)
  unique(c(hex, ref_hex_list(h3o::grid_disk(h3o::h3_from_strings(hex), 1L))))
}

ref_cell_polygons <- function(hex) {
  sf::st_set_crs(sf::st_as_sfc(h3o::h3_from_strings(hex)), 4326)
}

# Cells touched by every geometry of `g` (EPSG:4326), among `hex`: a list of
# sorted hex vectors.
ref_touched <- function(g, hex) {
  polygons <- ref_cell_polygons(hex)
  hits <- ref_s2(sf::st_intersects(g, polygons))
  lapply(hits, function(i) sort(hex[i], method = "radix"))
}

# The largest-overlap cell of every geometry, with the shares of every cell
# it touches. Ties (within 1e-9) and points go to the smallest cell.
ref_h3 <- function(g, hex) {
  touched <- ref_touched(g, hex)
  polygons <- ref_cell_polygons(hex)
  dims <- sf::st_dimension(g)
  out <- vector("list", length(g))
  for (i in seq_along(g)) {
    cells <- touched[[i]]
    if (length(cells) == 0) {
      out[[i]] <- list(h3 = NA_character_, cells = cells, share = numeric())
      next
    }
    if (length(cells) == 1) {
      share <- 1
    } else if (dims[[i]] == 0) {
      share <- rep(1 / length(cells), length(cells))
    } else {
      parts <- ref_s2(sf::st_intersection(g[i], polygons[match(cells, hex)]))
      measure <- if (dims[[i]] == 2) sf::st_area else sf::st_length
      amount <- as.numeric(ref_s2(measure(parts)))
      total <- as.numeric(ref_s2(measure(g[i])))
      # st_intersection drops empty results; put them back as zero
      kept <- ref_s2(sf::st_intersects(g[i], polygons[match(cells, hex)]))[[1]]
      share <- numeric(length(cells))
      if (length(amount) == length(cells)) {
        share <- amount / total
      } else {
        share[kept] <- amount / total
      }
    }
    best <- cells[share >= max(share) - 1e-9]
    out[[i]] <- list(h3 = sort(best, method = "radix")[[1]], cells = cells, share = share)
  }
  out
}

# Cells that intersect a query shape (EPSG:4326, inside the window), read on
# the sphere and read in the plane (`sf::sf_use_s2(FALSE)`).
ref_query_cells <- function(q, res, window_lon, window_lat) {
  hex <- ref_grid_cells(window_lon, window_lat, res)
  polygons <- ref_cell_polygons(hex)
  sphere <- hex[lengths(ref_s2(sf::st_intersects(polygons, q))) > 0]
  old <- suppressMessages(sf::sf_use_s2(FALSE))
  planar <- hex[lengths(suppressMessages(sf::st_intersects(polygons, q))) > 0]
  suppressMessages(sf::sf_use_s2(old))
  list(sphere = sphere, planar = planar)
}
