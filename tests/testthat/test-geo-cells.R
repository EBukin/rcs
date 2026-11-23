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

# Degenerate rings (plan 0003, fix A) -------------------------------------------

# Rings that sf::st_segmentize() (lwgeom, geodesic) collapses to fewer than 4
# points, closed at (x, y): three points 1e-13 degrees apart (1 point left),
# four points 1e-14 apart, and a zero-area spike A, B, A, A about 4 m long
# (3 points left). Each holds no area.
degenerate_ring <- function(kind, x, y) {
  switch(kind,
    tiny = cbind(c(x, x + 1e-13, x, x), c(y, y, y + 1e-13, y)),
    near = cbind(c(x, x + 1e-14, x + 1e-14, x), c(y, y, y + 1e-14, y)),
    spike = cbind(c(x, x + 5e-5, x, x), c(y, y, y, y))
  )
}

# A box of about 15 by 17 km at 30E 48N: wider than a resolution-5 edge, so
# its interior is filled by centre (the branch that densifying breaks).
degenerate_outer <- function() {
  cbind(c(30, 30.2, 30.2, 30, 30), c(48, 48, 48.15, 48.15, 48))
}

polygon_sfc <- function(...) {
  sf::st_sfc(sf::st_polygon(list(...)), crs = 4326)
}

# Cells and shares of each row of `x` by geo_encode(): a data frame (id,
# cell, share) sorted by id and cell; a row inside one cell has its h3 with
# share 1.
encoded_by_id <- function(x, ...) {
  out <- geo_encode(x, ...)
  data <- out$data
  index <- out$index
  inside <- !is.na(data$h3) & !as.character(data$.rcs_id) %in% as.character(index$.rcs_id)
  rows <- rbind(
    data.frame(
      id = data$id[match(as.character(index$.rcs_id), as.character(data$.rcs_id))],
      cell = h3_as_hex(index$h3), share = index$share
    ),
    data.frame(id = data$id[inside], cell = h3_as_hex(data$h3[inside]), share = rep(1, sum(inside)))
  )
  rows[order(rows$id, rows$cell, method = "radix"), , drop = FALSE]
}

# Same ids and cells, shares equal up to rounding (row names ignored).
expect_same_encoding <- function(object, expected) {
  expect_identical(as.list(object[c("id", "cell")]), as.list(expected[c("id", "cell")]))
  expect_equal(object$share, expected$share, tolerance = 1e-9)
}

test_that("a hole that densifying collapses to one point changes no cell and does not abort a write", {
  skip_if_no_h3()
  outer <- degenerate_outer()
  holed <- polygon_sfc(outer, degenerate_ring("tiny", 30.1, 48.07))
  plain <- polygon_sfc(outer)
  # the premise: lwgeom leaves the hole with 1 point
  dense <- sf::st_segmentize(holed, h3_edge_m[[6]] / 3)
  expect_lt(nrow(unclass(dense[[1]])[[2]]), 4L)

  expect_identical(geo_cells_touched(holed, 5L), geo_cells_touched(plain, 5L))
  # as a MULTIPOLYGON, st_cast() is a no-op and h3o would panic instead
  expect_identical(geo_cells_touched(sf::st_cast(holed, "MULTIPOLYGON"), 5L), geo_cells_touched(plain, 5L))

  st <- store_connect(withr::local_tempdir(), create = TRUE)
  expect_no_error(
    store_write(st, sf::st_sf(id = 1L, geometry = holed), "holed", title = "t", description = "t", key = "id")
  )
})

test_that("a zero-area spike hole and a hole of near-identical points change no cell", {
  skip_if_no_h3()
  outer <- degenerate_outer()
  holed <- polygon_sfc(outer, degenerate_ring("spike", 30.05, 48.03), degenerate_ring("near", 30.15, 48.1))
  plain <- polygon_sfc(outer)
  dense <- sf::st_segmentize(holed, h3_edge_m[[6]] / 3)
  expect_true(all(vapply(unclass(dense[[1]])[-1], nrow, integer(1)) < 4L))

  expect_identical(geo_cells_touched(holed, 5L), geo_cells_touched(plain, 5L))
  expect_identical(geo_cells_touched(sf::st_cast(holed, "MULTIPOLYGON"), 5L), geo_cells_touched(plain, 5L))
  expect_same_encoding(
    encoded_by_id(sf::st_sf(id = 1L, geometry = holed)),
    encoded_by_id(sf::st_sf(id = 1L, geometry = plain))
  )
})

