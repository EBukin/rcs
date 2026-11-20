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

test_that("store_open() returns a lazy query that prints its dataset, files and columns", {
  fx <- local_test_store(secondaries = 0L)
  withr::local_options(rcs.trace = TRUE)
  q <- store_open(fx$st, "daily")
  expect_s3_class(q, "rcs_query")
  expect_length(opened_files(), 0)
  expect_snapshot(q)
  expect_snapshot(dplyr::filter(q, year == 2024))
  expect_snapshot(store_open(fx$st, "nothing"), error = TRUE)
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
  expect_snapshot(q)
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
