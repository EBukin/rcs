# rcs: catalog-first cloud and local storage

A store is a named collection of datasets kept in one primary location
and any number of secondary ones. Every operation starts from the
catalog of the store.

## Options

All options are read through the internal `rcs_option()`, which holds
the defaults.

|  |  |  |
|----|----|----|
| Option | Default | Meaning |
| `rcs.quiet` | `FALSE` | Silence informative messages. |
| `rcs.trace` | `FALSE` | Record work counters, see [`rcs_trace()`](https://ebukin.github.io/rcs/reference/rcs_trace.md). |
| `rcs.staging_dir` | [`tempdir()`](https://rdrr.io/r/base/tempfile.html) | Folder where files are staged before upload. |
| `rcs.chunk_size` | `1e5` | Rows per chunk in vectorised geospatial work. |
| `rcs.workers` | `1` | Parallel workers for geocoding. |
| `rcs.lock_timeout` | `600` | Seconds after which a local lock is stale. |
| `rcs.record_writer` | `FALSE` | Record the user name in the catalog. |

## See also

Useful links:

- <https://github.com/EBukin/rcs>

- Report bugs at <https://github.com/EBukin/rcs/issues>

## Author

**Maintainer**: Eduard Bukin <edwardbukin@gmail.com> \[copyright
holder\]

Authors:

- Eduard Bukin <edwardbukin@gmail.com> \[copyright holder\]
