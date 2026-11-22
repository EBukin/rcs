# Staging of dataset versions as Parquet files, and reading row groups.

stage_table <- function(data, dataset = "sales/daily", ..., dir = withr::local_tempdir(.local_envir = parent.frame())) {
  files_stage(
    data, dataset,
    title = "Daily sales", description = "Simulated daily sales.",
    ..., dir = dir
  )
}

# Geospatial rows as `geo_encode()` returns them, built by hand: cells are
# made-up integer64 values grouped by a mocked `h3_parent()`.
fake_geo <- function(n = 12) {
  xy <- cbind(seq(-29.9, -24.1, length.out = n), seq(6.1, 8.9, length.out = n))
  geoms <- lapply(seq_len(n), function(i) sf::st_point(xy[i, ]))
  geoms[[n]] <- sf::st_point()
  h3 <- bit64::as.integer64(600000L + rep(c(11L, 12L, 21L, 22L), length.out = n))
  h3[n] <- bit64::NA_integer64_
  bbox <- bbox_df(xy[, 1], xy[, 2], xy[, 1], xy[, 2])
  bbox[n, ] <- NA_real_
  tibble::tibble(
    id = seq_len(n),
    cat = rep(c("a", "b"), length.out = n),
    .rcs_id = bit64::as.integer64(seq_len(n)),
    h3 = h3,
    bbox = bbox,
    geometry = unclass(sf::st_as_binary(sf::st_sfc(geoms)))
  )
}

local_geo_mocks <- function(frame = parent.frame()) {
  testthat::local_mocked_bindings(
    h3_parent = function(cells, res) cells %/% bit64::as.integer64(10L^(5L - res)),
    geo_metadata = function(data, crs) {
      paste0('{"version":"1.1.0","rows":', nrow(data), "}")
    },
    .env = frame
  )
}

read_parquet64 <- function(path) {
  withr::local_options(arrow.int64_downcast = FALSE)
  arrow::read_parquet(path)
}

test_that("check_key() accepts a unique key and no key", {
  x <- sim_table()
  expect_invisible(check_key(x, c("shop_id", "date", "product")))
  expect_identical(check_key(x, NULL), x)
  expect_identical(check_key(x, character()), x)
})

test_that("check_key() aborts on missing columns and repeated keys", {
  x <- sim_table()
  expect_error(check_key(x, c("shop_id", "nope")), "nope", class = "rcs_error_argument")
  expect_error(check_key(x, c("shop_id", "shop_id")), class = "rcs_error_argument")
  dup <- rbind(x[1:8, ], x[1:7, ])
  err <- expect_error(check_key(dup, c("shop_id", "date", "product")), class = "rcs_error_key")
  expect_s3_class(err, "rcs_error_argument")
  msg <- conditionMessage(err)
  expect_match(msg, "7 key values repeat")
  expect_match(msg, "And 2 more")
  expect_match(msg, paste0("shop_id = ", x$shop_id[[1]]), fixed = TRUE)
})

test_that("partition_plan() gives one group without partition", {
  x <- sim_table()
  plan <- partition_plan(x, NULL)
  expect_identical(plan$partition, character())
  expect_identical(plan$groups, list(seq_len(nrow(x))))
  expect_identical(partition_plan(x[0, ], NULL)$groups, list(integer()))
})

test_that("partition_plan() splits by columns, ordered by value", {
  x <- sim_table()
  plan <- partition_plan(x, c("year", "product"), max_files = 100)
  expect_identical(plan$partition, c("year", "product"))
  keys <- vapply(plan$groups, function(g) {
    paste(unique(x$year[g]), unique(as.character(x$product[g])))
  }, character(1))
  expect_length(keys, nrow(unique(x[c("year", "product")])))
  expect_identical(sort(unlist(plan$groups)), seq_len(nrow(x)))
  years <- vapply(plan$groups, function(g) x$year[g][[1]], integer(1))
  expect_false(is.unsorted(years))
})

