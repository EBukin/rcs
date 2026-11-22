# Inspecting a connection: `print.rcs_store()`, `store_datasets()`,
# `store_describe()` (with its print method) and `store_status()`. All of
# them work from the catalogs held by the connection: they make no backend
# call and open no data file.

# Status of a dataset in another location ------------------------------------

#' Compare one location with a source location, dataset by dataset
#'
#' The state vocabulary of `store_status()` and `store_datasets()`, from
#' catalogs only.
#'
#' @param source The `rcs_location` compared against (the primary unless
#'   `store_status(from = )` names another).
#' @param location Another `rcs_location`, the target.
#' @return A tibble, one row per dataset of the source catalog (in its
#'   order) followed by the datasets found only in `location`: `dataset`,
#'   `status` (`"same"`, `"differs"`, `"missing"`, `"extra"`, or
#'   `"unavailable"` for every row when either location is unavailable:
#'   then the rows are the datasets of the source catalog, or of the
#'   target's when the source is the unavailable one), `newer` (for
#'   `differs`: `"source"` or `"target"`, the side with the later `updated`;
#'   `NA` otherwise and on a tie), `primary_version`, `location_version`,
#'   `primary_updated`, `location_updated` (`primary_*` describe the
#'   source).
#' @noRd
location_status <- function(source, location) {
  pc <- source$catalog
  sc <- location$catalog
  available <- source$available && location$available
  if (!location$available) {
    sc <- sc[0, ]
  } else if (!source$available) {
    pc <- sc
    sc <- sc[0, ]
  }
  extra <- setdiff(sc$dataset, pc$dataset)
  dataset <- c(pc$dataset, sort(extra, method = "radix"))
  ip <- match(dataset, pc$dataset)
  is_ <- match(dataset, sc$dataset)
  pv <- pc$version[ip]
  sv <- sc$version[is_]
  pu <- pc$updated[ip]
  su <- sc$updated[is_]
  if (!source$available) {
    # The rows come from the target's catalog; nothing of the source is known.
    pv <- rep(NA_character_, length(dataset))
    sv <- location$catalog$version[match(dataset, location$catalog$dataset)]
    su <- location$catalog$updated[match(dataset, location$catalog$dataset)]
    pu <- su[0][seq_along(dataset)]
  }
  status <- rep("differs", length(dataset))
  status[!is.na(pv) & !is.na(sv) & pv == sv] <- "same"
  status[is.na(is_)] <- "missing"
  status[is.na(ip)] <- "extra"
  if (!available) {
    status <- rep("unavailable", length(dataset))
  }
  newer <- rep(NA_character_, length(dataset))
  differs <- status == "differs"
  newer[differs & pu > su] <- "source"
  newer[differs & su > pu] <- "target"
  tibble::tibble(
    dataset = dataset,
    status = status,
    newer = newer,
    primary_version = pv,
    location_version = sv,
    primary_updated = local_time(pu),
    location_updated = local_time(su)
  )
}

# Timestamps are stored in UTC and shown in the session's zone.
local_time <- function(x) {
  x <- as.POSIXct(x)
  attr(x, "tzone") <- ""
  x
}

is_index_entry <- function(catalog) {
  is_index_name(catalog$dataset) | !is.na(catalog$index_of)
}

# store_status() --------------------------------------------------------------

