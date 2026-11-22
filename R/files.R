# Data files: staging a dataset version as Parquet files (key check,
# partitioning, sorting, writing with the embedded metadata, per-file facts,
# version, file names, manifest), and reading row groups of stored files.
#
# Determinism is a contract: the same data, staged twice with the same
# arguments, give byte-identical files and therefore the same MD5s and the
# same version. Nothing written into a data file depends on the time, the
# session or the history setting (see `entry_metadata_json()`).

# Checks ----------------------------------------------------------------------

#' Check the key of the data to write
#'
#' Step 3 of `store_write()`: the key columns exist and identify the rows.
#'
#' @param data A data frame.
#' @param key Character vector of column names, or `NULL` / empty for none.
#' @param call Environment for the error.
#' @return `data`, invisibly. Aborts with class `rcs_error_argument` when a
#'   key column is missing, and with `c("rcs_error_key",
#'   "rcs_error_argument")` when key values repeat, listing the first five
#'   repeated key values.
#' @noRd
check_key <- function(data, key, call = caller_env()) {
  if (length(key) == 0) {
    return(invisible(data))
  }
  if (!is.character(key) || anyNA(key) || anyDuplicated(key) > 0) {
    cli::cli_abort(
      "{.arg key} must be distinct column names.",
      class = "rcs_error_argument", call = call
    )
  }
  missing <- setdiff(key, names(data))
  if (length(missing) > 0) {
    cli::cli_abort(
      "The key column{?s} {.field {missing}} {?is/are} not in the data.",
      class = "rcs_error_argument", call = call
    )
  }
  keys <- tibble::as_tibble(as.list(data)[key])
  dup <- vctrs::vec_duplicate_detect(keys)
  if (any(dup)) {
    values <- vctrs::vec_unique(keys[dup, , drop = FALSE])
    n <- nrow(values)
    shown <- format_key_values(utils::head(values, 5L))
    cli::cli_abort(
      c(
        "The key {.field {key}} does not identify the rows: {n} key value{?s} repeat{?s/}.",
        rlang::set_names(shown, "x"),
        i = if (n > 5) "And {n - 5} more."
      ),
      class = c("rcs_error_key", "rcs_error_argument"), call = call
    )
  }
  invisible(data)
}

# One line per row: `col = value, col = value`.
format_key_values <- function(values) {
  cols <- lapply(values, function(v) {
    out <- as.character(v)
    out[is.na(v)] <- "NA"
    out
  })
  lines <- do.call(paste, c(
    Map(function(name, v) paste0(name, " = ", v), names(cols), cols),
    sep = ", "
  ))
  gsub("([{}])", "\\1\\1", lines)
}

