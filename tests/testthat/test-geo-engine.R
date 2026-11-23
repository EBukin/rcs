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
  # the rebuilt spike (row 22) is still invalid on the sphere (plan 0003, B1)
  expect_identical(s2::s2_is_valid(rebuilt), c(TRUE, FALSE))
  ref <- list(ref_engine_sphere(rebuilt[1], hex), ref_engine_sphere(rebuilt[2], hex))
  ref_planar <- ref_engine_planar(g[22], hex)
  for (use in c(TRUE, FALSE)) {
    local_s2(use)
    for (engine in c("auto", "s2")) {
      out <- geo_h3_rows(g, 5L, geocode_engine = engine)
      # "s2" uses every rebuilt copy (D31); "auto" sends the spike, whose
      # rebuilt copy stays invalid, to the plane
      sphere_rows <- if (engine == "s2") 1:2 else 1L
      expect_identical(out$rebuilt, 20L + sphere_rows, info = engine)
      expect_identical(out$fallback, setdiff(21:22, 20L + sphere_rows), info = engine)
      if (engine == "auto") {
        row <- engine_row(out, 22L)
        expect_identical(row$h3, ref_planar$h3)
        expect_identical(row$cells, ref_planar$cells)
        expect_equal(row$share, ref_planar$share, tolerance = 1e-6)
      }
      for (k in sphere_rows) {
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

test_that("auto falls back to planar when the rebuilt copy stays invalid", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  g <- sf::st_geometry(x)
  # identity: the rebuilt copy is the invalid original, with the same measure
  local_mocked_bindings(geo_rebuild = function(geog) geog)
  out <- geo_h3_rows(g, 5L, geocode_engine = "auto")
  expect_identical(out$fallback, 21:22)
  expect_identical(out$rebuilt, integer())
  planar <- geo_planar_rows(geo_wkb(g[21:22]), 5L)
  for (k in 1:2) {
    row <- engine_row(out, 20L + k)
    ref <- planar[planar$from == k, , drop = FALSE]
    ref <- ref[order(ref$cell, method = "radix"), , drop = FALSE]
    expect_identical(row$cells, ref$cell, info = k)
    expect_equal(row$share, ref$share, tolerance = 1e-12, info = k)
    expect_equal(sum(row$share), 1, tolerance = 1e-6)
  }

  withr::local_options(rcs.quiet = TRUE)
  st <- store_connect(withr::local_tempdir(), create = TRUE)
  expect_warning(
    store_write(st, x, "invalid", title = "t", description = "t", key = "id"),
    class = "rcs_warning_s2_rebuild"
  )
})

test_that("s2 uses the rebuilt copy even when it stays invalid", {
  skip_if_no_h3()
  # the spike only: s2 cannot geocode the unrebuilt duplicate vertex of row
  # 21 at all, so the identity mock would abort there under "s2"
  g <- sf::st_geometry(geo_with_invalid())[c(1:20, 22)]
  local_mocked_bindings(geo_rebuild = function(geog) geog)
  out <- geo_h3_rows(g, 5L, geocode_engine = "s2")
  expect_identical(out$rebuilt, 21L)
  expect_identical(out$fallback, integer())
  expect_equal(sum(engine_row(out, 21L)$share), 1, tolerance = 1e-6)
  # the same mock under "auto" sends the row to the plane
  out <- geo_h3_rows(g, 5L, geocode_engine = "auto")
  expect_identical(out$rebuilt, integer())
  expect_identical(out$fallback, 21L)
})

test_that("a real rebuild that stays invalid falls back to planar under auto", {
  skip_if_no_h3()
  g <- geo_sfc_of_wkt(geo_stays_invalid_wkt())
  geog <- s2::as_s2_geography(g, check = FALSE)
  expect_false(s2::s2_is_valid(geog))
  expect_false(s2::s2_is_valid(s2::s2_rebuild(geog)))
  expect_true(local({
    local_s2(FALSE)
    sf::st_is_valid(g)
  }))

  out <- geo_h3_rows(g, 5L, geocode_engine = "auto")
  expect_identical(out$fallback, 1L)
  expect_identical(out$rebuilt, integer())
  planar <- geo_h3_rows(g, 5L, geocode_engine = "planar")
  expect_identical(engine_row(out, 1L), engine_row(planar, 1L))
  expect_equal(sum(out$index$share), 1, tolerance = 1e-6)
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
  # the rebuilt spike (row 22) stays invalid on the sphere: a fallback
  expect_identical(out$rebuilt, 21L)
  expect_identical(out$fallback, 22L)
  # rows given in another order report their own row numbers
  y <- x[c(22, 1:21), ]
  out <- geo_encode(y, geocode_engine = "auto")
  expect_identical(out$rebuilt, 22L)
  expect_identical(out$fallback, 1L)
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

# Rows invalid in the plane (plan 0003, fix C) ------------------------------------

# Cells and shares of `g` repaired by GEOS, geocoded by the planar engine.
planar_of_repaired <- function(g) {
  repaired <- local({
    local_s2(FALSE)
    sf::st_make_valid(g)
  })
  geo_h3_rows(repaired, 5L, geocode_engine = "planar")
}

test_that("rows invalid in the plane are repaired for geocoding, not stored repaired", {
  skip_if_no_h3()
  for (name in names(geo_plane_invalid_wkt())) {
    g <- geo_sfc_of_wkt(geo_plane_invalid_wkt()[[name]])
    expect_false(local({
      local_s2(FALSE)
      sf::st_is_valid(g)
    }), info = name)
    expect_false(s2::s2_is_valid(s2::as_s2_geography(g, check = FALSE)), info = name)
    ref <- engine_row(planar_of_repaired(g), 1L)
    expect_gt(length(ref$cells), 1)

    for (engine in c("planar", "auto")) {
      info <- paste(name, engine)
      out <- expect_no_error(geo_h3_rows(g, 5L, geocode_engine = engine))
      row <- engine_row(out, 1L)
      expect_identical(row$h3, ref$h3, info = info)
      expect_identical(row$cells, ref$cells, info = info)
      expect_equal(row$share, ref$share, tolerance = 1e-9, info = info)
      expect_equal(sum(row$share), 1, tolerance = 1e-9, info = info)
      expect_identical(out$fallback, if (engine == "auto") 1L else integer(), info = info)

      st <- store_connect(withr::local_tempdir(), create = TRUE)
      x <- sf::st_sf(id = 1L, geometry = g)
      suppressMessages(suppressWarnings(
        store_write(st, x, "shape",
          title = "t", description = "t", key = "id", geocode_engine = engine
        )
      ))
      back <- store_read(st, "shape")
      expect_identical(
        lapply(sf::st_as_binary(sf::st_geometry(back), EWKB = FALSE), as.raw),
        lapply(sf::st_as_binary(g, EWKB = FALSE), as.raw),
        info = info
      )
      index <- store_read(st, "shape__h3")
      expect_identical(sort(h3_as_hex(index$h3), method = "radix"), ref$cells, info = info)
      expect_equal(sum(index$share), 1, tolerance = 1e-9, info = info)
    }
  }
})

test_that("valid rows are not repaired and keep their cells beside invalid ones", {
  skip_if_no_h3()
  valid <- sf::st_geometry(geo_with_invalid())[1:20]
  invalid <- geo_sfc_of_wkt(geo_plane_invalid_wkt())
  # valid rows pay the validity check only: no repair is attempted
  local({
    local_mocked_bindings(geo_planar_repair = function(x) stop("repaired a valid row"))
    expect_no_error(geo_planar_rows(geo_wkb(valid), 5L))
  })
  together <- c(valid[1:10], invalid[1], valid[11:20], invalid[2])
  rows <- c(1:10, 12:21)
  for (engine in c("planar", "auto")) {
    alone <- geo_h3_rows(valid, 5L, geocode_engine = engine)
    out <- geo_h3_rows(together, 5L, geocode_engine = engine)
    expect_identical(out$h3[rows], alone$h3, info = engine)
    for (k in seq_along(rows)) {
      expect_identical(engine_row(out, rows[[k]])$cells, engine_row(alone, k)$cells, info = engine)
      expect_identical(engine_row(out, rows[[k]])$share, engine_row(alone, k)$share, info = engine)
    }
  }
})

test_that("a repair of lower dimension keeps the parts of the original dimension", {
  skip_if_no_h3()
  collapse <- geo_sfc_of_wkt(geo_plane_collapse_wkt()[1:2])
  repaired <- local({
    local_s2(FALSE)
    sf::st_make_valid(collapse)
  })
  expect_identical(
    as.character(sf::st_geometry_type(repaired)),
    c("LINESTRING", "GEOMETRYCOLLECTION")
  )

  # a polygon repaired to a line holds no area: no cells, `h3` NA
  expect_true(sf::st_is_empty(geo_planar_repair(collapse[1])))
  out <- expect_no_error(geo_h3_rows(collapse[1], 5L, geocode_engine = "planar"))
  expect_identical(out$h3, NA_character_)
  expect_identical(nrow(out$index), 0L)

  # a collection keeps its polygon: the cells of the box alone
  expect_identical(
    geo_planar_repair(collapse[2]),
    sf::st_polygon(list(cbind(c(30, 30, 30.3, 30.3, 30), c(48, 48.2, 48.2, 48, 48))))
  )
  box <- geo_sfc_of_wkt("POLYGON((30 48, 30.3 48, 30.3 48.2, 30 48.2, 30 48))")
  out <- expect_no_error(geo_h3_rows(collapse[2], 5L, geocode_engine = "planar"))
  ref <- geo_h3_rows(box, 5L, geocode_engine = "planar")
  expect_identical(engine_row(out, 1L)$cells, engine_row(ref, 1L)$cells)
  expect_equal(engine_row(out, 1L)$share, engine_row(ref, 1L)$share, tolerance = 1e-9)

  # both rows under "auto" and through a store
  expect_no_error(geo_h3_rows(collapse, 5L, geocode_engine = "auto"))
  st <- store_connect(withr::local_tempdir(), create = TRUE)
  x <- sf::st_sf(id = 1:2, geometry = collapse)
  expect_no_error(suppressMessages(suppressWarnings(
    store_write(st, x, "collapse",
      title = "t", description = "t", key = "id", geocode_engine = "planar"
    )
  )))
})

test_that("a repair into several polygons keeps them all", {
  skip_if_no_h3()
  g <- geo_sfc_of_wkt(geo_plane_collapse_wkt()[["two_parts"]])
  polygons <- local({
    local_s2(FALSE)
    sf::st_collection_extract(sf::st_make_valid(g), "POLYGON", warn = FALSE)
  })
  expect_length(polygons, 2)
  repaired <- geo_planar_repair(g)
  expect_s3_class(repaired, "MULTIPOLYGON")
  expect_length(unclass(repaired), 2)

  # the reference: the two polygons of the repair (the lines of the collection
  # are not of the row's dimension)
  ref <- engine_row(geo_h3_rows(sf::st_combine(polygons), 5L, geocode_engine = "planar"), 1L)
  expect_gt(length(ref$cells), 1)
  for (engine in c("planar", "auto")) {
    out <- expect_no_error(geo_h3_rows(g, 5L, geocode_engine = engine))
    row <- engine_row(out, 1L)
    expect_identical(row$h3, ref$h3, info = engine)
    expect_identical(row$cells, ref$cells, info = engine)
    expect_equal(row$share, ref$share, tolerance = 1e-9, info = engine)
    expect_equal(sum(row$share), 1, tolerance = 1e-9, info = engine)
  }
  st <- store_connect(withr::local_tempdir(), create = TRUE)
  suppressMessages(suppressWarnings(
    store_write(st, sf::st_sf(id = 1L, geometry = g), "two",
      title = "t", description = "t", key = "id", geocode_engine = "planar"
    )
  ))
  index <- store_read(st, "two__h3")
  expect_identical(sort(h3_as_hex(index$h3), method = "radix"), ref$cells)
  expect_equal(sum(index$share), 1, tolerance = 1e-9)
})

test_that("the planar engine geocodes WKB polygons with rings of fewer than 4 points", {
  skip_if_no_h3()
  box <- engine_row(geo_h3_rows(geo_short_ring_box(), 5L, geocode_engine = "planar"), 1L)
  for (k in 1:3) {
    g <- geo_short_ring_sfc(k)
    expect_identical(nrow(unclass(g[[1]])[[2]]), k)
    pairs <- expect_no_error(geo_planar_rows(geo_wkb(g), 5L))
    expect_identical(sort(pairs$cell, method = "radix"), box$cells, info = k)
    for (engine in c("planar", "auto")) {
      out <- expect_no_error(geo_h3_rows(g, 5L, geocode_engine = engine))
      expect_identical(engine_row(out, 1L)$cells, box$cells, info = paste(k, engine))
      expect_equal(sum(out$index$share), 1, tolerance = 1e-9, info = paste(k, engine))
    }
  }
})
