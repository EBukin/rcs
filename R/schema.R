# Contracts of the catalog: the three catalog files as Arrow schemas, their
# form in memory, the constructors of entries and file rows, the `columns`
# specification, the manifest and the metadata embedded in data files.
#
# In memory a catalog file is a tibble with exactly the columns of its schema,
# in schema order, typed as follows ("the in-memory form"):
#
#   Arrow type               R type
#   string                   character
#   list<string>             bare list of character vectors (never NULL, never NA)
#   int64                    bit64::integer64
#   int32                    integer
#   bool                     logical
#   timestamp[us, UTC]       POSIXct with tzone "UTC"
#   struct<xmin, ymin, ...>  data-frame column with four double columns
#
# `schema_as_arrow()` and `schema_as_tibble()` convert between the two forms and
# are the only way in and out; reading and writing the files through a backend
# belongs to R/catalog.R (work package C).

# Schemas ---------------------------------------------------------------------

bbox_names <- c("xmin", "ymin", "xmax", "ymax")

#' Arrow type of every `bbox` column
#' @return `struct<xmin: double, ymin: double, xmax: double, ymax: double>`.
#' @noRd
bbox_type <- function() {
  arrow::struct(
    xmin = arrow::float64(), ymin = arrow::float64(),
    xmax = arrow::float64(), ymax = arrow::float64()
  )
}

timestamp_type <- function() {
  arrow::timestamp("us", timezone = "UTC")
}

#' Arrow schemas of the three catalog files
#'
#' `catalog_schema()`: `_catalog.parquet`, one row per dataset.
#' `files_schema()`: `_files.parquet`, one row per data file of the current
#' versions. `history_schema()`: `_history.parquet`, the columns of
#' `files_schema()` plus `replaced`. `schema_get()` returns one of them by
#' name. The meaning of every column is in the plan, "Catalog schema".
#'
#' @param which `"catalog"`, `"files"` or `"history"`.
#' @return An [arrow::Schema].
#' @noRd
catalog_schema <- function() {
  arrow::schema(
    dataset = arrow::utf8(),
    kind = arrow::utf8(),
    title = arrow::utf8(),
    description = arrow::utf8(),
    source = arrow::utf8(),
    inputs = arrow::utf8(),
    key = arrow::list_of(arrow::utf8()),
    sorted_by = arrow::list_of(arrow::utf8()),
    partition = arrow::list_of(arrow::utf8()),
    partition_auto = arrow::boolean(),
    columns = arrow::utf8(),
    version = arrow::utf8(),
    n_files = arrow::int64(),
    rows = arrow::int64(),
    bytes = arrow::int64(),
    crs = arrow::utf8(),
    bbox = bbox_type(),
    h3_res = arrow::int32(),
    geocode_engine = arrow::utf8(),
    index_of = arrow::utf8(),
    history = arrow::boolean(),
    writer = arrow::utf8(),
    r_version = arrow::utf8(),
    rcs_version = arrow::utf8(),
    created = timestamp_type(),
    updated = timestamp_type()
  )
}

#' @noRd
files_schema <- function() {
  arrow::schema(
    dataset = arrow::utf8(),
    version = arrow::utf8(),
    path = arrow::utf8(),
    partition_values = arrow::utf8(),
    rows = arrow::int64(),
    bytes = arrow::int64(),
    md5 = arrow::utf8(),
    bbox = bbox_type(),
    h3_min = arrow::int64(),
    h3_max = arrow::int64(),
    created = timestamp_type()
  )
}

#' @noRd
history_schema <- function() {
  arrow::schema(!!!c(files_schema()$fields, list(arrow::field("replaced", timestamp_type()))))
}

#' @noRd
schema_get <- function(which = c("catalog", "files", "history")) {
  schema_cached(rlang::arg_match(which))$schema
}

# Building a schema and its kinds takes tens of milliseconds and they never
# change in a session, so each is built once per `which` and kept here.
schema_cache <- new.env(parent = emptyenv())