check_count <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  if (!rlang::is_scalar_integerish(x) || is.na(x) || x < 1) {
    cli::cli_abort(
      "{.arg {arg}} must be a positive whole number.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible(as.integer(x))
}

# Partitioning ----------------------------------------------------------------

#' Plan the partitions of the data to write
#'
#' Step 5 of `store_write()`, and the partition part of step 3.
#'
#' * `partition = NULL`: one file.
#' * `partition = c("col", ...)`: one file per combination of values of those
#'   columns; the columns must exist, be atomic and hold no `NA`.
#' * `partition = "h3"` (data with an `integer64` column `h3`): one file per
#'   H3 parent of `h3` at the finest resolution `r` (at most `h3_max_res`) whose
#'   number of groups is at most `max_files`, written as the column
#'   `h3_p<r>` (an `integer64` column placed right after `h3`). Rows with
#'   `h3 = NA` (empty geometries) form one group of their own, with the value
#'   `NA`, and count as a group.
#'
#' @param data A data frame (a table, or `geo_encode()$data`).
#' @param partition `NULL` or a character vector.
#' @param max_files Most files allowed.
#' @param h3_max_res The finest parent resolution to try with
#'   `partition = "h3"`: the geocode resolution for a new dataset, the
#'   current partition resolution for an `update` that must not re-partition
#'   to a finer one.
#' @param call Environment for the error.
#' @return A list: `data` (with the `h3_p<r>` column added for `"h3"`),
#'   `partition` (the partition column names as written, e.g. `"h3_p3"`;
#'   `character()` for one file), `res` (the parent resolution, or `NA`) and
#'   `groups`: a list of integer row indices, one element per file, ordered
#'   by the partition values. Aborts with class `rcs_error_argument` when a
#'   column is missing, holds `NA`, there are zero rows with a partition, or
#'   there are more groups than `max_files` (suggesting a coarser column, or
#'   for `"h3"` a larger `max_files`).
#' @noRd
partition_plan <- function(data, partition = NULL, max_files = 50L,
                           h3_max_res = NA_integer_, call = caller_env()) {
  max_files <- check_count(max_files, call = call)
  n <- nrow(data)
  if (length(partition) == 0) {
    return(list(data = data, partition = character(), res = NA_integer_, groups = list(seq_len(n))))
  }
  if (!is.character(partition) || anyNA(partition) || anyDuplicated(partition) > 0) {
    cli::cli_abort("{.arg partition} must be distinct column names.", class = "rcs_error_argument", call = call)
  }
  if (n == 0) {
    cli::cli_abort(
      c("Zero rows can only be written as one file.", i = "Use {.code partition = NULL}."),
      class = "rcs_error_argument", call = call
    )
  }
  if (identical(partition, "h3")) {
    return(partition_plan_h3(data, max_files, h3_max_res, call))
  }
  missing <- setdiff(partition, names(data))
  if (length(missing) > 0) {
    cli::cli_abort(
      "The partition column{?s} {.field {missing}} {?is/are} not in the data.",
      class = "rcs_error_argument", call = call
    )
  }
  bad <- partition[!vapply(partition, function(p) {
    col <- data[[p]]
    is.atomic(col) && !is.data.frame(col) && !inherits(col, "difftime")
  }, logical(1))]
  if (length(bad) > 0) {
    cli::cli_abort(
      "The partition column{?s} {.field {bad}} must hold plain values (not lists or structures).",
      class = "rcs_error_argument", call = call
    )
  }
  has_na <- partition[vapply(partition, function(p) anyNA(data[[p]]), logical(1))]
  if (length(has_na) > 0) {
    cli::cli_abort(
      "The partition column{?s} {.field {has_na}} may not hold missing values.",
      class = "rcs_error_argument", call = call
    )
  }
  groups <- partition_groups(data, partition)
  if (length(groups) > max_files) {
    k <- length(groups)
    cli::cli_abort(
      c(
        "Partitioning by {.field {partition}} gives {k} files, more than {.arg max_files} = {max_files}.",
        i = "Partition by a coarser column, or raise {.arg max_files}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  list(data = data, partition = partition, res = NA_integer_, groups = groups)
}

partition_plan_h3 <- function(data, max_files, h3_max_res, call) {
  if (!inherits(data[["h3"]], "integer64")) {
    cli::cli_abort(
      c(
        "{.code partition = \"h3\"} needs geocoded geospatial data.",
        i = "It is not available for tables or with {.code geocode = FALSE}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (!rlang::is_scalar_integerish(h3_max_res) || is.na(h3_max_res)) {
    cli::cli_abort("{.arg h3_max_res} must be a resolution.", .internal = TRUE)
  }
  # Parents of the distinct cells only, matched back to the rows.
  cells <- vctrs::vec_unique(data[["h3"]])
  at_cell <- vctrs::vec_match(data[["h3"]], cells)
  for (res in seq(as.integer(h3_max_res), 0L)) {
    cell_parents <- h3_parent(cells, res)
    if (vctrs::vec_unique_count(cell_parents) <= max_files) {
      parents <- cell_parents[at_cell]
      column <- paste0("h3_p", res)
      data <- tibble::as_tibble(data)
      data[[column]] <- parents
      at <- match("h3", names(data))
      others <- setdiff(names(data), column)
      data <- data[c(others[seq_len(at)], column, others[-seq_len(at)])]
      groups <- partition_groups(data, column)
      return(list(data = data, partition = column, res = res, groups = groups))
    }
  }
  cli::cli_abort(
    c(
      "Even H3 resolution 0 gives more than {.arg max_files} = {max_files} partitions.",
      i = "Raise {.arg max_files}."
    ),
    class = "rcs_error_argument", call = call
  )
}

# Row indices per combination of values, ordered by the values.
partition_groups <- function(data, columns) {
  keys <- tibble::as_tibble(as.list(data)[columns])
  loc <- vctrs::vec_group_loc(keys)
  loc$loc[vctrs::vec_order(loc$key)]
}

# Sorting ---------------------------------------------------------------------

#' Sort the rows to write
#'
#' Step 6 of `store_write()` for tables: by the key columns (radix order, so
#' independent of the locale), nothing without a key. Geospatial data come
#' sorted from `geo_encode()` and are not touched.
#'
#' @param data A data frame.
#' @param key Character vector, or `NULL`.
#' @return `data`, sorted.
#' @noRd
sort_rows <- function(data, key = NULL) {
  if (length(key) == 0 || nrow(data) < 2) {
    return(data)
  }
  data[vctrs::vec_order(tibble::as_tibble(as.list(data)[key])), , drop = FALSE]
}

# Schema and columns ----------------------------------------------------------

# The Arrow schema of the whole data, inferred once so that every partition
# file has the same schema; a `geometry` column is always `binary`, and a
# difftime column is `double`: its value in its own units, which the
# `columns` specification records (Arrow's `duration` has whole units only
# and would truncate). `files_arrow_values()` converts the data to match.
files_arrow_schema <- function(data) {
  schema <- arrow::infer_schema(files_arrow_values(data))
  if ("geometry" %in% names(data)) {
    fields <- schema$fields
    i <- match("geometry", names(schema))
    fields[[i]] <- arrow::field("geometry", arrow::binary())
    schema <- arrow::schema(!!!fields)
  }
  schema
}

# The data as written: every difftime column as a plain double in its own
# units (restored by `restore_types()` from `r_type`).
files_arrow_values <- function(data) {
  data <- tibble::as_tibble(data)
  for (name in names(data)) {
    if (inherits(data[[name]], "difftime")) {
      data[[name]] <- as.double(unclass(data[[name]]))
    }
  }
  data
}

#' The `columns` specification of the data to write
#'
#' @param data A data frame.
#' @param schema Its Arrow schema.
#' @param descriptions Named character vector, column name to description,
#'   or `NULL`.
#' @param call Environment for the error.
#' @return A tibble as `columns_spec()` builds it, with `r_type` for
#'   difftime, `integer64`, factor and plain list columns (not for the WKB
#'   `geometry`). Aborts with class `rcs_error_argument` when `descriptions`
#'   names a column the data lack.
#' @noRd
files_columns_spec <- function(data, schema, descriptions = NULL, call = caller_env()) {
  if (!is.null(descriptions)) {
    if (!is.character(descriptions) || !rlang::is_named(descriptions)) {
      cli::cli_abort(
        "{.arg columns} must be a named character vector of descriptions.",
        class = "rcs_error_argument", call = call
      )
    }
    unknown <- setdiff(names(descriptions), names(data))
    if (length(unknown) > 0) {
      cli::cli_abort(
        "{.arg columns} describes column{?s} the data lack: {.field {unknown}}.",
        class = "rcs_error_argument", call = call
      )
    }
  }
  r_type <- lapply(names(data), function(name) {
    col <- data[[name]]
    if (inherits(col, "integer64")) {
      list(class = "integer64")
    } else if (inherits(col, "difftime")) {
      list(class = "difftime", units = units(col))
    } else if (is.factor(col)) {
      list(class = "factor", levels = levels(col), ordered = is.ordered(col))
    } else if (is.list(col) && !is.data.frame(col) && name != "geometry") {
      list(class = "list")
    }
  })
  description <- unname(descriptions[names(data)])
  if (is.null(descriptions)) description <- NULL
  columns_spec(
    name = names(data),
    type = vapply(schema$fields, function(f) f$type$ToString(), character(1)),
    r_type = r_type,
    description = description
  )
}

# Facts per file --------------------------------------------------------------

#' Extent of a column of boxes, and range of cells
#'
#' @param bbox A `bbox_df()`.
#' @param cells An `integer64` vector.
#' @return `bbox_extent()`: a one-row `bbox_df()`, all `NA` when no row has a
#'   box. `cell_range()`: a list of two `integer64` scalars (min, max), `NA`
#'   when no cell is present.
#' @noRd
bbox_extent <- function(bbox) {
  if (is.null(bbox) || nrow(bbox) == 0 || all(is.na(bbox$xmin))) {
    return(bbox_na(1L))
  }
  bbox_df(
    min(bbox$xmin, na.rm = TRUE), min(bbox$ymin, na.rm = TRUE),
    max(bbox$xmax, na.rm = TRUE), max(bbox$ymax, na.rm = TRUE)
  )
}

#' @rdname bbox_extent
#' @noRd
cell_range <- function(cells) {
  cells <- cells[!is.na(cells)]
  if (length(cells) == 0) {
    return(list(bit64::NA_integer64_, bit64::NA_integer64_))
  }
  list(min(cells), max(cells))
}

# Writing ---------------------------------------------------------------------

#' Write one Parquet data file
#'
#' zstd compression, `rows_per_group` rows per row group, the key-value
#' metadata `rcs` and, when given, `geo`.
#'
#' @param data The rows of the file.
#' @param path Local file; its folder is created.
#' @param schema The Arrow schema (`files_arrow_schema()` of the whole data).
#' @param rcs The `rcs` JSON (`entry_metadata_json()`).
#' @param geo The `geo` JSON (`geo_metadata()`), or `NULL`.
#' @param rows_per_group Rows per row group.
#' @return `path`, invisibly.
#' @noRd
files_write_parquet <- function(data, path, schema, rcs, geo = NULL, rows_per_group = 50000L) {
  table <- arrow::arrow_table(files_arrow_values(data), schema = schema)
  table$metadata$rcs <- rcs
  if (!is.null(geo)) {
    table$metadata$geo <- geo
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(
    table, path,
    compression = "zstd",
    chunk_size = as.integer(rows_per_group)
  )
  invisible(path)
}

#' Stage a dataset version as Parquet files
#'
#' Steps 3 (key), 5 (partitions), 6 (sorting of tables) and 7 of
#' `store_write()`: writes the files into the staging folder, partition by
#' partition, computes MD5, rows, bytes, extent and cell range per file,
#' the version, the file names, the entry and the manifest, and writes the
#' manifest next to the files. Nothing leaves the machine.
#'
#' For a geospatial dataset pass `geo_encode()$data` as `data` (already in
#' written order, with `.rcs_id`, `h3`, `bbox` and WKB `geometry`), and its
#' `crs` and `h3_res`. For an index table pass `geo_encode()$index`,
#' `kind = "table"`, `index_of = <dataset>`, `sorted_by = c("h3", ".rcs_id")`
#' and, when it is partitioned, `partition = "h3"` with `h3_max_res` = the
#' dataset's `h3_res`.
#'
#' For `update`, pass the rows of the replaced and new partitions as `data`
#' and the file rows of the kept partitions as `keep`: the version is
#' computed over the kept and the new files, only the new files are written
#' and named, and every returned file row carries the new version (a kept
#' file keeps its path and `created`). Key uniqueness across kept partitions
#' is the caller's check.
#'
#' @param data A data frame.
#' @param dataset Full dataset name.
#' @param title,description Non-empty strings.
#' @param kind `"table"` or `"geospatial"`.
#' @param key Character vector of key columns, or `NULL`.
#' @param partition `NULL`, column names, or `"h3"` (see `partition_plan()`).
#' @param sorted_by Character vector, or `NULL` for the default: the key for
#'   tables; `c("h3", <key or ".rcs_id">)` for geospatial data (without
#'   `"h3"` when `geocode = FALSE`).
#' @param crs PROJJSON string (geospatial), else `NA`.
#' @param h3_res Geocode resolution (geospatial with geocodes), else `NA`.
#' @param geocode_engine The geocoding engine recorded in the entry
#'   (`"auto"`, `"s2"`, `"planar"`), or `NA` (tables, index tables,
#'   `geocode = FALSE`). Embedded in the files and the manifest only when not
#'   `NA`.
#' @param h3_max_res Finest parent resolution for `partition = "h3"`;
#'   default `h3_res`.
#' @param index_of For an index table, the dataset it indexes; else `NA`.
#' @param source,inputs Strings or `NA`.
#' @param columns Named character vector, column name to description, or
#'   `NULL`.
#' @param history Dataset-level history setting: `TRUE`, `FALSE` or `NA`.
#' @param max_files Most partition files.
#' @param rows_per_group Rows per row group.
#' @param keep `NULL`, or the file rows (`files_schema()`) of kept partitions.
#' @param created `POSIXct`: the `created` of the entry (that of the entry
#'   replaced, for a later write); default now. `updated` is now.
#' @param dir The staging folder; files are written at
#'   `file.path(dir, <relative path>)`. Use a fresh folder per write.
#' @param call Environment for the error.
#' @return A list:
#'
#'   * `entry`: the new entry (`new_entry()`);
#'   * `files`: all file rows of the version, sorted by path;
#'   * `staged`: a tibble with `path` (relative) and `local` (the staged
#'     file) for the files written by this call;
#'   * `manifest`: the `rcs_manifest`;
#'   * `manifest_local`: the staged manifest file, at
#'     `file.path(dir, manifest_path(dataset, version))`;
#'   * `partition`: the partition columns as written (e.g. `"h3_p3"`).
#'
#'   Aborts as `check_key()`, `partition_plan()` and `files_columns_spec()`
#'   do.
#' @noRd
files_stage <- function(data, dataset, title, description,
                        kind = c("table", "geospatial"),
                        key = NULL, partition = NULL, sorted_by = NULL,
                        crs = NA_character_, h3_res = NA_integer_,
                        h3_max_res = h3_res, geocode_engine = NA_character_,
                        index_of = NA_character_, source = NA_character_, inputs = NA_character_,
                        columns = NULL, history = NA,
                        max_files = 50L, rows_per_group = 50000L,
                        keep = NULL, created = now_utc(),
                        dir = rcs_option("rcs.staging_dir"),
                        call = caller_env()) {
  kind <- rlang::arg_match(kind)
  check_dataset_name(dataset, allow_index = !is.na(index_of), call = call)
  check_string(title, call = call)
  check_string(description, call = call)
  rows_per_group <- check_count(rows_per_group, call = call)
  if (!is.data.frame(data) || inherits(data, "sf")) {
    cli::cli_abort("{.arg data} must be a plain data frame.", .internal = TRUE)
  }
  data <- tibble::as_tibble(data)
  key <- as.character(key %||% character())
  check_key(data, key, call = call)

  if (kind == "table") {
    data <- sort_rows(data, key)
  }
  plan <- partition_plan(data, partition, max_files, h3_max_res, call = call)
  data <- plan$data
  if (is.null(sorted_by)) {
    sorted_by <- if (kind == "geospatial") {
      c(if ("h3" %in% names(data)) "h3", if (length(key) > 0) key else ".rcs_id")
    } else {
      key
    }
  }

  schema <- files_arrow_schema(data)
  spec <- files_columns_spec(data, schema, columns, call = call)
  columns_json <- columns_to_json(spec)
  provisional <- new_entry(
    dataset = dataset, kind = kind, title = title, description = description,
    version = strrep("0", 16), n_files = 0, rows = 0, bytes = 0,
    columns = columns_json, key = key, sorted_by = sorted_by,
    partition = plan$partition, source = source, inputs = inputs, crs = crs,
    h3_res = h3_res, geocode_engine = geocode_engine, index_of = index_of,
    history = history
  )
  rcs_json <- entry_metadata_json(provisional)
  geospatial <- kind == "geospatial" && "geometry" %in% names(data)
  has_cells <- inherits(data[["h3"]], "integer64")

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  tmp_dir <- file.path(dir, paste0(".rcs-tmp-", md5_string(paste(dataset, Sys.getpid(), as.numeric(Sys.time())))))
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  new <- lapply(seq_along(plan$groups), function(i) {
    rows <- plan$groups[[i]]
    part <- vctrs::vec_slice(data, rows)
    values <- if (length(plan$partition) > 0) as.list(part[1, plan$partition])
    tmp <- file.path(tmp_dir, paste0("part-", i, ".parquet"))
    geo <- if (geospatial) geo_metadata(part, crs)
    files_write_parquet(part, tmp, schema, rcs_json, geo, rows_per_group)
    range <- if (has_cells) cell_range(part$h3)
    list(
      tmp = tmp,
      values = values,
      partition_values = partition_values_json(values),
      rows = nrow(part),
      bytes = file.size(tmp),
      md5 = md5_file(tmp),
      bbox = if (geospatial) bbox_extent(part$bbox) else NULL,
      h3_min = range[[1]],
      h3_max = range[[2]]
    )
  })
  rm(data)

  keep <- keep %||% files_empty()
  new_pv <- vapply(new, function(f) f$partition_values, character(1))
  if (any(new_pv %in% keep$partition_values)) {
    cli::cli_abort("A kept partition is also written again.", .internal = TRUE)
  }
  new_md5 <- vapply(new, function(f) f$md5, character(1))
  version <- version_hash(c(keep$partition_values, new_pv), c(keep$md5, new_md5))

  paths <- vapply(new, function(f) data_file_path(dataset, version, f$values), character(1))
  local <- file.path(dir, paths)
  for (i in seq_along(new)) {
    dir.create(dirname(local[[i]]), recursive = TRUE, showWarnings = FALSE)
    if (file.exists(local[[i]])) unlink(local[[i]])
    if (!file.rename(new[[i]]$tmp, local[[i]])) {
      cli::cli_abort("Cannot move a staged file to {.path {local[[i]]}}.")
    }
  }

  now <- now_utc()
  new_rows <- new_file_rows(
    dataset = dataset, version = version, path = paths,
    partition_values = new_pv,
    rows = vapply(new, function(f) f$rows, numeric(1)),
    bytes = vapply(new, function(f) as.numeric(f$bytes), numeric(1)),
    md5 = new_md5,
    bbox = if (geospatial) vctrs::vec_rbind(!!!lapply(new, function(f) f$bbox)),
    h3_min = if (has_cells) do.call(c, lapply(new, function(f) f$h3_min)),
    h3_max = if (has_cells) do.call(c, lapply(new, function(f) f$h3_max)),
    created = now
  )
  keep$dataset <- rep(dataset, nrow(keep))
  keep$version <- rep(version, nrow(keep))
  files <- vctrs::vec_rbind(keep, new_rows)
  files <- files[order(files$path, method = "radix"), ]

  entry <- new_entry(
    dataset = dataset, kind = kind, title = title, description = description,
    version = version, n_files = nrow(files), rows = sum(files$rows),
    bytes = sum(files$bytes), columns = columns_json, key = key,
    sorted_by = sorted_by, partition = plan$partition, source = source,
    inputs = inputs, crs = crs,
    bbox = if (geospatial) bbox_extent(files$bbox) else NULL,
    h3_res = h3_res, geocode_engine = geocode_engine, index_of = index_of,
    history = history, created = created, updated = now
  )
  manifest <- new_manifest(entry, files, written = now)
  manifest_local <- file.path(dir, manifest_path(dataset, version))
  manifest_write_local(manifest, manifest_local)

  list(
    entry = entry,
    files = files,
    staged = tibble::tibble(path = paths, local = local),
    manifest = manifest,
    manifest_local = manifest_local,
    partition = plan$partition
  )
}

# Restoring R types -----------------------------------------------------------

#' Restore the R types of rows read from data files
#'
#' Arrow restores most types; the `columns` specification records the rest
#' (see the plan, "Types"), and this is the one place that restores them,
#' for every read path (`rows_finish()`, the serialization check of
#' `store_check()`, the rows `store_write()` reads back):
#'
#' * difftime: stored as a double in the recorded units (see
#'   `files_arrow_schema()`), restored with those units; a column Arrow
#'   returns as difftime gets the recorded units;
#' * `integer64`: a numeric column becomes `bit64::integer64`;
#' * factor: a factor or character column gets the recorded levels and
#'   order (zero-row files lose them);
#' * plain list: a bare list, the attributes of its elements dropped;
#' * the WKB `geometry` (no `r_type`): a bare list of raw vectors;
#' * a struct column (`bbox`): a tibble.
#'
#' A column is restored only when it still has its stored name and a
#' compatible type, so the rows of a query whose verbs changed a column are
#' left as they are.
#'
#' @param data A data frame read with `arrow.int64_downcast = FALSE`.
#' @param spec The `columns` specification (`columns_from_json()`).
#' @return A tibble with the same columns.
#' @noRd
restore_types <- function(data, spec) {
  data <- tibble::as_tibble(data)
  for (name in names(data)) {
    v <- data[[name]]
    i <- match(name, spec$name)
    r_type <- if (!is.na(i)) spec$r_type[[i]]
    cls <- r_type$class %||% ""
    if (cls == "list" || (name == "geometry" && is.list(v) && !is.data.frame(v))) {
      v <- restore_list(v, strip = name != "geometry")
    } else if (cls == "integer64") {
      if (is.numeric(v) && !inherits(v, "integer64")) v <- bit64::as.integer64(v)
    } else if (cls == "difftime") {
      v <- restore_difftime(v, r_type$units)
    } else if (cls == "factor") {
      if ((is.factor(v) || is.character(v)) &&
        (!is.factor(v) || !identical(levels(v), r_type$levels) ||
          !identical(is.ordered(v), isTRUE(r_type$ordered)))) {
        v <- factor(as.character(v), levels = r_type$levels, ordered = isTRUE(r_type$ordered))
      }
    } else if (is.data.frame(v)) {
      v <- tibble::as_tibble(v)
    }
    data[[name]] <- v
  }
  data
}

restore_difftime <- function(x, units) {
  if (is.null(units)) {
    return(x)
  }
  if (inherits(x, "difftime")) {
    units(x) <- units
    return(x)
  }
  if (is.double(x) || is.integer(x)) {
    return(as.difftime(as.double(x), units = units))
  }
  x
}

restore_list <- function(x, strip = TRUE) {
  if (!is.list(x) || is.data.frame(x)) {
    return(x)
  }
  # A bare list of the elements (Arrow returns an `arrow_list`); element
  # attributes are stripped only where an element has any.
  out <- unclass(x)
  attributes(out) <- NULL
  if (strip) {
    has <- which(lengths(lapply(out, attributes)) > 0L)
    out[has] <- lapply(out[has], function(e) {
      attributes(e) <- NULL
      e
    })
  }
  out
}

# Reading row groups ----------------------------------------------------------

# Open a stored Parquet file through the location's Arrow file system, call
# `fn(reader)` and close the file.
with_parquet_reader <- function(fs, path, be, fn) {
  file <- tryCatch(
    fs$fs$OpenInputFile(paste0(fs$path, "/", path)),
    error = function(e) {
      cli::cli_abort(
        c("Cannot open {.path {path}} in {.path {be$uri}}.", be_auth_hint_safe(be)),
        class = "rcs_error_backend", parent = e, call = NULL
      )
    }
  )
  on.exit(file$close(), add = TRUE)
  reader <- tryCatch(
    arrow::ParquetFileReader$create(file),
    error = function(e) {
      cli::cli_abort(
        "{.path {path}} in {.path {be$uri}} is not a readable Parquet file.",
        class = "rcs_error_backend", parent = e, call = NULL
      )
    }
  )
  trace_count("file_open", 1, location = be$uri, detail = path)
  fn(reader)
}

be_auth_hint_safe <- function(be) {
  tryCatch(be_auth_hint(be), error = function(e) character())
}

# Leaf (Parquet column) indices, starting at 0, of top-level fields: the
# readers take leaf indices, and a struct such as `bbox` has four leaves.
parquet_leaf_indices <- function(schema, columns) {
  leaf_count <- function(type) {
    if (inherits(type, "StructType")) {
      sum(vapply(type$fields(), function(f) leaf_count(f$type), numeric(1)))
    } else if (inherits(type, c("ListType", "LargeListType", "FixedSizeListType"))) {
      leaf_count(type$value_type)
    } else if (inherits(type, "MapType")) {
      leaf_count(type$key_type) + leaf_count(type$item_type)
    } else {
      1
    }
  }
  counts <- vapply(schema$fields, function(f) leaf_count(f$type), numeric(1))
  starts <- cumsum(c(0, counts))[seq_along(counts)]
  names(starts) <- names(counts) <- names(schema)
  as.integer(unlist(lapply(columns, function(col) starts[[col]] + seq_len(counts[[col]]) - 1)))
}

#' Row groups of stored Parquet files
#'
#' Reads the footers only. Implemented by C; called by E (`store_check()`)
#' and F (`store_sample()`, `store_glimpse()`).
#'
#' @param be A backend object.
#' @param paths Character vector of relative paths of Parquet files.
#' @return A tibble with one row per row group, in file and group order:
#'   `path` (character), `row_group` (integer, starting at 1) and `rows`
#'   (double). Counts one `file_open` per file.
#' @noRd
files_row_groups <- function(be, paths) {
  empty <- tibble::tibble(path = character(), row_group = integer(), rows = double())
  if (length(paths) == 0) {
    return(empty)
  }
  fs <- be_arrow_fs(be)
  out <- lapply(paths, function(p) {
    with_parquet_reader(fs, p, be, function(reader) {
      n <- reader$num_row_groups
      rows <- vapply(
        seq_len(n) - 1L,
        function(i) as.double(reader$ReadRowGroup(i, column_indices = integer())$num_rows),
        numeric(1)
      )
      tibble::tibble(path = rep(p, n), row_group = seq_len(n), rows = rows)
    })
  })
  vctrs::vec_rbind(empty, !!!out)
}

#' Read chosen row groups of one stored Parquet file
#'
#' Fetches only those row groups and columns. Implemented by C; called by E
#' and F.
#'
#' @param be A backend object.
#' @param path One relative path of a Parquet file.
#' @param row_groups Integer vector of row groups, starting at 1.
#' @param columns Character vector of column names, or `NULL` for all.
#' @return An [arrow::Table] with the rows of those groups in file order;
#'   no R types are restored and no geometry is decoded. Counts one
#'   `file_open`. Aborts with class `rcs_error_backend` when the file cannot
#'   be read, and (internal error) when a row group does not exist; a
#'   column the file lacks aborts with class `rcs_error_argument`.
#' @noRd
files_read_row_groups <- function(be, path, row_groups, columns = NULL) {
  fs <- be_arrow_fs(be)
  with_parquet_reader(fs, path, be, function(reader) {
    n <- reader$num_row_groups
    row_groups <- sort(unique(as.integer(row_groups)))
    if (length(row_groups) == 0 || anyNA(row_groups) || any(row_groups < 1L | row_groups > n)) {
      cli::cli_abort(
        "{.path {path}} has {n} row group{?s}; asked for {.val {row_groups}}.",
        .internal = TRUE
      )
    }
    schema <- reader$GetSchema()
    if (is.null(columns)) {
      return(reader$ReadRowGroups(row_groups - 1L))
    }
    unknown <- setdiff(columns, names(schema))
    if (length(unknown) > 0) {
      cli::cli_abort(
        "{.path {path}} has no column{?s} {.field {unknown}}.",
        class = "rcs_error_argument"
      )
    }
    table <- reader$ReadRowGroups(row_groups - 1L, parquet_leaf_indices(schema, columns))
    table[, columns]
  })
}