test_that("partition_plan() aborts on bad partitions", {
  x <- sim_table()
  expect_error(partition_plan(x, "nope"), "nope", class = "rcs_error_argument")
  expect_error(partition_plan(x, "qty"), "missing values", class = "rcs_error_argument")
  expect_error(partition_plan(x, "tags"), "plain values", class = "rcs_error_argument")
  expect_error(partition_plan(x[0, ], "year"), "Zero rows", class = "rcs_error_argument")
  expect_error(partition_plan(x, "shop_id", max_files = 5), "coarser", class = "rcs_error_argument")
  expect_error(partition_plan(x, "year", max_files = 0), class = "rcs_error_argument")
  expect_error(partition_plan(x, "h3"), "geocoded", class = "rcs_error_argument")
})

test_that("partition_plan() picks the finest h3 parent within max_files", {
  local_geo_mocks()
  g <- fake_geo()
  # resolution 5: 4 cells + null; 4: 2 parents + null; 3: 1 parent + null
  plan <- partition_plan(g, "h3", max_files = 5, h3_max_res = 5L)
  expect_identical(plan$partition, "h3_p5")
  expect_identical(plan$res, 5L)
  plan <- partition_plan(g, "h3", max_files = 3, h3_max_res = 5L)
  expect_identical(plan$partition, "h3_p4")
  expect_identical(names(plan$data)[1:5], c("id", "cat", ".rcs_id", "h3", "h3_p4"))
  expect_length(plan$groups, 3)
  # the row without a cell is a group of its own, placed last
  last <- plan$groups[[3]]
  expect_identical(last, nrow(g))
  expect_true(is.na(plan$data$h3_p4[last]))
  # an update can cap the resolution
  expect_identical(partition_plan(g, "h3", max_files = 5, h3_max_res = 3L)$partition, "h3_p3")
  expect_error(
    partition_plan(g, "h3", max_files = 1, h3_max_res = 5L),
    "resolution 0", class = "rcs_error_argument"
  )
})

test_that("sort_rows() orders by the key in radix order", {
  x <- sim_table()
  sorted <- sort_rows(x, c("shop_id", "date"))
  expect_false(is.unsorted(sorted$shop_id))
  expect_identical(sort_rows(x, NULL), x)
  y <- tibble::tibble(k = c("b", "B", "a", "é"), v = 1:4)
  expect_identical(sort_rows(y, "k")$k, c("B", "a", "b", "é"))
  big <- tibble::tibble(k = bit64::as.integer64(c("9007199254740995", "9007199254740993", "5")))
  expect_identical(as.character(sort_rows(big, "k")$k), c("5", "9007199254740993", "9007199254740995"))
})

test_that("files_columns_spec() records the R types Arrow does not restore", {
  x <- sim_table()
  spec <- files_columns_spec(x, files_arrow_schema(x), c(qty = "Quantity sold"))
  expect_identical(spec$name, names(x))
  r_type <- stats::setNames(spec$r_type, spec$name)
  expect_identical(r_type$big, list(class = "integer64"))
  expect_identical(r_type$wait, list(class = "difftime", units = "hours"))
  expect_identical(r_type$product, list(class = "factor", levels = sprintf("p%02d", 1:20), ordered = FALSE))
  expect_true(r_type$grade$ordered)
  expect_identical(r_type$tags, list(class = "list"))
  expect_null(r_type$qty)
  expect_identical(spec$description[spec$name == "qty"], "Quantity sold")
  expect_true(all(is.na(spec$description[spec$name != "qty"])))
  expect_identical(spec$type[spec$name == "big"], "int64")
  expect_identical(columns_from_json(columns_to_json(spec)), spec)
  expect_error(files_columns_spec(x, files_arrow_schema(x), c(nope = "x")), "nope", class = "rcs_error_argument")
  expect_error(files_columns_spec(x, files_arrow_schema(x), "x"), class = "rcs_error_argument")

  g <- fake_geo()
  geo_spec <- files_columns_spec(g, files_arrow_schema(g))
  expect_null(geo_spec$r_type[[match("geometry", geo_spec$name)]])
  expect_identical(geo_spec$type[geo_spec$name == "geometry"], "binary")
  expect_identical(files_arrow_schema(g[0, ])$geometry$type$ToString(), "binary")
})

# Stage `x` as one file, read it back and restore the recorded types.
stage_and_restore <- function(x) {
  out <- stage_table(x, rows_per_group = 3)
  back <- read_parquet64(out$staged$local)
  list(out = out, back = restore_types(back, columns_from_json(out$entry$columns)))
}

