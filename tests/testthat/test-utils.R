test_that("rcs_option() knows the defaults and honours options", {
  withr::local_options(
    rcs.quiet = NULL, rcs.trace = NULL, rcs.staging_dir = NULL, rcs.chunk_size = NULL,
    rcs.workers = NULL, rcs.lock_timeout = NULL, rcs.record_writer = NULL
  )
  expect_false(rcs_option("rcs.quiet"))
  expect_false(rcs_option("rcs.trace"))
  expect_identical(rcs_option("rcs.staging_dir"), tempdir())
  expect_identical(rcs_option("rcs.chunk_size"), 1e5)
  expect_identical(rcs_option("rcs.workers"), 1)
  expect_identical(rcs_option("rcs.lock_timeout"), 600)
  expect_false(rcs_option("rcs.record_writer"))
  withr::local_options(rcs.workers = 4)
  expect_identical(rcs_option("rcs.workers"), 4)
  expect_error(rcs_option("rcs.other"), "Unknown option")
})

test_that("rcs_inform() is silenced by rcs.quiet", {
  withr::local_options(rcs.quiet = FALSE)
  name <- "polygons"
  expect_message(rcs_inform("Reading {.val {name}}."), "polygons")
  withr::local_options(rcs.quiet = TRUE)
  expect_no_message(rcs_inform("Reading {.val {name}}."))
})

test_that("abort_not_implemented() names the function and the work package", {
  stub <- function() abort_not_implemented("geo_encode", "B")
  expect_error(stub(), "geo_encode", class = "rcs_error_not_implemented")
  expect_error(stub(), "work package B", class = "rcs_error_not_implemented")
  expect_error(abort_not_implemented("other"), "other", class = "rcs_error_not_implemented")
})

test_that("check_string() and check_flag() accept only what they name", {
  expect_invisible(check_string("a"))
  expect_no_error(check_string(NULL, allow_null = TRUE))
  title <- ""
  expect_error(check_string(title), "title", class = "rcs_error_argument")
  expect_error(check_string(NULL), class = "rcs_error_argument")
  expect_error(check_string(NA_character_), class = "rcs_error_argument")
  expect_error(check_string(c("a", "b")), class = "rcs_error_argument")
  expect_error(check_string(1), class = "rcs_error_argument")

  expect_invisible(check_flag(TRUE))
  expect_no_error(check_flag(NULL, allow_null = TRUE))
  expect_error(check_flag(NA), class = "rcs_error_argument")
  expect_error(check_flag("yes"), class = "rcs_error_argument")
  expect_error(check_flag(NULL), class = "rcs_error_argument")
})

test_that("valid dataset names pass", {
  for (name in c("polygons", "sales/daily", "a/b/c_d", "x1", "a_", "s__h3x")) {
    expect_identical(check_dataset_name(name), name)
  }
})

test_that("invalid dataset names abort with the rule", {
  bad <- c("Sales", "sales daily", "sales/", "/sales", "sales//daily", "sales.daily", "séries", "a-b")
  for (name in bad) {
    expect_error(check_dataset_name(name), "lower-case", class = "rcs_error_dataset_name")
  }
  expect_error(check_dataset_name("_hidden"), "start with", class = "rcs_error_dataset_name")
  expect_error(check_dataset_name("sales/_daily"), "start with", class = "rcs_error_dataset_name")
  expect_error(check_dataset_name("polygons__h3"), "reserved", class = "rcs_error_dataset_name")
  expect_no_error(check_dataset_name("polygons__h3", allow_index = TRUE))
  expect_error(check_dataset_name("_x__h3", allow_index = TRUE), class = "rcs_error_dataset_name")
  expect_error(check_dataset_name(""), class = "rcs_error_argument")
  expect_error(check_dataset_name(c("a", "b")), class = "rcs_error_argument")
})

