# Streaming against download, cold connect, and the cost of MD5
# verification, on a store in Google Cloud Storage against a local copy of
# the same store.
#
# Builds one local store with 100 datasets (98 small tables, one table of
# 1e6 rows partitioned by year, 1e5 polygons and their index table), copies
# its files unchanged under a random prefix of the test bucket named in
# RCS_TEST_GCS, and times connecting, reading and checking both copies. The
# prefix is removed at the end, also after a failure. Without RCS_TEST_GCS
# the script stops.
#
# The cost of `store_sync()` is not measured: the function does not exist
# yet (work package G).
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder) and RCS_TEST_GCS set:
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>", RCS_TEST_GCS = "gs://<bucket>")
#   source(file.path("<root>", "bench", "cloud.R"))
#
# Results: bench/results/cloud.parquet and bench/results/cloud-counters.parquet.

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "bench", "gargle", "httr2"))
gcs_root <- Sys.getenv("RCS_TEST_GCS", "")
if (!nzchar(gcs_root)) {
  cli::cli_abort("Set {.envvar RCS_TEST_GCS} to a test bucket; this benchmark needs one.")
}
n_table <- 1e6
n_polygons <- 1e5
n_small <- 98
work <- file.path(tempdir(), "rcs-bench-cloud")
unlink(work, recursive = TRUE)
local_root <- file.path(work, "store")
gcs_uri <- paste0(
  sub("/+$", "", gcs_root), "/bench-",
  substr(md5_string(paste(Sys.time(), stats::runif(1))), 1, 10), "/store"
)
options(rcs.quiet = TRUE)
env <- bench_env(storage = "gcs")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- data ----
# The local store, then its files copied one by one to the bucket with the
# package's own upload (`be_put()`), so that every object carries its MD5.
build_stores <- function() {
  st <- store_connect(local_root, create = TRUE)
  for (i in seq_len(n_small)) {
    store_write(st, rcs_sim_table(200, seed = i), sprintf("small/t%03d", i),
      title = sprintf("Small table %d", i), description = "Simulated daily sales, a small sample.",
      key = c("shop_id", "date", "product")
    )
  }
  store_write(st, rcs_sim_table(n_table, seed = 1), "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  store_write(st, rcs_sim_polygons(n_polygons, seed = 1), "shapes/polygons",
    title = "Polygons", description = "Simulated polygons in open ocean."
  )
  local <- be_new(local_root)
  remote <- be_new(gcs_uri)
  listing <- be_list(local)
  for (p in listing$path) {
    with_retry(function() be_put(remote, file.path(local_root, p), p))
  }
  list(datasets = nrow(st$primary$catalog), bytes = sum(listing$bytes), objects = nrow(listing))
}

# ---- connect ----
# Cold: the Arrow file system and the access token are created again (as in
# a new R session); warm: both are reused.
connect_cases <- function() {
  rbind(
    bench_run(connect_local = store_connect(local_root), case = "connect"),
    bench_run(
      connect_gcs_cold = store_connect(gcs_uri), case = "connect", run = "cold",
      setup = quote(gcs_reset_clients())
    ),
    bench_run(connect_gcs_warm = store_connect(gcs_uri), case = "connect")
  )
}

# ---- reads ----
# Streaming: `store_read()` on the bucket. Download: the dataset's files
# fetched whole (`be_get()`) into an empty folder; the local read of the
# copy is timed separately, so download-then-read is the sum of the two.
download <- function(be, paths) {
  for (p in paths) be_get(be, p, file.path(dl_dir, p))
}

read_cases <- function(st_gcs, st_local) {
  be_gcs <- st_gcs$primary$backend
  files <- st_gcs$primary$files
  sales <- files$path[files$dataset == "sales/daily"]
  sales_2025 <- files$path[files$dataset == "sales/daily" & grepl('"year":2025', files$partition_values, fixed = TRUE)]
  polygons <- files$path[files$dataset == "shapes/polygons"]
  fresh <- quote(unlink(dl_dir, recursive = TRUE))
  rbind(
    bench_run(stream = store_read(st_gcs, "sales/daily"), case = "sales full"),
    bench_run(download = download(be_gcs, sales), case = "sales full", setup = fresh),
    bench_run(local = store_read(st_local, "sales/daily"), case = "sales full"),
    bench_run(
      stream = store_read(st_gcs, "sales/daily", year == 2025L, columns = c(shop_id, date, qty)),
      case = "sales year and columns"
    ),
    bench_run(download = download(be_gcs, sales_2025), case = "sales year and columns", setup = fresh),
    bench_run(
      local = store_read(st_local, "sales/daily", year == 2025L, columns = c(shop_id, date, qty)),
      case = "sales year and columns"
    ),
    bench_run(stream = store_read(st_gcs, "shapes/polygons"), case = "polygons full"),
    bench_run(download = download(be_gcs, polygons), case = "polygons full", setup = fresh),
    bench_run(local = store_read(st_local, "shapes/polygons"), case = "polygons full")
  )
}

