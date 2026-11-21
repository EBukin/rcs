# Helpers of the tests of work package G (test-sync.R, test-integration.R,
# test-crash-points.R, test-random-operations.R):
#
#   * stores in local folders and quiet writes (`g_*`);
#   * the crash-point matrix (`crash_matrix()`);
#   * the random-operation test and its in-memory model (`random_sequence()`).

# Stores and data ----------------------------------------------------------------

g_key <- c("shop_id", "date", "product")
g_cols <- c("shop_id", "date", "year", "product", "qty", "price", "note")

# Empty stores in local folders: the primary, then `secondaries` copies.
g_paths <- function(secondaries = 0L, history = FALSE, frame = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = frame)
  paths <- file.path(root, c("primary", sprintf("secondary%d", seq_len(secondaries))))
  for (p in paths) suppressMessages(store_create(p, history = history))
  normalizePath(paths, winslash = "/")
}

g_connect <- function(paths, history = NULL) {
  suppressWarnings(suppressMessages(store_connect(paths[[1]], secondary = paths[-1], history = history)))
}

# A small sales table whose rows fall in the given years (key unique).
g_sim <- function(n = 30, seed = 1, years = c(2023L, 2024L)) {
  x <- rcs_sim_table(n, seed = seed)[g_cols]
  target <- as.integer(years[(seq_len(nrow(x)) %% length(years)) + 1L])
  md <- format(x$date, "%m-%d")
  md[md == "02-29"] <- "02-28"
  x$date <- as.Date(paste0(target, "-", md))
  x$year <- target
  x <- x[!duplicated(x[g_key]), ]
  x[order(x$year, x$shop_id, x$date, x$product), ]
}

g_write <- function(st, x, dataset = "sales/daily", mode = "create", ...) {
  suppressMessages(store_write(st, x, dataset,
    title = "Daily sales", description = "Simulated daily sales.",
    key = if (mode != "update") g_key, partition = if (mode != "update") "year",
    mode = mode, ...
  ))
}

g_quiet <- function(expr) {
  suppressWarnings(suppressMessages(expr))
}

g_no_wait <- function(frame = parent.frame()) {
  testthat::local_mocked_bindings(retry_waits = function() c(0, 0), .package = "rcs", .env = frame)
}

g_snapshot_output <- function(frame = parent.frame()) {
  withr::local_options(cli.width = 250, width = 250, rcs.quiet = FALSE, .local_envir = frame)
}

g_scrub <- function(root) {
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  function(x) {
    x <- gsub(root, "<root>", x, fixed = TRUE)
    x <- gsub("[0-9.]+ (B|kB|MB|GB)", "<bytes>", x)
    x <- gsub("[0-9]+m [0-9]+s|[0-9]+\\.[0-9]s", "<time>", x)
    x <- gsub("(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])", "<version>", x, perl = TRUE)
    x <- gsub("backend call [0-9]+", "backend call <n>", x)
    x <- gsub("[0-9]+ seconds? ago", "<n> seconds ago", x)
    gsub("[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}", "<date>", x)
  }
}

# A local backend that no stub wraps (for checks that must not count).
g_plain_backend <- function(path) {
  be <- be_new(path)
  if (inherits(be, "rcs_backend_stub")) stub_inner(be) else be
}

# Read a dataset through a connection whose primary is `path`.
g_read_at <- function(path, dataset, ...) {
  st <- g_connect(path)
  suppressMessages(store_read(st, dataset, ...))
}

# Datasets (not index tables) listed by the catalog stored at `path`.
g_listed <- function(path) {
  catalog <- location_read(g_plain_backend(path))$catalog
  sort(catalog$dataset[!is_index_entry(catalog)], method = "radix")
}

# NULL when two tables hold the same rows (in any order, compared by key),
# else a description of the first difference.
g_rows_differ <- function(got, expected, key = g_key) {
  got <- tibble::as_tibble(got)
  expected <- tibble::as_tibble(expected)
  if (!setequal(names(got), names(expected))) {
    return(paste0("columns differ: ", paste(names(got), collapse = ", ")))
  }
  if (nrow(got) != nrow(expected)) {
    return(paste0(nrow(got), " rows instead of ", nrow(expected)))
  }
  got <- got[vctrs::vec_order(key_frame(got, key)), ]
  expected <- expected[vctrs::vec_order(key_frame(expected, key)), ]
  for (col in names(expected)) {
    if (!identical(normalise_values(got[[col]]), normalise_values(expected[[col]]))) {
      return(paste0("column ", col, " differs"))
    }
  }
  NULL
}

