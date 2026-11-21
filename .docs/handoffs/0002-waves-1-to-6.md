# Handoff: build rcs, waves 1 to 6

- **Date:** 2026-11-20
- **Author:** Eduard Bukin
- **Plan:** `.docs/plans/0001-rcs-package.md`

## Where things stand

Build the R package `rcs` as the plan describes. Wave 0 (skeleton, contracts, test and benchmark infrastructure) is done and pushed. This session orchestrates waves 1 to 6 and writes no package code itself.

- **Done:** work packages 0, A, B, C, D, I, E, F, G, J, K (waves 0 to 4; the results of each wave are in the plan). The package installs and checks clean with every cross-package function present as a documented stub. `devtools::test()`: 619 expectations, 0 failed, 0 skipped. `devtools::check()`: 0 errors, 0 warnings, 0 notes. Coverage 99.3%.
- **In progress:** nothing. The project owner reviewed the contracts on 2026-11-20 and decided the four open points (see below). The changes that apply those decisions are verified but may still be uncommitted in the working tree (`R/schema.R`, `R/utils.R`, `R/hooks.R`, two test files, the plan, this handoff); worktrees start from the last commit, so they must be committed before wave 1.
- **Not started:** work packages M, L (waves 5 and 6).

## Files touched

Wave 0 created:

- `DESCRIPTION`, `NAMESPACE`, `LICENSE`, `LICENSE.md`, `.Rbuildignore`, `README.Rmd`, `README.md`, `man/`.
- `R/rcs-package.R`: package documentation, the table of options, `ignore_unused_imports()`.
- `R/utils.R`: options, messages, argument checks, dataset names, paths, MD5, version hash, timestamps.
- `R/schema.R`: catalog schemas, the in-memory form, constructors, `columns` specification, manifest, embedded metadata.
- `R/objects.R`: `rcs_location`, `rcs_store`, `rcs_query`.
- `R/backend.R`: the backend object, `be_new()`, the generics.
- `R/hooks.R`: the stubs of the functions called across work packages.
- `R/trace.R`: work counters.
- `R/sim.R`: simulated data.
- `bench/harness.R`, `bench/results/`.
- `tests/testthat/`: `helper-levels.R`, `helper-sim.R`, `test-schema.R`, `test-sim.R`, `test-trace.R`, and, beyond the plan's list, `test-utils.R`, `test-objects.R`, `test-backend.R`, `test-hooks.R`.

## The contracts and where they are documented

Every contract is written in roxygen (`@noRd`) directly above the function: arguments, types, return value, what it aborts on and with which condition class. Read the source file, not `man/`. A subagent implements or calls a function from that text alone; if the text does not suffice, that is a defect to report, not to guess around.

| Contract | File | What to read |
|---|---|---|
| Catalog tables in memory and in Arrow | `R/schema.R` | the header comment (type mapping), `schema_as_arrow()`, `schema_as_tibble()`, `schema_validate()`, `catalog_empty()` |
| Entries and file rows | `R/schema.R` | `new_entry()`, `new_file_rows()`, `bbox_df()` |
| `columns` JSON and `r_type` | `R/schema.R` | `columns_spec()`, `columns_to_json()`, `columns_from_json()` |
| Manifest | `R/schema.R` | `new_manifest()`, `manifest_to_json()`, `manifest_from_json()` |
| `rcs` metadata of a data file | `R/schema.R` | `entry_metadata_json()`, `entry_from_metadata_json()` |
| Names, paths, version | `R/utils.R` | `check_dataset_name()`, `index_name()`, `partition_values_json()`, `data_file_path()`, `manifest_path()`, `version_hash()`, `catalog_files`, `store_file`, `lock_dir` |
| MD5, time, messages, options | `R/utils.R` | `md5_file()`, `md5_hex_to_base64()`, `now_utc()`, `time_to_text()`, `rcs_inform()`, `rcs_option()`, `abort_not_implemented()` |
| Objects | `R/objects.R` | `new_location()`, `new_store()`, `store_locations()`, `store_set_location()`, `effective_history()`, `new_query()` |
| Backends | `R/backend.R` | the header comment (rules for all generics), `be_new()`, every `be_*()` |
| Hooks | `R/hooks.R` | the header comment (conventions), every stub |
| Work counters | `R/trace.R` | the header comment, `local_trace()`, `trace_count()`, `rcs_trace()` |
| Simulated data | `R/sim.R` | `rcs_sim_table()`, `rcs_sim_polygons()` (fixed ids 1 to 9), `rcs_sim_points()`, `rcs_sim_lines()`, `rcs_sim_raster()` |
| Test levels and test data | `tests/testthat/helper-levels.R`, `helper-sim.R` | `skip_below_level()`, `property_cases()`, `sim_polygons()`, `coords_of()` |
| Benchmarks | `bench/harness.R` | `bench_run()`, `bench_counters()`, `bench_env()`, `bench_save()`, `bench_read()` |

