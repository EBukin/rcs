# Spatial correctness of h3, index rows, cells touched and covering cells,
# against the brute-force references of helper-geo-reference.R.

box_cells <- function(res = 5) {
  sim_cached(paste0("box_cells_", res), ref_grid_cells(c(-30.6, -23.4), c(5.4, 9.6), res))
}

special_cells <- function() {
  sim_cached("special_cells", c(
    ref_grid_cells(list(c(178.4, 180), c(-180, -178.4)), c(5.4, 9.6), 5),
    ref_grid_cells(c(-180, 180), c(87.8, 90), 5, step = 0.02)
  ))
}

encoded_polygons <- function() {
  sim_cached("encoded_polygons", geo_encode(sim_polygons(special = TRUE)))
}

# Compare the encoding of the rows `ids` of `x` with the reference.
expect_matches_reference <- function(x, encoded, ids, hex) {
  data <- encoded$data
  index <- encoded$index
  index_id <- data$id[match(as.character(index$.rcs_id), as.character(data$.rcs_id))]
  ref <- ref_h3(sf::st_geometry(x)[match(ids, x$id)], hex)
  for (k in seq_along(ids)) {
    i <- ids[[k]]
    row <- which(data$id == i)
    expect_identical(h3_as_hex(data$h3[row]), ref[[k]]$h3, info = paste("h3 of id", i))
    at <- which(index_id == i)
    if (length(at) > 0) {
      cells <- h3_as_hex(index$h3[at])
      expect_identical(sort(cells, method = "radix"), ref[[k]]$cells, info = paste("index of id", i))
      expect_equal(index$share[at][order(cells, method = "radix")], ref[[k]]$share,
        tolerance = 1e-6, info = paste("shares of id", i)
      )
      expect_true(all(index$h3_main[at] == data$h3[row]), info = paste("h3_main of id", i))
    } else if (!is.na(ref[[k]]$h3)) {
      # an inside row touches its own cell only
      expect_identical(ref[[k]]$cells, ref[[k]]$h3, info = paste("inside row id", i))
    }
  }
}

# Rows of x tested at the current level: a sample at `cran`, all above.
level_ids <- function(ids, cran = 15L) {
  if (test_level() == "cran") {
    withr::with_seed(5, sort(sample(ids, min(cran, length(ids)))))
  } else {
    ids
  }
}

test_that("h3 and index rows equal the reference for the simulated polygons", {
  skip_if_no_h3()
  x <- sim_polygons(special = TRUE)
  encoded <- encoded_polygons()
  # the large shapes (ids 1 to 3) are slow for the reference
  ids <- c(4:9, level_ids(10:500))
  if (test_level() != "cran") {
    ids <- c(1:3, ids)
  }
  expect_matches_reference(x, encoded, ids, box_cells())
})

test_that("antimeridian and pole rows get the reference h3 and index rows", {
  skip_below_level("default")
  skip_if_no_h3()
  x <- sim_polygons(special = TRUE)
  expect_matches_reference(x, encoded_polygons(), c(501L, 502L), special_cells())
  data <- encoded_polygons()$data
  # their bbox is the plain box of their coordinates
  pole <- data$bbox[data$id == 502L, ]
  expect_equal(c(pole$xmin, pole$xmax), c(-180, 150))
})

test_that("the special rows are crossing rows found on the sphere", {
  skip_if_no_h3()
  x <- sim_polygons(special = TRUE)
  encoded <- encoded_polygons()
  data <- encoded$data
  ids <- data$.rcs_id[data$id %in% c(501L, 502L)]
  expect_true(all(as.character(ids) %in% as.character(encoded$index$.rcs_id)))
  # the pole row touches the cell holding the pole
  pole_cell <- ref_cell_hex(0, 90, 5)
  pole_id <- data$.rcs_id[data$id == 502L]
  expect_true(pole_cell %in% h3_as_hex(encoded$index$h3[encoded$index$.rcs_id == pole_id]))
  # the antimeridian row touches cells on both sides
  am_id <- data$.rcs_id[data$id == 501L]
  am_cells <- encoded$index$h3[encoded$index$.rcs_id == am_id]
  centres <- sf::st_coordinates(sf::st_centroid(ref_cell_polygons(h3_as_hex(am_cells))))
  expect_true(any(centres[, "X"] > 179) && any(centres[, "X"] < -179))
})

