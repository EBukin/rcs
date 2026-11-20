# Which H3 package, and what does geocoding cost per row?
#
# Compares h3o with h3jsr on the H3 operations the encoding needs, on 1e5 and
# 1e6 simulated polygons, times the whole geocoding (`geo_encode()`), and
# measures how often an inside row (four box corners in one cell) reaches
# into another cell, by row size and latitude (plan, "Open questions").
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "h3-backends.R"))
#
# Results: bench/results/h3-backends.parquet and
# bench/results/h3-inside-rows.parquet. Sizes can be narrowed with
# RCS_BENCH_SIZES (e.g. "1e5").

# ---- setup ----
root <- Sys.getenv("RCS_BENCH_ROOT", ".")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "h3jsr", "bench"))
sizes <- as.numeric(strsplit(Sys.getenv("RCS_BENCH_SIZES", "1e5;1e6"), ";")[[1]])
res <- 5L
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- data ----
# Corners of the boxes, the crossing rows and their cells, for one size.
prepare <- function(n) {
  x <- rcs_sim_polygons(n, seed = 1)
  g <- sf::st_geometry(x)
  box <- geo_envelope(g)
  keep <- !is.na(box$xmin)
  corners <- data.frame(
    x = c(box$xmin, box$xmin, box$xmax, box$xmax)[rep(keep, 4)],
    y = c(box$ymin, box$ymax, box$ymax, box$ymin)[rep(keep, 4)]
  )
  first <- h3_hex_of_points(box$xmin, box$ymin, res)
  third <- h3_hex_of_points(box$xmax, box$ymax, res)
  crossing <- which(keep & first != third)
  polygons <- sf::st_cast(g[crossing], "MULTIPOLYGON")
  cells <- unique(unlist(geo_touched_hex(geo_wkb(g[crossing]), res)))
  list(x = x, corners = corners, polygons = polygons, cells = cells)
}

# ---- corners ----
# Cell of every box corner: the bulk of geocoding (four points per row).
corners_h3o <- function(d) as.character(h3o::h3_from_xy(d$corners$y, d$corners$x, res))
corners_h3jsr <- function(d) h3jsr::point_to_cell(d$corners, res = res)

# ---- polyfill ----
# Cells whose centre is inside each crossing polygon (the mode both offer).
polyfill_h3o <- function(d) h3o::sfc_to_cells(d$polygons, res, "centroid")
polyfill_h3jsr <- function(d) h3jsr::polygon_to_cells(d$polygons, res = res)

# ---- boundaries ----
# Cell polygons, for the intersections with the crossing rows.
boundaries_h3o <- function(d) sf::st_as_sfc(h3o::h3_from_strings(d$cells))
boundaries_h3jsr <- function(d) h3jsr::cell_to_polygon(d$cells)

# ---- encode ----
# The whole encoding with the chosen package (h3o), per row.
encode <- function(d) geo_encode(d$x, h3_res = res)

# ---- run ----
rows <- list()
for (n in sizes) {
  case <- format(n, scientific = TRUE)
  cli::cli_inform("Preparing {case} polygons.")
  d <- prepare(n)
  cli::cli_inform("Timing {case} polygons.")
  agree <- identical(corners_h3o(d), corners_h3jsr(d))
  timed <- bench_run(
    corners_h3o = corners_h3o(d),
    corners_h3jsr = corners_h3jsr(d),
    polyfill_h3o = polyfill_h3o(d),
    polyfill_h3jsr = polyfill_h3jsr(d),
    boundaries_h3o = boundaries_h3o(d),
    boundaries_h3jsr = boundaries_h3jsr(d),
    encode_h3o = encode(d),
    case = case
  )
  timed$rows <- n
  timed$points <- c(rep(nrow(d$corners), 2), rep(length(d$polygons), 2), rep(length(d$cells), 2), n)
  timed$corners_agree <- agree
  rows[[case]] <- timed
  rm(d)
  gc()
}
backends <- do.call(rbind, rows)
backends$us_per_item <- 1e6 * backends$median_s / backends$points
bench_save(backends, "h3-backends", env = env, dir = results_dir)

# ---- inside-rows ----
# Random boxes; those whose four corners share a cell are inside rows. Their
# boundary, taken at 64 points per edge (parallels and meridians, where a
# vertex of the row may lie), is checked for points in another cell, before
# and after the package's remedy (extra points along the edge nearest the
# equator, `geo_edge_points()`).
measure_inside <- function(n, lat, width_km, seed, k = 64) {
  box <- withr::with_seed(seed, {
    cy <- stats::runif(n, lat - 1, lat + 1)
    cx <- stats::runif(n, -170, 170)
    w <- width_km / (111.32 * cos(cy * pi / 180))
    h <- width_km / 110.574 * stats::runif(n, 0.3, 1)
    list(xmin = cx - w / 2, xmax = cx + w / 2, ymin = cy - h / 2, ymax = cy + h / 2)
  })
  corner <- function(x, y) h3_hex_of_points(x, y, res)
  c1 <- corner(box$xmin, box$ymin)
  inside <- which(
    c1 == corner(box$xmin, box$ymax) & c1 == corner(box$xmax, box$ymax) & c1 == corner(box$xmax, box$ymin)
  )
  e <- lapply(box, `[`, inside)
  m <- length(inside)
  t <- seq(0, 1, length.out = k)
  along_x <- outer(e$xmin, rep(1, k)) + outer(e$xmax - e$xmin, t)
  along_y <- outer(e$ymin, rep(1, k)) + outer(e$ymax - e$ymin, t)
  px <- cbind(along_x, along_x, matrix(e$xmin, m, k), matrix(e$xmax, m, k))
  py <- cbind(matrix(e$ymin, m, k), matrix(e$ymax, m, k), along_y, along_y)
  cells <- matrix(h3_hex_of_points(c(px), c(py), res), m)
  violation <- rowSums(cells != c1[inside]) > 0
  edge <- geo_edge_points(e)
  kept <- rep(TRUE, m)
  if (length(edge$row) > 0) {
    off <- h3_hex_of_points(edge$x, edge$y, res) != c1[inside][edge$row]
    kept[unique(edge$row[off])] <- FALSE
  }
  data.frame(
    lat = lat, width_km = width_km, boxes = n, inside = m,
    violations = sum(violation), inside_after_remedy = sum(kept),
    violations_after_remedy = sum(violation & kept)
  )
}

grid <- expand.grid(width_km = c(0.5, 2, 8, 15), lat = c(5, 30, 60, 80, 85))
inside_rows <- do.call(rbind, lapply(seq_len(nrow(grid)), function(i) {
  cli::cli_inform("Inside rows: latitude {grid$lat[[i]]}, {grid$width_km[[i]]} km.")
  measure_inside(20000, grid$lat[[i]], grid$width_km[[i]], seed = i)
}))
bench_save(inside_rows, "h3-inside-rows", env = env, dir = results_dir)