test_that("a difftime of any units and fractional value survives a round trip exactly", {
  values <- c(66.85, 0.1, NA, -3.333333333333, 1e-9, 12345.678901234)
  for (units in c("secs", "mins", "hours", "days", "weeks")) {
    x <- tibble::tibble(id = seq_along(values), wait = as.difftime(values, units = units))
    got <- stage_and_restore(x)
    expect_identical(got$back$wait, x$wait, info = units)
    spec <- columns_from_json(got$out$entry$columns)
    expect_identical(spec$type[spec$name == "wait"], "double")
    expect_identical(spec$r_type[[match("wait", spec$name)]], list(class = "difftime", units = units))
    # writing is deterministic
    expect_identical(stage_table(x, rows_per_group = 3)$files$md5, got$out$files$md5)
  }
  zero <- tibble::tibble(id = integer(), wait = as.difftime(numeric(), units = "mins"))
  expect_identical(stage_and_restore(zero)$back$wait, zero$wait)
  only_na <- tibble::tibble(id = 1:2, wait = as.difftime(c(NA_real_, NA_real_), units = "days"))
  expect_identical(stage_and_restore(only_na)$back$wait, only_na$wait)
})

test_that("restore_types() restores every recorded type and leaves changed columns alone", {
  x <- sim_table()
  got <- stage_and_restore(x[0, ])$back
  expect_identical(levels(got$product), levels(x$product))
  expect_true(is.ordered(got$grade))
  expect_s3_class(got$big, "integer64")
  expect_s3_class(got$wait, "difftime")

  back <- read_parquet64(stage_table(x)$staged$local)
  spec <- columns_from_json(stage_table(x)$entry$columns)
  restored <- restore_types(back, spec)
  expect_null(attributes(restored$tags))
  expect_identical(restored$tags, lapply(sort_rows(x, NULL)$tags, function(e) {
    if (!is.null(e)) attributes(e) <- NULL
    e
  }))
  # a column that a query turned into another type keeps that type
  changed <- back
  changed$big <- as.character(changed$big)
  changed$product <- as.integer(changed$product)
  changed$wait <- "later"
  kept <- restore_types(changed, spec)
  expect_identical(kept$big, changed$big)
  expect_identical(kept$product, changed$product)
  expect_identical(kept$wait, changed$wait)
  # geometry becomes a bare list of raw vectors, a struct a tibble
  g <- fake_geo()
  local_geo_mocks()
  geo <- stage_table(g, kind = "geospatial", crs = "{}")
  rows <- restore_types(read_parquet64(geo$staged$local), columns_from_json(geo$entry$columns))
  expect_null(attributes(rows$geometry))
  expect_identical(rows$geometry, g$geometry)
  expect_s3_class(rows$bbox, "tbl_df")
})

test_that("files_stage() writes a one-file table with entry, file row and manifest", {
  x <- sim_table()
  dir <- withr::local_tempdir()
  out <- stage_table(x, key = c("shop_id", "date", "product"), rows_per_group = 200, dir = dir,
    source = "simulation", columns = c(qty = "Quantity"))
  entry <- out$entry
  expect_identical(entry$dataset, "sales/daily")
  expect_identical(entry$kind, "table")
  expect_identical(entry$key[[1]], c("shop_id", "date", "product"))
  expect_identical(entry$sorted_by[[1]], c("shop_id", "date", "product"))
  expect_identical(entry$partition[[1]], character())
  expect_identical(entry$source, "simulation")
  expect_identical(as.numeric(entry$rows), 500)
  expect_identical(as.numeric(entry$n_files), 1)
  expect_true(is.na(entry$h3_res))
  expect_true(is.na(entry$bbox$xmin))

  files <- out$files
  expect_identical(files$path, paste0("sales/daily/part-", entry$version, ".parquet"))
  expect_identical(files$partition_values, "{}")
  expect_identical(out$staged$local, file.path(dir, files$path))
  expect_identical(files$md5, md5_file(out$staged$local))
  expect_identical(as.numeric(files$bytes), as.numeric(file.size(out$staged$local)))
  expect_identical(entry$version, version_hash("{}", files$md5))
  expect_identical(as.numeric(entry$bytes), as.numeric(files$bytes))
  expect_true(is.na(files$h3_min))

  # the embedded metadata is the entry without the left-out columns
  reader <- arrow::ParquetFileReader$create(out$staged$local)
  meta <- reader$GetSchema()$metadata
  expect_identical(meta$rcs, entry_metadata_json(entry))
  expect_null(meta$geo)
  expect_identical(reader$num_row_groups, 3L)
  rm(reader)

  # rows come back sorted by the key, values intact
  back <- read_parquet64(out$staged$local)
  sorted <- sort_rows(x, c("shop_id", "date", "product"))
  expect_identical(back$shop_id, sorted$shop_id)
  expect_identical(back$note, sorted$note)
  expect_identical(as.character(back$big), as.character(sorted$big))

  # the manifest is staged next to the files and agrees
  expect_identical(out$manifest_local, file.path(dir, manifest_path("sales/daily", entry$version)))
  m <- manifest_from_json(readChar(out$manifest_local, file.size(out$manifest_local), useBytes = TRUE))
  expect_identical(m$entry, entry)
  expect_identical(m$files, files)
  # no temporary files are left behind
  expect_setequal(
    list.files(dir, recursive = TRUE, all.files = TRUE),
    c(files$path, manifest_path("sales/daily", entry$version))
  )
})