#' Compare the locations of a connection with one of them
#'
#' For each location other than the source and each dataset, compares the
#' catalogs held by the connection: a copy is the same when its version
#' equals the source's. The source is the primary unless `from` names
#' another location. No file is read and no location contacted; run
#' [store_refresh()] first to compare what is stored now.
#'
#' @param st A store connection made by [store_connect()].
#' @param from `NULL` (the default) to compare every secondary location with
#'   the primary, or the address of a location of the connection (as given
#'   to [store_connect()]) to compare every other location, the primary
#'   included, with that one.
#' @return A tibble with one row per location other than the source and
#'   dataset of the source catalog (index tables included), plus one per
#'   dataset found only in that location, ordered by location (in
#'   connection order) and dataset:
#'
#'   * `dataset`: the full name;
#'   * `location`: the address of the location compared with the source;
#'   * `status`: `"same"`, `"differs"` (another version), `"missing"` (not
#'     in that location), `"extra"` (only in that location), or
#'     `"unavailable"` when it or the source could not be reached;
#'   * `newer`: for `"differs"`, the side with the later `updated` time,
#'     `"source"` or `"target"` (the location of the row); `NA` otherwise.
#'     A hint only: the clocks of the machines that wrote may differ;
#'   * `primary_version`, `location_version`: the versions compared;
#'     `primary_version` is the source's (the primary's by default);
#'   * `primary_updated`, `location_updated`: the times of the last writes,
#'     `primary_updated` in the source.
#'
#'   The attribute `source` holds the address of the source. Zero rows when
#'   the connection has no other location. `store_sync()` brings missing
#'   and differing datasets up to date.
#' @seealso [store_datasets()], [store_refresh()], [store_sync()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-status")
#' st <- store_connect(
#'   file.path(root, "primary"),
#'   secondary = file.path(root, "copy"),
#'   create = TRUE
#' )
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_status(st)
#' store_status(st, from = file.path(root, "copy"))
#' unlink(root, recursive = TRUE)
store_status <- function(st, from = NULL) {
  validate_store(st)
  local_trace("store_status")
  source_uri <- if (is.null(from)) {
    st$primary$uri
  } else {
    location_arg(st, from, "from", rlang::current_env())
  }
  source <- current_location(st, source_uri)
  targets <- store_locations(st)
  targets <- targets[store_uris(st) != source_uri]
  parts <- lapply(targets, function(location) {
    out <- location_status(source, location)
    tibble::add_column(out, location = rep(location$uri, nrow(out)), .after = "dataset")
  })
  empty <- tibble::tibble(
    dataset = character(), location = character(), status = character(),
    newer = character(), primary_version = character(), location_version = character(),
    primary_updated = local_time(as.POSIXct(character(), tz = "UTC")),
    location_updated = local_time(as.POSIXct(character(), tz = "UTC"))
  )
  out <- vctrs::vec_rbind(empty, !!!parts)
  attr(out, "source") <- source_uri
  class(out) <- c("rcs_status", class(out))
  out
}

#' @rdname store_status
#' @param x The result of `store_status()`.
#' @param ... Passed on to the tibble's print method.
#' @details Printed, the source is named first; the addresses of the other
#'   locations are listed once above the table and the column `location`
#'   shows their numbers, so that long addresses stay readable; the values
#'   of the column are the full addresses.
#' @export
print.rcs_status <- function(x, ...) {
  shown <- x
  class(shown) <- setdiff(class(x), "rcs_status")
  attr(shown, "source") <- NULL
  source <- attr(x, "source", exact = TRUE)
  if (is.character(source) && length(source) == 1) {
    cat("Source: ", source, "\n", sep = "")
  }
  if (nrow(x) == 0 || !"location" %in% names(x) || !is.character(x$location)) {
    print(shown, ...)
    return(invisible(x))
  }
  uris <- unique(x$location[!is.na(x$location)])
  shown$location <- ifelse(is.na(x$location), NA_character_, paste0("[", match(x$location, uris), "]"))
  cat(paste0("Locations: ", paste0("[", seq_along(uris), "] ", uris, collapse = "\n           ")), "\n", sep = "")
  print(shown, ...)
  invisible(x)
}

# store_datasets() ------------------------------------------------------------

