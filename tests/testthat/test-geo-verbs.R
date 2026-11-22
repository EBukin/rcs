# Geospatial verbs (plan 0002, D26): rcs_geo_add(), rcs_geo_index(),
# rcs_geo_strip(), and the round trip through a store.

# The cells of `geo_encode()` in the row order of `x`.
encoded_by_row <- function(x, h3_res = 5L, geocode_engine = "auto") {
  enc <- geo_encode(x, h3_res = h3_res, geocode_engine = geocode_engine)
  h3 <- enc$data$h3
  h3[enc$order] <- enc$data$h3
  bbox <- enc$data$bbox
  bbox[enc$order, ] <- enc$data$bbox
  list(h3 = h3, bbox = bbox, enc = enc)
}

as_bits <- function(x) {
  bit64::as.integer64(unclass(x))
}

local_geo_store <- function(frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  suppressMessages(store_create(file.path(root, "primary")))
  store_connect(file.path(root, "primary"))
}

write_geo <- function(st, x, dataset = "shapes/geo", ...) {
  suppressMessages(store_write(st, x, dataset,
    title = "Shapes", description = "Simulated shapes.", ...
  ))
}

# (a) rcs_geo_add() ---------------------------------------------------------------

test_that("rcs_geo_add() adds h3, parents and bbox before the geometry, in row order", {
  skip_if_no_h3()
  raw <- rcs_sim_polygons(60, seed = 2)
  out <- rcs_geo_add(raw, h3_res = 5L, parents = c(3L, 1L))
  expect_s3_class(out, "sf")
  expect_identical(names(out), c("id", "area", "cat", "h3", "h3_p3", "h3_p1", "bbox", "geometry"))
  expect_identical(attr(out, "sf_column"), "geometry")
  expect_identical(out$id, raw$id)
  expect_identical(sf::st_geometry(out), sf::st_geometry(raw))
  ref <- encoded_by_row(raw)
  expect_s3_class(out$h3, "rcs_h3")
  expect_identical(as_bits(out$h3), as_bits(ref$h3))
  expect_s3_class(out$h3_p3, "rcs_h3")
  expect_identical(as_bits(out$h3_p3), as_bits(h3_parent(ref$h3, 3L)))
  expect_identical(as_bits(out$h3_p1), as_bits(h3_parent(ref$h3, 1L)))
  expect_identical(out$bbox, geo_bbox_df(sf::st_geometry(raw)))
  expect_identical(out$bbox, ref$bbox)
})

test_that("rcs_geo_add() puts new columns before the active geometry, not at the end", {
  skip_if_no_h3()
  raw <- rcs_sim_points(10, seed = 1)
  raw$after <- seq_len(10)
  out <- rcs_geo_add(raw, h3_res = 4L)
  expect_identical(names(out), c("id", "value", "cat", "h3", "bbox", "geometry", "after"))
})

test_that("rcs_geo_add() keeps equal columns, aborts on different ones unless replace = TRUE", {
  skip_if_no_h3()
  raw <- rcs_sim_points(30, seed = 4)
  once <- rcs_geo_add(raw, h3_res = 5L)
  expect_identical(rcs_geo_add(once, h3_res = 5L), once)
  tampered <- once
  tampered$h3[3] <- tampered$h3[1]
  expect_false(identical(as_bits(tampered$h3[3]), as_bits(once$h3[3])))
  expect_error(rcs_geo_add(tampered, h3_res = 5L), "h3", class = "rcs_error_prepared")
  expect_identical(rcs_geo_add(tampered, h3_res = 5L, replace = TRUE), once)
  other_res <- rcs_geo_add(once, h3_res = 6L, replace = TRUE)
  expect_identical(names(other_res), names(once))
  expect_identical(as_bits(other_res$h3), as_bits(encoded_by_row(raw, 6L)$h3))
  moved <- once
  moved$bbox$xmin[2] <- moved$bbox$xmin[2] - 1
  expect_error(rcs_geo_add(moved, h3_res = 5L), "bbox", class = "rcs_error_prepared")
})

