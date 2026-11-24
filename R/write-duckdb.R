# Writing a lazy table on a DuckDB connection (plan 0002, D36-D38, D40;
# plan 0004, D-B1-D-B6).
#
# `store_write(st, x)` with `x` a lazy table on a DuckDB connection runs
# with `preserve_insertion_order = true`, the caller's setting restored
# when `store_write()` ends (D-B6). A table (no `geometry`) with a
# partition is streamed by partition (`stage_duckdb_streamed()`): the query
# is described, checked and grouped as a subquery, and each partition is
# copied in turn into the temporary table `rcs_write_<random>_part`,
# written, checked and dropped. Otherwise the query is materialised once
# inside DuckDB as a temporary table `rcs_write_<random>` with the row
# number `.rcs_tmp`, every later statement reads that table, and it is
# dropped when `store_write()` ends, also on error. The key and the
# partitions are checked in DuckDB; the rows
# are streamed in batches of `rcs_option("rcs.duckdb_batch_rows")` rows
# into one Parquet writer per output file, re-buffered so that every row
# group holds exactly `rows_per_group` rows except the last of a file. The
# files, their names, the entry and the manifest equal those of
# `store_write()` of the same rows collected into R (`files_finish()`).
# Landing is the ordinary path; DuckDB never uploads. A table with a column
# `geometry` (WKB or `GEOMETRY`) is a geospatial dataset (D39): its
# geocodes pass through R in batches (`stage_duckdb_geo()`).

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

# DuckDB types Arrow cannot write (D38), anywhere in a type string: at top
# level or nested in a STRUCT, a LIST, an ARRAY or a MAP.
duckdb_unsupported_type <- "\\b(HUGEINT|UHUGEINT|INTERVAL|UNION|MAP)\\b"

# Does a DuckDB type string hold an unsupported type? Quoted field names
# (`STRUCT("map" INTEGER)`) and quoted ENUM values are not types.
duckdb_type_unsupported <- function(types) {
  bare <- gsub("\"([^\"]|\"\")*\"", "\"\"", types)
  bare <- gsub("'([^']|'')*'", "''", bare)
  grepl(duckdb_unsupported_type, bare)
}

# D38: the columns of types Arrow cannot write abort, one line per column.
check_duckdb_types <- function(cols, types, call) {
  bad <- duckdb_type_unsupported(types)
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
#' Sets `preserve_insertion_order = true` for the rest of `store_write()`
#' (D-B6), then streams a table with a partition by partition (D-B1,
#' `stage_duckdb_streamed()`), unless `options(rcs.duckdb_stream = FALSE)`;
#' anything else is materialised (`stage_duckdb_materialised()`).
#'
#' @param a The arguments of `store_write()` as `stage_full()` gets them;
#'   `a$call` is the frame of `store_write()`, which the temporary tables
#'   live as long as; `a$check` is its `check`.
#' @return A staging plan as `stage_full()` returns it, with `check`: the
#'   serialization check for DuckDB input (D40).
#' @noRd
stage_duckdb <- function(a) {
  check_duckdb_write()
  con <- dbplyr::remote_con(a$x)
  duckdb_local_insertion_order(con, frame = a$call)
  sql <- as.character(dbplyr::sql_render(a$x, con = con))
  names_all <- DBI::dbGetQuery(con, paste0("DESCRIBE SELECT * FROM (", sql, ") AS rcs_query LIMIT 0"))$column_name
  geospatial <- "geometry" %in% setdiff(names_all, duckdb_package_columns)
  partitioned <- length(a$partition %||% character()) > 0
  if (!geospatial && partitioned && isTRUE(rcs_option("rcs.duckdb_stream"))) {
    return(stage_duckdb_streamed(a, con, sql))
  }
  stage_duckdb_materialised(a, con)
}

#' Stage a lazy DuckDB table through one materialised copy
#'
#' The query is copied once into `rcs_write_<random>` (D37), which the key
#' check, the partition values, the stream and the serialization check
#' (run later by `store_write()`, D40) all read. A table with a column
#' `geometry` goes on to `stage_duckdb_geo()`.
#'
#' @param a The arguments of `store_write()`.
#' @param con The DuckDB connection.
#' @return A staging plan, as `stage_duckdb()`.
#' @noRd
stage_duckdb_materialised <- function(a, con) {
  call <- a$call
  tmp <- duckdb_materialise(con, a$x, frame = call)
  q_tmp <- duckdb_ident(con, tmp)
  described <- duckdb_describe(con, q_tmp, call)
  cols <- described$cols
  types <- described$types
  if ("geometry" %in% cols) {
    return(stage_duckdb_geo(a, con, tmp, cols, types))
  }
  select <- paste(duckdb_ident(con, cols), collapse = ", ")
  proto_table <- duckdb_frame(con, paste("SELECT", select, "FROM", q_tmp, "LIMIT 0"), table = TRUE)
  proto <- duckdb_as_tibble(proto_table)

  key <- as.character(a$key %||% character())
  check_key(proto, key, call = call)
  duckdb_check_key(con, q_tmp, key, call)
  partition <- duckdb_partition_values(con, q_tmp, a, cols, proto)$partition

  table <- duckdb_table_meta(a, proto, proto_table, types, key, partition)
  data_dir <- file.path(a$dir, "data")
  tmp_dir <- files_tmp_dir(data_dir, a$dataset)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  order_by <- duckdb_order_by(con, c(partition, key))
  total <- DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_tmp))$n
  new <- duckdb_write_files(
    con,
    sql = paste("SELECT", select, "FROM", q_tmp, "ORDER BY", order_by),
    partition = partition, proto = proto, schema = table$schema,
    rcs_json = files_rcs_json(table$meta), rows_per_group = a$rows_per_group,
    tmp_dir = tmp_dir, total = as.numeric(total)
  )
  staged <- files_finish(table$meta, new, NULL, created_of(a$existing, a$now), FALSE, FALSE, data_dir)

  check <- function(be, files, entry) {
    duckdb_check_files(con, q_tmp, cols, key, partition, be, files, entry)
  }
  list(data = staged_src(staged), index = NULL, reference = NULL, data_dir = data_dir, check = check)
}

