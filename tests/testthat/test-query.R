plain_tibble <- function(x, key = NULL) {
  x <- tibble::as_tibble(x)
  if (length(key) > 0 && nrow(x) > 1) {
    x <- x[do.call(order, c(unname(as.list(x[key])), method = "radix")), ]
  }
  attr(x, "row.names") <- seq_len(nrow(x))
  x
}

opened_files <- function() {
  trace <- rcs_trace()
  trace$detail[trace$counter == "file_open"]
}

# The version hex of a fixture depends on when it was written.
scrub_version <- function(x) gsub("(Version:  )[0-9a-f]{8}", "\\1<version>", x)

print_lines <- function(x, ...) utils::capture.output(print(x, ...))

test_that("store_open() returns a lazy query without opening files", {
  fx <- local_test_store(secondaries = 0L)
  withr::local_options(rcs.trace = TRUE)
  q <- store_open(fx$st, "daily")
  expect_s3_class(q, "rcs_query")
  expect_length(opened_files(), 0)
  expect_snapshot(store_open(fx$st, "nothing"), error = TRUE)
})

test_that("an unfiltered query prints a header, the first rows and the rows left", {
  fx <- local_test_store(secondaries = 0L)
  q <- store_open(fx$st, "summary")
  expect_snapshot(q, transform = scrub_version)
  out <- print_lines(q)
  entry <- q$entry
  expect_match(out[[3]], paste0("Version:  ", substr(entry$version, 1, 8), " (current)"), fixed = TRUE)
  expect_match(out[[1]], "[40 x 15] (table)", fixed = TRUE)
  expect_match(print_lines(dplyr::select(q, shop_id, qty))[[1]], "[40 x 2]", fixed = TRUE)
  expect_match(print_lines(dplyr::mutate(q, value = qty * price))[[1]], "[40 x 16]", fixed = TRUE)
  expect_match(print_lines(dplyr::arrange(q, qty))[[1]], "[?? x 15]", fixed = TRUE)
})

test_that("a filtered or shortened query prints ?? rows, the filter and the pruned files", {
  fx <- local_test_store(secondaries = 0L)
  q <- store_open(fx$st, "sales/daily")
  filtered <- q |>
    dplyr::filter(year == 2024, qty > 20) |>
    dplyr::select(shop_id, date, qty, price) |>
    dplyr::arrange(shop_id, date, qty, price)
  expect_snapshot(filtered, transform = scrub_version)
  short <- utils::head(store_open(fx$st, "summary"), 5)
  expect_snapshot(short, transform = scrub_version)
})

test_that("a geospatial query prints geometry and cells in hex", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  q <- store_open(fx$st, "shapes/polygons")
  expect_match(print_lines(q)[[1]], "shapes/polygons [60 x ", fixed = TRUE)
  sorted <- q |>
    dplyr::select(id, h3, area, geometry) |>
    dplyr::arrange(id)
  expect_snapshot(sorted, transform = scrub_version)
  out <- print_lines(sorted)
  first <- dplyr::collect(utils::head(sorted, 1))
  expect_true(any(grepl(format(first$h3), out, fixed = TRUE)))
})

test_that("a spatial filter prints its description and a footer that allows more rows", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  box <- sf::st_as_sfc(sf::st_bbox(c(xmin = -29, ymin = 6, xmax = -26, ymax = 9), crs = sf::st_crs(4326)))
  q <- store_open(fx$st, "shapes/polygons") |>
    dplyr::filter(area > 0) |>
    store_intersects(box) |>
    dplyr::select(id, area, geometry) |>
    dplyr::arrange(id)
  expect_snapshot(print(q, n = 3), transform = scrub_version)
  out <- print_lines(q, n = 3)
  expect_true("# Filter:   (with spatial predicate)" %in% out)
  expect_identical(utils::tail(out, 2)[[1]], "# i more rows may exist")
})

test_that("a query with no rows prints its header and 0 rows", {
  fx <- local_test_store(secondaries = 0L)
  none <- dplyr::filter(store_open(fx$st, "sales/daily"), year == 1999L)
  expect_snapshot(none, transform = scrub_version)
})

test_that("a dropped geometry is not counted and not printed", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  q <- store_open(fx$st, "shapes/polygons")
  with_geometry <- print_lines(q)[[1]]
  ncol_shown <- function(line) as.integer(sub(".* x ([0-9]+)\\].*", "\\1", line))
  flat <- q
  flat$geometry <- FALSE
  out <- print_lines(dplyr::arrange(dplyr::select(flat, id, area, geometry), id))
  expect_match(out[[1]], "[?? x 2]", fixed = TRUE)
  expect_false(any(grepl("geometry", out, fixed = TRUE)))
  expect_identical(ncol_shown(print_lines(flat)[[1]]), ncol_shown(with_geometry) - 1L)
  expect_identical(ncol_shown(print_lines(dplyr::select(q, -geometry))[[1]]), ncol_shown(with_geometry) - 1L)
})