#' List the datasets of a store
#'
#' The primary catalog as a tibble, with the state of each dataset in every
#' secondary location. Works from the catalogs held by the connection.
#'
#' @param st A store connection made by [store_connect()].
#' @param pattern `NULL`, or a regular expression the dataset names must
#'   match.
#' @param kind `NULL`, or any of `"table"`, `"geospatial"` and `"raster"`.
#' @param index `TRUE` also lists the H3 index tables of geospatial
#'   datasets (`<dataset>__h3`), which are hidden by default.
#' @return A tibble, one row per dataset, sorted by name: `dataset`, `kind`,
#'   `title`, `rows`, `bytes`, `n_files`, `partition` (the partition
#'   columns, a list), `version`, `updated` (in the session's time zone),
#'   then one column `in_<n>` per secondary location, numbered in connection
#'   order, holding `"same"`, `"differs"` or `"missing"` (`NA` when the
#'   location is unavailable). With `index = TRUE` a column `index_of` names
#'   the dataset an index table belongs to. The attribute `locations` holds
#'   the addresses: a named character vector with the names `primary` and
#'   `in_<n>`.
#' @seealso [store_describe()] for one dataset, [store_status()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-datasets")
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_datasets(st)
#' store_datasets(st, pattern = "^sales/", kind = "table")
#' unlink(root, recursive = TRUE)
store_datasets <- function(st, pattern = NULL, kind = NULL, index = FALSE) {
  validate_store(st)
  local_trace("store_datasets")
  check_string(pattern, allow_null = TRUE)
  if (!is.null(kind)) {
    kind <- rlang::arg_match(kind, c("table", "geospatial", "raster"), multiple = TRUE)
  }
  check_flag(index)
  catalog <- st$primary$catalog
  keep <- rep(TRUE, nrow(catalog))
  if (!index) {
    keep <- keep & !is_index_entry(catalog)
  }
  if (!is.null(pattern)) {
    keep <- keep & grepl(pattern, catalog$dataset, perl = TRUE)
  }
  if (!is.null(kind)) {
    keep <- keep & catalog$kind %in% kind
  }
  catalog <- catalog[keep, ]
  catalog <- catalog[order(catalog$dataset, method = "radix"), ]
  out <- tibble::tibble(
    dataset = catalog$dataset,
    kind = catalog$kind,
    title = catalog$title,
    rows = as.numeric(catalog$rows),
    bytes = as.numeric(catalog$bytes),
    n_files = as.integer(catalog$n_files),
    partition = catalog$partition,
    version = catalog$version,
    updated = local_time(catalog$updated)
  )
  if (index) {
    out$index_of <- catalog$index_of
  }
  locations <- c(primary = st$primary$uri)
  for (i in seq_along(st$secondary)) {
    location <- st$secondary[[i]]
    column <- paste0("in_", i)
    status <- location_status(st$primary, location)
    state <- status$status[match(out$dataset, status$dataset)]
    state[state == "unavailable"] <- NA_character_
    out[[column]] <- state
    locations[[column]] <- location$uri
  }
  attr(out, "locations") <- locations
  out
}

# print.rcs_store() -----------------------------------------------------------

#' Print a store connection
#'
#' Shows the locations with their backend and availability, the history
#' setting, and the datasets grouped by folder: name, kind, rows, size,
#' files, last update and, per secondary location, whether its copy is the
#' same (`=`), differs (a not-equal sign, `!=` on a console without UTF-8)
#' or is missing (a dash), and `?` for an unavailable location. Works from
#' the catalogs held by the connection.
#'
#' @param x A store connection made by [store_connect()].
#' @param index `TRUE` also lists the H3 index tables, hidden by default.
#' @param n Most datasets to list; the rest are counted.
#' @param ... Ignored.
#' @return `x`, invisibly.
#' @seealso [store_datasets()] for the same as a tibble.
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-print")
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' print(st)
#' unlink(root, recursive = TRUE)
print.rcs_store <- function(x, index = FALSE, n = 50, ...) {
  validate_store(x)
  local_trace("print")
  check_flag(index)
  lines <- c(
    cli::rule(left = "rcs store", width = min(cli::console_width(), 80)),
    store_location_lines(x),
    store_history_line(x),
    store_dataset_lines(x, index = index, n = n)
  )
  cli::cat_line(lines)
  invisible(x)
}

status_symbols <- function() {
  if (cli::is_utf8_output()) {
    c(
      same = "=", differs = intToUtf8(0x2260), missing = intToUtf8(0x2013),
      unavailable = "?", ellipsis = intToUtf8(0x2026)
    )
  } else {
    c(same = "=", differs = "!=", missing = "-", unavailable = "?", ellipsis = "...")
  }
}