test_that("files_stage() is deterministic and the version follows the data", {
  x <- sim_table()
  a <- stage_table(x, key = c("shop_id", "date", "product"), partition = "year")
  b <- stage_table(x[rev(seq_len(nrow(x))), ], key = c("shop_id", "date", "product"), partition = "year")
  expect_identical(a$files$md5, b$files$md5)
  expect_identical(a$entry$version, b$entry$version)
  expect_identical(a$files$path, b$files$path)

  y <- x
  y$qty[[10]] <- 1000L
  c <- stage_table(y, key = c("shop_id", "date", "product"), partition = "year")
  expect_false(identical(c$entry$version, a$entry$version))
  expect_identical(sum(c$files$md5 != a$files$md5), 1L)

  # history, provenance and time do not reach the files
  withr::local_options(rcs.record_writer = TRUE)
  d <- stage_table(x, key = c("shop_id", "date", "product"), partition = "year",
    history = TRUE, created = as.POSIXct("2020-01-01", tz = "UTC"))
  expect_identical(d$files$md5, a$files$md5)
})

test_that("files_stage() writes one file per partition", {
  x <- sim_table()
  out <- stage_table(x, partition = c("year", "product"), max_files = 100)
  entry <- out$entry
  combos <- unique(x[c("year", "product")])
  expect_identical(nrow(out$files), nrow(combos))
  expect_identical(entry$partition[[1]], c("year", "product"))
  expect_identical(entry$sorted_by[[1]], character())
  first <- out$files[1, ]
  values <- jsonlite::fromJSON(first$partition_values)
  expect_named(values, c("year", "product"))
  expect_identical(
    first$path,
    data_file_path("sales/daily", entry$version, list(year = values$year, product = values$product))
  )
  for (i in seq_len(nrow(out$files))) {
    back <- read_parquet64(out$staged$local[[i]])
    v <- jsonlite::fromJSON(out$files$partition_values[[i]])
    expect_true(all(back$year == v$year & as.character(back$product) == v$product))
    expect_identical(as.numeric(out$files$rows[[i]]), as.numeric(nrow(back)))
  }
  expect_identical(sum(as.numeric(out$files$rows)), as.numeric(nrow(x)))
  expect_identical(entry$version, version_hash(out$files$partition_values, out$files$md5))
  # every partition file has the same schema
  schemas <- lapply(out$staged$local, function(p) arrow::ParquetFileReader$create(p)$GetSchema())
  expect_true(all(vapply(schemas, function(s) s$Equals(schemas[[1]]), logical(1))))
})

test_that("files_stage() keeps partitions for an update", {
  x <- sim_table()
  full <- stage_table(x, partition = "year")
  years <- sort(unique(x$year))
  kept <- full$files[1, ]
  changed <- x[x$year != years[[1]], ]
  changed$qty <- changed$qty + 1L
  out <- stage_table(changed, partition = "year", keep = kept)
  expect_identical(nrow(out$files), nrow(full$files))
  expect_identical(nrow(out$staged), nrow(full$files) - 1L)
  expect_true(kept$path %in% out$files$path)
  expect_identical(out$files$created[out$files$path == kept$path], kept$created)
  expect_true(all(out$files$version == out$entry$version))
  expect_identical(out$entry$version, version_hash(out$files$partition_values, out$files$md5))
  expect_false(identical(out$entry$version, full$entry$version))
  expect_identical(as.numeric(out$entry$rows), as.numeric(nrow(x)))
  expect_error(stage_table(x, partition = "year", keep = kept), class = "rlang_error")
})

