# Which steps of the spatial filter pay off (file pruning, cell filter,
# index table, bbox pushdown, exact test), at which `h3_res`, row-group size
# and sort order?
#
# Writes simulated polygons in several layouts (one file or `partition =
# "h3"`; `h3_res` 4, 5, 6; 2e4, 5e4 or 1e5 rows per row group; rows sorted by
# `h3` and then as written, or by `h3` and then a finer cell) and runs the
# same queries on each: H3 cells of resolutions 3 to 9 and polygons of three
# sizes, five of each. Every query is run in several variants, built from
# the package's own internal steps with one or more steps left out, and
# against three comparisons: the bbox struct alone (the variant
# `bbox_only`), DuckDB spatial on the same files, and reading everything
# followed by `sf::st_filter()`.
#
# For each layout:
#
#   * counters: for every combination of file pruning (on, off) and row
#     filter (none, bbox, cells, cells with the index table, cells and bbox,
#     cells with the index table and bbox), the files opened, the row groups
#     whose statistics overlap the filter, and the candidate rows; each
#     candidate set is compared with the exact answer, so a combination that
#     loses rows is marked incomplete;
#   * times: the variants of `variants` below, each query type timed with
#     `bench_run()`, one query instance per repetition (the first one run
#     twice), so the median is over the five instances;
#   * DuckDB and read-all-then-filter, with their rows compared with the
#     package's result.
#
# A layout with `gcs = TRUE` in RCS_BENCH_GCS is also copied with
# `store_sync()` to a random prefix of the bucket named in RCS_TEST_GCS and
# timed there cold (a new connection and new cloud clients before every
# query); the prefix is removed at the end, also after a failure.
#
# Run in a fresh R session, with the project root in RCS_BENCH_ROOT (default:
# the working folder), one size per session (a write of 5e6 polygons needs
# about 10 GiB):
#
#   Sys.setenv(RCS_BENCH_ROOT = "<root>", RCS_BENCH_SIZES = "1e6")
#   source(file.path("<root>", "bench", "spatial.R"))
#
# RCS_BENCH_SIZES: one size (default 1e6). RCS_BENCH_LAYOUTS: layouts to
# run, separated by `;` (default: all of `layouts` for 1e6, `base;part` for
# larger sizes). RCS_BENCH_GCS: layouts also timed on GCS (default none).
# RCS_BENCH_VARIANTS: variants timed on `base` and `part` (default all).
# RCS_BENCH_GCS_VARIANTS and RCS_BENCH_GCS_QUERIES: variants and query types
# timed on GCS (defaults: `gcs_variants` below and all query types).
# RCS_BENCH_RESULTS: another results folder (for a trial run).
# Results are merged into bench/results/spatial.parquet (times),
# spatial-counters.parquet and spatial-layouts.parquet: rows of the layouts
# run replace earlier rows of the same size and layout.

# ---- setup ----
root <- normalizePath(Sys.getenv("RCS_BENCH_ROOT", "."), winslash = "/")
devtools::load_all(root, quiet = TRUE)
source(file.path(root, "bench", "harness.R"))
results_dir <- Sys.getenv("RCS_BENCH_RESULTS", file.path(root, "bench", "results"))
rlang::check_installed(c("h3o", "bench", "duckdb", "DBI"))
n <- as.numeric(Sys.getenv("RCS_BENCH_SIZES", "1e6"))
gcs_root <- Sys.getenv("RCS_TEST_GCS", "")
work <- file.path(tempdir(), "rcs-bench-spatial")
unlink(work, recursive = TRUE)
dir.create(work, recursive = TRUE)
options(rcs.quiet = TRUE, rcs.workers = 1)
sf::sf_use_s2(TRUE)
dataset <- "shapes/polygons"
instances <- 5L
env <- bench_env(storage = "ssd")
env$commit <- tryCatch(
  system2("git", c("-C", root, "rev-parse", "--short", "HEAD"), stdout = TRUE),
  error = function(e) NA_character_
)

