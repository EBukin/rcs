test_that("the box holds an edge between two resolution-0 cells", {
  skip_if_no_h3()
  lon <- seq(plan_box[["xmin"]], plan_box[["xmax"]], by = 0.05)
  edge_at <- function(lat) {
    cells <- ref_cell_hex(lon, rep(lat, length(lon)), 0)
    expect_length(unique(cells), 2)
    change <- which(cells[-1] != cells[-length(cells)])
    expect_length(change, 1)
    lon[change + 0:1]
  }
  # the plan: the edge runs between longitude -29.4 and -25.7
  expect_equal(edge_at(6), c(-29.45, -29.40))
  expect_equal(edge_at(7.5), c(-27.60, -27.55))
  expect_equal(edge_at(9), c(-25.75, -25.70))

  inside <- sim_res0_edge_lon(7.5)
  expect_gt(inside, -27.60)
  expect_lt(inside, -27.55)
})

test_that("the package's box is the plan's box", {
  expect_identical(sim_box, plan_box)
})

test_that("every coordinate of the simulated geometries is inside the box", {
  expect_in_box(coords_of(sim_polygons()))
  expect_in_box(sf::st_coordinates(sim_points()))
  expect_in_box(sf::st_coordinates(sim_lines()))
  expect_equal(sf::st_crs(sim_polygons()), sf::st_crs(4326))
  expect_equal(sf::st_crs(sim_points()), sf::st_crs(4326))
  expect_equal(sf::st_crs(sim_lines()), sf::st_crs(4326))
})

test_that("larger sets with other seeds stay inside the box", {
  skip_below_level("default")
  skip_if_no_h3()
  for (seed in 2:4) {
    expect_in_box(coords_of(rcs_sim_polygons(5000, seed = seed, crossing_share = 0.3)))
    expect_in_box(sf::st_coordinates(rcs_sim_lines(5000, seed = seed)))
    expect_in_box(sf::st_coordinates(rcs_sim_points(5000, seed = seed)))
  }
})

test_that("polygons have the documented columns and groups", {
  x <- sim_polygons()
  expect_s3_class(x, c("sf", "tbl_df"))
  expect_named(x, c("id", "area", "cat", "geometry"))
  expect_identical(x$id, 1:500)
  expect_type(x$area, "double")
  expect_true(all(x$cat %in% letters[1:5]))
  types <- as.character(sf::st_geometry_type(x))
  expect_identical(types[5:7], rep("MULTIPOLYGON", 3))
  expect_identical(unique(types[-(5:7)]), "POLYGON")
  expect_identical(which(sf::st_is_empty(x)), 9L)
  expect_identical(which(is.na(x$area)), 9L)
  expect_true(all(sf::st_is_valid(x[-9, ])))
})

test_that("the rectangle has four vertices and covers more than 100 cells", {
  x <- sim_polygons()
  rectangle <- sf::st_geometry(x)[1]
  expect_equal(nrow(sf::st_coordinates(rectangle)), 5)
  cells <- h3o::sfc_to_cells(rectangle, 5L, containment = "intersect")[[1]]
  expect_gt(length(unique(as.character(cells))), 100)
})

test_that("the large shapes span many cells and one has a hole", {
  x <- sim_polygons()
  for (id in 2:3) {
    cells <- h3o::sfc_to_cells(sf::st_geometry(x)[id], 5L, containment = "intersect")[[1]]
    expect_gt(length(unique(as.character(cells))), 10)
  }
  expect_length(sf::st_geometry(x)[[3]], 2)
})

test_that("the thin polygon is about 300 km by 100 m", {
  x <- sim_polygons()
  box <- sf::st_bbox(x[4, ])
  corner <- function(lon, lat) sf::st_sfc(sf::st_point(c(lon, lat)), crs = 4326)
  long <- sf::st_distance(corner(box[["xmin"]], box[["ymin"]]), corner(box[["xmax"]], box[["ymin"]]))
  wide <- sf::st_distance(corner(box[["xmin"]], box[["ymin"]]), corner(box[["xmin"]], box[["ymax"]]))
  expect_equal(as.numeric(long) / 1000, 300, tolerance = 0.01)
  expect_equal(as.numeric(wide), 100, tolerance = 0.02)
})

test_that("one multipolygon has parts in different cells", {
  x <- sim_polygons()
  parts <- sf::st_cast(sf::st_geometry(x)[7], "POLYGON")
  expect_length(parts, 2)
  centre <- sf::st_coordinates(sf::st_centroid(parts))
  cells <- ref_cell_hex(centre[, "X"], centre[, "Y"], 5)
  expect_false(cells[[1]] == cells[[2]])
})

test_that("one polygon crosses the resolution-0 edge", {
  x <- sim_polygons()
  vertices <- sf::st_coordinates(x[8, ])
  expect_length(unique(ref_cell_hex(vertices[, "X"], vertices[, "Y"], 0)), 2)
})

