# store_connect(), store_create(), store_refresh().

# Snapshots: long lines (paths stay on one line) and temporary paths replaced.
local_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
}

scrub_paths <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) gsub(root, "<root>", x, fixed = TRUE)
}

test_that("store_connect() reads the catalogs of every location", {
  fx <- local_test_store(partial = TRUE)
  st <- store_connect(fx$primary, secondary = fx$secondary)
  expect_s3_class(st, "rcs_store")
  expect_identical(store_uris(st), store_uris(fx$st))
  expect_identical(st$primary$catalog, fx$st$primary$catalog)
  expect_identical(st$primary$token, fx$st$primary$token)
  expect_identical(st$secondary[[2]]$catalog, fx$st$secondary[[2]]$catalog)
  expect_true(all(vapply(store_locations(st), function(l) l$available, logical(1))))
  expect_null(st$history)
  expect_false(st$store_history)
  expect_s3_class(st$connected_at, "POSIXct")
  expect_store_valid(st)
})

test_that("store_connect() reads catalog files in order and opens no data file", {
  fx <- local_test_store(secondaries = 1L)
  withr::local_options(rcs.trace = TRUE)
  st <- store_connect(fx$primary, secondary = fx$secondary)
  tr <- rcs_trace()
  reads <- tr[tr$counter == "catalog_read", ]
  expect_setequal(reads$detail, c("_catalog.parquet", "_files.parquet"))
  expect_identical(sum(reads$n), 4)
  expect_false(any(tr$counter == "file_open"))
  expect_identical(unique(tr$call), "store_connect")
})

test_that("addresses come from the environment, several secondaries separated by ;", {
  fx <- local_test_store()
  withr::local_envvar(
    STORE_PRIMARY = fx$primary,
    STORE_SECONDARY = paste0(fx$secondary[[1]], " ; ", fx$secondary[[2]], ";")
  )
  st <- store_connect()
  expect_identical(store_uris(st), c(fx$primary, fx$secondary))

  withr::local_envvar(OTHER_PRIMARY = fx$secondary[[2]], OTHER_SECONDARY = NA)
  other <- store_connect(env = "OTHER")
  expect_identical(store_uris(other), fx$secondary[[2]])

  # A primary given in the call is not mixed with the environment's secondaries.
  alone <- store_connect(fx$primary)
  expect_length(alone$secondary, 0)
  expect_store_valid(st)
})

test_that("a missing primary aborts naming the environment variables", {
  withr::local_envvar(STORE_PRIMARY = NA, MINE_PRIMARY = "")
  expect_error(store_connect(), class = "rcs_error_argument")
  expect_snapshot(store_connect(env = "MINE"), error = TRUE)
})

test_that("arguments are checked", {
  expect_snapshot(error = TRUE, {
    store_connect(1)
    store_connect("a", secondary = c("b", NA))
    store_connect("a", history = "yes")
    store_connect("a", create = NA)
    store_connect("s3://bucket/store")
  })
})

test_that("a location named twice aborts", {
  dir <- withr::local_tempdir()
  local_snapshot_output()
  expect_snapshot(
    store_connect(dir, secondary = paste0(dir, "/")),
    error = TRUE, transform = scrub_paths(dir)
  )
})

test_that("a location without catalogs aborts unless create = TRUE", {
  dir <- withr::local_tempdir()
  primary <- file.path(dir, "new")
  local_snapshot_output()
  expect_snapshot(store_connect(primary), error = TRUE, transform = scrub_paths(dir))
  expect_false(dir.exists(primary))

  st <- store_connect(primary, create = TRUE, history = TRUE)
  expect_identical(nrow(st$primary$catalog), 0L)
  expect_true(file.exists(file.path(primary, "_store.json")))
  expect_false(st$store_history)
  expect_true(st$history)
  expect_store_valid(st)

  # A secondary without catalogs aborts too ...
  secondary <- file.path(dir, "copy")
  expect_snapshot(store_connect(primary, secondary), error = TRUE, transform = scrub_paths(dir))
  # ... and is initialised with the store's default by create = TRUE.
  store_json_write(be_new(primary), TRUE)
  st <- store_connect(primary, secondary, create = TRUE)
  expect_true(st$secondary[[1]]$available)
  expect_true(store_json_read(be_new(secondary)))
  expect_store_valid(st)
})