# ---- layouts ----
# `sort = "fine"`: inside each `h3` cell, rows are ordered by the cell of
# their box centre at `h3_res + 3` (see `fine_sort()`).
layouts <- tibble::tribble(
  ~layout,        ~partition, ~h3_res, ~rows_per_group, ~sort,
  "base",         FALSE,      5L,      50000L,          "h3",
  "part",         TRUE,       5L,      50000L,          "h3",
  "res4",         FALSE,      4L,      50000L,          "h3",
  "res4_part",    TRUE,       4L,      50000L,          "h3",
  "res6",         FALSE,      6L,      50000L,          "h3",
  "res6_part",    TRUE,       6L,      50000L,          "h3",
  "rg2e4",        FALSE,      5L,      20000L,          "h3",
  "rg1e5",        FALSE,      5L,      100000L,         "h3",
  "fine",         FALSE,      5L,      50000L,          "fine"
)
# res4_part and res6_part are not run by default: the partition resolution
# is the finest at or below `h3_res` with at most `max_files` files, the
# same for `h3_res` 4, 5 and 6 on these data, so the files are those of
# `part`
default_layouts <- if (n <= 1e6) c("base", "part", "res4", "res6", "rg2e4", "rg1e5", "fine") else c("base", "part")
chosen <- strsplit(Sys.getenv("RCS_BENCH_LAYOUTS", paste(default_layouts, collapse = ";")), ";")[[1]]
on_gcs <- strsplit(Sys.getenv("RCS_BENCH_GCS", ""), ";")[[1]]
if (length(on_gcs) > 0 && !nzchar(gcs_root)) {
  cli::cli_abort("Set {.envvar RCS_TEST_GCS} to time layouts on GCS.")
}

# Written order with a finer cell inside `h3`: wraps `geo_encode()` for the
# duration of one write. The rows are put in the order (h3, cell of the box
# centre at h3_res + 3, previous order); `.rcs_id` is given again in that
# order and the index rows follow their rows. The finer cell is only a sort
# key; nothing about it is stored.
fine_sort <- function(encoded, h3_res) {
  data <- encoded$data
  box <- data$bbox
  cx <- (box$xmin + box$xmax) / 2
  cy <- (box$ymin + box$ymax) / 2
  fine <- rep(bit64::NA_integer64_, nrow(data))
  ok <- !is.na(cx)
  if (any(ok)) {
    points <- sf::st_as_sfc(wk::xy(cx[ok], cy[ok], crs = 4326))
    fine[ok] <- h3_as_int64(h3o::h3_from_points(points, min(15L, h3_res + 3L)))
  }
  order <- vctrs::vec_order(
    data.frame(h3 = as.character(data$h3), fine = as.character(fine), row = seq_len(nrow(data))),
    na_value = "largest"
  )
  # the cells of one resolution have the same number of digits, so their
  # decimal strings sort like the integers
  first <- min(data$.rcs_id)
  old_ids <- data$.rcs_id[order]
  data <- data[order, , drop = FALSE]
  data$.rcs_id <- first + bit64::as.integer64(seq_len(nrow(data)) - 1L)
  if (!is.null(encoded$index) && nrow(encoded$index) > 0) {
    index <- encoded$index
    index$.rcs_id <- data$.rcs_id[match(as.character(index$.rcs_id), as.character(old_ids))]
    index <- index[order(as.character(index$h3), as.numeric(index$.rcs_id)), , drop = FALSE]
    encoded$index <- index
  }
  encoded$data <- data
  encoded
}

with_fine_sort <- function(code) {
  ns <- asNamespace("rcs")
  original <- get("geo_encode", envir = ns)
  wrapped <- function(x, h3_res = 5L, ...) fine_sort(original(x, h3_res = h3_res, ...), h3_res)
  unlockBinding("geo_encode", ns)
  assign("geo_encode", wrapped, envir = ns)
  on.exit({
    assign("geo_encode", original, envir = ns)
    lockBinding("geo_encode", ns)
  })
  force(code)
}