test_that("points and lines get the reference h3 and index rows", {
  skip_if_no_h3()
  points <- sim_points()
  expect_matches_reference(points, geo_encode(points), level_ids(points$id, 20L), box_cells())
  lines <- sim_lines()
  expect_matches_reference(lines, geo_encode(lines), level_ids(lines$id, 12L), box_cells())
})

test_that("a projected CRS gives the same cells as EPSG:4326", {
  skip_if_no_h3()
  projected <- geo_encode(sim_polygons_projected())$data
  plain <- encoded_polygons()$data
  plain <- plain[plain$id <= 500, ]
  expect_identical(
    h3_as_hex(projected$h3[order(projected$id)]),
    h3_as_hex(plain$h3[order(plain$id)])
  )
})

test_that("other resolutions match the reference", {
  skip_if_no_h3()
  x <- sim_polygons()
  ids <- level_ids(4:500, 6L)
  for (res in c(3L, 7L)) {
    if (res == 7L) {
      # only around each chosen row: the whole box holds too many cells
      ids <- ids[ids > 9]
      hex <- unique(unlist(lapply(ids, function(i) {
        box <- sf::st_bbox(sf::st_geometry(x)[x$id == i])
        ref_grid_cells(
          c(box[["xmin"]] - 0.02, box[["xmax"]] + 0.02),
          c(box[["ymin"]] - 0.02, box[["ymax"]] + 0.02), res
        )
      })))
    } else {
      hex <- ref_grid_cells(c(-30.6, -23.4), c(5.4, 9.6), res)
    }
    expect_matches_reference(x, geo_encode(x[match(ids, x$id), ], h3_res = res), ids, hex)
  }
})

test_that("geo_cells_touched() equals the reference", {
  skip_if_no_h3()
  x <- sim_polygons()
  ids <- c(4:9, level_ids(10:500, 12L))
  touched <- geo_cells_touched(x[match(ids, x$id), ], 5L)
  ref <- ref_touched(sf::st_geometry(x)[match(ids, x$id)], box_cells())
  expect_identical(lapply(touched, h3_as_hex), ref)
  expect_identical(touched[[which(ids == 9L)]], bit64::integer64())
  for (cells in touched) {
    expect_s3_class(cells, "integer64")
  }
  # sf and sfc, and a projected CRS, give the same cells
  expect_identical(geo_cells_touched(sf::st_geometry(x[1:12, ]), 5L), geo_cells_touched(x[1:12, ], 5L))
  expect_identical(geo_cells_touched(sim_polygons_projected()[1:12, ], 5L), geo_cells_touched(x[1:12, ], 5L))
  expect_error(geo_cells_touched(sf::st_set_crs(x[1:2, ], NA), 5L), class = "rcs_error_geo")
  expect_error(geo_cells_touched(x[1:2, ], 16L), class = "rcs_error_argument")
})

test_that("h3o's intersect mode alone would miss cells (why the fallback is used)", {
  skip_if_no_h3()
  x <- sim_polygons()
  small <- sf::st_cast(sf::st_geometry(x)[200:210], "MULTIPOLYGON")
  expect_true(any(lengths(h3o::sfc_to_cells(small, 5L, "intersect")) == 0))
  expect_true(all(lengths(geo_cells_touched(small, 5L)) > 0))
})

# Covering ---------------------------------------------------------------------

