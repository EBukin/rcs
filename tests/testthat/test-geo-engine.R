# Geocoding engines (plan 0002, D31): per-row validation on the sphere,
# rebuild, its check, the planar engine and the planar fallback.

engines <- c("auto", "s2", "planar")

invalid_cells <- function() {
  sim_cached("invalid_cells", ref_grid_cells(c(-27.4, -26.7), c(6.9, 7.6), 5))
}

test_that("sphere-invalid rows are rebuilt and match the brute force on the sphere", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  g <- sf::st_geometry(x)
  hex <- invalid_cells()
  rebuilt <- s2::s2_rebuild(s2::as_s2_geography(g[21:22], check = FALSE))
  ref <- list(ref_engine_sphere(rebuilt[1], hex), ref_engine_sphere(rebuilt[2], hex))
  for (use in c(TRUE, FALSE)) {
    local_s2(use)
    for (engine in c("auto", "s2")) {
      out <- geo_h3_rows(g, 5L, geocode_engine = engine)
      expect_identical(out$rebuilt, 21:22, info = engine)
      expect_identical(out$fallback, integer(), info = engine)
      for (k in 1:2) {
        row <- engine_row(out, 20L + k)
        expect_identical(row$h3, ref[[k]]$h3, info = paste(engine, k))
        expect_identical(row$cells, ref[[k]]$cells, info = paste(engine, k))
        expect_equal(row$share, ref[[k]]$share, tolerance = 1e-6, info = paste(engine, k))
        expect_equal(sum(row$share), 1, tolerance = 1e-6)
      }
    }
  }
})

test_that("the planar engine matches the brute force in the plane", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  g <- sf::st_geometry(x)
  hex <- invalid_cells()
  ref <- list(ref_engine_planar(g[21], hex), ref_engine_planar(g[22], hex))
  for (use in c(TRUE, FALSE)) {
    local_s2(use)
    out <- geo_h3_rows(g, 5L, geocode_engine = "planar")
    expect_identical(out$rebuilt, integer())
    expect_identical(out$fallback, integer())
    for (k in 1:2) {
      row <- engine_row(out, 20L + k)
      expect_identical(row$h3, ref[[k]]$h3, info = k)
      expect_identical(row$cells, ref[[k]]$cells, info = k)
      expect_equal(row$share, ref[[k]]$share, tolerance = 1e-6, info = k)
      expect_equal(sum(row$share), 1, tolerance = 1e-6)
    }
    # every crossing row has shares that sum to 1
    sums <- tapply(out$index$share, out$index$row, sum)
    expect_equal(unname(as.numeric(sums)), rep(1, length(sums)), tolerance = 1e-6)
  }
})

test_that("long edges: s2 cells follow the sphere, planar cells the plane", {
  skip_below_level("default")
  skip_if_no_h3()
  g <- geo_sfc_of_wkt(geo_long_edge_wkt())
  sphere <- h3_as_hex(geo_cells_touched(g, 5L)[[1]])
  out_s2 <- geo_h3_rows(g, 5L, geocode_engine = "s2")
  expect_identical(engine_row(out_s2, 1L)$cells, sphere)

  disk <- unique(as.character(h3o::flatten_h3(h3o::grid_disk(h3o::h3_from_strings(sphere), 4L))))
  planar <- local({
    local_s2(FALSE)
    polygons <- ref_cell_polygons(disk)
    sort(disk[lengths(suppressMessages(sf::st_intersects(polygons, g))) > 0], method = "radix")
  })
  out_planar <- geo_h3_rows(g, 5L, geocode_engine = "planar")
  row <- engine_row(out_planar, 1L)
  expect_identical(row$cells, planar)
  expect_equal(sum(row$share), 1, tolerance = 1e-6)
  # some planar cells lie beyond the first ring of the sphere's cells
  first_ring <- unique(as.character(h3o::flatten_h3(h3o::grid_disk(h3o::h3_from_strings(sphere), 1L))))
  expect_gt(length(setdiff(planar, first_ring)), 0)
})

test_that("auto falls back to planar when the rebuild is empty or not faithful", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  g <- sf::st_geometry(x)
  planar <- geo_h3_rows(g, 5L, geocode_engine = "planar")
  check_fallback <- function(out) {
    expect_identical(out$fallback, 21:22)
    expect_identical(out$rebuilt, integer())
    for (i in 21:22) {
      row <- engine_row(out, i)
      expect_false(is.na(row$h3))
      expect_equal(sum(row$share), 1, tolerance = 1e-6)
      expect_identical(row, engine_row(planar, i))
    }
  }

  local_mocked_bindings(geo_rebuild = function(geog) {
    s2::as_s2_geography(rep("GEOMETRYCOLLECTION EMPTY", length(geog)))
  })
  check_fallback(geo_h3_rows(g, 5L, geocode_engine = "auto"))

  complement <- function(geog) {
    s2::s2_difference(s2::as_s2_geography(TRUE), geog)
  }
  # the complement is a real geography, not an error
  probe <- complement(s2::as_s2_geography(g[21:22], check = FALSE))
  expect_false(any(s2::s2_is_empty(probe)))
  local_mocked_bindings(geo_rebuild = complement)
  check_fallback(geo_h3_rows(g, 5L, geocode_engine = "auto"))
})

