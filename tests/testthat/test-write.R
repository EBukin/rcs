# store_write(): modes, kinds, uploads, failures, the write guard, counters.
# Data are verified with files_read_row_groups() and geo_decode(), not with
# store_read() (work package F).

# Helpers -----------------------------------------------------------------------

sales_data <- function(n = 120, seed = 1) {
  rcs_sim_table(n, seed = seed)
}

sales_key <- c("shop_id", "date", "product")

local_no_wait <- function(frame = parent.frame()) {
  testthat::local_mocked_bindings(retry_waits = function() c(0, 0), .package = "rcs", .env = frame)
}

local_store <- function(secondaries = 0L, history = FALSE, frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  paths <- file.path(root, c("primary", sprintf("secondary%d", seq_len(secondaries))))
  for (p in paths) suppressMessages(store_create(p, history = history))
  st <- store_connect(paths[[1]], secondary = paths[-1])
  list(st = st, root = normalizePath(root, winslash = "/"), paths = normalizePath(paths, winslash = "/"))
}

write_sales <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.",
    key = if (mode != "update") sales_key, partition = if (mode != "update") "year",
    mode = mode, ...
  ))
}

local_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
}

scrub <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) {
    x <- gsub(root, "<root>", x, fixed = TRUE)
    x <- gsub("[0-9.]+ (B|kB|MB|GB)", "<bytes>", x)
    x <- gsub("[0-9]+m [0-9]+s|[0-9]+\\.[0-9]s", "<time>", x)
    x <- gsub("(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])", "<version>", x, perl = TRUE)
    x <- gsub("backend call [0-9]+", "backend call <n>", x)
    gsub("[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}", "<date>", x)
  }
}

# All stored rows of a dataset in a location, R types restored.
stored_rows <- function(location, dataset) {
  entry <- location$catalog[location$catalog$dataset == dataset, ]
  paths <- location$files$path[location$files$dataset == dataset]
  rows <- lapply(paths, function(p) read_stored(location$backend, p))
  restore_types(vctrs::vec_rbind(!!!rows), columns_from_json(entry$columns))
}

expect_rows_equal <- function(stored, x, key) {
  x <- tibble::as_tibble(x)
  stored <- stored[vctrs::vec_order(key_frame(stored, key)), ]
  x <- x[vctrs::vec_order(key_frame(x, key)), ]
  expect_identical(nrow(stored), nrow(x))
  for (col in names(x)) {
    expect_identical(normalise_values(stored[[col]]), normalise_values(x[[col]]), label = col)
  }
}

data_puts <- function(stub) {
  log <- stub$log
  sum(log$generic == "be_put" & grepl("part-", log$path))
}

# Route every location of a connection through a counting stub.
stub_locations <- function(st, stub) {
  for (location in store_locations(st)) {
    location$backend <- stub_backend(location$backend, stub)
    store_set_location(st, location)
  }
  invisible(st)
}

# Arguments and modes -----------------------------------------------------------

test_that("arguments are checked before anything is written", {
  s <- local_store()
  x <- sales_data(20)
  expect_snapshot(error = TRUE, {
    store_write(s$st, x, "Sales", title = "t", description = "d")
    store_write(s$st, x, "sales__h3", title = "t", description = "d")
    store_write(s$st, x, "sales", title = "", description = "d")
    store_write(s$st, list(a = 1), "sales", title = "t", description = "d")
    store_write(s$st, x, "sales", title = "t", description = "d", history = "yes")
    store_write(s$st, x, "sales", title = "t", description = "d", mode = "update")
    store_write(s$st, x[0, ], "sales", title = "t", description = "d", partition = "year")
  })
  expect_identical(nrow(s$st$primary$catalog), 0L)
  expect_store_valid(s$st)
})

test_that("create writes a table to every location; create again aborts", {
  skip_below_level("default")
  s <- local_store(secondaries = 2L)
  x <- sales_data()
  local_snapshot_output()
  expect_snapshot(
    out <- store_write(s$st, x, "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      key = sales_key, partition = "year", source = "simulation"
    ),
    transform = scrub(s$root)
  )
  expect_identical(out$status, rep("written", 3))
  expect_identical(attr(out, "version"), s$st$primary$catalog$version)
  expect_store_valid(s$st)
  for (location in store_locations(s$st)) {
    expect_rows_equal(stored_rows(location, "sales/daily"), x, sales_key)
  }
  entry <- s$st$primary$catalog
  expect_identical(entry$partition[[1]], "year")
  expect_identical(entry$key[[1]], sales_key)
  expect_identical(entry$source, "simulation")
  expect_true(is.na(entry$history))
  expect_snapshot(write_sales(s$st, x), error = TRUE, transform = scrub(s$root))
  expect_store_valid(s$st)
})

test_that("a zero-row table and a table without key are written as one file", {
  skip_below_level("default")
  s <- local_store()
  x <- sales_data(30)
  suppressMessages(store_write(s$st, x[0, ], "empty", title = "Empty", description = "No rows."))
  suppressMessages(store_write(s$st, x, "plain", title = "Plain", description = "No key."))
  expect_store_valid(s$st)
  stored <- stored_rows(s$st$primary, "plain")
  for (col in names(x)) {
    expect_identical(normalise_values(stored[[col]]), normalise_values(x[[col]]), label = col)
  }
  expect_identical(as.numeric(s$st$primary$catalog$rows), c(0, 30))
})

# Determinism and unchanged writes ---------------------------------------------

test_that("the same data give the same version and upload nothing; one value changes it", {
  skip_below_level("default")
  s <- local_store(secondaries = 1L)
  x <- sales_data()
  first <- write_sales(s$st, x)
  v1 <- attr(first, "version")
  stub <- local_backend_stub(generic = "be_put")
  stub_locations(s$st, stub)
  withr::local_options(rcs.trace = TRUE)
  local_snapshot_output()
  expect_snapshot(
    again <- store_write(s$st, x, "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      key = sales_key, partition = "year", mode = "replace"
    ),
    transform = scrub(s$root)
  )
  expect_identical(attr(again, "version"), v1)
  expect_identical(again$status, c("unchanged", "same"))
  trace <- rcs_trace()
  expect_false(any(trace$counter == "backend_call" & trace$detail == "be_put"))
  expect_identical(sum(stub$log$generic == "be_put"), 0L)
  expect_store_valid(s$st)

  x$qty[[1]] <- x$qty[[1]] + 1L
  changed <- write_sales(s$st, x, mode = "replace")
  expect_false(identical(attr(changed, "version"), v1))
  expect_store_valid(s$st)
})

test_that("two writes in a row on one connection need no refresh", {
  skip_below_level("default")
  s <- local_store(secondaries = 1L)
  write_sales(s$st, sales_data(80, 1))
  write_sales(s$st, sales_data(90, 2), mode = "replace")
  suppressMessages(store_write(s$st, sales_data(20, 3), "sales/summary", title = "Summary", description = "Small."))
  expect_store_valid(s$st)
  expect_setequal(s$st$secondary[[1]]$catalog$dataset, c("sales/daily", "sales/summary"))
})

test_that("replace may change columns, key and partitioning", {
  skip_below_level("default")
  s <- local_store(secondaries = 1L)
  write_sales(s$st, sales_data())
  y <- sales_data(60, 4)[c("shop_id", "date", "qty")]
  y <- y[!duplicated(y[c("shop_id", "date")]), ]
  suppressMessages(store_write(s$st, y, "sales/daily",
    title = "Daily sales", description = "Fewer columns.",
    key = c("shop_id", "date"), mode = "replace"
  ))
  expect_store_valid(s$st)
  entry <- s$st$primary$catalog
  expect_identical(entry$partition[[1]], character())
  expect_identical(nrow(s$st$primary$files), 1L)
  expect_rows_equal(stored_rows(s$st$primary, "sales/daily"), y, c("shop_id", "date"))
})

test_that("descriptions of columns are kept when columns = NULL", {
  skip_below_level("default")
  s <- local_store()
  x <- sales_data(40)
  suppressMessages(store_write(s$st, x, "sales/daily",
    title = "Daily sales", description = "d", columns = c(qty = "Units sold")
  ))
  v <- s$st$primary$catalog$version
  suppressMessages(store_write(s$st, x, "sales/daily", title = "Daily sales", description = "d", mode = "replace"))
  spec <- columns_from_json(s$st$primary$catalog$columns)
  expect_identical(spec$description[spec$name == "qty"], "Units sold")
  expect_identical(s$st$primary$catalog$version, v)
})

# Update ------------------------------------------------------------------------