store_location_lines <- function(st) {
  locations <- store_locations(st)
  label <- c("primary", sprintf("secondary %d", seq_along(st$secondary)))
  type <- vapply(locations, function(l) l$backend$type, character(1))
  uri <- vapply(locations, function(l) l$uri, character(1))
  available <- vapply(locations, function(l) l$available, logical(1))
  uri[!available] <- paste(uri[!available], "(unavailable)")
  c("Locations:", text_table(list(label, type, uri), indent = 2))
}

store_history_line <- function(st) {
  if (is.null(st$history)) {
    paste0("History: ", on_off(st$store_history), " (store default)")
  } else {
    paste0(
      "History: ", on_off(st$history), " (this connection; store default ",
      on_off(st$store_history), ")"
    )
  }
}

on_off <- function(x) {
  if (isTRUE(x)) "on" else "off"
}

store_dataset_lines <- function(st, index, n) {
  catalog <- st$primary$catalog
  hidden <- 0L
  if (!index) {
    is_index <- is_index_entry(catalog)
    hidden <- sum(is_index)
    catalog <- catalog[!is_index, ]
  }
  catalog <- catalog[order(catalog$dataset, method = "radix"), ]
  total <- nrow(catalog)
  note <- if (hidden > 0) {
    sprintf(" (%d index table%s hidden)", hidden, if (hidden == 1) "" else "s")
  } else {
    ""
  }
  if (total == 0) {
    return(paste0("Datasets: none", note))
  }
  shown <- catalog[seq_len(min(total, n)), ]
  symbols <- status_symbols()

  folder <- ifelse(grepl("/", shown$dataset, fixed = TRUE), sub("/[^/]*$", "", shown$dataset), "")
  leaf <- dataset_last_segment(shown$dataset)
  # Top-level datasets first, then folders in name order.
  ord <- order(folder != "", folder, leaf, method = "radix")
  shown <- shown[ord, ]
  folder <- folder[ord]
  leaf <- leaf[ord]
  name <- ifelse(folder == "", leaf, paste0("  ", leaf))

  cols <- list(
    c("name", name),
    c("kind", shown$kind),
    c("rows", format_count(shown$rows)),
    c("size", format_bytes(shown$bytes)),
    c("files", format_count(shown$n_files)),
    c("updated", format(local_time(shown$updated), "%Y-%m-%d %H:%M"))
  )
  align <- c("left", "left", "right", "right", "right", "left")
  for (i in seq_along(st$secondary)) {
    status <- location_status(st$primary, st$secondary[[i]])
    state <- status$status[match(shown$dataset, status$dataset)]
    cols[[length(cols) + 1L]] <- c(as.character(i), unname(symbols[state]))
    align <- c(align, "left")
  }
  rows <- text_table(cols, align = align, indent = 2)
  header <- rows[[1]]
  body <- rows[-1]

  out <- c(sprintf("Datasets: %d%s", total, note), header)
  previous <- NA_character_
  for (i in seq_along(body)) {
    if (folder[[i]] != "" && !identical(folder[[i]], previous)) {
      out <- c(out, paste0("  ", folder[[i]], "/"))
    }
    previous <- folder[[i]]
    out <- c(out, body[[i]])
  }
  if (total > n) {
    out <- c(out, sprintf(
      "  %s and %d more; see store_datasets().", symbols[["ellipsis"]], total - n
    ))
  }
  if (length(st$secondary) > 0) {
    out <- c(out, sprintf(
      "Secondary copies: %s same, %s differs, %s missing, %s unavailable.",
      symbols[["same"]], symbols[["differs"]], symbols[["missing"]], symbols[["unavailable"]]
    ))
  }
  out
}

# Lines of a text table: `cols` is a list of character vectors of one length
# (the first element of each may be a header); columns are padded to their
# widths and joined by two spaces.
text_table <- function(cols, align = rep("left", length(cols)), indent = 0) {
  cols <- lapply(cols, function(x) {
    x <- as.character(x)
    x[is.na(x)] <- ""
    x
  })
  padded <- Map(
    function(x, a) {
      width <- cli::ansi_nchar(x, type = "width")
      pad <- strrep(" ", max(width, 0) - width)
      if (a == "right") paste0(pad, x) else paste0(x, pad)
    },
    cols, align
  )
  lines <- do.call(paste, c(unname(padded), sep = "  "))
  paste0(strrep(" ", indent), sub("\\s+$", "", lines))
}

