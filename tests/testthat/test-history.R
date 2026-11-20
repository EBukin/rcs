# History: the three levels of the setting, store_history(), store_prune(),
# and readers that connected before a write.

# Test-side work-around for a defect in R/files.R (see test-write.R):
# difftime is truncated to whole seconds; whole hours survive exactly.
whole_hours <- function(x) {
  x$wait <- as.difftime(round(as.numeric(x$wait, units = "hours")), units = "hours")
  x
}

sales_key <- c("shop_id", "date", "product")

local_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, .local_envir = frame)
}

scrub <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) {
    x <- gsub(root, "<root>", x, fixed = TRUE)
    gsub("[0-9.]+ (B|kB|MB|GB)", "<bytes>", x)
  }
}

local_paths <- function(n = 1L, history = FALSE, frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  paths <- file.path(root, c("primary", sprintf("secondary%d", seq_len(n - 1L))))
  for (p in paths) suppressMessages(store_create(p, history = history))
  normalizePath(paths, winslash = "/")
}

write_q <- function(st, x, dataset, mode = "create", ...) {
  suppressMessages(store_write(st, x, dataset,
    title = "Daily sales", description = "Simulated daily sales.",
    key = if (mode != "update") sales_key, partition = if (mode != "update") "year",
    mode = mode, ...
  ))
}

current_version <- function(st, dataset) {
  st$primary$catalog$version[st$primary$catalog$dataset == dataset]
}

# The three levels --------------------------------------------------------------

test_that("history follows the dataset's setting, else the connection's, else the store's", {
  skip_below_level("default")
  x1 <- whole_hours(rcs_sim_table(40, seed = 1))
  x2 <- x1
  x2$qty <- x2$qty + 1L
  levels <- list(NULL, TRUE, FALSE)
  label <- function(v) if (is.null(v)) "null" else tolower(as.character(v))
  for (store in c(FALSE, TRUE)) {
    primary <- local_paths(history = store)
    for (conn in levels) {
      st <- store_connect(primary, history = conn)
      for (ds in levels) {
        name <- paste0("d_", label(conn), "_", label(ds))
        write_q(st, x1, name, history = ds, check = FALSE)
        old <- st$primary$files$path[st$primary$files$dataset == name]
        v1 <- current_version(st, name)
        # The second write leaves the dataset's setting as it is.
        write_q(st, x2, name, mode = "replace", check = FALSE)
        expected <- if (!is.null(ds)) ds else if (!is.null(conn)) conn else store
        what <- paste0("store ", store, ", connection ", label(conn), ", dataset ", label(ds))
        history <- history_read(st$primary$backend)
        expect_identical(any(history$dataset == name & history$version == v1), expected, label = what)
        expect_identical(all(file.exists(file.path(primary, old))), expected, label = what)
        expect_identical(
          st$primary$catalog$history[st$primary$catalog$dataset == name],
          if (is.null(ds)) NA else ds,
          label = what
        )
      }
    }
    expect_store_valid(st)
  }
})

# store_history() ---------------------------------------------------------------

test_that("store_history() lists the versions and whether their files are present", {
  skip_below_level("default")
  primary <- local_paths(history = TRUE)
  st <- store_connect(primary)
  x <- whole_hours(rcs_sim_table(120, seed = 1))
  write_q(st, x, "sales/daily")
  v1 <- current_version(st, "sales/daily")
  y <- x[x$year == 2024, ]
  y$qty <- y$qty + 1L
  write_q(st, y, "sales/daily", mode = "update")
  v2 <- current_version(st, "sales/daily")
  h <- store_history(st, "daily")
  expect_identical(h$version, c(v2, v1))
  expect_identical(h$current, c(TRUE, FALSE))
  expect_identical(h$n_files, c(2L, 2L))
  expect_identical(h$rows, c(120, 120))
  expect_true(all(h$complete))
  expect_true(is.na(h$replaced[[1]]))
  expect_false(is.na(h$replaced[[2]]))
  expect_identical(names(h), c("version", "current", "written", "replaced", "n_files", "rows", "bytes", "complete"))

  only_v1 <- setdiff(
    history_read(st$primary$backend)$path,
    st$primary$files$path
  )
  unlink(file.path(primary, only_v1))
  h <- store_history(st, "sales/daily")
  expect_identical(h$complete, c(TRUE, FALSE))
  expect_error(store_history(st, "nothing"), class = "rcs_error_dataset_not_found")
})

# Readers that connected before a write -------------------------------------------

test_that("a reader connected before a write finds the old version with history, a clear error without", {
  skip_below_level("default")
  x <- whole_hours(rcs_sim_table(80, seed = 1))
  y <- x
  y$qty <- y$qty + 1L
  for (history in c(TRUE, FALSE)) {
    primary <- local_paths(history = history)
    writer <- store_connect(primary)
    write_q(writer, x, "sales/daily")
    reader <- store_connect(primary)
    v1 <- current_version(reader, "sales/daily")
    write_q(writer, y, "sales/daily", mode = "replace")
    stale <- reader$primary$files[reader$primary$files$dataset == "sales/daily", ]
    if (history) {
      rows <- files_lookup(reader$primary, "sales/daily", v1)
      expect_identical(rows$path, stale$path)
      data <- files_read_row_groups(reader$primary$backend, rows$path[[1]], 1L, "qty")
      expect_identical(nrow(data), as.integer(stale$rows[[1]]))
    } else {
      expect_false(any(file.exists(file.path(primary, stale$path))))
      store_refresh(reader)
      expect_error(files_lookup(reader$primary, "sales/daily", v1), class = "rcs_error_version_not_found")
    }
    expect_store_valid(writer)
  }
})

