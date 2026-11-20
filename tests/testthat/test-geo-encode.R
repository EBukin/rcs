# geo_encode(), geo_decode() and geo_metadata().

dplyr_free_rename <- function(x, old, new) {
  names(x)[names(x) == old] <- new
  x
}

with_geometry_name <- function(x, name) {
  y <- sf::st_drop_geometry(x)
  y[[name]] <- sf::st_geometry(x)
  sf::st_sf(y, sf_column_name = name)
}

small_polygons <- function() {
  sim_cached("small_polygons", rcs_sim_polygons(40, seed = 2, special = TRUE))
}

test_that("geo_encode() returns the documented columns, types and order", {
  skip_if_no_h3()
  x <- small_polygons()
  out <- geo_encode(x)
  expect_named(out, c("data", "index", "crs", "bbox"))
  data <- out$data
  expect_s3_class(data, "tbl_df")
  expect_false(inherits(data, "sf"))
  expect_named(data, c("id", "area", "cat", ".rcs_id", "h3", "bbox", "geometry"))
  expect_s3_class(data$.rcs_id, "integer64")
  expect_s3_class(data$h3, "integer64")
  expect_named(data$bbox, c("xmin", "ymin", "xmax", "ymax"))
  expect_type(data$geometry, "list")
  expect_null(attributes(data$geometry))
  expect_true(all(vapply(data$geometry, is.raw, logical(1))))
  expect_identical(nrow(data), nrow(x))

  # ids in written order from 1
  expect_identical(data$.rcs_id, bit64::as.integer64(seq_len(nrow(x))))
  # written order: by h3 (NA last), ties in the order of x
  hex <- h3_as_hex(data$h3)
  expect_identical(order(hex, data$id, method = "radix", na.last = TRUE), seq_len(nrow(x)))
  # the empty geometry has no cell, no box and sorts last
  empty <- which(data$id == 9L)
  expect_identical(empty, nrow(x))
  expect_true(is.na(data$h3[empty]))
  expect_true(all(is.na(unlist(data$bbox[empty, ]))))

  expect_identical(out$crs, sf::st_crs(4326)$ProjJson)
  expect_equal(out$bbox, c(
    xmin = min(data$bbox$xmin, na.rm = TRUE), ymin = min(data$bbox$ymin, na.rm = TRUE),
    xmax = max(data$bbox$xmax, na.rm = TRUE), ymax = max(data$bbox$ymax, na.rm = TRUE)
  ))
})

test_that("the bbox column is the box of every geometry in the data CRS", {
  skip_if_no_h3()
  x <- sf::st_transform(small_polygons()[1:40, ], 32626)
  out <- geo_encode(x)
  data <- out$data
  rows <- match(data$id, x$id)
  for (i in which(!sf::st_is_empty(x$geometry[rows]))) {
    box <- sf::st_bbox(x$geometry[rows[i]])
    expect_equal(unlist(data$bbox[i, ]), unclass(box)[c("xmin", "ymin", "xmax", "ymax")], ignore_attr = TRUE)
  }
  expect_identical(out$crs, sf::st_crs(32626)$ProjJson)
  # geocodes do not depend on the CRS of the data
  ref <- geo_encode(small_polygons()[1:40, ])$data
  expect_identical(
    h3_as_hex(data$h3[order(data$id)]),
    h3_as_hex(ref$h3[order(ref$id)])
  )
})

test_that("WKB round-trips through geo_decode()", {
  skip_if_no_h3()
  x <- small_polygons()
  out <- geo_encode(x)
  back <- geo_decode(out$data, out$crs)
  expect_s3_class(back, "sf")
  expect_s3_class(back, "tbl_df")
  expect_identical(names(back)[ncol(back)], "geometry")
  expect_identical(attr(back, "sf_column"), "geometry")
  expect_true(sf::st_crs(back) == sf::st_crs(x))
  rows <- match(back$id, x$id)
  expect_true(all(sf::st_equals_exact(back$geometry, x$geometry[rows], par = 0, sparse = FALSE)[cbind(seq_along(rows), seq_along(rows))] |
    sf::st_is_empty(back$geometry)))
  expect_identical(sf::st_as_binary(back$geometry), sf::st_as_binary(x$geometry[rows]))
  expect_s3_class(back$.rcs_id, "integer64")
  expect_named(back$bbox, c("xmin", "ymin", "xmax", "ymax"))
})

test_that("geo_decode() takes Arrow's binary column and missing values", {
  skip_if_no_h3()
  out <- geo_encode(small_polygons()[1:20, ])
  table <- arrow::arrow_table(out$data["id"], geometry = arrow::Array$create(out$data$geometry, type = arrow::binary()))
  df <- as.data.frame(table)
  back <- geo_decode(df, out$crs)
  expect_identical(sf::st_as_binary(back$geometry), sf::st_as_binary(geo_decode(out$data, out$crs)$geometry))
  wkb <- lapply(seq_len(nrow(df)), function(i) df$geometry[[i]])
  wkb[2] <- list(NULL)
  df$geometry <- wkb
  back <- geo_decode(df, out$crs)
  expect_true(sf::st_is_empty(back$geometry[2]))
})

