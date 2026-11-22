#' A preview of the first rows of a lazy query, for printing
#'
#' Wraps rows already read into R in a tibble of class `rcs_preview`, which
#' pillar prints with the query's header in place of `A tibble: n x m` and
#' with extra footer lines after pillar's own.
#'
#' @param data A data frame or an `sf` object: the rows to show.
#' @param header Named character vector: the header lines, as returned by
#'   `pillar::tbl_sum()` (pillar aligns the names and prefixes `# `).
#' @param footer Character vector: footer lines, each printed after
#'   `# i ` (the cli info symbol).
#' @return A tibble of class `rcs_preview`.
#' @noRd
new_rcs_preview <- function(data, header, footer = character()) {
  # attributes are set one by one: structure() would expand the compact row
  # names, and pillar would then print a `*` row-name column
  data <- tibble::as_tibble(data)
  attr(data, "rcs_header") <- header
  attr(data, "rcs_footer") <- footer
  class(data) <- c("rcs_preview", class(data))
  data
}

#' @exportS3Method pillar::tbl_sum
tbl_sum.rcs_preview <- function(x, ...) {
  attr(x, "rcs_header", exact = TRUE)
}

#' @exportS3Method pillar::tbl_format_footer
tbl_format_footer.rcs_preview <- function(x, setup, ...) {
  footer <- attr(x, "rcs_footer", exact = TRUE)
  extra <- if (length(footer) > 0) {
    pillar::style_subtle(paste0("# ", cli::symbol$info, " ", footer))
  }
  c(NextMethod(), extra)
}