expect_rows_same <- function(got, expected, key = g_key, label = "rows") {
  problem <- g_rows_differ(got, expected, key)
  testthat::expect(is.null(problem), paste0(label, ": ", problem))
  invisible(got)
}

# Run `expr`, muffling messages, collecting warnings and catching an error.
g_capture <- function(expr) {
  warnings <- list()
  error <- tryCatch(
    withCallingHandlers(
      {
        expr
        NULL
      },
      warning = function(w) {
        warnings[[length(warnings) + 1L]] <<- w
        invokeRestart("muffleWarning")
      },
      message = function(m) invokeRestart("muffleMessage")
    ),
    error = function(e) e
  )
  behind <- Filter(function(w) inherits(w, "rcs_warning_secondary_behind"), warnings)
  list(error = error, warnings = warnings, behind = length(behind) > 0)
}

# `expect_store_valid()` with a context line in its failure message.
g_expect_valid <- function(st, what, orphans_ok = FALSE) {
  ok <- tryCatch(
    {
      expect_store_valid(st, orphans_ok = orphans_ok)
      TRUE
    },
    expectation_failure = function(e) {
      testthat::fail(paste0(what, "\n", conditionMessage(e)))
      FALSE
    }
  )
  invisible(ok)
}

# Remove orphans of every age (store_prune() keeps those younger than an
# hour); history versions are kept.
g_prune_orphans <- function(st) {
  testthat::with_mocked_bindings(
    g_quiet(store_prune(st, keep = 1e6)),
    orphan_min_age = 0, .package = "rcs"
  )
}

# State of locations, from what is stored: current versions, history
# versions, and the file rows of the current versions.
g_state <- function(paths) {
  lapply(paths, function(p) {
    be <- g_plain_backend(p)
    location <- location_read(be)
    history <- history_read(be)
    list(
      current = stats::setNames(location$catalog$version, location$catalog$dataset),
      history = sort(unique(paste(history$dataset, history$version)), method = "radix"),
      files = location$files[c("path", "md5")]
    )
  })
}

# Files of a state that a location lacks (missing or with another MD5).
g_missing_files <- function(path, state) {
  files <- state$files
  if (nrow(files) == 0) {
    return(0L)
  }
  full <- file.path(path, files$path)
  present <- file.exists(full)
  md5 <- rep(NA_character_, length(full))
  md5[present] <- md5_file(full[present])
  sum(is.na(md5) | md5 != files$md5)
}

g_data_puts <- function(stub) {
  sum(stub$log$generic == "be_put" & grepl("part-", stub$log$path))
}

# The crash-point matrix -----------------------------------------------------------

