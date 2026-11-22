# DuckDB helpers for tests. Every connection the package makes uses
# `bigint = "integer64"` (plan 0002, fact 1), so the test connections do too.

# A DuckDB connection closed when `.env` ends, or a skip without duckdb/DBI.
local_duckdb <- function(bigint = "integer64", .env = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  con <- suppressMessages(DBI::dbConnect(duckdb::duckdb(), bigint = bigint))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = .env)
  con
}

# A DuckDB connection with the spatial extension loaded, or a skip. With `con`
# given, the extension is loaded into that connection; otherwise a new one is
# made by `local_duckdb()` and closed when `frame` ends.
local_duckdb_spatial <- function(con = NULL, frame = parent.frame()) {
  if (is.null(con)) {
    con <- local_duckdb(.env = frame)
  }
  load <- function(sql) {
    tryCatch(
      {
        DBI::dbExecute(con, sql)
        TRUE
      },
      error = function(e) FALSE
    )
  }
  if (!load("LOAD spatial")) {
    skip_if_offline()
    if (!load("INSTALL spatial") || !load("LOAD spatial")) {
      skip("The DuckDB spatial extension cannot be installed or loaded.")
    }
  }
  con
}
