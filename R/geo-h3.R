# H3 cells: conversion between hex strings, `integer64` and `h3o` `H3`
# vectors, validation, resolution and parents. Cells are `integer64` inside
# the package; this file holds the only converters.
#
# Layout of an H3 cell index (64 bits, most significant first): 1 reserved bit
# (0), 4 bits mode (1 for a cell), 3 reserved bits (0), 4 bits resolution,
# 7 bits base cell (0 to 121), then 15 digits of 3 bits each. Digits up to the
# resolution are 0 to 6, the others are 7. As 15 hex characters the index
# reads `8`, the resolution, then 13 characters (52 bits) for the base cell
# and the digits. Everything here works on those 52 bits as a double (exact
# below 2^53), so validation and parents need no H3 package.

h3_pentagon_base_cells <- c(4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117)

# Average hexagon edge length in metres per resolution, 0 to 15 (H3 tables).
h3_edge_m <- c(
  1281256.011, 483056.839, 182512.957, 68979.222, 26071.760, 9854.091,
  3724.533, 1406.476, 531.414, 200.786, 75.864, 28.664, 10.830, 4.092,
  1.546, 0.584
)

check_h3o <- function(call = caller_env()) {
  rlang::check_installed("h3o", reason = "to compute H3 cells.", call = call)
}

# Hex <-> 52-bit parts -------------------------------------------------------

# 52 low bits of 15-character hex strings as doubles; NA where `hex` is NA.
h3_hex_low <- function(hex) {
  a <- strtoi(substr(hex, 3, 3), 16L)
  b <- strtoi(substr(hex, 4, 9), 16L)
  c <- strtoi(substr(hex, 10, 15), 16L)
  a * 2^48 + b * 2^24 + c
}

# Hex strings from the resolution (0 to 15) and the 52 low bits.
h3_hex_build <- function(res, low) {
  out <- sprintf(
    "8%x%x%06x%06x",
    as.integer(res),
    as.integer(low %/% 2^48),
    as.integer((low %/% 2^24) %% 2^24),
    as.integer(low %% 2^24)
  )
  out[is.na(res) | is.na(low)] <- NA_character_
  out
}

# Which well-formed hex strings are valid cells. `hex` is lower case, 15
# characters, no NA.
h3_hex_is_cell <- function(hex) {
  ok <- grepl("^8[0-9a-f]{14}$", hex, perl = TRUE)
  res <- strtoi(substr(hex, 2, 2), 16L)
  low <- h3_hex_low(hex)
  base <- low %/% 2^45
  ok <- ok & !is.na(base) & base <= 121
  ok[is.na(ok)] <- FALSE
  # digits after the resolution are all 7
  tail <- 8^(15 - res)
  ok <- ok & (low %% tail) == tail - 1
  # digits up to the resolution are 0 to 6
  for (i in seq_len(max(c(0L, res[ok])))) {
    used <- ok & i <= res
    if (!any(used)) {
      next
    }
    digit <- (low[used] %/% 8^(15 - i)) %% 8
    ok[used] <- digit <= 6
  }
  # a pentagon has no digit 1 as its first non-zero digit (deleted subsequence)
  pentagon <- which(ok & base %in% h3_pentagon_base_cells)
  if (length(pentagon) > 0) {
    first <- rep(0, length(pentagon))
    for (i in seq_len(max(res[pentagon]))) {
      digit <- (low[pentagon] %/% 8^(15 - i)) %% 8
      take <- first == 0 & i <= res[pentagon] & digit > 0
      first[take] <- digit[take]
    }
    ok[pentagon[first == 1]] <- FALSE
  }
  ok
}

# An `integer64` is a double vector whose 8 bytes hold the integer. These two
# helpers split it into its high and low 32-bit halves (as signed integers)
# and back, through the bytes, which is much faster than integer64
# arithmetic. A half whose bits are 0x80000000 (INT_MIN) is NA_integer_ in R,
# both ways: `int64_halves()` gives NA_integer_ for it and
# `int64_from_halves()` writes NA_integer_ as those bits.
int64_halves <- function(x) {
  if (length(x) == 0) {
    return(list(high = integer(), low = integer()))
  }
  words <- readBin(writeBin(unclass(as.double(unclass(x))), raw()), "integer", n = 2L * length(x),
    size = 4L, endian = .Platform$endian)
  if (.Platform$endian == "little") {
    list(high = words[c(FALSE, TRUE)], low = words[c(TRUE, FALSE)])
  } else {
    list(high = words[c(TRUE, FALSE)], low = words[c(FALSE, TRUE)])
  }
}

int64_from_halves <- function(high, low) {
  if (length(high) == 0) {
    return(bit64::integer64())
  }
  words <- if (.Platform$endian == "little") rbind(low, high) else rbind(high, low)
  out <- readBin(writeBin(as.vector(words), raw(), size = 4L), "double", n = length(high), size = 8L)
  class(out) <- "integer64"
  out
}

# `integer64` to 15-character hex, without validation; NA for values that do
# not have the layout of a cell index (top hex digits 0 and 8).
h3_int64_to_hex_raw <- function(x) {
  halves <- int64_halves(x)
  high <- halves$high
  low_hex <- sprintf("%08x", halves$low)
  low_hex[is.na(halves$low)] <- "80000000"
  out <- paste0(sprintf("%07x", high), low_hex)
  # a high half of 0x80000000 (NA here) sets the sign bit: never a cell
  bad <- is.na(x) | is.na(high) | bitwShiftR(high, 24L) != 8L
  out[bad] <- NA_character_
  out
}