# ---- queries ----
# Five instances of each query type, the same for every layout of a size.
# Cells are given as hex strings; polygons are irregular 16-gons around a
# random centre, radius about 0.01, 0.1 or 0.5 degrees.
make_queries <- function(seed = 7) {
  withr::with_seed(seed, {
    out <- list()
    for (res in 3:9) {
      x <- stats::runif(instances, -29.9, -24.1)
      y <- stats::runif(instances, 6.1, 8.9)
      cells <- h3o::h3_from_points(sf::st_as_sfc(wk::xy(x, y, crs = 4326)), res)
      out[[paste0("cell", res)]] <- as.list(as.character(cells))
    }
    for (size in c(small = 0.01, medium = 0.1, large = 0.5)) {
      shapes <- lapply(seq_len(instances), function(i) {
        cx <- stats::runif(1, -29.4, -24.6)
        cy <- stats::runif(1, 6.6, 8.4)
        a <- sort(stats::runif(16, 0, 2 * pi))
        r <- size * stats::runif(16, 0.6, 1)
        xy <- cbind(cx + r * cos(a), cy + r * sin(a))
        sf::st_sfc(sf::st_polygon(list(rbind(xy, xy[1, ]))), crs = 4326)
      })
      out[[paste0("poly_", names(which(c(small = 0.01, medium = 0.1, large = 0.5) == size)))]] <- shapes
    }
    # diagonal strips 2 degrees long, 0.01 (strip) or 0.2 (band) degrees
    # wide, whose box is much larger than the shape; added after the first
    # runs at 1e6 rows
    strip <- function(half_width) {
      lapply(seq_len(instances), function(i) {
        cx <- stats::runif(1, -28, -26)
        cy <- stats::runif(1, 7, 8)
        a <- stats::runif(1, pi / 8, 3 * pi / 8)
        along <- c(cos(a), sin(a))
        across <- c(-sin(a), cos(a))
        w <- half_width * across
        corners <- rbind(c(cx, cy) - along - w, c(cx, cy) + along - w, c(cx, cy) + along + w, c(cx, cy) - along + w)
        sf::st_sfc(sf::st_polygon(list(rbind(corners, corners[1, ]))), crs = 4326)
      })
    }
    if (strips) {
      out$poly_strip <- strip(0.005)
      out$poly_band <- strip(0.1)
    }
    out
  })
}
strips <- n > 1e6 || nzchar(Sys.getenv("RCS_BENCH_STRIPS"))
queries <- make_queries()
query_types <- names(queries)
# The query shapes as the package tests them (cell polygons; polygons as
# given), in EPSG:4326, for the comparisons.
query_shape <- function(y) geo_covering(y, 5L, sf::st_crs(4326)$wkt)$shape
shapes <- lapply(queries, lapply, query_shape)

# ---- variants ----
# The steps of the spatial filter, each switched on or off. `prune`: drop
# files by their box (and, with cells, their h3 range); `cells`: the cell
# test on `h3`; `index`: add the rows of the index table (`.rcs_id`);
# `bbox`: the box test pushed into the scan; `exact`: `sf::st_intersects()`
# in `collect()`. `default` is `store_read(intersects = )` itself; until
# this benchmark it was `cells_index_bbox` for every query, since then it is
# `bbox_only` unless the query's box is much larger than the query (see
# `spatial_use_cells()`); the column `default_rule` of the results says
# which ("box first" since the change, missing before).
flags <- function(prune, cells, index, bbox, exact = TRUE) {
  list(prune = prune, cells = cells, index = index, bbox = bbox, exact = exact)
}
variants <- list(
  default = NULL,
  cells_index_bbox = flags(TRUE, TRUE, TRUE, TRUE),
  no_bbox = flags(TRUE, TRUE, TRUE, FALSE),
  no_prune = flags(FALSE, TRUE, TRUE, TRUE),
  no_index = flags(TRUE, TRUE, FALSE, TRUE),
  candidates = flags(TRUE, TRUE, TRUE, TRUE, exact = FALSE),
  bbox_only = flags(TRUE, FALSE, FALSE, TRUE),
  bbox_no_prune = flags(FALSE, FALSE, FALSE, TRUE),
  cells_only = flags(FALSE, TRUE, TRUE, FALSE),
  prune_only = flags(TRUE, FALSE, FALSE, FALSE)
)
gcs_variants <- strsplit(Sys.getenv("RCS_BENCH_GCS_VARIANTS", "default;cells_index_bbox;no_prune;bbox_only"), ";")[[1]]
# Layouts other than `base` and `part` are timed in these variants only.
short_variants <- c("default", "cells_index_bbox", "bbox_only")
# Variants timed on `base` and `part`: RCS_BENCH_VARIANTS (default all; at
# 5e6 rows fewer, see the article).
full_variants <- strsplit(Sys.getenv("RCS_BENCH_VARIANTS", paste(names(variants), collapse = ";")), ";")[[1]]

