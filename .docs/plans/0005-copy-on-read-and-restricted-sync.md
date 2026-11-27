# Copy on read to secondary locations; sync restricted to the datasets a secondary already holds; primary-only writes

- **Date:** 2026-11-26 (verified and revised 2026-11-27; version and preflight updated 2026-11-27 after plan 0006, parts A and C; revised 2026-11-27: rasters of plan 0006 taken in, Part C added, test scope)
- **Author:** Eduard Bukin
- **Status:** draft

## Goal

When this plan is done:

1. **Part A (sync).** `store_sync()` to secondary locations, without `datasets`, refreshes only the datasets each secondary already holds. It says that only those were synced, how many datasets and how much data (files, bytes) a full sync would add, and that `all = TRUE` copies everything. `datasets = ` still copies the named datasets whether or not a secondary holds them. A sync whose target is the primary (`from = <secondary>`) still sends everything. An empty secondary is announced at `store_connect()` and in every `store_sync()`, with an invitation to sync it by hand.
2. **Part B (copy on read).** `store_read()` of the current version of a dataset that a reachable **local secondary of a non-local primary** lacks, or holds at an older version, first copies the whole dataset to that secondary with the existing copy code, with a progress bar and a message, then reads from the copy. It does not copy when the download exceeds 2 GB (`rcs.copy_on_read_max_bytes`), for old versions, or when the connection or the call turns it off. In every one of those cases it reads only what it needs from the primary and says how to copy. `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` never copy. Rasters follow the same rules (see "What plan 0006 changed").
3. **Part C (primary-only writes).** `store_write(locations = "primary")` writes a dataset to the primary only. The catalog records it. `store_status()` and `store_datasets()` report `"primary only"` instead of `"missing"`; `store_sync(all = TRUE)` and copy on read leave such a dataset alone unless it is named. This is the way to keep a large raster in the bucket whatever its size.
4. Every change is test-driven: the tests are written first and shown to fail for the stated reason (red), then the code makes them pass (green). A separate verifier confirms each step. Each work package runs only the test files of the feature it changes ("Test scope"), never the whole package.
5. The new code paths are shown to be efficient by work counters (`rcs_trace()`) and a short timing script. The full benchmark (`bench/`) is **not** re-run.
6. Two releases, each in its own commit (not pushed), each with the website rebuilt into `docs/`: Parts A and B as version `0.0.0.9007`; Part C as version `0.0.0.9008`. The status is `done` only after Part C.

Decision record: `.docs/notes/0003-local-copy-on-read-and-restricted-sync.md`. Read it first. The decisions below make it precise and, where the owner decided otherwise on 2026-11-27 (D-B1, D-A6, D-A7), replace it. Where handoff 0004 differs from this plan, the plan governs. Part C comes from `.docs/notes/0004-raster-categorical-cog-and-primary-only.md` (point 5 of the report and its proposal "Primary-only writes"); everything needed to execute it is in this plan.