# Valid 15-character hex to `integer64`, without validation.
h3_hex_to_int64_raw <- function(hex) {
  high <- strtoi(substr(hex, 1, 7), 16L)
  low_high <- strtoi(substr(hex, 8, 11), 16L)
  low_low <- strtoi(substr(hex, 12, 15), 16L)
  # the low half as a signed 32-bit integer; 0x80000000 is NA_integer_, which
  # `int64_from_halves()` writes as those bits
  low <- low_high * 65536 + low_low
  low <- low - (low >= 2^31) * 2^32
  low[!is.na(low) & low == -2^31] <- NA_real_
  low <- as.integer(low)
  out <- int64_from_halves(high, low)
  out[is.na(hex)] <- bit64::NA_integer64_
  out
}

# Normalise any cell input to valid lower-case hex strings.
h3_input_hex <- function(x, arg, call) {
  if (inherits(x, "integer64")) {
    hex <- h3_int64_to_hex_raw(x)
    invalid <- !is.na(x) & is.na(hex)
    hex[invalid] <- "x"
  } else if (inherits(x, "H3")) {
    hex <- as.character(x)
  } else if (is.character(x)) {
    hex <- tolower(as.character(x))
    attributes(hex) <- NULL
  } else {
    numeric <- is.numeric(x)
    cli::cli_abort(
      c(
        "{.arg {arg}} must hold H3 cells as hex strings, {.cls integer64} or {.cls H3}, not {.obj_type_friendly {x}}.",
        i = if (numeric) "A plain number cannot hold an H3 cell: it would be rounded to another cell."
      ),
      class = "rcs_error_h3_input", call = call
    )
  }
  given <- !is.na(hex)
  valid <- rep(TRUE, length(hex))
  valid[given] <- h3_hex_is_cell(hex[given])
  if (!all(valid)) {
    bad <- which(!valid)
    shown <- as.character(x[bad])
    cli::cli_abort(
      c(
        "{.arg {arg}} holds {length(bad)} value{?s} that {?is/are} not {?a/} valid H3 cell{?s}.",
        x = "First: {.val {utils::head(shown, 5)}}."
      ),
      class = "rcs_error_h3_input", call = call
    )
  }
  hex
}

# Converters ------------------------------------------------------------------

#' Convert H3 cells to the internal form
#'
#' Implemented by B; called by C, E and F.
#'
#' @param x Cells: hex strings, `integer64` or an `h3o` `H3` vector; `NA`
#'   stays `NA`.
#' @param arg,call Used in the error message.
#' @return `h3_as_int64()`: an `integer64` vector of the same length.
#'   `h3_as_hex()`: a character vector of the same length (15 lower-case hex
#'   characters). Both abort with class `rcs_error_h3_input` when `x` is a
#'   plain numeric or any other type, or holds a string that is not a valid
#'   cell.
#' @noRd
h3_as_int64 <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  hex <- h3_input_hex(x, arg = arg, call = call)
  h3_hex_to_int64_raw(hex)
}

#' @noRd
h3_as_hex <- function(x, arg = rlang::caller_arg(x), call = caller_env()) {
  h3_input_hex(x, arg = arg, call = call)
}

# Internal: valid hex strings to an `h3o` `H3` vector (NA stays NA).
h3_hex_to_h3o <- function(hex) {
  check_h3o()
  h3o::h3_from_strings(hex)
}

# Resolution of valid hex strings (NA stays NA).
h3_hex_res <- function(hex) {
  strtoi(substr(hex, 2, 2), 16L)
}

# Hex of the cells of points at one resolution; NA for missing coordinates.
h3_hex_of_points <- function(lon, lat, res) {
  out <- rep(NA_character_, length(lon))
  ok <- !is.na(lon) & !is.na(lat)
  if (any(ok)) {
    out[ok] <- as.character(h3o::h3_from_xy(lat[ok], lon[ok], as.integer(res)))
  }
  out
}

#' Parent cells, for grouping only
#'
#' A cell is not inside its parent, so the result is used to group rows into
#' partitions (`h3_p<r>`) and for nothing geometric. Implemented by B; called
#' by C.
#'
#' @param cells `integer64` vector of cells of one resolution; `NA` stays
#'   `NA`.
#' @param res One integer, 0 to the resolution of `cells`.
#' @return `integer64` vector of the same length: the parent of each cell at
#'   resolution `res` (the cell itself when `res` is its own resolution).
#'   Aborts when `res` is finer than the cells.
#' @noRd
h3_parent <- function(cells, res) {
  if (!rlang::is_scalar_integerish(res, finite = TRUE) || res < 0 || res > 15) {
    cli::cli_abort(
      "{.arg res} must be one whole number from 0 to 15, not {.obj_type_friendly {res}}.",
      class = "rcs_error_argument"
    )
  }
  hex <- h3_input_hex(cells, arg = "cells", call = caller_env())
  own <- h3_hex_res(hex)
  if (any(own < res, na.rm = TRUE)) {
    cli::cli_abort(
      "{.arg res} ({res}) is finer than the resolution of the cells ({min(own, na.rm = TRUE)}).",
      class = "rcs_error_argument"
    )
  }
  step <- 8^(15 - res)
  low <- h3_hex_low(hex)
  parent_low <- (low %/% step) * step + (step - 1)
  out <- h3_hex_build(rep(res, length(hex)), parent_low)
  out[is.na(hex)] <- NA_character_
  h3_hex_to_int64_raw(out)
}
