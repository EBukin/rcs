# Benchmark: H3 package and the cost of geocoding

This article reads stored results; it does not run the benchmark. The
script is `bench/h3-backends.R`; its code is shown below as it was run.

## Question

The geospatial encoding needs, for every row, the H3 cells of the four
corners of its bounding box, and for the rows that cross cell edges the
cells whose centre lies inside the polygon and the cell polygons. Two R
packages offer these operations: `h3o` (Rust) and `h3jsr` (JavaScript
through V8). Which is faster on the package’s own workload, do they
agree, and what does geocoding cost per row once one is chosen?

A second question comes from the plan’s open points: a row whose four
box corners fall in one cell is treated as lying inside that cell. Box
edges along parallels are not great circles, so how often does such a
row reach into another cell, by row size and latitude?

## Setup

``` r

env <- backends[1, grep("^env_", names(backends))]
knitr::kable(data.frame(
  item = sub("^env_", "", names(env)),
  value = vapply(env, function(v) as.character(v[[1]]), character(1)),
  row.names = NULL
))
```

| item | value |
|:---|:---|
| date | 2026-11-20 16:32:55 |
| commit | d9ccd50 |
| r_version | 4.6.2 |
| os | Windows 10 x64 |
| cpu | Intel64 Family 6 Model 142 Stepping 12, GenuineIntel |
| cores | 8 |
| ram_gb | 31.8 |
| storage | ssd |
| packages | {“rcs”:“0.0.0.9000”,“arrow”:“26.0.1”,“sf”:“1.1.3”,“h3o”:“0.3.0”,“h3jsr”:“1.3.1”,“terra”:“1.9.50”,“duckdb”:“2.0.0”,“bit64”:“4.8.6”} |