#' Run an operation once with a counting stub, then once per failing call
#'
#' @param label Name of the case, shown in failures.
#' @param setup `function(paths)` building the start state in three local
#'   folders (primary, two secondaries); run once, then copied.
#' @param op `function(st)` running the operation on a connection.
#' @param stub_at Index of the location whose backend calls are counted and
#'   failed (1 = primary).
#' @param points `NULL` for the full matrix (a failure at every call), or
#'   the number of calls to fail, spread evenly over the N calls.
#' @param repair What follows a call that left a secondary behind with a
#'   warning: `"sync"` (writes) or `"repeat"` the call.
#' @param unlock `TRUE` to fail every `be_unlock()` call of the operation in
#'   addition to `points`.
#' @return The number of backend calls N of the operation, invisibly.
#'
#' A failing `be_unlock()` after a catalog switch only warns (class
#' `rcs_warning_unlock`): the operation completes and the lock stays. The
#' matrix asserts this, then removes the lock as its timeout would.
#' @noRd
crash_matrix <- function(label, setup, op, stub_at, points = NULL, repair = c("sync", "repeat"),
                         unlock = FALSE, frame = parent.frame()) {
  repair <- match.arg(repair)
  template <- withr::local_tempdir(.local_envir = frame)
  root <- withr::local_tempdir(.local_envir = frame)
  names <- c("primary", "secondary1", "secondary2")
  setup(file.path(template, names))
  paths <- normalizePath(file.path(root, names), winslash = "/", mustWork = FALSE)
  restore <- function() {
    unlink(paths, recursive = TRUE)
    for (n in names) file.copy(file.path(template, n), root, recursive = TRUE)
  }
  restore()
  stub <- local_backend_stub(uri = paths[[stub_at]], .local_envir = frame)
  before <- g_state(paths)

  # Counting run.
  st <- g_connect(paths)
  stub_reset(stub)
  clean <- g_capture(op(st))
  testthat::expect(is.null(clean$error), paste0(label, ": the operation fails without injected failure: ",
    if (!is.null(clean$error)) conditionMessage(clean$error)))
  n <- stub$calls
  generics <- stub$log$generic
  after <- g_state(paths)

  ks <- seq_len(n)
  if (!is.null(points) && points < n) {
    ks <- unique(round(seq(1, n, length.out = points + 2L)[-c(1L, points + 2L)]))
  }
  if (unlock) {
    ks <- sort(union(ks, which(generics == "be_unlock")))
  }
  for (k in ks) {
    restore()
    st <- g_connect(paths)
    stub_reset(stub)
    stub$fail_at <- k
    res <- g_capture(op(st))
    stub$fail_at <- NULL
    generic <- if (k <= nrow(stub$log)) stub$log$generic[[k]] else "?"
    what <- paste0(label, ": failure at backend call ", k, " of ", n, " (", generic, ")")
    unlocked <- Filter(function(w) inherits(w, "rcs_warning_unlock"), res$warnings)
    if (length(unlocked) > 0) {
      # The switch stands: the call completes, warns, and leaves the lock.
      lock <- file.path(paths[[stub_at]], lock_dir)
      testthat::expect(
        generic == "be_unlock" && is.null(res$error) && !res$behind && dir.exists(lock),
        paste0(what, ": a failed unlock must only warn, complete the call and leave the lock")
      )
      unlink(lock, recursive = TRUE)
    }
    g_expect_valid(st, paste(what, "- after the failure"), orphans_ok = TRUE)

    # Readers see the old or the new version of every dataset.
    now <- g_state(paths)
    for (i in seq_along(paths)) {
      ds <- union(names(before[[i]]$current), names(after[[i]]$current))
      for (d in ds) {
        v <- unname(now[[i]]$current[d])
        allowed <- c(unname(before[[i]]$current[d]), unname(after[[i]]$current[d]))
        testthat::expect(
          identical(v, allowed[[1]]) || identical(v, allowed[[2]]),
          paste0(what, ": ", names[[i]], " holds version ", v, " of ", d, ", neither the old nor the new")
        )
      }
    }

    # Repeating the call (or syncing a secondary left behind) succeeds and
    # sends only what is missing.
    if (!is.null(res$error) || res$behind) {
      missing <- g_missing_files(paths[[stub_at]], after[[stub_at]])
      stub_reset(stub)
      again <- withr::with_options(
        list(rcs.lock_timeout = 0),
        g_capture(if (!is.null(res$error) || repair == "repeat") op(st) else store_sync(st))
      )
      testthat::expect(
        is.null(again$error) && !again$behind,
        paste0(what, ": the repeated call fails: ",
          if (!is.null(again$error)) conditionMessage(again$error) else "a secondary is behind")
      )
      puts <- g_data_puts(stub)
      testthat::expect(
        puts <= missing,
        paste0(what, ": the repeated call sent ", puts, " data files; ", missing, " were missing")
      )
    }
    final <- g_state(paths)
    for (i in seq_along(paths)) {
      testthat::expect(
        identical(final[[i]]$current[order(names(final[[i]]$current))], after[[i]]$current[order(names(after[[i]]$current))]) &&
          identical(final[[i]]$history, after[[i]]$history),
        paste0(what, ": ", names[[i]], " does not end in the state of a run without failure")
      )
    }
    g_prune_orphans(st)
    g_expect_valid(st, paste(what, "- at the end, orphans pruned"))
  }
  invisible(n)
}

# The random-operation test ----------------------------------------------------------