test_that("update replaces the partitions of x, keeps the others and uploads only new files", {
  skip_below_level("default")
  s <- local_store(secondaries = 1L)
  x <- sales_data(200)
  write_sales(s$st, x)
  v1 <- s$st$primary$catalog$version
  kept_path <- s$st$primary$files$path[s$st$primary$files$partition_values == "{\"year\":2023}"]

  y <- x[x$year == 2024, ]
  y <- y[-1, ]
  y$qty <- y$qty + 1L
  extra <- x[x$year == 2023, ][1:3, ]
  extra$year <- 2025L
  extra$date <- extra$date + 3650
  y <- rbind(y, extra)

  stub <- local_backend_stub(generic = "be_put")
  stub_locations(s$st, stub)
  local_snapshot_output()
  expect_snapshot(
    out <- store_write(s$st, y, "sales/daily", title = "Daily sales",
      description = "Simulated daily sales.", mode = "update"
    ),
    transform = scrub(s$root)
  )
  # Two new partition files per location, nothing else.
  expect_identical(data_puts(stub), 4L)
  expect_identical(out$uploaded, c(2, 2))
  expect_store_valid(s$st)
  files <- s$st$primary$files
  expect_identical(nrow(files), 3L)
  expect_true(kept_path %in% files$path)
  expect_false(identical(s$st$primary$catalog$version, v1))
  expected <- rbind(x[x$year == 2023, ], y)
  expect_rows_equal(stored_rows(s$st$primary, "sales/daily"), expected, sales_key)
  expect_rows_equal(stored_rows(s$st$secondary[[1]], "sales/daily"), expected, sales_key)
})

test_that("update aborts on a key repeated across partitions, other columns and one-file datasets", {
  skip_below_level("default")
  s <- local_store()
  x <- sales_data(100)
  write_sales(s$st, x)
  dup <- x[x$year == 2023, ][1:2, ]
  dup$year <- 2024L
  local_snapshot_output()
  expect_snapshot(error = TRUE, transform = scrub(s$root), {
    write_sales(s$st, dup, mode = "update")
    write_sales(s$st, x[x$year == 2024, -5], mode = "update")
    write_sales(s$st, transform(x[x$year == 2024, ], qty = as.double(qty)), mode = "update")
    store_write(s$st, x, "sales/daily", title = "t", description = "d", key = "shop_id", mode = "update")
  })
  suppressMessages(store_write(s$st, x, "plain", title = "Plain", description = "One file."))
  expect_snapshot(store_write(s$st, x, "plain", title = "Plain", description = "One file.", mode = "update"),
    error = TRUE
  )
  expect_store_valid(s$st)
})

test_that("update brings a secondary that missed a write up to date", {
  skip_below_level("default")
  fx <- local_test_store(partial = TRUE)
  st <- fx$st
  before <- st$secondary[[2]]$catalog$version[st$secondary[[2]]$catalog$dataset == "sales/daily"]
  expect_false(identical(before, st$primary$catalog$version[st$primary$catalog$dataset == "sales/daily"]))
  x <- fx$data[["sales/daily"]]
  y <- x[x$year == min(x$year), ]
  out <- write_sales(st, y, mode = "update")
  expect_identical(out$status, rep("written", 3))
  versions <- vapply(store_locations(st), function(l) l$catalog$version[l$catalog$dataset == "sales/daily"], character(1))
  expect_identical(length(unique(versions)), 1L)
  expect_store_valid(st)
  expected <- rbind(fx$data[["sales/daily"]][fx$data[["sales/daily"]]$year != min(x$year), ], y)
  expect_rows_equal(stored_rows(st$secondary[[2]], "sales/daily"), expected, sales_key)
})

# Plan 0004: user h3_p<r> partitions ----------------------------------------------
# A column named `h3_p<r>` given as `partition` is a user column: kept as given,
# never recomputed (D-A1 to D-A7). Red reasons are those of the plan, WP1.

# The reporter's table (note 0002): character `h3_p3`, keyed by `id`.
user_h3_table <- function() {
  list(
    x = data.frame(
      id = 1:5, v = c(1.5, 2.5, 3.5, 4.5, 5.5),
      h3_p3 = c(rep("831e5afffffffff", 3), rep("831e5cfffffffff", 2))
    ),
    y = data.frame(id = 6:7, v = c(6.5, 7.5), h3_p3 = "831e5cfffffffff")
  )
}

write_user_table <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "t/plain",
    title = "Plain", description = "User h3_p3 partition.",
    key = if (mode != "update") "id", mode = mode, ...
  ))
}

dataset_entry <- function(st, dataset) {
  catalog <- st$primary$catalog
  catalog[catalog$dataset == dataset, ]
}

# Simulated points with a user `h3_p3` (hex text, or `rcs_h3` when `cells`):
# the res-3 parents, except row `mismatch_id` of `create`, which is given the
# cell of another partition. `update` replaces the partition `replaced`, adds
# the partition `added` and holds row 1000 whose `h3_p3` (`added`) is not its
# computed parent. `expected` is the dataset after the update.
user_h3_points <- function(cells = FALSE) {
  x <- rcs_sim_points(40, seed = 1)
  parent <- h3_as_hex(rcs_geo_add(x, parents = 3L)$h3_p3)
  by_size <- names(sort(table(parent), decreasing = TRUE))
  replaced <- by_size[[1]]
  added <- by_size[[2]]
  other <- by_size[[3]]
  create <- x[parent != added, ]
  create$h3_p3 <- parent[parent != added]
  mis <- which(!create$h3_p3 %in% c(replaced, other))[[1]]
  create$h3_p3[mis] <- other
  update <- x[parent %in% c(replaced, added), ]
  update$value <- update$value + 1
  update$h3_p3 <- parent[parent %in% c(replaced, added)]
  extra <- create[mis, ]
  extra$id <- 1000L
  extra$h3_p3 <- added
  update <- rbind(update, extra)
  expected <- rbind(create[create$h3_p3 != replaced, ], update)
  if (cells) {
    create$h3_p3 <- new_rcs_h3(h3_as_int64(create$h3_p3))
    update$h3_p3 <- new_rcs_h3(h3_as_int64(update$h3_p3))
  }
  list(
    create = create, update = update, expected = expected,
    mismatch_id = create$id[[mis]], mismatch = other, replaced = replaced, added = added
  )
}

write_user_points <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "points/user",
    title = "Points", description = "User h3_p3 partition.",
    key = if (mode != "update") "id", mode = mode, ...
  ))
}

# `h3_p3` of the stored rows as hex, named by `id`.
stored_h3_p3 <- function(st, dataset) {
  rows <- stored_rows(st$primary, dataset)
  hex <- if (is.character(rows$h3_p3)) rows$h3_p3 else h3_as_hex(rcs_h3_strip(rows$h3_p3))
  stats::setNames(hex, rows$id)[order(rows$id)]
}

expect_user_points_kept <- function(st, d) {
  expected <- stats::setNames(d$expected$h3_p3, d$expected$id)[order(d$expected$id)]
  stored <- stored_h3_p3(st, "points/user")
  expect_identical(stored, expected)
  expect_identical(stored[[as.character(d$mismatch_id)]], d$mismatch)
  expect_identical(stored[["1000"]], d$added)
  files <- st$primary$files[st$primary$files$dataset == "points/user", ]
  values <- vctrs::vec_unique(d$expected$h3_p3)
  if (is.character(stored_rows(st$primary, "points/user")$h3_p3)) {
    pv <- vapply(values, function(v) partition_values_json(list(h3_p3 = v)), character(1))
  } else {
    pv <- vapply(values, function(v) partition_values_json(list(h3_p3 = h3_as_int64(v))), character(1))
  }
  expect_setequal(files$partition_values, unname(pv))
  entry <- dataset_entry(st, "points/user")
  expect_identical(entry$partition[[1]], "h3_p3")
  expect_identical(entry$partition_auto, FALSE)
}

test_that("a table with a character user h3_p3 updates with partition = \"h3_p3\"", {
  # A-T1. Red: the update aborts with "Stored partition: h3".
  s <- local_store()
  d <- user_h3_table()
  write_user_table(s$st, d$x, partition = "h3_p3")
  write_user_table(s$st, d$y, mode = "update", partition = "h3_p3")
  rows <- stored_rows(s$st$primary, "t/plain")
  rows <- rows[order(rows$id), ]
  # the update replaces the partition 831e5cfffffffff entirely: ids 4-5 by 6-7
  expect_identical(rows$id, c(1:3, 6:7))
  expect_type(rows$h3_p3, "character")
  expect_identical(rows$h3_p3, c(d$x$h3_p3[1:3], d$y$h3_p3))
  entry <- dataset_entry(s$st, "t/plain")
  expect_identical(entry$partition[[1]], "h3_p3")
  expect_identical(entry$partition_auto, FALSE)
  expect_store_valid(s$st)
})

test_that("a table with a character user h3_p3 updates without partition", {
  # A-T2. Red: the update aborts with "`partition = \"h3\"` needs geocoded
  # geospatial data".
  s <- local_store()
  d <- user_h3_table()
  write_user_table(s$st, d$x, partition = "h3_p3")
  write_user_table(s$st, d$y, mode = "update")
  rows <- stored_rows(s$st$primary, "t/plain")
  rows <- rows[order(rows$id), ]
  # the update replaces the partition 831e5cfffffffff entirely: ids 4-5 by 6-7
  expect_identical(rows$id, c(1:3, 6:7))
  expect_type(rows$h3_p3, "character")
  expect_identical(rows$h3_p3, c(d$x$h3_p3[1:3], d$y$h3_p3))
  entry <- dataset_entry(s$st, "t/plain")
  expect_identical(entry$partition[[1]], "h3_p3")
  expect_identical(entry$partition_auto, FALSE)
  expect_store_valid(s$st)
})

