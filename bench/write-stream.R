# Does a partitioned lazy DuckDB write stay within one partition's memory?
#
# Plan 0004, WP5-B. Writes a synthetic table built inside DuckDB (a generator
# view over `rcs_sim_table()` rows, D-B5: 2e7 rows x id BIGINT + part
# INTEGER + 20 DOUBLE, about 3.5 GB raw) with `key = "id"` and
# `partition = "part"` (32 values, 625k rows and about 110 MB each), under
# caps that are below the whole table and above one partition:
# `memory_limit = '1GB'`, `max_temp_directory_size = '2GB'`, with the temp
# directory in a fresh folder under `tempdir()`. Two runs, each on its own
# fresh connection and its own store under `tempdir()`:
#
#   streamed      the default, one partition at a time
#   materialised  `options(rcs.duckdb_stream = FALSE)`, one copy of the query
#
# DuckDB memory (`duckdb_memory()`) and the size of the temp folder are
# sampled at the start and end of each file write, after every batch of rows
# and before each per-partition table is dropped, by wrapping the package's
# internal functions for the duration of the script (nothing in the package
# is changed). On Windows a PowerShell process also polls the temp folder
# every 250 ms, which catches the spill of a query that fails before any
# sample point.
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "write-stream.R"))
#
# Smaller runs: RCS_BENCH_K (default 2000) sets the rows per base row; keep
# the caps between one partition and the whole table. Results:
# output/tables/bench-write-stream.csv. Takes about 5-10 minutes and needs
# about 8 GB of free disk under `tempdir()`.

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
rlang::check_installed(c("duckdb", "dbplyr"))
out_path <- file.path(root, "output", "tables", "bench-write-stream.csv")

n_base <- 1e4
k <- as.numeric(Sys.getenv("RCS_BENCH_K", "2000"))
parts <- 32L
doubles <- 20L
memory_limit <- "1GB"
spill_cap <- "2GB"
row_bytes <- 8 + 4 + 8 * doubles # raw bytes of one row
work <- file.path(tempdir(), "rcs-bench-write-stream")
dir.create(work, recursive = TRUE, showWarnings = FALSE)
options(rcs.quiet = TRUE)
env <- bench_env(storage = "ssd")

# ---- samples ----
# Every sample: DuckDB memory and temp storage, and the bytes in the temp
# folder of the current run.
sample_state <- new.env()
sample_state$con <- NULL
sample_state$spill_dir <- NULL
sample_state$rows <- list()

dir_bytes <- function(dir) {
  files <- list.files(dir, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
  sum(file.size(files), na.rm = TRUE)
}

take_sample <- function(point) {
  con <- sample_state$con
  if (is.null(con) || !DBI::dbIsValid(con)) {
    return(invisible())
  }
  mem <- tryCatch(
    DBI::dbGetQuery(con, paste(
      "SELECT sum(memory_usage_bytes)::DOUBLE AS m, sum(temporary_storage_bytes)::DOUBLE AS t",
      "FROM duckdb_memory()"
    )),
    error = function(e) data.frame(m = NA_real_, t = NA_real_)
  )
  sample_state$rows[[length(sample_state$rows) + 1L]] <- data.frame(
    point = point, time = Sys.time(), memory = mem$m, temp_storage = mem$t,
    temp_dir = dir_bytes(sample_state$spill_dir)
  )
  invisible()
}

# Wrap internal functions of the package with a sample before and after
# (`when`), restored at the end of the script.
wrapped <- list()
sample_wrap <- function(fn, when) {
  ns <- asNamespace("rcs")
  original <- get(fn, envir = ns)
  wrapped[[fn]] <<- original
  wrapper <- function(...) {
    if ("before" %in% when) take_sample(paste0(fn, ":before"))
    if ("after" %in% when) on.exit(take_sample(paste0(fn, ":after")), add = TRUE)
    original(...)
  }
  if (bindingIsLocked(fn, ns)) unlockBinding(fn, ns)
  assign(fn, wrapper, envir = ns)
}
samples_restore <- function() {
  ns <- asNamespace("rcs")
  for (fn in names(wrapped)) assign(fn, wrapped[[fn]], envir = ns)
}

# The file writer (once per partition when streamed), every batch it
# fetches, the materialised copy, and the drop of a per-partition table
# (after its file and its check).
sample_wrap("duckdb_write_files", c("before", "after"))
sample_wrap("duckdb_progress_add", "after")
sample_wrap("duckdb_materialise", "after")
sample_wrap("duckdb_drop", "before")

# ---- poller ----
# A PowerShell loop writing the largest size of the temp folder seen so far
# to `out`, until `stop` exists. NULL off Windows.
poll_start <- function(dir) {
  if (.Platform$OS.type != "windows") {
    return(NULL)
  }
  p <- list(
    out = file.path(work, paste0("poll-", basename(dirname(dir)), ".txt")),
    stop = file.path(work, paste0("poll-", basename(dirname(dir)), ".stop")),
    script = file.path(work, "poll.ps1")
  )
  writeLines(c(
    "param($dir, $out, $stop)",
    "$max = 0; Set-Content -LiteralPath $out 0",
    "while (-not (Test-Path -LiteralPath $stop)) {",
    "  $s = (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |",
    "    Measure-Object -Property Length -Sum).Sum",
    "  if ($s -gt $max) { $max = $s; Set-Content -LiteralPath $out $max }",
    "  Start-Sleep -Milliseconds 250",
    "}"
  ), p$script)
  system2("powershell", c(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", shQuote(p$script),
    "-dir", shQuote(dir), "-out", shQuote(p$out), "-stop", shQuote(p$stop)
  ), wait = FALSE, stdout = FALSE, stderr = FALSE)
  p
}

poll_stop <- function(p) {
  if (is.null(p)) {
    return(NA_real_)
  }
  file.create(p$stop)
  Sys.sleep(1)
  value <- suppressWarnings(as.numeric(readLines(p$out, warn = FALSE)[1]))
  if (length(value) == 0) NA_real_ else value
}

# ---- data ----
# The generator view of D-B5 on a fresh, capped connection: no stored table,
# so that the data itself does not count against `memory_limit`.
make_connection <- function(spill_dir) {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, paste0("SET memory_limit = '", memory_limit, "'"))
  DBI::dbExecute(con, paste0("SET max_temp_directory_size = '", spill_cap, "'"))
  DBI::dbExecute(con, paste0("SET temp_directory = '", normalizePath(spill_dir, winslash = "/"), "'"))
  base <- as.data.frame(rcs_sim_table(n_base, seed = 1)[c("shop_id", "qty", "price")])
  base$b <- seq_len(nrow(base)) - 1L
  duckdb::duckdb_register(con, "sim_base", base)
  d <- paste0("(price * ", seq_len(doubles), " + r.range * 0.001 + qty)::DOUBLE AS d", seq_len(doubles),
    collapse = ", "
  )
  DBI::dbExecute(con, paste0(
    "CREATE VIEW wide_v AS SELECT (b * ", k, " + r.range)::BIGINT AS id, ",
    "((b * ", k, " + r.range) % ", parts, ")::INTEGER AS part, ", d,
    " FROM sim_base CROSS JOIN range(", k, ") AS r"
  ))
  con
}