test_that("crossing rows have bounding-box corners in several resolution-5 cells", {
  x <- sim_polygons()
  crossing <- x[10:59, ]
  several <- vapply(seq_len(nrow(crossing)), function(i) {
    box <- sf::st_bbox(crossing[i, ])
    cells <- ref_cell_hex(
      box[c("xmin", "xmax", "xmax", "xmin")], box[c("ymin", "ymin", "ymax", "ymax")], 5
    )
    length(unique(cells)) > 1
  }, logical(1))
  expect_true(all(several))
})

test_that("crossing_share sets the number of crossing rows", {
  skip_if_no_h3()
  none <- rcs_sim_polygons(40, crossing_share = 0)
  half <- rcs_sim_polygons(40, crossing_share = 0.5)
  expect_equal(nrow(none), 40)
  expect_equal(nrow(half), 40)
  corners_split <- function(x) {
    vapply(seq_len(nrow(x)), function(i) {
      box <- sf::st_bbox(x[i, ])
      cells <- ref_cell_hex(
        box[c("xmin", "xmax", "xmax", "xmin")], box[c("ymin", "ymin", "ymax", "ymax")], 5
      )
      length(unique(cells)) > 1
    }, logical(1))
  }
  expect_true(all(corners_split(half[10:29, ])))
  expect_lt(sum(corners_split(none[10:40, ])), 10)
})

test_that("small polygons are squares and hexagons of 0.01 to 0.5 square km", {
  x <- sim_polygons()
  small <- x[60:500, ]
  expect_gte(min(small$area), 0.01 * 0.97)
  expect_lte(max(small$area), 0.5 * 1.03)
  vertices <- table(sf::st_coordinates(small)[, "L2"])
  expect_setequal(unique(as.integer(vertices)), c(5L, 7L))
})

test_that("special rows lie outside the box, across the antimeridian and around the pole", {
  x <- sim_polygons(special = TRUE)
  expect_equal(nrow(x), 502)
  expect_identical(x$id[501:502], 501:502)
  skip_if_no_h3()
  plain <- rcs_sim_polygons(500, seed = 1)
  expect_identical(sf::st_geometry(x)[1:500], sf::st_geometry(plain))
  expect_identical(x$area[1:500], plain$area)

  antimeridian <- sf::st_coordinates(x[501, ])
  expect_setequal(antimeridian[, "X"], c(179, -179))
  expect_gte(min(antimeridian[, "Y"]), 6)
  expect_lte(max(antimeridian[, "Y"]), 9)
  # two degrees wide on the sphere, not 358
  expect_gt(x$area[[501]], 60000)
  expect_lt(x$area[[501]], 80000)

  pole <- sf::st_coordinates(x[502, ])
  expect_true(all(pole[, "Y"] > 88))
  expect_gt(diff(range(pole[, "X"])), 300)
  # a cap around the pole, not the rest of the globe
  expect_lt(x$area[[502]], pi * (1.5 * 111.7)^2)
})

test_that("polygons can be transformed to the projected CRS of the box", {
  projected <- sim_polygons_projected()
  expect_equal(sf::st_crs(projected), sf::st_crs(32626))
  expect_true(all(is.finite(coords_of(projected))))
})

test_that("points and lines have the documented columns", {
  points <- sim_points()
  expect_named(points, c("id", "value", "cat", "geometry"))
  expect_identical(unique(as.character(sf::st_geometry_type(points))), "POINT")
  lines <- sim_lines()
  expect_named(lines, c("id", "length", "cat", "geometry"))
  expect_identical(unique(as.character(sf::st_geometry_type(lines))), "LINESTRING")
  expect_true(all(lines$length > 0))
  vertices <- as.integer(table(sf::st_coordinates(lines)[, "L1"]))
  expect_true(all(vertices >= 2 & vertices <= 6))
  expect_equal(nrow(rcs_sim_points(0)), 0)
  expect_equal(nrow(rcs_sim_lines(0)), 0)
})

test_that("the raster covers the box with three layers", {
  x <- sim_raster()
  expect_s4_class(x, "SpatRaster")
  expect_identical(names(x), c("height", "cover", "moisture"))
  expect_equal(dim(x), c(100, 100, 3))
  expect_equal(
    as.vector(terra::ext(x)),
    plan_box[c("xmin", "xmax", "ymin", "ymax")]
  )
  expect_true(terra::same.crs(x, "EPSG:4326"))
  values <- terra::values(x)
  expect_setequal(unique(values[, "cover"]), 1:5)
  expect_true(anyNA(values[, "moisture"]))
  expect_false(anyNA(values[, "height"]))
})

test_that("the raster has 1000 x 1000 cells by default", {
  skip_below_level("default")
  skip_if_not_installed("terra")
  expect_equal(dim(rcs_sim_raster()), c(1000, 1000, 3))
})

