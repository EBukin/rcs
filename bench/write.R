# Where does write time go: geocode, sort, serialise, check, upload, verify?
#
# Times `store_write()` of simulated tables and polygons, 1e5 and 1e6 rows,
# with 1 and 4 geocoding workers (`options(rcs.workers = )`), into a local
# store and, when RCS_TEST_GCS is set, into a store in a test bucket (1e5
# rows only, so that the uploads stay small). Each repetition writes into a
# new, empty store. The time of each step is taken by wrapping the package's
# internal step functions for the duration of the script (self time: a step
# called inside another step is not counted twice); nothing in the package is
# changed.
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "write.R"))
#
# Results: bench/results/write.parquet (times and steps) and
# bench/results/write-counters.parquet. Sizes can be narrowed with
# RCS_BENCH_SIZES (e.g. "1e5").

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "bench", "mirai"))
sizes <- as.numeric(strsplit(Sys.getenv("RCS_BENCH_SIZES", "1e5;1e6"), ";")[[1]])
gcs_root <- Sys.getenv("RCS_TEST_GCS", "")
work <- file.path(tempdir(), "rcs-bench-write")
dir.create(work, recursive = TRUE, showWarnings = FALSE)
options(rcs.quiet = TRUE)
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- steps ----
# Internal functions and the step of `store_write()` they belong to. What is
# left of the total is "other": argument checks, catalog entries, manifests.
step_of <- c(
  geo_encode = "geocode",
  sort_rows = "sort", partition_plan = "sort",
  files_write_parquet = "serialise",
  md5_file = "hash",
  check_staged = "check",
  be_put = "upload",
  be_md5 = "verify",
  location_refresh = "catalogs", location_write = "catalogs",
  history_read = "catalogs", catalog_token = "catalogs"
)
steps <- unique(step_of)
step_state <- new.env()
step_state$stack <- character()
step_state$time <- stats::setNames(numeric(length(steps)), steps)
step_state$runs <- list()

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

steps_install <- function() {
  ns <- asNamespace("rcs")
  for (fn in names(step_of)) {
    if (bindingIsLocked(fn, ns)) unlockBinding(fn, ns)
    assign(fn, step_wrap(fn, step_of[[fn]]), envir = ns)
  }
}

# Close the step times of one repetition and start the next.
steps_flush <- function() {
  if (any(step_state$time != 0)) {
    step_state$runs[[length(step_state$runs) + 1L]] <- step_state$time
  }
  step_state$time[] <- 0
}

# Median seconds of each step over the repetitions flushed so far.
steps_median <- function() {
  runs <- do.call(rbind, step_state$runs)
  step_state$runs <- list()
  out <- apply(runs, 2, stats::median)
  stats::setNames(as.list(out), paste0("step_", names(out), "_s"))
}

steps_install()

# ---- data ----
make_data <- function(kind, n) {
  if (kind == "table") rcs_sim_table(n, seed = 1) else rcs_sim_polygons(n, seed = 1)
}

# A new, empty store for every repetition.
counter <- 0L
new_store <- function(location) {
  counter <<- counter + 1L
  name <- sprintf("store-%03d", counter)
  uri <- if (location == "local") file.path(work, name) else paste0(gcs_prefix, "/write/", name)
  store_connect(uri, create = TRUE)
}

# Every call writes a new dataset: `bench_run()` evaluates the expression of
# its first repetition twice (once to measure memory), into the same store.
written <- 0L
write_one <- function(st, x, kind) {
  written <<- written + 1L
  if (kind == "table") {
    store_write(st, x, sprintf("sales/daily_%03d", written),
      title = "Daily sales", description = "Simulated daily sales.",
      key = c("shop_id", "date", "product"), partition = "year"
    )
  } else {
    store_write(st, x, sprintf("shapes/polygons_%03d", written),
      title = "Polygons", description = "Simulated polygons in open ocean.",
      partition = "h3"
    )
  }
}

