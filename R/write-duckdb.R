# Writing a lazy table on a DuckDB connection (plan 0002, D36-D38, D40).
#
# `store_write(st, x)` with `x` a lazy table on a DuckDB connection: the
# query is materialised once inside DuckDB as a temporary table
# `rcs_write_<random>` with the row number `.rcs_tmp`, every later
# statement reads that table, and it is dropped when `store_write()` ends,
# also on error. The key and the partitions are checked in DuckDB; the rows
# are streamed in batches of `rcs_option("rcs.duckdb_batch_rows")` rows
# into one Parquet writer per output file, re-buffered so that every row
# group holds exactly `rows_per_group` rows except the last of a file. The
# files, their names, the entry and the manifest equal those of
# `store_write()` of the same rows collected into R (`files_finish()`).
# Landing is the ordinary path; DuckDB never uploads.

# Input -------------------------------------------------------------------------

# Is `x` a lazy table on a DuckDB connection?
is_duckdb_lazy <- function(x) {
  if (!inherits(x, "tbl_lazy")) {
    return(FALSE)
  }
  if (inherits(x, "tbl_duckdb_connection")) {
    return(TRUE)
  }
  con <- tryCatch(dbplyr::remote_con(x), error = function(e) NULL)
  inherits(con, "duckdb_connection")
}

# A lazy table on another backend.
abort_lazy_backend <- function(x, call) {
  cli::cli_abort(
    c(
      "{.arg x} is a lazy table on a database other than DuckDB.",
      i = "Collect it with {.fn dplyr::collect} first, or write it from a DuckDB connection."
    ),
    class = "rcs_error_argument", call = call
  )
}

