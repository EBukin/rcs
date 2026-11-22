# Prototype: an opened dataset prints like a dbplyr / dtplyr table.
#
# `print.rcs_query()` reads the first rows of the lazy query (only the row
# groups needed for them) and prints them with pillar, with a header that
# says where the data lives. The total row count comes from the catalog when
# the query has no filter; otherwise it is `??`, as dbplyr does.
#
# Load after `devtools::load_all()`: `source("dev/prototype/print.R")`.

proto_query_known_rows <- function(x) {
  unfiltered <- !inherits(x$query, "arrow_dplyr_query") || isTRUE(x$query$filtered_rows)
  unfiltered && is.null(x$spatial) && nrow(x$files) == as.numeric(x$entry$n_files)
}

proto_query_header <- function(x) {
  entry <- x$entry
  location <- x$location
  ncol <- length(setdiff(names(x$query), ".rcs_id")) - if (!x$geometry) 1L else 0L
  nrow <- if (proto_query_known_rows(x)) format_count(as.numeric(entry$rows)) else "??"
  current <- location$catalog$version[location$catalog$dataset == entry$dataset]
  version <- if (identical(current, entry$version)) "current" else "earlier"
  files <- paste0(nrow(x$files), " of ", format_count(as.numeric(entry$n_files)))
  if (nrow(x$files) < as.numeric(entry$n_files)) files <- paste0(files, " (pruned)")
  out <- c(
    Dataset  = paste0(entry$dataset, " [", nrow, " x ", ncol, "] (", entry$kind, ")"),
    Location = paste0(query_location_role(x), " (", class(location$backend)[[1]] |> sub(pattern = "rcs_backend_", replacement = ""), ")"),
    Version  = paste0(substr(entry$version, 1, 8), " (", version, ")"),
    Files    = files
  )
  if (!is.null(x$spatial)) out[["Spatial"]] <- spatial_describe(x$spatial)
  if (inherits(x$query, "arrow_dplyr_query") && !isTRUE(x$query$filtered_rows)) {
    out[["Filter"]] <- x$query$filtered_rows$ToString()
  }
  out
}

proto_print_lazy <- function(header, preview, more, n, hint, ...) {
  preview <- tibble::as_tibble(preview)
  class(preview) <- c("rcs_preview", class(preview))
  attr(preview, "rcs_header") <- header
  attr(preview, "rcs_more") <- more
  attr(preview, "rcs_hint") <- hint
  print(preview, n = n, ...)
}

print.rcs_query <- function(x, ..., n = 10) {
  # n + 1 rows tell whether more rows exist without counting them all.
  preview <- dplyr::collect(utils::head(x, n + 1))
  more <- nrow(preview) > n
  proto_print_lazy(
    proto_query_header(x), utils::head(preview, n), more, n,
    "Use `collect()` to read the rows into R.", ...
  )
  invisible(x)
}

# pillar hooks: our header instead of "A tibble: n x m", unknown row count.
tbl_sum.rcs_preview <- function(x, ...) attr(x, "rcs_header")

tbl_format_footer.rcs_preview <- function(x, setup, ...) {
  more <- attr(x, "rcs_more")
  default <- NextMethod()
  extra <- c(
    if (more) pillar::style_subtle("# ℹ more rows"),
    pillar::style_subtle(paste0("# ℹ ", attr(x, "rcs_hint")))
  )
  c(default, extra)
}

registerS3method("print", "rcs_query", print.rcs_query)
registerS3method("tbl_sum", "rcs_preview", tbl_sum.rcs_preview, envir = asNamespace("pillar"))
registerS3method("tbl_format_footer", "rcs_preview", tbl_format_footer.rcs_preview, envir = asNamespace("pillar"))