# Random query shapes in the box, of every kind the plan names.
random_query <- function(i) {
  withr::with_seed(1000 + i, {
    kind <- c("square", "strip", "rectangle", "hole", "point", "cell")[(i - 1) %% 6 + 1]
    cx <- stats::runif(1, -29.5, -24.5)
    cy <- stats::runif(1, 6.5, 8.5)
    ring <- function(x, y) list(cbind(c(x, x[1]), c(y, y[1])))
    shape <- switch(kind,
      square = {
        r <- stats::runif(1, 0.001, 0.1)
        sf::st_polygon(ring(cx + r * c(-1, 1, 1, -1), cy + r * c(-1, -1, 1, 1)))
      },
      strip = {
        len <- stats::runif(1, 0.5, 2)
        sf::st_polygon(ring(cx + c(0, len, len, 0), cy + c(0, 0, 0.0005, 0.0005)))
      },
      rectangle = {
        w <- stats::runif(1, 0.5, 1.5)
        h <- stats::runif(1, 0.3, 0.8)
        sf::st_polygon(ring(cx + c(-w, w, w, -w) / 2, cy + c(-h, -h, h, h) / 2))
      },
      hole = sf::st_polygon(c(
        ring(cx + c(-0.3, 0.3, 0.3, -0.3), cy + c(-0.2, -0.2, 0.2, 0.2)),
        ring(cx + c(-0.1, -0.1, 0.1, 0.1), cy + c(-0.1, 0.1, 0.1, -0.1))
      )),
      point = sf::st_point(c(cx, cy)),
      cell = NULL
    )
    if (kind == "cell") {
      res <- sample(2:9, 1)
      return(list(kind = kind, res = res, cell = ref_cell_hex(cx, cy, res)))
    }
    list(kind = kind, shape = sf::st_sfc(shape, crs = 4326))
  })
}

test_that("covering cells contain every cell that intersects the query", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  n <- property_cases(default = 200L, full = 600L, cran = 6L)
  for (i in seq_len(n)) {
    q <- random_query(i)
    h3_res <- if (i %% 5 == 0) 6L else 5L
    if (q$kind == "cell") {
      shape <- ref_cell_polygons(q$cell)
      covering <- suppressMessages(geo_covering(q$cell, h3_res, crs))
    } else {
      shape <- q$shape
      covering <- geo_covering(shape, h3_res, crs)
    }
    box <- sf::st_bbox(shape)
    margin <- 0.2
    ref <- ref_query_cells(
      shape, h3_res,
      c(box[["xmin"]] - margin, box[["xmax"]] + margin),
      c(box[["ymin"]] - margin, box[["ymax"]] + margin)
    )
    cells <- h3_as_hex(covering$cells)
    expect_true(all(ref$sphere %in% cells), info = paste(i, q$kind))
    expect_true(all(ref$planar %in% cells), info = paste(i, q$kind))
    expect_identical(cells, sort(unique(cells), method = "radix"))
  }
})