test_that("print() takes the number of rows from n or from rcs.print_rows", {
  fx <- local_test_store(secondaries = 0L)
  q <- store_open(fx$st, "summary")
  expect_snapshot(print(q, n = 3), transform = scrub_version)
  three <- print_lines(q, n = 3)
  withr::local_options(rcs.print_rows = 3)
  expect_identical(print_lines(q), three)
  expect_snapshot(print(q, n = 0), error = TRUE)
})

test_that("a long filter is cut to the console width", {
  fx <- local_test_store(secondaries = 0L)
  q <- dplyr::filter(store_open(fx$st, "summary"), shop_id %in% c(1:30, 41:70), qty > 0)
  expect_snapshot(q, transform = scrub_version)
  out <- print_lines(q, width = 60)
  filter_line <- grep("^# Filter:", out, value = TRUE)
  expect_length(filter_line, 1)
  expect_match(filter_line, "...", fixed = TRUE)
  expect_lte(nchar(filter_line), 60)
})

test_that("printing a filtered query opens only the kept files and returns the query", {
  fx <- local_test_store(secondaries = 0L)
  files <- fx$st$primary$files[fx$st$primary$files$dataset == "sales/daily", ]
  q <- dplyr::filter(store_open(fx$st, "sales/daily"), year == 2024L)
  withr::local_options(rcs.trace = TRUE)
  utils::capture.output(res <- withVisible(print(q)))
  expect_identical(opened_files(), files$path[grepl("2024", files$partition_values)])
  expect_false(res$visible)
  expect_identical(res$value, q)
})

test_that("dplyr verbs on a query equal dplyr on the collected data", {
  fx <- local_test_store(secondaries = 0L)
  q <- store_open(fx$st, "sales/daily")
  all <- dplyr::collect(q)
  expect_identical(nrow(all), nrow(fx$data[["sales/daily"]]))
  key <- c("shop_id", "date", "product")

  got <- q |>
    dplyr::filter(qty > 20, !is.na(price)) |>
    dplyr::select(shop_id, date, product, qty, price) |>
    dplyr::mutate(value = qty * price) |>
    dplyr::rename(amount = qty) |>
    dplyr::collect()
  expected <- all |>
    dplyr::filter(qty > 20, !is.na(price)) |>
    dplyr::select(shop_id, date, product, qty, price) |>
    dplyr::mutate(value = qty * price) |>
    dplyr::rename(amount = qty)
  expect_identical(plain_tibble(got, key), plain_tibble(expected, key))

  sorted <- q |> dplyr::arrange(dplyr::desc(qty)) |> head(5) |> dplyr::collect()
  expect_identical(sorted$qty, utils::head(sort(all$qty, decreasing = TRUE), 5))
  shops <- q |> dplyr::distinct(shop_id) |> dplyr::arrange(shop_id) |> dplyr::collect()
  expect_identical(shops$shop_id, sort(unique(all$shop_id)))
  expect_identical(sort(dplyr::pull(q, qty)), sort(all$qty))
  expect_identical(dplyr::pull(dplyr::filter(q, year == 2024), "year"), all$year[all$year == 2024])

  computed <- dplyr::compute(dplyr::filter(q, year == 2023))
  expect_s3_class(computed, "rcs_query")
  expect_identical(
    plain_tibble(dplyr::collect(computed), key),
    plain_tibble(all[all$year == 2023, ], key)
  )
  expect_identical(
    plain_tibble(dplyr::collect(dplyr::filter(computed, qty > 10)), key),
    plain_tibble(all[all$year == 2023 & all$qty > 10 & !is.na(all$qty), ], key)
  )
  out <- utils::capture.output(res <- dplyr::glimpse(q))
  expect_identical(res, q)
  expect_match(out[[1]], "Rows: 10")
})

test_that("collect() restores the R types after any filter", {
  fx <- local_test_store(secondaries = 0L)
  got <- dplyr::collect(dplyr::filter(store_open(fx$st, "sales/daily"), year == 2024))
  expect_s3_class(got$big, "integer64")
  expect_identical(units(got$wait), "hours")
  expect_identical(levels(got$product), sprintf("p%02d", 1:20))
  expect_type(got$tags, "list")
  expect_false(inherits(got$tags, "arrow_list"))
})