# Locations of a trace as roles, so that no local path is stored.
counters_tidy <- function(counters, st) {
  role <- ifelse(counters$location %in% st$primary$uri, "primary",
    ifelse(is.na(counters$location), NA_character_, "staging")
  )
  counters$location <- role
  counters$detail[counters$counter == "file_open"] <- NA_character_
  groups <- vctrs::vec_group_loc(counters[c("case", "expression", "call", "counter", "detail", "location")])
  out <- groups$key
  out$n <- vapply(groups$loc, function(i) sum(counters$n[i]), numeric(1))
  out
}

# ---- workers ----
# Four local mirai daemons for the geocoding, started once; each loads the
# package from the root, because it is not installed.
start_workers <- function(workers) {
  mirai::daemons(workers, .compute = "rcs")
  mirai::everywhere(pkgload::load_all(root, quiet = TRUE), root = root, .compute = "rcs")
  for (i in 1:120) {
    ready <- mirai::mirai_map(seq_len(2 * workers), function(i) isNamespaceLoaded("rcs"), .compute = "rcs")[]
    if (all(unlist(ready))) break
    Sys.sleep(1)
  }
}

# ---- run ----
cases <- expand.grid(
  kind = c("table", "polygons"), n = sizes, location = "local", workers = c(1L, 4L),
  stringsAsFactors = FALSE
)
cases <- cases[!(cases$kind == "table" & cases$workers == 4L), ]
if (nzchar(gcs_root)) {
  gcs_prefix <- paste0(sub("/+$", "", gcs_root), "/bench-", substr(md5_string(paste(Sys.time(), stats::runif(1))), 1, 10))
  cases <- rbind(cases, data.frame(kind = c("table", "polygons"), n = 1e5, location = "gcs", workers = 1L))
}
cases <- cases[cases$n %in% sizes, ]

run_cases <- function() {
  timed <- list()
  counted <- list()
  for (kind in unique(cases$kind)) {
    for (n in unique(cases$n[cases$kind == kind])) {
      x <- make_data(kind, n)
      x_bytes <- as.numeric(utils::object.size(x))
      todo <- cases[cases$kind == kind & cases$n == n, ]
      for (i in seq_len(nrow(todo))) {
        location <- todo$location[[i]]
        workers <- todo$workers[[i]]
        case <- paste(kind, format(n, scientific = TRUE), location, paste0("w", workers), sep = "-")
        cli::cli_inform("Timing {case}.")
        if (workers > 1) start_workers(workers)
        options(rcs.workers = workers)
        step_state$time[] <- 0
        step_state$runs <- list()
        row <- bench_run(
          write = write_one(st, x, kind),
          case = case,
          setup = quote({
            steps_flush()
            st <- new_store(location)
            step_state$time[] <- 0
          })
        )
        steps_flush()
        row <- cbind(row, tibble::as_tibble(steps_median()))
        row$kind <- kind
        row$rows <- n
        row$location <- location
        row$workers <- workers
        row$x_bytes <- x_bytes
        if (workers == 1) {
          st <- new_store(location)
          counters <- bench_counters(write_one(st, x, kind), case = case, expression = "write")
          row$bytes_written <- sum(counters$n[counters$counter == "bytes_up"])
          counted[[case]] <- counters_tidy(counters, st)
        } else {
          row$bytes_written <- NA_real_
        }
        timed[[case]] <- row
        options(rcs.workers = 1)
        if (workers > 1) mirai::daemons(0, .compute = "rcs")
        unlink(list.files(work, full.names = TRUE), recursive = TRUE)
      }
      rm(x)
      gc()
    }
  }
  list(timed = do.call(rbind, timed), counted = do.call(rbind, counted))
}

remove_gcs_prefix <- function() {
  if (!exists("gcs_prefix")) {
    return(invisible())
  }
  be <- be_new(gcs_prefix)
  left <- be_list(be)
  if (nrow(left) > 0) be_delete(be, left$path)
  cli::cli_inform("Removed {nrow(left)} object{?s} under the benchmark prefix.")
}

out <- tryCatch(run_cases(), finally = remove_gcs_prefix())
out$timed$rows_per_s <- out$timed$rows / out$timed$median_s
bench_save(out$timed, "write", env = env, dir = results_dir)
bench_save(out$counted, "write-counters", env = env, dir = results_dir)
unlink(work, recursive = TRUE)
