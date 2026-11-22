# Cells used throughout: valid resolution-5 and resolution-4 cells.
test_hex <- c("85283473fffffff", "85283447fffffff", "8528340bfffffff", "8428347ffffffff")

test_cells <- function(hex = test_hex) {
  new_rcs_h3(h3_hex_to_int64_raw(hex))
}

entry_for <- function(kind = "table", index_of = NA_character_, columns = NULL) {
  spec <- columns %||% columns_spec()
  list(kind = kind, index_of = index_of, columns = columns_to_json(spec))
}

# Class and constructor ---------------------------------------------------------

test_that("new_rcs_h3() gives class rcs_h3 on integer64, same bits", {
  x <- h3_hex_to_int64_raw(test_hex)
  h <- new_rcs_h3(x)
  expect_s3_class(h, c("rcs_h3", "integer64"), exact = TRUE)
  expect_identical(unclass(h), unclass(x))
  expect_s3_class(new_rcs_h3(), "rcs_h3")
  expect_length(new_rcs_h3(), 0)
})

# format() and print() ---------------------------------------------------------

test_that("format() gives lower-case hex, NA and <invalid>", {
  x <- c(test_cells(), new_rcs_h3(bit64::NA_integer64_), new_rcs_h3(bit64::as.integer64(42)))
  expect_identical(format(x), c(test_hex, "NA", "<invalid>"))
})

test_that("format() flags values with the cell layout but invalid digits", {
  # top digit 8, resolution 5, but digits after the resolution are not 7
  bad <- new_rcs_h3(h3_hex_to_int64_raw("852834730000000"))
  expect_identical(format(bad), "<invalid>")
})

test_that("format() never aborts on any 64-bit value", {
  set.seed(1)
  high <- sample(c(-.Machine$integer.max, .Machine$integer.max, 0L, -1L, 1L,
    sample.int(.Machine$integer.max, 200, replace = TRUE) * sample(c(-1L, 1L), 200, replace = TRUE)))
  low <- sample(c(-.Machine$integer.max, .Machine$integer.max, 0L, -1L, 1L,
    sample.int(.Machine$integer.max, 200, replace = TRUE) * sample(c(-1L, 1L), 200, replace = TRUE)))
  x <- new_rcs_h3(c(int64_from_halves(high, low), bit64::lim.integer64(), bit64::as.integer64(0)))
  out <- expect_no_error(format(x))
  expect_length(out, length(x))
  expect_true(all(out == "NA" | out == "<invalid>" | grepl("^8[0-9a-f]{14}$", out)))
  expect_no_error(print(x)) |> utils::capture.output() |> invisible()
})

test_that("print() shows the class, the length and hex", {
  x <- c(test_cells(), new_rcs_h3(bit64::NA_integer64_), new_rcs_h3(bit64::as.integer64(42)))
  expect_snapshot(print(x))
  expect_snapshot(print(new_rcs_h3()))
})

test_that("tibbles and sf print cells as hex", {
  x <- tibble::tibble(id = 1:4, h3 = test_cells())
  expect_snapshot(print(x))

  p <- rcs_sim_points(4)
  p$h3 <- test_cells()
  expect_snapshot(print(p))

  df_sf <- sf::st_sf(data.frame(id = 1:4, h3 = test_cells()), geometry = sf::st_geometry(p))
  expect_snapshot(print(df_sf))
})

test_that("pillar type is h3", {
  expect_identical(pillar::type_sum(test_cells()), "h3")
})

# Methods keep the class --------------------------------------------------------

test_that("subsetting, combining and reordering keep the class", {
  x <- test_cells()
  keep <- function(y) {
    expect_s3_class(y, c("rcs_h3", "integer64"), exact = TRUE)
  }
  keep(x[2:3])
  expect_identical(format(x[2:3]), test_hex[2:3])
  keep(x[[2]])
  expect_identical(format(x[[2]]), test_hex[[2]])
  y <- x
  y[1] <- x[4]
  keep(y)
  expect_identical(format(y), test_hex[c(4, 2, 3, 4)])
  keep(c(x, x))
  expect_identical(format(c(x, x)), rep(test_hex, 2))
  keep(c(x, bit64::as.integer64(x)))
  keep(rep(x, 2))
  expect_identical(format(rep(x, each = 2)), rep(test_hex, each = 2))
  keep(unique(c(x, x)))
  expect_identical(format(unique(c(x, x))), test_hex)
  keep(sort(x))
  expect_identical(format(sort(x)), sort(test_hex, method = "radix"))
  keep(sort(x, decreasing = TRUE))
  keep(rev(x))
  expect_identical(format(rev(x)), rev(test_hex))
})