test_that("a partition filter opens only the matching files, other filters every file", {
  fx <- local_test_store(secondaries = 0L)
  st <- fx$st
  data <- fx$data[["sales/daily"]]
  files <- st$primary$files[st$primary$files$dataset == "sales/daily", ]
  withr::local_options(rcs.trace = TRUE)
  key <- c("shop_id", "date", "product")
  year_2024 <- files$path[grepl("2024", files$partition_values)]

  target <- 2024L
  got <- dplyr::collect(dplyr::filter(store_open(st, "sales/daily"), year == target))
  expect_identical(opened_files(), year_2024)
  expect_identical(nrow(got), sum(data$year == 2024))

  got <- dplyr::collect(dplyr::filter(store_open(st, "sales/daily"), year %in% c(2024L, 2030L), qty > 5))
  expect_identical(opened_files(), year_2024)
  expect_identical(nrow(got), sum(data$year == 2024 & data$qty > 5, na.rm = TRUE))

  got <- dplyr::collect(dplyr::filter(store_open(st, "sales/daily"), year == 2024 | qty > 45))
  expect_setequal(opened_files(), files$path)
  expect_identical(nrow(got), sum(data$year == 2024 | data$qty > 45, na.rm = TRUE))

  # a partition column changed by an earlier verb is not used for pruning
  got <- store_open(st, "sales/daily") |>
    dplyr::mutate(year = year + 1L) |>
    dplyr::filter(year == 2024) |>
    dplyr::collect()
  expect_setequal(opened_files(), files$path)
  expect_identical(nrow(got), sum(data$year == 2023))

  # no partition matches: no file is opened, the types are kept
  none <- dplyr::collect(dplyr::filter(store_open(st, "sales/daily"), year == 1999L))
  expect_length(opened_files(), 0)
  expect_identical(nrow(none), 0L)
  expect_identical(names(none), names(data))
  expect_identical(levels(none$product), levels(data$product))
  expect_s3_class(none$big, "integer64")
})

test_that("partitions of dates, strings and cells are pruned", {
  skip_if_no_h3()
  fx <- local_test_store(geospatial = "polygons", secondaries = 0L)
  st <- fx$st
  table <- tibble::tibble(
    id = 1:12,
    day = rep(as.Date(c("2024-01-01", "2024-02-01", "2024-03-01")), 4),
    shop = rep(c("a", "b"), 6),
    value = seq_len(12) / 2
  )
  fixture_write(st, table, "demo/days", title = "Days", description = "Partitioned by date and shop.",
    key = "id", partition = c("day", "shop")
  )
  withr::local_options(rcs.trace = TRUE)
  got <- dplyr::collect(dplyr::filter(store_open(st, "demo/days"), day >= as.Date("2024-02-01"), shop == "a"))
  expect_length(opened_files(), 2)
  expect_identical(plain_tibble(got, "id"), plain_tibble(table[table$day >= as.Date("2024-02-01") & table$shop == "a", ], "id"))

  polygons <- store_read(st, "shapes/polygons", geometry = FALSE)
  column <- grep("^h3_p[0-9]+$", names(polygons), value = TRUE)
  cell <- polygons[[column]][[1]]
  q <- dplyr::filter(store_open(st, "shapes/polygons"), !!rlang::sym(column) == cell)
  got <- dplyr::collect(q)
  expect_length(opened_files(), 1)
  expect_identical(sort(got$id), sort(polygons$id[as.character(polygons[[column]]) == as.character(cell)]))
})

test_that("a lazy query reads from the location store_read() would read from", {
  fx <- local_test_store(secondaries = 1L)
  st <- fx$st
  primary <- st$primary
  primary$backend$type <- "gcs"
  st$primary <- primary
  expect_snapshot(
    q <- store_open(st, "sales/summary"),
    transform = function(x) gsub("[A-Za-z]:?[^ ]*secondary1", "<secondary1>", x)
  )
  expect_identical(q$location$uri, fx$secondary[[1]])
  expect_snapshot(q, transform = scrub_version)
  expect_match(print_lines(q)[[2]], "Location: secondary 1 (local)", fixed = TRUE)
})

test_that("a query on geospatial data collects sf without .rcs_id", {
  skip_if_no_h3()
  fx <- local_test_store(tables = FALSE, geospatial = "polygons", secondaries = 0L)
  q <- store_open(fx$st, "polygons")
  got <- dplyr::collect(dplyr::filter(q, area > 0.1))
  expect_s3_class(got, "sf")
  expect_false(".rcs_id" %in% names(got))
  data <- fx$data[["shapes/polygons"]]
  expect_setequal(got$id, data$id[which(data$area > 0.1)])
  areas <- dplyr::pull(q, area)
  expect_identical(sort(areas), sort(data$area))
  flat <- dplyr::collect(dplyr::select(q, id, area))
  expect_false(inherits(flat, "sf"))
})

test_that("verbs abort as dplyr does, with the query's message", {
  fx <- local_test_store(secondaries = 0L)
  q <- store_open(fx$st, "sales/daily")
  expect_snapshot(dplyr::filter(q, qty > 1, .by = shop_id), error = TRUE)
  expect_error(dplyr::select(q, nothing))
  expect_snapshot(store_intersects("not a query", 1), error = TRUE)
})