test_that("an invalid row does not change the other rows of its chunk", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  g <- sf::st_geometry(x)
  alone <- geo_h3_rows(g[1:20], 5L)
  together <- geo_h3_rows(g, 5L)
  expect_identical(together$h3[1:20], alone$h3)
  expect_identical(
    together$index[together$index$row <= 20, , drop = FALSE],
    alone$index,
    ignore_attr = TRUE
  )
  # the same with every row alone
  for (r in unique(alone$index$row)) {
    single <- geo_h3_rows(g[r], 5L)
    expect_identical(engine_row(single, 1L)$cells, engine_row(together, r)$cells)
    expect_identical(engine_row(single, 1L)$share, engine_row(together, r)$share)
  }
})

test_that("engines are deterministic", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  for (engine in engines) {
    a <- geo_encode(x, geocode_engine = engine)
    b <- geo_encode(x, geocode_engine = engine)
    expect_identical(a, b, info = engine)
  }
})

test_that("geo_encode() reports order, rebuilt and fallback as input rows", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  out <- geo_encode(x, geocode_engine = "auto")
  expect_identical(out$data$id, x$id[out$order])
  expect_identical(sort(out$order), seq_len(nrow(x)))
  expect_identical(out$rebuilt, 21:22)
  expect_identical(out$fallback, integer())
  # rows given in another order report their own row numbers
  y <- x[c(22, 1:21), ]
  out <- geo_encode(y, geocode_engine = "auto")
  expect_identical(out$rebuilt, c(1L, 22L))
  expect_identical(out$data$id, y$id[out$order])
  out <- geo_encode(x, geocode = FALSE)
  expect_identical(out$rebuilt, integer())
  expect_identical(out$fallback, integer())
  expect_identical(out$data$id, x$id[out$order])
})

test_that("inside rows get the same cell from every engine", {
  skip_if_no_h3()
  x <- sim_polygons()[1:150, ]
  g <- sf::st_geometry(x)
  out <- lapply(engines, function(e) geo_h3_rows(g, 5L, geocode_engine = e))
  inside <- setdiff(seq_along(g), out[[1]]$index$row)
  expect_gt(length(inside), 0)
  for (k in 2:3) {
    expect_identical(out[[k]]$h3[inside], out[[1]]$h3[inside], info = engines[[k]])
    expect_identical(setdiff(seq_along(g), out[[k]]$index$row), inside, info = engines[[k]])
  }
})

test_that("antimeridian and pole rows get the same cells from every engine", {
  skip_below_level("default")
  skip_if_no_h3()
  x <- sim_polygons(special = TRUE)
  g <- sf::st_geometry(x)[x$id %in% c(501L, 502L)]
  out <- lapply(engines, function(e) geo_h3_rows(g, 5L, geocode_engine = e))
  for (k in 2:3) {
    expect_identical(out[[k]]$h3, out[[1]]$h3, info = engines[[k]])
    expect_identical(out[[k]]$index, out[[1]]$index, info = engines[[k]])
  }
})

test_that("valid simulated rows under auto equal the brute-force reference", {
  skip_if_no_h3()
  x <- sim_polygons()
  n <- if (test_level() == "cran") 15L else 200L
  ids <- withr::with_seed(11, sort(sample(10:500, n)))
  g <- sf::st_geometry(x)[match(ids, x$id)]
  out <- geo_h3_rows(g, 5L, geocode_engine = "auto")
  expect_identical(out$rebuilt, integer())
  expect_identical(out$fallback, integer())
  ref <- ref_h3(g, sim_cached("box_cells_5", ref_grid_cells(c(-30.6, -23.4), c(5.4, 9.6), 5)))
  for (k in seq_along(ids)) {
    expect_identical(out$h3[[k]], ref[[k]]$h3, info = ids[[k]])
    row <- engine_row(out, k)
    if (length(row$cells) > 0) {
      expect_identical(row$cells, ref[[k]]$cells, info = ids[[k]])
      expect_equal(row$share, ref[[k]]$share, tolerance = 1e-6, info = ids[[k]])
    } else {
      expect_identical(ref[[k]]$cells, ref[[k]]$h3, info = ids[[k]])
    }
  }
})

test_that("projected data follow the engines on the EPSG:4326 copy", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  p <- sf::st_transform(x, 32626)
  for (engine in engines) {
    a <- geo_encode(x, geocode_engine = engine)
    b <- geo_encode(p, geocode_engine = engine)
    expect_identical(b$rebuilt, a$rebuilt, info = engine)
    expect_identical(b$fallback, a$fallback, info = engine)
    expect_identical(h3_as_hex(b$data$h3), h3_as_hex(a$data$h3), info = engine)
  }
})

test_that("geo_rebuild() wraps s2_rebuild()", {
  geog <- s2::as_s2_geography(geo_sfc_of_wkt(geo_invalid_wkt()), check = FALSE)
  expect_identical(
    s2::s2_as_binary(geo_rebuild(geog)),
    s2::s2_as_binary(s2::s2_rebuild(geog))
  )
})