test_that("covering returns shape, bbox and cells in the data CRS", {
  skip_if_no_h3()
  q <- sf::st_sfc(sf::st_polygon(list(cbind(c(-28, -27, -27, -28, -28), c(7, 7, 7.5, 7.5, 7)))), crs = 4326)
  same <- geo_covering(q, 5L, sf::st_crs(4326)$ProjJson)
  expect_s3_class(same$shape, "sfc")
  expect_length(same$shape, 1)
  expect_identical(sf::st_as_binary(same$shape), sf::st_as_binary(q))
  expect_equal(same$bbox, c(xmin = -28, ymin = 7, xmax = -27, ymax = 7.5))
  expect_s3_class(same$cells, "integer64")

  projected <- geo_covering(q, 5L, sf::st_crs(32626)$ProjJson)
  expect_true(sf::st_crs(projected$shape) == sf::st_crs(32626))
  # densified before the change of CRS
  expect_gt(nrow(wk::wk_coords(projected$shape)), 5)
  box <- sf::st_bbox(projected$shape)
  expect_equal(projected$bbox, unclass(box)[c("xmin", "ymin", "xmax", "ymax")], ignore_attr = TRUE)
  expect_identical(projected$cells, same$cells)

  # a query in a projected CRS on data in EPSG:4326
  back <- geo_covering(sf::st_transform(q, 32626), 5L, sf::st_crs(4326)$ProjJson)
  expect_true(sf::st_crs(back$shape) == sf::st_crs(4326))
  expect_true(all(h3_as_hex(same$cells) %in% h3_as_hex(back$cells)) ||
    length(setdiff(h3_as_hex(same$cells), h3_as_hex(back$cells))) < 3)

  # a bbox object and an sf object
  bb <- geo_covering(sf::st_bbox(q), 5L, sf::st_crs(4326)$ProjJson)
  expect_identical(bb$cells, same$cells)
  sfq <- geo_covering(sf::st_sf(id = 1, geometry = q), 5L, sf::st_crs(4326)$ProjJson)
  expect_identical(sfq$cells, same$cells)

  # no geocodes: no cells
  none <- geo_covering(q, NA, sf::st_crs(4326)$ProjJson)
  expect_null(none$cells)
  expect_equal(none$bbox, same$bbox)
})

test_that("several query geometries are combined", {
  skip_if_no_h3()
  a <- sf::st_point(c(-28, 7))
  b <- sf::st_point(c(-26, 8))
  q <- sf::st_sfc(a, b, crs = 4326)
  out <- geo_covering(q, 5L, sf::st_crs(4326)$ProjJson)
  expect_length(out$shape, 1)
  one <- geo_covering(sf::st_sfc(a, crs = 4326), 5L, sf::st_crs(4326)$ProjJson)$cells
  two <- geo_covering(sf::st_sfc(b, crs = 4326), 5L, sf::st_crs(4326)$ProjJson)$cells
  expect_setequal(h3_as_hex(out$cells), c(h3_as_hex(one), h3_as_hex(two)))
  expect_length(one, 7)
})

test_that("hex, integer64 and H3 queries give the same covering", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  hex <- c(ref_cell_hex(-27.3, 7.2, 7), ref_cell_hex(-26.1, 8.1, 7))
  a <- suppressMessages(geo_covering(hex, 5L, crs))
  b <- suppressMessages(geo_covering(h3_as_int64(hex), 5L, crs))
  c <- suppressMessages(geo_covering(h3o::h3_from_strings(hex), 5L, crs))
  expect_identical(a, b)
  expect_identical(a, c)
  expect_error(geo_covering(suppressWarnings(as.numeric(h3_as_int64(hex))), 5L, crs), class = "rcs_error_h3_input")
  expect_snapshot(geo_covering(6.2e17, 5L, crs), error = TRUE)
})

test_that("a query cell finer than the stored resolution informs", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  fine <- ref_cell_hex(-27.3, 7.2, 8)
  expect_message(geo_covering(fine, 5L, crs), "finer")
  expect_no_message(geo_covering(ref_cell_hex(-27.3, 7.2, 4), 5L, crs))
  withr::local_options(rcs.quiet = TRUE)
  expect_no_message(geo_covering(fine, 5L, crs))
  # the stored cell holding the query cell is covered
  cells <- h3_as_hex(geo_covering(fine, 5L, crs)$cells)
  expect_true(ref_cell_hex(-27.3, 7.2, 5) %in% cells)
})

test_that("covering aborts on a shape without CRS or an empty shape", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  expect_error(geo_covering(sf::st_sfc(sf::st_point(c(1, 2))), 5L, crs), class = "rcs_error_geo")
  expect_error(geo_covering(sf::st_sfc(sf::st_polygon(), crs = 4326), 5L, crs), class = "rcs_error_geo")
  expect_error(geo_covering(sf::st_sfc(crs = 4326), 5L, crs), class = "rcs_error_geo")
  expect_error(geo_covering(NA_character_, 5L, crs), class = "rcs_error_geo")
  expect_snapshot(geo_covering(sf::st_sfc(sf::st_polygon(), crs = 4326), 5L, crs), error = TRUE)
})