# D36: an update needs the stored partitions in R.
check_duckdb_mode <- function(mode, call) {
  if (identical(mode, "update")) {
    cli::cli_abort(
      c(
        "A lazy DuckDB table cannot be written with {.code mode = \"update\"}.",
        i = "Collect the rows with {.fn dplyr::collect} and update from R, or write the whole dataset with {.code mode = \"replace\"}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  invisible()
}

check_duckdb_write <- function() {
  rlang::check_installed(c("duckdb", "DBI", "dbplyr"), reason = "to write a lazy DuckDB table.")
}

# Columns the package computes; dropped from `x` (D36).
duckdb_package_columns <- c(".rcs_id", "h3", "bbox", "geom")

# DuckDB types Arrow cannot write (D38).
duckdb_unsupported_type <- "^(HUGEINT|UHUGEINT|INTERVAL|UNION|MAP)\\b"

# D38: the columns of types Arrow cannot write abort, one line per column.
check_duckdb_types <- function(cols, types, call) {
  bad <- grepl(duckdb_unsupported_type, types)
  if (!any(bad)) {
    return(invisible())
  }
  esc <- function(v) gsub("([{}])", "\\1\\1", v)
  lines <- paste0("{.field ", esc(cols[bad]), "}: ", esc(types[bad]))
  cli::cli_abort(
    c(
      "{sum(bad)} column{?s} of {.arg x} {?has/have} a DuckDB type that cannot be stored:",
      rlang::set_names(lines, rep("x", length(lines))),
      i = "Cast {cli::qty(sum(bad))}{?it/them} to a supported type in the query, for example with {.code CAST(... AS VARCHAR)}."
    ),
    class = "rcs_error_argument", call = call
  )
}

#' The Arrow schema of the files written from DuckDB
#'
#' The schema inferred from the R prototype, except the timestamp columns
#' (D38): a DuckDB `TIMESTAMP` is stored without time zone (its wall clock)
#' and a `TIMESTAMP WITH TIME ZONE` as UTC, in the unit DuckDB gives, so
#' that the files do not depend on the time zone of the R session.
#'
#' @param schema The schema `files_arrow_schema()` infers.
#' @param duck The Arrow schema of the same columns as DuckDB exports them.
#' @param types The DuckDB types of the columns.
#' @return An Arrow schema.
#' @noRd
duckdb_arrow_schema <- function(schema, duck, types) {
  stamp <- which(grepl("^TIMESTAMP", types))
  if (length(stamp) == 0) {
    return(schema)
  }
  fields <- schema$fields
  for (i in stamp) {
    unit <- c("s", "ms", "us", "ns")[duck$fields[[i]]$type$unit() + 1L]
    zone <- if (grepl("WITH TIME ZONE", types[[i]], fixed = TRUE)) "UTC" else ""
    fields[[i]] <- arrow::field(fields[[i]]$name, arrow::timestamp(unit, timezone = zone))
  }
  arrow::schema(!!!fields)
}

# Staging -------------------------------------------------------------------------

#' Stage a lazy DuckDB table as a table dataset
#'
#' @param a The arguments of `store_write()` as `stage_full()` gets them;
#'   `a$call` is the frame of `store_write()`, which the temporary table
#'   lives as long as.
#' @return A staging plan as `stage_full()` returns it, with `check`: the
#'   serialization check for DuckDB input (D40).
#' @noRd
stage_duckdb <- function(a) {
  check_duckdb_write()
  call <- a$call
  con <- dbplyr::remote_con(a$x)
  tmp <- duckdb_materialise(con, a$x, frame = call)
  q_tmp <- duckdb_ident(con, tmp)

  described <- DBI::dbGetQuery(con, paste("DESCRIBE", q_tmp))
  names_all <- setdiff(described$column_name, ".rcs_tmp")
  dropped <- intersect(names_all, duckdb_package_columns)
  if (length(dropped) > 0) {
    rcs_inform(c(
      i = "Column{?s} {.field {dropped}} of {.arg x} {?is/are} the package's own and {?is/are} dropped."
    ))
  }
  cols <- setdiff(names_all, dropped)
  types <- described$column_type[match(cols, described$column_name)]
  check_duckdb_types(cols, types, call)
  select <- paste(duckdb_ident(con, cols), collapse = ", ")
  proto_table <- duckdb_frame(con, paste("SELECT", select, "FROM", q_tmp, "LIMIT 0"), table = TRUE)
  proto <- duckdb_as_tibble(proto_table)

  key <- as.character(a$key %||% character())
  check_key(proto, key, call = call)
  duckdb_check_key(con, q_tmp, key, call)

  partition <- as.character(a$partition %||% character())
  if (length(partition) > 0) {
    if (!is.character(partition) || anyNA(partition)) {
      cli::cli_abort("{.arg partition} must be distinct column names.", class = "rcs_error_argument", call = call)
    }
    known <- partition[partition %in% cols]
    values <- if (length(known) == length(partition)) {
      duckdb_frame(con, paste(
        "SELECT DISTINCT", paste(duckdb_ident(con, partition), collapse = ", "), "FROM", q_tmp
      ))
    } else {
      proto
    }
    # the checks and the message of `partition_plan()`, on the distinct values
    partition <- partition_plan(values, partition, a$max_files, call = call)$partition
  }

  descriptions <- a$columns %||% stored_descriptions(a$existing, cols)
  schema <- duckdb_arrow_schema(files_arrow_schema(proto), proto_table$schema, types)
  spec <- files_columns_spec(proto, schema, descriptions, call = call, cells_by_name = FALSE)
  meta <- files_meta(
    dataset = a$dataset, kind = "table", title = a$title,
    description = a$description, spec = spec, key = key, sorted_by = key,
    partition = partition, source = a$source, inputs = a$inputs,
    crs = NA_character_, h3_res = NA_integer_, geocode_engine = NA_character_,
    index_of = NA_character_, history = a$history
  )
  data_dir <- file.path(a$dir, "data")
  tmp_dir <- files_tmp_dir(data_dir, a$dataset)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  order_by <- duckdb_order_by(con, c(partition, key))
  total <- DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_tmp))$n
  new <- duckdb_write_files(
    con,
    sql = paste("SELECT", select, "FROM", q_tmp, "ORDER BY", order_by),
    partition = partition, proto = proto, schema = schema,
    rcs_json = files_rcs_json(meta), rows_per_group = a$rows_per_group,
    tmp_dir = tmp_dir, total = as.numeric(total)
  )
  staged <- files_finish(meta, new, NULL, created_of(a$existing, a$now), FALSE, FALSE, data_dir)

  check <- function(be, files, entry) {
    duckdb_check_files(con, q_tmp, cols, key, partition, be, files, entry)
  }
  list(data = staged_src(staged), index = NULL, reference = NULL, data_dir = data_dir, check = check)
}

#' Materialise the query of a lazy table as a temporary DuckDB table
#'
#' @param con The DuckDB connection.
#' @param x The lazy table.
#' @param frame The frame whose end drops the table.
#' @return The table's name, `rcs_write_<random>`. It holds every column of
#'   `x` and `.rcs_tmp`, the row number (D37).
#' @noRd
duckdb_materialise <- function(con, x, frame) {
  name <- paste0("rcs_write_", substr(md5_string(paste(Sys.getpid(), as.numeric(Sys.time()), stats::runif(1))), 1, 12))
  q_name <- duckdb_ident(con, name)
  withr::defer(duckdb_drop(con, q_name), envir = frame)
  sql <- as.character(dbplyr::sql_render(x, con = con))
  duckdb_exec(con, paste0(
    "CREATE TEMPORARY TABLE ", q_name, " AS SELECT *, row_number() OVER () AS \".rcs_tmp\" FROM (",
    sql, ") AS rcs_query"
  ))
  name
}

duckdb_drop <- function(con, q_name) {
  if (DBI::dbIsValid(con)) {
    try(DBI::dbExecute(con, paste("DROP TABLE IF EXISTS", q_name)), silent = TRUE)
  }
  invisible()
}

duckdb_ident <- function(con, x) {
  as.character(DBI::dbQuoteIdentifier(con, x))
}

# `ORDER BY` of the stream: the columns, then the row number (D38).
duckdb_order_by <- function(con, columns) {
  by <- if (length(columns) > 0) paste(duckdb_ident(con, columns), "NULLS LAST")
  paste(c(by, "\".rcs_tmp\""), collapse = ", ")
}

# A small result as a tibble, through Arrow (the types the stream gets),
# or as the Arrow table with `table = TRUE`.
duckdb_frame <- function(con, sql, table = FALSE) {
  withr::local_options(arrow.int64_downcast = FALSE)
  res <- DBI::dbSendQuery(con, sql, arrow = TRUE)
  on.exit(DBI::dbClearResult(res), add = TRUE)
  out <- duckdb::duckdb_fetch_record_batch(res)$read_table()
  if (table) {
    return(out)
  }
  duckdb_as_tibble(out)
}

# An Arrow table or record batch as a tibble; BIGINT stays `integer64`.
duckdb_as_tibble <- function(x) {
  withr::local_options(arrow.int64_downcast = FALSE)
  tibble::as_tibble(as.data.frame(x))
}

# D38: key uniqueness in DuckDB; the first five repeated values in the
# order of their first rows.
duckdb_check_key <- function(con, q_tmp, key, call) {
  if (length(key) == 0) {
    return(invisible())
  }
  q_key <- paste(duckdb_ident(con, key), collapse = ", ")
  groups <- paste("FROM", q_tmp, "GROUP BY", q_key, "HAVING count(*) > 1")
  n <- DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM (SELECT 1", groups, ")"))$n
  if (n == 0) {
    return(invisible())
  }
  values <- duckdb_frame(con, paste(
    "SELECT", q_key, groups, "ORDER BY min(\".rcs_tmp\") LIMIT 5"
  ))
  abort_key_repeats(key, values, as.numeric(n), call)
}

# Streaming -----------------------------------------------------------------------

#' Stream the rows of a query into Parquet files
#'
#' One file per run of equal partition values (the query is ordered by
#' them), written by an `arrow::ParquetFileWriter` with the schema and the
#' metadata `files_write_parquet()` writes, so that the bytes equal those of
#' `files_stage()` for the same rows.
#'
#' @param con The DuckDB connection.
#' @param sql The ordered query.
#' @param partition The partition columns, or `character()`.
#' @param proto A zero-row tibble with the columns of the query.
#' @param schema,rcs_json The Arrow schema and the `rcs` JSON of the files.
#' @param rows_per_group Rows per row group.
#' @param tmp_dir Folder for the files, named `part-<i>.parquet`.
#' @param total Rows of the query (for the progress bar).
#' @return A list of `files_file_facts()`, one per file.
#' @noRd
duckdb_write_files <- function(con, sql, partition, proto, schema, rcs_json,
                               rows_per_group, tmp_dir, total) {
  if (total == 0) {
    path <- file.path(tmp_dir, "part-1.parquet")
    files_write_parquet(proto, path, schema, rcs_json, NULL, rows_per_group)
    return(list(files_file_facts(path, NULL, 0)))
  }
  n <- rcs_option("rcs.duckdb_batch_rows")
  withr::local_options(arrow.int64_downcast = FALSE)
  batches <- duckdb_batches(con, sql, n)
  on.exit(batches$close(), add = TRUE)
  bar <- NULL
  if (!isTRUE(rcs_option("rcs.quiet"))) {
    bar <- write_progress(phase = "Writing files", total = total, batches = ceiling(total / n))
  }

  out <- list()
  current <- NULL
  on.exit(if (!is.null(current)) parquet_stream_abandon(current), add = TRUE)
  done <- 0
  k <- 0L
  while (!is.null(batch <- batches$next_batch())) {
    k <- k + 1L
    data <- tibble::as_tibble(as.data.frame(batch))
    runs <- if (length(partition) > 0) {
      vctrs::vec_group_loc(vctrs::vec_identify_runs(data[partition]))$loc
    } else {
      list(seq_len(nrow(data)))
    }
    for (rows in runs) {
      part <- vctrs::vec_slice(data, rows)
      values <- if (length(partition) > 0) as.list(part[1, partition])
      pv <- partition_values_json(values)
      if (is.null(current) || !identical(current$pv, pv)) {
        if (!is.null(current)) {
          out[[length(out) + 1L]] <- parquet_stream_close(current)
        }
        path <- file.path(tmp_dir, paste0("part-", length(out) + 1L, ".parquet"))
        current <- parquet_stream_open(path, values, pv, schema, rcs_json, rows_per_group)
      }
      parquet_stream_add(current, part)
    }
    done <- done + nrow(data)
    if (!is.null(bar)) write_progress(bar, rows = done, batch = k)
  }
  if (!is.null(current)) {
    out[[length(out) + 1L]] <- parquet_stream_close(current)
    current <- NULL
  }
  if (!is.null(bar)) write_progress(bar, done = TRUE)
  out
}

# One output file being streamed: an environment with the path, the
# partition values, the writer (opened with the first row group), the rows
# buffered for the next row group and the rows written.
parquet_stream_open <- function(path, values, pv, schema, rcs_json, rows_per_group) {
  f <- new.env(parent = emptyenv())
  f$path <- path
  f$values <- values
  f$pv <- pv
  f$schema <- schema
  f$rcs_json <- rcs_json
  f$rows_per_group <- as.integer(rows_per_group)
  f$buffer <- NULL
  f$rows <- 0
  f$writer <- NULL
  f$sink <- NULL
  f
}

parquet_stream_add <- function(f, data) {
  f$buffer <- if (is.null(f$buffer)) data else vctrs::vec_rbind(f$buffer, data)
  size <- f$rows_per_group
  while (nrow(f$buffer) >= size) {
    parquet_stream_group(f, vctrs::vec_slice(f$buffer, seq_len(size)))
    f$buffer <- vctrs::vec_slice(f$buffer, -seq_len(size))
  }
  invisible(f)
}

# One row group, converted exactly as `files_write_parquet()` converts.
parquet_stream_group <- function(f, chunk) {
  table <- arrow::arrow_table(files_arrow_values(chunk), schema = f$schema)
  table$metadata$rcs <- f$rcs_json
  if (is.null(f$writer)) {
    dir.create(dirname(f$path), recursive = TRUE, showWarnings = FALSE)
    f$sink <- arrow::FileOutputStream$create(f$path)
    f$writer <- arrow::ParquetFileWriter$create(
      table$schema, f$sink,
      properties = arrow::ParquetWriterProperties$create(names(table), compression = "zstd")
    )
  }
  f$writer$WriteTable(table, chunk_size = f$rows_per_group)
  f$rows <- f$rows + nrow(chunk)
  invisible(f)
}

parquet_stream_close <- function(f) {
  if (!is.null(f$buffer) && nrow(f$buffer) > 0) {
    parquet_stream_group(f, f$buffer)
  }
  f$buffer <- NULL
  f$writer$Close()
  f$sink$close()
  f$writer <- NULL
  files_file_facts(f$path, f$values, f$rows)
}

# After an error: close the file so that its folder can be removed.
parquet_stream_abandon <- function(f) {
  if (!is.null(f$writer)) try(f$writer$Close(), silent = TRUE)
  if (!is.null(f$sink)) try(f$sink$close(), silent = TRUE)
  invisible()
}

#' Batches of a DuckDB query as Arrow record batches
#'
#' @param con A DuckDB connection.
#' @param sql The query.
#' @param n Most rows per batch.
#' @return An iterator: a list with `next_batch()` (the next
#'   `arrow::RecordBatch` of at most `n` rows, larger ones re-sliced, or
#'   `NULL` at the end, which also clears the result), `close()` (clears
#'   the result; safe to call twice) and `schema`. Only one batch is held
#'   in R at a time.
#' @noRd
duckdb_batches <- function(con, sql, n) {
  n <- as.integer(n)
  if (is.na(n) || n < 1L) {
    cli::cli_abort("{.code rcs.duckdb_batch_rows} must be a positive whole number.", class = "rcs_error_argument")
  }
  res <- DBI::dbSendQuery(con, sql, arrow = TRUE)
  open <- TRUE
  close <- function() {
    if (open) {
      open <<- FALSE
      DBI::dbClearResult(res)
    }
    invisible()
  }
  reader <- tryCatch(duckdb::duckdb_fetch_record_batch(res, chunk_size = n), error = function(e) {
    close()
    rlang::cnd_signal(e)
  })
  pending <- NULL
  next_batch <- function() {
    while (is.null(pending) || pending$num_rows == 0) {
      if (!open) {
        return(NULL)
      }
      pending <<- reader$read_next_batch()
      if (is.null(pending)) {
        close()
        return(NULL)
      }
    }
    if (pending$num_rows <= n) {
      out <- pending
      pending <<- NULL
    } else {
      out <- pending$Slice(0, n)
      pending <<- pending$Slice(n)
    }
    out
  }
  list(next_batch = next_batch, close = close, schema = reader$schema)
}

#' Progress of a phase of a DuckDB write
#'
#' A cli progress bar: rows done of the total, batch k of K, time left.
#' The caller creates it only when `rcs.quiet` is not set.
#'
#' @param bar `NULL` to create a bar, else the bar to update.
#' @param phase Label of the phase (creation).
#' @param total Rows of the phase (creation).
#' @param batches Number of batches K (creation).
#' @param rows Rows done (update).
#' @param batch The batch k just done (update).
#' @param done `TRUE` ends the bar.
#' @param .envir The frame whose end ends the bar.
#' @return The bar: a list with `id`, invisibly.
#' @noRd
write_progress <- function(bar = NULL, phase = NULL, total = NULL, batches = NULL,
                           rows = 0, batch = 0L, done = FALSE, .envir = parent.frame()) {
  if (is.null(bar)) {
    id <- cli::cli_progress_bar(
      format = paste(
        "{cli::pb_extra$phase} {cli::pb_bar} {cli::pb_current}/{cli::pb_total} rows",
        "| batch {cli::pb_extra$batch}/{cli::pb_extra$batches} | {cli::pb_eta}"
      ),
      total = total, clear = TRUE,
      extra = list(phase = phase, batch = 0L, batches = batches),
      .envir = .envir
    )
    return(invisible(list(id = id)))
  }
  if (isTRUE(done)) {
    cli::cli_progress_done(id = bar$id)
  } else {
    cli::cli_progress_update(id = bar$id, set = rows, extra = list(batch = batch))
  }
  invisible(bar)
}

# Check ---------------------------------------------------------------------------

#' The serialization check of files staged from DuckDB (D40)
#'
#' Per file: the row count of the footer equals the rows streamed, and up
#' to 20 sampled rows of one row group equal the rows at the same positions
#' of the file's partition in the materialised table, ordered as streamed
#' (by the key, then `.rcs_tmp`; keyless rows by `.rcs_tmp` alone).
#'
#' @return A tibble as `check_serialization()` returns it.
#' @noRd
duckdb_check_files <- function(con, q_tmp, cols, key, partition, be, files, entry, n = 20L) {
  withr::local_options(arrow.int64_downcast = FALSE)
  spec <- columns_from_json(entry$columns)
  select <- paste(duckdb_ident(con, cols), collapse = ", ")
  order_by <- duckdb_order_by(con, key)
  rows <- lapply(seq_len(nrow(files)), function(i) {
    path <- files$path[[i]]
    problem <- tryCatch(
      duckdb_check_file(con, q_tmp, select, order_by, partition, be, path, files$rows[[i]], spec, n),
      rcs_error_backend = function(e) paste("it cannot be read:", first_line(conditionMessage(e)))
    )
    if (is.na(problem)) {
      check_row(be$uri, entry$dataset, path, "ok")
    } else {
      check_row(be$uri, entry$dataset, path, "failed", problem)
    }
  })
  vctrs::vec_rbind(check_empty(), !!!rows)
}

duckdb_check_file <- function(con, q_tmp, select, order_by, partition, be, path, streamed, spec, n) {
  groups <- files_row_groups(be, path)
  footer <- sum(groups$rows)
  if (footer != streamed) {
    return(paste0("its footer holds ", footer, " rows, ", streamed, " were streamed"))
  }
  if (footer == 0) {
    return(NA_character_)
  }
  pick <- withr::with_preserve_seed({
    g <- sample.int(nrow(groups), 1L)
    take <- sort(sample.int(groups$rows[[g]], min(n, groups$rows[[g]])))
    list(g = g, take = take)
  })
  offset <- sum(groups$rows[seq_len(pick$g - 1L)])
  table <- files_read_row_groups(be, path, groups$row_group[[pick$g]])
  data <- check_sample_rows(table, pick$take, spec)

  where <- ""
  if (length(partition) > 0) {
    values <- data[1, partition]
    name <- paste0("rcs_check_", substr(md5_string(paste(path, stats::runif(1))), 1, 12))
    duckdb::duckdb_register(con, name, as.data.frame(values), overwrite = TRUE)
    on.exit(try(duckdb::duckdb_unregister(con, name), silent = TRUE), add = TRUE)
    where <- paste0(
      " WHERE (", paste(duckdb_ident(con, partition), collapse = ", "), ") IN (SELECT ",
      paste(duckdb_ident(con, partition), collapse = ", "), " FROM ", duckdb_ident(con, name), ")"
    )
  }
  positions <- paste(format(offset + pick$take, scientific = FALSE, trim = TRUE), collapse = ", ")
  ref <- duckdb_frame(con, paste0(
    "SELECT ", select, " FROM (SELECT ", select, ", row_number() OVER (ORDER BY ", order_by,
    ") AS \".rcs_pos\" FROM ", q_tmp, where, ") WHERE \".rcs_pos\" IN (", positions,
    ") ORDER BY \".rcs_pos\""
  ))
  ref <- restore_types(ref, spec)
  if (nrow(ref) != nrow(data)) {
    return(paste0(nrow(data) - nrow(ref), " sampled rows are not in x"))
  }
  shared <- intersect(names(data), names(ref))
  differ <- shared[!vapply(shared, function(col) {
    identical(normalise_values(data[[col]]), normalise_values(ref[[col]]))
  }, logical(1))]
  if (length(differ) > 0) {
    return(paste0(
      "column", if (length(differ) > 1) "s", " ", paste(differ, collapse = ", "),
      " differ", if (length(differ) == 1) "s", " from x"
    ))
  }
  NA_character_
}