schema_cached <- function(which) {
  cached <- schema_cache[[which]]
  if (is.null(cached)) {
    schema <- switch(
      which,
      catalog = catalog_schema(),
      files = files_schema(),
      history = history_schema()
    )
    cached <- list(schema = schema, kinds = schema_field_kinds(schema))
    assign(which, cached, envir = schema_cache)
  }
  cached
}

# Field kinds of `schema_get(which)`, from the cache.
schema_kinds <- function(which = c("catalog", "files", "history")) {
  schema_cached(rlang::arg_match(which))$kinds
}

dataset_kinds <- c("table", "geospatial", "raster")

# Values of the catalog column `geocode_engine` (besides `NA`).
catalog_geocode_engines <- c("auto", "s2", "planar")

# Columns added to a schema after stores were first written. A catalog file
# without them is read with the column filled with `NA` (in schema position),
# validates, and is written back with it.
schema_optional <- list(catalog = c("partition_auto", "geocode_engine"), files = character(), history = character())

# `x` with the missing optional columns of `which` added as `NA`, in schema
# order (other columns keep their order and are not checked here).
schema_fill_optional <- function(x, which) {
  kinds <- schema_kinds(which)
  missing <- setdiff(schema_optional[[which]], names(x))
  if (length(missing) == 0 || !is.data.frame(x)) {
    return(x)
  }
  for (name in missing) {
    x[[name]] <- vctrs::vec_init(empty_column(kinds[[name]]), nrow(x))
  }
  present <- intersect(names(kinds), names(x))
  x[c(present, setdiff(names(x), present))]
}

# In-memory form --------------------------------------------------------------

# Kind of a field, used to convert and validate: "string", "strings" (list),
# "int64", "int32", "bool", "time", "bbox".
schema_field_kinds <- function(schema) {
  kinds <- vapply(schema$fields, function(field) {
    type <- field$type$ToString()
    if (startsWith(type, "struct")) {
      "bbox"
    } else if (startsWith(type, "list")) {
      "strings"
    } else if (startsWith(type, "timestamp")) {
      "time"
    } else {
      switch(type, string = "string", int64 = "int64", int32 = "int32", bool = "bool",
        cli::cli_abort("Unexpected type {.val {type}}.", .internal = TRUE))
    }
  }, character(1))
  stats::setNames(kinds, names(schema))
}

#' Bounding boxes as the data-frame column of the in-memory form
#'
#' @param xmin,ymin,xmax,ymax Double vectors of one length; `NA` for no
#'   extent (tables, empty geometries).
#' @param n Number of rows.
#' @return A tibble with the columns `xmin`, `ymin`, `xmax`, `ymax` (double).
#'   `bbox_na(n)` gives `n` rows of `NA`.
#' @noRd
bbox_df <- function(xmin, ymin, xmax, ymax) {
  tibble::tibble(
    xmin = as.double(xmin), ymin = as.double(ymin),
    xmax = as.double(xmax), ymax = as.double(ymax)
  )
}

#' @noRd
bbox_na <- function(n = 1L) {
  bbox_df(rep(NA_real_, n), rep(NA_real_, n), rep(NA_real_, n), rep(NA_real_, n))
}

empty_column <- function(kind) {
  switch(
    kind,
    string = character(),
    strings = list(),
    int64 = bit64::integer64(),
    int32 = integer(),
    bool = logical(),
    time = as.POSIXct(numeric(), origin = "1970-01-01", tz = "UTC"),
    bbox = bbox_na(0L)
  )
}

#' Empty catalog files in the in-memory form
#'
#' @return A zero-row tibble with the columns and types of the schema.
#'   `store_create()` writes these three to initialise a location.
#' @noRd
catalog_empty <- function() {
  schema_empty("catalog")
}

#' @noRd
files_empty <- function() {
  schema_empty("files")
}

#' @noRd
history_empty <- function() {
  schema_empty("history")
}