test_that("the table has one column of every type", {
  x <- sim_table()
  expect_s3_class(x, "tbl_df")
  expect_identical(
    vapply(x, function(col) class(col)[[1]], character(1)),
    c(
      shop_id = "integer", date = "Date", year = "integer", product = "factor",
      qty = "integer", price = "numeric", promo = "logical", grade = "ordered",
      delivered = "Date", big = "integer64", wait = "difftime", note = "character",
      tags = "list", ts = "POSIXct", ts_local = "POSIXct"
    )
  )
  expect_identical(levels(x$product), sprintf("p%02d", 1:20))
  expect_false("p20" %in% x$product)
  expect_identical(levels(x$grade), c("low", "mid", "high"))
  expect_identical(units(x$wait), "hours")
  expect_identical(attr(x$ts, "tzone"), "UTC")
  expect_identical(attr(x$ts_local, "tzone"), "")
  both <- !is.na(x$ts) & !is.na(x$ts_local)
  expect_equal(as.numeric(x$ts)[both], as.numeric(x$ts_local)[both])
  expect_identical(x$year, as.integer(format(x$date, "%Y")))
  expect_gte(length(unique(x$year)), 2)
})

test_that("the table has a unique key and missing values elsewhere", {
  x <- sim_table()
  key <- c("shop_id", "date", "product")
  expect_equal(anyDuplicated(x[key]), 0)
  expect_false(anyNA(x[c(key, "year")]))
  others <- setdiff(names(x), c(key, "year", "tags"))
  expect_true(all(vapply(x[others], anyNA, logical(1))))
  expect_true(any(vapply(x$tags, is.null, logical(1))))
  expect_true(any(lengths(x$tags) == 0 & !vapply(x$tags, is.null, logical(1))))
})

test_that("the table holds values that are hard to store", {
  x <- sim_table()
  big <- x$big[!is.na(x$big)]
  expect_true(any(big > bit64::as.integer64("9007199254740992")))
  expect_true(any(big < bit64::as.integer64(2000)))
  # above 2^53 an odd value does not survive a double
  through_double <- suppressWarnings(bit64::as.integer64(as.double(big)))
  expect_true(any(as.character(big) != as.character(through_double)))
  notes <- x$note[!is.na(x$note)]
  expect_true(any(grepl("[^\\x01-\\x7f]", notes, perl = TRUE)))
  expect_true(any(notes == ""))
  expect_true(all(validUTF8(notes)))
})

test_that("a table of zero rows keeps every column and type", {
  empty <- rcs_sim_table(0)
  expect_equal(nrow(empty), 0)
  expect_identical(lapply(empty, class), lapply(sim_table(), class))
  expect_identical(levels(empty$product), sprintf("p%02d", 1:20))
})

test_that("generators are reproducible and leave the random stream alone", {
  skip_if_no_h3()
  expect_identical(rcs_sim_table(50, seed = 3), rcs_sim_table(50, seed = 3))
  expect_false(identical(rcs_sim_table(50, seed = 3), rcs_sim_table(50, seed = 4)))
  expect_identical(rcs_sim_polygons(30, seed = 3), rcs_sim_polygons(30, seed = 3))
  expect_false(identical(rcs_sim_polygons(30, seed = 3), rcs_sim_polygons(30, seed = 4)))
  expect_identical(rcs_sim_points(30, seed = 3), rcs_sim_points(30, seed = 3))
  expect_identical(rcs_sim_lines(30, seed = 3), rcs_sim_lines(30, seed = 3))

  withr::local_seed(99)
  expected <- runif(1)
  set.seed(99)
  rcs_sim_table(10)
  rcs_sim_polygons(20)
  rcs_sim_points(10)
  rcs_sim_lines(10)
  expect_identical(runif(1), expected)
})

test_that("generators keep the session's s2 setting", {
  skip_if_no_h3()
  old <- suppressMessages(sf::sf_use_s2(FALSE))
  withr::defer(suppressMessages(sf::sf_use_s2(old)))
  rcs_sim_polygons(20)
  rcs_sim_lines(5)
  expect_false(sf::sf_use_s2())
})

test_that("generators reject bad arguments", {
  expect_error(rcs_sim_table(-1), class = "rcs_error_argument")
  expect_error(rcs_sim_table("a"), class = "rcs_error_argument")
  expect_error(rcs_sim_polygons(19), class = "rcs_error_argument")
  expect_error(rcs_sim_polygons(30, crossing_share = 0.9), class = "rcs_error_argument")
  expect_error(rcs_sim_polygons(30, special = NA), class = "rcs_error_argument")
  expect_error(rcs_sim_points(1.5), class = "rcs_error_argument")
  expect_error(rcs_sim_lines(-2), class = "rcs_error_argument")
})
