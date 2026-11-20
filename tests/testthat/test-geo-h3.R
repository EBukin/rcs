# Cell conversion, validation and parents.

# Cells of every resolution at random places, by h3o alone.
ref_random_cells <- function(n_per_res = 50, seed = 1) {
  withr::with_seed(seed, {
    unlist(lapply(0:15, function(r) {
      ref_cell_hex(stats::runif(n_per_res, -180, 180), stats::runif(n_per_res, -89, 89), r)
    }))
  })
}

test_that("hex, integer64 and H3 inputs convert to the same cells", {
  skip_if_no_h3()
  hex <- ref_random_cells()
  int <- h3_as_int64(hex)
  expect_s3_class(int, "integer64")
  expect_length(int, length(hex))
  expect_identical(h3_as_hex(int), hex)
  expect_identical(h3_as_int64(h3o::h3_from_strings(hex)), int)
  expect_identical(h3_as_hex(h3o::h3_from_strings(hex)), hex)
  expect_identical(h3_as_int64(int), int)
  expect_identical(h3_as_hex(toupper(hex)), hex)
})

test_that("a cell converts to its documented integer", {
  expect_identical(
    h3_as_int64("8928308280fffff"),
    bit64::as.integer64("617700169958293503")
  )
  expect_identical(h3_as_hex(bit64::as.integer64("617700169958293503")), "8928308280fffff")
})

test_that("NA and zero-length inputs pass through", {
  expect_identical(h3_as_hex(c(NA, "8928308280fffff")), c(NA, "8928308280fffff"))
  int <- h3_as_int64(c("8928308280fffff", NA))
  expect_true(is.na(int[2]))
  expect_identical(h3_as_hex(int), c("8928308280fffff", NA))
  expect_identical(h3_as_int64(character()), bit64::integer64())
  expect_identical(h3_as_hex(bit64::integer64()), character())
})

test_that("a plain numeric or another type aborts", {
  expect_error(h3_as_int64(617700169958293503), class = "rcs_error_h3_input")
  expect_error(h3_as_hex(1L), class = "rcs_error_h3_input")
  expect_error(h3_as_int64(list("8928308280fffff")), class = "rcs_error_h3_input")
  expect_error(h3_as_int64(TRUE), class = "rcs_error_h3_input")
  expect_snapshot(h3_as_int64(1.5), error = TRUE)
})

test_that("strings and integers that are not cells abort", {
  skip_if_no_h3()
  bad <- c(
    "8928308280ffff0", # digit after the resolution not 7
    "zz", "", "0928308280fffff", "8928308280fffffff",
    "80f5fffffffffff" # base cell 122 does not exist
  )
  expect_true(h3o::is_valid_h3("80f3fffffffffff")) # base cell 121 does
  for (b in bad) {
    expect_error(h3_as_int64(b), class = "rcs_error_h3_input", info = b)
  }
  expect_error(h3_as_hex(bit64::as.integer64(c(0, -5, 12345))), class = "rcs_error_h3_input")
  expect_snapshot(h3_as_hex(c("8928308280fffff", "8928308280ffff0")), error = TRUE)
})

test_that("validation agrees with h3o on altered cells", {
  skip_if_no_h3()
  hex <- ref_random_cells(n_per_res = property_cases(default = 200L, full = 1000L, cran = 30L))
  altered <- withr::with_seed(2, {
    at <- sample(1:15, length(hex), replace = TRUE)
    substr(hex, at, at) <- sample(c(0:9, letters[1:6]), length(hex), replace = TRUE)
    hex
  })
  expect_identical(h3_hex_is_cell(altered), h3o::is_valid_h3(altered))
})

test_that("pentagon cells and their deleted subsequence are recognised", {
  skip_if_no_h3()
  # base cell 4 is a pentagon; its children never start with digit 1
  pentagon <- "8009fffffffffff"
  children <- as.character(h3o::get_children(h3o::h3_from_strings(pentagon), 2L)[[1]])
  expect_true(all(h3_hex_is_cell(children)))
  # resolution 1, base cell 4, digit 1: deleted; digit 0: the centre child
  expect_false(h3o::is_valid_h3("81087ffffffffff"))
  expect_error(h3_as_int64("81087ffffffffff"), class = "rcs_error_h3_input")
  expect_true(h3o::is_valid_h3("81083ffffffffff"))
  expect_s3_class(h3_as_int64("81083ffffffffff"), "integer64")
})

test_that("h3_parent() equals h3o's parents at every coarser resolution", {
  skip_if_no_h3()
  cells <- withr::with_seed(3, ref_cell_hex(stats::runif(300, -180, 180), stats::runif(300, -85, 85), 9))
  int <- h3_as_int64(cells)
  for (r in 0:9) {
    ref <- as.character(h3o::get_parents(h3o::h3_from_strings(cells), r))
    expect_identical(h3_as_hex(h3_parent(int, r)), ref, info = r)
  }
  expect_identical(h3_parent(int, 9L), int)
})

test_that("h3_parent() keeps NA and aborts for a finer resolution", {
  int <- h3_as_int64(c("8928308280fffff", NA))
  out <- h3_parent(int, 5L)
  expect_true(is.na(out[2]))
  expect_identical(h3_as_hex(out[1]), "85283083fffffff")
  expect_error(h3_parent(int, 10L), "finer")
  expect_error(h3_parent(int, 1.5), class = "rcs_error_argument")
  expect_error(h3_parent(c(1, 2), 1L), class = "rcs_error_h3_input")
})

test_that("the cell of a point is computed from the point, not from a parent", {
  skip_if_no_h3()
  # find a point whose resolution-6 cell's parent is not its resolution-5 cell
  found <- withr::with_seed(4, {
    lon <- stats::runif(2000, -30, -24)
    lat <- stats::runif(2000, 6, 9)
    c5 <- ref_cell_hex(lon, lat, 5)
    c6 <- ref_cell_hex(lon, lat, 6)
    parent <- as.character(h3o::get_parents(h3o::h3_from_strings(c6), 5L))
    i <- which(parent != c5)[1]
    list(lon = lon[i], lat = lat[i], c5 = c5[i], parent = parent[i])
  })
  expect_false(identical(found$c5, found$parent))
  point <- sf::st_sf(id = 1L, geometry = sf::st_sfc(sf::st_point(c(found$lon, found$lat)), crs = 4326))
  encoded <- geo_encode(point, h3_res = 5L)
  expect_identical(h3_as_hex(encoded$data$h3), found$c5)
  expect_identical(h3_as_hex(geo_cells_touched(point, 5L)[[1]]), found$c5)
})