test_that("sf with a character user h3_p3 updates with partition = \"h3_p3\" and keeps every value", {
  # A-T3 (a). Red: the update aborts with "Stored partition: h3".
  skip_if_no_h3()
  s <- local_store()
  d <- user_h3_points()
  write_user_points(s$st, d$create, partition = "h3_p3")
  write_user_points(s$st, d$update, mode = "update", partition = "h3_p3")
  expect_user_points_kept(s$st, d)
  expect_store_valid(s$st)
})

test_that("sf with a character user h3_p3 updates without partition and keeps every value", {
  # A-T3 (b). Red: the update aborts with "The column h3_p3 of `x` differs from
  # the partition column the write computes".
  skip_if_no_h3()
  s <- local_store()
  d <- user_h3_points()
  write_user_points(s$st, d$create, partition = "h3_p3")
  write_user_points(s$st, d$update, mode = "update")
  expect_user_points_kept(s$st, d)
  expect_store_valid(s$st)
})

test_that("sf with an rcs_h3 user h3_p3 updates with partition = \"h3_p3\" and keeps every value", {
  # A-T4 (a). Red: the update aborts with "Stored partition: h3".
  skip_if_no_h3()
  s <- local_store()
  d <- user_h3_points(cells = TRUE)
  write_user_points(s$st, d$create, partition = "h3_p3")
  write_user_points(s$st, d$update, mode = "update", partition = "h3_p3")
  expect_user_points_kept(s$st, d)
  expect_store_valid(s$st)
})

test_that("sf with an rcs_h3 user h3_p3 updates without partition and keeps every value", {
  # A-T4 (b). Red: the update aborts with "The column h3_p3 of `x` differs from
  # the partition column the write computes".
  skip_if_no_h3()
  s <- local_store()
  d <- user_h3_points(cells = TRUE)
  write_user_points(s$st, d$create, partition = "h3_p3")
  write_user_points(s$st, d$update, mode = "update")
  expect_user_points_kept(s$st, d)
  expect_store_valid(s$st)
})

write_auto_points <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "points/auto",
    title = "Points", description = "Automatic h3 partition.",
    key = if (mode != "update") "id", mode = mode, ...
  ))
}

test_that("sf with partition = \"h3\" updates with and without partition as before", {
  # A-T5. Guard: passes before plan 0004.
  skip_if_no_h3()
  s <- local_store()
  x <- rcs_sim_points(60, seed = 4)
  write_auto_points(s$st, x, partition = "h3", max_files = 10)
  partition <- dataset_entry(s$st, "points/auto")$partition[[1]]
  expect_match(partition, "^h3_p[0-9]+$")
  res <- as.integer(sub("^h3_p", "", partition))
  # in the order of `rows` (geo_encode() reorders them)
  part_of <- function(rows) as.character(rcs_geo_add(rows, parents = res)[[partition]])
  # update 1, with partition = "h3": every row of the largest partition
  first <- names(sort(table(part_of(x)), decreasing = TRUE))[[1]]
  y <- x[part_of(x) == first, ]
  y$value <- y$value + 1
  # update 2, without partition: new points, new ids
  z <- rcs_sim_points(10, seed = 9)
  z$id <- z$id + 100L
  local_snapshot_output()
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(
    store_write(s$st, y, "points/auto", title = "Points", description = "Automatic h3 partition.",
      mode = "update", partition = "h3", max_files = 10
    ),
    transform = scrub(s$root)
  )
  expect_snapshot(
    store_write(s$st, z, "points/auto", title = "Points", description = "Automatic h3 partition.",
      mode = "update", max_files = 10
    ),
    transform = scrub(s$root)
  )
  expect_identical(dataset_entry(s$st, "points/auto")$partition[[1]], partition)
  after_y <- rbind(x[part_of(x) != first, ], y)
  all_rows <- rbind(after_y[!part_of(after_y) %in% part_of(z), ], z)
  parents <- vctrs::vec_unique(h3_parent(geo_encode(all_rows, 5L)$data$h3, res))
  pv <- vapply(seq_along(parents), function(i) {
    partition_values_json(rlang::set_names(list(parents[i]), partition))
  }, character(1))
  expect_setequal(s$st$primary$files$partition_values[s$st$primary$files$dataset == "points/auto"], pv)
  stored <- stored_rows(s$st$primary, "points/auto")
  expect_setequal(stored$id, all_rows$id)
  expect_identical(stored$value[order(stored$id)], all_rows$value[order(all_rows$id)])
  expect_store_valid(s$st)
})

test_that("partition = \"h3\" is recorded as partition_auto = TRUE on create and update", {
  # A-T5, red part. Red: the catalog has no column `partition_auto`.
  skip_if_no_h3()
  s <- local_store()
  x <- rcs_sim_points(60, seed = 4)
  write_auto_points(s$st, x[1:40, ], partition = "h3", max_files = 10)
  expect_identical(dataset_entry(s$st, "points/auto")$partition_auto, TRUE)
  write_auto_points(s$st, x[41:50, ], mode = "update", partition = "h3", max_files = 10)
  expect_identical(dataset_entry(s$st, "points/auto")$partition_auto, TRUE)
  write_auto_points(s$st, x[51:60, ], mode = "update", max_files = 10)
  expect_identical(dataset_entry(s$st, "points/auto")$partition_auto, TRUE)
})

# A-T6 (guard): an update of partition = "h3" beyond max_files re-partitions to
# a coarser resolution. Covered by the test "an update of partition = \"h3\"
# beyond max_files re-partitions the dataset" in the section Geospatial below.

test_that("an update whose partition differs from the stored kind aborts naming the stored partition", {
  # A-T7. Red: the automatic case aborts today with "Stored partition: h3"
  # without "written as"; the user case passes the comparison and aborts later
  # with class `rcs_error_prepared` ("differs from the partition column the
  # write computes"), not `rcs_error_argument`.
  skip_if_no_h3()
  s <- local_store()
  x <- rcs_sim_points(40, seed = 1)
  suppressMessages(store_write(s$st, x, "points/auto",
    title = "Points", description = "Automatic partition.", key = "id", partition = "h3"
  ))
  written <- dataset_entry(s$st, "points/auto")$partition[[1]]
  expect_identical(written, "h3_p5")
  err <- expect_error(
    store_write(s$st, x[1:5, ], "points/auto", title = "Points", description = "Automatic partition.",
      mode = "update", partition = written
    ),
    class = "rcs_error_argument"
  )
  expect_match(cli::ansi_strip(conditionMessage(err)), paste0("written as [`\"]?", written))
  d <- user_h3_points()
  write_user_points(s$st, d$create, partition = "h3_p3")
  err <- expect_error(
    write_user_points(s$st, d$update, mode = "update", partition = "h3"),
    class = "rcs_error_argument"
  )
  expect_match(cli::ansi_strip(conditionMessage(err)), "h3_p3", fixed = TRUE)
  local_snapshot_output()
  expect_snapshot(error = TRUE, {
    store_write(s$st, x[1:5, ], "points/auto", title = "Points", description = "Automatic partition.",
      mode = "update", partition = "h3_p5"
    )
    store_write(s$st, d$update, "points/user", title = "Points", description = "User h3_p3 partition.",
      mode = "update", partition = "h3"
    )
  })
})

test_that("format_partition() shows a character h3_p<r> value as it is and a cell as hex", {
  # A-T9. Red: the character value gives "h3_p3 = NA" and the warning "NAs
  # introduced by coercion to integer64 range".
  expect_no_warning(shown <- format_partition('{"h3_p3":"831e5afffffffff"}'))
  expect_identical(shown, "h3_p3 = 831e5afffffffff")
  # an automatic integer64 cell, written as a string of digits
  cell <- partition_values_json(list(h3_p3 = h3_as_int64("835658fffffffff")))
  expect_identical(format_partition(cell), "h3_p3 = 835658fffffffff")
  expect_identical(format_partition('{"year":2024}'), "year = 2024")
})

test_that("the update message of a character user h3_p3 shows the values as given", {
  # A-T9, message. Red: the update aborts with "Stored partition: h3".
  s <- local_store()
  d <- user_h3_table()
  write_user_table(s$st, d$x, partition = "h3_p3")
  local_snapshot_output()
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(
    store_write(s$st, d$y, "t/plain", title = "Plain", description = "User h3_p3 partition.",
      mode = "update", partition = "h3_p3"
    ),
    transform = scrub(s$root)
  )
})