#' Stage a lazy DuckDB table partition by partition
#'
#' D-B2: the query runs as a subquery and is never copied whole. It is
#' described, its key is checked with one grouped query, and its distinct
#' partition values (with their row counts) give the files. Then, for each
#' partition in the order of `partition_plan()`, its rows are copied into
#' the temporary table `rcs_write_<random>_part` (the values bound as
#' parameters), written to one file, checked against that table (D-B3,
#' unless `check = FALSE`) and dropped. With a key the rows are ordered by
#' the key alone (unique, so total); without one, by their row number in
#' the partition, `.rcs_tmp`. The files equal those of
#' `stage_duckdb_materialised()` (D-B4).
#'
#' @param a The arguments of `store_write()`.
#' @param con The DuckDB connection.
#' @param sql The rendered query of `a$x`.
#' @return A staging plan, as `stage_duckdb()`; its `check` returns the
#'   results collected in the loop.
#' @noRd
stage_duckdb_streamed <- function(a, con, sql) {
  call <- a$call
  from <- paste0("(", sql, ") AS rcs_query")
  described <- duckdb_describe(con, from, call)
  cols <- described$cols
  types <- described$types
  select <- paste(duckdb_ident(con, cols), collapse = ", ")
  proto_table <- duckdb_frame(con, paste("SELECT", select, "FROM", from, "LIMIT 0"), table = TRUE)
  proto <- duckdb_as_tibble(proto_table)

  key <- as.character(a$key %||% character())
  check_key(proto, key, call = call)
  numbered <- paste0("(SELECT *, row_number() OVER () AS \".rcs_tmp\" FROM ", from, ") AS rcs_numbered")
  duckdb_check_key(con, from, key, call, from_numbered = numbered)
  parts <- duckdb_partition_values(con, from, a, cols, proto, counts = TRUE)
  partition <- parts$partition
  values <- parts$values
  rows <- as.numeric(values$.rcs_n)

  table <- duckdb_table_meta(a, proto, proto_table, types, key, partition)
  rcs_json <- files_rcs_json(table$meta)
  spec <- columns_from_json(table$meta$columns)
  data_dir <- file.path(a$dir, "data")
  tmp_dir <- files_tmp_dir(data_dir, a$dataset)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

  q_part <- duckdb_ident(con, paste0(duckdb_table_name(), "_part"))
  withr::defer(duckdb_drop(con, q_part), envir = call)
  number <- length(key) == 0
  create <- paste0(
    "CREATE TEMPORARY TABLE ", q_part, " AS SELECT *",
    if (number) ", row_number() OVER () AS \".rcs_tmp\"",
    " FROM ", from, " WHERE ",
    paste(duckdb_ident(con, partition), "IS NOT DISTINCT FROM ?", collapse = " AND ")
  )
  order_by <- duckdb_order_by(con, key, numbered = number)
  stream <- paste("SELECT", select, "FROM", q_part, "ORDER BY", order_by)
  check <- !isFALSE(a$check)
  progress <- duckdb_progress(sum(rows), rcs_option("rcs.duckdb_batch_rows"))

  new <- vector("list", nrow(values))
  problems <- character()
  for (i in seq_len(nrow(values))) {
    params <- unname(lapply(partition, function(p) values[[p]][[i]]))
    DBI::dbExecute(con, create, params = params)
    part_dir <- file.path(tmp_dir, i)
    facts <- duckdb_write_files(
      con, sql = stream, partition = partition, proto = proto, schema = table$schema,
      rcs_json = rcs_json, rows_per_group = a$rows_per_group,
      tmp_dir = part_dir, total = rows[[i]], progress = progress
    )[[1]]
    new[[i]] <- facts
    if (check) {
      problems[[facts$partition_values]] <- duckdb_check_problem(
        con, q_part, select, order_by, character(), be_new(part_dir),
        basename(facts$tmp), facts$rows, spec
      )
    }
    duckdb_drop(con, q_part)
  }
  duckdb_progress_done(progress)
  staged <- files_finish(table$meta, new, NULL, created_of(a$existing, a$now), FALSE, FALSE, data_dir)

  check_results <- function(be, files, entry) {
    out <- lapply(seq_len(nrow(files)), function(i) {
      problem <- unname(problems[files$partition_values[[i]]])
      if (is.na(problem)) {
        check_row(be$uri, entry$dataset, files$path[[i]], "ok")
      } else {
        check_row(be$uri, entry$dataset, files$path[[i]], "failed", problem)
      }
    })
    vctrs::vec_rbind(check_empty(), !!!out)
  }
  list(data = staged_src(staged), index = NULL, reference = NULL, data_dir = data_dir, check = check_results)
}

#' The columns of a DuckDB query or table
#'
#' Drops the package's own columns with one message and aborts on types
#' Arrow cannot write (D36, D38).
#'
#' @param con The DuckDB connection.
#' @param from A `FROM` source: a quoted table, or a subquery with alias.
#' @param call Environment for the errors.
#' @return A list: `cols` (the columns kept) and `types` (their DuckDB
#'   types).
#' @noRd
duckdb_describe <- function(con, from, call) {
  described <- DBI::dbGetQuery(con, paste("DESCRIBE SELECT * FROM", from, "LIMIT 0"))
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
  list(cols = cols, types = types)
}

#' The partition of a DuckDB table write, from its distinct values
#'
#' The checks and the messages of `partition_plan()`, run on the distinct
#' partition values (or on the zero-row prototype when a column is
#' missing, for its message).
#'
#' @param con The DuckDB connection.
#' @param from A `FROM` source of the rows.
#' @param a The arguments of `store_write()`.
#' @param cols The columns of `x` kept.
#' @param proto A zero-row tibble of those columns.
#' @param counts Also count the rows of each partition?
#' @return A list: `partition` (the columns, or `character()`) and
#'   `values` (one row per partition in the order of `partition_plan()`,
#'   with `.rcs_n`, the rows, when `counts`; `NULL` without a partition).
#' @noRd
duckdb_partition_values <- function(con, from, a, cols, proto, counts = FALSE) {
  call <- a$call
  partition <- as.character(a$partition %||% character())
  if (length(partition) == 0) {
    return(list(partition = character(), values = NULL))
  }
  if (!is.character(partition) || anyNA(partition)) {
    cli::cli_abort("{.arg partition} must be distinct column names.", class = "rcs_error_argument", call = call)
  }
  known <- partition[partition %in% cols]
  values <- if (length(known) == length(partition)) {
    q_partition <- paste(duckdb_ident(con, partition), collapse = ", ")
    if (counts) {
      duckdb_frame(con, paste(
        "SELECT", q_partition, ", count(*) AS \".rcs_n\" FROM", from, "GROUP BY", q_partition
      ))
    } else {
      duckdb_frame(con, paste("SELECT DISTINCT", q_partition, "FROM", from))
    }
  } else {
    proto
  }
  # the checks and the message of `partition_plan()`, on the distinct values
  plan <- partition_plan(values[setdiff(names(values), ".rcs_n")], partition, a$max_files, call = call)
  first <- vapply(plan$groups, function(rows) rows[[1]], integer(1))
  list(partition = plan$partition, values = values[first, , drop = FALSE])
}