test_that("files_stage() writes zero rows as one file", {
  x <- sim_table()[0, ]
  out <- stage_table(x, key = "shop_id")
  expect_identical(as.numeric(out$entry$rows), 0)
  expect_identical(nrow(out$files), 1L)
  expect_identical(nrow(read_parquet64(out$staged$local)), 0L)
  expect_error(stage_table(x, partition = "year"), "Zero rows", class = "rcs_error_argument")
})

test_that("files_stage() validates its arguments", {
  x <- sim_table()
  expect_error(stage_table(x, dataset = "Bad Name"), class = "rcs_error_dataset_name")
  expect_error(stage_table(x, dataset = "a__h3"), class = "rcs_error_dataset_name")
  expect_error(files_stage(x, "a", title = "", description = "d", dir = withr::local_tempdir()), class = "rcs_error_argument")
  expect_error(stage_table(x, rows_per_group = 0), class = "rcs_error_argument")
  expect_error(stage_table(rbind(x, x[1, ]), key = c("shop_id", "date", "product")), class = "rcs_error_key")
})

test_that("files_stage() writes geospatial files with geo metadata, extent and cells", {
  local_geo_mocks()
  g <- fake_geo()
  crs <- sf::st_crs(4326)$proj4string
  out <- files_stage(
    g, "shapes/points", title = "Points", description = "Simulated points.",
    kind = "geospatial", crs = crs, h3_res = 5L, partition = "h3", max_files = 3,
    dir = withr::local_tempdir()
  )
  entry <- out$entry
  expect_identical(out$partition, "h3_p4")
  expect_identical(entry$partition[[1]], "h3_p4")
  expect_identical(entry$sorted_by[[1]], c("h3", ".rcs_id"))
  expect_identical(entry$h3_res, 5L)
  expect_identical(entry$crs, crs)
  expect_equal(entry$bbox$xmin, -29.9)
  expect_equal(entry$bbox$ymax, max(g$bbox$ymax, na.rm = TRUE))
  files <- out$files
  expect_identical(nrow(files), 3L)
  null_file <- files[grepl("h3_p4=null", files$path), ]
  expect_identical(nrow(null_file), 1L)
  expect_identical(null_file$partition_values, '{"h3_p4":null}')
  expect_true(is.na(null_file$h3_min))
  expect_true(is.na(null_file$bbox$xmin))
  cells <- files[!grepl("null", files$path), ]
  expect_true(all(cells$h3_min <= cells$h3_max))
  expect_identical(as.character(min(cells$h3_min)), "600011")
  for (p in out$staged$local) {
    meta <- arrow::ParquetFileReader$create(p)$GetSchema()$metadata
    expect_match(meta$geo, '"version":"1.1.0"', fixed = TRUE)
    expect_identical(meta$rcs, entry_metadata_json(entry))
  }
  back <- read_parquet64(out$staged$local[[1]])
  expect_identical(names(back), c("id", "cat", ".rcs_id", "h3", "h3_p4", "bbox", "geometry"))
  expect_type(back$geometry, "list")

  flat <- files_stage(
    g[setdiff(names(g), "h3")], "polygons", title = "Flat", description = "No geocodes.",
    kind = "geospatial", crs = crs, dir = withr::local_tempdir()
  )
  expect_identical(flat$entry$sorted_by[[1]], ".rcs_id")
  expect_true(is.na(flat$files$h3_min))
  expect_false(is.na(flat$files$bbox$xmin))
})

