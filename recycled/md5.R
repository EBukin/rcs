# Recycled, anonymised. Not run after editing: treat as a starting point, not as tested code.
# Target: wave 0, R/utils.R (shared by every backend).

#' MD5 of a local file, as 32 hex characters
#' @noRd
md5_file <- function(path) {
  digest::digest(path, algo = "md5", file = TRUE)
}

#' Convert a hex MD5 to base64
#'
#' Object stores report MD5 in base64 (`md5Hash`, `Content-MD5`); catalogs
#' hold hex. Vectorise before use: this version takes one value.
#' @noRd
md5_hex_to_base64 <- function(hex) {
  bytes <- as.raw(strtoi(substring(hex, seq(1, 31, 2), seq(2, 32, 2)), 16L))
  jsonlite::base64_enc(bytes)
}

#' Format a number of bytes for messages
#' @noRd
format_bytes <- function(bytes) {
  format(structure(bytes, class = "object_size"), units = "auto")
}
