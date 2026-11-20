# How do time, memory and staging disk grow from 1e5 to 5e6 polygons?
#
# Writes simulated polygons (partition = "h3") and, for comparison, tables
# (partition = "year") of growing size into a local store, one worker. Each
# size runs in a new R process (a mirai daemon) so that its memory can be
# watched from outside: this script samples the daemon's resident memory and
# the size of the staging folder every 0.2 s while the write runs, and reads
# the process's peak working set before and after. Times of the write's
# steps are taken as in `bench/write.R` (internal functions wrapped for the
# duration of the run; the package is not changed).
#
# Peak memory is reported against the size of `x` in memory
# (`object.size()`): the increase of resident memory during the write over
# the memory held just before it.
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "scale.R"))
#
# Sizes: RCS_BENCH_SIZES (default "1e5;5e5;1e6;2e6;5e6") and kinds:
# RCS_BENCH_KINDS (default "polygons;table"). Repetitions: 5 up to 1e6 rows,
# 3 up to 2e6, 1 above (RCS_BENCH_REPS overrides). Results are merged into
# bench/results/scale.parquet: rows of the sizes run replace earlier rows of
# the same kind and size, so sizes can be run in separate sessions.

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "bench", "mirai", "ps"))
sizes <- as.numeric(strsplit(Sys.getenv("RCS_BENCH_SIZES", "1e5;5e5;1e6;2e6;5e6"), ";")[[1]])
kinds <- strsplit(Sys.getenv("RCS_BENCH_KINDS", "polygons;table"), ";")[[1]]
reps_for <- function(n) {
  given <- Sys.getenv("RCS_BENCH_REPS", "")
  if (nzchar(given)) {
    return(as.integer(given))
  }
  if (n <= 1e6) 5L else if (n <= 2e6) 3L else 1L
}
work <- file.path(tempdir(), "rcs-bench-scale")
unlink(work, recursive = TRUE)
dir.create(work, recursive = TRUE)
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- worker ----
# Code run inside the daemon: load the package, wrap the step functions,
# make the data, write once.
worker_code <- quote({
  devtools::load_all(root, quiet = TRUE)
  options(rcs.quiet = TRUE, rcs.workers = 1)
  step_of <- c(
    geo_encode = "geocode", sort_rows = "sort", partition_plan = "sort",
    files_write_parquet = "serialise", md5_file = "hash", check_staged = "check",
    be_put = "upload", be_md5 = "verify", location_refresh = "catalogs",
    location_write = "catalogs", history_read = "catalogs", catalog_token = "catalogs"
  )
  step_state <- new.env()
  step_state$stack <- character()
  step_state$time <- stats::setNames(numeric(length(unique(step_of))), unique(step_of))
  step_wrap <- function(fn, step) {
    original <- get(fn, envir = asNamespace("rcs"))
    force(step)
    function(...) {
      start <- bench::hires_time()
      step_state$stack <- c(step_state$stack, step)
      on.exit({
        took <- bench::hires_time() - start
        depth <- length(step_state$stack)
        step_state$stack <- step_state$stack[-depth]
        step_state$time[[step]] <- step_state$time[[step]] + took
        if (depth > 1) {
          parent <- step_state$stack[[depth - 1]]
          step_state$time[[parent]] <- step_state$time[[parent]] - took
        }
      })
      original(...)
    }
  }
  ns <- asNamespace("rcs")
  for (fn in names(step_of)) {
    if (bindingIsLocked(fn, ns)) unlockBinding(fn, ns)
    assign(fn, step_wrap(fn, step_of[[fn]]), envir = ns)
  }
  make_data <- function(kind, n) {
    start <- bench::hires_time()
    x <<- if (kind == "table") rcs_sim_table(n, seed = 1) else rcs_sim_polygons(n, seed = 1)
    gc()
    list(seconds = as.numeric(bench::hires_time() - start), x_bytes = as.numeric(utils::object.size(x)))
  }
  write_once <- function(kind, store, stage) {
    unlink(c(store, stage), recursive = TRUE)
    dir.create(stage, recursive = TRUE)
    options(rcs.staging_dir = stage)
    st <- store_connect(store, create = TRUE)
    gc()
    step_state$time[] <- 0
    start <- bench::hires_time()
    if (kind == "table") {
      store_write(st, x, "sales/daily",
        title = "Daily sales", description = "Simulated daily sales.",
        key = c("shop_id", "date", "product"), partition = "year",
        max_files = 100L
      )
    } else {
      store_write(st, x, "shapes/polygons",
        title = "Polygons", description = "Simulated polygons in open ocean.",
        partition = "h3"
      )
    }
    seconds <- as.numeric(bench::hires_time() - start)
    files <- st$primary$files
    c(
      list(seconds = seconds, files = nrow(files), store_bytes = sum(as.numeric(files$bytes))),
      stats::setNames(as.list(step_state$time), paste0("step_", names(step_state$time), "_s"))
    )
  }
})