#' The schema and the file metadata of a DuckDB table write
#'
#' @param a The arguments of `store_write()`.
#' @param proto,proto_table The zero-row prototype as a tibble and as the
#'   Arrow table DuckDB exports.
#' @param types The DuckDB types of the columns.
#' @param key,partition The key and the partition columns.
#' @return A list: `schema` (Arrow) and `meta` (`files_meta()`).
#' @noRd
duckdb_table_meta <- function(a, proto, proto_table, types, key, partition) {
  descriptions <- a$columns %||% stored_descriptions(a$existing, names(proto))
  schema <- duckdb_arrow_schema(files_arrow_schema(proto), proto_table$schema, types)
  spec <- files_columns_spec(proto, schema, descriptions, call = a$call, cells_by_name = FALSE)
  meta <- files_meta(
    dataset = a$dataset, kind = "table", title = a$title,
    description = a$description, spec = spec, key = key, sorted_by = key,
    partition = partition, partition_auto = FALSE, source = a$source, inputs = a$inputs,
    crs = NA_character_, h3_res = NA_integer_, geocode_engine = NA_character_,
    index_of = NA_character_, history = a$history
  )
  list(schema = schema, meta = meta)
}

#' Run a DuckDB write with `preserve_insertion_order = true`
#'
#' D-B6 ("Option A" of plan 0004): under `false`, DuckDB may return the
#' rows of a top-level `ORDER BY` out of order, so the files would be
#' wrong. The setting is turned on when it is off, and the caller's value
#' is restored when `frame` ends, also on error.
#'
#' @param con The DuckDB connection.
#' @param frame The frame whose end restores the setting.
#' @noRd
duckdb_local_insertion_order <- function(con, frame) {
  value <- DBI::dbGetQuery(con, "SELECT current_setting('preserve_insertion_order') AS v")$v
  if (identical(tolower(as.character(value)), "true")) {
    return(invisible())
  }
  duckdb_exec(con, "SET preserve_insertion_order = true")
  withr::defer(
    if (DBI::dbIsValid(con)) {
      try(DBI::dbExecute(con, paste("SET preserve_insertion_order =", tolower(as.character(value)))), silent = TRUE)
    },
    envir = frame
  )
  invisible()
}