test_that("a MULTIPOLYGON part whose outer ring collapses changes no cell and does not panic h3o", {
  skip_if_no_h3()
  # the degenerate part lies in a 750 m window cut out of the box, so the
  # cell around it is touched by the box anyway
  window <- cbind(c(30.095, 30.095, 30.105, 30.105, 30.095), c(48.065, 48.075, 48.075, 48.065, 48.065))
  with_part <- sf::st_sfc(
    sf::st_multipolygon(list(list(degenerate_outer(), window), list(degenerate_ring("tiny", 30.1, 48.07)))),
    crs = 4326
  )
  without <- sf::st_sfc(sf::st_multipolygon(list(list(degenerate_outer(), window))), crs = 4326)

  expect_no_error(touched <- geo_cells_touched(with_part, 5L))
  expect_identical(touched, geo_cells_touched(without, 5L))
  for (engine in c("auto", "planar")) {
    expect_same_encoding(
      encoded_by_id(sf::st_sf(id = 1L, geometry = with_part), geocode_engine = engine),
      encoded_by_id(sf::st_sf(id = 1L, geometry = without), geocode_engine = engine)
    )
  }
})

test_that("one degenerate row leaves the cells and shares of the other rows in its chunk unchanged", {
  skip_if_no_h3()
  outer <- degenerate_outer()
  shifted <- outer + rep(c(0.5, 0.2), each = nrow(outer))
  multi <- sf::st_multipolygon(list(list(outer + 1), list(outer + rep(c(1.3, 1), each = nrow(outer)))))
  small <- cbind(c(29.5, 29.51, 29.51, 29.5, 29.5), c(47.5, 47.5, 47.51, 47.51, 47.5))
  holed <- sf::st_polygon(list(
    outer + 2, degenerate_ring("tiny", 32.1, 50.07), degenerate_ring("spike", 32.05, 50.03),
    degenerate_ring("near", 32.15, 50.1)
  ))
  others <- sf::st_sf(
    id = 1:4,
    geometry = sf::st_sfc(
      sf::st_polygon(list(outer)), sf::st_polygon(list(shifted)), multi, sf::st_polygon(list(small)),
      crs = 4326
    )
  )
  chunk <- rbind(others, sf::st_sf(id = 5L, geometry = sf::st_sfc(holed, crs = 4326)))

  out <- encoded_by_id(chunk)
  alone <- encoded_by_id(others)
  expect_same_encoding(out[out$id != 5L, ], alone)
  plain <- encoded_by_id(sf::st_sf(id = 5L, geometry = polygon_sfc(outer + 2)))
  expect_same_encoding(out[out$id == 5L, ], plain)
})

test_that("degenerate holes injected into simulated polygons change no cell or share", {
  skip_if_no_h3()
  edge <- h3_edge_m[[6]]
  # the random rows (ids above 9; the first rows are fixed edge cases such as
  # slivers and empty geometries)
  x <- rcs_sim_polygons(60, seed = 4)
  x <- x[x$id > 9, ][1:50, ]

  withr::with_seed(11, {
    # rcs_sim_polygons() rows are mostly smaller than a resolution-5 edge:
    # scale each about its box centre to 1.2 to 3 edges wide
    plain <- lapply(sf::st_geometry(x), function(g) {
      box <- sf::st_bbox(g)
      centre <- c(mean(box[c("xmin", "xmax")]), mean(box[c("ymin", "ymax")]))
      extent <- geo_extent_m(as.list(box))
      (g - centre) * (stats::runif(1, 1.2, 3) * edge / extent) + centre
    })
    holed <- lapply(plain, function(g) {
      # interior points at least 0.01 degrees from every ring, in the plane
      inner <- sf::st_buffer(sf::st_sfc(g), -0.01)
      box <- sf::st_bbox(inner)
      for (k in seq_len(sample(1:3, 1))) {
        tries <- sf::st_cast(sf::st_sfc(sf::st_multipoint(cbind(
          stats::runif(100, box[["xmin"]], box[["xmax"]]),
          stats::runif(100, box[["ymin"]], box[["ymax"]])
        ))), "POINT")
        point <- tries[[which(lengths(sf::st_intersects(tries, inner)) > 0)[[1]]]]
        ring <- degenerate_ring(sample(c("tiny", "near", "spike"), 1), point[[1]], point[[2]])
        if (inherits(g, "POLYGON")) {
          g <- sf::st_polygon(c(unclass(g), list(ring)))
        } else {
          parts <- unclass(g)
          at <- which(vapply(parts, function(p) {
            lengths(sf::st_intersects(sf::st_sfc(point), sf::st_sfc(sf::st_polygon(p)))) > 0
          }, logical(1)))[[1]]
          parts[[at]] <- c(parts[[at]], list(ring))
          g <- sf::st_multipolygon(parts)
        }
      }
      g
    })
  })
  plain <- sf::st_sf(id = x$id, geometry = sf::st_sfc(plain, crs = 4326))
  holed <- sf::st_sf(id = x$id, geometry = sf::st_sfc(holed, crs = 4326))
  expect_true(all(geo_extent_m(geo_envelope(geo_wkb(sf::st_geometry(plain)))) > edge))
  expect_true(all(wk::wk_count(holed)$n_ring > wk::wk_count(plain)$n_ring))

  expect_identical(geo_cells_touched(holed, 5L), geo_cells_touched(plain, 5L))
  expect_same_encoding(encoded_by_id(holed), encoded_by_id(plain))
})