test_that("an unreachable secondary warns and is marked unavailable", {
  fx <- local_test_store()
  stub <- local_backend_stub(uri = fx$secondary[[1]], fail_at = 1)
  local_snapshot_output()
  expect_snapshot(
    st <- store_connect(fx$primary, fx$secondary),
    transform = scrub_paths(dirname(fx$primary))
  )
  expect_false(st$secondary[[1]]$available)
  expect_identical(nrow(st$secondary[[1]]$catalog), 0L)
  expect_true(st$secondary[[2]]$available)
  status <- store_status(st)
  expect_true(all(status$status[status$location == st$secondary[[1]]$uri] == "unavailable"))
  expect_store_valid(st)

  # store_refresh() finds it again once it can be reached.
  stub$fail_at <- NULL
  store_refresh(st)
  expect_true(st$secondary[[1]]$available)
  expect_identical(st$secondary[[1]]$catalog, fx$st$secondary[[1]]$catalog)
  expect_store_valid(st)
})

test_that("an unreachable primary aborts with the authentication hint", {
  fx <- local_test_store(secondaries = 0L)
  stub <- local_backend_stub(uri = fx$primary, fail_at = 1)
  local_snapshot_output()
  expect_snapshot(
    store_connect(fx$primary),
    error = TRUE, transform = scrub_paths(dirname(fx$primary))
  )
  stub_reset(stub)
  expect_error(store_connect(fx$primary), class = "rcs_error_backend")
})

test_that("an unreachable primary on GCS aborts with the hint of every client", {
  local_mocked_bindings(location_exists = function(be) {
    cli::cli_abort("Injected: no route to the bucket.", class = "rcs_error_backend")
  })
  expect_snapshot(store_connect("gs://example-bucket/store"), error = TRUE)
})

test_that("store_create() initialises an empty store once", {
  dir <- withr::local_tempdir()
  location <- file.path(dir, "store")
  local_snapshot_output()
  expect_snapshot(uri <- store_create(location, history = TRUE), transform = scrub_paths(dir))
  expect_identical(uri, be_new(location)$uri)
  st <- store_connect(location)
  expect_true(st$store_history)
  expect_identical(nrow(st$primary$files), 0L)
  expect_true(file.exists(file.path(location, "_history.parquet")))
  expect_store_valid(st)

  token <- md5_file(file.path(location, "_catalog.parquet"))
  expect_snapshot(store_create(location), error = TRUE, transform = scrub_paths(dir))
  expect_identical(md5_file(file.path(location, "_catalog.parquet")), token)
  expect_error(store_create(location), class = "rcs_error_store_exists")

  withr::local_options(rcs.quiet = TRUE)
  expect_silent(store_create(file.path(dir, "quiet")))
})

test_that("store_refresh() sees writes made through another connection", {
  fx <- local_test_store(partial = TRUE)
  st <- store_connect(fx$primary, fx$secondary)
  other <- store_connect(fx$primary, fx$secondary)
  fixture_write(other, rcs_sim_table(10, seed = 9), "extra/table",
    title = "Extra", description = "Written by another connection."
  )
  expect_false("extra/table" %in% st$primary$catalog$dataset)
  withr::local_options(rcs.trace = TRUE)
  out <- store_refresh(st)
  expect_identical(out, st)
  expect_true("extra/table" %in% st$primary$catalog$dataset)
  expect_true("extra/table" %in% st$secondary[[2]]$catalog$dataset)
  tr <- rcs_trace()
  expect_false(any(tr$counter == "file_open"))
  withr::local_options(rcs.trace = FALSE)
  expect_store_valid(st)
})

test_that("store_refresh() marks a secondary unavailable when it cannot be reached", {
  fx <- local_test_store()
  st <- store_connect(fx$primary, fx$secondary)
  unlink(fx$secondary[[2]], recursive = TRUE)
  local_snapshot_output()
  expect_snapshot(store_refresh(st), transform = scrub_paths(dirname(fx$primary)))
  expect_false(st$secondary[[2]]$available)
  expect_true(st$secondary[[1]]$available)
  expect_store_valid(st)
})

test_that("store_refresh() aborts when the primary cannot be reached", {
  fx <- local_test_store(secondaries = 0L)
  stub <- local_backend_stub(uri = fx$primary)
  st <- store_connect(fx$primary)
  stub_reset(stub)
  stub$fail_at <- 1
  expect_error(store_refresh(st), class = "rcs_error_backend")
  expect_error(store_refresh(list()), class = "rcs_error_object")
})