# Catalog entries for `partition_is_auto()`, one per case of D-A2, written for
# real so that `spec` is what the write stores.
partition_cases <- function(st) {
  tab <- user_h3_table()$x
  tab_cells <- tab
  tab_cells$h3_p3 <- h3_as_int64(tab_cells$h3_p3)
  d <- user_h3_points()
  cells <- user_h3_points(cells = TRUE)$create
  pts <- rcs_sim_points(40, seed = 1)
  w <- function(x, dataset, ...) {
    suppressMessages(store_write(st, x, dataset, title = "t", description = "d", ...))
  }
  w(tab, "tab/char", key = "id", partition = "h3_p3")
  w(tab_cells, "tab/cells", key = "id", partition = "h3_p3")
  w(tab, "tab/none", key = "id")
  w(pts, "sf/auto", key = "id", partition = "h3")
  w(cells, "sf/cells", key = "id", partition = "h3_p3")
  w(d$create, "sf/char", key = "id", partition = "h3_p3")
  w(pts, "sf/cat", key = "id", partition = "cat")
  w(cells, "sf/two", key = "id", partition = c("cat", "h3_p3"))
  w(pts, "sf/none", key = "id")
  function(dataset, auto = NA) {
    entry <- dataset_entry(st, dataset)
    entry$partition_auto <- auto
    list(entry = entry, spec = columns_from_json(entry$columns))
  }
}

test_that("partition_is_auto() resolves every case of D-A2", {
  # A-T10. Red: could not find function "partition_is_auto".
  skip_if_no_h3()
  s <- local_store()
  case <- partition_cases(s$st)
  is_auto <- function(dataset, auto = NA) {
    one <- case(dataset, auto)
    partition_is_auto(one$entry, one$spec)
  }
  # a recorded flag is used as it is
  expect_identical(is_auto("sf/cells", TRUE), TRUE)
  expect_identical(is_auto("sf/auto", FALSE), FALSE)
  expect_identical(is_auto("tab/char", FALSE), FALSE)
  # legacy (NA), no partition
  expect_identical(is_auto("tab/none"), NA)
  expect_identical(is_auto("sf/none"), NA)
  # legacy, a table: never automatic
  expect_identical(is_auto("tab/char"), FALSE)
  expect_identical(is_auto("tab/cells"), FALSE)
  # legacy, geospatial: automatic only for one h3_p<r> column of cells
  expect_identical(is_auto("sf/auto"), TRUE)
  expect_identical(is_auto("sf/cells"), TRUE)
  expect_identical(is_auto("sf/char"), FALSE)
  expect_identical(is_auto("sf/cat"), FALSE)
  expect_identical(is_auto("sf/two"), FALSE)
})

test_that("an update of a user h3_p3 beyond max_files aborts as for any user column and keeps the files", {
  # D-A4. Red: with `partition = "h3_p3"` the update aborts with "Stored
  # partition: h3" (right class, wrong message); without it, with class
  # `rcs_error_prepared` ("differs from the partition column the write
  # computes"). The expected abort is the one of any user column, as for
  # `year`: "Partitioning by h3_p3 would give N files, more than `max_files`".
  skip_if_no_h3()
  for (cells in c(FALSE, TRUE)) {
    for (given in list("h3_p3", NULL)) {
      local({
        s <- local_store()
        d <- user_h3_points(cells = cells)
        n_create <- length(vctrs::vec_unique(d$create$h3_p3))
        write_user_points(s$st, d$create, partition = "h3_p3", max_files = n_create)
        files_before <- s$st$primary$files[s$st$primary$files$dataset == "points/user", ]
        label <- paste0("cells = ", cells, ", partition = ", if (is.null(given)) "NULL" else given)
        err <- expect_error(
          write_user_points(s$st, d$update, mode = "update", partition = given, max_files = n_create),
          class = "rcs_error_argument", label = label
        )
        expect_match(
          cli::ansi_strip(conditionMessage(err)),
          "Partitioning by h3_p3 would give [0-9]+ files, more than `max_files`",
          label = label
        )
        expect_identical(dataset_entry(s$st, "points/user")$partition[[1]], "h3_p3", label = label)
        files_after <- s$st$primary$files[s$st$primary$files$dataset == "points/user", ]
        expect_identical(files_after$path, files_before$path, label = label)
        expect_identical(files_after$partition_values, files_before$partition_values, label = label)
      })
    }
  }
})

test_that("create records partition_auto: NA without partition, FALSE for user columns, TRUE for \"h3\"", {
  # D-A1, D-A5. Red: the catalog has no column `partition_auto`.
  skip_if_no_h3()
  s <- local_store()
  # (a) no partition
  suppressMessages(store_write(s$st, sales_data(30), "flag/none", title = "t", description = "d"))
  expect_identical(dataset_entry(s$st, "flag/none")$partition_auto, NA)
  # (b) a user column that is not h3_p<r>
  suppressMessages(store_write(s$st, sales_data(30), "flag/year",
    title = "t", description = "d", key = sales_key, partition = "year"
  ))
  expect_identical(dataset_entry(s$st, "flag/year")$partition_auto, FALSE)
  # (c) sf with partition = "h3_p3" whose values all equal the computed parents
  x <- rcs_sim_points(40, seed = 1)
  x$h3_p3 <- rcs_geo_add(x, parents = 3L)$h3_p3
  suppressMessages(store_write(s$st, x, "flag/equal",
    title = "t", description = "d", key = "id", partition = "h3_p3"
  ))
  expect_identical(dataset_entry(s$st, "flag/equal")$partition[[1]], "h3_p3")
  expect_identical(dataset_entry(s$st, "flag/equal")$partition_auto, FALSE)
})

test_that("an index table partitioned by h3 records partition_auto = TRUE", {
  # D-A1. Red: the catalog has no column `partition_auto`.
  # stage_index() partitions the index table with partition = "h3" when it
  # has more than `rows_per_group * 100` rows: 150 polygons give about 370
  # index rows, so rows_per_group = 1 makes it partitioned. The DuckDB
  # stager duckdb_stage_index() is not covered here (test-write-duckdb-geo.R
  # is outside WP1's files).
  skip_if_no_h3()
  s <- local_store()
  pol <- rcs_sim_polygons(150, seed = 1)
  suppressMessages(store_write(s$st, pol, "shapes/indexed",
    title = "t", description = "d", key = "id", rows_per_group = 1L
  ))
  index <- dataset_entry(s$st, "shapes/indexed__h3")
  expect_identical(index$index_of, "shapes/indexed")
  expect_match(index$partition[[1]], "^h3_p[0-9]+$")
  expect_identical(index$partition_auto, TRUE)
  expect_identical(dataset_entry(s$st, "shapes/indexed")$partition_auto, NA)
})

# Geospatial --------------------------------------------------------------------

test_that("geospatial data are written with their index table, replaced and stripped of it", {
  skip_below_level("default")
  skip_if_no_h3()
  s <- local_store(secondaries = 1L)
  pol <- rcs_sim_polygons(40, seed = 1)
  suppressMessages(store_write(s$st, pol, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", partition = "h3", max_files = 4
  ))
  expect_store_valid(s$st)
  catalog <- s$st$primary$catalog
  expect_setequal(catalog$dataset, c("shapes/polygons", "shapes/polygons__h3"))
  expect_identical(catalog$index_of[catalog$dataset == "shapes/polygons__h3"], "shapes/polygons")
  rows <- stored_rows(s$st$primary, "shapes/polygons")
  decoded <- geo_decode(rows, catalog$crs[catalog$dataset == "shapes/polygons"])
  decoded <- decoded[order(decoded$id), ]
  original <- pol[order(pol$id), ]
  expect_identical(decoded$area, original$area)
  expect_identical(
    lapply(sf::st_as_binary(sf::st_geometry(decoded), EWKB = FALSE), as.raw),
    lapply(sf::st_as_binary(sf::st_geometry(original), EWKB = FALSE), as.raw)
  )
  expect_identical(sort(as.numeric(rows$.rcs_id)), as.numeric(seq_len(40)))

  suppressMessages(store_write(s$st, pol, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", geocode = FALSE, mode = "replace"
  ))
  expect_store_valid(s$st)
  expect_identical(s$st$primary$catalog$dataset, "shapes/polygons")
  expect_identical(s$st$secondary[[1]]$catalog$dataset, "shapes/polygons")
  expect_true(is.na(s$st$primary$catalog$h3_res))

  suppressMessages(store_write(s$st, sf::st_drop_geometry(pol), "shapes/polygons",
    title = "Polygons", description = "Now a table.", mode = "replace"
  ))
  expect_identical(s$st$primary$catalog$kind, "table")
  expect_store_valid(s$st)
})

test_that("an update of partition = \"h3\" beyond max_files re-partitions the dataset", {
  skip_below_level("default")
  skip_if_no_h3()
  s <- local_store()
  pol <- rcs_sim_polygons(60, seed = 1)
  enc <- geo_encode(pol, 5L)
  parent <- as.character(h3_parent(enc$data$h3, 1L))
  first <- names(sort(table(parent), decreasing = TRUE))[[1]]
  a <- pol[pol$id %in% enc$data$id[parent %in% first], ]
  b <- pol[!pol$id %in% a$id, ]
  suppressMessages(store_write(s$st, a, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", key = "id",
    partition = "h3", max_files = 3
  ))
  expect_identical(s$st$primary$catalog$partition[[1]], "h3_p2")
  max_id <- max(as.numeric(stored_rows(s$st$primary, "shapes/polygons")$.rcs_id))
  local_snapshot_output()
  expect_snapshot(
    store_write(s$st, b, "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", max_files = 3
    ),
    transform = scrub(s$root)
  )
  entry <- s$st$primary$catalog[s$st$primary$catalog$dataset == "shapes/polygons", ]
  expect_identical(entry$partition[[1]], "h3_p0")
  expect_identical(as.numeric(entry$rows), 60)
  expect_store_valid(s$st)
  rows <- stored_rows(s$st$primary, "shapes/polygons")
  expect_setequal(rows$id, pol$id)
  expect_false(anyDuplicated(as.numeric(rows$.rcs_id)) > 0)
  expect_true(all(as.numeric(rows$.rcs_id[rows$id %in% b$id]) > max_id))
})

