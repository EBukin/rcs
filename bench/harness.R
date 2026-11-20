# Benchmark harness: one way to time, to read the work counters and to save
# results. Every script in `bench/` starts with
#
#   devtools::load_all()
#   source("bench/harness.R")
#
# and is run from the project root. Results go to
# `bench/results/<name>.parquet` and are committed; the articles in
# `vignettes/articles/` read them and never run a benchmark themselves.
#
#   bench_run()      time expressions, at least 5 repetitions each
#   bench_counters() work counters of one evaluation of an expression
#   bench_env()      where the benchmark ran: versions, hardware, commit
#   bench_save()     write results with the environment attached
#   bench_read()     read stored results
#
# Nothing here records a user name or a machine name.

bench_results_dir <- file.path("bench", "results")

#' Time expressions
#'
#' @param ... Named expressions, timed with `bench::mark()`.
#' @param case One string naming the case (data size, backend, ...); stored
#'   with every row.
#' @param run `"warm"` or `"cold"`. A cold run must start from a state the
#'   script itself prepared (new connection, files not read before); the
#'   harness only records the mark.
#' @param min_iterations At least 5.
#' @param setup Expression evaluated before every iteration, not timed
#'   (quoted, e.g. `quote(st <- connect())`); `NULL` for none.
#' @param env Environment in which the expressions are evaluated.
#' @return A tibble with one row per expression: `case`, `expression`, `run`,
#'   `n` (iterations), `median_s`, `min_s`, `max_s`, `mem_alloc_bytes`,
#'   `gc_per_s`.
bench_run <- function(..., case = NA_character_, run = c("warm", "cold"),
                      min_iterations = 5L, setup = NULL, env = parent.frame()) {
  rlang::check_installed("bench")
  run <- rlang::arg_match(run)
  if (min_iterations < 5) {
    cli::cli_abort("{.arg min_iterations} must be at least 5.")
  }
  exprs <- rlang::exprs(...)
  if (length(exprs) == 0 || !rlang::is_named(exprs)) {
    cli::cli_abort("Give every expression a name.")
  }
  rows <- lapply(names(exprs), function(name) {
    seconds <- numeric(min_iterations)
    memory <- NA_real_
    gc_count <- 0
    for (i in seq_len(min_iterations)) {
      if (!is.null(setup)) {
        eval(setup, env)
      }
      mark <- bench::mark(
        eval(exprs[[name]], env),
        iterations = 1, check = FALSE, filter_gc = FALSE, memory = i == 1
      )
      seconds[[i]] <- as.numeric(mark$median)
      gc_count <- gc_count + mark$n_gc
      if (i == 1) {
        memory <- as.numeric(mark$mem_alloc)
      }
    }
    tibble::tibble(
      case = case,
      expression = name,
      run = run,
      n = as.integer(min_iterations),
      median_s = stats::median(seconds),
      min_s = min(seconds),
      max_s = max(seconds),
      mem_alloc_bytes = memory,
      gc_per_s = gc_count / sum(seconds)
    )
  })
  do.call(rbind, rows)
}

#' Work counters of one evaluation
#'
#' @param expr Expression that calls one exported function of the package.
#' @param case,expression Labels stored with every row.
#' @return The tibble of `rcs::rcs_trace()` with the columns `case` and
#'   `expression` in front.
bench_counters <- function(expr, case = NA_character_, expression = NA_character_) {
  old <- options(rcs.trace = TRUE)
  on.exit(options(old))
  rcs_trace_reset()
  force(expr)
  counters <- rcs_trace()
  rcs_trace_reset()
  tibble::tibble(case = case, expression = expression, counters)
}

bench_first_line <- function(command, args) {
  out <- tryCatch(
    suppressWarnings(system2(command, args, stdout = TRUE, stderr = FALSE)),
    error = function(e) character()
  )
  out <- trimws(out[nzchar(trimws(out))])
  if (length(out) == 0) NA_character_ else out[[length(out)]]
}

