# Quick performance check against the stored baseline.
#
# A small version of every benchmark (write, read, spatial, cloud, connect) on 1e5
# rows, in a few minutes. Each measure is timed with `bench_run()` (5
# repetitions, median) and its work counters are taken once with
# `bench_counters()`. The check fails, with an error and so a non-zero exit
# status, when a median time is more than 20% above the baseline or a
# counter is above it. Byte counters may exceed it by 1%: the catalog files
# and manifests a write uploads hold the time of the write, so their
# compressed size varies by a few bytes.
#
# Local only, unless RCS_TEST_GCS names a test bucket: then a write, a
# connect and a read on a store under a random prefix of that bucket are
# added (and the prefix removed at the end). Measures present in only one of
# the baseline and the current run are listed but do not fail the check.
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "quick.R"))
#
# RCS_BENCH_MODE = "baseline" writes bench/results/baseline.parquet instead
# of checking against it.

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "bench"))
mode <- rlang::arg_match0(Sys.getenv("RCS_BENCH_MODE", "check"), c("check", "baseline"))
gcs_root <- Sys.getenv("RCS_TEST_GCS", "")
n <- 1e5
time_tolerance <- 1.2
bytes_tolerance <- 1.01
work <- file.path(tempdir(), "rcs-bench-quick")
unlink(work, recursive = TRUE)
options(rcs.quiet = TRUE, rcs.workers = 1)
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- data ----
sales <- rcs_sim_table(n, seed = 1)
polygons <- rcs_sim_polygons(n, seed = 1)
key <- c("shop_id", "date", "product")
# spatial queries: a cell of resolution 7 and a box of 0.2 degrees
spatial_cell <- as.character(h3o::h3_from_points(sf::st_as_sfc(wk::xy(-27, 7.5, crs = 4326)), 7L))
spatial_box <- sf::st_as_sfc(sf::st_bbox(c(xmin = -27.1, ymin = 7.4, xmax = -26.9, ymax = 7.6), crs = sf::st_crs(4326)))

# Every write goes to a new dataset: `bench_run()` evaluates the expression
# of its first repetition twice.
written <- 0L
write_sales <- function(st) {
  written <<- written + 1L
  store_write(st, sales, sprintf("bench/sales_%03d", written),
    title = "Daily sales", description = "Simulated daily sales.",
    key = key, partition = "year"
  )
}
write_polygons <- function(st) {
  written <<- written + 1L
  store_write(st, polygons, sprintf("bench/polygons_%03d", written),
    title = "Polygons", description = "Simulated polygons in open ocean.",
    partition = "h3"
  )
}

# The store read and connected to: 100 datasets (98 small tables, the
# sales table, the polygons and their index table).
make_store <- function(uri) {
  st <- store_connect(uri, create = TRUE)
  for (i in seq_len(98)) {
    store_write(st, rcs_sim_table(200, seed = i), sprintf("small/t%03d", i),
      title = sprintf("Small table %d", i), description = "Simulated daily sales, a small sample.",
      key = key
    )
  }
  store_write(st, sales, "sales/daily",
    title = "Daily sales", description = "Simulated daily sales.", key = key, partition = "year"
  )
  store_write(st, polygons, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons in open ocean."
  )
  st
}

# ---- measures ----
# Each measure: an expression, timed and counted.
local_measures <- function(st, uri) {
  list(
    write_table = quote(write_sales(st_write)),
    write_polygons = quote(write_polygons(st_write)),
    connect_100 = rlang::expr(store_connect(!!uri)),
    read_full = quote(store_read(st, "sales/daily")),
    read_columns = quote(store_read(st, "sales/daily", columns = c(shop_id, date, qty))),
    read_key = quote(store_read(st, "sales/daily", shop_id == 7L, product == "p07")),
    read_partition = quote(store_read(st, "sales/daily", year == 2024L)),
    read_polygons = quote(store_read(st, "shapes/polygons")),
    read_spatial_cell = quote(store_read(st, "shapes/polygons", intersects = spatial_cell)),
    read_spatial_box = quote(store_read(st, "shapes/polygons", intersects = spatial_box)),
    check_integrity = quote(store_check(st, "sales/daily"))
  )
}

