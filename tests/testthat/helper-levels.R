# Test levels. `RCS_TEST_LEVEL` is `cran`, `default` or `full`:
#
#   cran     unit tests, no network, small data, a few seconds per file;
#   default  adds the local integration suite and property tests of about
#            200 cases;
#   full     adds property runs of 2,000 cases, the random-operation test and
#            the suite against `RCS_TEST_GCS`.
#
# When the variable is unset the level is `cran` on CRAN and under
# `R CMD check`, and `default` otherwise (`devtools::test()`).
#
# Start every test that belongs to a higher level with
# `skip_below_level("default")` or `skip_below_level("full")`.

test_levels <- c("cran", "default", "full")

test_level <- function() {
  level <- Sys.getenv("RCS_TEST_LEVEL", "")
  if (!nzchar(level)) {
    on_cran <- !identical(Sys.getenv("NOT_CRAN"), "true")
    return(if (on_cran || testthat::is_checking()) "cran" else "default")
  }
  if (!level %in% test_levels) {
    cli::cli_abort(
      "{.envvar RCS_TEST_LEVEL} must be one of {.val {test_levels}}, not {.val {level}}."
    )
  }
  level
}

skip_below_level <- function(level) {
  level <- match.arg(level, test_levels)
  current <- test_level()
  if (match(current, test_levels) < match(level, test_levels)) {
    testthat::skip(paste0("Test level is '", current, "'; this test needs '", level, "'."))
  }
  invisible(TRUE)
}

# Number of cases of a property test at the current level.
property_cases <- function(default = 200L, full = 2000L, cran = 20L) {
  switch(test_level(), cran = cran, default = default, full = full)
}