# store_prune() -----------------------------------------------------------------

test_that("store_prune() removes history beyond keep, never a file a kept version names", {
  skip_below_level("default")
  paths <- local_paths(n = 2L, history = TRUE)
  st <- store_connect(paths[[1]], secondary = paths[[2]])
  x <- whole_hours(rcs_sim_table(120, seed = 1))
  write_q(st, x, "sales/daily")
  v1 <- current_version(st, "sales/daily")
  y <- x[x$year == 2024, ]
  y$qty <- y$qty + 1L
  write_q(st, y, "sales/daily", mode = "update")
  v2 <- current_version(st, "sales/daily")
  # v1 and v2 share the file of the kept partition.
  shared <- intersect(history_read(st$primary$backend)$path, st$primary$files$path)
  expect_length(shared, 1L)
  z <- x
  z$price <- z$price * 2
  write_q(st, z, "sales/daily", mode = "replace")
  v3 <- current_version(st, "sales/daily")
  expect_identical(store_history(st, "sales/daily")$version, c(v3, v2, v1))

  local_snapshot_output()
  expect_snapshot(dry <- store_prune(st, keep = 1, dry_run = TRUE), transform = scrub(dirname(paths[[1]])))
  expect_identical(store_history(st, "sales/daily")$version, c(v3, v2, v1))
  expect_false(any(dry$path %in% shared))

  expect_snapshot(out <- store_prune(st, keep = 1), transform = scrub(dirname(paths[[1]])))
  expect_identical(out[c("location", "path")], dry[c("location", "path")])
  expect_identical(store_history(st, "sales/daily")$version, c(v3, v2))
  expect_true(all(file.exists(file.path(paths, shared))))
  expect_true(all(store_history(st, "sales/daily")$complete))
  expect_store_valid(st)
  for (p in paths) {
    expect_false(file.exists(file.path(p, manifest_path("sales/daily", v1))))
  }

  store_prune(st, "daily", keep = 0) |> suppressMessages()
  expect_identical(store_history(st, "sales/daily")$version, v3)
  expect_identical(nrow(history_read(st$secondary[[1]]$backend)), 0L)
  expect_store_valid(st)
  expect_snapshot(store_prune(st))
})

test_that("store_prune(before = ) removes versions replaced before a time", {
  skip_below_level("default")
  primary <- local_paths(history = TRUE)
  st <- store_connect(primary)
  x <- whole_hours(rcs_sim_table(40, seed = 1))
  for (i in 1:3) {
    x$qty <- x$qty + 1L
    write_q(st, x, "sales/daily", mode = "replace")
  }
  h <- store_history(st, "sales/daily")
  cut <- h$replaced[[3]] + 0.0005
  suppressMessages(store_prune(st, keep = 5, before = cut))
  expect_identical(store_history(st, "sales/daily")$version, h$version[1:2])
  suppressMessages(store_prune(st, keep = 5, before = as.Date("2000-01-01")))
  expect_identical(store_history(st, "sales/daily")$version, h$version[1:2])
  expect_store_valid(st)
  expect_snapshot(error = TRUE, {
    store_prune(st, keep = -1)
    store_prune(st, before = "not a time")
  })
})

test_that("store_prune() removes old orphans in every location and keeps young ones", {
  skip_below_level("default")
  paths <- local_paths(n = 2L)
  st <- store_connect(paths[[1]], secondary = paths[[2]])
  write_q(st, whole_hours(rcs_sim_table(40, seed = 1)), "sales/daily")
  old <- c(
    file.path(paths[[1]], "sales/daily/year=2023/part-0000000000000000.parquet"),
    file.path(paths[[2]], "sales/daily/._part.parquet.tmp-abc"),
    file.path(paths[[2]], "gone/_manifest-0000000000000000.json")
  )
  young <- file.path(paths[[1]], "sales/daily/part-1111111111111111.parquet")
  for (f in c(old, young)) {
    dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
    writeLines("x", f)
  }
  Sys.setFileTime(old, Sys.time() - 7200)
  out <- suppressMessages(store_prune(st, dry_run = TRUE))
  expect_setequal(out$path, c(
    "sales/daily/year=2023/part-0000000000000000.parquet",
    "sales/daily/._part.parquet.tmp-abc",
    "gone/_manifest-0000000000000000.json"
  ))
  expect_true(all(out$reason == "orphan"))
  expect_true(all(file.exists(old)))

  # Limited to one dataset, only its orphans go.
  out <- suppressMessages(store_prune(st, "sales/daily"))
  expect_identical(nrow(out), 2L)
  expect_true(file.exists(old[[3]]))
  suppressMessages(store_prune(st))
  expect_false(any(file.exists(old)))
  expect_true(file.exists(young))
  expect_store_valid(st, orphans_ok = TRUE)
  unlink(young)
  expect_store_valid(st)
})