test_that("files_row_groups() lists row groups from the footers", {
  local_backend_fallback()
  x <- sim_table()
  dir <- withr::local_tempdir()
  out <- stage_table(x, partition = "year", rows_per_group = 100, dir = dir)
  be <- be_new(dir)
  withr::local_options(rcs.trace = TRUE)
  rcs_trace_reset()
  groups <- files_row_groups(be, out$files$path)
  expect_named(groups, c("path", "row_group", "rows"))
  expect_type(groups$row_group, "integer")
  expect_type(groups$rows, "double")
  for (i in seq_len(nrow(out$files))) {
    g <- groups[groups$path == out$files$path[[i]], ]
    expect_identical(g$row_group, seq_len(nrow(g)))
    expect_identical(sum(g$rows), as.numeric(out$files$rows[[i]]))
    expect_true(all(g$rows <= 100))
  }
  trace <- rcs_trace()
  opens <- trace[trace$counter == "file_open", ]
  expect_setequal(opens$detail, out$files$path)
  expect_true(all(opens$n == 1))
  expect_identical(nrow(files_row_groups(be, character())), 0L)
  expect_error(files_row_groups(be, "nope.parquet"), class = "rcs_error_backend")
})

test_that("files_read_row_groups() reads chosen groups and columns", {
  local_backend_fallback()
  local_geo_mocks()
  x <- sim_table()
  dir <- withr::local_tempdir()
  out <- stage_table(x, key = c("shop_id", "date", "product"), rows_per_group = 100, dir = dir)
  be <- be_new(dir)
  path <- out$files$path
  all <- read_parquet64(file.path(dir, path))

  t <- files_read_row_groups(be, path, c(3, 2))
  expect_s3_class(t, "Table")
  expect_identical(t$num_rows, 200L)
  expect_identical(as.data.frame(t)$shop_id, all$shop_id[101:300])

  t <- files_read_row_groups(be, path, 1, columns = c("qty", "shop_id"))
  expect_identical(names(t), c("qty", "shop_id"))
  expect_identical(as.data.frame(t)$qty, all$qty[1:100])
  expect_error(files_read_row_groups(be, path, 9), class = "rlang_error")
  expect_error(files_read_row_groups(be, path, 1, "nope"), class = "rcs_error_argument")

  # a struct column has several leaves in the file
  g <- fake_geo()
  gdir <- withr::local_tempdir()
  gout <- files_stage(g, "shapes/points", title = "P", description = "P.", kind = "geospatial",
    crs = "x", h3_res = 5L, dir = gdir)
  t <- files_read_row_groups(be_new(gdir), gout$files$path, 1, c("geometry", "bbox", "id"))
  expect_identical(names(t), c("geometry", "bbox", "id"))
  df <- as.data.frame(t)
  expect_identical(df$id, g$id)
  expect_equal(df$bbox$xmax, g$bbox$xmax)
})

test_that("restore_list() gives what the element-by-element version gave", {
  old <- function(x, strip = TRUE) {
    if (!is.list(x) || is.data.frame(x)) {
      return(x)
    }
    lapply(seq_along(x), function(i) {
      e <- x[[i]]
      if (strip && !is.null(e)) attributes(e) <- NULL
      e
    })
  }
  tags <- rcs_sim_table(200, seed = 1)$tags
  from_arrow <- as.data.frame(arrow::arrow_table(tags = tags))$tags
  wkb <- as.data.frame(arrow::arrow_table(geometry = arrow::Array$create(
    lapply(1:5, function(i) as.raw(seq_len(i))), type = arrow::binary()
  )))$geometry
  cases <- list(
    from_arrow, from_arrow[0], tags, list(a = 1, NULL, structure(1:2, foo = 1), c(x = "a")), 1:3
  )
  for (x in cases) {
    expect_identical(restore_list(x), old(x))
    expect_identical(restore_list(x, strip = FALSE), old(x, strip = FALSE))
  }
  expect_identical(restore_list(wkb, strip = FALSE), old(wkb, strip = FALSE))
})

test_that("partition_plan_h3() matched back from distinct cells equals the parent of every row", {
  skip_if_no_h3()
  encoded <- geo_encode(rcs_sim_polygons(200, seed = 2), h3_res = 5L, geocode = TRUE, key = NULL, id_start = 1)
  data <- encoded$data
  for (max_files in c(4L, 30L, 1000L)) {
    plan <- partition_plan_h3(data, max_files, 5L, call = NULL)
    expect_identical(plan$data[[plan$partition]], h3_parent(data$h3, plan$res))
    finer <- plan$res + 1L
    if (finer <= 5L) {
      expect_gt(vctrs::vec_unique_count(h3_parent(data$h3, finer)), max_files)
    }
  }
})

# Geocoding engine column (plan 0002, D30) ------------------------------------