schema_empty <- function(which) {
  kinds <- schema_kinds(which)
  tibble::as_tibble(lapply(kinds, empty_column))
}

#' Convert a catalog file between the in-memory form and Arrow
#'
#' @param x `schema_as_arrow()`: a tibble in the in-memory form.
#'   `schema_as_tibble()`: an [arrow::Table] (or anything
#'   `as.data.frame()` turns into a data frame) read from a catalog file.
#' @param which `"catalog"`, `"files"` or `"history"`.
#' @return `schema_as_arrow()`: an [arrow::Table] with exactly
#'   `schema_get(which)`, ready for `arrow::write_parquet()`.
#'   `schema_as_tibble()`: a tibble in the in-memory form (`int64` kept as
#'   `integer64`, lists unwrapped, times in UTC). Both validate with
#'   `schema_validate()` and abort with class `rcs_error_schema`.
#' @noRd
schema_as_arrow <- function(x, which = c("catalog", "files", "history")) {
  which <- rlang::arg_match(which)
  schema_validate(x, which)
  x <- schema_fill_optional(x, which)
  arrow::arrow_table(x, schema = schema_get(which))
}

#' @noRd
schema_as_tibble <- function(x, which = c("catalog", "files", "history")) {
  which <- rlang::arg_match(which)
  kinds <- schema_kinds(which)
  withr::local_options(arrow.int64_downcast = FALSE)
  x <- tibble::as_tibble(as.data.frame(x))
  x <- schema_fill_optional(x, which)
  missing <- setdiff(names(kinds), names(x))
  if (length(missing) > 0) {
    cli::cli_abort(
      "The {which} file lacks the column{?s} {.field {missing}}.",
      class = "rcs_error_schema"
    )
  }
  x <- x[names(kinds)]
  for (name in names(kinds)) {
    x[[name]] <- switch(
      kinds[[name]],
      strings = lapply(unclass(x[[name]]), as.character),
      int64 = bit64::as.integer64(x[[name]]),
      bbox = tibble::as_tibble(x[[name]]),
      x[[name]]
    )
  }
  schema_validate(x, which)
  x
}