Who implements which stub, and who calls it:

| Stub in `R/hooks.R` | Implemented by | Called by |
|---|---|---|
| `h3_as_int64()`, `h3_as_hex()` | B, `R/geo-h3.R` | C, E, F |
| `h3_parent()` | B, `R/geo-h3.R` | C |
| `geo_encode()` | B, `R/geo-encode.R` | E |
| `geo_decode()` | B, `R/geo-encode.R` | E, F |
| `geo_metadata()` | B, `R/geo-encode.R` | C |
| `geo_cells_touched()` | B, `R/geo-encode.R` | B, F |
| `geo_covering()` | B, `R/geo-encode.R` | F, I |
| `files_row_groups()`, `files_read_row_groups()` | C, `R/files.R` | E, F |
| `resolve_dataset()`, `choose_location()` | C, `R/resolve.R` | D, E, F, G |
| `raster_stage()` | I, `R/raster.R` | E |
| `raster_open()` | I, `R/raster.R` | F |
| backend methods for `rcs_backend_local`, `rcs_backend_gcs` | A | everyone |

Rules for stubs:

- The implementing package moves the documentation to its own file, keeps the signature and return value exactly, and deletes the stub from `R/hooks.R` in its worktree. This is required: files load in alphabetical order, so a stub left in `hooks.R` replaces an implementation in `geo-encode.R` or `files.R`.
- `tests/testthat/test-hooks.R` checks the signatures and stays as it is. It passes for stubs and for implementations.
- Two packages of one wave delete different stubs from `R/hooks.R`; if the merge conflicts, the resolution is the union of the deletions.
- A package that needs a hook of its own wave before the merge (C needs `h3_parent()` and `geo_metadata()` from B) tests with `testthat::local_mocked_bindings()`; the real combination is tested after the merge.

## Decisions taken in wave 0

Where the plan left a signature or a shape open. Reviewed by the project owner on 2026-11-20.

Catalog and files:

1. In memory a catalog file is a tibble with the schema's columns in schema order: `string` is character, `list<string>` a bare list of character vectors, `int64` is `bit64::integer64`, `int32` integer, timestamps `POSIXct` in UTC, `bbox` a data-frame column with four doubles. `schema_as_arrow()` and `schema_as_tibble()` are the only conversions.
2. Timestamps are `timestamp[us, UTC]`; `now_utc()` rounds to microseconds so that a value survives Parquet and JSON unchanged. In JSON a timestamp is `2026-01-31T12:00:00.000000Z`.
3. In the manifest and in the `rcs` metadata every `int64` is a JSON string, because a cell or a large count does not fit a JSON number; `NA` is `null`; `entry$columns` stays the JSON string of the catalog.
4. The version is the first 16 hex characters of the MD5 of the lines `<partition_values>|<md5>`, sorted in the C locale, joined with `"\n"`, no trailing newline. A test pins one value (`cc969206f5123a26`); changing the definition changes the version of every stored dataset.
5. `partition_values` is one canonical JSON object, keys in partition-column order; factors, dates and `integer64` as strings; `{}` for a one-file dataset.
6. `data_file_path()` and `manifest_path()` build every path; partition values are URL-encoded with reserved characters escaped.
7. The `columns` specification is a tibble `name`, `type`, `r_type`, `description`. `r_type` is `NULL` or a list with `class`: `difftime` (+ `units`), `integer64`, `factor` (+ `levels`, `ordered`), `list`, and for raster layers `SpatRaster` (+ `resolution`, `dim`). The catalog has no column for raster resolution; it lives here.
8. Dataset names are checked against ASCII only (`perl = TRUE`): in some locales `[a-z]` matches accented letters.

