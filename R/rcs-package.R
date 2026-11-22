#' rcs: catalog-first cloud and local storage
#'
#' A store is a named collection of datasets kept in one primary location and
#' any number of secondary ones. Every operation starts from the catalog of the
#' store.
#'
#' @section Options:
#' All options are read through the internal `rcs_option()`, which holds the
#' defaults.
#'
#' | Option | Default | Meaning |
#' |---|---|---|
#' | `rcs.quiet` | `FALSE` | Silence informative messages. |
#' | `rcs.trace` | `FALSE` | Record work counters, see [rcs_trace()]. |
#' | `rcs.staging_dir` | `tempdir()` | Folder where files are staged before upload. |
#' | `rcs.chunk_size` | `1e5` | Rows per chunk in vectorised geospatial work. |
#' | `rcs.workers` | `1` | Parallel workers for geocoding. |
#' | `rcs.lock_timeout` | `600` | Seconds after which a local lock is stale. |
#' | `rcs.record_writer` | `FALSE` | Record the user name in the catalog. |
#' | `rcs.print_rows` | `10` | Rows shown when a lazy query is printed. |
#' | `rcs.duckdb_batch_rows` | `5e5` | Rows per batch when writing from DuckDB. |
#' | `rcs.s2_rebuild_tol` | `1e-3` | Relative area change accepted for a geometry repaired on the sphere. |
#'
#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @importFrom rlang %||% caller_env :=
## usethis namespace: end
NULL