test_that("index names are built and recognised", {
  expect_identical(index_name(c("polygons", "shapes/polygons")), c("polygons__h3", "shapes/polygons__h3"))
  expect_identical(is_index_name(c("polygons__h3", "polygons", "a__h3/b")), c(TRUE, FALSE, FALSE))
  expect_identical(index_parent("shapes/polygons__h3"), "shapes/polygons")
  expect_identical(index_parent("shapes/polygons"), "shapes/polygons")
})

test_that("catalog file names are fixed", {
  expect_identical(
    catalog_files,
    c(catalog = "_catalog.parquet", files = "_files.parquet", history = "_history.parquet")
  )
  expect_identical(store_file, "_store.json")
  expect_identical(lock_dir, "_lock")
})

test_that("partition values have one canonical JSON form", {
  expect_identical(partition_values_json(), "{}")
  expect_identical(partition_values_json(list()), "{}")
  expect_identical(partition_values_json(list(year = 2024L)), "{\"year\":2024}")
  expect_identical(
    partition_values_json(list(year = 2024L, product = factor("p07"))),
    "{\"year\":2024,\"product\":\"p07\"}"
  )
  expect_identical(
    partition_values_json(list(day = as.Date("2024-02-29"))),
    "{\"day\":\"2024-02-29\"}"
  )
  expect_identical(
    partition_values_json(list(h3_p2 = bit64::as.integer64("599686042433355775"))),
    "{\"h3_p2\":\"599686042433355775\"}"
  )
  expect_identical(partition_values_json(list(x = 0.1)), "{\"x\":0.1}")
  expect_identical(
    partition_values_json(tibble::tibble(year = 2024L, shop = "a")),
    "{\"year\":2024,\"shop\":\"a\"}"
  )
  expect_error(partition_values_json(list(2024)))
  expect_error(partition_values_json(list(year = 1:2)))
})

test_that("data file and manifest paths follow the plan", {
  version <- "0123456789abcdef"
  expect_identical(
    data_file_path("sales/daily", version),
    "sales/daily/part-0123456789abcdef.parquet"
  )
  expect_identical(
    data_file_path("sales/daily", version, list(year = 2024L, shop = "a b/c")),
    "sales/daily/year=2024/shop=a%20b%2Fc/part-0123456789abcdef.parquet"
  )
  expect_identical(
    data_file_path("height", version, ext = "tif"),
    "height/part-0123456789abcdef.tif"
  )
  expect_identical(
    manifest_path(c("sales/daily", "polygons"), version),
    c("sales/daily/_manifest-0123456789abcdef.json", "polygons/_manifest-0123456789abcdef.json")
  )
})

test_that("md5 helpers agree with known values", {
  dir <- withr::local_tempdir()
  empty <- file.path(dir, "empty")
  file.create(empty)
  text <- file.path(dir, "text")
  writeBin(charToRaw("The quick brown fox jumps over the lazy dog"), text)
  expect_identical(
    md5_file(c(empty, text)),
    c("d41d8cd98f00b204e9800998ecf8427e", "9e107d9d372bb6826bd81d3542a419d6")
  )
  expect_identical(md5_file(character()), character())
  expect_error(md5_file(file.path(dir, "missing")), "missing")
  expect_identical(md5_string(""), "d41d8cd98f00b204e9800998ecf8427e")
  expect_identical(
    md5_string("The quick brown fox jumps over the lazy dog"),
    "9e107d9d372bb6826bd81d3542a419d6"
  )
})

test_that("md5 converts between hex and base64", {
  hex <- c("d41d8cd98f00b204e9800998ecf8427e", NA, "9e107d9d372bb6826bd81d3542a419d6")
  base64 <- c("1B2M2Y8AsgTpgAmY7PhCfg==", NA, "nhB9nTcrtoJr2B01QqQZ1g==")
  expect_identical(md5_hex_to_base64(hex), base64)
  expect_identical(md5_base64_to_hex(base64), hex)
  expect_identical(md5_hex_to_base64(character()), character())
})