test_that("rcs_geo_add() with h3_res = NULL adds only bbox; bbox = FALSE adds none", {
  skip_if_no_h3()
  raw <- rcs_sim_lines(15, seed = 1)
  expect_identical(names(rcs_geo_add(raw, h3_res = NULL)), c(setdiff(names(raw), "geometry"), "bbox", "geometry"))
  expect_identical(names(rcs_geo_add(raw, bbox = FALSE)), c(setdiff(names(raw), "geometry"), "h3", "geometry"))
  expect_identical(rcs_geo_add(raw, h3_res = NULL, bbox = FALSE), raw)
})

test_that("rcs_geo_add() checks its arguments", {
  skip_if_no_h3()
  raw <- rcs_sim_points(5, seed = 1)
  expect_error(rcs_geo_add(sf::st_drop_geometry(raw)), class = "rcs_error_argument")
  expect_error(rcs_geo_add(sf::st_set_crs(raw, NA)), class = "rcs_error_geo")
  expect_error(rcs_geo_add(raw, h3_res = 5L, parents = 5L), class = "rcs_error_argument")
  expect_error(rcs_geo_add(raw, h3_res = 5L, parents = c(2L, 7L)), class = "rcs_error_argument")
  expect_error(rcs_geo_add(raw, h3_res = NULL, parents = 2L), class = "rcs_error_argument")
  expect_error(rcs_geo_add(raw, geocode_engine = "flat"), class = "rcs_error_argument")
  expect_snapshot(error = TRUE, {
    rcs_geo_add(raw, h3_res = 5L, parents = c(2L, 5L))
  })
})

test_that("rcs_geo_add() warns naming the row numbers of rebuilt rows", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  w <- expect_warning(out <- rcs_geo_add(x, h3_res = 5L, geocode_engine = "s2"), class = "rcs_warning_s2_rebuild")
  expect_match(conditionMessage(w), "row 21")
  expect_match(conditionMessage(w), "row 22")
  ref <- suppressWarnings(encoded_by_row(x, geocode_engine = "s2"))
  expect_identical(as_bits(out$h3), as_bits(ref$h3))
  expect_snapshot(invisible(rcs_geo_add(x, h3_res = 5L, geocode_engine = "s2")))
})

test_that("rcs_geo_add() follows the engine: planar cells differ from s2 for long edges", {
  skip_if_no_h3()
  x <- sf::st_sf(id = 1:2, geometry = geo_sfc_of_wkt(c(geo_long_edge_wkt(), "POINT(-27 7)")))
  planar <- rcs_geo_add(x, h3_res = 3L, geocode_engine = "planar")
  expect_identical(as_bits(planar$h3), as_bits(encoded_by_row(x, 3L, "planar")$h3))
})

# (b) rcs_geo_index() -------------------------------------------------------------

test_that("rcs_geo_index() gives the index rows of geo_encode() keyed by id", {
  skip_if_no_h3()
  raw <- rcs_sim_polygons(80, seed = 5)
  idx <- rcs_geo_index(raw, "id", h3_res = 5L)
  expect_identical(names(idx), c("id", "h3", "h3_main", "share"))
  expect_s3_class(idx$h3, "rcs_h3")
  expect_s3_class(idx$h3_main, "rcs_h3")
  expect_false(is.unsorted(match(idx$id, raw$id)))
  enc <- geo_encode(raw, h3_res = 5L)
  ref <- tibble::tibble(
    id = enc$data$id[match(enc$index$.rcs_id, enc$data$.rcs_id)],
    h3 = as.character(enc$index$h3), h3_main = as.character(enc$index$h3_main),
    share = enc$index$share
  )
  got <- tibble::tibble(
    id = idx$id, h3 = as.character(as_bits(idx$h3)), h3_main = as.character(as_bits(idx$h3_main)),
    share = idx$share
  )
  ord <- function(d) d[order(d$id, d$h3), ]
  expect_equal(ord(got), ord(ref), ignore_attr = TRUE)
  expect_gt(nrow(got), 0)
})