test_that("comparison and arithmetic are those of integer64", {
  x <- test_cells()
  i <- bit64::as.integer64(x)
  expect_identical(x == x[1], i == i[1])
  expect_identical(x < x[1], i < i[1])
  expect_identical(as.character(x - x[1]), as.character(i - i[1]))
})

test_that("as.character() gives decimals, as for integer64", {
  x <- c(test_cells(), new_rcs_h3(bit64::NA_integer64_))
  expect_identical(as.character(x), as.character(bit64::as.integer64(x)))
  expect_identical(as.character(x)[1], "599686042433355775")
})

# vctrs and dplyr ----------------------------------------------------------------

test_that("vctrs common type with integer64 and itself is rcs_h3", {
  x <- test_cells()
  i <- bit64::as.integer64(x)
  expect_s3_class(vctrs::vec_ptype2(x, x), "rcs_h3")
  expect_s3_class(vctrs::vec_ptype2(x, i), "rcs_h3")
  expect_s3_class(vctrs::vec_ptype2(i, x), "rcs_h3")
  expect_s3_class(vctrs::vec_cast(i, new_rcs_h3()), "rcs_h3")
  expect_s3_class(vctrs::vec_cast(x, bit64::integer64()), "integer64")
  expect_false(inherits(vctrs::vec_cast(x, bit64::integer64()), "rcs_h3"))
  expect_identical(format(vctrs::vec_c(i, x)), rep(test_hex, 2))
  expect_identical(format(vctrs::vec_slice(x, 2:1)), test_hex[2:1])
})

test_that("dplyr verbs keep values and give rcs_h3", {
  x <- c(test_cells(), new_rcs_h3(bit64::NA_integer64_))
  df <- tibble::tibble(id = 1:5, h3 = x)

  f <- dplyr::filter(df, h3 == x[2] | is.na(h3))
  expect_s3_class(f$h3, "rcs_h3")
  expect_identical(format(f$h3), c(test_hex[2], "NA"))

  a <- dplyr::arrange(df, h3)
  expect_s3_class(a$h3, "rcs_h3")
  expect_identical(format(a$h3), c(sort(test_hex, method = "radix"), "NA"))
  expect_identical(format(dplyr::arrange(df, dplyr::desc(h3))$h3)[1:4],
    sort(test_hex, decreasing = TRUE, method = "radix"))

  other <- tibble::tibble(h3 = x[c(3, 1)], w = c("c", "a"))
  j <- dplyr::left_join(df, other, by = "h3")
  expect_s3_class(j$h3, "rcs_h3")
  expect_identical(j$w, c("a", NA, "c", NA, NA))

  other64 <- tibble::tibble(h3 = bit64::as.integer64(x[c(3, 1)]), w = c("c", "a"))
  j64 <- dplyr::left_join(df, other64, by = "h3")
  expect_s3_class(j64$h3, "rcs_h3")
  expect_identical(j64$w, c("a", NA, "c", NA, NA))
  j64r <- dplyr::left_join(other64, df, by = "h3")
  expect_s3_class(j64r$h3, "rcs_h3")
  expect_identical(j64r$id, c(3L, 1L))

  b <- dplyr::bind_rows(df, tibble::tibble(id = 6L, h3 = bit64::as.integer64(x[1])))
  expect_s3_class(b$h3, "rcs_h3")
  expect_identical(format(b$h3), c(format(x), test_hex[1]))
  b2 <- dplyr::bind_rows(tibble::tibble(id = 6L, h3 = bit64::as.integer64(x[1])), df)
  expect_s3_class(b2$h3, "rcs_h3")
})

# rcs_h3_hex() ---------------------------------------------------------------------

test_that("rcs_h3_hex() converts every input form", {
  x <- c(test_cells(), new_rcs_h3(bit64::NA_integer64_))
  want <- c(test_hex, NA)
  expect_identical(rcs_h3_hex(x), want)
  expect_identical(rcs_h3_hex(bit64::as.integer64(x)), want)
  expect_identical(rcs_h3_hex(c(toupper(test_hex), NA)), want)
  expect_identical(rcs_h3_hex(character()), character())
  expect_identical(rcs_h3_hex(new_rcs_h3()), character())
  skip_if_not_installed("h3o")
  expect_identical(rcs_h3_hex(h3o::h3_from_strings(test_hex)), test_hex)
})

test_that("rcs_h3_hex() warns for doubles and validates them", {
  expect_identical(rcs_h3_hex(NA_real_), NA_character_)
  # a double cannot hold a resolution-5 cell: its last bits are lost
  d <- as.double(bit64::as.integer64(test_cells()[1]))
  expect_snapshot(rcs_h3_hex(d), error = TRUE)
  expect_warning(
    expect_error(rcs_h3_hex(d), class = "rcs_error_h3_input"),
    class = "rcs_warning_h3_double"
  )
})