#' Validate a catalog file in the in-memory form
#'
#' Checks the column names and order, the R type of every column and, per
#' file: `catalog`: `dataset` unique and not `NA`, `kind` one of `table`,
#' `geospatial`, `raster`, `version` 16 hex characters; `files` and
#' `history`: `dataset`, `version`, `path` and `md5` not `NA`, and in `files`
#' no `path` twice. A catalog table may lack the optional columns
#' `partition_auto` and `geocode_engine` (stores written before they
#' existed); when present the values of `geocode_engine` are `NA` or one of
#' `"auto"`, `"s2"`, `"planar"`.
#'
#' @param x A tibble.
#' @param which `"catalog"`, `"files"` or `"history"`.
#' @param call Environment for the error.
#' @return `x`, invisibly. Aborts with class `rcs_error_schema`, one bullet
#'   per problem.
#' @noRd
schema_validate <- function(x, which = c("catalog", "files", "history"),
                            call = caller_env()) {
  which <- rlang::arg_match(which)
  kinds <- schema_kinds(which)
  fail <- function(problems) {
    cli::cli_abort(
      c("Invalid {which} table.", rlang::set_names(problems, "x")),
      class = "rcs_error_schema", call = call
    )
  }
  if (!is.data.frame(x)) {
    fail("It must be a data frame, not {.obj_type_friendly {x}}.")
  }
  absent <- setdiff(schema_optional[[which]], names(x))
  kinds <- kinds[!names(kinds) %in% absent]
  if (!identical(names(x), names(kinds))) {
    fail(c(
      "Its columns must be {.field {names(kinds)}}, in this order.",
      "It has {.field {names(x)}}."
    ))
  }
  ok <- vapply(names(kinds), function(name) {
    col <- x[[name]]
    switch(
      kinds[[name]],
      string = is.character(col),
      strings = rlang::is_bare_list(col) && all(vapply(col, is.character, logical(1))) &&
        !anyNA(unlist(col)),
      int64 = inherits(col, "integer64"),
      int32 = is.integer(col),
      bool = is.logical(col),
      time = inherits(col, "POSIXct") && identical(attr(col, "tzone"), "UTC"),
      bbox = is.data.frame(col) && identical(names(col), bbox_names) &&
        all(vapply(col, is.double, logical(1)))
    )
  }, logical(1))
  if (!all(ok)) {
    bad <- names(kinds)[!ok]
    fail(paste0("Column {.field ", bad, "} must be of kind ", kinds[bad], "."))
  }
  problems <- character()
  if (which == "catalog") {
    if (anyNA(x$dataset) || anyDuplicated(x$dataset) > 0) {
      problems <- c(problems, "{.field dataset} must be unique and not missing.")
    }
    if (!all(x$kind %in% dataset_kinds)) {
      problems <- c(problems, "{.field kind} must be one of {.val {dataset_kinds}}.")
    }
    if (!all(grepl("^[0-9a-f]{16}$", x$version))) {
      problems <- c(problems, "{.field version} must be 16 hex characters.")
    }
    engine <- x[["geocode_engine"]]
    if (!is.null(engine) && !all(is.na(engine) | engine %in% catalog_geocode_engines)) {
      problems <- c(problems, "{.field geocode_engine} must be missing or one of {.val {catalog_geocode_engines}}.")
    }
  } else {
    if (anyNA(x$dataset) || anyNA(x$version) || anyNA(x$path) || anyNA(x$md5)) {
      problems <- c(problems, "{.field dataset}, {.field version}, {.field path} and {.field md5} may not be missing.")
    }
    if (which == "files" && anyDuplicated(x$path) > 0) {
      problems <- c(problems, "A {.field path} is named twice.")
    }
  }
  if (length(problems) > 0) {
    fail(problems)
  }
  invisible(x)
}

# Constructors ----------------------------------------------------------------

as_int64_scalar <- function(x) {
  if (length(x) == 0 || is.null(x)) bit64::NA_integer64_ else bit64::as.integer64(x)
}

as_bbox_row <- function(bbox) {
  if (is.null(bbox) || all(is.na(unlist(bbox)))) {
    return(bbox_na(1L))
  }
  bbox <- unlist(bbox)
  bbox_df(bbox[["xmin"]], bbox[["ymin"]], bbox[["xmax"]], bbox[["ymax"]])
}