# store_describe() ------------------------------------------------------------

#' Describe one dataset
#'
#' The full catalog entry of a dataset: title, description, provenance, key,
#' partition, coordinate reference system, extent, H3 resolution, the table
#' of columns, the table of files of its current version and its state in
#' every secondary location. Works from the catalogs held by the
#' connection; no data file is opened.
#'
#' @param st A store connection made by [store_connect()].
#' @param dataset The dataset's full name, or its last part when that is
#'   unique. Index tables (`<dataset>__h3`) can be named too.
#' @return An object of class `rcs_description`, printed as a summary: a list
#'   with
#'
#'   * `entry`: the catalog entry, a one-row tibble;
#'   * `columns`: a tibble `name`, `type` (Arrow type), `r_type` (the R type
#'     the package restores on read, as text, `NA` when Arrow restores it by
#'     itself), `description`;
#'   * `files`: a tibble of the files of the current version: `path`,
#'     `partition_values`, `rows`, `bytes`, `md5`, `created`;
#'   * `locations`: a tibble `location`, `role` and `status` (as in
#'     [store_status()]; `"primary"` for the primary);
#'   * `index`: the name of the dataset's index table, or `NA`.
#' @seealso [store_datasets()].
#' @export
#' @examples
#' root <- file.path(tempdir(), "rcs-example-describe")
#' st <- store_connect(file.path(root, "primary"), create = TRUE)
#' store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
#'   title = "Daily sales", description = "Simulated daily sales.",
#'   key = c("shop_id", "date", "product"), partition = "year"
#' )
#' store_describe(st, "sales/daily")
#' unlink(root, recursive = TRUE)
store_describe <- function(st, dataset) {
  validate_store(st)
  local_trace("store_describe")
  name <- resolve_dataset(st, dataset, index = TRUE)
  catalog <- st$primary$catalog
  entry <- catalog[catalog$dataset == name, ]
  files <- st$primary$files[st$primary$files$dataset == name, ]
  files <- files[order(files$path, method = "radix"), ]
  spec <- columns_from_json(entry$columns)
  index <- catalog$dataset[!is.na(catalog$index_of) & catalog$index_of == name]

  roles <- c("primary", sprintf("secondary %d", seq_along(st$secondary)))
  status <- vapply(st$secondary, function(location) {
    s <- location_status(st$primary, location)
    s$status[match(name, s$dataset)]
  }, character(1))

  structure(
    list(
      entry = entry,
      columns = tibble::tibble(
        name = spec$name,
        type = spec$type,
        r_type = vapply(spec$r_type, r_type_text, character(1)),
        description = spec$description
      ),
      files = tibble::tibble(
        path = files$path,
        partition_values = files$partition_values,
        rows = as.numeric(files$rows),
        bytes = as.numeric(files$bytes),
        md5 = files$md5,
        created = local_time(files$created)
      ),
      locations = tibble::tibble(
        location = store_uris(st),
        role = roles,
        status = c("primary", status)
      ),
      index = if (length(index) == 1) index else NA_character_
    ),
    class = "rcs_description"
  )
}

r_type_text <- function(r_type) {
  if (is.null(r_type)) {
    return(NA_character_)
  }
  switch(
    r_type$class,
    difftime = paste0("difftime (", r_type$units, ")"),
    factor = paste0(
      if (isTRUE(r_type$ordered)) "ordered factor" else "factor",
      " (", length(r_type$levels), " level", if (length(r_type$levels) == 1) "" else "s", ")"
    ),
    SpatRaster = paste0(
      "raster layer (", paste(r_type$dim, collapse = " x "), " cells)"
    ),
    r_type$class
  )
}