Objects:

9. `rcs_store` is an environment with a class, not a list around one. Fields: `primary`, `secondary` (unnamed list), `history` (connection override: `TRUE`, `FALSE` or `NULL`), `store_history` (the store's default from `_store.json`), `connected_at`. Locations change only through `store_set_location()`, which matches by `uri`.
10. `rcs_location$backend` is the backend object, and `uri` is the address as `be_new()` normalised it. Two addresses are the same location exactly when their `uri` are equal.
11. `effective_history(st, dataset_history)` implements the precedence dataset, connection, store.
12. `rcs_query` has the fields `store`, `entry`, `location`, `files`, `query`, `spatial`, `geometry`.

Backends:

13. `be_new(uri)` is a plain function: it parses the address, builds the object (`type`, `uri`, `root`, `bucket`, `prefix`) and passes it to the new generic `be_init()`, where a backend checks its clients. Parsing contacts nothing.
14. New generics `be_lock(be, timeout)` and `be_unlock(be)` carry the local lock; the default methods do nothing (cloud backends).
15. `be_delete()`, `be_md5()` and `be_exists()` take a vector of paths. `be_md5()` gives `NA` for a missing file; `be_delete()` skips missing files.
16. `be_list()` returns a tibble `path`, `bytes`, `modified`; `store_prune()` needs the age of orphans.
17. `be_arrow_fs()` returns `list(fs, path)`; a file `p` is `paste0(path, "/", p)` in `fs`.
18. Every generic counts itself (`backend_call`) before dispatch; `be_put()` and `be_get()` count the bytes. Methods and the failing stub backend do not count again.
19. All paths passed to generics are relative to the location root, forward slashes, no leading slash. Failures abort with class `rcs_error_backend`; retries belong to the caller.

Hooks:

20. Cells are `integer64` everywhere inside the package; `h3_as_int64()` and `h3_as_hex()` are the only converters and reject a plain numeric with class `rcs_error_h3_input`.
21. WKB geometry is a bare list of raw vectors in the column `geometry`; Arrow writes it as `binary`.
22. `geo_encode(x, h3_res, geocode, key, id_start)` also puts the rows into written order and assigns `.rcs_id` in that order, because the order depends on `h3` and the index table refers to the ids. It returns `data` (a tibble, not `sf`), `index`, `crs`, `bbox`.
23. `geo_decode(data, crs)` only turns WKB into `sf`; which helper columns a read drops is decided in F.
24. `geo_metadata(data, crs)` gives the `geo` JSON of one file, so that C can write it per file without knowing GeoParquet.
25. `geo_covering(shape, h3_res, crs)` returns `shape` (data CRS, for the exact test), `bbox` (`NULL` when bounding-box tests must be skipped) and `cells` (`NULL` without geocodes).
26. `raster_stage()` returns `entry`, `files` and `staged`; the staged file lies at `file.path(dir, files$path)`. `raster_open(be, path, intersects)` takes the backend object.
27. `files_row_groups(be, paths)` (new) lists row groups from footers; `files_read_row_groups(be, path, row_groups, columns)` returns an Arrow `Table`; row groups are numbered from 1.
28. `resolve_dataset(st, dataset, index, call)` returns the full name; `choose_location(st, dataset, version, call)` returns the `rcs_location` and prints the "reading from secondary" line itself.

Work counters, options, errors:

29. Every exported function that touches a store starts with `local_trace("<name>")`; the outermost call owns the records. Counters: `backend_call`, `catalog_read`, `file_open`, `row_groups_total`, `row_groups_overlap`, `rows_candidate`, `rows_returned`, `bytes_up`, `bytes_down`. `rcs_trace()` returns `call`, `counter`, `detail`, `location`, `n`.
30. Options are read only through `rcs_option()`, which holds the defaults.
31. Condition classes in use: `rcs_error_not_implemented`, `rcs_error_argument`, `rcs_error_dataset_name`, `rcs_error_schema`, `rcs_error_object`, `rcs_error_unsupported_location`; reserved by the documentation for later packages: `rcs_error_backend`, `rcs_error_locked`, `rcs_error_h3_input`, `rcs_error_geo`, `rcs_error_raster`, `rcs_error_dataset_not_found`, `rcs_error_dataset_ambiguous`, `rcs_error_version_not_found`.

Simulated data and tests:

32. `rcs_sim_table()` has three columns more than the plan (`promo` logical, `grade` ordered factor, `delivered` Date), so that every type of "Types" occurs with missing values. `shop_id`, `date`, `product` (a unique key) and `year` hold no missing value.
33. `rcs_sim_polygons()` needs `n >= 20` and the h3o package. Ids 1 to 9 are fixed shapes in a documented order, then the crossing rows, then the small ones; the special rows are `n + 1` and `n + 2`. The projected case is `sf::st_transform(x, 32626)`.
34. `rcs_sim_raster()` takes `nrow` and `ncol` (default 1000) so that tests can use a small raster.
35. Test level when `RCS_TEST_LEVEL` is unset: `cran` on CRAN and under `R CMD check` (`testthat::is_checking()`), else `default`. `property_cases()` gives the number of cases of a property test per level.
36. `DESCRIPTION`: `Depends: R (>= 4.4.0)`; no `VignetteBuilder` yet (K adds it with the first vignette). `dplyr` and `tidyselect` are imported but not yet called; `ignore_unused_imports()` in `R/rcs-package.R` names them, and the package that first uses one removes its line.

## Open points, decided by the project owner on 2026-11-20

All four are applied to the plan, the code and the tests; nothing is open.

1. **Empty geometries and `partition = "h3"` (B, C, E).** Rows without a cell (`h3` NA) form one partition of their own; its value is `null` in `partition_values` and in the path (`h3_p2=null`). `partition_values_json()` and `data_file_path()` do this already.
2. **Reproducible file MD5s (C).** The embedded `rcs` metadata also leaves out `bbox`, `history`, `r_version` and `rcs_version` (`entry_not_embedded`, `R/schema.R`).
3. **`rcs_sim_table()`.** No missing value in `shop_id`, `date`, `product` and `year`; confirmed.
4. **Columns a read returns (F).** `.rcs_id` is dropped; `h3`, `bbox` and `h3_p<r>` are returned.

## How to verify

In an R session of your own (see the `run-r` skill), from the project folder:

```r
devtools::document()
devtools::test()     # 619 expectations, 0 failed, 0 skipped
devtools::check()    # 0 errors, 0 warnings, 0 notes
```

```
git status           # clean, or only the decision changes named above
git log --oneline    # the wave 0 commit on main, pushed
```

## Next steps

1. Read `CLAUDE.md`, the whole plan, this handoff, and the header comments of `R/schema.R`, `R/backend.R`, `R/hooks.R` and `R/trace.R`.
2. Run the verification above; it must pass before anything is launched. If `git status` shows the uncommitted changes named under "Where things stand", commit them with explicit paths and push; this is approved by the project owner.
3. Run waves 1 to 6 by the procedure below.

Orchestration procedure:

- The session's agent orchestrates and writes no package code itself. For each wave it launches one subagent per work package, in parallel, each with `model: "opus"` and `isolation: "worktree"`, at most 3 at once.
- Each subagent's brief names:
  - its work package and the plan (`.docs/plans/0001-rcs-package.md`), to be read in full;
  - the files it owns, and that it touches no other file except to delete its own stubs from `R/hooks.R`;
  - the contract documentation: this handoff and the roxygen above the functions it implements or calls;
  - the rule that it passes its worktree path to `devtools::load_all("<worktree>")` and `devtools::test("<worktree>")` and never calls `setwd()`, `devtools::document()` or `devtools::install()`, and never commits `NAMESPACE`, `man/` or `DESCRIPTION`;
  - the `run-r` lifecycle: its own Positron R session, closed at the end, the user's console never touched;
  - the report format: what it built, test results, deviations, `DESCRIPTION` changes needed, anything in the plan or the contracts that proved wrong, and `session closed` as the last line.
- After a wave: merge the branches, apply the `DESCRIPTION` changes, run `devtools::document()`, the whole test suite at `RCS_TEST_LEVEL=default` and `devtools::check()`; fix or send back what fails; tick the packages in the plan; commit and push. Then start the next wave without asking. Stop only when the suite still fails after one round of fixes, or when a subagent reports that the plan is wrong.
- A report that does not end with `session closed`: send a small agent to `quit()` that R session.
- Before wave 6 ask the project owner for the list of forbidden terms for the neutrality scan; it is never written to a file in the repository.

## Gotchas

Decisions already made; do not reopen them:

- Everything under "Gotchas" of `.docs/handoffs/0001-wave-0-kickoff.md` still holds: backends `local` and `gcs` only, test bucket `gs://rcs-test` under a random prefix; history off by default with three levels; no `h3_cell` column, `.rcs_id` on every geospatial dataset, a manifest per version, the connection updates in place; `update` warns and never aborts on shrinking partitions; writes go to all locations; antimeridian and pole geometries are supported; no CI workflow; the neutrality rule; commit messages without e-mail address and without AI attribution.

Things that looked right and were not:

- `h3o::h3_from_xy(x, y, resolution)` takes latitude first. An H3 index does not fit a double. A cell is not inside its parent.
- Arrow returns a small-valued int64 column as `integer` unless `arrow.int64_downcast` is `FALSE`; `schema_as_tibble()` sets it, other reads must set it themselves.
- Do not lower Arrow's thread pools; a dataset scan then deadlocked the R session.
- `sf::st_coordinates()` fails on a geometry column of mixed types, which is what `rcs_sim_polygons()` returns (polygons and multipolygons). Use `wk::wk_coords()`, or `coords_of()` in tests.
- `c()` and `[<-` on an `sfc` compute every bounding box again; build a plain list and call `sf::st_sfc()` once (see `rcs_sim_polygons()`).
- Code before `UseMethod()` runs, and `on.exit()` set there fires after the method returns; the backend generics count their work this way.
- `devtools::check()` sets `NOT_CRAN=true`, so that variable does not tell a check from `devtools::test()`; `testthat::is_checking()` does.
- Source files under `R/` must be ASCII: write non-ASCII text as `\u` escapes, and check with a search for non-ASCII bytes before the wave's `devtools::check()`.
- A method for an internal generic written in a test is not found by dispatch; use `testthat::local_mocked_s3_method()`.
- `h3o`, `terra`, `bench` and `covr` were not installed although the plan's "Verified facts" name them; they are now (h3o 0.3.0, terra 1.9.50, bench 1.1.4, covr 4.0.0). Nothing is installed for other cloud services.
