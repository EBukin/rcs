# New, written during the plan review (not recycled). The two conversions were
# run once in R 4.6.2 with bit64 4.8.6 and round-tripped a resolution-5 cell;
# they are not unit-tested. Target: work package B, R/geo-h3.R.
#
# Why they are needed:
#   * h3o 0.3.0 holds cells as a list of external pointers (class `H3`) and
#     exchanges them as hex strings only; it has no int64 form.
#   * An H3 index does not fit a double: a cell typed as a numeric literal is
#     silently rounded to a different, usually invalid, index. Accept cells as
#     hex strings, `integer64` or `H3` vectors only.
#   * h3o 0.3.0: `h3_from_xy(x, y, resolution)` takes LATITUDE first. With
#     longitude first it returns a valid cell somewhere else, without error.
#     `h3_from_points()` on an sfc is not affected.

#' H3 hex strings to integer64
#' @noRd
h3_hex_to_int64 <- function(hex) {
  n <- nchar(hex)
  high <- strtoi(substr(hex, 1, n - 8), 16L)
  low <- as.numeric(paste0("0x", substr(hex, n - 7, n)))
  bit64::as.integer64(high) * bit64::as.integer64(4294967296) +
    bit64::as.integer64(low)
}

#' integer64 to H3 hex strings
#' @noRd
h3_int64_to_hex <- function(cell) {
  two32 <- bit64::as.integer64(4294967296)
  high <- as.numeric(cell %/% two32)
  low <- as.numeric(cell %% two32)
  sprintf("%x%04x%04x", as.integer(high), as.integer(low %/% 65536), as.integer(low %% 65536))
}