**Provenance of Part C.** Moved from plan 0006, Part B, on 2026-11-27 (owner's instruction of that day: plan 0005 implements what plan 0006 was waiting for). Plan 0006 is closed for its Parts A and C; this plan is the only place where primary-only writes are specified. No agent needs plan 0006 to execute this plan.

| In plan 0006 | Here |
|---|---|
| D-B1 … D-B7 | D-C1 … D-C7 |
| WP6 (survey) | WP9 |
| WP7, WP7-V (red tests) | WP10, WP10-V |
| WP8, WP8-V (code) | WP11, WP11-V |
| WP9 (docs and release) | WP12, WP12-V, WP13 |
| B-T1 … B-T10 | C-T1 … C-T10 |

## Context

### What exists that this plan builds on

Line numbers were checked against the code at `0b47207` (version `0.0.0.9006`) on 2026-11-27. They move as soon as a work package edits a file: **find every function by its name; the name governs.**

- **Choosing where a read comes from.** `choose_location()` in `R/resolve.R` (line 92) picks, among available locations holding the dataset at the primary's version: local backends first (**the primary first among them**), then the primary, then other secondaries. "Local" is `identical(location$backend$type, "local")`. So a read comes from a secondary only when the primary is not local and the secondary is. For an old `version` it reads `_history.parquet` and calls `be_exists()`. It informs `Reading "<dataset>" from secondary <uri>.` It makes no backend call for the current version. It compares **versions only**.
- **Read entry point.** `read_target()` in `R/read.R` (line 21) resolves the name (index tables too), calls `choose_location()`, and finds entry and files. For the current version the entry is the **primary's** catalog entry (`R/read.R:31-35`), whichever location serves the files. `store_read()` (line 201), `store_sample()` (line 310) and `store_glimpse()` (line 414) all call it; so do `store_open()` (`R/query.R:137`) and `store_duckdb()` (`R/duckdb.R:228`). No other function in `R/` calls `store_read()`. `store_read()` has `...` (filter expressions) before its named arguments; its raster branch (`R/read.R:214-235`: the raster-argument checks at lines 215-230, then `raster_open()`), `select_columns()` and the `intersects` validation run after `read_target()` (line 212).
- **Copying one dataset.** `store_copy()` in `R/sync.R` (line 755) refreshes both locations through `reach()` (aborts with `rcs_error_backend`, outside any `tryCatch`), creates its own staging folder and `write_context()` (lines 776-780), builds a unit with `sync_unit()` (the dataset plus its index table), writes fresh manifests (`sync_fresh_manifests()`, new `written` time), and lands it with `land_location()` (`R/write.R:1662`). `land_location()` sends only the files the target lacks: it matches path + MD5 against the target's files table **and against `history_read(be)` and `be_md5()`, which are backend calls** (`R/write.R:1671-1679`), verifies MD5, puts manifests, then switches the catalogs under the write lock; it always makes the landed version the current one and has no conflict check. Its upload goes through `upload_verified()` (`R/write.R:1601`), which shows a cli progress bar unless `rcs.quiet`. `source_file()` caches downloads per context only (`R/write.R:1538-1554`). `landed_anyway()` (`R/sync.R:344`) handles errors raised after the catalog switch. Write-class errors are `write_error_classes` (`R/write.R:708`: backend, conflict, locked, schema).
- **Does a location hold an entry?** `holds_entry()` (`R/write.R:1480`) compares the **whole catalog entry** (`entry_key()`: every field, `columns` and `updated` included), not only the version. `land_location()` (line 1665), `unit_needed()` (`R/sync.R:331`), `landed_anyway()` and the dry run use it.
- **Sync.** `store_sync()` (`R/sync.R:113`) builds every unit of the source and a fresh manifest for each (lines 133-140), prints `sync_header()` (line 144, "Syncing {n} datasets…"), then plans per target with `sync_plan(st, source, target, units, restrict, delete, force)` (line 376), which returns `copy`, `conflicts`, `overwritten`, `delete`, `kept`. `restrict` is `NULL` whenever `datasets` is `NULL`. Targets that are unavailable or behind at refresh get a result with no plan (lines 148-151). Landing is `sync_location()` (line 424; re-signals non-write errors; its `behind()` is used at line 465); the dry run is `sync_plan_location()` (line 505). `sync_footer()` (line 633; returns early for dry runs; line 649 prints "Every secondary location is up to date." when every status is `"same"`). The result tibble (one row per target) is built by `sync_result()` / `sync_result_row()` / `sync_empty()` (lines 534-557). `sync_refresh()` (lines 229-255) turns write-class refresh failures into a warning.
- **Connection object.** An environment. `new_store()` and `validate_store()` in `R/objects.R` (lines 109, 123); the documented field table is above them. `_history.parquet` is **never held in the object** (`R/objects.R:21`). `store_connect()` in `R/connect.R:68` (no `...`). `store_refresh()` (`R/connect.R:194`) replaces only the locations. The primary is always available (`validate_store()` aborts otherwise). `available` is a held field of each location.
- **Options.** Defaults in `rcs_option()` (`R/utils.R:19-37`, with a roxygen list at lines 12-15), documented in the table in `R/rcs-package.R:11-23`.
- **Bytes.** The catalog and file rows carry `bytes` as `bit64::integer64` (`R/schema.R:66, 89`): convert with `as.numeric()` before summing or comparing. `format_bytes()` (`R/utils.R:409`) uses decimal units; `format_bytes(2e9)` prints `2.0 GB`. `format_seconds()` prints `4.2s`.
- **Work counters.** `R/trace.R`; counters `backend_call`, `catalog_read`, `file_open`, `bytes_up`, `bytes_down`. They record only under `options(rcs.trace = TRUE)`; tests read them with `rcs_trace()` / `rcs_trace_reset()`. `bytes_down` counts the package's own downloads (`be_get()`), not GDAL's range requests.
- **Messages that send users to `store_sync()`** (written `{.fn store_sync}` in the source; snapshotted in `tests/testthat/_snaps/write.md`): `R/write.R:697` (warning in `write_refresh()`, secondary unreachable: "Run `store_sync()` once it can be reached."), `R/write.R:1899` (warning in `land_secondary()`, write to a secondary failed: "Run `store_sync()` to bring it up to date."), `R/write.R:2004` (inform in `write_footer()`: "{n} secondary location(s) is/are behind; run `store_sync()` to bring it/them up to date."). Roxygen at `R/write.R:329-331` and `R/inspect.R:119-120`.
- **Tests.** `store_sync(` appears on 54 lines of `tests/testthat/test-sync.R` and 9 of `test-integration.R` (test names included), in one call of `test-crash-points.R` (line 64, `op_sync()`; lines 6 and 125 are a comment and a label), one call of `test-catalog.R` (line 508) and `helper-model.R` (3 calls: line 289 in `crash_matrix()`, lines 369 and 458 in `random_sequence()`). `test-sync.R:473` is a level-`full` test against a bucket that shares its body (`s_check_delete()`, `s_check_offline()`) with local tests. Most fixtures build the connection with `fixture_connect()` → `new_store()` (`helper-store.R:143`), not `store_connect()`. A cloud primary is simulated by `primary <- st$primary; primary$backend$type <- "gcs"; st$primary <- primary` (`test-read.R:166-169`; the same in `test-query.R:280-282`); backend generics dispatch on the S3 class, so the folder keeps working. A secondary is made unavailable as in `test-sync.R:150-160`. `local_backend_stub(uri =, generic =, fail_at =)` (`helper-backend-stub.R:75`) makes a backend call fail. Snapshot helpers: `g_quiet()`, `g_snapshot_output()` (sets `rcs.quiet = FALSE`). Class maps for tests: `sim_landcover(nrow, ncol, seed, file, legend, colors)` with `sim_landcover_labels` and `sim_landcover_colors` (`helper-sim.R:62-65`). A bucket prefix for a test: `local_raster_bucket()` (`test-raster-gcs.R:11`; defined in that test file, so other files cannot call it).
- **Docs that describe sync or secondaries:** `vignettes/locations.Rmd`, `vignettes/duckdb.Rmd`, `vignettes/geospatial.Rmd` ("Large maps"), `vignettes/articles/testing.Rmd`, `README.Rmd`, `bench/spatial.R:547`.
- **Website.** `docs/` is committed and served from `main`. It is built by `site_build()` in `pkgdown/deploy.R`. The guard at the end of that file builds only when the file is sourced at top level: inside a `callr` process `source("pkgdown/deploy.R")` builds nothing, and `site_build()` has to be called after it.

### What plan 0006 changed (rasters), and what it means here

Plan 0006, parts A and C (versions `0.0.0.9005` and `0.0.0.9006`), changed how rasters are written and read. Checked in the code on 2026-11-27:

- **One file per raster.** A raster dataset is one Cloud Optimized GeoTIFF, `<dataset>/part-<version>.tif`. `raster_stage()` (`R/raster.R:1013`) writes it below `rcs.staging_dir`; `land_location()` uploads it and verifies its MD5, as for any dataset. One file means: copying a raster is all or nothing.
- **Reading a raster.** In `store_read()`, the raster branch comes right after `read_target()` (`R/read.R:214-235`). It aborts with `rcs_error_argument` when `...`, `columns`, `geometry`, `exact` or `exact_engine` is given, then returns `raster_open(<backend of the chosen location>, <path>, intersects, columns = columns_from_json(target$entry$columns))`. `raster_open()` (`R/raster.R:1153`) opens the file through GDAL (`be_gdal_path()`: the folder path for a local store, `/vsigs/…` for a bucket) and, with `intersects`, crops it to the query's box. The file is never downloaded by a read: GDAL fetches the tiles of the window. `store_glimpse()` opens a raster the same way (`R/read.R:434-442`); `store_sample()` aborts for a raster.
- **Retry after a stale listing.** When `terra::rast()` fails on a `/vsi…` path, `raster_open()` calls `terra::clearVSIcache()` and tries once more (`R/raster.R:1157-1178`). So a raster replaced in the bucket is read again in the same session. Nothing in this plan needs to handle that.
- **Arguments of `store_write()`.** Its last arguments are now `crs = NULL, datatype = NULL, nodata = NULL, gdal = NULL` (`R/write.R:481-488`; the checks at lines 509-526). Part C's `locations` goes after `gdal`.
- **Legend and colours live in the catalog entry, not in the file.** They are fields of the layer's `r_type` inside `entry$columns` (`values`, `levels`, `levels_name`, `color_values`, `colors`; `r_type_array_fields`, `R/schema.R:588`). Writing the same cells with another legend or other colours gives the **same MD5 and the same version**. `resolve_target()` (`R/write.R:1449`) then makes "a change of the entry only": the same files, a new manifest under the same path, `updated = now`, and the catalogs rewritten. `store_read()` restores legend and colours from the entry.
- **What decides that a secondary "differs".** Three places, not alike:
  - `location_status()` (`R/inspect.R:27`, used by `store_status()`, `store_datasets()` and the print of a connection) compares **versions only** (line 53). A secondary that holds the same version with an older legend is `"same"`.
  - The sync plan and every landing compare the **whole entry**: `unit_needed()` → `holds_entry()`. So a write lands the new entry in every available secondary without sending a file, and `store_sync()` refreshes a secondary that missed it (for example because it was unavailable during the second write). **The existing code already handles this**; the restricted sync of Part A keeps it, because such a secondary holds the dataset (D-A2). Guard test: A-T13. `sync_plan()` records a conflict or an overwrite only when the versions differ (line 384), so this refresh is silent.
  - `choose_location()` compares **versions only**, so a read is served by a local secondary that holds the version with an older entry. The legend and colours of a current-version read still come from the primary's entry (`read_target()`), so the read is right. The secondary's own catalog stays stale until something refreshes it; a connection to that secondary alone would show the old legend.
  - The copy-on-read gate of Part B was worded on versions ("holds an older version"). It needs a rule for the same version with another entry: **D-B13** (orchestrator's default: keep the secondary equal to the primary). Red test: B-T20.
- **Copy on read and rasters.** The 2 GB rule applies to a raster as to any dataset (D-B2). A windowed read, `store_read(st, "<raster>", intersects = <shape>)`, with a non-local primary and a local secondary, does this:

  | Case | What happens |
  |---|---|
  | The secondary lacks the raster (or holds an older version) and the file is at or under the limit | The **whole file** is copied to the secondary first. Then the window is read from the local copy. |
  | The file is over the limit | Nothing is copied. The window is read from the bucket through `/vsigs/`. A message says how to copy. |
  | `copy = FALSE`, or `copy_on_read = FALSE` on the connection | Nothing is copied, nothing is said. The window is read from the bucket. |
  | The secondary holds the current version | Nothing is copied. The window is read from the local copy. |
  | The dataset is primary-only (Part C) and the secondary lacks it | Nothing is copied, whatever the size. The window is read from the bucket. One line says so. |

  A user who wants a raster to stay in the bucket whatever its size writes it with `locations = "primary"` (Part C). Tests: B-T14 (a raster is copied), B-T18 (the table above, on a small class map), B-T19 (the same against a bucket, level `full`), C-T11 and C-T12 (primary-only class map).
- **The help of `store_read()`** says in its section "Rasters" that "the file is not downloaded". After Part B that is false for the first case of the table. WP5b corrects it.

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh Opus session) runs **no code**: no R, and no Bash that builds, tests or edits. It may read files and git state (`git status`, `git diff`, `git log`, `git show --stat`). It spawns every work package as an Agent with `model: "opus"`, gives it this plan's path, its WP name and the "Results" facts, checks each report against the acceptance criteria, ticks the steps, and fills in "Results" and "Outcome". It edits only this plan file.
- **TDD cycle per part.** (1) A **test writer** adds tests only, with no change under `R/`. (2) A **red verifier** confirms in a fresh session that each new test fails for the reason stated, and that tests marked "guard" pass already. (3) A **code writer** changes `R/` until the tests pass. It may not change a test's code; a test it believes wrong goes back to the orchestrator with the reason. (4) A **green verifier** reads the diff with no prior conclusions, runs the tests and regressions, and runs a mutation check.
- Writers and verifiers are separate agents. Verifiers never edit files. Each verifier gets the acceptance criteria and the paths, not the writer's conclusions.
- **Red tests.** Every red test has at least one assertion that is not a snapshot (`expect_message(regexp = )`, `expect_identical()`, a catalog check), because a new `expect_snapshot()` records today's output and passes. The test writer deletes any snapshot entry and any `*.new.md` its red run created.
- **Snapshots.** The code writer (green) may run `testthat::snapshot_accept()` for new snapshots and for existing ones whose recorded code line or hint text changed because of this plan. The green verifier reads the whole `tests/testthat/_snaps/*.md` diff against the decisions, and checks that no `*.new.md` remains.
- **Existing tests whose expectations change** are edited by the test writer of that part, in the smallest way, so that the test keeps checking what it checked before. Allowed edits in Parts A and B, and no others:
  - add `all = TRUE` or `datasets = "<name>"` to a `store_sync()` call;
  - add `copy = FALSE` to a `store_read()` call, or `st$copy_on_read <- FALSE` after a fixture (the fixtures use `new_store()`, which gets the default `TRUE`);
  - `test-sync.R:422`: add `"skipped"`, `"skipped_files"`, `"skipped_bytes"` after `"conflicts"` in the expected names;
  - `test-objects.R:43`: add `"copy_on_read"` to the expected fields;
  - `test-connect.R:324`: add `copy_on_read` to the expected formals of `store_connect()`.
  Never delete an expectation. A test edited only with `st$copy_on_read <- FALSE` or `datasets = ` still passes in the red phase. The other edited tests are **expected to fail** in the red phase, for these reasons only: `unused argument (all = TRUE)`; for `copy = FALSE`, the simple error `filter expressions must be either an expression or a list of expressions`; for the three value changes, the missing name. They must pass at the green step. The allowed edits of Part C are those WP9 lists (see WP10).
- **Routing on FAIL.** A verifier's FAIL goes to a fresh writer of the same kind with the verifier's findings and the diff (do not try to resume the old agent), then to a fresh verifier. A regression failure in a test nobody edited, found at a green step, goes to a test writer of that part (allowed edits above), then the red verifier's check of that edit, then back. After the second FAIL of the same WP, the orchestrator stops and asks the owner. A writer that stopped mid-WP leaves its partial diff in place: a fresh writer of the same WP continues from `git diff`; nothing is reverted.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report of an agent that ran R ends with `session closed`. If one does not, the orchestrator sends a small agent to `quit()` that session.
- **Running tests.** `devtools::load_all()` then `testthat::test_local(filter = "<one filter>")`, in the agent's own R session or in a `callr::r_bg()` process started from it; this runs at test level `default` (checked). Which filters: "Test scope" below. Known times: `^sync$` about 150 s, `crash-points` about 85 s. Tests that use counters set `withr::local_options(rcs.trace = TRUE)`.
- **Mutation checks** are done in the R session only, never by editing files: mock with `testthat::local_mocked_bindings()` or `assignInNamespace()`, then run the test file with `testthat::test_local(filter = "...", load_package = "none")`, because the default reloads the package and undoes the mutation.
- Tests use only data from `rcs_sim_*()` or small frames and rasters built in code from it. Every location goes under `withr::local_tempdir()`. Raster tests start with `skip_if_not_installed("terra")`.
- R style: `r-lib:r-testthat`, `r-lib:r-cli`, `r-lib:r-tidyverse-style`. Messages use cli only, with the classes of the surrounding code. Internal helpers get the comment / `@noRd` block the file already uses.
- **No full benchmark.** Efficiency is shown by WP6 only.
- **Two releases.** WP8 releases Parts A and B as `0.0.0.9007`; WP13 releases Part C as `0.0.0.9008`. Between the two the status of this plan is `active`, and "Results" says "Parts A and B released as 0.0.0.9007 (`<hash>`); Part C in progress". The orchestrator writes that line, with the hash, after the WP8 commit; it travels with the Part C commit. So between the two releases this plan file is the one expected uncommitted change (ticks, "Results"); nothing else may be uncommitted. After WP8 the orchestrator reports to the owner and starts WP9 **without waiting for an answer**. Exception: when any one verification step of Parts A and B failed three times (possible only after the owner allowed a further round under the routing rule), it reports and waits for the owner's word. The status becomes `done` in WP13 only.
- **Website at each release.** The release writer rebuilds the site: from the project root, `callr::r(function() { source("pkgdown/deploy.R"); site_build() }, show = TRUE)` (the `source()` alone builds nothing there). Then it checks the changed pages (`git diff --name-only -- docs`, plus untracked files under `docs`): none may contain the local user name (`Sys.info()[["user"]]`), the home folder path, `AppData`, or a path with a `Users/<name>` or `/home/<name>` folder (search with forward and back slashes). On a hit it does not commit and reports. `docs` is committed with the release.
- **Commit.** The owner authorised on 2026-11-27 the release commits once everything is green, without a further OK. Staged by explicit paths. **No push.**

### Test scope (binding for every work package)

The owner's instruction (2026-11-27): a part is tested only on the features it changes, never on the whole package.

1. **Never the whole suite.** No `devtools::test()` and no `testthat::test_local()` without `filter = `. No `devtools::check()`, no `covr`, no script of `bench/`.
2. **Only the filters your work package names.** Each work package below lists its exact filters. One filter per run: never join filters with `|`. A filter is a regular expression on the file name; where a name is a part of another one it is anchored: `^sync$`, `^read$`, `^write$`, `^raster$`, `^intersects$` (plain `intersects` would also run `test-duckdb-intersects.R`; plain `write` would also run `test-write-duckdb.R`).
3. **A file not in the table below is not run**, in any work package. Not run at all in this plan: `duckdb` (six files), `query`, `resolve`, `history`, `check`, `files`, `backend`, `backend-gcs`, `auth`, `raster-gcs`, `geo-*`, `types`, `h3-type`, `interop`, `sim`, `trace`, `utils`, `hooks`. Reasons: `R/query.R` and `R/duckdb.R` get roxygen only, and B-T10 guards that lazy reads never copy; `R/resolve.R`, `R/raster.R`, `R/check.R`, the backends and the geo code are not changed; `test-history.R` calls neither `store_sync()` nor `store_copy()`. One exception: the row "a file on WP1's read list". If WP1 names a test to edit in `test-check.R`, `test-raster.R`, `test-write.R`, `test-intersects.R` or `test-sync.R`, that file's filter (`check`, `^raster$`, `^write$`, `^intersects$`, `^sync$`) is run by WP4c, WP4-V, WP5a and WP5-V, and by nobody else.
4. **Broad files** (`integration`, `crash-points`, `random-operations`) are run **once per part, by the green verifier of that part only**, and only where the table gives a reason. Test writers, red verifiers and code writers do not run them. Edits to tests in those files (and in `helper-model.R`) are checked by reading in the red phase and by the run in the green verification. One exception: after a FAIL in a broad file, the writer who fixes it runs that one file to confirm the fix, and the next verifier runs it again.
5. **Raster filters.** `^raster$` is run only where the raster branch of `store_read()` in `R/read.R` is touched: WP5a and WP5-V; and, for WP4c and WP4-V, only under the exception of rule 3. `R/raster.R` is not changed by this plan.
6. **Bucket runs (level `full`).** One run per part at level `full`, by the green verifier, of the one file named in the table; the mutation runs of that file are extra and at level `default`. Set in the agent's own process only, never in a file: `RCS_TEST_GCS = "gs://rcs-test"` and `RCS_TEST_LEVEL = "full"` (for example `withr::with_envvar()` around the one `test_local()` call). Tests write only under their own `rcs-test-<id>/` prefix and remove it; the owner's `demo/` is never touched; the verifier lists the bucket afterwards and reports that only `demo/` is left. Every other run is at level `default`. If the bucket cannot be reached, the verifier reports it and the orchestrator asks the owner.
7. **A failing test outside your listed files is not investigated by running more files.** Report it, with the first lines of the failure.
8. **`options(rcs.quiet = TRUE)` must not be left set** in a session that runs tests: it changes message snapshots and creates `_snaps/*.new.md`. Check `getOption("rcs.quiet")` is `NULL` before a run; delete any `*.new.md` a run created and say so.

Feature → test files:

| Part | Filter (file) | Why it is run | Who runs it |
|---|---|---|---|
| A, sync | `^sync$` (`test-sync.R`) | New tests A-T1–A-T10, A-T13; the existing `store_sync()` tests, edited | WP2, WP2-V, WP3, WP3-V |
| A | `connect` | A-T11 (empty-secondary notice); the connect snapshots | WP2, WP2-V, WP3, WP3-V |
| A | `^write$` | A-T12; the three hints in `_snaps/write.md` (D-A7) | WP2, WP2-V, WP3, WP3-V |
| A | `catalog` | `test-catalog.R:493` syncs an old-format location with `store_sync(st)` (edited) | WP2, WP2-V, WP3, WP3-V |
| A, broad | `integration` | 9 `store_sync()` calls that rely on a plain sync completing secondaries (edited) | WP3-V, once |
| A, broad | `crash-points` | The `store_sync()` crash matrix and the "sync" repair step (`helper-model.R:289`, edited) | WP3-V, once |
| A, broad | `random-operations` | The model's sync operation (`helper-model.R:369, 458`, edited) | WP3-V, once |
| A, bucket | `^sync$` at level `full` | Part A changes no backend call. But `test-sync.R:473` shares its body with local tests this part edits, and would otherwise never run after the edit | WP3-V, once (this run replaces its default-level run of `^sync$`) |
| B, copy on read | `copy-on-read` (new `test-copy-on-read.R`) | Every new test of Part B | WP4a, WP4b, WP4-V, WP5a, WP5b, WP5-V, WP8 |
| B | `^read$` | `store_read()` is changed; edited tests; the class-map reads there go through the raster branch | WP4c, WP4-V, WP5a, WP5b, WP5-V, WP8 |
| B | `objects`, `connect` | `copy_on_read` field and argument (edited expectations) | WP4c, WP4-V, WP5a, WP5-V |
| B | `^sync$` | `store_copy()` is refactored into `copy_unit()`; its tests and snapshots must not change | WP5a, WP5-V, WP8 |
| B | `^raster$` | The raster-argument checks of `store_read()` move (D-B9); `test-raster.R` reads class maps through `store_read()` | WP5a, WP5-V |
| B | `^intersects$` | `store_read(intersects = )` runs through the reordered body of `store_read()` | WP5a, WP5-V |
| B | a file on WP1's read list other than the above | Only if WP1 names a test in it that needs `copy = FALSE` or `st$copy_on_read <- FALSE`. The orchestrator adds the row in "Results" before WP4c. A broad file among them follows rule 4 | WP4c, WP4-V, WP5a, WP5-V |
| B, broad | `integration` | `store_read()` and `store_copy()` through the public functions with three local folders: the guard that a local primary copies nothing | WP5-V, once |
| B, broad | `random-operations` | The model's copy operation (`helper-model.R:452`) runs the refactored `store_copy()` | WP5-V, once |
| B, bucket | `copy-on-read` at level `full` | Part B adds no backend call, but its real case is a bucket primary, which the default-level tests only fake (B-T19) | WP5-V, once (replaces its default-level run of `copy-on-read`) |
| C, primary-only | `primary-only` (new `test-primary-only.R`) | Every new test of Part C | WP10, WP10-V, WP11, WP11-V, WP13 |
| C | `^write$` | `store_write()` gets `locations`; result rows, lines and footer change | WP10, WP10-V, WP11, WP11-V, WP13 |
| C | `inspect` | Status vocabulary, print symbols and legend line, `store_describe()` | WP10, WP10-V, WP11, WP11-V, WP13 |
| C | `^sync$` | `sync_scope()` and the "not copied" block (D-C5) | WP10, WP10-V, WP11, WP11-V |
| C | `copy-on-read` | The copy-on-read gate (D-C6); the helpers moved to a helper file (WP10) | WP10, WP10-V, WP11, WP11-V |
| C | `connect` | The empty-secondary notice (D-C8) | WP10, WP10-V, WP11, WP11-V |
| C | `schema`, `catalog` | The new optional catalog column; catalogs written before it | WP10, WP10-V, WP11, WP11-V |
| C | `^read$` | The gate runs in every `store_read()` | WP11, WP11-V |
| C, broad | `integration` | Asserts that every secondary receives every write; the loop over secondaries in `store_write()` changes | WP11-V, once |
| C, broad | `crash-points` | The `store_write()` crash matrix runs through the changed loop | WP11-V, once |
| C, broad | `random-operations` | The invariants (`helper-invariants.R`) and the model after the status and write changes | WP11-V, once |
| C, bucket | `primary-only` at level `full` | Part C changes no backend call; one test (C-T12) shows the real case: a class map kept in a bucket, read as a window through `/vsigs/` | WP11-V, once (replaces its default-level run of `primary-only`) |

Cut from the earlier text of this plan, with the reason: `history` and `inspect` in Part A (no `store_sync()` call in them; `R/inspect.R` gets roxygen only); `resolve`, `query`, `duckdb`, `history`, `crash-points`, `check` in Part B (rule 3; `test-crash-points.R` runs no `store_copy()` and reads through primary-only connections); `integration`, `crash-points`, `random-operations` in every writer and red-verifier step (rule 4). Cut from the work packages moved into Part C: `history` and `raster` (the write pipeline changes only in the loop over secondaries; `R/raster.R` is not changed).

### Parallel schedule

Code writers never run in parallel. At most 3 R sessions at once. Tasks that write the same file never run together.

| Stage | Runs | Waits for |
|---|---|---|
| 1 | WP1 (survey) | WP0 |
| 2 | WP2 (tests A) | WP1 |
| 3 | WP2-V | WP2 |
| 4 | WP3 (code A) ∥ WP4a then WP4b (tests B: the new file `test-copy-on-read.R` only) | WP2-V |
| 5 | WP3-V (WP4b may still run) | WP3 |
| 6 | WP4c (edits to existing tests for B) | WP3-V |
| 7 | WP4-V | WP4b, WP4c |
| 8 | WP5a then WP5b (code B) | WP4-V |
| 9 | WP5-V | WP5b |
| 10 | WP6 (efficiency) ∥ WP7 then WP7-V (docs A and B) | WP5-V |
| 11 | WP8 (release `0.0.0.9007`) | WP6, WP7-V |
| 12 | WP9 (survey C) | WP8 |
| 13 | WP10 (tests C) | WP9 |
| 14 | WP10-V | WP10 |
| 15 | WP11 (code C) | WP10-V |
| 16 | WP11-V | WP11 |
| 17 | WP12 then WP12-V (docs C) | WP11-V |
| 18 | WP13 (release `0.0.0.9008`) | WP12-V |

WP4a and WP4b may run while WP3 and WP3-V run because they write only `test-copy-on-read.R` (their helpers stay at the top of that file: a half-written `helper-*.R` would break every other run), run only the filter `copy-on-read`, and their test setups fill secondaries with `store_copy()`, never `store_sync()`. While WP3 edits `R/`, a `devtools::load_all()` of WP4a or WP4b may fail: they wait and retry, and never touch `R/`. WP3 accepts snapshots per file (`snapshot_accept("sync")`, `"connect"`, `"write"`), never all at once, so it cannot accept an entry of `copy-on-read`. Nothing in Part C runs in parallel.

### Decisions taken (do not ask the owner about these)

Part A, `store_sync()`:

- **D-A1. New argument `all = FALSE`**, placed after `datasets`. `TRUE` restores today's behaviour (every dataset of the source to every target). `all = TRUE` together with non-`NULL` `datasets` aborts with `rcs_error_argument`. `all` must be a flag (`check_flag()`).
- **D-A2. Default scope per target.** With `datasets = NULL` and `all = FALSE`, a target that is a **secondary** receives only the units whose dataset has an entry in its held catalog, at any version (an index-table entry alone does not count). A target that is the **primary** (`identical(target$uri, st$primary$uri)`) receives every unit. The rule is one internal function in `R/sync.R`, `sync_scope(st, target, units, restrict, all)` (`restrict` as in `sync_plan()`: `NULL` unless `datasets` was given), returning `list(keep = <units>, skip = <units>)`; with `all = TRUE`, or `restrict` not `NULL`, `skip` is empty. `sync_plan()` gets a new last argument `all` (`sync_plan(st, source, target, units, restrict, delete, force, all)`), calls `sync_scope()` first, plans only `keep`, and returns `skipped` (the `skip` units) beside its other fields. `delete = TRUE`, `force` and conflicts are unchanged (deletions come from the catalogs, not from units; a conflict needs the target to hold the dataset). A held dataset is still refreshed whenever `unit_needed()` says so: at another version, or at the same version with another entry (a raster's legend or colours).
- **D-A3. What was not copied.** One internal function in `R/sync.R`, `files_lacking(units, target)`: input a list of units and a target location; output `list(files = <integer>, bytes = <numeric>)`, the files of those units (index tables included) whose path + MD5 is not in the target's **held files table**. It uses no history and makes **no backend call**; the figure is an upper bound of what a full sync would send. The result tibble gets three columns after `conflicts`: `skipped` (list of dataset names), `skipped_files` (integer) and `skipped_bytes` (numeric). `files`/`bytes` keep their meaning (files sent). Targets that got no plan (unavailable, or behind at refresh) have `character()`, `0L`, `0` and no message line; a target whose landing fails still reports what was skipped.
- **D-A4. Messages.**
  - Header: with `datasets = NULL`, `all = FALSE` and at least one secondary target, `sync_header()` does not print the count of every source dataset; the full sentence is `Syncing the datasets already held by each secondary location, from the {role} <uri> to {k} {noun}.` (today: `Syncing {n} dataset{?s} from the {role} <uri> to {k} {noun}.`; `{noun}` from `target_noun()` as today). A-T2 matches "Syncing the datasets already held by each secondary location". Otherwise the header is unchanged.
  - Block: emitted by `store_sync()` itself, after the per-target lines and before `sync_footer()`, for dry runs too, with the same wording, through `rcs_inform()`, when any secondary skipped datasets:

    ```
    ℹ Synced only the datasets already in each secondary location.
    ℹ <secondary uri>: 41 datasets not copied (1,204 files, 86.3 GB).
    ℹ <empty secondary uri> is empty: 41 datasets not copied (1,204 files, 86.3 GB).
      Use `store_sync(st, all = TRUE)` to copy every dataset, or `datasets = ` to copy some.
    ```

    One `<uri>` line per secondary that skipped something; the "is empty" form when its held catalog has no dataset. Counts with `format_count()`, size with `format_bytes()`. No block when nothing was skipped.
  - Footer: "Every secondary location is up to date." is not printed when any target skipped datasets.
- **D-A5. Status.** A target whose only difference from the source is skipped datasets has status `"same"`.
- **D-A6. Empty secondary at connection.** `store_connect()` informs, once per available secondary whose catalog holds no dataset while the primary holds at least one (through `rcs_inform()`):

  ```
  ℹ Secondary <uri> is empty.
    Use `store_sync(st, all = TRUE)` to copy every dataset, or `store_sync(st, datasets = )` to copy some.
  ```

  `store_refresh()` does not repeat it.
- **D-A7. Hints after a write that missed a secondary.** A failed create leaves the secondary without the dataset, so a default sync no longer repairs it. The three messages keep their first sentence and their class, and their hint becomes (with the dataset's name where the function has it, per WP1; else `datasets = ` without a value):
  - `write_refresh()` (`R/write.R:697`): ``Once it can be reached, run `store_sync(st, datasets = "<name>")`, or `store_sync(st, all = TRUE)` for every dataset.``
  - `land_secondary()` (`R/write.R:1899`): ``Run `store_sync(st, datasets = "<name>")` to bring it up to date, or `store_sync(st, all = TRUE)` for every dataset.``
  - `write_footer()` (`R/write.R:2004`): ``{n} secondary location{?s} {?is/are} behind; run `store_sync(st, datasets = "<name>")` to bring {?it/them} up to date, or `store_sync(st, all = TRUE)` for every dataset.``

  The roxygen at `R/write.R:329-331` and `R/inspect.R:119-120` says the same. Writes themselves are unchanged: a new dataset is written to every available location.
- **D-A8. Manifests only for what is copied.** `store_sync()` writes fresh manifests only for units that some target's plan copies (plan the targets first, or write them per target, cached), not for every unit of the source.

Part B, copy on read:

- **D-B1. Where copies go.** Only to secondaries the read will then use: **available**, with a local backend, while the primary's backend is not local (the same `backend$type` test as `choose_location()`), and lacking the dataset or holding an **older** version, or lacking its index table (the semantics of `unit_needed()`, `R/sync.R:331`). "Older": the secondary's entry has another version and its `updated` is not later than the primary's. The same version with another entry: D-B13. A secondary whose version was updated later than the primary's is never overwritten by a read: it is skipped with the message of D-B7. With a local primary, or only cloud secondaries, a read copies nothing and prints nothing; this holds for `copy = TRUE` too, which then informs ``No secondary location to copy to. Use `store_sync(st, datasets = "<name>")`.`` All targets of one read share one unit, one staging folder and one `write_context()` (as `sync_location()` does), so files are downloaded once.
- **D-B2. When `store_read()` copies.** Only when all hold: the read is of the current version (`version` is `NULL` or equals the primary's version); the connection's `copy_on_read` is `TRUE`; the call's `copy` is not `FALSE`; at least one secondary needs the copy (D-B1); and the bytes to download do not exceed the limit (D-B3), unless `copy = TRUE`. Filters, `columns` and `intersects` do not change the rule. Raster datasets follow the same rule: a windowed read (`intersects = `) of a raster at or under the limit copies the whole file first ("What plan 0006 changed").
- **D-B3. Limit.** New option `rcs.copy_on_read_max_bytes`, default `2e9`. The bytes measured are those of `files_lacking()` (D-A3) for the unit, taken for the target that lacks the most. Above the limit: no copy to any target.
- **D-B4. New argument `store_read(copy = NULL)`**, placed after `version`. `NULL` follows D-B2. `TRUE` copies regardless of the limit, the connection setting and the version (old versions: D-B6). `FALSE` never copies and prints no hint. Anything else aborts with `rcs_error_argument`.
- **D-B5. New argument `store_connect(copy_on_read = TRUE)`**, the last argument of `store_connect()`, a flag (`check_flag()`), stored as `st$copy_on_read`. `new_store()` gets `copy_on_read = TRUE` as a default argument, so its other callers keep working; `validate_store()` checks it; the field table documents it. `store_refresh()` keeps it. When `FALSE`, reads neither copy nor print a hint (unless `copy = TRUE`).
- **D-B6. Old versions.** `store_read(version = <old>)` never copies by default. When `copy` is `NULL`, `copy_on_read` is `TRUE`, at least one secondary passes the D-B1 backend test, and the read is served by the primary, it informs, right after `read_target()` returns and before the data are read (one place, before the raster branch):

  ```
  ℹ Read version 3f9a1c0d2b4e5f60 of "sales/daily" from <uri>; old versions are not copied to secondary locations.
    Use `copy = TRUE` to copy it.
  ```

  With `copy = TRUE`, before the read: the source is the location `choose_location()` would read the version from; each other D-B1-eligible secondary (available, local, primary not local) whose current entry is not that version and whose `_history.parquet` lacks the version's rows (one `history_read()` per target; allowed here) receives it through a new internal function in `R/sync.R`, `land_history(st, source, target, dataset, version, ctx)`:
  - uploads the version's files with `upload_verified()`, the context's source being `source`;
  - copies the version's manifest **unchanged**, keeping its original `written` (a new `written` would make `store_rebuild()` turn it into the current version);
  - under `write_guard()`, appends the source's history rows of that version, with their `replaced` values unchanged, by `location_write(target, target$catalog, target$files, <history>)`.

  The secondary's current entry is unchanged, **whether or not it holds the dataset** (checked: invariants, `store_check()`, `store_prune()` and old-version reads all work in both cases). Known and documented in `store_read()`'s roxygen: `store_rebuild()` of a secondary that holds only an old version of a dataset makes that version its current entry. Messages as D-B7's copy lines, with "to the history of <secondary>". With `copy = TRUE` and no D-B1-eligible secondary it informs `No secondary location to copy to.` (without the `store_sync()` hint, which does not copy old versions; plan writer's default, 2026-11-27). Failures follow D-B8.
- **D-B7. Messages** (all through `rcs_inform()`; texts are snapshotted, close to these):
  - Copy: `ℹ Copying "sales/daily" (version <v>, 12 files, 340 MB) from <primary> to <secondary> before reading.` (the files and bytes to send, from `files_lacking()`) then the progress bar of `upload_verified()`, then `✔ 12/12 files sent (340 MB) in 4.2s, MD5 verified.` The `Reading "sales/daily" from secondary <uri>.` line follows from `choose_location()` inside `read_target()` and prints **once** per read: `copy_before_read()` never prints it (where it needs the source of an old version it finds it without that message). `store_copy()`'s own messages and snapshots do not change: the shared helper returns the figures and each caller prints its own lines.
  - Above the limit: ``ℹ "sales/daily" needs 3.4 GB, above the 2.0 GB limit for copying on read (`rcs.copy_on_read_max_bytes`). Reading from <primary>.`` then ``Use `copy = TRUE`, or `store_sync(st, datasets = "sales/daily")`, to copy it.``
  - Newer secondary skipped: ``! <secondary> holds a newer version of "sales/daily"; it is not replaced. See `store_sync()`.`` (inform, not warn).
  - Entry only (D-B13): `ℹ Updating the catalog entry of "grids/cover" in <secondary> to the primary's (version <v>, no file sent).`
- **D-B8. Failure of the copy.** For each target, the refresh of that target and the landing are inside one caught region. A write-class error (`write_error_classes`) does not fail the read: a warning of class `rcs_warning_secondary_behind` says the copy to `<secondary>` failed, that the next read retries, and names ``store_sync(st, datasets = "<name>")`` and `copy_on_read = FALSE`; the read goes on from the primary. The same holds when the refresh of the primary fails with a write-class error: one warning, no copy at all. Errors of other classes propagate. A failure after the catalog switch is handled with `landed_anyway()`. Nothing is remembered between reads: a failing secondary warns on every read.
- **D-B9. Order inside `store_read()`.** `store_read()` itself calls the copy step, `copy_before_read(st, name, version, copy, call)`, after its argument checks and just before `read_target()`; the read then comes from the fresh copy through the existing `choose_location()` order. `copy_before_read()` first resolves `name` and checks `version` with the same helpers `read_target()` uses (`R/read.R:22-29`), so a bad name or version aborts with today's error before anything is copied. The raster-argument checks (`R/read.R:215-230`) move before the copy step **for a read of the current version**, where they need only the kind in the primary's catalog entry. For an old version they stay after `read_target()`, on the entry of that version's manifest, because `mode = "replace"` may change a dataset's kind (corrected 2026-11-27); such a read copies only with `copy = TRUE` (D-B6). The checks are one internal function in `R/read.R`, `check_raster_read_args(dataset, given, call)`, called from both places, not two copies; `given` is the character vector of the arguments given, built in `store_read()` itself, because `missing()` works only there (the results of `missing(geometry)` and `missing(exact)` are passed in, not re-evaluated). The `columns` and `intersects` checks stay where they are. `read_target()` is unchanged; `raster_open()` is unchanged; `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` are unchanged.
- **D-B10. Catalog freshness.** The copy step decides from the catalogs held by the connection (no backend call when nothing is needed). When a copy is needed, it refreshes the primary and each target, then **repeats the D-B1–D-B3 and D-B13 decision once on the refreshed catalogs** before landing (a target that became newer is skipped; if the primary's current version changed and `version` named the previous one, the read is an old-version read and nothing is copied). `land_location()` updates the held catalogs, so `st` is current afterwards.
- **D-B11. No eligible secondary.** With no secondary, or none passing D-B1's backend test, nothing changes from today: no message, no write anywhere.
- **D-B12. Index tables.** A read whose `name` is an index table never copies.
- **D-B13. Same version, another entry (orchestrator's default, 2026-11-27: keep the secondaries equal to the primary).** A raster written again with the same cells and another legend or other colours keeps its version and changes only its catalog entry. A D-B1-eligible secondary whose entry of the dataset has the primary's version but is not the primary's entry (`holds_entry()` is `FALSE`; this is what `unit_needed()` tests) needs the copy when its `updated` is not later than the primary's. The copy sends no data file: the manifest and the catalogs only, through the same `copy_unit()`. `files_lacking()` gives 0 bytes, so the limit never stops it. The message is the "entry only" line of D-B7, not the copy lines. When the secondary's `updated` is later than the primary's, it is left as it is and nothing is printed (the data are the same; `store_sync()` aligns the entries). The other conditions of D-B2 apply (current version, `copy_on_read`, `copy`). A secondary whose entry equals the primary's costs nothing: the comparison uses the held catalogs.

Part C, primary-only writes:

- **D-C1. New argument `store_write(locations = NULL)`**, placed after `gdal`. `"primary"`: write to the primary only. `"all"`: write to every location. `NULL`: keep the dataset's stored setting; `"all"` for a new dataset. Anything else aborts with `rcs_error_argument`. It applies to every kind of dataset and to every mode. With no secondary in the connection it is still recorded. `store_write()` already has a local variable `locations` (`R/write.R:590`, `store_locations(st)`): the code writer renames that local.
- **D-C2. New optional catalog column `primary_only`** (`arrow::boolean()`, after `partition_auto`), added the way `partition_auto` was: `catalog_schema()`, `schema_optional$catalog`, `entry_omitted_when_na`, and `new_entry()` (argument `primary_only = NA`). `TRUE` for a primary-only dataset, `NA` otherwise (never `FALSE`), so that the manifests of all other datasets keep their bytes and their catalog rows keep their values (the catalog file itself gains the all-`NA` column at its next write, through `schema_as_arrow()`, as it did for `partition_auto`). The index table of a geospatial dataset carries the same value. `locations = "all"` on a primary-only dataset sets it back to `NA` and writes everywhere.
  - **Not in the data files.** `primary_only` joins `entry_not_embedded` (`R/schema.R`), like `history`: where a dataset is kept does not change its files, its MD5s or its version. Switching `locations` for unchanged data is "a change of the entry only" in `resolve_target()`: no file is sent.
  - **One place sets it.** `store_write()` resolves the setting after `check_write_mode()` through one internal function in `R/write.R`, `resolve_primary_only(locations, existing, call)`, which checks `locations` (D-C1) and returns `TRUE` or `NA` (`existing[["primary_only"]]` when `locations` is `NULL`; `NA` for a new dataset). One internal function in `R/write.R`, `plan_primary_only(plan, value, now)`, called right after staging and before `resolve_target()`, sets the value on `plan$data$entry` and on `plan$index$entry` and writes their local manifests again (`new_manifest(entry, files, written = now)` to the same `manifest_local`). The stage functions and the entry builders (`files_stage()`, `raster_stage()`, the DuckDB paths) are **not** changed. If WP9 finds a stage path where this cannot work, it names the smallest change and the orchestrator records it in "Results" before WP10.
  - `store_rebuild()` takes the flag from the manifest; a dataset rebuilt from the metadata in its files (no manifest) has `NA`.
- **D-C3. Writing.** With the setting resolved to primary-only, the secondaries are not landed and **not contacted at all** (plan writer's default, 2026-11-27): `store_write()` refreshes the primary first, resolves the setting, and refreshes the secondaries only when the write is not primary-only (`write_refresh()` is split or gets an argument for it). So an unreachable secondary raises no "is skipped" warning during a primary-only write. Each secondary gets a result row with status `"primary only"`, `files` `NA`, `uploaded` 0, `bytes` 0, whether or not it is available. `write_line()` prints `kept in the primary only` for it (bullet `i`); `write_footer()` counts it neither as written nor as behind. A secondary that already holds the dataset is left as it is; one `rcs_inform()` message per write names all of them, judged from the catalogs the connection holds: ``ℹ <secondary uri 1>, <secondary uri 2> hold{?s} "<name>" and {?is/are} not updated by this primary-only write.`` then ``Use `store_sync(st, datasets = "<name>")` to update {?it/them}.``
- **D-C4. Status.** In `location_status()`, a dataset the target lacks whose source entry has `primary_only` `TRUE` has status `"primary only"` instead of `"missing"`, when the target is a secondary (`location_status(source, location, target_is_secondary = TRUE)`; `store_status()` passes `FALSE` when the location compared is the primary; a primary that lacks a dataset of the source is `"missing"` as before). A target that holds it is compared as any other (`"same"` / `"differs"`). `store_status()`, `store_datasets()`, the print of a connection and the print of `store_describe()` use the new value. Its symbol in the prints is `P` (plan writer's default, 2026-11-27; with and without UTF-8), added to `status_symbols()`. The legend line gains `, P primary only` between `missing` and `? unavailable` ("Secondary copies: = same, ≠ differs, – missing, P primary only, ? unavailable.") **only when the store holds a primary-only dataset**, so the existing snapshots keep their bytes. Any count of missing datasets no longer includes them. `store_check()` is unchanged (it reports `"missing"` for a location that does not hold the dataset).
- **D-C5. Sync.** `store_sync(all = TRUE)` does not copy a primary-only dataset to a secondary that lacks it. `sync_scope()` puts such a unit in `skip` also with `all = TRUE` (never when `restrict` is not `NULL`) and returns their names as a third element, `primary_only`. They are listed in `skipped` and counted in `skipped_files` / `skipped_bytes` (D-A3). In the block of D-A4 they get a line of their own and are left out of the other counts:

  ```
  ℹ <secondary uri>: 2 primary-only datasets not copied (2 files, 1.6 GB).
    Use `store_sync(st, datasets = )` to copy them.
  ```

  The hint "Use `store_sync(st, all = TRUE)` …" is printed only when ordinary datasets were skipped. "Every secondary location is up to date." is printed when the only skipped datasets are primary-only ones. `store_sync(datasets = "<name>")` and `store_copy()` copy a primary-only dataset; the flag travels with the entry. The default sync (D-A2) needs no change: it never copies a dataset a secondary lacks, and refreshes one it holds. A sync to the primary (`from = <secondary>`) sends everything, as before.
- **D-C6. Copy on read.** `store_read()` does not copy a primary-only dataset to a secondary that lacks it, whatever its size (D-B2 gains this condition; the check is in `copy_before_read()`, before the limit). It reads from the primary and informs, one line per read (through `rcs_inform()`; none with `copy = FALSE` or `copy_on_read = FALSE`, as D-B4 and D-B5 say): ``ℹ "<name>" is kept in the primary only; reading from <primary uri>.`` then ``Use `copy = TRUE` to copy it.`` `copy = TRUE` copies. A secondary that holds the dataset is treated as for any dataset: an older version is refreshed (D-B1), another entry of the same version too (D-B13). With a local primary or no eligible secondary nothing is printed (D-B11). For a raster this means: every read, whole or windowed, goes to the bucket through `/vsigs/`.
- **D-C7. Version `0.0.0.9008`**, in its own commit (WP13).
- **D-C8. The notices of Part A.** The empty-secondary notice of `store_connect()` (D-A6) counts only the primary's datasets that are not primary-only: a primary that holds nothing else prints no notice. (New in this plan; follows from D-C5: `all = TRUE` would copy nothing.)

- **D-V. Versions.** `0.0.0.9007` for Parts A and B (WP8); `0.0.0.9008` for Part C (WP13). There is no NEWS.md; do not create one.

## Steps

### WP0. Preflight (orchestrator, no code)

- [ ] `git merge-base --is-ancestor 6953970 HEAD` succeeds (the releases of plan 0006, parts A and C, are in the history) and `DESCRIPTION` says `0.0.0.9006`. Otherwise stop and report to the owner. The line numbers in "Context" were checked at `0b47207`; if `git diff --stat 0b47207 HEAD -- R/` is not empty, they may have moved: find each function by name.
- [ ] `git status` is clean (the revised plan is committed). Otherwise ask the owner.
- [ ] Set this plan's status to `active`.

### WP1. Survey (investigator, Opus, may run R; no edits to the repo)

Scripts go in the agent's scratchpad. The facts in "Results" are already established; do not redo them. Tests run: none (scratch scripts only; "Test scope").

- [ ] **Sync-dependent tests.** List every test (file, line, `test_that` name) whose expectations rely on `store_sync()` copying datasets a secondary does not hold, in `test-sync.R` (the shared bodies `s_check_delete()` and `s_check_offline()`, used by the bucket test at line 473, included), `test-integration.R`, `test-crash-points.R`, `test-catalog.R`, `helper-model.R`. For each, the edit that keeps its meaning: `datasets = "<name>"` where the test is about repairing one dataset (for example `test-sync.R:112`), else `all = TRUE`. List the existing `expect_snapshot()` calls whose code line changes.
- [ ] **Connect notice (D-A6).** List the tests that snapshot or assert the output of `store_connect()` with an empty secondary and a non-empty primary (they gain a line), in every test file. WP2 may change the files this list names, in the smallest way (plan writer's default, 2026-11-27); a file among them that is not in the Part A rows of "Test scope" is added there by the orchestrator, in "Results", for WP2, WP2-V, WP3 and WP3-V (a broad file: WP3-V only).
- [ ] **Write hints (D-A7).** For each of `write_refresh()`, `land_secondary()` and `write_footer()` (`R/write.R:697, 1899, 2004`), say whether the dataset name is in scope, and list the snapshot entries in `_snaps/write.md` (and elsewhere) that contain the old hint.
- [ ] **Read-dependent tests.** List every test that calls `store_read()` with a simulated cloud primary and a local secondary that lacks the dataset or holds an older version (known: `test-read.R:163`, last line; scan `test-read.R`, `test-write.R:274`, `test-intersects.R`, `test-sync.R`, `test-integration.R`, `test-check.R:107`, `test-raster.R:2115`). For each, the edit (`copy = FALSE` or `st$copy_on_read <- FALSE`).
- [ ] **Simulated cloud primary through a copy.** In a scratch store, set `primary$backend$type <- "gcs"` as `test-read.R:166` does, then run `store_copy()` from that primary to a local secondary and `store_refresh()`. Report whether the copy works and whether the faked `type` survives the refresh done inside `store_copy()`. If it does not survive, name the smallest test-side way to keep it (the WP4 helper will use it). Do the same once with a small raster (`rcs_sim_raster(nrow = 20, ncol = 20)`): copy it, then `store_read(intersects = <box>)` with the faked primary, and report which location's file was opened (`rcs_trace()`, counter `file_open`).
- [ ] **Same version, another entry.** In a scratch store with a local secondary: write `sim_landcover(legend = TRUE)` (source it from `tests/testthat/helper-sim.R`) to both; write the same cells with another label through a primary-only connection; `store_refresh()`. Report `store_status()` (expected `"same"`), `unit_needed()` for the secondary (expected `TRUE`), and that `store_sync(st)` sends no file and makes the secondary's entry equal to the primary's. This confirms the facts behind A-T13 and D-B13.
- [ ] **Bucket access.** With `RCS_TEST_GCS = "gs://rcs-test"` set in the agent's process only, list a prefix `rcs-test-<random>/` with `be_list()` (it is empty). Report whether the bucket answers. Write nothing there.
- [ ] Report the lists and answers, and `session closed`. The orchestrator copies them into "Results".

### Part A. Sync restricted to datasets a secondary holds

#### WP2. Red tests for Part A (test writer, Opus)

Files it may change: `tests/testthat/test-sync.R` (new tests together under a comment `# Plan 0005: sync restricted to held datasets`), `tests/testthat/test-connect.R` (A-T11), `tests/testthat/test-write.R` (A-T12), the existing tests on WP1's sync list in `test-sync.R`, `test-integration.R`, `test-crash-points.R`, `test-catalog.R`, `helper-model.R` (allowed edits only), and the test files on WP1's connect-notice list (the smallest edit that keeps the test's meaning: the extra line expected, or the connection made quietly). No change under `R/`.

Each `test_that()` is named by the behaviour; its comment states the expected red reason.

- [ ] **A-T1 (red).** Primary with three datasets; a secondary holding one of them at an older version. Default `store_sync()` brings that one to the primary's version and copies neither of the other two. The result has `skipped` = the two names, `skipped_files` = their file count and `skipped_bytes` = the sum of their file bytes from the primary's files table. Red: both are copied; the columns do not exist.
- [ ] **A-T2 (red).** `expect_message()` on "not copied" and on the header text of D-A4, absence of "Every secondary location is up to date", then a snapshot of the whole output with `rcs.quiet = FALSE`; and a sync where nothing was skipped prints no block. Red: no such message.
- [ ] **A-T3 (red).** `all = TRUE` copies every dataset, and the resulting catalogs equal those of a second secondary filled with `store_sync(datasets = <every name>)` (versions and file sets). Red: unused argument `all`.
- [ ] **A-T4 (guard).** `datasets = "<name>"` copies that dataset to a secondary that does not hold it.
- [ ] **A-T5 (red).** `all = TRUE` with `datasets` aborts with `rcs_error_argument`; `all = NA` and `all = "yes"` abort with `rcs_error_argument` (`expect_error(class = )`). Snapshot the first message. Red: unused argument (another error class).
- [ ] **A-T6 (red + guard).** Work written on a secondary (a new dataset and an update of an existing one) and `store_sync(st, from = <secondary>)`: the primary receives both (guard); a second secondary that does not hold the new dataset does not receive it (red).
- [ ] **A-T7 (red).** Empty secondary, default sync: nothing copied, status `"same"`, `skipped` lists every dataset, the message has the "is empty" line with the full size and no "up to date" line.
- [ ] **A-T8 (red).** `dry_run = TRUE` reports the restricted plan and the skipped datasets with their size (result columns and `expect_message()`), and changes nothing on disk (the secondary's catalogs and file listing before and after).
- [ ] **A-T9 (guard).** `delete = TRUE` deletes from a secondary the datasets the source no longer holds, as before.
- [ ] **A-T10 (red).** Efficiency, with `rcs.trace = TRUE`: a default sync to a secondary that holds one dataset has the same sums of `backend_call` and `catalog_read` over all locations as `store_sync(st, datasets = "<that one>")` on an identical second store. Red: today the default copies the others.
- [ ] **A-T11 (red; `test-connect.R`).** `store_connect()` with an empty secondary and a non-empty primary informs as D-A6 (`expect_message()`, then snapshot); it does not when the secondary holds a dataset, nor when the primary is empty too; `store_refresh()` does not repeat it.
- [ ] **A-T12 (red; `test-write.R`).** A create that fails on one secondary (`local_backend_stub()`) warns with a hint containing `datasets = "<name>"` and `all = TRUE` (`expect_warning(regexp = )`); a following `store_sync(st, datasets = "<name>")` repairs it (guard part).
- [ ] **A-T13 (guard; `skip_if_not_installed("terra")`).** The same version with another legend. A class map `sim_landcover(nrow = 12, ncol = 16, legend = TRUE)` written to a primary and one secondary; then the same cells with another label (change one entry of the levels), written through a primary-only connection; `store_refresh()`. Then: the two versions are equal and `store_status()` says `"same"`; a default `store_sync()` lists the dataset in `datasets`, sends 0 files, and afterwards the secondary's catalog entry equals the primary's (`columns` and `updated`); a connection to the secondary alone reads the new label (`terra::cats()`). A second default sync copies nothing. Passes today (`unit_needed()` compares whole entries) and must still pass after WP3.
- [ ] Apply the allowed edits to the existing tests on WP1's sync list and to `test-sync.R:422`.
- [ ] Tests run, each filter in its own run: `^sync$`, `connect`, `^write$`, `catalog`. Nothing else ("Test scope": the edits in `test-integration.R`, `test-crash-points.R` and `helper-model.R` are not run here; WP3-V runs them). Report each new test red or green with the first line of its failure; each edited existing test in the four files with its failure reason (must be one of the reasons in the Rules); every other test of the four files passing. Delete snapshot entries and `*.new.md` created by the run.
- [ ] Report: test names, file and line, the red/green table, the edited tests (all files), `session closed`.

#### WP2-V. Red verification (verifier, Opus, fresh session)

Files it may change: none.

- [ ] Read only the test diff, D-A1–D-A8 and note 0003. Check that the tests encode the decisions, that every red test has a non-snapshot assertion, and that no test depends on another test's state.
- [ ] Check each edit to an existing test against WP1's list and the allowed edits; no expectation removed or weakened. The edits in `test-integration.R`, `test-crash-points.R` and `helper-model.R` are checked by reading.
- [ ] Tests run, each filter in its own run: `^sync$`, `connect`, `^write$`, `catalog`. Every red test fails for the reason in its comment; every guard passes (A-T4, A-T9, A-T13, the guard parts of A-T6 and A-T12); every edited existing test fails only for a reason in the Rules; no other failure. `git diff --stat -- R/` is empty; no `*.new.md` and no new snapshot entries.
- [ ] PASS or FAIL with reasons, then `session closed`.

#### WP3. Code for Part A (code writer, Opus)

Files it may change: `R/sync.R`, `R/connect.R` (D-A6 only), `R/write.R` and `R/inspect.R` (D-A7 only), and `tests/testthat/_snaps/*.md` through `snapshot_accept()` only.

- [ ] D-A1–D-A8, with the function names and signatures given there (`sync_scope(st, target, units, restrict, all)`, `files_lacking(units, target)`, `sync_plan(st, source, target, units, restrict, delete, force, all)` returning `skipped`). Update the roxygen of `store_sync()`: the new argument, the default scope, the three result columns, an example with `all = TRUE`. Do not run `devtools::document()` (WP8 does).
- [ ] Tests run until green, each filter in its own run: `^sync$`, `connect`, `^write$`, `catalog`. Nothing else. Accept snapshots as the Rules allow; do not change test code.
- [ ] Report: diff summary, counts per filter, the snapshot entries accepted, `session closed`.

#### WP3-V. Green verification (verifier, Opus, fresh session)

Files it may change: none.

- [ ] Read the `R/` diff with no prior conclusions against D-A1–D-A8. Look for: a backend call in `files_lacking()`; a primary target wrongly restricted; deletions changed; `dry_run` writing anything; manifests written for skipped units; a held dataset at the same version with another entry no longer refreshed; an old hint left in `R/` (read every line that `grep -n "store_sync" R/write.R R/inspect.R` returns).
- [ ] Read the `_snaps/` diff against D-A4, D-A6, D-A7.
- [ ] Tests run, each filter in its own run, reporting counts and failures verbatim:
  - `^sync$` once at level `full` with the bucket (plus the mutation runs at level `default`, below) ("Test scope", rule 6); report the result of "store_sync() in both directions works with a GCS secondary" by name, and the bucket listing afterwards;
  - `connect`, `^write$`, `catalog`;
  - the broad files, once each, at level `default`: `integration`, `crash-points`, `random-operations`.
- [ ] Mutation check (Rules), each followed by `^sync$` with `load_package = "none"` at level `default`: mock `sync_scope()` to return every unit in `keep`: A-T1, A-T6 (red part), A-T7, A-T10 must fail. Mock `files_lacking()` to return zeros: A-T1 and A-T2 must fail. Report which tests failed.
- [ ] PASS or FAIL, then `session closed`.

### Part B. Copy on read

#### WP4a. Red tests, first half (test writer, Opus; may start when WP2-V has passed)

Files it may change: new `tests/testthat/test-copy-on-read.R` only. Tests run: `copy-on-read` only.

Helper at the top of the file (not in a `helper-*.R` file: see "Parallel schedule"): `local_cor_store(secondaries = 1L, ...)` builds a primary and local secondaries under `withr::local_tempdir()`, writes the datasets through a primary-only connection, connects with `store_connect(primary, secondary = ...)` (quietly) and then simulates a cloud primary as `test-read.R:166-169` does (or as WP1 found necessary). Secondaries are pre-filled with `store_copy()` where a test needs it. Datasets from `rcs_sim_table()`, `rcs_sim_points()` / `rcs_sim_polygons()` (with an index table), `rcs_sim_raster()` and `sim_landcover()`. Messages are checked with `rcs.quiet = FALSE` and a transform that replaces temp paths, sizes and seconds. A backend stub acts only on connections made after it was started (it is installed through `be_init()`): the helper takes an argument that delays the connection, or the stub's arguments, so that every test with a stub (B-T4, B-T13, B-T15, B-T20) starts it before `store_connect()`.

- [ ] **B-T1 (red).** Empty secondary: `store_read()` returns the same data as a read through a primary-only connection; afterwards the secondary's catalog holds the dataset at the primary's version, with the same file MD5s. `expect_message()` on "Copying" and on "Reading .* from secondary", then a snapshot. Red: the secondary stays empty.
- [ ] **B-T2 (red).** The progress bar shows during the copy: with `options(cli.progress_show_after = 0)` and `testthat::local_reproducible_output(width = 300)`, `capture_messages()` of the read contains a line matching `\d+/\d+ files`. No snapshot.
- [ ] **B-T3 (red).** A second read of the same dataset copies nothing: `bytes_up` is 0, no "Copying" message, and it informs "Reading … from secondary". Red: no first copy, so the second read comes from the primary.
- [ ] **B-T4 (red).** After the dataset is updated on the primary (`mode = "update"` changing one partition, through a primary-only connection, then `store_refresh()`), the next read copies the new version and sends only the changed files: a counting stub on the secondary (`local_backend_stub(uri = <secondary>)` without `fail_at`; its `stub$log` has `generic` and `path`) gives `g_data_puts(stub)` (`helper-model.R:188`) equal to the number of changed partition files.
- [ ] **B-T5 (red).** With `options(rcs.copy_on_read_max_bytes = <below the dataset's size>)`: no copy; the data equal a read from the primary; `expect_message()` on "above the", then a snapshot (D-B7). The same with a filter and with `columns`. Red: no such message.
- [ ] **B-T6 (red).** `copy = TRUE` copies above the limit; `copy = FALSE` never copies (empty secondary) and prints nothing; `copy = "yes"` and `copy = NA` abort with `rcs_error_argument` (`expect_error(class = )`). Red: the simple error `filter expressions must be …`.
- [ ] **B-T7 (red).** `store_connect(..., copy_on_read = FALSE)`: no copy, no hint; `st$copy_on_read` is `FALSE`; `store_refresh()` keeps it; `copy = TRUE` still copies. `copy_on_read = "no"` aborts with `rcs_error_argument`. Red: unused argument.
- [ ] **B-T8 (guard + red).** No secondary: `store_read()` writes nothing outside the primary (list the temp folder before and after) and prints no copy line (guard). Local primary (no simulation) with an empty local secondary: the read copies nothing and prints nothing (guard); with `copy = TRUE` it informs "No secondary location to copy to" (red).
- [ ] Report: test names and lines, the red/green table with the first line of each failure, `session closed`.

#### WP4b. Red tests, second half (test writer, Opus; after WP4a)

Files it may change: `tests/testthat/test-copy-on-read.R` only (append). Tests run: `copy-on-read` only, at level `default`.

- [ ] **B-T9 (red).** Old version: primary with history and two versions of one dataset (written through a primary-only connection); secondary A holds the current version (`store_copy()`), secondary B holds nothing.
  - `store_read(version = <old>)` copies nothing, returns the old data, and informs as D-B6 (`expect_message()` on "old versions are not copied", then snapshot). Red: no such message.
  - With `copy = TRUE`: in A and in B the old version's files and manifest exist, the history holds the version's rows with the primary's `replaced` values, the manifest's `written` equals the primary's, and the current entry is unchanged (A: current version; B: no entry). `expect_store_valid()` holds. A following `store_read(version = <old>)` informs "Reading … from secondary". A second `copy = TRUE` adds no history rows.
- [ ] **B-T10 (guard).** `store_sample()`, `store_glimpse()`, `store_open()` (both engines; `skip_if_not_installed("duckdb")`) and `store_duckdb()` copy nothing: the secondary's catalog and file listing are unchanged. A `store_read()` of an index table by name copies nothing (D-B12).
- [ ] **B-T11 (guard).** A secondary made unavailable (as `test-sync.R:150-160`): the read succeeds from the primary, copies nothing, raises no error or warning.
- [ ] **B-T12 (red).** A secondary holding a version updated later than the primary's (written through a connection whose primary is that folder, after the primary's write): the read does not replace it, reads from the primary, and informs "holds a newer version" (`expect_message()`, then snapshot). Red: no such message.
- [ ] **B-T13 (red).** Two secondaries, both empty: one read copies to both; both catalogs hold the version; a counting stub on the primary (`local_backend_stub(uri = <primary>)` without `fail_at`) shows each data file fetched once (`be_get` rows of `stub$log` with a `part-` path: no path twice).
- [ ] **B-T14 (red).** A geospatial dataset with an index table: the secondary's catalog has the index entry after the read. A secondary that holds the dataset but not its index table receives the index. A raster dataset: copied, one data file.
- [ ] **B-T15 (red).** The copy fails: `g_no_wait()`, then `local_backend_stub(uri = <secondary>, generic = "be_put", path = "part-", fail_at = 1:3)`, started before `store_connect()` so that the secondary's backend is the stub (every upload is tried three times by `with_retry()`; one failure is absorbed; same pattern as `test-write.R:1298`). The read returns the data from the primary, a warning of class `rcs_warning_secondary_behind` mentions `datasets = "<name>"`, and the secondary's catalog is unchanged. A non-write error (mock `land_location()` with `local_mocked_bindings()` to raise a plain `rlang::abort()` with class `"other_error"`) propagates. Red: no copy is attempted, so no warning.
- [ ] **B-T16 (red until `copy` exists, then the efficiency guard).** With `rcs.trace = TRUE` and the secondary already current: `store_read()` and `store_read(copy = FALSE)` have the same `backend_call` and `catalog_read` counts and `bytes_up` 0.
- [ ] **B-T17 (guard for D-B9; passes today because nothing copies yet).** Empty secondary: a `store_read()` that the raster-argument check refuses (`R/read.R:215-230`: `columns = ` or a filter on a raster dataset aborts with `rcs_error_argument`) aborts and the secondary is still empty; the same for an unknown dataset name and for a malformed `version` with `copy = TRUE`.
- [ ] **B-T18 (red; `skip_if_not_installed("terra")`).** A windowed read of a raster, on a class map `sim_landcover(file = <temp file>, legend = TRUE, colors = TRUE)` written with `nodata = 0` through a primary-only connection, and a box inside it. The reference is the window read through the primary-only connection.
  - (a) Empty secondary, default limit: `store_read(st, "grids/cover", intersects = box)` first copies the whole file (the secondary's catalog holds the primary's version; its one data file has the primary's MD5; `expect_message()` on "Copying"), then reads the window from the local copy ("Reading … from secondary"; with `rcs.trace = TRUE` the `file_open` of the read has the secondary's `location`). The window has fewer cells than the map, equals the reference (values as codes), and carries the legend (`terra::cats()`) and the colours (`terra::coltab()`). Red: the secondary stays empty.
  - (b) A fresh store, `options(rcs.copy_on_read_max_bytes = <below the file's size>)`: nothing is copied (the secondary's folder holds no `.tif`), the window equals the reference with legend and colours, the `file_open` has the primary's `location`, and `expect_message()` on "above the". Red: no such message.
  - (c) A fresh store, `copy = FALSE`: nothing is copied and no copy line is printed; the window equals the reference (guard).
- [ ] **B-T19 (red; level `full`, bucket; written here, first run by WP5-V).** Add at the top of the file `local_test_bucket()`, a copy of `local_raster_bucket()` (`test-raster-gcs.R:11-50`, which stays as it is): it skips below level `full`, without `RCS_TEST_GCS`, without Arrow's GCS support or terra; it works under a random prefix `rcs-test-<random>/`, removes it at the end and fails if anything is left. The test: a store created in the bucket prefix as primary, a local folder as secondary; a small table and the class map of B-T18 written through a primary-only connection. Then, through `store_connect(<bucket>, secondary = <folder>)`: `store_read()` of the table copies it (the secondary's catalog holds the version) and returns the same rows; a windowed read of the class map with `options(rcs.copy_on_read_max_bytes = 1)` copies nothing, has one `file_open` at the bucket's `location`, no `be_get` of a `.tif`, and returns the window with legend and colours; the same read with the default limit copies the file and reads the window from the local folder.
- [ ] **B-T20 (red; `skip_if_not_installed("terra")`).** The same version with another entry (D-B13). Setup as A-T13, with the simulated cloud primary: the secondary holds the class map at the primary's version with the older label. `store_read(st, "grids/cover")`: returns the new label; `expect_message()` on "Updating the catalog entry", no "Copying" line; a counting stub on the secondary shows no data file put (`g_data_puts(stub)` is 0); afterwards the secondary's catalog entry equals the primary's, and a connection to the secondary alone reads the new label. A second read prints no "Updating" line. Guard part: a secondary whose entry of the same version was updated **later** than the primary's (the label changed through a connection whose primary is that folder, after the primary's write) is left as it is and nothing is printed. Red: no "Updating" message; the secondary's entry stays old.
- [ ] Report: test names and lines, the red/green table (B-T19 "not run"), `session closed`.

#### WP4c. Edits to existing tests for Part B (test writer, Opus; after WP3-V)

Files it may change: the tests on WP1's read list, `tests/testthat/test-objects.R:43`, `tests/testthat/test-connect.R:324`. Allowed edits only.

- [ ] Apply the edits.
- [ ] Tests run, each filter in its own run: `^read$`, `objects`, `connect`, and the filter of each other file in which this WP edited a test, unless it is a broad file ("Test scope", rules 2 and 4). Nothing else. Report each edited test with its failure reason (one of the reasons in the Rules) and every other test of those files passing; `session closed`.

#### WP4-V. Red verification (verifier, Opus, fresh session; after WP4b and WP4c)

Files it may change: none.

- [ ] Read the test diff, D-B1–D-B13 and "Results". Check that the tests encode the decisions, that every red test has a non-snapshot assertion and fails because nothing is copied or the message is missing (not because of a setup error: the setup of B-T1, B-T9, B-T13, B-T18 and B-T20 must run to the first new assertion), that B-T16 measures the right counters, that B-T19 touches only its own `rcs-test-<random>/` prefix (by reading; it is not run here), and that edits to existing tests are among the allowed ones.
- [ ] Tests run, each filter in its own run, at level `default`: `copy-on-read`, and the filters WP4c ran. Red tests red for the stated reason, guards green, edited tests failing only for the allowed reasons, nothing else failing. `git diff --stat -- R/` shows only Part A's files; no `*.new.md`.
- [ ] PASS or FAIL, `session closed`.

#### WP5a. Code for Part B, current version (code writer, Opus; after WP4-V)

Files it may change: `R/read.R`, `R/sync.R`, `R/objects.R`, `R/connect.R`, `R/utils.R` (option default and the list at lines 12-15), `R/rcs-package.R` (option table), and `tests/testthat/_snaps/*.md` through `snapshot_accept()` only. `R/resolve.R` and `R/raster.R` are not changed.

- [ ] D-B1–D-B5 and D-B7–D-B13:
  - `R/sync.R`: refactor `store_copy()`'s body into one internal helper, `copy_unit(st, source, targets, dataset, ctx)` (builds the unit once, fresh manifests, then for each target `land_location()` and `landed_anyway()`; returns per target the landing figures or the error; prints nothing). `store_copy()` calls it with one target and keeps its messages and its aborts. No second copy body.
  - `R/read.R`: `copy_before_read(st, name, version, copy, call)`, `@noRd`, returns nothing and updates `st` in place; it reads `st$copy_on_read` and `rcs_option("rcs.copy_on_read_max_bytes")` at call time and calls `files_lacking()` and `copy_unit()`. `store_read()` calls it as D-B9 says. For an old version with `copy = TRUE` it calls `land_history()`, which WP5b writes: until then leave a clearly marked call site that does nothing.
- [ ] Tests run until green, each filter in its own run: `copy-on-read` (all green but B-T9's `copy = TRUE` part; B-T19 skipped), `^read$`, `objects`, `connect`, `^sync$`, `^raster$`, `^intersects$`, and the other non-broad filters WP4c ran. Nothing else. Accept snapshots as the Rules allow; do not change test code.
- [ ] Report: diff summary, counts per filter, `session closed`.

#### WP5b. Code for Part B, old versions and documentation (code writer, Opus; after WP5a)

Files it may change: `R/sync.R` (`land_history()`), `R/read.R` (its call, the D-B6 message, roxygen), `R/connect.R`, `R/query.R`, `R/duckdb.R` (roxygen only), and `tests/testthat/_snaps/*.md` through `snapshot_accept()` only.

- [ ] D-B6 as specified there.
- [ ] Roxygen: `store_read()` (argument `copy`; a section "Copy to secondary locations" with the rule of D-B1/D-B2, the limit, old versions and the `store_rebuild()` note, the entry-only refresh of D-B13, how to turn it off); in its section "Rasters", replace the claim that the file is never downloaded by what is true now: a read never downloads the file to read it, but with a local secondary of a bucket primary the whole file is first copied there when it is at or under the limit, and the window is then read from the copy; `copy = FALSE` or a larger file leaves the read on the bucket. `store_connect()` (argument `copy_on_read`, the empty-secondary notice); `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` say in one sentence that they never copy. Do not run `devtools::document()`.
- [ ] Tests run until green, each filter in its own run: `copy-on-read`, `^read$`. Nothing else.
- [ ] Report: diff summary, counts, `session closed`.

#### WP5-V. Green verification (verifier, Opus, fresh session)

Files it may change: none.

- [ ] Read the `R/` diff of WP5a and WP5b against D-B1–D-B13. Look for: a backend call when no copy is needed; a copy to a cloud secondary or with a local primary; a copy from `store_sample()`/`store_glimpse()`/lazy reads; a newer secondary overwritten (no re-check after the refresh); a refresh outside the caught region; a failed copy that fails the read; a duplicated copy body; the limit compared with the wrong bytes or with `integer64`; an old manifest rewritten with a new `written`; a raster read whose window is fetched from the bucket although the copy was made; a same-version entry refresh that sends a data file or runs on every read; a roxygen sentence about rasters that is not true of the code.
- [ ] Read the `_snaps/` diff against D-B6 and D-B7; `store_copy()`'s snapshots unchanged.
- [ ] Tests run, each filter in its own run:
  - `copy-on-read` once at level `full` with the bucket (plus the mutation runs at level `default`, below) ("Test scope", rule 6): B-T19 must pass; report the bucket listing afterwards;
  - `^read$`, `^sync$`, `objects`, `connect`, `^raster$`, `^intersects$`, and the other non-broad filters WP4c ran;
  - the broad files, once each, at level `default`: `integration`, `random-operations`.
- [ ] Mutation check (Rules), each followed by `copy-on-read` with `load_package = "none"` at level `default`:
  - mock `copy_before_read()` to return `invisible()`: B-T1, B-T3, B-T4, B-T9 (copy part), B-T13, B-T18 (a), B-T20 must fail;
  - wrap the original `copy_before_read()` so it runs under `withr::local_options(rcs.copy_on_read_max_bytes = Inf)`: B-T5 and B-T18 (b) must fail;
  - wrap it so it sets `st$copy_on_read <- TRUE` first: B-T7 must fail.
  Report which failed; a mutation no test catches is reported as a gap and counts as FAIL.
- [ ] PASS or FAIL, `session closed`.

### WP6. Efficiency check (verifier, Opus, own session; after WP5-V; parallel with WP7)

No full benchmark. Script in the agent's scratchpad; nothing written to `bench/` or `output/`. Files it may change: none. Tests run: none.

- [ ] Primary and secondary local folders under `tempdir()`, the primary simulated as cloud (as in WP4a's helper), a dataset of about 1e6 rows from `rcs_sim_table()` partitioned into about 10 files. Measure with `system.time()` (5 runs each, median), with `rcs.trace = TRUE` for the counters:
  1. `store_read()` through a primary-only connection (baseline);
  2. the first `store_read()` with an empty secondary (the secondary folder is rebuilt empty before each run);
  3. the second `store_read()` (secondary current);
  4. `store_read(copy = FALSE)` with the secondary current;
  5. `store_copy()` of the same dataset to an empty secondary.
- [ ] **PASS criteria (counters only):** (3) has `bytes_up` 0 and the same `backend_call` and `catalog_read` counts as (4); a default `store_sync()` against a secondary holding 1 of 20 small datasets has the same `backend_call` and `catalog_read` sums as `store_sync(datasets = "<that one>")`.
- [ ] **Reported, not gating:** the five medians; (2) against (5) plus (3); the two sync timings.
- [ ] Report the table, PASS or FAIL, `session closed`. A FAIL is routed to a fresh WP5a writer under the Rules.

### WP7. Documentation for Parts A and B (writer, Opus; after WP5-V; parallel with WP6)

Files it may change, and the required edits:

- `vignettes/locations.Rmd`: the text at lines 201-204 and 256-258 and the evaluated chunks at 263-271 (after `sales/weekly` is written through a primary-only connection, a default sync now skips it: show the default sync and its message, then `datasets =` or `all = TRUE`); a new section on the working-copy model.
- `vignettes/duckdb.Rmd:489-495`: `store_sync(st)` to an empty bucket becomes `store_sync(st, all = TRUE)`.
- `vignettes/geospatial.Rmd`, section "Large maps", the bullet "Read windows": with a local secondary of a bucket primary, a windowed read first copies the whole map when it is at or under the limit; `copy = FALSE` (or `copy_on_read = FALSE`) keeps the read on the bucket. The last bullet ("Every location gets the map") is left for WP12.
- `vignettes/articles/testing.Rmd`: lines 90-91 and 243 (sync repairs; mention `test-copy-on-read.R`).
- `README.Rmd`: one sentence on copy on read where secondary locations are mentioned; no edit (and no `build_readme()`) if they are not mentioned. `bench/spatial.R:547` (`all = TRUE`; not run). `bench/cloud.R` needs no change.
- `.docs/plans/0001-rcs-package.md`: lines 31, 72, 224, 252, 253, so they match D-A2 and D-B1/D-B2.

- [ ] Describe: the working-copy model (local secondary = working copy of a cloud primary); copy on read with its targets (D-B1), the 2 GB limit, `copy =`, `copy_on_read =`; that samples, glimpses and lazy reads stay remote; restricted sync, `all = TRUE`, the empty-secondary notice. Vignettes write only below `tempdir()`.
- [ ] Render each edited vignette with `devtools::load_all()` first, then `rmarkdown::render(<file>, output_dir = <folder under tempdir()>, envir = new.env())` in the same session, so the source package is used; it must run without error. Render `README.Rmd` with `devtools::build_readme()`. Tests run: none.
- [ ] Report the files changed, the render results, `session closed`.

#### WP7-V. Documentation check (verifier, Opus, fresh session)

Files it may change: none. Tests run: none.

- [ ] Read the doc diff against D-A2, D-A4, D-A6, D-A7, D-B1, D-B2, D-B6, D-B13. Render the edited vignettes as WP7 does and read the output of every chunk that calls `store_sync()` or `store_read()`: it must agree with the prose around it. `grep` the repo (outside `.docs/` except plan 0001, and outside `docs/`) for remaining claims that a plain `store_sync()` copies missing datasets or repairs any secondary, and for claims that a raster read never copies or downloads the file.
- [ ] PASS or FAIL, `session closed`.

### WP8. Release of Parts A and B, `0.0.0.9007` (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" for Parts A and B and the paragraph "Parts A and B" of "Outcome" before the writer commits, so both go in one commit. The status **stays `active`**.
- [ ] One writer (Opus). Files it may change: `DESCRIPTION`, `man/`, `NAMESPACE` (through `devtools::document()`), `docs/` (through the site build). It:
  - sets `Version: 0.0.0.9007` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed (`store_read.Rd`, `store_sync.Rd`, `store_connect.Rd`, `store_sample.Rd`, `store_glimpse.Rd`, `store_open.Rd`, `store_duckdb.Rd`, `store_write.Rd`, `store_status.Rd`, `rcs-package.Rd`, and any other the diff explains);
  - runs, each filter in its own run: `copy-on-read`, `^sync$`, `^read$`, once more; no `*.new.md` under `tests/testthat/_snaps/`;
  - rebuilds the website and checks the changed pages (Rules, "Website at each release"); the pages show version `0.0.0.9007`;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `DESCRIPTION`, `README.Rmd`, `README.md`, the edited vignettes and bench script, `docs`, `.docs/plans/0001-rcs-package.md`, this plan);
  - commits with no email address and no AI attribution, for example `Plan 0005, parts A and B: store_read() copies datasets up to 2 GB to local secondaries of a cloud primary; store_sync() refreshes only the datasets a secondary holds (all = TRUE for every dataset); site rebuilt; version 0.0.0.9007`;
  - does **not** push;
  - reports the commit hash, `git show --stat HEAD`, `git status` (clean), the result of the page check, and `session closed`.
- [ ] The orchestrator checks the `git show --stat HEAD` list against the expected paths, then reports to the owner in a few bullets: what changed in sync and in reads, the tests with counts, the WP6 table, open questions, and that Part C starts now. It writes the release line with the commit hash into "Results" (this edit stays uncommitted until WP13), then starts WP9 without waiting (Rules, "Two releases").

### Part C. Primary-only writes

Runs after WP8. The code it builds on is the code of Parts A and B as released: `sync_scope()`, `files_lacking()`, the "not copied" block of `store_sync()`, `copy_before_read()`.

#### WP9. Survey C (investigator, Opus, may run R; no edits to the repo)

Scripts go in the agent's scratchpad. Tests run: none.

- [ ] **Where the flag goes.** List every place that lists the optional catalog columns or names `partition_auto` (grep in `R/` and `tests/`): `catalog_schema()`, `schema_optional`, `entry_omitted_when_na`, `entry_not_embedded`, `new_entry()`, and the tests that fake a catalog written before a column existed (`tests/testthat/test-catalog.R`, `test-schema.R`). These are the places `primary_only` must reach.
- [ ] **One place to set it (D-C2).** In a scratch store, confirm for every stage path (`stage_full()` table and geospatial with an index table, `stage_update()`, `stage_raster()`, the DuckDB paths) that the plan returns `data` and `index` with `entry`, `files` and `manifest_local`, and that writing the manifest again with `new_manifest(entry, files, written = now)` after setting a field on the entry gives a manifest that `store_write()` lands unchanged. If a path differs, name the smallest change. Confirm with `entry_metadata_json()` that a field in `entry_not_embedded` does not change a Parquet file's MD5.
- [ ] **Invariants.** Read `tests/testthat/helper-invariants.R`, `helper-model.R` and `store_check()`: say which invariants or model steps assume that every secondary receives every write, and what each needs so that a primary-only dataset passes. List the edit for each (file, line).
- [ ] **The hooks of Parts A and B.** Name, with lines as they are now: `sync_scope()`, `files_lacking()`, the code that prints the "not copied" block, the code of the empty-secondary notice in `store_connect()`, and the place in `copy_before_read()` where the limit is tested. Say where D-C5, D-C6 and D-C8 hook in.
- [ ] **Status vocabulary.** List every place, test and snapshot that enumerates the status values (`"same"`, `"differs"`, `"missing"`, …) or the print symbols: `location_status()`, `status_symbols()`, `store_dataset_lines()`, `print.rcs_description()`, `write_line()`, `write_footer()`, the roxygen of `store_status()`, `store_datasets()`, `print.rcs_store()` and `store_write()`; `_snaps/inspect.md`, `_snaps/write.md`. Say which snapshots change under D-C3 and D-C4 (expected: none of the existing ones).
- [ ] **Docs.** List the sentences of `vignettes/locations.Rmd` (known: the section "Writes land everywhere", lines 80-99), `vignettes/geospatial.Rmd` (known: the last bullet of "Large maps", lines 719-721), `vignettes/rcs.Rmd` and `README.Rmd` (known: line 48) that say a write reaches every location or that a dataset cannot be kept in the primary only.
- [ ] Report the lists and `session closed`. The orchestrator copies them into "Results".

#### WP10. Red tests for Part C (test writer, Opus)

Files it may change: new `tests/testthat/test-primary-only.R`; new `tests/testthat/helper-copy-on-read.R` (the helpers `local_cor_store()` and `local_test_bucket()` **moved unchanged** from the top of `test-copy-on-read.R`, so that both files can use them; `test-copy-on-read.R` loses only those definitions); the existing tests and helpers on WP9's lists (where the flag goes, status vocabulary, invariants), edited in the smallest way, each edit following from D-C2, D-C3 or D-C4 (known: the column list at `tests/testthat/test-schema.R:40-45` gains `"primary_only"` after `"partition_auto"`; expected red until WP11). Never delete an expectation a decision does not overturn. No change under `R/`.

Setup: a primary and one or two local secondaries under `withr::local_tempdir()`; datasets from `rcs_sim_table()`, `rcs_sim_points()` (with an index table), `rcs_sim_raster(nrow = 20, ncol = 20)` and `sim_landcover()`. Where a test needs the copy-on-read gate, the primary is simulated as cloud after the writes (as `local_cor_store()` does). Each `test_that()` is named by the behaviour; its comment states the expected red reason.

- [ ] **C-T1 (red).** `store_write(…, locations = "primary")` for a table: the primary holds it; the secondary's catalog and folder do not (list the folder); the result row of the secondary has status `"primary only"`, `uploaded` 0, `bytes` 0; `expect_message()` on "kept in the primary only"; no "behind" line in the output. Red: unused argument.
- [ ] **C-T2 (red).** The primary's catalog entry has `primary_only` `TRUE`; a dataset written without `locations` has `NA`, and its manifest JSON on disk has no `primary_only` field (guard on the bytes of ordinary manifests); the manifest of the primary-only dataset has the field. An ordinary dataset's catalog row has the same values as before (the catalog file itself has the new all-`NA` column: expected). A catalog file without the column, faked inside the test as `test-schema.R:355-370` does for `geocode_engine` (the helpers at `test-catalog.R:535` are local to that file), reads with `NA` and validates. The same table written with and without `locations = "primary"` (two stores) has the same version and the same data-file MD5s.
- [ ] **C-T3 (red).** `store_status()` and `store_datasets()` give `"primary only"` for it and `"missing"` for a dataset removed from the secondary by hand. Snapshot the print of the connection (symbol `P`, the legend line with `P primary only`), of `store_status()` and of `store_describe()` for the dataset. A store without a primary-only dataset prints the legend line as today (guard).
- [ ] **C-T4 (red).** A later `store_write(mode = "replace")` without `locations` stays primary-only; with `locations = "all"` and the same data it lands in the secondary, the entry's `primary_only` is `NA`, the version is unchanged and the primary receives no data file. `locations = "secondary"`, `NA` and `c("all", "primary")` abort with `rcs_error_argument` (snapshot one).
- [ ] **C-T5 (red).** A secondary that already holds the dataset: a `replace` with new data and `locations = "primary"` leaves the secondary's files and catalog as they were, informs once (snapshot; D-C3), and `store_status()` gives `"differs"`.
- [ ] **C-T6 (red).** A geospatial dataset with an index table: neither reaches the secondary; both entries carry the flag.
- [ ] **C-T7 (red).** A raster (`rcs_sim_raster(nrow = 20, ncol = 20)`) written with `locations = "primary"`, the primary then simulated as cloud: `store_read()` returns it from the primary with the D-C6 message (`expect_message()` on "kept in the primary only", then snapshot), and the secondary stays without it; `store_read(copy = FALSE)` prints no such line; `store_read(copy = TRUE)` copies it.
- [ ] **C-T8 (red).** `store_sync()` (default) copies nothing of it; `store_sync(all = TRUE)` copies every other dataset and not this one, lists it in `skipped`, prints the line of D-C5 (`expect_message()` on "primary-only", then snapshot) and no "Use `store_sync(st, all = TRUE)`" hint; `store_sync(datasets = "<name>")` copies it, after which `store_status()` gives `"same"`, the secondary's entry has `primary_only` `TRUE`, and a default sync keeps it refreshed after a new primary-only write.
- [ ] **C-T9 (guard).** With no secondary, `locations = "primary"` writes exactly what a normal write does apart from the flag.
- [ ] **C-T10 (red).** Efficiency: with `rcs_trace()`, a primary-only write makes no `bytes_up` and no upload call to the secondary (a counting stub on the secondary, `local_backend_stub(uri = <secondary>)`, logs no call at all); a secondary made unavailable raises no warning.
- [ ] **C-T11 (red; `skip_if_not_installed("terra")`).** A class map stays in the primary. `sim_landcover(file = <temp file>, legend = TRUE, colors = TRUE)` written with `nodata = 0` and `locations = "primary"` through a connection with one local secondary; the primary then simulated as cloud. `store_read(st, "grids/cover", intersects = <box inside the map>)`: a `SpatRaster` with fewer cells than the map, categorical with the five labels (`terra::cats()`), with the colours (`terra::coltab()`; compare with `sim_landcover_colors`), its values equal to the same window read through a primary-only connection; the `file_open` (with `rcs.trace = TRUE`) has the primary's `location`. The whole read `store_read(st, "grids/cover")` has legend and colours too. Afterwards the secondary's catalog has no entry for the dataset and its folder holds no `.tif` and no manifest of it. Red: unused argument `locations`.
- [ ] **C-T12 (red; level `full`, bucket; written here, first run by WP11-V).** With `local_test_bucket()`: a store in the bucket prefix as primary, a local folder as secondary. The class map of C-T11 written with `locations = "primary"` through that connection: the bucket holds one `.tif`; the secondary's folder holds no file of the dataset; `store_status()` gives `"primary only"`; a windowed read returns the window with legend and colours, with one `file_open` at the bucket's `location` and no `be_get` of a `.tif`; a second, identical write uploads nothing.
- [ ] **C-T13 (red).** `store_connect()` with an empty secondary and a primary that holds only primary-only datasets prints no empty-secondary notice (D-C8); with one ordinary dataset beside them it prints it (guard). Red: the notice is printed.
- [ ] Apply the edits WP9 listed to existing tests and helpers (where the flag goes, status vocabulary, invariants). Move the two helpers to `helper-copy-on-read.R`.
- [ ] Tests run, each filter in its own run, at level `default`: `primary-only`, `^write$`, `inspect`, `^sync$`, `copy-on-read`, `connect`, `schema`, `catalog`. Nothing else (the broad files are run by WP11-V). Report each new test red or green with the first line of its failure (C-T12 "not run"), every edited existing test with its state, `copy-on-read` passing as before the move, `session closed`. Delete snapshot entries and `*.new.md` created by the run.

#### WP10-V. Red verification (verifier, Opus, fresh session)

Files it may change: none.

- [ ] Read only the test diff, D-C1–D-C8, "What plan 0006 changed" and WP9's lists in "Results". Check that the tests encode the decisions, that every red test has a non-snapshot assertion, that no test depends on another test's state, that every folder is under `withr::local_tempdir()`, that no test uses data other than `rcs_sim_*()`, and that C-T12 touches only its own `rcs-test-<random>/` prefix (by reading).
- [ ] Check the edits to existing tests and helpers against WP9's lists: nothing else was removed or weakened. Check with `git diff` that `local_cor_store()` and `local_test_bucket()` were moved unchanged.
- [ ] Tests run, each filter in its own run, at level `default`: `primary-only`, `^write$`, `inspect`, `^sync$`, `copy-on-read`, `connect`, `schema`, `catalog`. Every red test fails for the reason in its comment (C-T1 because of the missing argument, not a setup error); every guard passes; every untouched existing test passes. `git diff --stat -- R/` is empty against the WP8 commit; no `*.new.md`.
- [ ] PASS or FAIL with reasons, `session closed`.

#### WP11. Code for Part C (code writer, Opus; after WP10-V)

Files it may change: `R/write.R`, `R/schema.R`, `R/inspect.R`, `R/sync.R`, `R/read.R`, `R/connect.R` (D-C8 only), any file WP9 named under "One place to set it" (only as recorded in "Results"), and `tests/testthat/_snaps/*.md` through `snapshot_accept()` only. `R/raster.R` is not changed.

- [ ] D-C1–D-C6 and D-C8, with the names given there (`resolve_primary_only()`, `plan_primary_only()`, the `primary_only` element of `sync_scope()`, the argument `target_is_secondary` of `location_status()`).
- [ ] Roxygen (do not run `devtools::document()`; WP13 does):
  - `store_write()`: the argument `locations`; the status `"primary only"` in the return value; a paragraph **"Primary-only datasets"**: what the setting does, that it is recorded with the dataset and kept by later writes until `locations = "all"`, what `store_status()`, `store_sync()` and `store_read()` do with such a dataset, that the version and the files do not depend on it, and when to use it (a large raster read through the bucket);
  - `store_status()` and `store_datasets()`: the new status value; `print.rcs_store()`: the symbol `P`;
  - `store_sync()`: what `all = TRUE` leaves out, and that `datasets = ` copies it;
  - `store_read()`: no copy on read for a primary-only dataset a secondary lacks, the line it prints, `copy = TRUE`; in "Rasters", that a primary-only raster is always read from the primary.
- [ ] Tests run until green, each filter in its own run, at level `default`: `primary-only` (C-T12 skipped), `^write$`, `inspect`, `^sync$`, `copy-on-read`, `connect`, `schema`, `catalog`, `^read$`. Nothing else. Do not edit tests; accept only new snapshots and those whose change follows from D-C2, D-C3 or D-C4, listed in the report.
- [ ] Report: diff summary, counts per filter, the snapshot entries accepted, `session closed`.

#### WP11-V. Green verification (verifier, Opus, fresh session)

Files it may change: none.

- [ ] Read the `R/` diff against D-C1–D-C8 with no prior conclusions. Look for: `primary_only` written as `FALSE`; a manifest of an ordinary dataset whose bytes changed, or a catalog row of one whose values changed (the new all-`NA` column in the catalog file is expected); the flag inside a data file's metadata, or a version that depends on it; any backend call to a secondary during a primary-only write; a primary-only secondary row counted as behind; `all = TRUE` copying a primary-only dataset; the default sync no longer refreshing a held copy; a copy on read of a primary-only dataset without `copy = TRUE`; an old catalog without the column failing to read; an existing snapshot of the legend line changed; a change in `R/raster.R`.
- [ ] Read the `_snaps/` diff against D-C3–D-C6.
- [ ] Tests run, each filter in its own run:
  - `primary-only` once at level `full` with the bucket (plus the mutation runs at level `default`, below) ("Test scope", rule 6): C-T12 must pass; report the bucket listing afterwards;
  - `^write$`, `inspect`, `^sync$`, `copy-on-read`, `connect`, `schema`, `catalog`, `^read$`, at level `default`;
  - the broad files, once each, at level `default`: `integration`, `crash-points`, `random-operations`.
- [ ] Mutation check (Rules), each followed by `primary-only` with `load_package = "none"` at level `default`:
  - the write ignores the setting (mock `resolve_primary_only()` to return `NA`): C-T1, C-T5, C-T6, C-T10, C-T11 must fail;
  - `location_status()` ignores the flag: C-T3 must fail;
  - `sync_scope()` ignores the flag: C-T8 must fail;
  - the gate of `copy_before_read()` ignores the flag: C-T7 must fail.
  Report which failed; a mutation no test catches is a gap and counts as FAIL.
- [ ] PASS or FAIL, `session closed`.

#### WP12. Documentation for Part C (writer, Opus; after WP11-V)

Files it may change, and the required edits:

- `vignettes/locations.Rmd`: the section "Writes land everywhere" (it says there is no argument to choose locations: now there is one); the sentence on the print symbols (add `P`); a short new section "Primary-only datasets": when to use them (large rasters read through the bucket), an evaluated chunk that writes a small dataset with `locations = "primary"` and shows the connection and `store_status()`, and what sync and reads do with it.
- `vignettes/geospatial.Rmd`, section "Large maps": the last bullet, which says a dataset cannot yet be kept in the primary only, becomes the advice to write a large map with `locations = "primary"` and to read windows from the bucket, with one evaluated chunk on the small class map of that section (a second store with a local secondary below `tempdir()`); the bullet "Read windows" names it as the way to avoid the copy whatever the size.
- `vignettes/rcs.Rmd` and `README.Rmd`: only the sentences WP9 listed (one clause each: unless written with `locations = "primary"`).
- `vignettes/articles/testing.Rmd`: mention `test-primary-only.R` beside `test-copy-on-read.R`.
- `.docs/plans/0001-rcs-package.md`: the "Catalog schema" table gains the `primary_only` row, marked "(added in plan 0005)"; the `store_write()` and `store_status()` lines mention the argument and the status, marked the same way.

- [ ] Make the edits. Vignettes write only below `tempdir()`.
- [ ] Render each edited vignette as WP7 does; it must run without error. `devtools::build_readme()` if `README.Rmd` changed. Tests run: none.
- [ ] Report the files changed, the render results, `session closed`.

#### WP12-V. Documentation check (verifier, Opus, fresh session)

Files it may change: none. Tests run: none.

- [ ] Read the doc diff and the roxygen written in WP11 against D-C1–D-C8. Every statement must be true of the code: check the ones about status, sync and reads in a scratch store. Render the edited vignettes and read the output of every chunk that uses `locations = "primary"`. `grep` the repo (outside `.docs/` except plan 0001, and outside `docs/`) for remaining claims that a write always reaches every location or that a dataset cannot be kept in the primary only.
- [ ] PASS or FAIL, `session closed`.

#### WP13. Release of Part C, `0.0.0.9008` (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" for Part C and completes "Outcome", and sets the status to `done`, before the writer commits, so both go in one commit.
- [ ] One writer (Opus). Files it may change: `DESCRIPTION`, `man/`, `NAMESPACE` (through `devtools::document()`), `docs/` (through the site build). It:
  - sets `Version: 0.0.0.9008` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed (`store_write.Rd`, `store_status.Rd`, `store_datasets.Rd`, `store_sync.Rd`, `store_read.Rd`, `print.rcs_store.Rd`, and any other the diff explains);
  - runs, each filter in its own run: `primary-only`, `^write$`, `inspect`, once more; no `*.new.md` under `tests/testthat/_snaps/`;
  - rebuilds the website and checks the changed pages (Rules, "Website at each release"); the pages show version `0.0.0.9008`;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `DESCRIPTION`, `README.Rmd` and `README.md` if changed, the edited vignettes, `docs`, `.docs/plans/0001-rcs-package.md`, this plan);
  - commits with no email address and no AI attribution, for example `Plan 0005, part C: store_write(locations = "primary") keeps a dataset in the primary only; status, sync and copy on read respect it; site rebuilt; version 0.0.0.9008`;
  - does **not** push;
  - reports the commit hash, `git show --stat HEAD`, `git status` (clean), the result of the page check, and `session closed`.
- [ ] The orchestrator checks the `git show --stat HEAD` list against the expected paths, then reports to the owner in a few bullets: what changed, the tests with counts, open questions.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- `store_status()` still reports datasets a secondary never held as `"missing"`. With the working-copy model a separate status (for example `"not held"`) might read better. Not in this plan.
- `store_rebuild()` of a secondary that holds only an old version of a dataset makes it the current entry (D-B6). Documented here; a marker for "history only" could avoid it. Not in this plan.
- The random-operations model uses `all = TRUE`, so it never exercises the restricted default. It also never writes a primary-only dataset.
- `store_status()` compares versions only: a secondary that holds the same version of a raster with an older legend or older colours is `"same"`, although `store_sync()` and a read (D-B13) refresh it. Should the status show it?
- `store_sync()` records a conflict only when the versions differ. A secondary whose entry of the same version was changed later (a legend set offline) is overwritten by a sync from the primary without a conflict or a warning. Copy on read leaves it alone (D-B13).
- (From plan 0006.) A legend or colours written again for the same cells replace the earlier ones under the same version; the earlier ones are not kept in the history, also not for `store_read(version = )`. A secondary refreshed by a sync or a read gets the new ones. Should the manifest keep a history of them?
- (From plan 0006.) `rcs_trace()` counts `bytes_down` only in the package's own downloads, not GDAL's range requests. So the tests of "the window is read from the bucket, nothing copied" (B-T18, B-T19, C-T11, C-T12) assert where the file was opened and that no file was fetched whole, not how many bytes a window costs.
- (From plan 0006.) The national maps (11.8e9 cells in a bucket) cannot be tested in the package, which holds no raw data. After Part C the owner writes one map with `locations = "primary"` from the downstream project and checks `store_status()` and a windowed read.
- Note 0004 also proposed a size threshold for skipping the secondary at write time. Part C gives only the explicit argument; the 2 GB rule acts on reads, not on writes.
- `store_check()` reports a primary-only dataset as `"missing"` in a secondary (D-C4 leaves it unchanged).
- `raster-gcs` and the other bucket tests outside the three bucket runs of "Test scope" (in `test-raster.R`, `test-duckdb.R`, `test-auth.R`, `test-backend-gcs.R`) are never run in this plan (`test-integration.R` has no level-`full` test), although Part B changes what a read through a bucket primary with a local secondary does. B-T19 covers the new behaviour; the old bucket tests are not re-run. Should one release run them?
- Every agent of this plan runs with model `opus` (Rules). Kept as it is.
- The symbol `P` for "primary only" in the prints is the plan writer's choice (D-C4).

## Results

### Facts established before execution (plan verification, 2026-11-27)

- **D-B6 probe.** An old version's files, unchanged manifest and history rows (with the primary's `replaced`) were placed in a secondary (a) holding the dataset at the current version and (b) not holding it. In both: `expect_store_valid()` passes; `store_check()` is unchanged (`ok` / `missing`); `store_read(version = <old>)` reads from the secondary; `store_prune(keep = 1)` keeps the rows and `keep = 0` removes files and manifest cleanly. `store_rebuild()`: (a) unchanged; (b) the old version becomes the current entry. A manifest rewritten with a new `written` makes `store_rebuild()` promote the old version even in (a): hence "copy the manifest unchanged". Duplicate history rows pass the invariants but must be avoided.
- **Test level.** `testthat::test_local()` and `devtools::test()` both run at level `default`. `^sync$`: 28 tests, about 150 s. `crash-points`: about 85 s.
- **Progress bar.** With `cli.progress_show_after = 0` and `rcs.quiet = FALSE`, `capture_messages()` gets one line per file, for example `<root>/s ===============>---------------  1/2 files`. At width 80 the path truncates the counter: use `local_reproducible_output(width = 300)`. The "files sent" line carries bytes and seconds: transform them in snapshots.
- **`copy =` today.** `store_read(st, "<name>", copy = FALSE)` (or `"yes"`) fails with a simple error, `filter expressions must be either an expression or a list of expressions`.
- **Random-operations model.** It checks reads through primary-only connections; it needs only `all = TRUE` at `helper-model.R:289, 369, 458`.

### Facts checked for the revision of 2026-11-27 (by reading the code at `0b47207`, version `0.0.0.9006`; no R was run)

- **Same version, another entry.** `resolve_target()` (`R/write.R:1449`) keeps the files and writes a new entry with `updated = now` when the version is the same and the entry differs. `holds_entry()` (`R/write.R:1480`) compares the whole entry, so `land_location()` lands it in a secondary with no file sent, and `unit_needed()` (`R/sync.R:331`) makes `store_sync()` refresh a secondary that missed it. `location_status()` (`R/inspect.R:53`) and `choose_location()` (`R/resolve.R:109-112`) compare versions only. `read_target()` (`R/read.R:31-35`) takes the entry of a current-version read from the primary's catalog. `sync_plan()` (`R/sync.R:384`) records conflicts and overwrites only when versions differ. WP1 confirms these in a scratch store.
- **A dataset can change its kind.** `stage_update()` aborts when the kind of `x` differs from the stored one and says to use `mode = "replace"` to change it (`R/write.R:851-863`). So an old version may have another kind than the current entry: D-B9 moves the raster-argument checks before the copy step only for a read of the current version.
- **What the test files call.** `test-history.R`, `test-inspect.R`, `test-write.R`, `test-read.R`, `test-check.R`, `test-intersects.R`, `test-connect.R` and `test-random-operations.R` contain no `store_sync(` call of their own (the model's are in `helper-model.R`). `test-crash-points.R` has no `store_copy()`; the model's copy is at `helper-model.R:452`. `test-raster.R:2115` writes and reads a class map through `store_write()` and `store_read()` with a local secondary. `test-random-operations.R` and `test-crash-points.R` run a part of their tests at level `default`.
- **Embedded metadata.** `entry_not_embedded` (`R/schema.R:682-685`) lists the entry fields kept out of the data files (`history` among them); `entry_omitted_when_na` (line 690) lists the fields left out of manifests and metadata when `NA`.
- **Stage paths.** `stage_full()`, `stage_index()`, `stage_raster()` and the DuckDB paths all return version sources with `entry`, `files` and `manifest_local` (`staged_src()`, `R/write.R:736`; `stage_raster()` lines 832-842). WP9 confirms D-C2's single setter on them.
- **A name already in use.** The test fixture `fixture_write()` (`helper-store.R:178`) has an argument `locations` (the locations a fixture lands in) and `store_check()` has `locations = "all"` (addresses to check). Neither is the new `store_write(locations = )`.

### Execution

(Filled in by the orchestrator: WP1's lists and answers, then each WP's verdict and counts; after the WP8 commit the line "Parts A and B released as 0.0.0.9007 (`<hash>`); Part C in progress", committed with Part C; then WP9's lists and the verdicts of Part C.)

## Outcome

(Filled in at WP8 for Parts A and B, and completed at WP13 for Part C, when the status becomes `done`.)