test_that("rcs_h3_hex() aborts on values that are not cells", {
  expect_snapshot(rcs_h3_hex(c("85283473fffffff", "not a cell")), error = TRUE)
  expect_error(rcs_h3_hex(bit64::as.integer64(42)), class = "rcs_error_h3_input")
  expect_error(rcs_h3_hex(new_rcs_h3(bit64::as.integer64(42))), class = "rcs_error_h3_input")
  expect_error(rcs_h3_hex(1L), class = "rcs_error_h3_input")
  expect_error(rcs_h3_hex(list()), class = "rcs_error_h3_input")
})

test_that("the DuckDB macro gives the same hex as rcs_h3_hex()", {
  expect_identical(
    h3_duckdb_macro_sql(),
    "CREATE OR REPLACE MACRO rcs_h3_hex(x) AS lower(printf('%x', x))"
  )
  con <- local_duckdb()
  DBI::dbExecute(con, h3_duckdb_macro_sql())
  DBI::dbWriteTable(con, "cells", data.frame(h3 = bit64::as.integer64(test_cells())))
  got <- DBI::dbGetQuery(con, "SELECT rcs_h3_hex(h3) AS hex FROM cells")$hex
  expect_identical(got, rcs_h3_hex(test_cells()))
})

# h3_classify() ------------------------------------------------------------------

test_that("h3_classify() classes cell columns of geospatial datasets", {
  cells <- bit64::as.integer64(test_cells())
  data <- tibble::tibble(
    h3 = cells, h3_main = cells, h3_p3 = cells, h3_px = cells,
    other = cells, n = 1:4
  )
  out <- h3_classify(data, entry_for(kind = "geospatial"))
  expect_s3_class(out, "tbl_df")
  for (nm in c("h3", "h3_main", "h3_p3")) {
    expect_s3_class(out[[nm]], "rcs_h3")
    expect_identical(unclass(out[[nm]]), unclass(cells))
  }
  for (nm in c("h3_px", "other")) {
    expect_false(inherits(out[[nm]], "rcs_h3"))
    expect_s3_class(out[[nm]], "integer64")
  }
  expect_identical(out$n, 1:4)
})

test_that("h3_classify() classes cell columns of index tables", {
  cells <- bit64::as.integer64(test_cells())
  data <- tibble::tibble(h3 = cells, h3_main = cells, share = 0.5)
  out <- h3_classify(data, entry_for(kind = "table", index_of = "parcels"))
  expect_s3_class(out$h3, "rcs_h3")
  expect_s3_class(out$h3_main, "rcs_h3")
  expect_identical(out$share, rep(0.5, 4))
})

test_that("h3_classify() leaves an integer64 h3 column of a plain table", {
  cells <- bit64::as.integer64(test_cells())
  data <- tibble::tibble(h3 = cells, h3_p3 = cells)
  out <- h3_classify(data, entry_for(kind = "table"))
  expect_identical(out, data)
  expect_false(inherits(out$h3, "rcs_h3"))
})

test_that("h3_classify() classes columns recorded as rcs_h3", {
  cells <- bit64::as.integer64(test_cells())
  spec <- columns_spec(
    name = c("cell", "plain"),
    type = c("int64", "int64"),
    r_type = list(list(class = "rcs_h3"), list(class = "integer64"))
  )
  data <- tibble::tibble(cell = cells, plain = cells)
  out <- h3_classify(data, entry_for(kind = "table", columns = spec))
  expect_s3_class(out$cell, "rcs_h3")
  expect_false(inherits(out$plain, "rcs_h3"))
})

test_that("h3_classify() keeps sf and data frame classes and skips non-integer64", {
  p <- rcs_sim_points(4)
  p$h3 <- bit64::as.integer64(test_cells())
  p$h3_main <- test_hex
  out <- h3_classify(p, entry_for(kind = "geospatial"))
  expect_s3_class(out, "sf")
  expect_s3_class(out$h3, "rcs_h3")
  expect_identical(out$h3_main, test_hex)

  df <- data.frame(h3 = bit64::as.integer64(test_cells()))
  out_df <- h3_classify(df, entry_for(kind = "geospatial"))
  expect_identical(class(out_df), "data.frame")
  expect_s3_class(out_df$h3, "rcs_h3")
})

test_that("h3_classify() tolerates entries without columns or index_of", {
  cells <- bit64::as.integer64(test_cells())
  data <- tibble::tibble(h3 = cells)
  out <- h3_classify(data, list(kind = "geospatial"))
  expect_s3_class(out$h3, "rcs_h3")
  out2 <- h3_classify(data, list(kind = "table", index_of = NA_character_, columns = NA_character_))
  expect_identical(out2, data)
})
