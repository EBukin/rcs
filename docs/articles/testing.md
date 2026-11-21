# How rcs is tested

A storage package must not lose or mix up data, also when a network
fails halfway through a write. This article describes how the tests of
rcs check that, and how to run them. The code below is not run here: it
starts the test suite, which takes from seconds to many minutes
depending on the level.

Two rules hold throughout the suite:

- every algorithm is compared with a slow, independent reference;
- every operation on a store is followed by a check of the store’s
  invariants.

All tests use simulated data from the `rcs_sim_*()` generators, and
every store is built in temporary folders that are removed afterwards.
The tests use testthat (third edition).

## Test levels

The suite has three levels, chosen by the environment variable
`RCS_TEST_LEVEL`. Each level adds tests to the one before.

| Level | What it runs | Default when |
|----|----|----|
| `cran` | Unit tests: no network, small data, a few seconds per file. | `RCS_TEST_LEVEL` is unset and the tests run on CRAN or under `R CMD check`. |
| `default` | Adds the integration suite on local folders and property tests of about 200 random cases each. | `RCS_TEST_LEVEL` is unset otherwise, e.g. under [`devtools::test()`](https://devtools.r-lib.org/reference/test.html). |
| `full` | Adds property tests of up to 2,000 cases, every point of every crash-point matrix, the long random-operation sequences, and the tests against a Google Cloud Storage bucket. | Never; set it. |

Run each level from the package folder:

``` r

# default: the local integration suite and property tests
devtools::test()

# cran: unit tests only
withr::with_envvar(c(RCS_TEST_LEVEL = "cran"), devtools::test())

# full: everything, including the random-operation test
withr::with_envvar(c(RCS_TEST_LEVEL = "full"), devtools::test())

# one file
devtools::test(filter = "intersects")
```

Inside the tests, `skip_below_level("default")` or
`skip_below_level("full")` at the top of a test skips it below that
level, and `property_cases()` gives the number of random cases of a
property test at the current level. Both live in
`tests/testthat/helper-levels.R`.

## Store invariants

After every step of every integration test, `expect_store_valid(st)`
(`tests/testthat/helper-invariants.R`) reads the catalogs of every
available location again and checks, for each:

1.  every file the catalog names (current and history) exists, with the
    recorded size and MD5 checksum, and its Parquet footer holds the
    recorded number of rows;
2.  every dataset’s version equals the hash of its file rows, and its
    totals (files, rows, bytes) equal the sums of those rows;
3.  a manifest exists for every version in the catalog and agrees with
    it, and no file is named by two datasets;
4.  with history off, no file exists that the catalog does not name,
    apart from files left by an injected failure, which
    [`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
    must then remove;
5.  every index table agrees with its dataset: every row identifier
    exists and every recorded main cell equals the row’s `h3`;
6.  every secondary copy of a dataset either equals the primary’s or is
    reported as `missing` or `differs` by
    [`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md).

It also checks that the connection object holds the catalogs that are
stored, so that a function that changed a location updated the object in
place. All problems are collected and reported in one failure.

## Failures and crash points

A backend stub (`tests/testthat/helper-backend-stub.R`) wraps the local
backend, counts the calls made through it and, on chosen calls, fails or
silently alters a written file. With it the tests check, among others:

- a failure of the primary during upload, or between two catalog files:
  no catalog changes, and repeating the call succeeds and copies only
  what is missing;
- a failure of a secondary during a write: a warning, the secondary is
  reported as behind, and
  [`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
  repairs it;
- a transient error on the first two attempts of one file: the write
  succeeds;
- an upload that silently alters a file: the MD5 check stops the write;
- a catalog changed by another writer between the start of a write and
  its catalog switch: the write stops and changes nothing;
- a stale lock on a local location is taken over, a fresh one blocks;
- a lock that cannot be released after a catalog switch only warns: the
  operation completes, secondaries included, and the lock stays until
  its timeout;
- a reader connected before a write reads the old version when history
  is kept, and without history gets an error (class
  `rcs_error_version_not_found`) telling it to run
  [`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md).

The **crash-point matrix** goes through the backend calls of an
operation. Each of
[`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
(every mode, and a geospatial write with its index table),
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md),
[`store_delete()`](https://ebukin.github.io/rcs/reference/store_delete.md)
and
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
is first run with a counting stub to learn its number of backend calls,
N. It is then run again with the stub failing at one call, on the
primary and on a secondary: at level `full` at every call 1, 2, …, N; at
level `default` at one call of some of the matrices, plus every
`be_unlock()` call. After each failure the invariants hold, every
location holds the old or the new version of each dataset and never a
mixture, and repeating the call (or
[`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
for a secondary left behind by a write) succeeds, sends only the files
that are missing, and ends in the state of a run without failure.
Orphans left by the failure are then removed by
[`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md).

The matrix is the helper `crash_matrix()` in
`tests/testthat/helper-model.R`; a test file calls it like this:

``` r

crash_matrix("store_sync()",
  setup = function(paths) { ... },   # builds the start state in three folders
  op = function(st) store_sync(st),  # the operation on a connection
  stub_at = 1L,                      # 1: fail in the primary, 2: in a secondary
  points = NULL,                     # NULL: every call; a number: that many
  repair = "repeat",                 # what follows a failure
  unlock = TRUE                      # also fail every be_unlock() call
)
```

## The random-operation test

Seeded sequences of operations run against three local locations and, in
parallel, against a plain model in memory: a named list of data frames
per location. Level `default` runs two short sequences of 6 operations;
level `full` runs four sequences of 50
(`tests/testthat/test-random-operations.R`, with the helper
`random_sequence()` in `helper-model.R`). The operations are create,
replace, update, delete, sync, copy, prune, rebuild, an injected
failure, and switching history on or off for the store, the connection
or one dataset. After every step the invariants hold, and
[`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
of every dataset from every location equals the model. A failing run
prints its seed and its list of operations, so it can be replayed.

## Reference oracles

The algorithms of the package are checked against slow references that
share no code with it (`tests/testthat/helper-geo-reference.R` and the
tests themselves):

- the `h3` cell of every simulated row equals the cell of largest
  overlap found by brute force, by intersecting the geometry with every
  nearby cell on the sphere;
- the index table’s rows equal the cells a brute-force intersection with
  the cell grid finds, for every row that crosses a cell edge;
- the cells computed for a query contain every cell that intersects the
  query shape, on the sphere and in the plane, among the cells of a
  dense grid of points around it, for random shapes including thin
  strips, large rectangles with four vertices, shapes with holes and
  single points;
- a spatial read returns exactly the rows of
  [`sf::st_filter()`](https://r-spatial.github.io/sf/reference/st_join.html)
  on the whole dataset, for random query shapes and H3 cells of
  resolutions 2 to 9, and a superset with `exact = FALSE`; repeated for
  a projected CRS, for partitioned and unpartitioned datasets, for
  `geocode = FALSE`, for points and lines, and with
  [`sf::sf_use_s2()`](https://r-spatial.github.io/sf/reference/s2.html)
  on and off;
- the polygons across the antimeridian and around the pole get the
  brute-force cells, are found from either side of ±180° and at the
  pole, and are not returned by a query elsewhere;
- a round trip of every column type (logical, integer, double, text with
  non-ASCII characters, factors with unused levels, ordered factors,
  dates, times with time zones, time differences, 64-bit integers, list
  columns, missing values, zero rows, every geometry type) is
  [`identical()`](https://rdrr.io/r/base/identical.html) after
  normalisation, for one file and for partitioned datasets.

## Other checks

- **Detection:** an altered data file, a missing data file, a truncated
  catalog, a wrong MD5 in the catalog and a manifest that disagrees with
  the catalog are each caught by
  [`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md),
  with a message naming the file.
- **Determinism:** the same data written twice give the same version;
  changing one value changes it.
- **Work counters:** with `options(rcs.trace = TRUE)` the package counts
  backend calls, files opened, row groups and rows (see
  [`rcs_trace()`](https://ebukin.github.io/rcs/reference/rcs_trace.md)).
  Because the counts are exact, tests assert them: listing and
  describing a store open no data file, a filter on partition columns
  opens only the matching files, a repeated identical write uploads no
  data file.
- **Messages:** print methods, write summaries and error messages are
  covered by snapshot tests (`expect_snapshot()`).
- **Interoperability** (`tests/testthat/test-interop.R`, level
  `default`): DuckDB with its spatial extension reads a written
  geospatial file as a geometry column with its CRS, and a filter on the
  `bbox` struct returns the rows of the same filter in R; GDAL
  ([`sf::st_read()`](https://r-spatial.github.io/sf/reference/st_read.html))
  reads the file when its Parquet driver is present. Each test skips
  when its tool is missing; common Windows builds of GDAL lack the
  Parquet driver.

## The cloud tests

At level `full`, the Google Cloud Storage backend is tested against a
real bucket when the environment variable `RCS_TEST_GCS` names one
(`tests/testthat/test-backend-gcs.R`): uploads, downloads, MD5 checksums
read without a download, listing and deletion, a Parquet file streamed
through Arrow and a file read through GDAL’s `/vsigs/` path; and a
raster is opened through `/vsigs/` (`test-raster.R`). The GDAL tests
also need `GOOGLE_APPLICATION_CREDENTIALS`. The integration suite itself
runs on local folders only. Each run works under a random prefix in the
bucket and removes it at the end. Use a dedicated, empty bucket, and set
up credentials as described in
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md):

``` r

withr::with_envvar(
  c(RCS_TEST_LEVEL = "full", RCS_TEST_GCS = "gs://my-test-bucket"),
  devtools::test()
)
```

Without `RCS_TEST_GCS`, and on CRAN, these tests are skipped.

## Coverage

``` r

covr::package_coverage()
```

The aim is at least 90% of lines overall and 80% in every file.
