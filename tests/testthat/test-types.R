# store_restore_types(): R types from the catalog's `columns` specification
# for data that reached R by other routes (plan 0002, D4, D5, D8).

# A local store holding `t/sales`: the simulated table plus `small`, an
# integer64 column whose values fit an integer (Arrow returns integers).
local_types_store <- function(n = 60, frame = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = frame)
  withr::local_options(rcs.quiet = TRUE, .local_envir = frame)
  st <- store_connect(dir, create = TRUE)
  data <- rcs_sim_table(n)
  data$small <- bit64::as.integer64(seq_len(n))
  store_write(st, data, "t/sales", title = "Sales", description = "Simulated sales")
  list(st = st, dir = dir, data = data)
}

# The rows of a dataset as Arrow gives them from its files (storage types).
read_files <- function(dir, dataset) {
  paths <- list.files(file.path(dir, dataset), pattern = "^part-.*\\.parquet$", full.names = TRUE)
  stopifnot(length(paths) == 1)
  tibble::as_tibble(arrow::read_parquet(paths))
}

test_that("store_restore_types() restores types of data read from the files", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")
  raw$product <- as.character(raw$product)
  raw$grade <- as.character(raw$grade)
  expect_type(raw$wait, "double")
  expect_type(raw$small, "integer")
  expect_s3_class(raw$tags, "arrow_list")

  got <- store_restore_types(raw, s$st, "t/sales")
  expect_s3_class(got, "tbl_df")
  expect_identical(levels(got$product), sprintf("p%02d", 1:20))
  expect_false(is.ordered(got$product))
  expect_identical(as.character(got$product), raw$product)
  expect_true(is.ordered(got$grade))
  expect_identical(levels(got$grade), c("low", "mid", "high"))
  expect_s3_class(got$wait, "difftime")
  expect_identical(units(got$wait), "hours")
  expect_equal(as.double(got$wait), raw$wait)
  expect_s3_class(got$small, "integer64")
  expect_identical(got$small, bit64::as.integer64(raw$small))
  expect_identical(got$big, s$data$big)
  expect_type(got$tags, "list")
  expect_false(inherits(got$tags, "arrow_list"))
  expect_identical(got$tags, lapply(raw$tags, as.vector))
  # untouched columns
  expect_identical(got$note, raw$note)
  expect_identical(got$date, raw$date)
})

test_that("factors from factor input and the short name", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")
  raw$product <- factor(as.character(raw$product))
  got <- store_restore_types(raw, s$st, "sales")
  expect_identical(levels(got$product), sprintf("p%02d", 1:20))
  expect_identical(as.character(got$product), as.character(raw$product))
})

test_that("values outside the levels become NA with one warning per column", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")[1:5, c("product", "grade", "qty")]
  raw$product <- c("p01", "zz", "yy", NA, "p02")
  raw$grade <- factor(c("low", "top", "mid", "high", "low"))
  expect_snapshot(got <- store_restore_types(raw, s$st, "t/sales"))
  expect_identical(as.character(got$product), c("p01", NA, NA, NA, "p02"))
  expect_identical(as.character(got$grade), c("low", NA, "mid", "high", "low"))
  expect_true(is.ordered(got$grade))
})

test_that("integer64 from double: whole values below 2^53 only", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")[1:3, c("small", "big")]
  raw$small <- c(1, 2, 3)
  raw$big <- c(1, 2^53 + 2, 3)
  expect_snapshot(got <- store_restore_types(raw, s$st, "t/sales"))
  expect_identical(got$small, bit64::as.integer64(1:3))
  expect_identical(got$big, raw$big)

  raw$big <- c(1.5, 2, NA)
  expect_snapshot(got <- store_restore_types(raw, s$st, "t/sales"))
  expect_identical(got$big, raw$big)

  raw$big <- c(-4, 2, NA)
  expect_no_warning(got <- store_restore_types(raw, s$st, "t/sales"))
  expect_identical(got$big, bit64::as.integer64(c(-4, 2, NA)))
})

test_that("incompatible types and unknown columns are left as they are, silently", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")[1:4, ]
  odd <- tibble::tibble(
    product = 1:4, grade = c(TRUE, FALSE, NA, TRUE), wait = c("a", "b", "c", "d"),
    small = c("1", "2", "3", "4"), tags = 1:4, extra = raw$note
  )
  expect_no_warning(got <- store_restore_types(odd, s$st, "t/sales"))
  expect_identical(got, odd)
})