test_that("rcs_geo_index(crossing_only = FALSE) adds one line per inside row with share 1", {
  skip_if_no_h3()
  raw <- rcs_sim_polygons(40, seed = 6)
  crossing <- rcs_geo_index(raw, "id", h3_res = 5L)
  all <- rcs_geo_index(raw, "id", h3_res = 5L, crossing_only = FALSE)
  inside <- setdiff(raw$id, crossing$id)
  expect_gt(length(inside), 0)
  extra <- all[all$id %in% inside, ]
  expect_identical(sort(extra$id), sort(inside))
  expect_identical(extra$share, rep(1, length(inside)))
  expect_identical(as_bits(extra$h3), as_bits(extra$h3_main))
  h3 <- rcs_geo_add(raw, h3_res = 5L, bbox = FALSE)$h3
  expect_identical(as_bits(extra$h3), as_bits(h3[match(extra$id, raw$id)]))
  expect_identical(nrow(all), nrow(crossing) + length(inside))
  expect_false(is.unsorted(match(all$id, raw$id)))
  expect_error(rcs_geo_index(raw, "nope"), class = "rcs_error_argument")
})

# (c) rcs_geo_strip() -------------------------------------------------------------

test_that("rcs_geo_strip() undoes rcs_geo_add() exactly", {
  skip_if_no_h3()
  for (raw in list(rcs_sim_polygons(30, seed = 1), rcs_sim_points(20), rcs_sim_lines(20), geo_with_invalid())) {
    prepared <- suppressWarnings(rcs_geo_add(raw, parents = c(2L, 0L)))
    expect_identical(rcs_geo_strip(prepared), raw)
  }
})

test_that("rcs_geo_strip() drops the package columns, or the named ones", {
  skip_if_no_h3()
  raw <- rcs_sim_points(10)
  x <- rcs_geo_add(raw, parents = 3L)
  x$.rcs_id <- bit64::as.integer64(seq_len(10))
  x$h3_main <- x$h3
  x$geom <- sf::st_geometry(raw)
  expect_identical(names(rcs_geo_strip(x)), names(raw))
  expect_identical(names(rcs_geo_strip(x, columns = "bbox")), setdiff(names(x), "bbox"))
  expect_error(rcs_geo_strip(x, columns = "nope"), class = "rcs_error_argument")
  expect_error(rcs_geo_strip(x, columns = "geometry"), class = "rcs_error_argument")
})

test_that("rcs_geo_strip() keeps geom when it is the active geometry column", {
  skip_if_no_h3()
  raw <- sf::st_set_geometry(rcs_sim_points(10), "geom")
  expect_identical(attr(raw, "sf_column"), "geom")
  prepared <- rcs_geo_add(raw)
  expect_identical(names(prepared), c("id", "value", "cat", "h3", "bbox", "geom"))
  expect_identical(rcs_geo_strip(prepared), raw)
})

# (d) Round trip through a store ---------------------------------------------------

expect_round_trip <- function(st, raw, prepared, dataset, key, ...) {
  write_geo(st, prepared, dataset, key = key, ...)
  back <- rcs_geo_strip(dplyr::collect(store_open(st, dataset)))
  back <- back[order(back[[key]]), ]
  raw <- raw[order(raw[[key]]), ]
  expect_equal(
    tibble::as_tibble(sf::st_drop_geometry(back)),
    tibble::as_tibble(sf::st_drop_geometry(raw))
  )
  expect_identical(
    lapply(sf::st_as_binary(sf::st_geometry(back), EWKB = FALSE), as.raw),
    lapply(sf::st_as_binary(sf::st_geometry(raw), EWKB = FALSE), as.raw)
  )
  expect_equal(sf::st_crs(back), sf::st_crs(raw))
}

test_that("raw -> rcs_geo_add() -> store -> collect() -> rcs_geo_strip() gives raw back", {
  skip_below_level("default")
  skip_if_no_h3()
  st <- local_geo_store()
  shapes <- list(
    points = rcs_sim_points(60, seed = 7),
    lines = rcs_sim_lines(40, seed = 7),
    polygons = rcs_sim_polygons(40, seed = 7)
  )
  for (kind in names(shapes)) {
    raw <- shapes[[kind]]
    expect_round_trip(st, raw, rcs_geo_add(raw), paste0("plain/", kind), "id")
    expect_round_trip(st, raw, rcs_geo_add(raw, parents = 2L), paste0("parents/", kind), "id")
    expect_round_trip(st, raw, rcs_geo_add(raw), paste0("h3part/", kind), "id", partition = "h3", max_files = 4)
    expect_round_trip(st, raw, rcs_geo_add(raw, parents = 0L), paste0("h3parents/", kind), "id", partition = "h3", max_files = 4)
  }
})