Simulated polygons
([`rcs_sim_polygons()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md),
open ocean, 10% built across cell edges), resolution 5. Each operation
is timed with `bench_run()` (at least five repetitions, median
reported).

``` r

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
```

``` r

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
```

``` r

# Cell of every box corner: the bulk of geocoding (four points per row).
corners_h3o <- function(d) as.character(h3o::h3_from_xy(d$corners$y, d$corners$x, res))
corners_h3jsr <- function(d) h3jsr::point_to_cell(d$corners, res = res)
```

``` r

# Cells whose centre is inside each crossing polygon (the mode both offer).
polyfill_h3o <- function(d) h3o::sfc_to_cells(d$polygons, res, "centroid")
polyfill_h3jsr <- function(d) h3jsr::polygon_to_cells(d$polygons, res = res)
```

``` r

# Cell polygons, for the intersections with the crossing rows.
boundaries_h3o <- function(d) sf::st_as_sfc(h3o::h3_from_strings(d$cells))
boundaries_h3jsr <- function(d) h3jsr::cell_to_polygon(d$cells)
```

``` r

# The whole encoding with the chosen package (h3o), per row.
encode <- function(d) geo_encode(d$x, h3_res = res)
```

``` r

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
```

## Results

``` r

shown <- backends[c("case", "expression", "points", "median_s", "min_s", "max_s", "us_per_item")]
shown$median_s <- signif(shown$median_s, 3)
shown$min_s <- signif(shown$min_s, 3)
shown$max_s <- signif(shown$max_s, 3)
shown$us_per_item <- signif(shown$us_per_item, 3)
knitr::kable(shown)
```

| case  | expression       |  points | median_s |    min_s |    max_s | us_per_item |
|:------|:-----------------|--------:|---------:|---------:|---------:|------------:|
| 1e+05 | corners_h3o      |  399996 |  1.82000 |  1.25000 |  1.84000 |        4.56 |
| 1e+05 | corners_h3jsr    |  399996 |  3.28000 |  3.10000 |  3.41000 |        8.20 |
| 1e+05 | polyfill_h3o     |   15113 |  0.20700 |  0.19900 |  0.21300 |       13.70 |
| 1e+05 | polyfill_h3jsr   |   15113 |  1.16000 |  1.15000 |  1.22000 |       76.80 |
| 1e+05 | boundaries_h3o   |     882 |  0.00939 |  0.00809 |  0.01030 |       10.60 |
| 1e+05 | boundaries_h3jsr |     882 |  0.13000 |  0.12800 |  0.15600 |      147.00 |
| 1e+05 | encode_h3o       |  100000 |  6.03000 |  5.73000 |  6.73000 |       60.30 |
| 1e+06 | corners_h3o      | 3999996 | 25.90000 | 14.80000 | 34.40000 |        6.48 |
| 1e+06 | corners_h3jsr    | 3999996 | 67.80000 | 63.80000 | 70.50000 |       16.90 |
| 1e+06 | polyfill_h3o     |  150829 |  1.81000 |  1.76000 |  1.87000 |       12.00 |
| 1e+06 | polyfill_h3jsr   |  150829 | 13.40000 | 12.60000 | 14.70000 |       89.00 |
| 1e+06 | boundaries_h3o   |     886 |  0.00942 |  0.00894 |  0.00947 |       10.60 |
| 1e+06 | boundaries_h3jsr |     886 |  0.14100 |  0.13800 |  0.15300 |      159.00 |
| 1e+06 | encode_h3o       | 1000000 | 64.80000 | 63.90000 | 70.90000 |       64.80 |

`points` counts the items of each operation: box corners, crossing
polygons, distinct cells, or rows for `encode_h3o`. Both packages return
the same cell for every corner: `corners_agree` is TRUE in every case.

``` r

ratio <- function(case, op) {
  rows <- backends[backends$case == case, ]
  rows$median_s[rows$expression == paste0(op, "_h3jsr")] /
    rows$median_s[rows$expression == paste0(op, "_h3o")]
}
speedup <- expand.grid(case = unique(backends$case), operation = c("corners", "polyfill", "boundaries"),
  stringsAsFactors = FALSE)
speedup$h3jsr_over_h3o <- round(mapply(ratio, speedup$case, speedup$operation), 1)
knitr::kable(speedup)
```

| case  | operation  | h3jsr_over_h3o |
|:------|:-----------|---------------:|
| 1e+05 | corners    |            1.8 |
| 1e+06 | corners    |            2.6 |
| 1e+05 | polyfill   |            5.6 |
| 1e+06 | polyfill   |            7.4 |
| 1e+05 | boundaries |           13.8 |
| 1e+06 | boundaries |           14.9 |

Inside rows, before and after the remedy:

``` r

knitr::kable(inside[c("lat", "width_km", "boxes", "inside", "violations", "inside_after_remedy", "violations_after_remedy")])
```

| lat | width_km | boxes | inside | violations | inside_after_remedy | violations_after_remedy |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 0.5 | 20000 | 18758 | 0 | 18758 | 0 |
| 5 | 2.0 | 20000 | 15302 | 0 | 15302 | 0 |
| 5 | 8.0 | 20000 | 4992 | 0 | 4992 | 0 |
| 5 | 15.0 | 20000 | 115 | 0 | 115 | 0 |
| 30 | 0.5 | 20000 | 18772 | 0 | 18772 | 0 |
| 30 | 2.0 | 20000 | 15429 | 0 | 15429 | 0 |
| 30 | 8.0 | 20000 | 5130 | 0 | 5130 | 0 |
| 30 | 15.0 | 20000 | 155 | 0 | 155 | 0 |
| 60 | 0.5 | 20000 | 18796 | 0 | 18796 | 0 |
| 60 | 2.0 | 20000 | 15358 | 0 | 15358 | 0 |
| 60 | 8.0 | 20000 | 4969 | 0 | 4969 | 0 |
| 60 | 15.0 | 20000 | 128 | 0 | 128 | 0 |
| 80 | 0.5 | 20000 | 18847 | 0 | 18847 | 0 |
| 80 | 2.0 | 20000 | 15520 | 0 | 15520 | 0 |
| 80 | 8.0 | 20000 | 5304 | 0 | 5304 | 0 |
| 80 | 15.0 | 20000 | 173 | 0 | 173 | 0 |
| 85 | 0.5 | 20000 | 18859 | 0 | 18859 | 0 |
| 85 | 2.0 | 20000 | 15496 | 0 | 15496 | 0 |
| 85 | 8.0 | 20000 | 5340 | 0 | 5340 | 0 |
| 85 | 15.0 | 20000 | 157 | 0 | 157 | 0 |

``` r

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
```

## Verdict

- `h3o` is the H3 package of `rcs`. It is faster than `h3jsr` on every
  operation measured, by the factors in the table above, and gives the
  same cells. `h3jsr` is not needed.
- Geocoding costs about 64.8 microseconds per row on 1,000,000 polygons
  (whole `geo_encode()`, one worker). The corner cells take 40% of it;
  most of the rest goes to the crossing rows (about 15% of the simulated
  rows): candidate cells, the spherical intersection test and the
  intersection areas.
- Inside rows: 0 of 197,600 inside rows had a boundary point in another
  cell. The package nevertheless tests extra points along the edge
  nearest the equator when the bend of that parallel could exceed 1 cm
  (`geo_edge_points()`); a box that fails becomes a crossing row.

## Limits

- One machine, local disk, one worker; `rcs.workers > 1` is not measured
  here.
- `h3o`’s `"intersect"` mode, which would give the cells a polygon
  touches in one call, misses the cell of a polygon lying inside one
  cell, and returns too few cells for a polygon around a pole (71 of 338
  at resolution 5 for the simulated pole row; for the antimeridian row
  403 of 404, with or without splitting the shape at 180 degrees). The
  package therefore finds touched cells from boundary points, their
  first ring and the cells whose centre is inside, tests each candidate
  on the sphere with `s2`, and descends the H3 hierarchy for shapes
  across the antimeridian or around a pole. These steps are part of
  `encode_h3o`, but not of the per-package comparison.
- The inside-row measure samples box edges at 64 points; a reach shorter
  than that spacing between two sample points would go unseen.