# One seeded sequence of operations on a primary and two secondaries, checked
# after every step against a plain model: a named list of data frames per
# location. Returns the operation log invisibly; a failing run reports its
# seed and its operations, and `random_sequence(seed, n_ops)` replays it.
random_sequence <- function(seed, n_ops = 50L, frame = parent.frame()) {
  withr::local_seed(seed)
  history_default <- sample(c(TRUE, FALSE), 1)
  paths <- g_paths(secondaries = 2L, history = history_default)
  stub <- local_backend_stub(uri = paths)
  st <- g_connect(paths)
  model <- list(list(), list(), list())
  names_pool <- c("a", "b", "c/d")
  log <- character()
  failed <- FALSE
  stopped <- FALSE

  note <- function(text) log <<- c(log, sprintf("%2d: %s", length(log) + 1L, text))
  sync_model <- function() {
    for (i in 2:3) {
      for (d in names(model[[1]])) model[[i]][[d]] <<- model[[1]][[d]]
    }
  }
  write_model <- function(d, x) {
    for (i in 1:3) model[[i]][[d]] <<- x
  }

  # Run a store call, with an injected failure at call `fail_at` (or none);
  # after a failure the call is repeated, after a secondary left behind
  # store_sync() runs; orphans are then pruned. Returns `TRUE` when the
  # model must take a sync of every dataset (a secondary was behind).
  run <- function(call, fail_at = NULL, repair = "sync") {
    stub_reset(stub)
    stub$fail_at <- fail_at
    res <- g_capture(call())
    stub$fail_at <- NULL
    if (any(vapply(res$warnings, inherits, logical(1), "rcs_warning_unlock"))) {
      # A failed unlock after a switch leaves the lock until its timeout.
      unlink(file.path(paths, lock_dir), recursive = TRUE)
    }
    if (is.null(fail_at)) {
      if (!is.null(res$error) || res$behind) {
        testthat::fail(paste0("Step ", length(log), " fails without injected failure: ",
          if (!is.null(res$error)) conditionMessage(res$error) else "a secondary is behind"))
        stopped <<- TRUE
      }
      return(FALSE)
    }
    synced <- FALSE
    if (!is.null(res$error) || res$behind) {
      again <- withr::with_options(
        list(rcs.lock_timeout = 0),
        g_capture(if (!is.null(res$error) || repair == "repeat") call() else store_sync(st))
      )
      synced <- is.null(res$error) && repair == "sync"
      if (!is.null(again$error) || again$behind) {
        testthat::fail(paste0("Step ", length(log), ": the call repeated after the failure fails: ",
          if (!is.null(again$error)) conditionMessage(again$error) else "a secondary is behind"))
        stopped <<- TRUE
        return(synced)
      }
    }
    g_prune_orphans(st)
    synced
  }

  step <- function() {
    present <- names(model[[1]])
    absent <- setdiff(names_pool, present)
    kinds <- c(
      if (length(absent) > 0) c("create", "create"),
      if (length(present) > 0) c("replace", "update", "update", "delete", "copy"),
      "sync", "prune", "rebuild", "history", "fail", "fail"
    )
    kind <- sample(kinds, 1)
    fail_at <- NULL
    if (kind == "fail") {
      fail_at <- sample.int(80L, 1)
      kind <- sample(c(
        if (length(absent) > 0) "create",
        if (length(present) > 0) c("replace", "update", "delete", "copy"),
        "sync", "prune"
      ), 1)
    }
    tag <- if (is.null(fail_at)) "" else sprintf(" [failure at call %d]", fail_at)
    hist_arg <- sample(list(NULL, TRUE, FALSE), 1, prob = c(0.6, 0.2, 0.2))[[1]]
    hist_text <- if (is.null(hist_arg)) "NULL" else as.character(hist_arg)
    switch(kind,
      create = {
        d <- sample(absent, 1)
        n <- sample(8:25, 1)
        s <- sample.int(1e5, 1)
        note(sprintf("create %s (n = %d, seed = %d, history = %s)%s", d, n, s, hist_text, tag))
        x <- g_sim(n, s)
        synced <- run(function() g_write(st, x, d, "create", history = hist_arg, check = FALSE), fail_at)
        write_model(d, x)
        if (synced) sync_model()
      },
      replace = {
        d <- sample(present, 1)
        n <- sample(8:25, 1)
        s <- sample.int(1e5, 1)
        same <- runif(1) < 0.2
        note(sprintf("replace %s (n = %d, seed = %d, history = %s%s)%s", d, n, s, hist_text,
          if (same) ", same data" else "", tag))
        x <- if (same) model[[1]][[d]] else g_sim(n, s)
        synced <- run(function() g_write(st, x, d, "replace", history = hist_arg, check = FALSE), fail_at)
        write_model(d, x)
        if (synced) sync_model()
      },
      update = {
        d <- sample(present, 1)
        years <- sort(sample(2021:2026, sample(1:2, 1)))
        n <- sample(4:12, 1)
        s <- sample.int(1e5, 1)
        note(sprintf("update %s (years %s, n = %d, seed = %d)%s", d, paste(years, collapse = "+"), n, s, tag))
        x <- g_sim(n, s, years)
        synced <- run(function() g_write(st, x, d, "update", check = FALSE), fail_at)
        old <- model[[1]][[d]]
        write_model(d, rbind(old[!old$year %in% x$year, ], x))
        if (synced) sync_model()
      },
      delete = {
        d <- sample(present, 1)
        note(sprintf("delete %s%s", d, tag))
        synced <- run(function() store_delete(st, d, confirm = d, history = TRUE), fail_at, "repeat")
        for (i in 1:3) model[[i]][[d]] <<- NULL
        if (synced) sync_model()
      },
      copy = {
        d <- sample(present, 1)
        holders <- which(vapply(model, function(m) d %in% names(m), logical(1)))
        from <- if (length(holders) == 1) holders else sample(holders, 1)
        to <- sample(setdiff(1:3, from), 1)
        note(sprintf("copy %s from location %d to location %d%s", d, from, to, tag))
        synced <- run(function() store_copy(st, d, from = paths[[from]], to = paths[[to]]), fail_at, "repeat")
        model[[to]][[d]] <<- model[[from]][[d]]
        if (synced) sync_model()
      },
      sync = {
        note(sprintf("sync%s", tag))
        run(function() store_sync(st), fail_at)
        sync_model()
      },
      prune = {
        keep <- sample(0:2, 1)
        note(sprintf("prune (keep = %d)%s", keep, tag))
        synced <- run(function() store_prune(st, keep = keep), fail_at, "repeat")
        if (synced) sync_model()
      },
      rebuild = {
        i <- sample(1:3, 1)
        note(sprintf("rebuild location %d", i))
        run(function() store_rebuild(st, paths[[i]]))
      },
      history = {
        level <- sample(c("store", "connection"), 1)
        value <- sample(list(NULL, TRUE, FALSE), 1)[[1]]
        if (level == "store") {
          value <- value %||% FALSE
          note(sprintf("store history default = %s", value))
          for (p in paths) store_json_write(g_plain_backend(p), value)
          g_quiet(store_refresh(st))
        } else {
          note(sprintf("reconnect with history = %s", if (is.null(value)) "NULL" else value))
          st <<- g_connect(paths, history = value)
        }
      }
    )
  }

  check <- function() {
    what <- paste0("After step ", length(log), " (", log[[length(log)]], ")")
    if (!isTRUE(g_expect_valid(st, what))) {
      return(FALSE)
    }
    for (i in 1:3) {
      expected <- sort(as.character(names(model[[i]])), method = "radix")
      listed <- g_listed(paths[[i]])
      if (!identical(listed, expected)) {
        testthat::fail(paste0(what, ": location ", i, " lists ", paste(listed, collapse = ", "),
          "; the model has ", paste(expected, collapse = ", ")))
        return(FALSE)
      }
      for (d in expected) {
        got <- tryCatch(g_read_at(paths[[i]], d), error = function(e) e)
        problem <- if (inherits(got, "error")) conditionMessage(got) else g_rows_differ(got, model[[i]][[d]])
        if (!is.null(problem)) {
          testthat::fail(paste0(what, ": ", d, " read from location ", i, " differs from the model: ", problem))
          return(FALSE)
        }
      }
    }
    testthat::succeed()
    TRUE
  }

  withCallingHandlers(
    {
      for (k in seq_len(n_ops)) {
        step()
        if (stopped || !check()) break
      }
    },
    expectation_failure = function(e) failed <<- TRUE
  )
  if (failed || stopped) {
    testthat::fail(paste0(
      "Random-operation sequence failed. Replay: random_sequence(seed = ", seed, ", n_ops = ", n_ops, ")\n",
      "Operations:\n", paste(log, collapse = "\n")
    ))
  }
  invisible(log)
}