# ---- watch ----
# Wait for a mirai while sampling the daemon's resident memory and the size
# of the staging folder.
folder_bytes <- function(dir) {
  paths <- list.files(dir, recursive = TRUE, full.names = TRUE, all.files = TRUE)
  if (length(paths) == 0) 0 else sum(file.size(paths), na.rm = TRUE)
}

watch <- function(m, handle, stage = NULL) {
  peak_rss <- 0
  peak_stage <- 0
  while (mirai::unresolved(m)) {
    rss <- tryCatch(ps::ps_memory_info(handle)[["rss"]], error = function(e) NA_real_)
    peak_rss <- max(peak_rss, rss, na.rm = TRUE)
    if (!is.null(stage)) peak_stage <- max(peak_stage, folder_bytes(stage))
    Sys.sleep(0.2)
  }
  value <- m$data
  if (mirai::is_error_value(value)) {
    cli::cli_abort("The write failed in the daemon: {as.character(value)}")
  }
  list(value = value, peak_rss = peak_rss, peak_stage = peak_stage)
}

# ---- run ----
run_size <- function(kind, n) {
  # cleanup = FALSE: the data made by one task stay for the next ones
  mirai::daemons(1, dispatcher = FALSE, cleanup = FALSE, .compute = "scale")
  on.exit(mirai::daemons(0, .compute = "scale"))
  ready <- mirai::mirai(
    {
      assign("root", root, envir = globalenv())
      eval(worker_code, globalenv())
      Sys.getpid()
    },
    worker_code = worker_code, root = root, .compute = "scale"
  )[]
  if (mirai::is_error_value(ready)) cli::cli_abort("The daemon did not start: {as.character(ready)}")
  handle <- ps::ps_handle(ready)
  made <- watch(mirai::mirai(make_data(kind, n), kind = kind, n = n, .compute = "scale"), handle)
  rows <- list()
  for (rep in seq_len(reps_for(n))) {
    store <- file.path(work, "store")
    stage <- file.path(work, "stage")
    before <- ps::ps_memory_info(handle)
    w <- watch(
      mirai::mirai(write_once(kind, store, stage), kind = kind, store = store, stage = stage, .compute = "scale"),
      handle, stage
    )
    after <- ps::ps_memory_info(handle)
    rows[[rep]] <- tibble::tibble(
      kind = kind, rows = n, rep = rep, reps = reps_for(n),
      sim_s = made$value$seconds, x_bytes = made$value$x_bytes,
      sim_peak_rss_bytes = made$peak_rss,
      rss_before_bytes = before[["rss"]],
      peak_rss_bytes = w$peak_rss,
      peak_wset_before_bytes = before[["peak_wset"]],
      peak_wset_after_bytes = after[["peak_wset"]],
      staging_peak_bytes = w$peak_stage,
      !!!w$value
    )
    cli::cli_inform("{kind} {format(n, scientific = TRUE)} repetition {rep}: {round(w$value$seconds, 1)} s.")
  }
  unlink(file.path(work, c("store", "stage")), recursive = TRUE)
  do.call(rbind, rows)
}

# Each size is saved as soon as it is done, merged into the stored results:
# rows of earlier runs of other sizes keep their own environment columns.
save_rows <- function(new_rows) {
  new_rows$seconds_per_1e6_rows <- 1e6 * new_rows$seconds / new_rows$rows
  new_rows$rss_increase_bytes <- new_rows$peak_rss_bytes - new_rows$rss_before_bytes
  new_rows$memory_over_x <- new_rows$rss_increase_bytes / new_rows$x_bytes
  path <- file.path(results_dir, "scale.parquet")
  if (!file.exists(path)) {
    return(bench_save(new_rows, "scale", env = env, dir = results_dir))
  }
  tagged <- env
  names(tagged) <- paste0("env_", names(tagged))
  new_rows <- cbind(new_rows, tagged[rep(1L, nrow(new_rows)), ])
  # read without memory mapping: Windows cannot overwrite a mapped file
  old <- tibble::as_tibble(arrow::read_parquet(path, mmap = FALSE))
  old <- old[!paste(old$kind, old$rows) %in% paste(new_rows$kind, new_rows$rows), names(new_rows)]
  out <- rbind(old, new_rows)
  out <- out[order(out$kind, out$rows, out$rep), ]
  arrow::write_parquet(tibble::as_tibble(out), path)
  cli::cli_inform("Saved {nrow(out)} rows to {.path {path}}.")
}

for (kind in kinds) {
  for (n in sizes) {
    if (kind == "table" && !n %in% c(1e5, 1e6, 5e6)) next
    cli::cli_inform("Scale: {kind}, {format(n, scientific = TRUE)} rows.")
    save_rows(run_size(kind, n))
  }
}
unlink(work, recursive = TRUE)