embedded_rcs <- function(path) {
  arrow::ParquetFileReader$create(path)$GetSchema()$metadata$rcs
}

expected_rcs <- function(entry) {
  kinds <- schema_kinds("catalog")
  to_json(row_to_list(entry, kinds[setdiff(names(kinds), c(entry_not_embedded, "geocode_engine"))]))
}

test_that("files_stage() with geocode_engine = NA embeds no geocode_engine key", {
  local_geo_mocks()
  table <- stage_table(rcs_sim_table(200, seed = 1))
  expect_true(is.na(table$entry$geocode_engine))
  geo <- files_stage(
    fake_geo(), "shapes/points", title = "Points", description = "Simulated points.",
    kind = "geospatial", crs = sf::st_crs(4326)$proj4string, h3_res = 5L,
    dir = withr::local_tempdir()
  )
  expect_true(is.na(geo$entry$geocode_engine))
  for (out in list(table, geo)) {
    for (p in out$staged$local) {
      json <- embedded_rcs(p)
      expect_false("geocode_engine" %in% names(jsonlite::fromJSON(json, simplifyVector = FALSE)))
      expect_identical(json, expected_rcs(out$entry))
    }
    manifest <- jsonlite::fromJSON(paste(readLines(out$manifest_local, warn = FALSE), collapse = "\n"),
      simplifyVector = FALSE)
    expect_false("geocode_engine" %in% names(manifest$entry))
  }
})

test_that("files_stage() with a geocoding engine embeds it in the files and the manifest", {
  local_geo_mocks()
  out <- files_stage(
    fake_geo(), "shapes/points", title = "Points", description = "Simulated points.",
    kind = "geospatial", crs = sf::st_crs(4326)$proj4string, h3_res = 5L,
    partition = "h3", max_files = 3, geocode_engine = "auto", dir = withr::local_tempdir()
  )
  expect_identical(out$entry$geocode_engine, "auto")
  for (p in out$staged$local) {
    json <- embedded_rcs(p)
    expect_identical(jsonlite::fromJSON(json, simplifyVector = FALSE)$geocode_engine, "auto")
    expect_identical(json, entry_metadata_json(out$entry))
  }
  manifest <- manifest_from_json(paste(readLines(out$manifest_local, warn = FALSE), collapse = "\n"))
  expect_identical(manifest$entry$geocode_engine, "auto")
  expect_identical(out$manifest$entry$geocode_engine, "auto")

  # the engine is part of the files, so the version differs from the NA write
  plain <- files_stage(
    fake_geo(), "shapes/points", title = "Points", description = "Simulated points.",
    kind = "geospatial", crs = sf::st_crs(4326)$proj4string, h3_res = 5L,
    partition = "h3", max_files = 3, dir = withr::local_tempdir()
  )
  expect_false(identical(plain$entry$version, out$entry$version))
})

# H3 cell class on write (plan 0002, D8) ---------------------------------------

o2_hex <- c("85283473fffffff", "85283447fffffff", "8528340bfffffff", "8428347ffffffff")

o2_cells <- function(n, hex = o2_hex) {
  new_rcs_h3(h3_hex_to_int64_raw(rep_len(hex, n)))
}

o2_r_type <- function(spec) {
  stats::setNames(spec$r_type, spec$name)
}

test_that("files_columns_spec() records rcs_h3 for user cell columns and integer64 for the package's cells", {
  n <- 8
  x <- tibble::tibble(
    id = seq_len(n),
    h3 = o2_cells(n),
    cell = o2_cells(n),
    big = bit64::as.integer64(seq_len(n))
  )
  spec <- files_columns_spec(x, files_arrow_schema(x))
  r_type <- o2_r_type(spec)
  # a table: no name rule, every rcs_h3 column is a user column
  expect_identical(r_type$h3, list(class = "rcs_h3"))
  expect_identical(r_type$cell, list(class = "rcs_h3"))
  expect_identical(r_type$big, list(class = "integer64"))
  expect_identical(spec$type[spec$name %in% c("h3", "cell", "big")], rep("int64", 3))
  expect_identical(columns_from_json(columns_to_json(spec)), spec)

  # the package's own cell columns record integer64 whatever their class
  y <- tibble::tibble(
    .rcs_id = bit64::as.integer64(seq_len(n)),
    h3 = o2_cells(n), h3_main = o2_cells(n), h3_p3 = o2_cells(n),
    cell = o2_cells(n), plain = bit64::as.integer64(o2_cells(n))
  )
  own <- o2_r_type(files_columns_spec(y, files_arrow_schema(y), cells_by_name = TRUE))
  for (name in c("h3", "h3_main", "h3_p3", "plain")) {
    expect_identical(own[[name]], list(class = "integer64"), info = name)
  }
  expect_identical(own$cell, list(class = "rcs_h3"))
  # rows with .rcs_id are geospatial rows or an index table by default
  expect_identical(o2_r_type(files_columns_spec(y, files_arrow_schema(y))), own)
  expect_identical(
    o2_r_type(files_columns_spec(y, files_arrow_schema(y), cells_by_name = FALSE))$h3,
    list(class = "rcs_h3")
  )
})