# Completeness -----------------------------------------------------------------

# Rows the candidate rule of the spatial filter keeps for a covering: `h3` in
# the covering, or an index row in the covering.
candidate_ids <- function(encoded, cells) {
  data <- encoded$data
  hex <- h3_as_hex(cells)
  direct <- data$id[!is.na(data$h3) & h3_as_hex(data$h3) %in% hex]
  via <- encoded$index$.rcs_id[h3_as_hex(encoded$index$h3) %in% hex]
  unique(c(direct, data$id[as.character(data$.rcs_id) %in% as.character(via)]))
}

test_that("the candidate rule finds every row that intersects a query", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  sets <- list(
    polygons = list(x = sim_polygons(), encoded = encoded_polygons()),
    points = list(x = sim_points(), encoded = geo_encode(sim_points())),
    lines = list(x = sim_lines(), encoded = geo_encode(sim_lines()))
  )
  n <- property_cases(default = 120L, full = 600L, cran = 4L)
  for (name in names(sets)) {
    x <- sets[[name]]$x
    encoded <- sets[[name]]$encoded
    for (i in seq_len(n)) {
      q <- random_query(i)
      shape <- if (q$kind == "cell") ref_cell_polygons(q$cell) else q$shape
      covering <- suppressMessages(geo_covering(if (q$kind == "cell") q$cell else shape, 5L, crs))
      found <- candidate_ids(encoded, covering$cells)
      for (s2 in c(TRUE, FALSE)) {
        old <- suppressMessages(sf::sf_use_s2(s2))
        hit <- x$id[lengths(suppressMessages(sf::st_intersects(x, covering$shape))) > 0]
        suppressMessages(sf::sf_use_s2(old))
        expect_true(all(hit %in% found), info = paste(name, i, q$kind, "s2", s2))
      }
    }
  }
})

test_that("queries find the antimeridian and pole rows, the main box does not", {
  skip_if_no_h3()
  crs <- sf::st_crs(4326)$ProjJson
  encoded <- encoded_polygons()
  sq <- function(x, y) sf::st_sfc(sf::st_polygon(list(cbind(x[c(1, 2, 2, 1, 1)], y[c(1, 1, 2, 2, 1)]))), crs = 4326)
  east <- geo_covering(sq(c(179.2, 179.6), c(7, 7.4)), 5L, crs)
  west <- geo_covering(sq(c(-179.6, -179.2), c(7, 7.4)), 5L, crs)
  across <- geo_covering(sq(c(179.8, -179.8), c(7, 7.4)), 5L, crs)
  pole <- geo_covering(sf::st_sfc(sf::st_point(c(10, 89.5)), crs = 4326), 5L, crs)
  main <- geo_covering(sq(c(-30, -24), c(6, 9)), 5L, crs)
  expect_true(501L %in% candidate_ids(encoded, east$cells))
  expect_true(501L %in% candidate_ids(encoded, west$cells))
  expect_true(501L %in% candidate_ids(encoded, across$cells))
  expect_null(across$bbox)
  expect_false(is.null(east$bbox))
  expect_true(502L %in% candidate_ids(encoded, pole$cells))
  expect_false(any(c(501L, 502L) %in% candidate_ids(encoded, main$cells)))
  # a query around the pole itself skips the box test
  cap <- sf::st_sfc(sf::st_polygon(list(cbind(c(seq(-180, 150, by = 30), -180), 89.8))), crs = 4326)
  around <- geo_covering(cap, 5L, crs)
  expect_null(around$bbox)
  expect_true(502L %in% candidate_ids(encoded, around$cells))
  expect_true(ref_cell_hex(0, 90, 5) %in% h3_as_hex(around$cells))
})