# A fresh name for the temporary tables of a write, `rcs_write_<random>`.
duckdb_table_name <- function() {
  paste0("rcs_write_", substr(md5_string(paste(Sys.getpid(), as.numeric(Sys.time()), stats::runif(1))), 1, 12))
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
  name <- duckdb_table_name()
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

# `ORDER BY` of the stream: the columns, then the row number (D38), which
# `numbered = FALSE` leaves out (a unique key alone is a total order).
duckdb_order_by <- function(con, columns, numbered = TRUE) {
  by <- if (length(columns) > 0) paste(duckdb_ident(con, columns), "NULLS LAST")
  paste(c(by, if (numbered) "\".rcs_tmp\""), collapse = ", ")
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
# order of their first rows. `from` is a `FROM` source (a quoted table or a
# subquery with alias); `from_numbered` the same rows with `.rcs_tmp`,
# read only when keys repeat.
duckdb_check_key <- function(con, from, key, call, from_numbered = from) {
  if (length(key) == 0) {
    return(invisible())
  }
  q_key <- paste(duckdb_ident(con, key), collapse = ", ")
  groups <- function(source) paste("FROM", source, "GROUP BY", q_key, "HAVING count(*) > 1")
  n <- DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM (SELECT 1", groups(from), ")"))$n
  if (n == 0) {
    return(invisible())
  }
  values <- duckdb_frame(con, paste(
    "SELECT", q_key, groups(from_numbered), "ORDER BY min(\".rcs_tmp\") LIMIT 5"
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
#' @param file_meta `NULL`, or a function of the partition values of a file
#'   (a named list, or `NULL`) called before the file is opened, returning
#'   a list with `geo` (the `geo` JSON or `NULL`), `bbox` (the one-row
#'   extent of the file's boxes, or `NULL`) and `h3` (the file's cells or
#'   their range, or `NULL`): the facts a geospatial file or an index file
#'   needs whose rows are not in R (D39).
#' @param progress `NULL` (a progress bar of this call's rows), or the
#'   `duckdb_progress()` of a write over several calls, which this call
#'   advances but does not end.
#' @return A list of `files_file_facts()`, one per file.
#' @noRd
duckdb_write_files <- function(con, sql, partition, proto, schema, rcs_json,
                               rows_per_group, tmp_dir, total, file_meta = NULL,
                               progress = NULL) {
  facts_of <- function(values) {
    if (is.null(file_meta)) list() else file_meta(values)
  }
  if (total == 0) {
    path <- file.path(tmp_dir, "part-1.parquet")
    fm <- facts_of(NULL)
    files_write_parquet(proto, path, schema, rcs_json, fm$geo, rows_per_group)
    return(list(files_file_facts(path, NULL, 0, bbox = fm$bbox, h3 = fm$h3)))
  }
  n <- rcs_option("rcs.duckdb_batch_rows")
  withr::local_options(arrow.int64_downcast = FALSE)
  batches <- duckdb_batches(con, sql, n)
  on.exit(batches$close(), add = TRUE)
  own <- is.null(progress)
  if (own) {
    progress <- duckdb_progress(total, n)
  }

  out <- list()
  current <- NULL
  on.exit(if (!is.null(current)) parquet_stream_abandon(current), add = TRUE)
  while (!is.null(batch <- batches$next_batch())) {
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
        current <- parquet_stream_open(path, values, pv, schema, rcs_json, rows_per_group,
          facts = facts_of(values)
        )
      }
      parquet_stream_add(current, part)
    }
    duckdb_progress_add(progress, nrow(data))
  }
  if (!is.null(current)) {
    out[[length(out) + 1L]] <- parquet_stream_close(current)
    current <- NULL
  }
  if (own) {
    duckdb_progress_done(progress)
  }
  out
}

#' The progress of the rows written from DuckDB
#'
#' One bar over `total` rows in batches of `n` rows, as `write_progress()`
#' shows it; none under `rcs.quiet`. A streamed write fetches each
#' partition in its own batches, so the bar counts the batches of `n` rows
#' of the whole write: batch k is shown when `k * n` rows (or all rows) are
#' done.
#'
#' @param total Rows of the write.
#' @param n Rows per batch.
#' @param frame The frame whose end ends the bar.
#' @return An environment: `bar` (or `NULL`), `total`, `n`, `rows` (done)
#'   and `batch` (the last batch shown).
#' @noRd
duckdb_progress <- function(total, n, frame = parent.frame()) {
  p <- new.env(parent = emptyenv())
  p$total <- total
  p$n <- n
  p$rows <- 0
  p$batch <- 0L
  p$bar <- NULL
  if (!isTRUE(rcs_option("rcs.quiet"))) {
    p$bar <- write_progress(
      phase = "Writing files", total = total, batches = ceiling(total / n), .envir = frame
    )
  }
  p
}

duckdb_progress_add <- function(p, rows) {
  p$rows <- p$rows + rows
  if (is.null(p$bar)) {
    return(invisible(p))
  }
  while (p$rows >= min((p$batch + 1) * p$n, p$total) && p$batch < ceiling(p$total / p$n)) {
    p$batch <- p$batch + 1L
    write_progress(p$bar, rows = min(p$batch * p$n, p$total), batch = p$batch)
  }
  invisible(p)
}

duckdb_progress_done <- function(p) {
  if (!is.null(p$bar)) {
    write_progress(p$bar, done = TRUE)
  }
  invisible(p)
}

# One output file being streamed: an environment with the path, the
# partition values, the writer (opened with the first row group), the rows
# buffered for the next row group and the rows written; `facts` as
# `file_meta()` of `duckdb_write_files()` returns them.
parquet_stream_open <- function(path, values, pv, schema, rcs_json, rows_per_group,
                                facts = list()) {
  f <- new.env(parent = emptyenv())
  f$facts <- facts
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
  if (!is.null(f$facts$geo)) {
    table$metadata$geo <- f$facts$geo
  }
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
  files_file_facts(f$path, f$values, f$rows, bbox = f$facts$bbox, h3 = f$facts$h3)
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

# Geospatial ----------------------------------------------------------------------

#' Stage a lazy DuckDB table with a geometry column as a geospatial dataset
#'
#' D39. Pass 1 streams `.rcs_tmp` and the WKB through R in batches: per
#' batch the boxes, the cells and the index rows (the engine of D31, as
#' `geo_encode()` computes them) and the geometry types, staged as Parquet
#' and loaded into the temporary table `<tmp>_geo` (with `.rcs_id`, the row
#' number in the order of `geo_encode()`: `h3`, the key, `.rcs_tmp`) and
#' `<tmp>_index` (index rows with `.rcs_id`). Between the passes, for
#' `partition = "h3"`, the distinct cells come into R and the map
#' `h3 -> h3_p<res>` is staged as `<tmp>_map`. Pass 2 streams the rows,
#' joined in DuckDB and ordered by the partition and `.rcs_id`, into one
#' file per partition, and the index rows into the index file(s). The files
#' equal those of `store_write()` of the same `sf`.
#'
#' `partition` takes what `store_write()` takes for an `sf`: `"h3"` or
#' attribute columns.
#'
#' @param a The arguments of `store_write()`.
#' @param con The DuckDB connection.
#' @param tmp The name of the materialised table.
#' @param cols,types The columns of `x` kept, and their DuckDB types.
#' @return A staging plan as `stage_full()` returns it, with `check` (D40)
#'   and `rebuild` (D32).
#' @noRd
stage_duckdb_geo <- function(a, con, tmp, cols, types) {
  call <- a$call
  q_tmp <- duckdb_ident(con, tmp)
  geom_type <- types[[match("geometry", cols)]]
  if (!grepl("^(BLOB|GEOMETRY)", geom_type)) {
    cli::cli_abort(
      c(
        "Column {.field geometry} of {.arg x} must hold WKB ({.code BLOB}) or be a {.code GEOMETRY}, not {.code {geom_type}}.",
        i = "Convert it in the query, for example with {.code ST_AsWKB()} of the spatial extension."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (is.null(a$crs)) {
    cli::cli_abort(
      c(
        "{.arg crs} is required to write a DuckDB table with a {.field geometry} column.",
        i = "Give the coordinate reference system of the geometries, for example {.code crs = 4326}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  crs <- tryCatch(sf::st_crs(a$crs), error = function(e) sf::NA_crs_)
  if (is.na(crs)) {
    cli::cli_abort(
      "{.arg crs} must be a coordinate reference system that {.fn sf::st_crs} reads.",
      class = "rcs_error_argument", call = call
    )
  }
  crs_json <- geo_crs_json(crs)
  geocode <- isTRUE(a$geocode)
  h3_res <- check_h3_res(a$h3_res, call = call)
  if (geocode) {
    check_h3o()
  }
  key <- as.character(a$key %||% character())
  attrs <- setdiff(cols, "geometry")
  geom_sql <- if (grepl("^GEOMETRY", geom_type)) "ST_AsWKB(t.\"geometry\")" else "t.\"geometry\""

  # the columns of the files, in the order of `geo_encode()$data`
  select_attrs <- if (length(attrs) > 0) paste0("t.", duckdb_ident(con, attrs), collapse = ", ")
  proto_attrs <- duckdb_frame(con, paste(
    "SELECT", paste(c(select_attrs, "1 AS \".rcs_one\""), collapse = ", "), "FROM", q_tmp, "AS t LIMIT 0"
  ))
  proto_attrs$.rcs_one <- NULL
  check_key(proto_attrs, key, call = call)
  duckdb_check_key(con, q_tmp, key, call)
  total <- as.numeric(DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_tmp))$n)
  partition <- duckdb_geo_partition_early(con, q_tmp, a, attrs, proto_attrs, geocode, total, call)

  # pass 1: geocodes in R, staged and loaded into DuckDB
  pass1 <- duckdb_geo_pass1(con, q_tmp, geom_sql, crs, geocode, h3_res, a$geocode_engine, file.path(a$dir, "pass1"))
  q_geo <- duckdb_ident(con, paste0(tmp, "_geo"))
  q_index <- duckdb_ident(con, paste0(tmp, "_index"))
  withr::defer(duckdb_drop(con, q_geo), envir = call)
  withr::defer(duckdb_drop(con, q_index), envir = call)
  key_select <- if (length(key) > 0) paste0(", ", paste(duckdb_ident(con, key), collapse = ", "))
  duckdb_exec(con, paste0(
    "CREATE TEMPORARY TABLE ", q_geo, " AS SELECT p.*, row_number() OVER (ORDER BY ",
    duckdb_order_by(con, c(if (geocode) "h3", key)), ") AS \".rcs_id\" FROM ",
    duckdb_parquet_list(con, pass1$data), " AS p JOIN (SELECT \".rcs_tmp\"", key_select,
    " FROM ", q_tmp, ") AS k USING (\".rcs_tmp\")"
  ))
  if (geocode) {
    duckdb_exec(con, paste0(
      "CREATE TEMPORARY TABLE ", q_index, " AS SELECT g.\".rcs_id\", i.h3, i.h3_main, i.share FROM ",
      duckdb_parquet_list(con, pass1$index), " AS i JOIN ", q_geo, " AS g USING (\".rcs_tmp\")"
    ))
  }
  rebuild <- list(
    rebuilt = duckdb_geo_keys(con, q_tmp, q_geo, key, pass1$rebuilt),
    fallback = duckdb_geo_keys(con, q_tmp, q_geo, key, pass1$fallback)
  )

  # between the passes: the partition map of `partition = "h3"` (D39)
  h3_part <- NULL
  if (identical(partition, "h3")) {
    h3_part <- duckdb_h3_partition(
      con, paste("SELECT DISTINCT h3 FROM", q_geo), a, h3_res,
      name = paste0(tmp, "_map"), path = file.path(a$dir, "pass1", "map.parquet")
    )
    partition <- h3_part$column
    if (partition %in% attrs) {
      duckdb_check_supplied_partition(con, q_tmp, q_geo, h3_part, types[[match(partition, cols)]], call)
      attrs <- setdiff(attrs, partition)
      select_attrs <- if (length(attrs) > 0) paste0("t.", duckdb_ident(con, attrs), collapse = ", ")
      proto_attrs[[partition]] <- NULL
    }
  }

  # pass 2: the data file(s)
  proto <- proto_attrs
  proto$.rcs_id <- bit64::integer64()
  if (geocode) {
    proto$h3 <- bit64::integer64()
  }
  if (!is.null(h3_part)) {
    proto[[partition]] <- bit64::integer64()
  }
  proto$bbox <- bbox_na(0L)
  proto$geometry <- list()
  descriptions <- a$columns %||% stored_descriptions(a$existing, names(proto))
  schema <- files_arrow_schema(proto)
  spec <- files_columns_spec(proto, schema, descriptions, call = call, cells_by_name = TRUE)
  meta <- files_meta(
    dataset = a$dataset, kind = "geospatial", title = a$title,
    description = a$description, spec = spec, key = key,
    sorted_by = c(if (geocode) "h3", if (length(key) > 0) key else ".rcs_id"),
    partition = partition, partition_auto = !is.null(h3_part),
    source = a$source, inputs = a$inputs, crs = crs_json, h3_res = if (geocode) h3_res else NA_integer_,
    geocode_engine = if (geocode) a$geocode_engine else NA_character_,
    index_of = NA_character_, history = a$history
  )
  data_dir <- file.path(a$dir, "data")
  tmp_dir <- files_tmp_dir(data_dir, a$dataset)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  bbox_sql <- paste0(
    "struct_pack(", paste0(bbox_names, " := g.", duckdb_ident(con, paste0(".rcs_", bbox_names)), collapse = ", "), ")"
  )
  # the partition expressions, named by the columns they give
  group <- if (!is.null(h3_part)) {
    rlang::set_names(paste0("m.", duckdb_ident(con, partition)), partition)
  } else if (length(partition) > 0) {
    rlang::set_names(paste0("t.", duckdb_ident(con, partition)), partition)
  } else {
    character()
  }
  from <- paste0(
    q_tmp, " AS t JOIN ", q_geo, " AS g USING (\".rcs_tmp\")",
    if (!is.null(h3_part)) paste0(" LEFT JOIN ", h3_part$q_map, " AS m ON g.h3 = m.h3")
  )
  data_sql <- function(where = "") {
    paste0(
      "SELECT ", paste(c(select_attrs, "g.\".rcs_id\"", if (geocode) "g.h3",
        if (!is.null(h3_part)) paste(group, "AS", duckdb_ident(con, partition)),
        paste(bbox_sql, "AS bbox"), paste(geom_sql, "AS geometry")), collapse = ", "),
      " FROM ", from, where,
      " ORDER BY ", paste(c(if (length(group) > 0) paste(group, "NULLS LAST"), "g.\".rcs_id\""), collapse = ", ")
    )
  }
  new <- duckdb_write_files(
    con, sql = data_sql(), partition = partition, proto = proto, schema = schema,
    rcs_json = files_rcs_json(meta), rows_per_group = a$rows_per_group,
    tmp_dir = tmp_dir, total = pass1$total,
    file_meta = duckdb_file_meta(con, from, group, h3 = if (geocode) "g.h3", crs_json = crs_json)
  )
  staged <- files_finish(meta, new, NULL, created_of(a$existing, a$now), TRUE, geocode, data_dir)

  # the index file
  index <- NULL
  if (geocode) {
    index <- duckdb_stage_index(con, q_index, a, h3_res, tmp)
  }

  check <- function(be, files, entry) {
    duckdb_check_geo_files(con, data_sql, be, files, entry)
  }
  list(
    data = staged_src(staged), index = index, reference = NULL, data_dir = data_dir,
    check = check, rebuild = rebuild
  )
}

#' Pass 1 of a geospatial DuckDB write: geocodes of every row, in batches
#'
#' @param con The DuckDB connection.
#' @param q_tmp The quoted materialised table.
#' @param geom_sql The SQL of the WKB of a row of `t` (the materialised
#'   table).
#' @param crs The CRS of the geometries (`sf::st_crs()`).
#' @param geocode,h3_res,geocode_engine As `store_write()`.
#' @param dir Staging folder for the Parquet files of the pass.
#' @return A list: `data` and `index` (the staged files; per row
#'   `.rcs_tmp`, `h3`, `.rcs_xmin` ... `.rcs_ymax`, `.rcs_gtype`; per index
#'   row `.rcs_tmp`, `h3`, `h3_main`, `share`), `rebuilt` and `fallback`
#'   (`.rcs_tmp` of the rows rebuilt on the sphere and of the planar
#'   fallbacks, D32), `total` (rows).
#' @noRd
duckdb_geo_pass1 <- function(con, q_tmp, geom_sql, crs, geocode, h3_res, geocode_engine, dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  withr::local_options(arrow.int64_downcast = FALSE)
  total <- as.numeric(DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_tmp))$n)
  n <- rcs_option("rcs.duckdb_batch_rows")
  write_part <- function(data, kind, k) {
    path <- file.path(dir, paste0(kind, "-", k, ".parquet"))
    arrow::write_parquet(data, path)
    path
  }
  # zero-row files fix the schema of the pass, also for an empty table
  empty <- duckdb_geo_batch(list(), bit64::integer64(), crs, geocode, h3_res, geocode_engine)
  data_files <- write_part(empty$data, "data", 0L)
  index_files <- write_part(empty$index, "index", 0L)
  rebuilt <- list()
  fallback <- list()
  if (total > 0) {
    batches <- duckdb_batches(con, paste0(
      "SELECT t.\".rcs_tmp\", ", geom_sql, " AS geometry FROM ", q_tmp, " AS t ORDER BY t.\".rcs_tmp\""
    ), n)
    on.exit(batches$close(), add = TRUE)
    bar <- NULL
    if (!isTRUE(rcs_option("rcs.quiet"))) {
      bar <- write_progress(phase = "Geocoding", total = total, batches = ceiling(total / n))
    }
    done <- 0
    k <- 0L
    while (!is.null(batch <- batches$next_batch())) {
      k <- k + 1L
      data <- as.data.frame(batch)
      wkb <- data$geometry
      attributes(wkb) <- NULL
      enc <- duckdb_geo_batch(wkb, data$.rcs_tmp, crs, geocode, h3_res, geocode_engine)
      data_files <- c(data_files, write_part(enc$data, "data", k))
      index_files <- c(index_files, write_part(enc$index, "index", k))
      rebuilt[[k]] <- enc$rebuilt
      fallback[[k]] <- enc$fallback
      done <- done + nrow(data)
      if (!is.null(bar)) write_progress(bar, rows = done, batch = k)
    }
    if (!is.null(bar)) write_progress(bar, done = TRUE)
  }
  list(
    data = data_files, index = index_files,
    rebuilt = do.call(c, c(list(bit64::integer64()), rebuilt)),
    fallback = do.call(c, c(list(bit64::integer64()), fallback)),
    total = total
  )
}

# The geocodes of one batch, computed as `geo_encode()` computes them: the
# boxes in the data's CRS, the cells of the geometries in EPSG:4326. A
# missing geometry (`NULL`) is geocoded as an empty one.
duckdb_geo_batch <- function(wkb, ids, crs, geocode, h3_res, geocode_engine) {
  present <- wkb
  missing <- vapply(present, is.null, logical(1))
  if (any(missing)) {
    present[missing] <- list(geo_empty_wkb)
  }
  geometry <- if (length(present) > 0) geo_wkb_to_sfc(present, crs) else sf::st_sfc(crs = crs)
  bbox <- geo_bbox_df(geometry)
  data <- tibble::tibble(.rcs_tmp = ids)
  index <- tibble::tibble(
    .rcs_tmp = bit64::integer64(), h3 = bit64::integer64(),
    h3_main = bit64::integer64(), share = double()
  )
  rebuilt <- fallback <- bit64::integer64()
  if (geocode) {
    encoded <- geo_h3_rows(geo_to_4326(geometry), h3_res, geocode_engine)
    data$h3 <- h3_hex_to_int64_raw(encoded$h3)
    rows <- encoded$index
    index <- tibble::tibble(
      .rcs_tmp = ids[rows$row],
      h3 = h3_hex_to_int64_raw(rows$cell),
      h3_main = h3_hex_to_int64_raw(encoded$h3[rows$row]),
      share = as.double(rows$share)
    )
    rebuilt <- ids[encoded$rebuilt]
    fallback <- ids[encoded$fallback]
  }
  for (name in bbox_names) {
    data[[paste0(".rcs_", name)]] <- bbox[[name]]
  }
  data$.rcs_gtype <- geo_type_strings(wkb)
  list(data = data, index = index, rebuilt = rebuilt, fallback = fallback)
}

# `read_parquet([...])` of local files.
duckdb_parquet_list <- function(con, paths) {
  paths <- normalizePath(paths, winslash = "/", mustWork = TRUE)
  paste0("read_parquet([", paste(DBI::dbQuoteString(con, paths), collapse = ", "), "])")
}

# The keys of rows given by `.rcs_tmp`, in input order, as D32 shows them:
# the key columns, else `.rcs_id`.
duckdb_geo_keys <- function(con, q_tmp, q_geo, key, ids) {
  if (length(ids) == 0) {
    return(character())
  }
  ids <- paste(as.character(sort(ids)), collapse = ", ")
  values <- if (length(key) > 0) {
    duckdb_frame(con, paste0(
      "SELECT ", paste(duckdb_ident(con, key), collapse = ", "), " FROM ", q_tmp,
      " WHERE \".rcs_tmp\" IN (", ids, ") ORDER BY \".rcs_tmp\""
    ))
  } else {
    duckdb_frame(con, paste0(
      "SELECT \".rcs_id\" FROM ", q_geo, " WHERE \".rcs_tmp\" IN (", ids, ") ORDER BY \".rcs_tmp\""
    ))
  }
  format_key_values(values)
}

#' The facts of every file written from DuckDB, in one aggregation
#'
#' One grouped aggregation over the rows of the output files: per file
#' (a combination of partition values) the distinct geometry types and the
#' extent of the boxes, for `geo_metadata_of()` and `files_file_facts()`,
#' and the range of the cells (D39). Only one row per file reaches R.
#'
#' @param con The DuckDB connection.
#' @param from The SQL `FROM` clause of the rows; pass-1 columns of a
#'   geospatial write under the alias `g`.
#' @param group The partition expressions, named by the partition columns
#'   (`character()`: one file).
#' @param h3 SQL of the cell of a row, or `NULL` without cells.
#' @param crs_json The PROJJSON of a geospatial dataset, or `NULL` (an index
#'   table: no geometry facts).
#' @return A function of the partition values of a file (a named list, or
#'   `NULL`), as `file_meta` of `duckdb_write_files()` takes it.
#' @noRd
duckdb_file_meta <- function(con, from, group, h3 = NULL, crs_json = NULL) {
  withr::local_options(arrow.int64_downcast = FALSE)
  geospatial <- !is.null(crs_json)
  q <- paste0("g.", duckdb_ident(con, paste0(".rcs_", bbox_names)))
  aggs <- c(
    if (length(group) > 0) paste(group, "AS", duckdb_ident(con, names(group))),
    if (geospatial) c(
      "list(DISTINCT g.\".rcs_gtype\") FILTER (WHERE g.\".rcs_gtype\" IS NOT NULL) AS \".rcs_types\"",
      paste0("min(", q[[1]], ") AS \".rcs_xmin\""), paste0("min(", q[[2]], ") AS \".rcs_ymin\""),
      paste0("max(", q[[3]], ") AS \".rcs_xmax\""), paste0("max(", q[[4]], ") AS \".rcs_ymax\"")
    ),
    if (!is.null(h3)) paste0("min(", h3, ") AS \".rcs_h3_min\", max(", h3, ") AS \".rcs_h3_max\"")
  )
  agg <- duckdb_frame(con, paste0(
    "SELECT ", paste(aggs, collapse = ", "), " FROM ", from,
    if (length(group) > 0) paste(" GROUP BY", paste(group, collapse = ", "))
  ))
  keys <- vapply(seq_len(nrow(agg)), function(i) {
    partition_values_json(if (length(group) > 0) as.list(agg[i, names(group)]))
  }, character(1))
  function(values) {
    i <- match(partition_values_json(values), keys)
    if (is.na(i)) {
      cli::cli_abort("No facts for the partition {partition_values_json(values)}.", .internal = TRUE)
    }
    row <- agg[i, ]
    out <- list()
    if (geospatial) {
      types <- unlist(row$.rcs_types[[1]]) %||% character()
      extent <- c(row$.rcs_xmin, row$.rcs_ymin, row$.rcs_xmax, row$.rcs_ymax)
      out$geo <- geo_metadata_of(types, extent, crs_json)
      out$bbox <- bbox_df(row$.rcs_xmin, row$.rcs_ymin, row$.rcs_xmax, row$.rcs_ymax)
    }
    if (!is.null(h3)) {
      out$h3 <- c(row$.rcs_h3_min, row$.rcs_h3_max)
    }
    out
  }
}

#' Partition checks of a geospatial DuckDB write that need no cells
#'
#' Before pass 1, so that a partition that cannot apply aborts before any
#' geocoding: the checks and messages of `partition_plan()` for attribute
#' columns (on their distinct values); `partition = "h3"` without cells or
#' without rows aborts as for an `sf`. `"h3"` mixed with other columns, or
#' other package columns, abort.
#'
#' @return The partition as given (`"h3"` is resolved between the passes).
#' @noRd
duckdb_geo_partition_early <- function(con, q_tmp, a, attrs, proto_attrs, geocode, total, call) {
  partition <- as.character(a$partition %||% character())
  if (length(partition) == 0) {
    return(character())
  }
  if (identical(partition, "h3")) {
    if (!geocode || total == 0) {
      # the abort of `partition_plan()` for data without cells or rows
      probe <- tibble::tibble(.rcs_one = rep(1, min(total, 1)))
      if (geocode) probe$h3 <- bit64::as.integer64(probe$.rcs_one)
      partition_plan(probe, "h3", a$max_files, 0L, call = call)
    }
    return(partition)
  }
  own <- intersect(partition, c(".rcs_id", "h3", "bbox", "geometry"))
  if (length(own) > 0) {
    cli::cli_abort(
      c(
        "A geospatial DuckDB table cannot be partitioned by {.field {own}}.",
        i = "Use {.code partition = \"h3\"} alone, or attribute columns of {.arg x}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  values <- if (all(partition %in% attrs)) {
    duckdb_frame(con, paste(
      "SELECT DISTINCT", paste(duckdb_ident(con, partition), collapse = ", "), "FROM", q_tmp
    ))
  } else {
    vctrs::vec_init(proto_attrs, 1L)
  }
  partition_plan(values, partition, a$max_files, call = call)$partition
}

#' The H3 partition map of a DuckDB write
#'
#' D39: the distinct cells come into R, the resolution is chosen by the
#' rule of `partition_plan_h3()` (the finest at or below `h3_res` with at
#' most `max_files` parents), and the two-column map `h3 -> h3_p<res>` is
#' staged as a temporary table for joins in DuckDB.
#'
#' @param sql The query of the distinct cells.
#' @param name,path Name of the temporary table, staging file of the map.
#' @return A list: `column` (`"h3_p<res>"`), `res`, `q_map` (the quoted
#'   table, dropped when `store_write()` ends).
#' @noRd
duckdb_h3_partition <- function(con, sql, a, h3_res, name, path) {
  cells <- duckdb_frame(con, sql)
  plan <- partition_plan(cells, "h3", a$max_files, h3_res, call = a$call)
  column <- plan$partition
  res <- plan$res
  map <- plan$data[c("h3", column)]
  rm(cells, plan)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(map, path)
  rm(map)
  q_map <- duckdb_ident(con, name)
  withr::defer(duckdb_drop(con, q_map), envir = a$call)
  duckdb_exec(con, paste0(
    "CREATE TEMPORARY TABLE ", q_map, " AS SELECT * FROM ", duckdb_parquet_list(con, path)
  ))
  list(column = column, res = res, q_map = q_map)
}

# D27: a column of `x` named as the chosen partition column serves as it
# when it holds the same cells; a different one aborts, as for an `sf`.
duckdb_check_supplied_partition <- function(con, q_tmp, q_geo, h3_part, type, call) {
  q_col <- duckdb_ident(con, h3_part$column)
  n <- if (identical(type, "BIGINT")) {
    as.numeric(DBI::dbGetQuery(con, paste0(
      "SELECT count(*) AS n FROM ", q_tmp, " AS t JOIN ", q_geo, " AS g USING (\".rcs_tmp\")",
      " LEFT JOIN ", h3_part$q_map, " AS m ON g.h3 = m.h3",
      " WHERE t.", q_col, " IS DISTINCT FROM m.", q_col
    ))$n)
  } else {
    as.numeric(DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_tmp))$n)
  }
  if (n == 0) {
    return(invisible())
  }
  column <- h3_part$column
  cli::cli_abort(
    c(
      "The column {.field {column}} of {.arg x} differs from the partition column the write computes ({n} row{?s}).",
      i = "With {.code partition = \"h3\"} the write partitions by {.field {column}}.",
      i = "Remove the column with {.fn rcs_geo_strip}, or prepare it with {.fn rcs_geo_add} from the same cells."
    ),
    class = "rcs_error_prepared", call = call
  )
}

#' Stage the index table of a geospatial DuckDB write
#'
#' The files, names, entry and manifest of `stage_index()` for the same
#' rows, streamed from DuckDB in the order `h3`, `.rcs_id`: one file, or,
#' above `rows_per_group * 100` rows, one file per H3 parent (the partition
#' map of `duckdb_h3_partition()` on the index cells), ordered by the
#' parent. Index rows never come into R as a whole (D36).
#'
#' @param tmp The name of the materialised table (prefix of the map).
#' @return A version source (`staged_src()`), or `NULL` without index rows.
#' @noRd
duckdb_stage_index <- function(con, q_index, a, h3_res, tmp) {
  rows <- as.numeric(DBI::dbGetQuery(con, paste("SELECT count(*) AS n FROM", q_index))$n)
  if (rows == 0) {
    return(NULL)
  }
  index_dataset <- index_name(a$dataset)
  proto <- tibble::tibble(
    .rcs_id = bit64::integer64(), h3 = bit64::integer64(),
    h3_main = bit64::integer64(), share = double()
  )
  partition <- character()
  group <- character()
  from <- paste(q_index, "AS i")
  select <- "i.\".rcs_id\", i.h3"
  if (rows > a$rows_per_group * 100) {
    part <- duckdb_h3_partition(
      con, paste("SELECT DISTINCT h3 FROM", q_index), a, h3_res,
      name = paste0(tmp, "_index_map"), path = file.path(a$dir, "pass1", "index-map.parquet")
    )
    partition <- part$column
    group <- rlang::set_names(paste0("m.", duckdb_ident(con, partition)), partition)
    from <- paste0(from, " JOIN ", part$q_map, " AS m ON i.h3 = m.h3")
    select <- paste0(select, ", ", group, " AS ", duckdb_ident(con, partition))
    proto <- tibble::tibble(
      .rcs_id = bit64::integer64(), h3 = bit64::integer64(), !!partition := bit64::integer64(),
      h3_main = bit64::integer64(), share = double()
    )
  }
  sql <- paste0(
    "SELECT ", select, ", i.h3_main, i.share FROM ", from, " ORDER BY ",
    paste(c(if (length(group) > 0) paste(group, "NULLS LAST"), "i.h3", "i.\".rcs_id\""), collapse = ", ")
  )
  schema <- files_arrow_schema(proto)
  spec <- files_columns_spec(proto, schema, NULL, call = a$call, cells_by_name = TRUE)
  meta <- files_meta(
    dataset = index_dataset, kind = "table",
    title = paste("H3 index of", a$dataset),
    description = paste0("Rows of ", a$dataset, " that cross H3 cells at resolution ", h3_res, "."),
    spec = spec, key = character(), sorted_by = c("h3", ".rcs_id"),
    partition = partition, partition_auto = TRUE, source = NA_character_, inputs = NA_character_,
    crs = NA_character_, h3_res = NA_integer_, geocode_engine = NA_character_,
    index_of = a$dataset, history = a$history
  )
  dir <- file.path(a$dir, "index")
  tmp_dir <- files_tmp_dir(dir, index_dataset)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  new <- duckdb_write_files(
    con, sql = sql, partition = partition, proto = proto, schema = schema,
    rcs_json = files_rcs_json(meta), rows_per_group = a$rows_per_group,
    tmp_dir = tmp_dir, total = rows,
    file_meta = duckdb_file_meta(con, from, group, h3 = "i.h3")
  )
  staged_src(files_finish(meta, new, NULL, created_of(a$existing_index, a$now), FALSE, TRUE, dir))
}


#' The serialization check of geospatial files staged from DuckDB (D40)
#'
#' Per file: the footer row count equals the rows streamed, and up to 20
#' sampled rows of one row group equal the rows with the same `.rcs_id`
#' fetched from the materialised table.
#'
#' @param data_sql A function of a SQL `WHERE` clause giving the query of
#'   the rows as written.
#' @return A tibble as `check_serialization()` returns it.
#' @noRd
duckdb_check_geo_files <- function(con, data_sql, be, files, entry, n = 20L) {
  withr::local_options(arrow.int64_downcast = FALSE)
  spec <- columns_from_json(entry$columns)
  rows <- lapply(seq_len(nrow(files)), function(i) {
    path <- files$path[[i]]
    problem <- tryCatch(
      duckdb_check_geo_file(con, data_sql, be, path, files$rows[[i]], spec, n),
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

duckdb_check_geo_file <- function(con, data_sql, be, path, streamed, spec, n) {
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
  table <- files_read_row_groups(be, path, groups$row_group[[pick$g]])
  data <- check_sample_rows(table, pick$take, spec)
  ids <- paste(as.character(data$.rcs_id), collapse = ", ")
  ref <- duckdb_frame(con, data_sql(paste0(" WHERE g.\".rcs_id\" IN (", ids, ")")))
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
    problem <- duckdb_check_problem(con, q_tmp, select, order_by, partition, be, path, files$rows[[i]], spec, n)
    if (is.na(problem)) {
      check_row(be$uri, entry$dataset, path, "ok")
    } else {
      check_row(be$uri, entry$dataset, path, "failed", problem)
    }
  })
  vctrs::vec_rbind(check_empty(), !!!rows)
}

# The problem of one staged file (`NA` when it passes): `duckdb_check_file()`
# with a file that cannot be read as a problem. Also run by
# `stage_duckdb_streamed()` on each file against its partition's table
# (D-B3), with `partition = character()`.
duckdb_check_problem <- function(con, q_tmp, select, order_by, partition, be, path, streamed, spec, n = 20L) {
  withr::local_options(arrow.int64_downcast = FALSE)
  tryCatch(
    duckdb_check_file(con, q_tmp, select, order_by, partition, be, path, streamed, spec, n),
    rcs_error_backend = function(e) paste("it cannot be read:", first_line(conditionMessage(e)))
  )
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