test_that("files_stage() records integer64 for the cells of geospatial data and index tables", {
  local_geo_mocks()
  g <- fake_geo()
  g$h3 <- new_rcs_h3(g$h3)
  g$cell <- new_rcs_h3(g$h3)
  geo <- stage_table(g, kind = "geospatial", crs = "{}")
  r_type <- o2_r_type(columns_from_json(geo$entry$columns))
  expect_identical(r_type$h3, list(class = "integer64"))
  expect_identical(r_type$cell, list(class = "rcs_h3"))
  plain <- g
  plain$h3 <- bit64::as.integer64(plain$h3)
  expect_identical(stage_table(plain, kind = "geospatial", crs = "{}")$files$md5, geo$files$md5)

  n <- 10
  index <- tibble::tibble(
    .rcs_id = bit64::as.integer64(seq_len(n)),
    h3 = o2_cells(n), h3_main = o2_cells(n), share = rep(1, n)
  )
  staged <- stage_table(index, "shapes/polygons__h3", index_of = "shapes/polygons", sorted_by = c("h3", ".rcs_id"))
  r_type <- o2_r_type(columns_from_json(staged$entry$columns))
  expect_identical(r_type$h3, list(class = "integer64"))
  expect_identical(r_type$h3_main, list(class = "integer64"))
})

test_that("a user column written as rcs_h3 or as integer64 gives the same files, paths and version", {
  n <- 40
  x <- tibble::tibble(id = seq_len(n), cell = o2_cells(n), qty = seq_len(n) * 2L)
  y <- x
  y$cell <- bit64::as.integer64(y$cell)
  expect_false(inherits(y$cell, "rcs_h3"))
  for (partition in list(NULL, "cell")) {
    a <- stage_table(x, "cells/user", key = "id", partition = partition)
    b <- stage_table(y, "cells/user", key = "id", partition = partition)
    info <- paste("partition:", partition %||% "none")
    expect_identical(a$files$path, b$files$path, info = info)
    expect_identical(a$files$md5, b$files$md5, info = info)
    expect_identical(a$entry$version, b$entry$version, info = info)
    expect_identical(o2_r_type(columns_from_json(a$entry$columns))$cell, list(class = "rcs_h3"), info = info)
    expect_identical(o2_r_type(columns_from_json(b$entry$columns))$cell, list(class = "integer64"), info = info)
    expect_identical(unname(tools::md5sum(a$staged$local)), unname(tools::md5sum(b$staged$local)), info = info)
  }
  expect_length(stage_table(x, "cells/user", key = "id", partition = "cell")$files$path, length(o2_hex))
})

test_that("restore_types() gives rcs_h3 to columns recorded as rcs_h3 only", {
  n <- 6
  x <- tibble::tibble(id = seq_len(n), cell = o2_cells(n), big = bit64::as.integer64(o2_cells(n)))
  out <- stage_table(x)
  back <- read_parquet64(out$staged$local)
  expect_false(inherits(back$cell, "rcs_h3"))
  restored <- restore_types(back, columns_from_json(out$entry$columns))
  expect_s3_class(restored$cell, "rcs_h3")
  expect_identical(restored$cell, x$cell)
  expect_false(inherits(restored$big, "rcs_h3"))
  expect_identical(restored$big, x$big)
  # a column a query changed keeps its type
  changed <- back
  changed$cell <- as.character(changed$cell)
  expect_identical(restore_types(changed, columns_from_json(out$entry$columns))$cell, changed$cell)
})