#' Build the catalog entry of one dataset
#'
#' @param dataset Full dataset name (validated with `check_dataset_name()`;
#'   index names are allowed when `index_of` is given).
#' @param kind `"table"`, `"geospatial"` or `"raster"`.
#' @param title,description Non-empty strings.
#' @param version 16 hex characters (`version_hash()`).
#' @param n_files,rows,bytes Totals; anything `bit64::as.integer64()` accepts.
#' @param columns The `columns` JSON string (`columns_to_json()`).
#' @param key,sorted_by,partition Character vectors, empty when none.
#' @param partition_auto `TRUE` when the partition was chosen by
#'   `partition = "h3"`, `FALSE` when the partition columns are user columns,
#'   `NA` without partition (plan 0004, D-A1).
#' @param source,inputs Strings or `NA`.
#' @param crs PROJJSON string or `NA`.
#' @param bbox Named numeric `c(xmin, ymin, xmax, ymax)` in the data CRS, or
#'   `NULL`.
#' @param h3_res Integer or `NA` (not geospatial, or `geocode = FALSE`).
#' @param geocode_engine The geocoding engine of the write (`"auto"`, `"s2"`
#'   or `"planar"`), or `NA` (tables, index tables, rasters,
#'   `geocode = FALSE`, datasets written before the column existed).
#' @param index_of For an index table, the dataset it indexes; else `NA`.
#' @param history Dataset-level history setting: `TRUE`, `FALSE` or `NA` (not
#'   set).
#' @param created,updated `POSIXct`; default now. A later write keeps the
#'   `created` of the entry it replaces.
#' @return A one-row tibble in the in-memory form of `catalog_schema()`.
#'   `writer` is filled only when `rcs_option("rcs.record_writer")`;
#'   `r_version` and `rcs_version` are filled from the session. Aborts on an
#'   invalid name, kind, title, description or version.
#' @noRd
new_entry <- function(dataset, kind, title, description, version,
                      n_files, rows, bytes, columns,
                      key = character(), sorted_by = character(),
                      partition = character(), partition_auto = NA,
                      source = NA_character_, inputs = NA_character_,
                      crs = NA_character_, bbox = NULL, h3_res = NA_integer_,
                      geocode_engine = NA_character_,
                      index_of = NA_character_, history = NA,
                      created = now_utc(), updated = created) {
  check_dataset_name(dataset, allow_index = !is.na(index_of))
  kind <- rlang::arg_match(kind, dataset_kinds)
  check_string(title)
  check_string(description)
  check_string(columns)
  writer <- if (isTRUE(rcs_option("rcs.record_writer"))) {
    Sys.info()[["user"]]
  } else {
    NA_character_
  }
  entry <- tibble::tibble(
    dataset = dataset,
    kind = kind,
    title = title,
    description = description,
    source = as.character(source %||% NA),
    inputs = as.character(inputs %||% NA),
    key = list(as.character(key)),
    sorted_by = list(as.character(sorted_by)),
    partition = list(as.character(partition)),
    partition_auto = as.logical(partition_auto %||% NA),
    columns = columns,
    version = version,
    n_files = as_int64_scalar(n_files),
    rows = as_int64_scalar(rows),
    bytes = as_int64_scalar(bytes),
    crs = as.character(crs %||% NA),
    bbox = as_bbox_row(bbox),
    h3_res = as.integer(h3_res),
    geocode_engine = as.character(geocode_engine %||% NA),
    index_of = as.character(index_of),
    history = as.logical(history),
    writer = writer,
    r_version = as.character(getRversion()),
    rcs_version = as.character(utils::packageVersion("rcs")),
    created = as_utc(created),
    updated = as_utc(updated)
  )
  schema_validate(entry, "catalog")
  entry
}

as_utc <- function(x) {
  as.POSIXct(as.numeric(x), origin = "1970-01-01", tz = "UTC")
}

#' Build rows of `_files.parquet`
#'
#' Vectorised: one row per file.
#'
#' @param dataset,version One string each, or one per file. `version` is the
#'   dataset version the rows belong to.
#' @param path Paths relative to the location root (`data_file_path()`).
#' @param partition_values Canonical JSON strings
#'   (`partition_values_json()`).
#' @param rows,bytes Per file; anything `bit64::as.integer64()` accepts.
#' @param md5 Hex MD5 per file.
#' @param bbox A `bbox_df()` with one row per file, or `NULL` for none.
#' @param h3_min,h3_max `integer64` per file, or `NULL` for none. A plain
#'   numeric aborts: an H3 cell does not fit a double.
#' @param created `POSIXct`; default now.
#' @return A tibble in the in-memory form of `files_schema()`.
#' @noRd
new_file_rows <- function(dataset, version, path, partition_values, rows, bytes,
                          md5, bbox = NULL, h3_min = NULL, h3_max = NULL,
                          created = now_utc()) {
  n <- length(path)
  check_cells <- function(x, arg) {
    if (is.null(x)) {
      return(rep(bit64::NA_integer64_, n))
    }
    if (!inherits(x, "integer64")) {
      cli::cli_abort(
        "{.arg {arg}} must be {.cls integer64}, not {.obj_type_friendly {x}}.",
        class = "rcs_error_argument", call = caller_env()
      )
    }
    x
  }
  out <- tibble::tibble(
    dataset = rep_len(dataset, n),
    version = rep_len(version, n),
    path = as.character(path),
    partition_values = as.character(partition_values),
    rows = bit64::as.integer64(rows),
    bytes = bit64::as.integer64(bytes),
    md5 = as.character(md5),
    bbox = bbox %||% bbox_na(n),
    h3_min = check_cells(h3_min, "h3_min"),
    h3_max = check_cells(h3_max, "h3_max"),
    created = rep_len(as_utc(created), n)
  )
  schema_validate(out, "files")
  out
}