test_that("a re-partitioning update that replaces every old file keeps the new rows", {
  skip_if_no_h3()
  s <- local_store()
  old <- rcs_sim_points(40)
  new <- rcs_sim_points(200, seed = 2)
  write_points <- function(x, ...) {
    suppressMessages(store_write(s$st, x, "points/sites",
      title = "Points", description = "Simulated points.", ...
    ))
  }
  write_points(old, partition = "h3", max_files = 10)
  old_pv <- s$st$primary$files$partition_values
  res_old <- as.integer(sub("^h3_p", "", s$st$primary$catalog$partition[[1]]))
  parents <- vctrs::vec_unique(h3_parent(geo_encode(new, 5L)$data$h3, res_old))
  new_pv <- vapply(seq_along(parents), function(i) partition_values_json(rlang::set_names(list(parents[i]), paste0("h3_p", res_old))), character(1))
  # the precondition of the bug: every old partition is replaced
  expect_true(all(old_pv %in% new_pv))

  write_points(new, mode = "update", max_files = 3)
  expect_store_valid(s$st)
  expect_identical(as.numeric(s$st$primary$catalog$rows), 200)
  rows <- stored_rows(s$st$primary, "points/sites")
  # the union of the kept rows (none) and the new rows
  row_text <- function(id, value, wkb) {
    paste(id, value, vapply(wkb, function(g) paste(as.character(g), collapse = ""), character(1)))
  }
  new_wkb <- unclass(sf::st_as_binary(sf::st_geometry(new), EWKB = FALSE))
  expect_setequal(
    row_text(rows$id, rows$value, rows$geometry),
    row_text(new$id, new$value, new_wkb)
  )
})

# Geocoding engines (plan 0002, D30, D32) ----------------------------------------

write_shapes <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", mode = mode, ...
  ))
}

# Evaluates `expr` and returns the warnings of class `rcs_warning_s2_rebuild`.
rebuild_warnings <- function(expr) {
  out <- list()
  withCallingHandlers(expr, rcs_warning_s2_rebuild = function(w) {
    out[[length(out) + 1L]] <<- w
    invokeRestart("muffleWarning")
  })
  out
}

shapes_entry <- function(st) {
  catalog <- st$primary$catalog
  catalog[catalog$dataset == "shapes/polygons", ]
}

# Records the `geocode_engine` of every `geo_encode()` call into `log`.
local_engine_log <- function(log, frame = parent.frame()) {
  real <- geo_encode
  testthat::local_mocked_bindings(
    geo_encode = function(x, ..., geocode_engine = "auto") {
      log$engines <- c(log$engines, geocode_engine)
      real(x, ..., geocode_engine = geocode_engine)
    },
    .package = "rcs", .env = frame
  )
}

# `n_valid` simulated polygons, then the two polygons of fact 18 repeated 25
# times each, shifted by whole degrees of longitude inside the simulation
# box; `id` numbers the rows.
geo_with_invalid_repeated <- function(n_valid) {
  valid <- sf::st_geometry(rcs_sim_polygons(n_valid, seed = 7))
  invalid <- geo_sfc_of_wkt(geo_invalid_wkt())
  shifts <- rep(-2:2, each = 5)
  copies <- lapply(c(1, 2), function(j) {
    do.call(c, lapply(shifts, function(k) invalid[j] + c(k, 0)))
  })
  geometry <- c(valid, sf::st_set_crs(c(copies[[1]], copies[[2]]), 4326))
  sf::st_sf(id = seq_along(geometry), geometry = geometry)
}

# Rewrites `_catalog.parquet` of a location folder with `geocode_engine` set
# to NA, as for a dataset written before plan 0002.
clear_catalog_engine <- function(root) {
  path <- file.path(root, "_catalog.parquet")
  catalog <- arrow::read_parquet(readBin(path, "raw", file.size(path)), as_data_frame = FALSE)
  catalog$geocode_engine <- arrow::Array$create(rep(NA_character_, catalog$num_rows), arrow::utf8())
  arrow::write_parquet(catalog, path, compression = "zstd")
}

test_that("geocode_engine is checked and stored; NA for tables and geocode = FALSE", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  expect_snapshot(error = TRUE, {
    store_write(s$st, x, "shapes/polygons", title = "t", description = "d", geocode_engine = "sphere")
  })
  expect_identical(nrow(s$st$primary$catalog), 0L)
  rebuild_warnings(write_shapes(s$st, x, geocode_engine = "s2"))
  expect_identical(shapes_entry(s$st)$geocode_engine, "s2")
  expect_length(rebuild_warnings(write_shapes(s$st, x, mode = "replace", geocode = FALSE)), 0L)
  expect_identical(shapes_entry(s$st)$geocode_engine, NA_character_)
  write_sales(s$st, sales_data(20), geocode_engine = "planar")
  catalog <- s$st$primary$catalog
  expect_identical(catalog$geocode_engine[catalog$dataset == "sales/daily"], NA_character_)
  expect_store_valid(s$st)
})

test_that("store_check() passes for keyless sf datasets written with each engine", {
  skip_below_level("default")
  skip_if_no_h3()
  x <- geo_with_invalid()
  for (engine in c("auto", "s2", "planar")) local({
    s <- local_store()
    warnings <- rebuild_warnings(
      write_shapes(s$st, x, partition = "h3", max_files = 4, geocode_engine = engine)
    )
    expect_identical(shapes_entry(s$st)$geocode_engine, engine)
    if (engine != "planar") {
      expect_length(warnings, 1L)
      expect_match(conditionMessage(warnings[[1]]), ".rcs_id = ", fixed = TRUE)
    }
    log <- new.env()
    local_engine_log(log)
    checked <- suppressMessages(store_check(s$st, "shapes/polygons", x))
    expect_identical(log$engines, engine)
    expect_true(all(checked$status == "ok"), label = engine)
    expect_store_valid(s$st)
  })
})

test_that("10,000 rows with 50 sphere-invalid polygons: one partition each, shares sum to 1, keys named", {
  skip_below_level("default")
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid_repeated(10000)
  invalid_ids <- 10000L + seq_len(50)
  warnings <- rebuild_warnings(write_shapes(s$st, x, key = "id", partition = "h3"))
  expect_length(warnings, 1L)
  message <- cli::ansi_strip(conditionMessage(warnings[[1]]))
  for (id in invalid_ids[1:5]) {
    expect_match(message, paste0("id = ", id, "\\b"))
  }
  expect_no_match(message, paste0("id = ", invalid_ids[[6]], "\\b"))
  expect_match(message, "\\b50\\b")

  expect_identical(shapes_entry(s$st)$geocode_engine, "auto")
  files <- s$st$primary$files[s$st$primary$files$dataset == "shapes/polygons", ]
  rows <- vctrs::vec_rbind(!!!lapply(files$path, function(p) {
    read_stored(s$st$primary$backend, p, c("id", ".rcs_id", "h3"))
  }))
  expect_identical(nrow(rows), nrow(x))
  expect_false(anyDuplicated(rows$id) > 0)
  expect_setequal(rows$id, x$id)
  empty <- x$id[sf::st_is_empty(x)]
  expect_identical(sort(rows$id[is.na(rows$h3)]), sort(empty))
  expect_true(all(invalid_ids %in% rows$id[!is.na(rows$h3)]))

  index_paths <- s$st$primary$files$path[s$st$primary$files$dataset == "shapes/polygons__h3"]
  index <- vctrs::vec_rbind(!!!lapply(index_paths, function(p) read_stored(s$st$primary$backend, p)))
  sums <- tapply(index$share, as.character(index$.rcs_id), sum)
  expect_true(all(abs(sums - 1) < 1e-6))
  invalid_rcs_ids <- as.character(rows$.rcs_id[rows$id %in% invalid_ids])
  expect_true(all(invalid_rcs_ids %in% names(sums)))

  checked <- suppressMessages(store_check(s$st, "shapes/polygons", x))
  expect_true(all(checked$status == "ok"))
  expect_store_valid(s$st)
})

test_that("the same data written twice give the same version, with the warning both times", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  warnings <- rebuild_warnings(write_shapes(s$st, x, key = "id", partition = "h3", max_files = 4))
  v <- shapes_entry(s$st)$version
  warnings <- c(warnings, rebuild_warnings(
    out <- write_shapes(s$st, x, mode = "replace", key = "id", partition = "h3", max_files = 4)
  ))
  expect_length(warnings, 2L)
  expect_identical(attr(out, "version"), v)
  expect_identical(out$status, "unchanged")
})

