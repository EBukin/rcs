# The signatures other work packages build against. These tests stay when a
# work package replaces a stub by its implementation: the arguments and their
# defaults may not change without a change of the plan.

hook_signatures <- list(
  h3_as_int64 = c("x", "arg", "call"),
  h3_as_hex = c("x", "arg", "call"),
  h3_parent = c("cells", "res"),
  geo_encode = c("x", "h3_res", "geocode", "key", "id_start", "geocode_engine", "tol"),
  geo_h3_rows = c("g", "h3_res", "geocode_engine", "tol"),
  geo_rebuild = "geog",
  geo_decode = c("data", "crs"),
  geo_metadata = c("data", "crs"),
  geo_cells_touched = c("x", "h3_res"),
  geo_covering = c("shape", "h3_res", "crs"),
  raster_stage = c(
    "x", "dataset", "title", "description", "source", "inputs", "columns", "history", "dir"
  ),
  raster_open = c("be", "path", "intersects"),
  files_row_groups = c("be", "paths"),
  files_read_row_groups = c("be", "path", "row_groups", "columns"),
  resolve_dataset = c("st", "dataset", "index", "call"),
  choose_location = c("st", "dataset", "version", "call")
)

test_that("every hook exists with the signature of the contract", {
  namespace <- asNamespace("rcs")
  for (name in names(hook_signatures)) {
    expect_true(exists(name, envir = namespace, inherits = FALSE), info = name)
    expect_identical(names(formals(get(name, envir = namespace))), hook_signatures[[name]], info = name)
  }
})

test_that("hooks keep their defaults", {
  expect_identical(formals(geo_encode)$h3_res, 5L)
  expect_true(formals(geo_encode)$geocode)
  expect_null(formals(geo_encode)$key)
  expect_identical(formals(geo_encode)$geocode_engine, "auto")
  expect_identical(formals(geo_h3_rows)$geocode_engine, "auto")
  expect_identical(deparse(formals(geo_encode)$tol), "rcs_option(\"rcs.s2_rebuild_tol\")")
  expect_null(formals(raster_open)$intersects)
  expect_null(formals(files_read_row_groups)$columns)
  expect_false(formals(resolve_dataset)$index)
  expect_null(formals(choose_location)$version)
})