test_that("the version depends on the files and not on their order", {
  values <- c("{\"year\":2023}", "{\"year\":2024}")
  md5 <- c("d41d8cd98f00b204e9800998ecf8427e", "9e107d9d372bb6826bd81d3542a419d6")
  version <- version_hash(values, md5)
  expect_match(version, "^[0-9a-f]{16}$")
  expect_identical(version_hash(rev(values), rev(md5)), version)
  expect_false(identical(version_hash(values, rev(md5)), version))
  expect_false(identical(version_hash(values[1], md5[1]), version))
  # the definition, spelled out
  lines <- c(
    "{\"year\":2023}|d41d8cd98f00b204e9800998ecf8427e",
    "{\"year\":2024}|9e107d9d372bb6826bd81d3542a419d6"
  )
  expect_identical(
    version,
    substr(digest::digest(paste(lines, collapse = "\n"), algo = "md5", serialize = FALSE), 1, 16)
  )
  expect_identical(
    version_hash("{}", md5[1]),
    substr(digest::digest("{}|d41d8cd98f00b204e9800998ecf8427e", algo = "md5", serialize = FALSE), 1, 16)
  )
})

test_that("the version of fixed files never changes", {
  # A change here changes the version of every stored dataset.
  expect_identical(
    version_hash(
      c("{\"year\":2023}", "{\"year\":2024}"),
      c("d41d8cd98f00b204e9800998ecf8427e", "9e107d9d372bb6826bd81d3542a419d6")
    ),
    "cc969206f5123a26"
  )
})

test_that("version_hash() refuses incomplete input", {
  expect_error(version_hash(character(), character()))
  expect_error(version_hash("{}", NA_character_))
  expect_error(version_hash(c("{}", "{}"), "d41d8cd98f00b204e9800998ecf8427e"))
})

test_that("now_utc() is in UTC and whole microseconds", {
  now <- now_utc()
  expect_s3_class(now, "POSIXct")
  expect_identical(attr(now, "tzone"), "UTC")
  expect_lt(abs(as.numeric(now) - as.numeric(Sys.time())), 5)
  expect_identical(time_from_text(time_to_text(now)), now)
})

test_that("timestamps round-trip through text", {
  times <- as.POSIXct(
    c("2026-01-31 12:00:00", "2026-12-31 23:59:59.999999", "1999-01-01 00:00:00.000001", NA),
    tz = "UTC"
  )
  text <- time_to_text(times)
  expect_identical(
    text,
    c("2026-01-31T12:00:00.000000Z", "2026-12-31T23:59:59.999999Z", "1999-01-01T00:00:00.000001Z", NA)
  )
  back <- time_from_text(text)
  expect_identical(attr(back, "tzone"), "UTC")
  expect_equal(as.numeric(back), as.numeric(times), tolerance = 1e-12)
  # a fraction that rounds up to the next second
  expect_identical(
    time_to_text(as.POSIXct(1.9999996, origin = "1970-01-01", tz = "UTC")),
    "1970-01-01T00:00:02.000000Z"
  )
  # the session's zone does not matter
  local <- as.POSIXct("2026-01-31 12:00:00", tz = "UTC")
  attr(local, "tzone") <- ""
  expect_identical(time_to_text(local), "2026-01-31T12:00:00.000000Z")
})

test_that("bytes and counts are formatted for messages", {
  expect_identical(
    format_bytes(c(0, 999, 1000, 1500000, 2.1e9, NA)),
    c("0 B", "999 B", "1.0 kB", "1.5 MB", "2.1 GB", NA)
  )
  expect_identical(format_bytes(bit64::as.integer64("5000000000000000")), "5000.0 TB")
  expect_identical(format_count(c(5012334, 12, NA)), c("5,012,334", "12", NA))
  expect_identical(format_count(bit64::as.integer64(1234567)), "1,234,567")
})