# Columns specification -------------------------------------------------------

#' The `columns` specification of a dataset
#'
#' Stored in the entry as a JSON array of
#' `{name, type, r_type, description}`.
#'
#' In memory it is a tibble with the columns `name` (character), `type`
#' (character: the Arrow type as `type$ToString()` gives it), `r_type` (list)
#' and `description` (character, `NA` when none). `r_type` is `NULL` when Arrow
#' restores the R type by itself, else a named list with the element `class`:
#'
#' | R type | `r_type` |
#' |---|---|
#' | `difftime` | `list(class = "difftime", units = "hours")` |
#' | `integer64` | `list(class = "integer64")` |
#' | factor | `list(class = "factor", levels = <character>, ordered = FALSE)` |
#' | ordered factor | the same with `ordered = TRUE` |
#' | plain list column | `list(class = "list")` |
#' | raster layer | `list(class = "SpatRaster", resolution = c(x, y), dim = c(nrow, ncol))` |
#' | raster layer of a file with a NoData value | the same, then `nodata = <number>` |
#' | categorical raster layer (a legend) | then `values = <codes>, levels = <labels>, levels_name = "<label column>"` |
#' | raster layer with a colour table | then `color_values = <codes>, colors = <"#RRGGBBAA">` |
#'
#' The raster fields add up in this order: a class map with a NoData value,
#' a legend and colours has all of them. The fields `levels`, `values`,
#' `color_values`, `colors`, `resolution` and `dim` are JSON arrays whatever
#' their length.
#'
#' * `nodata`: one number, the same for every layer of a raster; absent when
#'   the file has no NoData value.
#' * `values` (numbers, sorted) and `levels` (character): the codes of the
#'   legend and their labels, of one length and in one order; `levels_name`
#'   is the name the label column had.
#' * `color_values` (numbers, sorted) and `colors` (character, `#RRGGBBAA`
#'   in upper case): the codes that have a colour and their colours, of one
#'   length and in one order. Both are absent for a layer without a colour
#'   table. With a legend they hold only the codes of the legend; without
#'   one, every row of the colour table (256 rows for a table read from a
#'   file).
#'
#' `columns_spec()` builds the tibble, `columns_to_json()` serialises it and
#' `columns_from_json()` parses the string of an entry. A round trip is
#' identical.
#'
#' @param name,type Character vectors of one length.
#' @param r_type List of that length, or `NULL` for all `NULL`.
#' @param description Character vector of that length, or `NULL` for all `NA`.
#' @param spec A tibble as built by `columns_spec()`.
#' @param json One JSON string.
#' @return `columns_spec()` and `columns_from_json()`: the tibble.
#'   `columns_to_json()`: one string.
#' @noRd
columns_spec <- function(name = character(), type = character(),
                         r_type = NULL, description = NULL) {
  n <- length(name)
  r_type <- r_type %||% rep(list(NULL), n)
  description <- description %||% rep(NA_character_, n)
  if (length(type) != n || length(r_type) != n || length(description) != n) {
    cli::cli_abort("All arguments must have one length.", .internal = TRUE)
  }
  tibble::tibble(
    name = as.character(name),
    type = as.character(type),
    r_type = unname(as.list(r_type)),
    description = as.character(description)
  )
}

# The fields of an `r_type` that are JSON arrays whatever their length.
r_type_array_fields <- c("levels", "values", "color_values", "colors", "resolution", "dim")