# ---- run ----
run_mode <- function(mode) {
  cli::cli_inform("Writing {mode}.")
  run_dir <- file.path(work, mode)
  spill_dir <- file.path(run_dir, "duckdb-temp")
  store_dir <- file.path(run_dir, "store")
  dir.create(spill_dir, recursive = TRUE, showWarnings = FALSE)
  con <- make_connection(spill_dir)
  on.exit({
    DBI::dbDisconnect(con, shutdown = TRUE)
    unlink(run_dir, recursive = TRUE)
  })
  suppressMessages(store_create(store_dir, history = FALSE))
  st <- store_connect(store_dir)
  rows_total <- as.numeric(DBI::dbGetQuery(con, "SELECT count(*)::DOUBLE AS n FROM wide_v")$n)
  largest <- as.numeric(DBI::dbGetQuery(con, paste(
    "SELECT max(n)::DOUBLE AS n FROM (SELECT count(*) AS n FROM wide_v GROUP BY part)"
  ))$n)
  x <- dplyr::tbl(con, "wide_v")

  sample_state$con <- con
  sample_state$spill_dir <- spill_dir
  sample_state$rows <- list()
  old <- options(rcs.duckdb_stream = mode == "streamed")
  poller <- poll_start(spill_dir)
  take_sample("start")
  start <- bench::hires_time()
  result <- tryCatch(
    {
      store_write(st, x, "bench/wide",
        title = "Wide synthetic table", description = "Simulated rows multiplied in DuckDB.",
        key = "id", partition = "part"
      )
      list(status = "ok", error = NA_character_)
    },
    error = function(e) {
      list(status = "failed", error = strsplit(conditionMessage(e), "\n", fixed = TRUE)[[1]][[1]])
    }
  )
  wall <- as.numeric(bench::hires_time() - start)
  take_sample("end")
  polled <- poll_stop(poller)
  options(old)
  sample_state$con <- NULL

  samples <- do.call(rbind, sample_state$rows)
  if (result$status == "ok") {
    st <- store_connect(store_dir)
    written_rows <- as.numeric(st$primary$catalog$rows[st$primary$catalog$dataset == "bench/wide"])
    files <- sum(st$primary$files$dataset == "bench/wide")
  } else {
    written_rows <- NA_real_
    files <- NA_integer_
  }
  peak_memory <- max(samples$memory, na.rm = TRUE)
  peak_dir <- max(c(samples$temp_dir, polled), na.rm = TRUE)
  tibble::tibble(
    mode = mode,
    status = result$status,
    error = result$error,
    wall_s = round(wall, 1),
    rows = rows_total,
    rows_written = written_rows,
    partitions = parts,
    files = files,
    largest_partition_rows = largest,
    largest_partition_bytes = largest * row_bytes,
    table_bytes = rows_total * row_bytes,
    memory_limit = memory_limit,
    spill_cap = spill_cap,
    n_samples = nrow(samples),
    peak_duckdb_memory_bytes = peak_memory,
    peak_duckdb_temp_storage_bytes = max(samples$temp_storage, na.rm = TRUE),
    peak_temp_dir_sampled_bytes = max(samples$temp_dir, na.rm = TRUE),
    peak_temp_dir_polled_bytes = polled,
    peak_memory_plus_spill_bytes = peak_memory + peak_dir,
    peak_over_largest_partition = round((peak_memory + peak_dir) / (largest * row_bytes), 2),
    peak_over_table = round((peak_memory + peak_dir) / (rows_total * row_bytes), 3)
  )
}

out <- tryCatch(
  do.call(rbind, lapply(c("streamed", "materialised"), run_mode)),
  finally = {
    samples_restore()
    unlink(work, recursive = TRUE)
  }
)
out$duckdb_version <- as.character(utils::packageVersion("duckdb"))
out$r_version <- env$r_version
out$cores <- env$cores
out$ram_gb <- env$ram_gb
out$commit <- env$commit
out$date <- format(env$date, "%Y-%m-%d")
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
utils::write.csv(out, out_path, row.names = FALSE, na = "")
cli::cli_inform("Saved {nrow(out)} row{?s} to {.path {out_path}}.")