# Name and identifier of a PROJJSON string, e.g. "WGS 84 (EPSG:4326)".
crs_text <- function(crs) {
  if (is.na(crs) || !nzchar(crs)) {
    return(NA_character_)
  }
  parsed <- tryCatch(jsonlite::fromJSON(crs, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(parsed)) {
    return("(unreadable PROJJSON)")
  }
  id <- parsed$id
  code <- if (!is.null(id$authority) && !is.null(id$code)) paste0(id$authority, ":", id$code)
  name <- parsed$name %||% "unnamed"
  if (is.null(code)) name else paste0(name, " (", code, ")")
}

#' @rdname store_describe
#' @param x An `rcs_description`.
#' @param n Most files to list; the rest are counted.
#' @param ... Ignored.
#' @export
print.rcs_description <- function(x, n = 10, ...) {
  e <- x$entry
  symbols <- status_symbols()
  none <- if (cli::is_utf8_output()) intToUtf8(0x2013) else "-"
  text <- function(v) if (length(v) == 0 || all(is.na(v))) none else paste(v, collapse = ", ")
  stamp <- function(t) format(local_time(t), "%Y-%m-%d %H:%M:%S %Z")
  facts <- list(
    c("Kind", e$kind),
    c("Version", e$version),
    c("Rows", format_count(e$rows)),
    c("Files", format_count(e$n_files)),
    c("Size", format_bytes(e$bytes)),
    c("Key", text(e$key[[1]])),
    c("Partition", text(e$partition[[1]])),
    c("Sorted by", text(e$sorted_by[[1]])),
    c("Source", text(e$source)),
    c("Inputs", text(e$inputs))
  )
  if (e$kind %in% c("geospatial", "raster")) {
    box <- e$bbox
    extent <- if (anyNA(unlist(box))) {
      text(NA)
    } else {
      sprintf(
        "xmin %s, ymin %s, xmax %s, ymax %s",
        signif(box$xmin, 7), signif(box$ymin, 7), signif(box$xmax, 7), signif(box$ymax, 7)
      )
    }
    facts <- c(facts, list(c("CRS", text(crs_text(e$crs))), c("Extent", extent)))
  }
  if (identical(e$kind, "geospatial")) {
    facts <- c(facts, list(c("H3 res", if (is.na(e$h3_res)) "none (no geocodes)" else as.character(e$h3_res))))
  }
  if (!is.na(e$index_of)) {
    facts <- c(facts, list(c("Index of", e$index_of)))
  }
  if (!is.na(x$index)) {
    facts <- c(facts, list(c("Index table", x$index)))
  }
  facts <- c(facts, list(
    c("History", if (is.na(e$history)) "not set (the connection's setting applies)" else on_off(e$history)),
    c("Created", stamp(e$created)),
    c("Updated", stamp(e$updated)),
    c("Written by", text(c(
      if (!is.na(e$writer)) e$writer,
      if (!is.na(e$r_version)) paste("R", e$r_version),
      if (!is.na(e$rcs_version)) paste("rcs", e$rcs_version)
    )))
  ))
  fact_lines <- text_table(
    list(vapply(facts, `[[`, character(1), 1), vapply(facts, `[[`, character(1), 2))
  )

  loc <- x$locations
  loc_state <- ifelse(loc$status == "primary", "", paste0(symbols[loc$status], " ", loc$status))
  loc_lines <- text_table(list(loc$role, loc_state, loc$location), indent = 2)

  cols <- x$columns
  col_lines <- text_table(
    list(
      c("name", cols$name),
      c("type", cols$type),
      c("r_type", cols$r_type),
      c("description", cols$description)
    ),
    indent = 2
  )

  files <- x$files
  shown <- files[seq_len(min(nrow(files), n)), ]
  file_lines <- text_table(
    list(
      c("path", shown$path),
      c("partition", shown$partition_values),
      c("rows", format_count(shown$rows)),
      c("size", format_bytes(shown$bytes))
    ),
    align = c("left", "left", "right", "right"),
    indent = 2
  )
  if (nrow(files) > n) {
    file_lines <- c(file_lines, sprintf("  %s and %d more.", symbols[["ellipsis"]], nrow(files) - n))
  }

  cli::cat_line(c(
    cli::rule(left = e$dataset, width = min(cli::console_width(), 80)),
    e$title,
    e$description,
    "",
    fact_lines,
    "",
    "Locations:",
    loc_lines,
    "",
    sprintf("Columns (%d):", nrow(cols)),
    col_lines,
    "",
    sprintf("Files (%d):", nrow(files)),
    file_lines
  ))
  invisible(x)
}