#' @noRd
columns_to_json <- function(spec) {
  items <- lapply(seq_len(nrow(spec)), function(i) {
    r_type <- spec$r_type[[i]]
    if (!is.null(r_type)) {
      for (field in intersect(names(r_type), r_type_array_fields)) {
        r_type[[field]] <- I(r_type[[field]])
      }
    }
    list(
      name = spec$name[[i]],
      type = spec$type[[i]],
      r_type = r_type,
      description = if (is.na(spec$description[[i]])) NULL else spec$description[[i]]
    )
  })
  to_json(items)
}

#' @noRd
columns_from_json <- function(json) {
  items <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  r_type <- lapply(items, function(item) {
    r_type <- item$r_type
    if (is.null(r_type)) {
      return(NULL)
    }
    for (field in intersect(names(r_type), r_type_array_fields)) {
      r_type[[field]] <- unlist(r_type[[field]]) %||% character()
    }
    r_type
  })
  columns_spec(
    name = vapply(items, function(item) item$name, character(1)),
    type = vapply(items, function(item) item$type, character(1)),
    r_type = r_type,
    description = vapply(items, function(item) item$description %||% NA_character_, character(1))
  )
}

# JSON of catalog rows --------------------------------------------------------

to_json <- function(x) {
  as.character(jsonlite::toJSON(
    json_exact_doubles(x),
    auto_unbox = TRUE, digits = NA, null = "null", na = "null", json_verbatim = TRUE
  ))
}

# One row of a catalog file as a list ready for JSON: `int64` as strings (an
# int64 does not fit a JSON number), times as text, `bbox` as an object or
# null, lists of strings as arrays, `NA` as null.
row_to_list <- function(row, kinds) {
  out <- lapply(names(kinds), function(name) {
    value <- row[[name]]
    switch(
      kinds[[name]],
      strings = I(value[[1]]),
      int64 = if (is.na(value)) NULL else as.character(value),
      time = if (is.na(value)) NULL else time_to_text(value),
      bbox = if (all(is.na(unlist(value)))) NULL else as.list(value),
      if (is.na(value)) NULL else value
    )
  })
  stats::setNames(out, names(kinds))
}

row_from_list <- function(item, kinds) {
  cols <- lapply(names(kinds), function(name) {
    value <- item[[name]]
    switch(
      kinds[[name]],
      string = as.character(value %||% NA),
      strings = list(as.character(unlist(value))),
      int64 = if (is.null(value)) bit64::NA_integer64_ else bit64::as.integer64(value),
      int32 = as.integer(value %||% NA),
      bool = as.logical(value %||% NA),
      time = time_from_text(value %||% NA),
      bbox = as_bbox_row(value)
    )
  })
  tibble::as_tibble(stats::setNames(cols, names(kinds)))
}

rows_from_list <- function(items, which) {
  kinds <- schema_kinds(which)
  rows <- lapply(items, row_from_list, kinds = kinds)
  vctrs::vec_rbind(schema_empty(which), !!!rows)
}

# Metadata embedded in data files ---------------------------------------------

entry_not_embedded <- c(
  "version", "n_files", "rows", "bytes", "bbox", "history",
  "writer", "r_version", "rcs_version", "created", "updated"
)

# Entry fields left out of the embedded metadata and of the manifest when they
# are `NA`, so that adding them kept the file MD5s and versions of datasets
# that do not use them (plan 0002, D30; `partition_auto`, plan 0004).
entry_omitted_when_na <- c("partition_auto", "geocode_engine")

# `row_to_list()` of an entry without the fields of `entry_omitted_when_na`
# that are `NULL` (`NA`).
entry_to_list <- function(entry, kinds) {
  out <- row_to_list(entry, kinds)
  drop <- intersect(entry_omitted_when_na, names(out))
  drop <- drop[vapply(out[drop], is.null, logical(1))]
  out[setdiff(names(out), drop)]
}

