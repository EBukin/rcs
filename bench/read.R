# What does the package add on top of Arrow for full reads, column subsets,
# key filters and partition filters?
#
# Writes simulated data once into a local store, then reads the same files
# three ways: `store_read()`, `arrow::read_parquet()` on each file of the
# catalog's file list, and `arrow::open_dataset()` on that list with dplyr
# verbs. The Arrow reads are given the file paths (taken from the catalog
# before timing) and return Arrow's own R types; `store_read()` also restores
# the recorded R types (integer64, difftime, list columns, factors) and turns
# WKB into `sf`. For polygons a fourth method adds that decoding to the
# Arrow read (`arrow_sf`).
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>")
#   source(file.path("<root>", "bench", "read.R"))
#
# Results: bench/results/read.parquet and bench/results/read-counters.parquet.
# The size can be changed with RCS_BENCH_SIZES (one value, default 1e6).

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- file.path(root, "bench", "results")
rlang::check_installed(c("h3o", "bench"))
n <- as.numeric(strsplit(Sys.getenv("RCS_BENCH_SIZES", "1e6"), ";")[[1]])[[1]]
work <- file.path(tempdir(), "rcs-bench-read")
unlink(work, recursive = TRUE)
options(rcs.quiet = TRUE)
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- data ----
# One table written twice (one file; partitioned by year) and polygons in
# one file, all sorted by the package (tables by key, polygons by h3).
st <- store_connect(work, create = TRUE)
sales <- rcs_sim_table(n, seed = 1)
key <- c("shop_id", "date", "product")
store_write(st, sales, "sales/one",
  title = "Daily sales, one file", description = "Simulated daily sales.", key = key
)
store_write(st, sales, "sales/by_year",
  title = "Daily sales by year", description = "Simulated daily sales.", key = key, partition = "year"
)
store_write(st, rcs_sim_polygons(n, seed = 1), "shapes/polygons",
  title = "Polygons", description = "Simulated polygons in open ocean."
)
rm(sales)
gc()

# Absolute paths of a dataset's files, from the catalog; `year` of each file
# for the partitioned table.
files_of <- function(dataset) {
  rows <- st$primary$files[st$primary$files$dataset == dataset, ]
  file.path(work, rows$path)
}
year_file <- function(dataset, year) {
  rows <- st$primary$files[st$primary$files$dataset == dataset, ]
  keep <- grepl(paste0('"year":', year), rows$partition_values, fixed = TRUE)
  file.path(work, rows$path[keep])
}
polygon_crs <- sf::st_crs(st$primary$catalog$crs[st$primary$catalog$dataset == "shapes/polygons"])

# ---- arrow ----
# Arrow only: each file read whole and bound, or one dataset over the list.
read_files <- function(paths, ...) {
  parts <- lapply(paths, function(p) arrow::read_parquet(p, ...))
  if (length(parts) == 1) parts[[1]] else vctrs::vec_rbind(!!!parts)
}
open_files <- function(paths) arrow::open_dataset(paths, format = "parquet")
as_sf <- function(data) {
  data$geometry <- sf::st_as_sfc(structure(data$geometry, class = "WKB"), crs = polygon_crs)
  sf::st_as_sf(data)
}

# ---- operations ----
# Each operation as the three (or four) methods; same rows, same columns.
operations <- function(dataset) {
  paths <- files_of(dataset)
  ops <- list(
    full = list(
      store = quote(store_read(st, dataset)),
      arrow_read_parquet = quote(read_files(paths)),
      arrow_open_dataset = quote(dplyr::collect(open_files(paths)))
    ),
    columns = list(
      store = quote(store_read(st, dataset, columns = c(shop_id, date, qty))),
      arrow_read_parquet = quote(read_files(paths, col_select = c("shop_id", "date", "qty"))),
      arrow_open_dataset = quote(dplyr::collect(dplyr::select(open_files(paths), shop_id, date, qty)))
    ),
    key_filter = list(
      store = quote(store_read(st, dataset, shop_id == 7L, product == "p07")),
      arrow_read_parquet = quote(local({
        d <- read_files(paths)
        d[d$shop_id == 7L & d$product == "p07", ]
      })),
      arrow_open_dataset = quote(dplyr::collect(dplyr::filter(open_files(paths), shop_id == 7L, product == "p07")))
    ),
    partition_filter = list(
      store = quote(store_read(st, dataset, year == 2025L)),
      # with the catalog's file list, Arrow alone reads only the file of
      # that year when there is one; otherwise it reads all and filters
      arrow_read_parquet = quote(local({
        one <- year_file(dataset, 2025L)
        if (length(one) == 1) {
          read_files(one)
        } else {
          d <- read_files(paths)
          d[d$year == 2025L, ]
        }
      })),
      arrow_open_dataset = quote(dplyr::collect(dplyr::filter(open_files(paths), year == 2025L)))
    )
  )
  if (dataset == "shapes/polygons") {
    ops <- list(
      full = list(
        store = quote(store_read(st, dataset)),
        arrow_read_parquet = quote(read_files(paths)),
        arrow_open_dataset = quote(dplyr::collect(open_files(paths))),
        arrow_sf = quote(as_sf(read_files(paths)))
      ),
      no_geometry = list(
        store = quote(store_read(st, dataset, geometry = FALSE)),
        arrow_read_parquet = quote(read_files(paths, col_select = -geometry)),
        arrow_open_dataset = quote(dplyr::collect(dplyr::select(open_files(paths), -geometry)))
      ),
      columns = list(
        store = quote(store_read(st, dataset, columns = c(id, area), geometry = FALSE)),
        arrow_read_parquet = quote(read_files(paths, col_select = c("id", "area"))),
        arrow_open_dataset = quote(dplyr::collect(dplyr::select(open_files(paths), id, area)))
      )
    )
  }
  list(paths = paths, ops = ops)
}

# ---- run ----
timed <- list()
counted <- list()
for (dataset in c("sales/one", "sales/by_year", "shapes/polygons")) {
  spec <- operations(dataset)
  paths <- spec$paths
  for (operation in names(spec$ops)) {
    case <- paste(dataset, operation)
    cli::cli_inform("Timing {case}.")
    methods <- spec$ops[[operation]]
    for (method in names(methods)) {
      expr <- methods[[method]]
      rows <- nrow(eval(expr))
      row <- rlang::inject(bench_run(!!method := !!expr, case = case))
      row$dataset <- dataset
      row$operation <- operation
      row$method <- method
      row$rows_returned <- rows
      row$files <- length(paths)
      timed[[paste(case, method)]] <- row
    }
    counters <- bench_counters(eval(methods$store), case = case, expression = "store")
    counters$location <- ifelse(is.na(counters$location), NA_character_, "primary")
    counters$detail[counters$counter == "file_open"] <- NA_character_
    groups <- vctrs::vec_group_loc(counters[c("case", "expression", "call", "counter", "detail", "location")])
    agg <- groups$key
    agg$n <- vapply(groups$loc, function(i) sum(counters$n[i]), numeric(1))
    counted[[case]] <- agg
  }
}
timed <- do.call(rbind, timed)
timed$rows <- n
bench_save(timed, "read", env = env, dir = results_dir)
bench_save(do.call(rbind, counted), "read-counters", env = env, dir = results_dir)
unlink(work, recursive = TRUE)