test_that("geo_decode() handles zero rows and a data frame of geometry only", {
  skip_if_no_h3()
  out <- geo_encode(small_polygons()[0, ])
  back <- geo_decode(out$data, out$crs)
  expect_s3_class(back, "sf")
  expect_identical(nrow(back), 0L)
  only <- geo_decode(out$data["geometry"], out$crs)
  expect_named(only, "geometry")
  expect_error(geo_decode(data.frame(a = 1), out$crs), class = "rcs_error_geo")
  expect_snapshot(geo_decode(data.frame(a = 1), out$crs), error = TRUE)
})

test_that("geo_encode() handles zero rows", {
  skip_if_no_h3()
  out <- geo_encode(small_polygons()[0, ])
  expect_identical(nrow(out$data), 0L)
  expect_named(out$data, c("id", "area", "cat", ".rcs_id", "h3", "bbox", "geometry"))
  expect_identical(nrow(out$index), 0L)
  expect_named(out$index, c(".rcs_id", "h3", "h3_main", "share"))
  expect_true(all(is.na(out$bbox)))
  expect_named(out$bbox, c("xmin", "ymin", "xmax", "ymax"))
})

test_that("geocode = FALSE skips cells and sorts by key or keeps the order", {
  x <- sim_points()[1:50, ]
  out <- geo_encode(x, geocode = FALSE)
  expect_null(out$index)
  expect_false("h3" %in% names(out$data))
  expect_identical(out$data$id, x$id)
  keyed <- geo_encode(x, geocode = FALSE, key = c("cat", "id"))
  expect_identical(keyed$data$id, x$id[order(x$cat, x$id, method = "radix")])
})

test_that("rows with the same cell are sorted by key, and id_start offsets ids", {
  skip_if_no_h3()
  x <- sim_points()[1:200, ]
  out <- geo_encode(x, h3_res = 2L, key = "cat", id_start = bit64::as.integer64("5000000000"))
  hex <- h3_as_hex(out$data$h3)
  expect_identical(order(hex, out$data$cat, out$data$id, method = "radix"), seq_len(200))
  expect_identical(out$data$.rcs_id[1], bit64::as.integer64("5000000000"))
  expect_identical(out$data$.rcs_id[200], bit64::as.integer64("5000000199"))
  expect_identical(geo_encode(x[1:3, ], id_start = 7)$data$.rcs_id, bit64::as.integer64(7:9))
})

test_that("geo_encode() aborts on missing CRS, reserved names and bad arguments", {
  skip_if_no_h3()
  x <- small_polygons()[1:5, ]
  expect_error(geo_encode(sf::st_set_crs(x, NA)), class = "rcs_error_geo")
  expect_error(geo_encode(dplyr_free_rename(x, "cat", "h3")), class = "rcs_error_geo")
  expect_error(geo_encode(dplyr_free_rename(x, "cat", ".rcs_id")), class = "rcs_error_geo")
  expect_error(geo_encode(dplyr_free_rename(x, "cat", "bbox")), class = "rcs_error_geo")
  other <- with_geometry_name(x, "shape")
  other$geometry <- 1
  expect_error(geo_encode(other), class = "rcs_error_geo")
  expect_error(geo_encode(as.data.frame(x)), class = "rcs_error_geo")
  expect_error(geo_encode(x, h3_res = 16L), class = "rcs_error_argument")
  expect_error(geo_encode(x, key = "nope"), class = "rcs_error_argument")
  expect_error(geo_encode(x, id_start = 1.5), class = "rcs_error_argument")
  expect_snapshot(geo_encode(dplyr_free_rename(x, "cat", "h3")), error = TRUE)
  expect_snapshot(geo_encode(sf::st_set_crs(x, NA)), error = TRUE)
})

test_that("a geometry column with another name is encoded as geometry", {
  skip_if_no_h3()
  x <- with_geometry_name(small_polygons()[1:5, ], "shape")
  out <- geo_encode(x)
  expect_named(out$data, c("id", "area", "cat", ".rcs_id", "h3", "bbox", "geometry"))
})

test_that("geo_encode() is deterministic and its chunks do not matter", {
  skip_if_no_h3()
  x <- small_polygons()
  a <- geo_encode(x)
  b <- geo_encode(x)
  expect_identical(a, b)
  withr::local_options(rcs.chunk_size = 7)
  c <- geo_encode(x)
  expect_identical(c, a)
})

test_that("mirai workers give the same result", {
  skip_below_level("default")
  skip_if_no_h3()
  skip_if_not_installed("mirai")
  skip_if_not_installed("pkgload")
  root <- testthat::test_path("..", "..")
  skip_if_not(file.exists(file.path(root, "DESCRIPTION")))
  x <- small_polygons()
  ref <- geo_encode(x)
  mirai::daemons(2, .compute = "rcs")
  withr::defer(mirai::daemons(0, .compute = "rcs"))
  mirai::everywhere(pkgload::load_all(root, quiet = TRUE), root = normalizePath(root), .compute = "rcs")
  withr::local_options(rcs.chunk_size = 10, rcs.workers = 2)
  expect_identical(geo_encode(x), ref)
})