test_that("update geocodes with the stored engine; another explicit engine aborts", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  rebuild_warnings(write_shapes(s$st, x[1:15, ], key = "id", partition = "h3", max_files = 20, geocode_engine = "s2"))
  expect_snapshot(error = TRUE, {
    store_write(s$st, x[16:22, ], "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", geocode_engine = "auto"
    )
  })
  log <- new.env()
  local_engine_log(log)
  warnings <- rebuild_warnings(write_shapes(s$st, x[16:22, ], mode = "update", geocode_engine = "s2"))
  expect_length(warnings, 1L)
  rebuild_warnings(write_shapes(s$st, x[16:22, ], mode = "update"))
  expect_identical(log$engines, c("s2", "s2"))
  expect_identical(shapes_entry(s$st)$geocode_engine, "s2")
  expect_store_valid(s$st)
})

test_that("update of a dataset without engine geocodes new rows with s2; an explicit engine aborts", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  write_shapes(s$st, x[1:15, ], key = "id", partition = "h3", max_files = 20, geocode_engine = "planar")
  clear_catalog_engine(s$paths[[1]])
  st <- store_connect(s$paths[[1]])
  expect_identical(shapes_entry(st)$geocode_engine, NA_character_)
  expect_snapshot(error = TRUE, {
    store_write(st, x[16:22, ], "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", geocode_engine = "s2"
    )
  })
  log <- new.env()
  local_engine_log(log)
  warnings <- rebuild_warnings(write_shapes(st, x[16:22, ], mode = "update"))
  expect_length(warnings, 1L)
  expect_identical(log$engines, "s2")
  expect_identical(shapes_entry(st)$geocode_engine, NA_character_)
  expect_store_valid(st)
})

test_that("an explicit engine on update of a geocode = FALSE dataset aborts without naming s2", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  x$grp <- rep(c("a", "b"), length.out = nrow(x))
  write_shapes(s$st, x[1:15, ], key = "id", partition = "grp", geocode = FALSE)
  expect_snapshot(error = TRUE, {
    store_write(s$st, x[16:22, ], "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", mode = "update", geocode_engine = "s2"
    )
  })
})

test_that("the rebuild warning is signalled with warn >= 1, so it shows at once", {
  skip_if_no_h3()
  x <- geo_with_invalid()
  warn_seen <- function(warn) {
    s <- local_store()
    withr::local_options(warn = warn)
    seen <- NULL
    withCallingHandlers(
      write_shapes(s$st, x, key = "id"),
      rcs_warning_s2_rebuild = function(w) {
        seen <<- as.integer(getOption("warn"))
        invokeRestart("muffleWarning")
      }
    )
    seen
  }
  expect_identical(warn_seen(0), 1L)
  expect_identical(warn_seen(-1), 1L)
  expect_identical(warn_seen(1), 1L)
  expect_identical(warn_seen(2), 2L)
  s <- local_store()
  withr::local_options(warn = 2)
  expect_error(write_shapes(s$st, x, key = "id"), "invalid on the sphere")
})

test_that("the rebuild warning names rebuilt rows and fallbacks, before the upload lines", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  local_snapshot_output()
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(
    store_write(s$st, x, "shapes/polygons", title = "Polygons",
      description = "Simulated polygons.", key = "id"
    ),
    transform = scrub(s$root)
  )
  # An empty rebuild fails the check of "auto": both rows fall back.
  local_mocked_bindings(geo_rebuild = function(geog) {
    s2::as_s2_geography(rep("GEOMETRYCOLLECTION EMPTY", length(geog)))
  })
  expect_snapshot(
    store_write(s$st, x, "shapes/keyless", title = "Polygons",
      description = "Simulated polygons."
    ),
    transform = scrub(s$root)
  )
})

test_that("a rebuilt row is found by a read of its cell", {
  skip_if_no_h3()
  s <- local_store()
  x <- geo_with_invalid()
  rebuild_warnings(write_shapes(s$st, x, key = "id", partition = "h3", max_files = 4))
  rows <- stored_rows(s$st$primary, "shapes/polygons")
  # The stored geometries stay invalid on the sphere, so the exact test is
  # planar here (the exact engine of a dataset is work package N2).
  local_s2(FALSE)
  for (id in c(21L, 22L)) {
    cell <- rows$h3[rows$id == id]
    got <- store_read(s$st, "shapes/polygons", intersects = cell)
    expect_true(id %in% got$id, label = paste("row", id))
  }
})

# Rasters -----------------------------------------------------------------------

test_that("a raster is written, replaced, and cannot be updated", {
  skip_below_level("default")
  skip_if_not_installed("terra")
  s <- local_store(secondaries = 1L)
  r <- rcs_sim_raster(seed = 1, nrow = 40, ncol = 40)
  suppressMessages(store_write(s$st, r, "grid", title = "Grid", description = "Simulated raster."))
  expect_store_valid(s$st)
  expect_identical(s$st$primary$catalog$kind, "raster")
  v <- s$st$primary$catalog$version
  # A new title with the same cells changes the entry, not the version.
  suppressMessages(store_write(s$st, r, "grid", title = "Grid 2", description = "Simulated raster.", mode = "replace"))
  expect_identical(s$st$primary$catalog$version, v)
  expect_identical(s$st$primary$catalog$title, "Grid 2")
  expect_identical(s$st$secondary[[1]]$catalog$title, "Grid 2")
  expect_store_valid(s$st)
  stored <- terra::rast(file.path(s$paths[[1]], s$st$primary$files$path))
  expect_equal(terra::values(stored), terra::values(r), ignore_attr = TRUE)
  expect_snapshot(error = TRUE, {
    store_write(s$st, r, "grid", title = "Grid", description = "d", mode = "update")
    store_write(s$st, r, "grid2", title = "Grid", description = "d", partition = "x")
  })
})

# Plan 0006: types, nodata, options, legend, staging

test_that("a class map is written with its type, nodata and legend in every manifest", {
  # A-T17. Red: unused argument `nodata` of `store_write()`.
  skip_below_level("default")
  skip_if_not_installed("terra")
  s <- local_store(secondaries = 1L)
  x <- sim_landcover(nrow = 12, ncol = 16, file = withr::local_tempfile(fileext = ".tif"), legend = TRUE)
  write <- function(...) {
    suppressMessages(store_write(
      s$st, x, "grids/cover",
      title = "Cover", description = "Simulated class map.", nodata = 0, ...
    ))
  }
  first <- write()
  expect_identical(first$uploaded, c(1, 1))
  expect_store_valid(s$st)
  version <- s$st$primary$catalog$version
  expect_identical(s$st$secondary[[1]]$catalog$version, version)

  # the manifest, as it is on disk in every location
  for (root in s$paths) {
    manifest <- jsonlite::fromJSON(
      file.path(root, manifest_path("grids/cover", version)),
      simplifyVector = FALSE
    )
    layers <- jsonlite::fromJSON(manifest$entry$columns, simplifyVector = FALSE)
    expect_length(layers, 1L)
    layer <- layers[[1]]
    expect_identical(layer$name, "cover")
    expect_identical(layer$type, "INT1U")
    expect_identical(layer$r_type$class, "SpatRaster")
    expect_equal(layer$r_type$nodata, 0)
    expect_equal(unlist(layer$r_type$resolution), terra::res(x))
    expect_equal(unlist(layer$r_type$dim), c(12, 16))
    expect_equal(unlist(layer$r_type$values), 1:5)
    expect_identical(unlist(layer$r_type$levels), sim_landcover_labels)
    expect_identical(layer$r_type$levels_name, "label")
    # the stored file holds codes, with the NoData tag, and no side file
    stored <- file.path(root, s$st$primary$files$path)
    info <- terra::describe(stored)
    expect_true(any(grepl("Type=Byte", info, fixed = TRUE)))
    expect_true(any(grepl("NoData Value=0", info, fixed = TRUE)))
    expect_identical(
      sort(list.files(file.path(root, "grids/cover"), all.files = TRUE, no.. = TRUE)),
      sort(basename(c(manifest_path("grids/cover", version), s$st$primary$files$path)))
    )
  }

  # the same map again uploads nothing
  second <- write(mode = "replace")
  expect_identical(second$uploaded, c(0, 0))
  expect_identical(s$st$primary$catalog$version, version)
  expect_store_valid(s$st)
})

test_that("datatype, nodata and gdal apply to rasters only", {
  # A-T17. Red: unused arguments of `store_write()` (an error without the
  # class `rcs_error_argument`).
  skip_below_level("default")
  s <- local_store()
  write <- function(...) {
    store_write(s$st, sales_data(), "sales/plain", title = "Sales", description = "Simulated sales.", ...)
  }
  expect_error(write(datatype = "INT1U"), class = "rcs_error_argument")
  expect_error(write(nodata = 0), class = "rcs_error_argument")
  expect_error(write(gdal = "COMPRESS=ZSTD"), class = "rcs_error_argument")
  expect_false("sales/plain" %in% s$st$primary$catalog$dataset)
  expect_snapshot(write(nodata = 0), error = TRUE)
})

# Failures ----------------------------------------------------------------------