#' The `rcs` key-value metadata of a Parquet data file
#'
#' The JSON of the catalog entry without `version`, the totals (`n_files`,
#' `rows`, `bytes`), the dataset's `bbox`, `history`, `writer`, `r_version`,
#' `rcs_version`, `created` and `updated`: nothing that changes when the same
#' data are written again, by any version of R or of the package and under
#' any history setting, so that file MD5s are reproducible. `partition_auto`
#' and `geocode_engine` are embedded only when they are not `NA`.
#' `entry_from_metadata_json()` parses it back; the left-out columns are `NA`
#' (`version` is `NA` too, so the result does not pass `schema_validate()`
#' until `store_rebuild()` has filled it).
#'
#' @param entry A one-row tibble of `catalog_schema()`.
#' @param json One JSON string.
#' @return `entry_metadata_json()`: one JSON string, the same for the same
#'   entry on every machine. `entry_from_metadata_json()`: a one-row tibble
#'   with the columns of `catalog_schema()`.
#' @noRd
entry_metadata_json <- function(entry) {
  kinds <- schema_kinds("catalog")
  to_json(entry_to_list(entry, kinds[setdiff(names(kinds), entry_not_embedded)]))
}

#' @noRd
entry_from_metadata_json <- function(json) {
  item <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  row_from_list(item, schema_kinds("catalog"))
}

# Manifest --------------------------------------------------------------------

#' The manifest of one dataset version
#'
#' Stored as `<dataset>/_manifest-<version>.json` (`manifest_path()`):
#' `{"entry": {...}, "files": [{...}, ...], "written": "<UTC timestamp>"}`.
#' In the JSON every `int64` is a string, every timestamp is text
#' (`time_to_text()`), `bbox` is an object or null, `NA` is null, and
#' `entry$columns` stays the JSON string of the catalog. `partition_auto` and
#' `geocode_engine` are left out when `NA` and read back as `NA` when absent.
#'
#' In memory a manifest is a list of class `rcs_manifest` with `entry` (a
#' one-row tibble of `catalog_schema()`), `files` (a tibble of
#' `files_schema()` whose rows all carry the entry's dataset and version) and
#' `written` (`POSIXct`, UTC). `manifest_from_json(manifest_to_json(m))` is
#' identical to `m`.
#'
#' @param entry A one-row tibble of `catalog_schema()`.
#' @param files A tibble of `files_schema()`.
#' @param written `POSIXct`; default now.
#' @param manifest A list as built by `new_manifest()`.
#' @param json One JSON string.
#' @return `new_manifest()` and `manifest_from_json()`: the list; they abort
#'   with class `rcs_error_schema` when `entry` or `files` are invalid, when
#'   `entry` has not exactly one row, or when a file row names another dataset
#'   or version. `manifest_to_json()`: one string.
#' @noRd
new_manifest <- function(entry, files, written = now_utc()) {
  schema_validate(entry, "catalog")
  schema_validate(files, "files")
  if (nrow(entry) != 1) {
    cli::cli_abort("A manifest holds exactly one entry.", class = "rcs_error_schema")
  }
  if (!all(files$dataset == entry$dataset) || !all(files$version == entry$version)) {
    cli::cli_abort(
      "Every file row of a manifest must carry the dataset and version of its entry.",
      class = "rcs_error_schema"
    )
  }
  structure(
    list(entry = entry, files = files, written = as_utc(written)),
    class = "rcs_manifest"
  )
}

#' @noRd
manifest_to_json <- function(manifest) {
  entry_kinds <- schema_kinds("catalog")
  file_kinds <- schema_kinds("files")
  to_json(list(
    entry = entry_to_list(manifest$entry, entry_kinds),
    files = lapply(
      seq_len(nrow(manifest$files)),
      function(i) row_to_list(manifest$files[i, ], file_kinds)
    ),
    written = time_to_text(manifest$written)
  ))
}

#' @noRd
manifest_from_json <- function(json) {
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  new_manifest(
    entry = rows_from_list(list(parsed$entry), "catalog"),
    files = rows_from_list(parsed$files, "files"),
    written = time_from_text(parsed$written)
  )
}
