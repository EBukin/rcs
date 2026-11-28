# The crash-point matrix (plan, "Testing"): each operation is run once with a
# counting stub to learn its number N of backend calls in one location, then
# N times with the stub failing at call 1, 2, ..., N, on the primary and on a
# secondary. After every failure the invariants hold and every location
# holds the old or the new version of each dataset; the repeated call (or
# store_sync() for a secondary left behind by a write) succeeds and sends
# only what is missing; the store ends as after a run without failure, and
# store_prune() removes the orphans. See `crash_matrix()` in helper-model.R.
#
# Level default runs a few crash points of some matrices; level full runs
# every call of every matrix.

skip_below_level("default")

full <- function() identical(test_level(), "full")

# Points per matrix at level default (NULL: all).
crash_points <- function(default = 1L) {
  if (full()) NULL else default
}

# Start states, built in three folders (primary, secondary1, secondary2).
setup_empty <- function(history = FALSE) {
  function(paths) {
    for (p in paths) suppressMessages(store_create(p, history = history))
  }
}

setup_written <- function(history = FALSE, versions = 1L) {
  function(paths) {
    for (p in paths) suppressMessages(store_create(p, history = history))
    st <- g_connect(paths)
    g_write(st, g_sim(20, 1), check = FALSE)
    for (i in seq_len(versions - 1L)) {
      g_write(st, g_sim(20, 1 + i), mode = "replace", check = FALSE)
    }
    g_write(st, g_sim(10, 7), "sales/summary", check = FALSE)
  }
}

# The primary is ahead: secondary1 lacks a dataset, secondary2 holds an older
# version of one.
setup_behind <- function(paths) {
  for (p in paths) suppressMessages(store_create(p))
  g_write(g_connect(paths[c(1, 3)]), g_sim(20, 1), check = FALSE)
  primary <- g_connect(paths[[1]])
  g_write(primary, g_sim(20, 2), mode = "replace", check = FALSE)
  g_write(primary, g_sim(10, 7), "sales/summary", check = FALSE)
}

# History versions to prune and an orphan in every location.
setup_prunable <- function(paths) {
  setup_written(history = TRUE, versions = 3L)(paths)
  for (p in paths) {
    orphan <- file.path(p, "sales", "daily", "year=2023", "part-0123456789abcdef.parquet")
    arrow::write_parquet(data.frame(a = 1), orphan)
    Sys.setFileTime(orphan, Sys.time() - 7200)
  }
}

op_create <- function(st) g_write(st, g_sim(20, 1), check = FALSE)
op_replace <- function(st) g_write(st, g_sim(20, 2), mode = "replace", check = FALSE)
op_update <- function(st) g_write(st, g_sim(8, 3, years = c(2024L, 2025L)), mode = "update", check = FALSE)
op_sync <- function(st) store_sync(st, all = TRUE)
op_delete <- function(st) store_delete(st, "sales/daily", confirm = "sales/daily", history = TRUE)
op_prune <- function(st) store_prune(st, keep = 0)

# Every matrix also fails each be_unlock() call of the operation: after a
# catalog switch that failure only warns (class rcs_warning_unlock), the
# operation completes, secondaries included, and the lock stays until its
# timeout (R/write.R, write_guard()).
matrix_case <- function(label, setup, op, repair = "sync", default = TRUE) {
  test_that(paste("crash points:", label), {
    if (!default) skip_below_level("full")
    g_no_wait()
    local_mocked_bindings(orphan_min_age = 0)
    for (role in c("primary", "secondary")) {
      at <- if (role == "primary") 1L else 2L
      crash_matrix(paste(label, "on the", role), setup, op,
        stub_at = at, points = crash_points(), repair = repair, unlock = TRUE
      )
    }
    succeed()
  })
}

test_that("a failing be_unlock() after the primary's switch warns and the secondaries are written", {
  g_no_wait()
  paths <- g_paths(secondaries = 2L)
  stub <- local_backend_stub(uri = paths[[1]], generic = "be_unlock", fail_at = 1)
  st <- g_connect(paths)
  res <- g_capture(op_create(st))
  expect_null(res$error)
  expect_false(res$behind)
  expect_true(any(vapply(res$warnings, inherits, logical(1), "rcs_warning_unlock")))
  expect_true(dir.exists(file.path(paths[[1]], lock_dir)))
  state <- g_state(paths)
  versions <- vapply(state, function(s) unname(s$current["sales/daily"]), character(1))
  expect_false(anyNA(versions))
  expect_length(unique(versions), 1L)
  unlink(file.path(paths[[1]], lock_dir), recursive = TRUE)
  g_expect_valid(st, "after a failed unlock")
})

test_that("a failing be_unlock() before the switch still aborts", {
  g_no_wait()
  paths <- g_paths(secondaries = 0L)
  st <- g_connect(paths)
  location <- st$primary
  stub <- local_backend_stub(generic = "be_unlock", fail_at = 1)
  location$backend <- stub_backend(location$backend, stub)
  # A guarded step that ends without switching the catalogs.
  step <- function() {
    write_guard(location)
    "done"
  }
  expect_error(step(), class = "rcs_error_stub")
  unlink(file.path(paths[[1]], lock_dir), recursive = TRUE)
})

matrix_case("store_write(mode = \"create\")", setup_empty(), op_create, default = FALSE)
matrix_case("store_write(mode = \"replace\")", setup_written(), op_replace)
matrix_case("store_write(mode = \"replace\") with history", setup_written(history = TRUE), op_replace, default = FALSE)
matrix_case("store_write(mode = \"update\")", setup_written(), op_update, default = FALSE)
matrix_case("store_sync()", setup_behind, op_sync, repair = "repeat")
matrix_case("store_delete()", setup_written(history = TRUE, versions = 2L), op_delete, repair = "repeat")
matrix_case("store_prune()", setup_prunable, op_prune, repair = "repeat", default = FALSE)

test_that("crash points: store_write() of geospatial data with its index table", {
  skip_below_level("full")
  skip_if_no_h3()
  g_no_wait()
  local_mocked_bindings(orphan_min_age = 0)
  pol <- rcs_sim_polygons(30, seed = 1)
  setup <- function(paths) {
    for (p in paths) suppressMessages(store_create(p))
    suppressMessages(store_write(g_connect(paths), pol, "shapes/polygons",
      title = "Polygons", description = "d", partition = "h3", max_files = 4, check = FALSE
    ))
  }
  op <- function(st) {
    store_write(st, pol[pol$id <= 25, ], "shapes/polygons",
      title = "Polygons", description = "d", mode = "replace", check = FALSE
    )
  }
  for (at in 1:2) crash_matrix("geospatial replace", setup, op, stub_at = at)
})