gcs_measures <- function(uri) {
  list(
    gcs_write_table = quote(write_sales(st_gcs_write)),
    gcs_connect = rlang::expr(store_connect(!!uri)),
    gcs_read_full = quote(store_read(st_gcs, "sales/daily")),
    gcs_read_partition = quote(store_read(st_gcs, "sales/daily", year == 2024L))
  )
}

measure <- function(name, expr, eval_env) {
  cli::cli_inform("Measuring {name}.")
  timed <- rlang::inject(bench_run(!!name := !!expr, case = "quick", env = eval_env))
  counted <- bench_counters(eval(expr, eval_env), case = "quick", expression = name)
  totals <- tapply(counted$n, counted$counter, sum)
  rbind(
    tibble::tibble(measure = name, metric = "median_s", kind = "time", value = timed$median_s),
    tibble::tibble(measure = name, metric = names(totals), kind = "counter", value = as.numeric(totals))
  )
}

# ---- run ----
remove_gcs_prefix <- function() {
  if (!exists("gcs_prefix")) {
    return(invisible())
  }
  be <- be_new(gcs_prefix)
  left <- tryCatch(be_list(be), error = function(e) NULL)
  if (!is.null(left) && nrow(left) > 0) be_delete(be, left$path)
}

run_quick <- function() {
  e <- environment()
  st_write <- store_connect(file.path(work, "write"), create = TRUE)
  uri <- file.path(work, "store")
  st <- make_store(uri)
  ms <- local_measures(st, uri)
  out <- lapply(names(ms), function(name) measure(name, ms[[name]], e))
  if (nzchar(gcs_root)) {
    gcs_prefix <<- paste0(sub("/+$", "", gcs_root), "/quick-", substr(md5_string(paste(Sys.time(), stats::runif(1))), 1, 10))
    st_gcs_write <- store_connect(paste0(gcs_prefix, "/write"), create = TRUE)
    gcs_uri <- paste0(gcs_prefix, "/store")
    st_gcs <- store_connect(gcs_uri, create = TRUE)
    store_write(st_gcs, sales, "sales/daily",
      title = "Daily sales", description = "Simulated daily sales.", key = key, partition = "year"
    )
    gm <- gcs_measures(gcs_uri)
    out <- c(out, lapply(names(gm), function(name) measure(name, gm[[name]], e)))
  }
  do.call(rbind, out)
}

current <- tryCatch(run_quick(), finally = remove_gcs_prefix())
unlink(work, recursive = TRUE)

# ---- compare ----
if (mode == "baseline") {
  bench_save(current, "baseline", env = env, dir = results_dir)
} else {
  baseline <- bench_read("baseline", dir = results_dir)
  both <- merge(
    current[c("measure", "metric", "kind", "value")],
    baseline[c("measure", "metric", "value")],
    by = c("measure", "metric"), all = TRUE, suffixes = c("", "_baseline")
  )
  limit <- ifelse(both$kind == "time", time_tolerance * both$value_baseline,
    ifelse(grepl("^bytes_", both$metric), bytes_tolerance * both$value_baseline, both$value_baseline)
  )
  both$ratio <- both$value / both$value_baseline
  both$failed <- !is.na(both$value) & !is.na(limit) & both$value > limit + 1e-12
  print(tibble::as_tibble(both[order(both$measure, both$metric), ]), n = Inf)
  unmatched <- both[is.na(both$value) | is.na(both$value_baseline), ]
  if (nrow(unmatched) > 0) {
    cli::cli_inform(c(i = "Not compared (in one run only): {.val {unique(paste(unmatched$measure, unmatched$metric))}}."))
  }
  bad <- both[both$failed, ]
  if (nrow(bad) > 0) {
    lines <- sprintf("%s %s: %s against %s (x%.2f)", bad$measure, bad$metric, signif(bad$value, 4), signif(bad$value_baseline, 4), bad$ratio)
    cli::cli_abort(c(
      "{nrow(bad)} measure{?s} above the baseline.",
      rlang::set_names(lines, rep("x", length(lines)))
    ))
  }
  cli::cli_inform(c(v = "All {sum(!is.na(both$ratio))} measures within the baseline."))
}