bench_cpu <- function() {
  os <- Sys.info()[["sysname"]]
  if (os == "Windows") {
    Sys.getenv("PROCESSOR_IDENTIFIER", NA_character_)
  } else if (os == "Darwin") {
    bench_first_line("sysctl", c("-n", "machdep.cpu.brand_string"))
  } else if (file.exists("/proc/cpuinfo")) {
    lines <- readLines("/proc/cpuinfo", warn = FALSE)
    model <- grep("^model name", lines, value = TRUE)
    if (length(model) == 0) NA_character_ else trimws(sub("^[^:]*:", "", model[[1]]))
  } else {
    NA_character_
  }
}

bench_ram_gb <- function() {
  if (!requireNamespace("ps", quietly = TRUE)) {
    return(NA_real_)
  }
  round(ps::ps_system_memory()[["total"]] / 1024^3, 1)
}

#' Where a benchmark ran
#'
#' @param storage Type of the storage under test, e.g. `"ssd"`, `"hdd"`,
#'   `"gcs"`. It cannot be detected; set it here or in `RCS_BENCH_STORAGE`.
#' @param packages Packages whose versions are recorded.
#' @return A one-row tibble: `date` (UTC), `commit`, `r_version`, `os`,
#'   `cpu`, `cores`, `ram_gb`, `storage` and `packages` (JSON object, name to
#'   version; `null` when not installed). No user name and no machine name.
bench_env <- function(storage = Sys.getenv("RCS_BENCH_STORAGE", NA_character_),
                      packages = c("rcs", "arrow", "sf", "h3o", "h3jsr", "terra", "duckdb", "bit64")) {
  versions <- lapply(stats::setNames(packages, packages), function(package) {
    if (requireNamespace(package, quietly = TRUE)) {
      as.character(utils::packageVersion(package))
    } else {
      NA_character_
    }
  })
  info <- Sys.info()
  tibble::tibble(
    date = as.POSIXct(format(Sys.time(), tz = "UTC"), tz = "UTC"),
    commit = bench_first_line("git", c("rev-parse", "--short", "HEAD")),
    r_version = as.character(getRversion()),
    os = paste(info[["sysname"]], info[["release"]]),
    cpu = bench_cpu(),
    cores = parallel::detectCores(logical = TRUE),
    ram_gb = bench_ram_gb(),
    storage = storage,
    packages = as.character(jsonlite::toJSON(versions, auto_unbox = TRUE, na = "null"))
  )
}

#' Save and read benchmark results
#'
#' @param results A data frame of results (`bench_run()`,
#'   `bench_counters()` or a script's own table).
#' @param name Name of the result set; the file is
#'   `bench/results/<name>.parquet`.
#' @param env The environment row to attach; default `bench_env()`.
#' @param dir Folder of the results.
#' @return `bench_save()`: the path, invisibly; every row carries the columns
#'   of `bench_env()` with the prefix `env_`. `bench_read()`: a tibble.
bench_save <- function(results, name, env = bench_env(), dir = bench_results_dir) {
  if (!grepl("^[a-z0-9-]+$", name)) {
    cli::cli_abort("{.arg name} must use lower-case letters, digits and {.code -}.")
  }
  names(env) <- paste0("env_", names(env))
  out <- cbind(tibble::as_tibble(results), env[rep(1L, nrow(results)), ])
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, paste0(name, ".parquet"))
  arrow::write_parquet(tibble::as_tibble(out), path)
  cli::cli_inform("Saved {nrow(out)} row{?s} to {.path {path}}.")
  invisible(path)
}

bench_read <- function(name, dir = bench_results_dir) {
  path <- file.path(dir, paste0(name, ".parquet"))
  if (!file.exists(path)) {
    cli::cli_abort(c(
      "No stored results named {.val {name}}.",
      i = "Run the benchmark script first; expected {.path {path}}."
    ))
  }
  tibble::as_tibble(arrow::read_parquet(path))
}