# ---- md5 ----
# MD5 of the stored files: from object metadata on the bucket, by hashing
# the files locally; and the integrity check, which adds the Parquet footers.
md5_cases <- function(st_gcs, st_local) {
  files <- st_gcs$primary$files
  sales <- files$path[files$dataset == "sales/daily"]
  rbind(
    bench_run(gcs = be_md5(st_gcs$primary$backend, sales), case = "md5 of sales files"),
    bench_run(local = be_md5(st_local$primary$backend, sales), case = "md5 of sales files"),
    bench_run(gcs = store_check(st_gcs, "sales/daily"), case = "check sales"),
    bench_run(local = store_check(st_local, "sales/daily"), case = "check sales")
  )
}

# ---- counters ----
counter_cases <- function(st_gcs, st_local) {
  roles <- c(stats::setNames("gcs", gcs_uri), stats::setNames("local", st_local$primary$uri))
  out <- rbind(
    bench_counters(store_connect(gcs_uri), "connect", "gcs"),
    bench_counters(store_connect(local_root), "connect", "local"),
    bench_counters(store_read(st_gcs, "sales/daily"), "sales full", "gcs"),
    bench_counters(store_read(st_local, "sales/daily"), "sales full", "local"),
    bench_counters(store_read(st_gcs, "sales/daily", year == 2025L, columns = c(shop_id, date, qty)), "sales year and columns", "gcs"),
    bench_counters(store_read(st_local, "sales/daily", year == 2025L, columns = c(shop_id, date, qty)), "sales year and columns", "local"),
    bench_counters(store_check(st_gcs, "sales/daily"), "check sales", "gcs"),
    bench_counters(store_check(st_local, "sales/daily"), "check sales", "local")
  )
  out$location <- unname(roles[out$location])
  out$detail[out$counter == "file_open"] <- NA_character_
  groups <- vctrs::vec_group_loc(out[c("case", "expression", "call", "counter", "detail", "location")])
  agg <- groups$key
  agg$n <- vapply(groups$loc, function(i) sum(out$n[i]), numeric(1))
  agg
}

# ---- run ----
remove_gcs_prefix <- function() {
  be <- be_new(sub("/store$", "", gcs_uri))
  left <- tryCatch(be_list(be), error = function(e) NULL)
  if (!is.null(left) && nrow(left) > 0) be_delete(be, left$path)
  cli::cli_inform("Removed {if (is.null(left)) 0 else nrow(left)} object{?s} under the benchmark prefix.")
}

dl_dir <- file.path(work, "download")
run_all <- function() {
  cli::cli_inform("Building the stores.")
  built <- build_stores()
  st_local <- store_connect(local_root)
  st_gcs <- store_connect(gcs_uri)
  cli::cli_inform("Timing connect.")
  timed <- connect_cases()
  cli::cli_inform("Timing reads.")
  timed <- rbind(timed, read_cases(st_gcs, st_local))
  cli::cli_inform("Timing MD5 and checks.")
  timed <- rbind(timed, md5_cases(st_gcs, st_local))
  counted <- counter_cases(st_gcs, st_local)
  timed$datasets <- built$datasets
  timed$store_bytes <- built$bytes
  timed$store_objects <- built$objects
  sales <- st_local$primary$files[st_local$primary$files$dataset == "sales/daily", ]
  timed$sales_bytes <- sum(sales$bytes)
  timed$sales_files <- nrow(sales)
  list(timed = timed, counted = counted)
}

out <- tryCatch(run_all(), finally = remove_gcs_prefix())
bench_save(out$timed, "cloud", env = env, dir = results_dir)
bench_save(out$counted, "cloud-counters", env = env, dir = results_dir)
unlink(work, recursive = TRUE)