test_that("a primary failing during upload changes no catalog; the repeated call sends only what is missing", {
  skip_below_level("default")
  local_no_wait()
  s <- local_store(secondaries = 1L)
  x <- sales_data()
  # The second data file fails three times in a row.
  stub <- local_backend_stub(uri = s$paths[[1]], generic = "be_put", path = "part-", fail_at = 2:4)
  st <- store_connect(s$paths[[1]], secondary = s$paths[[2]])
  token <- st$primary$token
  local_snapshot_output()
  expect_snapshot(write_sales(st, x), error = TRUE, transform = scrub(s$root))
  # Again: the first file is reused, the second fails three times.
  stub_reset(stub)
  stub$fail_at <- 1:3
  err <- tryCatch(write_sales(st, x), error = function(e) e)
  expect_identical(data_puts(stub), 3L)
  expect_s3_class(err, c("rcs_error_write"))
  expect_s3_class(err, c("rcs_error_stub"))
  expect_identical(catalog_token(st$primary$backend), token)
  expect_identical(nrow(st$primary$catalog), 0L)
  expect_identical(nrow(st$secondary[[1]]$catalog), 0L)
  expect_store_valid(st, orphans_ok = TRUE)

  stub$fail_at <- NULL
  stub_reset(stub)
  out <- write_sales(st, x)
  expect_identical(out$status, c("written", "written"))
  expect_identical(data_puts(stub), 1L)
  expect_store_valid(st)
})

test_that("a primary failing between _files.parquet and _catalog.parquet changes no catalog", {
  skip_below_level("default")
  local_no_wait()
  s <- local_store()
  stub <- local_backend_stub(uri = s$paths[[1]], generic = "be_put", path = "^_catalog\\.parquet$")
  st <- store_connect(s$paths[[1]])
  x <- sales_data()
  write_sales(st, x)
  v1 <- st$primary$catalog$version
  x$qty <- x$qty + 1L
  stub_reset(stub)
  stub$fail_at <- 1:3
  expect_error(write_sales(st, x, mode = "replace"), class = "rcs_error_stub")
  stored <- location_read(st$primary$backend)
  expect_identical(stored$catalog$version, v1)
  expect_true(all(stored$files$version == v1))
  expect_store_valid(st, orphans_ok = TRUE)

  stub$fail_at <- NULL
  stub$generic <- "be_put"
  stub$path <- "part-"
  stub_reset(stub)
  write_sales(st, x, mode = "replace")
  expect_identical(data_puts(stub), 0L)
  expect_false(identical(st$primary$catalog$version, v1))
  expect_store_valid(st)
})

test_that("a transient error on two attempts of one file is absorbed", {
  skip_below_level("default")
  local_no_wait()
  s <- local_store()
  stub <- local_backend_stub(uri = s$paths[[1]], generic = "be_put", path = "part-", fail_at = 1:2)
  st <- store_connect(s$paths[[1]])
  out <- write_sales(st, sales_data())
  expect_identical(out$status, "written")
  expect_identical(sum(stub$log$failed), 2L)
  expect_store_valid(st)
})

test_that("an upload that silently alters a file fails MD5 verification", {
  skip_below_level("default")
  local_no_wait()
  s <- local_store()
  stub <- local_backend_stub(uri = s$paths[[1]], generic = "be_put", path = "part-", fail_at = 1, mode = "corrupt")
  st <- store_connect(s$paths[[1]])
  local_snapshot_output()
  expect_snapshot(write_sales(st, sales_data()), error = TRUE, transform = scrub(s$root))
  expect_identical(nrow(st$primary$catalog), 0L)
  corrupted <- stub$log$path[stub$log$failed]
  expect_false(file.exists(file.path(s$paths[[1]], corrupted)))
  expect_store_valid(st, orphans_ok = TRUE)
})

test_that("a secondary failing mid-write warns and is reported behind", {
  skip_below_level("default")
  local_no_wait()
  s <- local_store(secondaries = 2L)
  stub <- local_backend_stub(uri = s$paths[[2]], generic = "be_put", path = "part-", fail_at = 1:3)
  st <- store_connect(s$paths[[1]], secondary = s$paths[-1])
  local_snapshot_output()
  expect_snapshot(
    out <- store_write(st, sales_data(), "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.",
      key = sales_key, partition = "year"
    ),
    transform = scrub(s$root)
  )
  expect_identical(out$status, c("written", "behind", "written"))
  status <- store_status(st)
  expect_identical(status$status, c("missing", "same"))
  expect_store_valid(st, orphans_ok = TRUE)
})

test_that("the write guard aborts when the catalog changed during the write", {
  skip_below_level("default")
  s <- local_store()
  write_sales(s$st, sales_data())
  original <- verify_md5
  touched <- FALSE
  # Another writer rewrites _catalog.parquet (same content, other bytes)
  # while this write uploads its files.
  testthat::local_mocked_bindings(verify_md5 = function(be, paths, md5) {
    if (!touched) {
      touched <<- TRUE
      catalog <- strip_md5_attr(catalog_read(be, "catalog"))
      arrow::write_parquet(schema_as_arrow(catalog, "catalog"), file.path(be$root, "_catalog.parquet"),
        compression = "uncompressed"
      )
    }
    original(be, paths, md5)
  })
  x <- sales_data(150, 2)
  v1 <- s$st$primary$catalog$version
  local_snapshot_output()
  expect_snapshot(write_sales(s$st, x, mode = "replace"), error = TRUE, transform = scrub(s$root))
  expect_identical(location_read(s$st$primary$backend)$catalog$version, v1)
  expect_store_valid(s$st, orphans_ok = TRUE)
  write_sales(s$st, x, mode = "replace")
  expect_store_valid(s$st)
})

test_that("a fresh local lock blocks a write; a stale one is taken over", {
  skip_below_level("default")
  s <- local_store()
  lock <- file.path(s$paths[[1]], "_lock")
  dir.create(lock)
  writeLines(time_to_text(now_utc()), file.path(lock, "time"))
  expect_error(write_sales(s$st, sales_data()), class = "rcs_error_locked")
  expect_identical(nrow(s$st$primary$catalog), 0L)
  expect_true(dir.exists(lock))

  writeLines("2000-01-01T00:00:00.000000Z", file.path(lock, "time"))
  expect_warning(write_sales(s$st, sales_data()), class = "rcs_warning_lock_stale")
  expect_false(dir.exists(lock))
  expect_store_valid(s$st)
})

test_that("the summary of a raster write counts cells, and of a geospatial write its index files", {
  skip_if_not_installed("terra")
  s <- local_store()
  withr::local_options(rcs.quiet = FALSE)
  messages_of <- function(expr) {
    out <- character()
    withCallingHandlers(expr, message = function(m) {
      out <<- c(out, conditionMessage(m))
      invokeRestart("muffleMessage")
    })
    cli::ansi_strip(out)
  }
  r <- rcs_sim_raster(seed = 1, nrow = 10, ncol = 10)
  messages <- messages_of(store_write(s$st, r, "grid", title = "Grid", description = "Simulated raster."))
  expect_true(any(grepl("100 cells in 1 file", messages, fixed = TRUE)))
  skip_if_no_h3()
  pol <- rcs_sim_polygons(40, seed = 1)
  messages <- messages_of(store_write(s$st, pol, "shapes/polygons", title = "Polygons", description = "d"))
  entry <- s$st$primary$catalog
  n_data <- as.numeric(entry$n_files[entry$dataset == "shapes/polygons"])
  n_index <- as.numeric(entry$n_files[entry$dataset == "shapes/polygons__h3"])
  expect_true(any(grepl(paste0("in ", n_data, " file.*index table in ", n_index, " file"), messages)))
  sent <- paste0(n_data + n_index, "/", n_data + n_index, " files sent")
  expect_true(any(grepl(sent, messages, fixed = TRUE)))
})

# Prepared data (D27) --------------------------------------------------------------

write_prepared <- function(st, x, mode = "create", ...) {
  suppressMessages(store_write(st, x, "shapes/prepared",
    title = "Prepared", description = "Simulated shapes.", mode = mode, ...
  ))
}

prepared_entry <- function(st) {
  catalog <- st$primary$catalog
  catalog[catalog$dataset == "shapes/prepared", ]
}

test_that("prepared data equal to the write's own columns are accepted, with the raw version", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_polygons(60, seed = 8)
  p <- local_store()
  write_prepared(p$st, raw, key = "id", partition = "h3", max_files = 4)
  prepared <- rcs_geo_add(raw)
  prepared$.rcs_id <- bit64::as.integer64(rev(seq_len(60)))
  write_prepared(s$st, prepared, key = "id", partition = "h3", max_files = 4)
  expect_identical(prepared_entry(s$st)$version, prepared_entry(p$st)$version)
  expect_identical(prepared_entry(s$st)$h3_res, 5L)
  # bbox alone, h3 alone, and integer64 instead of rcs_h3
  only_bbox <- rcs_geo_add(raw, h3_res = NULL)
  write_prepared(s$st, only_bbox, mode = "replace", key = "id", partition = "h3", max_files = 4)
  expect_identical(prepared_entry(s$st)$version, prepared_entry(p$st)$version)
  only_h3 <- rcs_geo_add(raw, bbox = FALSE)
  only_h3$h3 <- rcs_h3_strip(only_h3$h3)
  write_prepared(s$st, only_h3, mode = "replace", key = "id", partition = "h3", max_files = 4)
  expect_identical(prepared_entry(s$st)$version, prepared_entry(p$st)$version)
  expect_store_valid(s$st)
})