# Combinations whose counters are taken: file pruning by row filter.
row_filters <- list(
  none = c(cells = FALSE, index = FALSE, bbox = FALSE),
  bbox = c(cells = FALSE, index = FALSE, bbox = TRUE),
  cells = c(cells = TRUE, index = FALSE, bbox = FALSE),
  cells_index = c(cells = TRUE, index = TRUE, bbox = FALSE),
  cells_bbox = c(cells = TRUE, index = FALSE, bbox = TRUE),
  cells_index_bbox = c(cells = TRUE, index = TRUE, bbox = TRUE)
)

# One query in one variant, from the package's internal steps (the same
# functions `store_read()` uses). Returns what `store_read()` returns; with
# `ids_only` the column `id` of the candidate rows, without geometry.
run_variant <- function(st, y, v, ids_only = FALSE) {
  if (is.null(v)) {
    return(store_read(st, dataset, intersects = y))
  }
  target <- read_target(st, dataset)
  entry <- target$entry
  location <- target$location
  covering <- geo_covering(y, entry$h3_res, entry$crs)
  cells <- if (v$cells) covering$cells
  ids <- NULL
  if (v$cells && v$index) {
    ids <- spatial_index_rows(c(list(store = st), target[c("entry", "location", "files")]), cells)
  }
  test <- list(
    shape = covering$shape, exact = v$exact && !ids_only, bbox = if (v$bbox) covering$bbox,
    cells = cells, ids = ids$.rcs_id, geographic = TRUE
  )
  files <- target$files
  if (v$prune) {
    by <- list(bbox = covering$bbox, cells = cells, geographic = TRUE)
    files <- files[spatial_keep_files(files, by, ids$h3_main), ]
  }
  schema <- if (nrow(files) == 0) query_open_files(location, target$files$path[[1]])$schema
  source <- query_open_files(location, files$path, schema = schema)
  q <- new_query(st, entry, location, files, dplyr::select(source, dplyr::everything()))
  predicate <- spatial_predicate(test)
  if (!is.null(predicate)) q <- query_bottom_filter(q, predicate)
  q$spatial <- list(tests = list(test), cells = length(cells), index = length(ids) > 0)
  if (ids_only) {
    q$geometry <- FALSE
    q$query <- dplyr::select(q$query, "id")
  }
  query_collect(q)
}

# ---- comparisons ----
duckdb_sql <- function(paths, shape) {
  b <- sf::st_bbox(shape)
  wkt <- sf::st_as_text(sf::st_geometry(shape)[[1]])
  sprintf(
    paste(
      "SELECT id, area, cat, h3, bbox, ST_AsWKB(geometry) AS geometry",
      "FROM read_parquet([%s])",
      "WHERE bbox.xmin <= %.17g AND bbox.xmax >= %.17g AND bbox.ymin <= %.17g AND bbox.ymax >= %.17g",
      "AND ST_Intersects(geometry, ST_GeomFromText('%s'))"
    ),
    paste0("'", paths, "'", collapse = ", "), b[["xmax"]], b[["xmin"]], b[["ymax"]], b[["ymin"]], wkt
  )
}