test_that("geo_metadata() writes GeoParquet 1.1", {
  skip_if_no_h3()
  out <- geo_encode(small_polygons())
  json <- geo_metadata(out$data, out$crs)
  expect_type(json, "character")
  geo <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_identical(geo$version, "1.1.0")
  expect_identical(geo$primary_column, "geometry")
  col <- geo$columns$geometry
  expect_identical(col$encoding, "WKB")
  expect_identical(unlist(col$geometry_types), c("MultiPolygon", "Polygon"))
  expect_type(col$crs, "list")
  expect_identical(col$crs$id$code, 4326L)
  expect_equal(unlist(col$bbox), unname(out$bbox))
  expect_identical(
    col$covering,
    list(bbox = list(
      xmin = list("bbox", "xmin"), ymin = list("bbox", "ymin"),
      xmax = list("bbox", "xmax"), ymax = list("bbox", "ymax")
    ))
  )
  # the same rows give the same string
  expect_identical(geo_metadata(out$data, out$crs), json)
  # zero rows: no types, no bbox
  none <- jsonlite::fromJSON(geo_metadata(out$data[0, ], out$crs), simplifyVector = FALSE)
  expect_length(none$columns$geometry$geometry_types, 0)
  expect_null(none$columns$geometry$bbox)
  expect_error(geo_metadata(out$data["id"], out$crs), class = "rcs_error_geo")
})

test_that("geo_metadata() names every geometry type", {
  skip_if_no_h3()
  g <- sf::st_sfc(
    sf::st_point(c(-27, 7)),
    sf::st_linestring(cbind(c(-27, -26), c(7, 7))),
    sf::st_multipoint(cbind(c(-27, -26), c(7, 7))),
    sf::st_multilinestring(list(cbind(c(-27, -26), c(7, 7)))),
    sf::st_geometrycollection(list(sf::st_point(c(-27, 7)))),
    crs = 4326
  )
  x <- sf::st_sf(id = seq_along(g), geometry = g)
  out <- geo_encode(x, geocode = FALSE)
  geo <- jsonlite::fromJSON(geo_metadata(out$data, out$crs))
  expect_identical(
    geo$columns$geometry$geometry_types,
    c("GeometryCollection", "LineString", "MultiLineString", "MultiPoint", "Point")
  )
  z <- sf::st_sf(id = 1L, geometry = sf::st_sfc(sf::st_point(c(-27, 7, 1)), crs = 4326))
  out <- geo_encode(z, geocode = FALSE)
  geo <- jsonlite::fromJSON(geo_metadata(out$data, out$crs))
  expect_identical(geo$columns$geometry$geometry_types, "Point Z")
})

test_that("a GeoParquet file written with the metadata is read back by sf types", {
  skip_if_no_h3()
  out <- geo_encode(small_polygons())
  tab <- arrow::arrow_table(
    out$data[c("id", ".rcs_id", "h3")],
    bbox = out$data$bbox,
    geometry = arrow::Array$create(out$data$geometry, type = arrow::binary())
  )
  tab$metadata$geo <- geo_metadata(out$data, out$crs)
  path <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(tab, path)
  back <- arrow::read_parquet(path, as_data_frame = FALSE)
  expect_identical(back$metadata$geo, tab$metadata$geo)
  df <- withr::with_options(list(arrow.int64_downcast = FALSE), as.data.frame(back))
  decoded <- geo_decode(df, out$crs)
  expect_identical(sf::st_as_binary(decoded$geometry), sf::st_as_binary(geo_decode(out$data, out$crs)$geometry))
})

test_that("boxes far from the equator get extra test points on their equator-side edge", {
  box <- list(
    xmin = c(-27, -27, 10, -27), ymin = c(7, 80, -80.1, -0.05),
    xmax = c(-26.99, -26.5, 10.5, -26.95), ymax = c(7.01, 80.05, -80, 0.05)
  )
  edge <- geo_edge_points(box)
  # a small box near the equator and a box across it need none
  expect_false(any(edge$row %in% c(1L, 4L)))
  # a wide box at 80 degrees north gets points on its southern edge
  expect_true(any(edge$row == 2L))
  expect_true(all(edge$y[edge$row == 2L] == 80))
  expect_true(all(edge$x[edge$row == 2L] > -27 & edge$x[edge$row == 2L] < -26.5))
  # at 80 degrees south the northern edge is the one nearest the equator
  expect_true(all(edge$y[edge$row == 3L] == -80))
  # with a coarse tolerance there are fewer points
  expect_lt(length(geo_edge_points(box, tolerance_m = 1)$row), length(edge$row))
})