test_that("geo_drop_short_rings() drops short rings and polygons with a short outer ring, and nothing else", {
  square <- cbind(c(0, 1, 1, 0, 0), c(0, 0, 1, 1, 0))
  dot <- matrix(c(0.5, 0.5), ncol = 2)
  polygons <- sf::st_sfc(
    sf::st_polygon(list(square, dot)),
    sf::st_multipolygon(list(list(dot), list(square, dot))),
    sf::st_polygon(list(dot)),
    sf::st_multipolygon(list(list(dot), list(dot))),
    sf::st_polygon(list(square)),
    sf::st_polygon()
  )
  out <- geo_drop_short_rings(polygons)
  expect_identical(out[[1]], sf::st_polygon(list(square)))
  expect_identical(out[[2]], sf::st_multipolygon(list(list(square))))
  # an element left with no polygon becomes empty, of its own type
  expect_identical(out[[3]], sf::st_polygon())
  expect_identical(out[[4]], sf::st_multipolygon())
  expect_identical(out[[5]], polygons[[5]])
  expect_identical(out[[6]], polygons[[6]])

  # XYZ, XYM and XYZM keep their dimension
  for (dim in c("XYZ", "XYM", "XYZM")) {
    extra <- nchar(dim) - 2
    square_d <- cbind(square, matrix(1, nrow(square), extra))
    dot_d <- cbind(dot, matrix(1, 1, extra))
    out <- geo_drop_short_rings(sf::st_sfc(
      sf::st_polygon(list(square_d, dot_d), dim = dim),
      sf::st_multipolygon(list(list(dot_d), list(square_d)), dim = dim),
      sf::st_polygon(list(dot_d), dim = dim)
    ))
    expect_identical(out[[1]], sf::st_polygon(list(square_d), dim = dim), info = dim)
    expect_identical(out[[2]], sf::st_multipolygon(list(list(square_d)), dim = dim), info = dim)
    expect_identical(out[[3]], sf::st_polygon(dim = dim), info = dim)
  }

  # a ring with no point is short: sf's constructors refuse one, WKB can carry it
  none <- matrix(numeric(), ncol = 2)
  p <- structure(list(square, none), class = c("XY", "POLYGON", "sfg"))
  expect_identical(geo_drop_short_rings(sf::st_sfc(p))[[1]], sf::st_polygon(list(square)))

  # an sfc without short rings comes back as the same object
  x <- sf::st_geometry(rcs_sim_polygons(40, seed = 2))
  x <- sf::st_set_precision(x[sf::st_geometry_type(x) %in% c("POLYGON", "MULTIPOLYGON")], 1e6)
  expect_identical(geo_drop_short_rings(x), x)
  # with one short ring, only that element changes; precision and CRS stay
  first <- which(sf::st_geometry_type(x) == "POLYGON")[[1]]
  y <- x
  y[[first]] <- sf::st_polygon(c(unclass(x[[first]]), list(matrix(c(-27, 7), ncol = 2))))
  out <- geo_drop_short_rings(y)
  expect_identical(out[[first]], x[[first]])
  expect_identical(sfc_list(out[-first]), sfc_list(x[-first]))
  expect_identical(attr(out, "precision"), 1e6)
  expect_identical(sf::st_crs(out), sf::st_crs(x))
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