test_that("a store read of a geospatial dataset can be written again unchanged", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_points(50, seed = 3)
  write_shapes(s$st, raw, key = "id", partition = "h3", max_files = 4)
  back <- dplyr::collect(store_open(s$st, "shapes/polygons"))
  expect_true(all(c("h3", "bbox") %in% names(back)))
  out <- write_shapes(s$st, back, mode = "replace", key = "id", partition = "h3", max_files = 4)
  expect_identical(out$status[[1]], "unchanged")
})

test_that("tampered h3 or bbox abort naming the rows", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_points(40, seed = 2)
  prepared <- rcs_geo_add(raw)
  tampered <- prepared
  tampered$h3[c(4, 9)] <- tampered$h3[c(9, 4)]
  expect_false(identical(as.character(tampered$h3), as.character(prepared$h3)))
  err <- expect_error(write_prepared(s$st, tampered, key = "id"), class = "rcs_error_prepared")
  expect_match(conditionMessage(err), "id = 4", fixed = TRUE)
  expect_match(conditionMessage(err), "\"auto\"", fixed = TRUE)
  err <- expect_error(write_prepared(s$st, tampered), class = "rcs_error_prepared")
  expect_match(conditionMessage(err), "row 4", fixed = TRUE)
  moved <- prepared
  moved$bbox$ymax[7] <- moved$bbox$ymax[7] + 0.5
  err <- expect_error(write_prepared(s$st, moved, key = "id"), class = "rcs_error_prepared")
  expect_match(conditionMessage(err), "id = 7", fixed = TRUE)
  expect_identical(nrow(s$st$primary$catalog), 0L)
  local_snapshot_output()
  expect_snapshot(error = TRUE, {
    store_write(s$st, tampered, "shapes/prepared", title = "t", description = "d", key = "id")
  })
  expect_snapshot(error = TRUE, {
    store_write(s$st, moved, "shapes/prepared", title = "t", description = "d")
  })
})

test_that("cells prepared with another engine abort and name the write's engine", {
  skip_if_no_h3()
  s <- local_store()
  # a sliver along 60 degrees north: its long edges bow north on the sphere,
  # so its main cell at resolution 2 differs between the plane and the sphere
  sliver <- "POLYGON((-40 60, 0 60, 0 60.5, -40 60.5, -40 60))"
  x <- sf::st_sf(id = 1:2, geometry = geo_sfc_of_wkt(c(sliver, "POINT(-27 7)")))
  planar <- rcs_geo_add(x, h3_res = 2L, geocode_engine = "planar")
  sphere <- rcs_geo_add(x, h3_res = 2L, geocode_engine = "s2")
  expect_false(identical(as.character(planar$h3), as.character(sphere$h3)))
  err <- expect_error(write_prepared(s$st, planar, key = "id"), class = "rcs_error_prepared")
  expect_match(conditionMessage(err), "\"auto\"", fixed = TRUE)
  expect_match(conditionMessage(err), "geocode_engine", fixed = TRUE)
  write_prepared(s$st, planar, key = "id", geocode_engine = "planar")
  expect_identical(prepared_entry(s$st)$geocode_engine, "planar")
  local_snapshot_output()
  expect_snapshot(error = TRUE, {
    store_write(s$st, planar, "shapes/other", title = "t", description = "d", geocode_engine = "s2")
  })
})

test_that("h3_res is taken from the cells; mixed or other resolutions abort", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_points(30, seed = 5)
  write_prepared(s$st, rcs_geo_add(raw, h3_res = 7L), key = "id")
  expect_identical(prepared_entry(s$st)$h3_res, 7L)
  write_prepared(s$st, rcs_geo_add(raw, h3_res = 7L), mode = "replace", key = "id", h3_res = 7L)
  mixed <- rcs_geo_add(raw, h3_res = 7L)
  mixed$h3[1:3] <- rcs_geo_add(raw[1:3, ], h3_res = 6L)$h3
  expect_error(write_prepared(s$st, mixed, mode = "replace", key = "id"), class = "rcs_error_prepared")
  expect_error(
    write_prepared(s$st, rcs_geo_add(raw, h3_res = 7L), mode = "replace", key = "id", h3_res = 5L),
    class = "rcs_error_prepared"
  )
  expect_error(
    write_prepared(s$st, rcs_geo_add(raw, h3_res = 7L), mode = "replace", key = "id", geocode = FALSE),
    class = "rcs_error_prepared"
  )
  # bbox alone with geocode = FALSE is fine
  write_prepared(s$st, rcs_geo_add(raw, h3_res = NULL), mode = "replace", key = "id", geocode = FALSE)
  expect_true(is.na(prepared_entry(s$st)$h3_res))
  local_snapshot_output()
  prepared7 <- rcs_geo_add(raw, h3_res = 7L)
  expect_snapshot(error = TRUE, {
    store_write(s$st, mixed, "shapes/other", title = "t", description = "d")
  })
  expect_snapshot(error = TRUE, {
    store_write(s$st, prepared7, "shapes/other", title = "t", description = "d", h3_res = 5L)
  })
  expect_snapshot(error = TRUE, {
    store_write(s$st, prepared7, "shapes/other", title = "t", description = "d", geocode = FALSE)
  })
})

test_that("update handles prepared data the same way", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_points(60, seed = 6)
  write_prepared(s$st, rcs_geo_add(raw), key = "id", partition = "h3", max_files = 4)
  part <- raw[raw$id <= 10, ]
  part$value <- part$value + 1
  plain <- local_store()
  write_prepared(plain$st, raw, key = "id", partition = "h3", max_files = 4)
  write_prepared(plain$st, part, mode = "update")
  write_prepared(s$st, rcs_geo_add(part), mode = "update")
  expect_identical(prepared_entry(s$st)$version, prepared_entry(plain$st)$version)
  tampered <- rcs_geo_add(part)
  tampered$bbox$xmin[1] <- tampered$bbox$xmin[1] - 1
  expect_error(write_prepared(s$st, tampered, mode = "update"), class = "rcs_error_prepared")
  expect_error(write_prepared(s$st, rcs_geo_add(part, h3_res = 6L), mode = "update"), class = "rcs_error_prepared")
  # the stored partition column may come along when equal
  partition <- prepared_entry(s$st)$partition[[1]]
  r <- as.integer(sub("h3_p", "", partition))
  write_prepared(s$st, rcs_geo_add(part, parents = r), mode = "update")
  write_prepared(plain$st, part, mode = "update")
  expect_identical(prepared_entry(s$st)$version, prepared_entry(plain$st)$version)
  wrong <- rcs_geo_add(part, parents = r)
  wrong[[partition]][1] <- h3_parent(rcs_geo_add(sf::st_sf(geometry = geo_sfc_of_wkt("POINT(-10 50)")))$h3, r)
  expect_error(write_prepared(s$st, wrong, mode = "update"), class = "rcs_error_prepared")
  expect_store_valid(s$st)
})

test_that("h3_p<r> user columns are stored and read as rcs_h3", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_polygons(30, seed = 9)
  write_prepared(s$st, rcs_geo_add(raw, parents = c(3L, 1L)), key = "id")
  spec <- columns_from_json(prepared_entry(s$st)$columns)
  expect_identical(spec$r_type[[match("h3_p3", spec$name)]], list(class = "integer64"))
  back <- dplyr::collect(store_open(s$st, "shapes/prepared"))
  expect_s3_class(back$h3_p3, "rcs_h3")
  expect_s3_class(back$h3_p1, "rcs_h3")
  expect_identical(as.character(back$h3_p3), as.character(h3_parent(back$h3, 3L)))
})

test_that("with partition = \"h3\" an equal h3_p<r> serves as partition column, a different one aborts", {
  skip_if_no_h3()
  s <- local_store()
  raw <- rcs_sim_polygons(60, seed = 10)
  p <- local_store()
  write_prepared(p$st, raw, key = "id", partition = "h3", max_files = 4)
  partition <- prepared_entry(p$st)$partition[[1]]
  r <- as.integer(sub("h3_p", "", partition))
  prepared <- rcs_geo_add(raw, parents = r)
  write_prepared(s$st, prepared, key = "id", partition = "h3", max_files = 4)
  expect_identical(prepared_entry(s$st)$partition[[1]], partition)
  expect_identical(prepared_entry(s$st)$version, prepared_entry(p$st)$version)
  wrong <- prepared
  wrong[[partition]][1] <- h3_parent(rcs_geo_add(sf::st_sf(geometry = geo_sfc_of_wkt("POINT(-10 50)")))$h3, r)
  expect_error(
    write_prepared(s$st, wrong, mode = "replace", key = "id", partition = "h3", max_files = 4),
    partition, class = "rcs_error_prepared"
  )
})