# ---- helpers ----
# The counter `row_groups_overlap` reads the `h3`, `.rcs_id` and `bbox`
# values of every row group for every query; here each row group is read
# once per file and reduced to three rows (the minima, the maxima and the
# widest box), which give the same answer in `row_group_overlaps()`.
overlap_cache <- new.env()
row_group_stats <- function(fs, path) {
  key <- paste0(fs$path, "/", path)
  if (!is.null(overlap_cache[[key]])) {
    return(overlap_cache[[key]])
  }
  file <- fs$fs$OpenInputFile(key)
  on.exit(file$close())
  reader <- arrow::ParquetFileReader$create(file)
  schema <- reader$GetSchema()
  columns <- intersect(c("h3", ".rcs_id", "bbox"), names(schema))
  leaves <- parquet_leaf_indices(schema, columns)
  low <- function(v) if (all(is.na(v))) v[1] else min(v, na.rm = TRUE)
  high <- function(v) if (all(is.na(v))) v[1] else max(v, na.rm = TRUE)
  out <- lapply(seq_len(reader$num_row_groups) - 1L, function(g) {
    s <- withr::with_options(list(arrow.int64_downcast = FALSE), as.data.frame(reader$ReadRowGroup(g, leaves)))
    widest <- which.max(s$bbox$xmax - s$bbox$xmin)
    if (length(widest) == 0) widest <- 1L
    three <- s[c(1L, 1L, widest), , drop = FALSE]
    for (col in setdiff(names(s), "bbox")) {
      three[[col]][1:2] <- c(low(s[[col]]), high(s[[col]]))
    }
    for (col in names(s$bbox)) {
      three$bbox[[col]][1:2] <- c(low(s$bbox[[col]]), high(s$bbox[[col]]))
    }
    three
  })
  overlap_cache[[key]] <- out
  out
}
cached_overlap <- function(q) {
  fs <- be_arrow_fs(q$location$backend)
  tests <- q$spatial$tests
  total <- 0
  for (path in q$files$path) {
    for (stats in row_group_stats(fs, path)) {
      if (all(vapply(tests, row_group_overlaps, logical(1), stats = stats))) total <- total + 1
    }
  }
  total
}
local({
  ns <- asNamespace("rcs")
  unlockBinding("spatial_row_groups_overlap", ns)
  assign("spatial_row_groups_overlap", cached_overlap, envir = ns)
})

counters_of <- function(st, y, v) {
  out <- NULL
  counters <- bench_counters(out <- run_variant(st, y, v, ids_only = TRUE))
  n_of <- function(counter, pattern = NULL) {
    keep <- counters$counter == counter
    if (!is.null(pattern)) keep <- keep & grepl(pattern, counters$detail)
    sum(counters$n[keep])
  }
  list(
    ids = out$id,
    files_data = n_of("file_open", "^shapes/polygons/"),
    files_index = n_of("file_open", "__h3/"),
    row_groups_total = n_of("row_groups_total"),
    row_groups_overlap = n_of("row_groups_overlap"),
    rows_candidate = nrow(out)
  )
}

# Time one query type: one instance per repetition, chosen in `setup`;
# `expr_of(y, shape)` gets the query as given and its shape.
time_type <- function(expr_of, qtype, label, case, run = "warm", reconnect = NULL) {
  state <- new.env()
  state$k <- 0L
  state$expr_of <- expr_of
  setup <- rlang::expr({
    k <- k %% !!instances + 1L
    y <- queries[[!!qtype]][[k]]
    s <- shapes[[!!qtype]][[k]]
    !!reconnect
  })
  row <- rlang::inject(bench_run(!!label := expr_of(y, s), case = case, run = run, setup = setup, env = state))
  row$query <- qtype
  row
}

layout_facts <- function(st) {
  files <- st$primary$files
  data <- files[files$dataset == dataset, ]
  index <- files[files$dataset == index_name(dataset), ]
  groups <- files_row_groups(st$primary$backend, data$path)
  tibble::tibble(
    files = nrow(data), row_groups = nrow(groups), data_bytes = sum(as.numeric(data$bytes)),
    index_files = nrow(index), index_rows = sum(as.numeric(index$rows)),
    index_bytes = sum(as.numeric(index$bytes))
  )
}

# ---- saving ----
save_merged <- function(new_rows, name) {
  if (is.null(new_rows) || nrow(new_rows) == 0) {
    return(invisible())
  }
  path <- file.path(results_dir, paste0(name, ".parquet"))
  tagged <- env
  names(tagged) <- paste0("env_", names(tagged))
  new_rows <- cbind(tibble::as_tibble(new_rows), tagged[rep(1L, nrow(new_rows)), ])
  if (file.exists(path)) {
    old <- tibble::as_tibble(arrow::read_parquet(path, mmap = FALSE))
    replaced <- paste(old$rows, old$layout, old$location) %in% paste(new_rows$rows, new_rows$layout, new_rows$location)
    old <- old[!replaced, ]
    new_rows <- vctrs::vec_rbind(old, new_rows)
  }
  arrow::write_parquet(tibble::as_tibble(new_rows), path)
  cli::cli_inform("Saved {nrow(new_rows)} rows to {.path {path}}.")
}