test_that("difftime from double and from difftime in other units", {
  s <- local_types_store()
  x <- tibble::tibble(wait = c(1.5, NA))
  got <- store_restore_types(x, s$st, "t/sales")
  expect_identical(got$wait, as.difftime(c(1.5, NA), units = "hours"))
  x <- tibble::tibble(wait = as.difftime(c(90, NA), units = "mins"))
  got <- store_restore_types(x, s$st, "t/sales")
  expect_identical(units(got$wait), "hours")
  expect_equal(as.double(got$wait), c(1.5, NA))
})

test_that("the class of x is kept: data frame, tibble, sf", {
  s <- local_types_store()
  raw <- read_files(s$dir, "t/sales")
  df <- as.data.frame(raw)
  got <- store_restore_types(df, s$st, "t/sales")
  expect_identical(class(got), "data.frame")
  expect_s3_class(got$wait, "difftime")
  expect_identical(class(store_restore_types(raw, s$st, "t/sales")), class(raw))
  expect_identical(store_restore_types(raw[0, ], s$st, "t/sales")$small, bit64::integer64())
})

test_that("H3 cells by h3_classify(): geospatial datasets and index tables", {
  skip_if_not_installed("sf")
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  files <- list.files(file.path(fx$primary, "shapes/polygons"),
    pattern = "^part-.*\\.parquet$", recursive = TRUE, full.names = TRUE
  )
  raw <- tibble::as_tibble(as.data.frame(arrow::read_parquet(files[[1]])))
  cells <- grep("^h3", names(raw), value = TRUE)
  expect_true(all(c("h3") %in% cells))
  got <- store_restore_types(raw, fx$st, "shapes/polygons")
  for (name in cells) {
    expect_s3_class(got[[name]], c("rcs_h3", "integer64"), exact = TRUE)
    expect_identical(unclass(got[[name]]), unclass(raw[[name]]))
  }

  index_files <- list.files(file.path(fx$primary, "shapes/polygons__h3"),
    pattern = "^part-.*\\.parquet$", recursive = TRUE, full.names = TRUE
  )
  idx <- tibble::as_tibble(as.data.frame(arrow::read_parquet(index_files[[1]])))
  got <- store_restore_types(idx, fx$st, "shapes/polygons__h3")
  expect_s3_class(got$h3, "rcs_h3")
  expect_s3_class(got$h3_main, "rcs_h3")

  # sf class kept
  shapes <- store_read(fx$st, "shapes/polygons")
  cells <- shapes$h3
  class(shapes$h3) <- "integer64"
  got <- store_restore_types(shapes, fx$st, "shapes/polygons")
  expect_identical(class(got), class(shapes))
  expect_identical(attr(got, "sf_column"), attr(shapes, "sf_column"))
  expect_s3_class(got$h3, "rcs_h3")
  expect_identical(unclass(got$h3), unclass(cells))
})

test_that("a column recorded as rcs_h3 becomes rcs_h3; a plain integer64 h3 stays", {
  s <- local_types_store()
  cells <- h3_hex_to_int64_raw(c("85283473fffffff", "85283447fffffff"))
  x <- tibble::tibble(h3 = cells, small = cells)
  # A table: `h3` is not a cell column by name.
  got <- store_restore_types(x, s$st, "t/sales")
  expect_false(inherits(got$h3, "rcs_h3"))
  expect_false(inherits(got$small, "rcs_h3"))
  # Record `small` as rcs_h3 in the catalog held by the connection.
  catalog <- s$st$primary$catalog
  i <- match("t/sales", catalog$dataset)
  spec <- columns_from_json(catalog$columns[[i]])
  spec$r_type[[match("small", spec$name)]] <- list(class = "rcs_h3")
  catalog$columns[[i]] <- columns_to_json(spec)
  s$st$primary$catalog <- catalog
  got <- store_restore_types(x, s$st, "t/sales")
  expect_s3_class(got$small, c("rcs_h3", "integer64"), exact = TRUE)
  expect_identical(unclass(got$small), unclass(cells))
  # also from a double that holds a small value exactly
  got <- store_restore_types(tibble::tibble(small = c(5, NA)), s$st, "t/sales")
  expect_s3_class(got$small, "rcs_h3")
})

test_that("unknown dataset and bad arguments abort", {
  s <- local_types_store()
  x <- tibble::tibble(qty = 1:2)
  expect_error(store_restore_types(x, s$st, "t/nothing"), class = "rcs_error_dataset_not_found")
  expect_snapshot(store_restore_types(x, s$st, "t/nothing"), error = TRUE)
  expect_snapshot(store_restore_types(1:3, s$st, "t/sales"), error = TRUE)
})