# ---- run ----
x <- rcs_sim_polygons(n, seed = 1)
gc()

run_layout <- function(spec) {
  name <- spec$layout
  uri <- file.path(work, name)
  st <- store_connect(uri, create = TRUE)
  cli::cli_inform("Layout {name}: writing {format(n, big.mark = ',')} polygons.")
  write <- function() {
    store_write(st, x, dataset,
      title = "Polygons", description = "Simulated polygons in open ocean.",
      partition = if (spec$partition) "h3", h3_res = spec$h3_res,
      rows_per_group = spec$rows_per_group, check = FALSE
    )
  }
  start <- bench::hires_time()
  if (spec$sort == "fine") with_fine_sort(write()) else write()
  write_s <- as.numeric(bench::hires_time() - start)
  if (identical(name, chosen[[length(chosen)]])) {
    # the data are not needed after the last write; free the memory
    rm(x, envir = globalenv())
    gc()
  }
  facts <- tibble::tibble(rows = n, layout = name, location = "local", !!!spec[-1], write_s = write_s, layout_facts(st))
  st <- store_connect(uri)
  part <- spec$partition

  # counters and completeness
  cli::cli_inform("Layout {name}: counters.")
  counted <- list()
  reference <- list()
  for (qtype in query_types) {
    for (k in seq_len(instances)) {
      y <- queries[[qtype]][[k]]
      truth <- sort(store_read(st, dataset, intersects = y, columns = id, geometry = TRUE)$id)
      reference[[paste(qtype, k)]] <- truth
      # with one file, pruning changes nothing but an empty result
      for (prune in if (part) c(TRUE, FALSE) else TRUE) {
        for (rf in names(row_filters)) {
          f <- row_filters[[rf]]
          v <- flags(prune, f[["cells"]], f[["index"]], f[["bbox"]], exact = FALSE)
          cnt <- counters_of(st, y, v)
          counted[[length(counted) + 1L]] <- tibble::tibble(
            query = qtype, instance = k, prune = prune, row_filter = rf,
            files_data = cnt$files_data, files_index = cnt$files_index,
            row_groups_total = cnt$row_groups_total, row_groups_overlap = cnt$row_groups_overlap,
            rows_candidate = cnt$rows_candidate, rows_returned = length(truth),
            missing = sum(!truth %in% cnt$ids),
            returned_md5 = md5_string(paste(truth, collapse = ","))
          )
        }
      }
    }
  }
  counted <- do.call(rbind, counted)
  counted <- tibble::tibble(rows = n, layout = name, location = "local", counted)

  # times
  cli::cli_inform("Layout {name}: times.")
  timed <- list()
  add <- function(row, variant, complete) {
    row$variant <- variant
    row$complete <- complete
    timed[[length(timed) + 1L]] <<- row
  }
  for (vname in names(variants)) {
    if (vname == "prune_only" && !part) next
    if (!name %in% c("base", "part") && !vname %in% short_variants) next
    if (name %in% c("base", "part") && !vname %in% full_variants) next
    v <- variants[[vname]]
    complete <- !identical(vname, "no_index")
    for (qtype in query_types) {
      add(time_type(function(y, s) run_variant(st, y, v), qtype, vname, name), vname, complete)
    }
  }
  # DuckDB on the same files, local only
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "LOAD spatial")
  paths <- file.path(uri, st$primary$files$path[st$primary$files$dataset == dataset])
  duck_rows <- list()
  for (qtype in query_types) {
    for (k in seq_len(instances)) {
      got <- DBI::dbGetQuery(con, duckdb_sql(paths, shapes[[qtype]][[k]]))$id
      truth <- reference[[paste(qtype, k)]]
      duck_rows[[length(duck_rows) + 1L]] <- tibble::tibble(
        query = qtype, instance = k, rows_duckdb = length(got),
        duckdb_missing = sum(!truth %in% got), duckdb_extra = sum(!got %in% truth)
      )
    }
    add(time_type(function(y, s) DBI::dbGetQuery(con, duckdb_sql(paths, s)), qtype, "duckdb", name), "duckdb", NA)
  }
  duck_rows <- do.call(rbind, duck_rows)
  counted <- merge(counted, duck_rows, by = c("query", "instance"), all.x = TRUE, sort = FALSE)
  # read everything, then sf::st_filter(), on the base layouts
  if (name %in% c("base")) {
    cli::cli_inform("Layout {name}: read everything, then filter.")
    add(bench_run(read_all = store_read(st, dataset), case = name), "read_all", TRUE)
    timed[[length(timed)]]$query <- NA_character_
    all <- store_read(st, dataset)
    hits <- list()
    # one filter of 1e6 rows takes about 40 s (s2); above 1e6 rows only the
    # read of everything is timed, which alone exceeds the spatial reads
    filter_types <- if (n <= 1e6) query_types else character()
    for (qtype in filter_types) {
      add(time_type(function(y, s) sf::st_filter(all, s), qtype, "st_filter", name), "st_filter", TRUE)
      for (k in seq_len(instances)) {
        got <- sort(sf::st_filter(all, shapes[[qtype]][[k]])$id)
        hits[[paste(qtype, k)]] <- identical(got, reference[[paste(qtype, k)]])
      }
    }
    if (length(hits) > 0) {
      facts$st_filter_identical <- sum(unlist(hits))
      facts$st_filter_compared <- length(hits)
    }
    rm(all)
    gc()
  }
  timed <- do.call(vctrs::vec_rbind, timed)
  timed <- tibble::tibble(rows = n, layout = name, location = "local", timed)
  timed$default_rule <- if (exists("spatial_use_cells", asNamespace("rcs"))) "box first" else NA_character_

  # GCS, cold
  if (name %in% on_gcs) {
    cli::cli_inform("Layout {name}: GCS.")
    prefix <- paste0(sub("/+$", "", gcs_root), "/spatial-", substr(md5_string(paste(Sys.time(), stats::runif(1))), 1, 10))
    gcs_uri <- paste0(prefix, "/store")
    gcs_out <- tryCatch(
      {
        st_both <- store_connect(uri, secondary = gcs_uri, create = TRUE)
        start <- bench::hires_time()
        store_sync(st_both, all = TRUE)
        sync_s <- as.numeric(bench::hires_time() - start)
        gcs_timed <- list()
        holder <- new.env()
        gcs_types <- strsplit(Sys.getenv("RCS_BENCH_GCS_QUERIES", paste(query_types, collapse = ";")), ";")[[1]]
        for (vname in gcs_variants) {
          v <- variants[[vname]]
          for (qtype in intersect(query_types, gcs_types)) {
            row <- time_type(function(y, s) run_variant(holder$st, y, v), qtype, vname, name,
              run = "cold",
              reconnect = rlang::expr({
                gcs_reset_clients()
                assign("st", store_connect(!!gcs_uri), envir = !!holder)
              })
            )
            row$variant <- vname
            row$complete <- TRUE
            gcs_timed[[length(gcs_timed) + 1L]] <- row
          }
        }
        list(timed = do.call(vctrs::vec_rbind, gcs_timed), sync_s = sync_s)
      },
      finally = {
        be <- be_new(prefix)
        left <- tryCatch(be_list(be), error = function(e) NULL)
        if (!is.null(left) && nrow(left) > 0) be_delete(be, left$path)
      }
    )
    gcs_out$timed$default_rule <- timed$default_rule[[1]]
    timed <- vctrs::vec_rbind(timed, tibble::tibble(rows = n, layout = name, location = "gcs", gcs_out$timed))
    facts$gcs_sync_s <- gcs_out$sync_s
  }
  list(timed = timed, counted = counted, facts = facts)
}

for (name in chosen) {
  spec <- layouts[layouts$layout == name, ]
  if (nrow(spec) != 1) cli::cli_abort("Unknown layout {.val {name}}.")
  out <- run_layout(as.list(spec))
  save_merged(out$timed, "spatial")
  save_merged(out$counted, "spatial-counters")
  save_merged(out$facts, "spatial-layouts")
  unlink(file.path(work, name), recursive = TRUE)
  gc()
}
unlink(work, recursive = TRUE)
