# Copy on read to secondary locations; sync restricted to the datasets a secondary already holds

- **Date:** 2026-11-26 (verified and revised 2026-11-27; version and preflight updated 2026-11-27 after plan 0006, parts A and C)
- **Author:** Eduard Bukin
- **Status:** draft

## Goal

When this plan is done:

1. **Part A (sync).** `store_sync()` to secondary locations, without `datasets`, refreshes only the datasets each secondary already holds. It says that only those were synced, how many datasets and how much data (files, bytes) a full sync would add, and that `all = TRUE` copies everything. `datasets = ` still copies the named datasets whether or not a secondary holds them. A sync whose target is the primary (`from = <secondary>`) still sends everything. An empty secondary is announced at `store_connect()` and in every `store_sync()`, with an invitation to sync it by hand.
2. **Part B (copy on read).** `store_read()` of the current version of a dataset that a reachable **local secondary of a non-local primary** lacks, or holds at an older version, first copies the whole dataset to that secondary with the existing copy code, with a progress bar and a message, then reads from the copy. It does not copy when the download exceeds 2 GB (`rcs.copy_on_read_max_bytes`), for old versions, or when the connection or the call turns it off. In every one of those cases it reads only what it needs from the primary and says how to copy. `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` never copy.
3. Every change is test-driven: the tests are written first and shown to fail for the stated reason (red), then the code makes them pass (green). A separate verifier confirms each step.
4. The new code paths are shown to be efficient by work counters (`rcs_trace()`) and a short timing script. The full benchmark (`bench/`) is **not** re-run.
5. Version `0.0.0.9007`, committed (not pushed) once everything is green.

Decision record: `.docs/notes/0003-local-copy-on-read-and-restricted-sync.md`. Read it first. The decisions below make it precise and, where the owner decided otherwise on 2026-11-27 (D-B1, D-A6, D-A7), replace it. Where handoff 0004 differs from this plan, the plan governs.

## Context

### What exists that this plan builds on

- **Choosing where a read comes from.** `choose_location()` in `R/resolve.R` (line 92) picks, among available locations holding the dataset at the primary's version: local backends first (**the primary first among them**), then the primary, then other secondaries. "Local" is `identical(location$backend$type, "local")`. So a read comes from a secondary only when the primary is not local and the secondary is. For an old `version` it reads `_history.parquet` and calls `be_exists()`. It informs `Reading "<dataset>" from secondary <uri>.` It makes no backend call for the current version.
- **Read entry point.** `read_target()` in `R/read.R` (line 21) resolves the name (index tables too), calls `choose_location()`, and finds entry and files. `store_read()` (line 131), `store_sample()` (line 237) and `store_glimpse()` (line 339) all call it; so do `store_open()` (`R/query.R:137`) and `store_duckdb()` (`R/duckdb.R:228`). No other function in `R/` calls `store_read()`. `store_read()` has `...` (filter expressions) before its named arguments; its raster-argument checks (`R/read.R:142-160`), `select_columns()` and the `intersects` validation run after `read_target()`.
- **Copying one dataset.** `store_copy()` in `R/sync.R` (line 755) refreshes both locations through `reach()` (aborts with `rcs_error_backend`, outside any `tryCatch`), creates its own staging folder and `write_context()` (lines 776-780), builds a unit with `sync_unit()` (the dataset plus its index table), writes fresh manifests (`sync_fresh_manifests()`, new `written` time), and lands it with `land_location()` (`R/write.R:1435`). `land_location()` sends only the files the target lacks: it matches path + MD5 against the target's files table **and against `history_read(be)` and `be_md5()`, which are backend calls** (`R/write.R:1444-1450`), verifies MD5, puts manifests, then switches the catalogs under the write lock; it always makes the landed version the current one and has no conflict check. Its upload goes through `upload_verified()` (`R/write.R:1374`), which shows a cli progress bar unless `rcs.quiet`. `source_file()` caches downloads per context only (`R/write.R:1311-1326`). `landed_anyway()` (`R/sync.R:344`) handles errors raised after the catalog switch. Write-class errors are `write_error_classes` (`R/write.R:482`: backend, conflict, locked, schema).
- **Sync.** `store_sync()` (`R/sync.R:113`) builds every unit of the source and a fresh manifest for each (lines 133-140), prints `sync_header()` (line 144, "Syncing {n} datasets…"), then plans per target with `sync_plan(st, source, target, units, restrict, delete, force)` (line 376), which returns `copy`, `conflicts`, `overwritten`, `delete`, `kept`. `restrict` is `NULL` whenever `datasets` is `NULL`. Targets that are unavailable or behind at refresh get a result with no plan (lines 148-151). Landing is `sync_location()` (re-signals non-write errors; `behind()` at line 465); the dry run is `sync_plan_location()` (line 517). `sync_footer()` (line 633; returns early for dry runs; line 649 prints "Every secondary location is up to date." when every status is `"same"`). The result tibble (one row per target) is built by `sync_result()` / `sync_result_row()` / `sync_empty()` (lines 534-557). `sync_refresh()` (lines 240-251) turns write-class refresh failures into a warning.
- **Connection object.** An environment. `new_store()` and `validate_store()` in `R/objects.R` (lines 109, 123); the documented field table is above them. `_history.parquet` is **never held in the object** (`R/objects.R:21`). `store_connect()` in `R/connect.R:68` (no `...`). `store_refresh()` replaces only the locations. The primary is always available (`validate_store()` aborts otherwise). `available` is a held field of each location.
- **Options.** Defaults in `rcs_option()` (`R/utils.R:14-31`, with a roxygen list at lines 12-15), documented in the table in `R/rcs-package.R:22`.
- **Bytes.** The catalog and file rows carry `bytes` as `bit64::integer64` (`R/schema.R:66, 89`): convert with `as.numeric()` before summing or comparing. `format_bytes()` (`R/utils.R:409`) uses decimal units; `format_bytes(2e9)` prints `2.0 GB`. `format_seconds()` prints `4.2s`.
- **Work counters.** `R/trace.R`; counters `backend_call`, `catalog_read`, `file_open`, `bytes_up`, `bytes_down`. They record only under `options(rcs.trace = TRUE)`; tests read them with `rcs_trace()` / `rcs_trace_reset()`.
- **Messages that send users to `store_sync()`** (written `{.fn store_sync}` in the source; snapshotted in `tests/testthat/_snaps/write.md`): `R/write.R:471` (warning, secondary unreachable: "Run `store_sync()` once it can be reached."), `R/write.R:1672` (warning, write to a secondary failed: "Run `store_sync()` to bring it up to date."), `R/write.R:1777` (inform in the write footer: "{n} secondary location(s) is/are behind; run `store_sync()` to bring it/them up to date."). Roxygen at `R/write.R:186-188` and `R/inspect.R:119-120`.
- **Tests.** `store_sync(` appears in `tests/testthat/test-sync.R` (54 calls), `test-integration.R` (9), `test-crash-points.R` (3), `test-catalog.R` (2) and `helper-model.R` (3 calls: lines 289, 369, 458). Most fixtures build the connection with `fixture_connect()` → `new_store()` (`helper-store.R:143`), not `store_connect()`. A cloud primary is simulated by `primary <- st$primary; primary$backend$type <- "gcs"; st$primary <- primary` (`test-read.R:166-169`); backend generics dispatch on the S3 class, so the folder keeps working. A secondary is made unavailable as in `test-sync.R:150-160`. `local_backend_stub(uri =, generic =, fail_at =)` (`helper-backend-stub.R:75`) makes a backend call fail. Snapshot helpers: `g_quiet()`, `g_snapshot_output()` (sets `rcs.quiet = FALSE`).
- **Docs that describe sync or secondaries:** `vignettes/locations.Rmd`, `vignettes/duckdb.Rmd`, `vignettes/articles/testing.Rmd`, `README.Rmd`, `bench/spatial.R:547`.

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh Opus session) runs **no code**: no R, and no Bash that builds, tests or edits. It may read files and git state (`git status`, `git diff`, `git log`, `git show --stat`). It spawns every work package as an Agent with `model: "opus"`, gives it this plan's path, its WP name and the "Results" facts, checks each report against the acceptance criteria, ticks the steps, and fills in "Results" and "Outcome". It edits only this plan file.
- **TDD cycle per part.** (1) A **test writer** adds tests only, with no change under `R/`. (2) A **red verifier** confirms in a fresh session that each new test fails for the reason stated, and that tests marked "guard" pass already. (3) A **code writer** changes `R/` until the tests pass. It may not change a test's code; a test it believes wrong goes back to the orchestrator with the reason. (4) A **green verifier** reads the diff with no prior conclusions, runs the tests and regressions, and runs a mutation check.
- Writers and verifiers are separate agents. Verifiers never edit files. Each verifier gets the acceptance criteria and the paths, not the writer's conclusions.
- **Red tests.** Every red test has at least one assertion that is not a snapshot (`expect_message(regexp = )`, `expect_identical()`, a catalog check), because a new `expect_snapshot()` records today's output and passes. The test writer deletes any snapshot entry and any `*.new.md` its red run created.
- **Snapshots.** The code writer (green) may run `testthat::snapshot_accept()` for new snapshots and for existing ones whose recorded code line or hint text changed because of this plan. The green verifier reads the whole `tests/testthat/_snaps/*.md` diff against the decisions, and checks that no `*.new.md` remains.
- **Existing tests whose expectations change** are edited by the test writer of that part, in the smallest way, so that the test keeps checking what it checked before. Allowed edits, and no others:
  - add `all = TRUE` or `datasets = "<name>"` to a `store_sync()` call;
  - add `copy = FALSE` to a `store_read()` call, or `st$copy_on_read <- FALSE` after a fixture (the fixtures use `new_store()`, which gets the default `TRUE`);
  - `test-sync.R:422`: add `"skipped"`, `"skipped_files"`, `"skipped_bytes"` after `"conflicts"` in the expected names;
  - `test-objects.R:43`: add `"copy_on_read"` to the expected fields;
  - `test-connect.R:324`: add `copy_on_read` to the expected formals of `store_connect()`.
  Never delete an expectation. A test edited only with `st$copy_on_read <- FALSE` or `datasets = ` still passes in the red phase. The other edited tests are **expected to fail** in the red phase, for these reasons only: `unused argument (all = TRUE)`; for `copy = FALSE`, the simple error `filter expressions must be either an expression or a list of expressions`; for the three value changes, the missing name. They must pass at the green step.
- **Routing on FAIL.** A verifier's FAIL goes to a fresh writer of the same kind with the verifier's findings and the diff (do not try to resume the old agent), then to a fresh verifier. A regression failure in a test nobody edited, found at a green step, goes to a test writer of that part (allowed edits above), then the red verifier's check of that edit, then back. After the second FAIL of the same WP, the orchestrator stops and asks the owner. A writer that stopped mid-WP leaves its partial diff in place: a fresh writer of the same WP continues from `git diff`; nothing is reverted.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report ends with `session closed`. If one does not, the orchestrator sends a small agent to `quit()` that session.
- **Running tests.** `devtools::load_all()` then `testthat::test_local(filter = "...")`; this runs at test level `default` (checked). Never run the whole suite (more than 30 minutes). Known times: `^sync$` about 150 s, `crash-points` about 85 s. `filter` is a regular expression on the file name: `duckdb` matches six files (all are wanted). Tests that use counters set `withr::local_options(rcs.trace = TRUE)`.
- **Mutation checks** are done in the R session only, never by editing files: mock with `testthat::local_mocked_bindings()` or `assignInNamespace()`, then run the test file with `testthat::test_local(filter = "...", load_package = "none")`, because the default reloads the package and undoes the mutation.
- **Order and parallelism.** WP1 → WP2 → WP2-V → WP3 → WP3-V → WP4c → WP4-V → WP5a → WP5b → WP5-V → (WP6 ∥ WP7 → WP7-V) → WP8. WP4a then WP4b may run while WP3 and WP3-V run: they write only the new `test-copy-on-read.R`, run only the filter `copy-on-read`, and their test setups fill secondaries with `store_copy()`, never `store_sync()`. Nothing else overlaps. Code writers never run in parallel.
- Tests use only data from `rcs_sim_*()` or small frames built in code. Every location goes under `withr::local_tempdir()`.
- R style: `r-lib:r-testthat`, `r-lib:r-cli`, `r-lib:r-tidyverse-style`. Messages use cli only, with the classes of the surrounding code. Internal helpers get the comment / `@noRd` block the file already uses.
- **No full benchmark.** Efficiency is shown by WP6 only.
- **Commit.** The owner authorised on 2026-11-27 the WP8 commit once everything is green, without a further OK. Staged by explicit paths. **No push.**

### Decisions taken (do not ask the owner about these)

Part A, `store_sync()`:

- **D-A1. New argument `all = FALSE`**, placed after `datasets`. `TRUE` restores today's behaviour (every dataset of the source to every target). `all = TRUE` together with non-`NULL` `datasets` aborts with `rcs_error_argument`. `all` must be a flag (`check_flag()`).
- **D-A2. Default scope per target.** With `datasets = NULL` and `all = FALSE`, a target that is a **secondary** receives only the units whose dataset has an entry in its held catalog, at any version (an index-table entry alone does not count). A target that is the **primary** (`identical(target$uri, st$primary$uri)`) receives every unit. The rule is one internal function in `R/sync.R`, `sync_scope(st, target, units, all)`, returning `list(keep = <units>, skip = <units>)`; with `all = TRUE`, or `datasets` given, `skip` is empty. `sync_plan()` gets a new argument `all`, calls `sync_scope()` first, plans only `keep`, and returns `skipped` (the `skip` units) beside its other fields. `delete = TRUE`, `force` and conflicts are unchanged (deletions come from the catalogs, not from units; a conflict needs the target to hold the dataset).
- **D-A3. What was not copied.** One internal function in `R/sync.R`, `files_lacking(units, target)`: input a list of units and a target location; output `list(files = <integer>, bytes = <numeric>)`, the files of those units (index tables included) whose path + MD5 is not in the target's **held files table**. It uses no history and makes **no backend call**; the figure is an upper bound of what a full sync would send. The result tibble gets three columns after `conflicts`: `skipped` (list of dataset names), `skipped_files` (integer) and `skipped_bytes` (numeric). `files`/`bytes` keep their meaning (files sent). Targets that got no plan (unavailable, or behind at refresh) have `character()`, `0L`, `0` and no message line; a target whose landing fails still reports what was skipped.
- **D-A4. Messages.**
  - Header: with `datasets = NULL`, `all = FALSE` and at least one secondary target, `sync_header()` does not print the count of every source dataset; it says `Syncing the datasets already held by each secondary location` (the rest of the header as today). Otherwise the header is unchanged.
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
  - `R/write.R:471`: ``Once it can be reached, run `store_sync(st, datasets = "<name>")`, or `store_sync(st, all = TRUE)` for every dataset.``
  - `R/write.R:1672`: ``Run `store_sync(st, datasets = "<name>")` to bring it up to date, or `store_sync(st, all = TRUE)` for every dataset.``
  - `R/write.R:1777`: ``{n} secondary location{?s} {?is/are} behind; run `store_sync(st, datasets = "<name>")` to bring {?it/them} up to date, or `store_sync(st, all = TRUE)` for every dataset.``

  The roxygen at `R/write.R:186-188` and `R/inspect.R:119-120` says the same. Writes themselves are unchanged: a new dataset is written to every available location.
- **D-A8. Manifests only for what is copied.** `store_sync()` writes fresh manifests only for units that some target's plan copies (plan the targets first, or write them per target, cached), not for every unit of the source.

Part B, copy on read:

- **D-B1. Where copies go.** Only to secondaries the read will then use: **available**, with a local backend, while the primary's backend is not local (the same `backend$type` test as `choose_location()`), and lacking the dataset or holding an **older** version, or lacking its index table (the semantics of `unit_needed()`, `R/sync.R:331`). "Older": the secondary's entry has another version and its `updated` is not later than the primary's. A secondary whose version was updated later than the primary's is never overwritten by a read: it is skipped with the message of D-B7. With a local primary, or only cloud secondaries, a read copies nothing and prints nothing; this holds for `copy = TRUE` too, which then informs ``No secondary location to copy to. Use `store_sync(st, datasets = "<name>")`.`` All targets of one read share one unit, one staging folder and one `write_context()` (as `sync_location()` does), so files are downloaded once.
- **D-B2. When `store_read()` copies.** Only when all hold: the read is of the current version (`version` is `NULL` or equals the primary's version); the connection's `copy_on_read` is `TRUE`; the call's `copy` is not `FALSE`; at least one secondary needs the copy (D-B1); and the bytes to download do not exceed the limit (D-B3), unless `copy = TRUE`. Filters, `columns` and `intersects` do not change the rule. Raster datasets follow the same rule.
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

  The secondary's current entry is unchanged, **whether or not it holds the dataset** (checked: invariants, `store_check()`, `store_prune()` and old-version reads all work in both cases). Known and documented in `store_read()`'s roxygen: `store_rebuild()` of a secondary that holds only an old version of a dataset makes that version its current entry. Messages as D-B7's copy lines, with "to the history of <secondary>". Failures follow D-B8.
- **D-B7. Messages** (all through `rcs_inform()`; texts are snapshotted, close to these):
  - Copy: `ℹ Copying "sales/daily" (version <v>, 12 files, 340 MB) from <primary> to <secondary> before reading.` (the files and bytes to send, from `files_lacking()`) then the progress bar of `upload_verified()`, then `✔ 12/12 files sent (340 MB) in 4.2s, MD5 verified.` The `Reading "sales/daily" from secondary <uri>.` line follows from `choose_location()`. `store_copy()`'s own messages and snapshots do not change: the shared helper returns the figures and each caller prints its own lines.
  - Above the limit: ``ℹ "sales/daily" needs 3.4 GB, above the 2.0 GB limit for copying on read (`rcs.copy_on_read_max_bytes`). Reading from <primary>.`` then ``Use `copy = TRUE`, or `store_sync(st, datasets = "sales/daily")`, to copy it.``
  - Newer secondary skipped: ``! <secondary> holds a newer version of "sales/daily"; it is not replaced. See `store_sync()`.`` (inform, not warn).
- **D-B8. Failure of the copy.** For each target, the refresh of that target and the landing are inside one caught region. A write-class error (`write_error_classes`) does not fail the read: a warning of class `rcs_warning_secondary_behind` says the copy to `<secondary>` failed, that the next read retries, and names ``store_sync(st, datasets = "<name>")`` and `copy_on_read = FALSE`; the read goes on from the primary. The same holds when the refresh of the primary fails with a write-class error: one warning, no copy at all. Errors of other classes propagate. A failure after the catalog switch is handled with `landed_anyway()`. Nothing is remembered between reads: a failing secondary warns on every read.
- **D-B9. Order inside `store_read()`.** `store_read()` itself calls the copy step, `copy_before_read(st, name, version, copy, call)`, after its argument checks and just before `read_target()`; the read then comes from the fresh copy through the existing `choose_location()` order. `copy_before_read()` first resolves `name` and checks `version` with the same helpers `read_target()` uses (`R/read.R:22-29`), so a bad name or version aborts with today's error before anything is copied. The raster-argument checks (`R/read.R:142-160`), which need only the catalog entry, move before the copy step. The `columns` and `intersects` checks stay where they are. `read_target()` is unchanged; `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` are unchanged.
- **D-B10. Catalog freshness.** The copy step decides from the catalogs held by the connection (no backend call when nothing is needed). When a copy is needed, it refreshes the primary and each target, then **repeats the D-B1–D-B3 decision once on the refreshed catalogs** before landing (a target that became newer is skipped; if the primary's current version changed and `version` named the previous one, the read is an old-version read and nothing is copied). `land_location()` updates the held catalogs, so `st` is current afterwards.
- **D-B11. No eligible secondary.** With no secondary, or none passing D-B1's backend test, nothing changes from today: no message, no write anywhere.
- **D-B12. Index tables.** A read whose `name` is an index table never copies.

- **D-V. Version `0.0.0.9007`.** There is no NEWS.md; do not create one.

## Steps

### WP0. Preflight (orchestrator, no code)

- [ ] `git merge-base --is-ancestor 6953970 HEAD` succeeds (the releases of plan 0006, parts A and C, are in the history) and `DESCRIPTION` says `0.0.0.9006`. Otherwise stop and report to the owner. Plan 0006 changed `R/raster.R`, `R/write.R`, `R/read.R`, `R/check.R`, `R/inspect.R` and `R/schema.R` after this plan was verified: the line numbers given in "Context" for those files may have moved, so find each function by name.
- [ ] `git status` is clean (the revised plan is committed). Otherwise ask the owner.
- [ ] Set this plan's status to `active`.

### WP1. Survey (investigator, Opus, may run R; no edits to the repo)

Scripts go in the agent's scratchpad. The facts in "Results" are already established; do not redo them.

- [ ] **Sync-dependent tests.** List every test (file, line, `test_that` name) whose expectations rely on `store_sync()` copying datasets a secondary does not hold, in `test-sync.R`, `test-integration.R`, `test-crash-points.R`, `test-catalog.R`, `helper-model.R`. For each, the edit that keeps its meaning: `datasets = "<name>"` where the test is about repairing one dataset (for example `test-sync.R:112`), else `all = TRUE`. List the existing `expect_snapshot()` calls whose code line changes.
- [ ] **Connect notice (D-A6).** List the tests that snapshot or assert the output of `store_connect()` with an empty secondary and a non-empty primary (they gain a line).
- [ ] **Write hints (D-A7).** For each of `R/write.R:471, 1672, 1777`, say whether the dataset name is in scope, and list the snapshot entries in `_snaps/write.md` (and elsewhere) that contain the old hint.
- [ ] **Read-dependent tests.** List every test that calls `store_read()` with a simulated cloud primary and a local secondary that lacks the dataset or holds an older version (known: `test-read.R:163`, last line; scan `test-read.R`, `test-write.R:276`, `test-intersects.R`, `test-sync.R`, `test-integration.R`, `test-check.R:108`). For each, the edit (`copy = FALSE` or `st$copy_on_read <- FALSE`).
- [ ] **Simulated cloud primary through a copy.** In a scratch store, set `primary$backend$type <- "gcs"` as `test-read.R:166` does, then run `store_copy()` from that primary to a local secondary and `store_refresh()`. Report whether the copy works and whether the faked `type` survives the refresh done inside `store_copy()`. If it does not survive, name the smallest test-side way to keep it (the WP4 helper will use it).
- [ ] Report the lists and answers, and `session closed`. The orchestrator copies them into "Results".

### Part A. Sync restricted to datasets a secondary holds

#### WP2. Red tests for Part A (test writer, Opus)

Files: `tests/testthat/test-sync.R` (new tests together under a comment `# Plan 0005: sync restricted to held datasets`), `tests/testthat/test-connect.R` (A-T11), `tests/testthat/test-write.R` (A-T12), and the existing tests on WP1's sync list (allowed edits only). No change under `R/`.

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
- [ ] Apply the allowed edits to the existing tests on WP1's sync list and to `test-sync.R:422`.
- [ ] Run `testthat::test_local(filter = "^sync$")`, then each of `integration`, `crash-points`, `catalog`, `random-operations`, `connect`, `^write$`, `history`, `inspect` separately. Report each new test red or green with the first line of its failure; each edited existing test with its failure reason (must be one of the reasons in the Rules); every other test passing. Delete snapshot entries and `*.new.md` created by the run.
- [ ] Report: test names, file and line, the red/green table, the edited tests, `session closed`.

#### WP2-V. Red verification (verifier, Opus, fresh session)

- [ ] Read only the test diff, D-A1–D-A8 and note 0003. Check that the tests encode the decisions, that every red test has a non-snapshot assertion, and that no test depends on another test's state.
- [ ] Check each edit to an existing test against WP1's list and the allowed edits; no expectation removed or weakened.
- [ ] Run the same filters. Every red test fails for the reason in its comment; every guard passes; every edited existing test fails only for a reason in the Rules; no other failure. `git diff --stat -- R/` is empty; no `*.new.md` and no new snapshot entries.
- [ ] PASS or FAIL with reasons, then `session closed`.

#### WP3. Code for Part A (code writer, Opus)

Files: `R/sync.R`, `R/connect.R` (D-A6 only), `R/write.R` and `R/inspect.R` (D-A7 only).

- [ ] D-A1–D-A8, with the function names and signatures given there (`sync_scope()`, `files_lacking()`, `sync_plan(..., all)` returning `skipped`). Update the roxygen of `store_sync()`: the new argument, the default scope, the three result columns, an example with `all = TRUE`. Do not run `devtools::document()` (WP8 does).
- [ ] Run the filters of WP2 until green. Accept snapshots as the Rules allow; do not change test code.
- [ ] Report: diff summary, counts per filter, the snapshot entries accepted, `session closed`.

#### WP3-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the `R/` diff with no prior conclusions against D-A1–D-A8. Look for: a backend call in `files_lacking()`; a primary target wrongly restricted; deletions changed; `dry_run` writing anything; manifests written for skipped units; an old hint left in `R/` (read every line that `grep -n "store_sync" R/write.R R/inspect.R` returns).
- [ ] Read the `_snaps/` diff against D-A4, D-A6, D-A7.
- [ ] Run, each separately, reporting counts and failures verbatim: `^sync$`, `integration`, `crash-points`, `catalog`, `history`, `inspect`, `random-operations`, `connect`, `^write$`.
- [ ] Mutation check (Rules): mock `sync_scope()` to return every unit in `keep`: A-T1, A-T6 (red part), A-T7, A-T10 must fail. Mock `files_lacking()` to return zeros: A-T1 and A-T2 must fail. Report which tests failed.
- [ ] PASS or FAIL, then `session closed`.

### Part B. Copy on read

#### WP4a. Red tests, first half (test writer, Opus; may start when WP2-V has passed)

Files: new `tests/testthat/test-copy-on-read.R` only. Runs only `testthat::test_local(filter = "copy-on-read")`.

Helper at the top of the file: `local_cor_store(secondaries = 1L, ...)` builds a primary and local secondaries under `withr::local_tempdir()`, writes the datasets through a primary-only connection, connects with `store_connect(primary, secondary = ...)` (quietly) and then simulates a cloud primary as `test-read.R:166-169` does (or as WP1 found necessary). Secondaries are pre-filled with `store_copy()` where a test needs it. Datasets from `rcs_sim_table()`, `rcs_sim_points()` / `rcs_sim_polygons()` (with an index table) and `rcs_sim_raster()`. Messages are checked with `rcs.quiet = FALSE` and a transform that replaces temp paths, sizes and seconds.

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

Files: `tests/testthat/test-copy-on-read.R` only (append). Same helper and filter.

- [ ] **B-T9 (red).** Old version: primary with history and two versions of one dataset (written through a primary-only connection); secondary A holds the current version (`store_copy()`), secondary B holds nothing.
  - `store_read(version = <old>)` copies nothing, returns the old data, and informs as D-B6 (`expect_message()` on "old versions are not copied", then snapshot). Red: no such message.
  - With `copy = TRUE`: in A and in B the old version's files and manifest exist, the history holds the version's rows with the primary's `replaced` values, the manifest's `written` equals the primary's, and the current entry is unchanged (A: current version; B: no entry). `expect_store_valid()` holds. A following `store_read(version = <old>)` informs "Reading … from secondary". A second `copy = TRUE` adds no history rows.
- [ ] **B-T10 (guard).** `store_sample()`, `store_glimpse()`, `store_open()` (both engines; `skip_if_not_installed("duckdb")`) and `store_duckdb()` copy nothing: the secondary's catalog and file listing are unchanged. A `store_read()` of an index table by name copies nothing (D-B12).
- [ ] **B-T11 (guard).** A secondary made unavailable (as `test-sync.R:150-160`): the read succeeds from the primary, copies nothing, raises no error or warning.
- [ ] **B-T12 (red).** A secondary holding a version updated later than the primary's (written through a connection whose primary is that folder, after the primary's write): the read does not replace it, reads from the primary, and informs "holds a newer version" (`expect_message()`, then snapshot). Red: no such message.
- [ ] **B-T13 (red).** Two secondaries, both empty: one read copies to both; both catalogs hold the version; a counting stub on the primary (`local_backend_stub(uri = <primary>)` without `fail_at`) shows each data file fetched once (`be_get` rows of `stub$log` with a `part-` path: no path twice).
- [ ] **B-T14 (red).** A geospatial dataset with an index table: the secondary's catalog has the index entry after the read. A secondary that holds the dataset but not its index table receives the index. A raster dataset: copied, one data file.
- [ ] **B-T15 (red).** The copy fails: `local_backend_stub(uri = <secondary>, generic = "be_put", fail_at = 1)`. The read returns the data from the primary, a warning of class `rcs_warning_secondary_behind` mentions `datasets = "<name>"`, and the secondary's catalog is unchanged. A non-write error (mock `land_location()` with `local_mocked_bindings()` to raise a plain `rlang::abort()` with class `"other_error"`) propagates. Red: no copy is attempted, so no warning.
- [ ] **B-T16 (red until `copy` exists, then the efficiency guard).** With `rcs.trace = TRUE` and the secondary already current: `store_read()` and `store_read(copy = FALSE)` have the same `backend_call` and `catalog_read` counts and `bytes_up` 0.
- [ ] **B-T17 (guard for D-B9; passes today because nothing copies yet).** Empty secondary: `store_read()` with a raster argument on a tabular dataset (the check at `R/read.R:142-160`) aborts and the secondary is still empty; the same for an unknown dataset name and for a malformed `version` with `copy = TRUE`.
- [ ] Report: test names and lines, the red/green table, `session closed`.

#### WP4c. Edits to existing tests for Part B (test writer, Opus; after WP3-V)

Files: the tests on WP1's read list, `tests/testthat/test-objects.R:43`, `tests/testthat/test-connect.R:324`. Allowed edits only.

- [ ] Apply the edits.
- [ ] Run, each separately: `^read$`, `objects`, `connect`, `^write$`, `intersects`, `^sync$`, `integration`, `check`. Report each edited test with its failure reason (one of the reasons in the Rules) and every other test passing; `session closed`.

#### WP4-V. Red verification (verifier, Opus, fresh session; after WP4b and WP4c)

- [ ] Read the test diff, D-B1–D-B12 and "Results". Check that the tests encode the decisions, that every red test has a non-snapshot assertion and fails because nothing is copied or the message is missing (not because of a setup error: the setup of B-T1, B-T9 and B-T13 must run to the first new assertion), that B-T16 measures the right counters, and that edits to existing tests are among the allowed ones.
- [ ] Run `copy-on-read` and the filters of WP4c. Red tests red for the stated reason, guards green, edited tests failing only for the allowed reasons, nothing else failing. `git diff --stat -- R/` shows only Part A's files; no `*.new.md`.
- [ ] PASS or FAIL, `session closed`.

#### WP5a. Code for Part B, current version (code writer, Opus; after WP4-V)

Files: `R/read.R`, `R/sync.R`, `R/objects.R`, `R/connect.R`, `R/utils.R` (option default and the list at lines 12-15), `R/rcs-package.R` (option table). `R/resolve.R` is not changed.

- [ ] D-B1–D-B5 and D-B7–D-B12:
  - `R/sync.R`: refactor `store_copy()`'s body into one internal helper, `copy_unit(st, source, targets, dataset, ctx)` (builds the unit once, fresh manifests, then for each target `land_location()` and `landed_anyway()`; returns per target the landing figures or the error; prints nothing). `store_copy()` calls it with one target and keeps its messages and its aborts. No second copy body.
  - `R/read.R`: `copy_before_read(st, name, version, copy, call)`, `@noRd`, returns nothing and updates `st` in place; it reads `st$copy_on_read` and `rcs_option("rcs.copy_on_read_max_bytes")` at call time and calls `files_lacking()` and `copy_unit()`. `store_read()` calls it as D-B9 says. For an old version with `copy = TRUE` it calls `land_history()`, which WP5b writes: until then leave a clearly marked call site that does nothing.
- [ ] Run `copy-on-read` (all but B-T9's `copy = TRUE` part green) and the filters of WP4c until green. Accept snapshots as the Rules allow; do not change test code.
- [ ] Report: diff summary, counts per filter, `session closed`.

#### WP5b. Code for Part B, old versions and documentation (code writer, Opus; after WP5a)

Files: `R/sync.R` (`land_history()`), `R/read.R` (its call, the D-B6 message, roxygen), `R/connect.R`, `R/query.R`, `R/duckdb.R` (roxygen only).

- [ ] D-B6 as specified there.
- [ ] Roxygen: `store_read()` (argument `copy`; a section "Copy to secondary locations" with the rule of D-B1/D-B2, the limit, old versions and the `store_rebuild()` note, how to turn it off); `store_connect()` (argument `copy_on_read`, the empty-secondary notice); `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` say in one sentence that they never copy. Do not run `devtools::document()`.
- [ ] Run `copy-on-read`, `^read$`, `history` until green.
- [ ] Report: diff summary, counts, `session closed`.

#### WP5-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the `R/` diff of WP5a and WP5b against D-B1–D-B12. Look for: a backend call when no copy is needed; a copy to a cloud secondary or with a local primary; a copy from `store_sample()`/`store_glimpse()`/lazy reads; a newer secondary overwritten (no re-check after the refresh); a refresh outside the caught region; a failed copy that fails the read; a duplicated copy body; the limit compared with the wrong bytes or with `integer64`; an old manifest rewritten with a new `written`.
- [ ] Read the `_snaps/` diff against D-B6 and D-B7; `store_copy()`'s snapshots unchanged.
- [ ] Run, each separately: `copy-on-read`, `^read$`, `^sync$`, `resolve`, `integration`, `crash-points`, `query`, `duckdb`, `connect`, `objects`, `history`, `random-operations`, `^write$`, `intersects`, `check`.
- [ ] Mutation check (Rules), each followed by the `copy-on-read` file:
  - mock `copy_before_read()` to return `invisible()`: B-T1, B-T3, B-T4, B-T9 (copy part), B-T13 must fail;
  - wrap the original `copy_before_read()` so it runs under `withr::local_options(rcs.copy_on_read_max_bytes = Inf)`: B-T5 must fail;
  - wrap it so it sets `st$copy_on_read <- TRUE` first: B-T7 must fail.
  Report which failed; a mutation no test catches is reported as a gap and counts as FAIL.
- [ ] PASS or FAIL, `session closed`.

### WP6. Efficiency check (verifier, Opus, own session; after WP5-V; parallel with WP7)

No full benchmark. Script in the agent's scratchpad; nothing written to `bench/` or `output/`.

- [ ] Primary and secondary local folders under `tempdir()`, the primary simulated as cloud (as in WP4a's helper), a dataset of about 1e6 rows from `rcs_sim_table()` partitioned into about 10 files. Measure with `system.time()` (5 runs each, median), with `rcs.trace = TRUE` for the counters:
  1. `store_read()` through a primary-only connection (baseline);
  2. the first `store_read()` with an empty secondary (the secondary folder is rebuilt empty before each run);
  3. the second `store_read()` (secondary current);
  4. `store_read(copy = FALSE)` with the secondary current;
  5. `store_copy()` of the same dataset to an empty secondary.
- [ ] **PASS criteria (counters only):** (3) has `bytes_up` 0 and the same `backend_call` and `catalog_read` counts as (4); a default `store_sync()` against a secondary holding 1 of 20 small datasets has the same `backend_call` and `catalog_read` sums as `store_sync(datasets = "<that one>")`.
- [ ] **Reported, not gating:** the five medians; (2) against (5) plus (3); the two sync timings.
- [ ] Report the table, PASS or FAIL, `session closed`. A FAIL is routed to a fresh WP5a writer under the Rules.

### WP7. Documentation (writer, Opus; after WP5-V; parallel with WP6)

Files and required edits:

- `vignettes/locations.Rmd`: the text at lines 201-204 and 256-258 and the evaluated chunks at 263-271 (after `sales/weekly` is written through a primary-only connection, a default sync now skips it: show the default sync and its message, then `datasets =` or `all = TRUE`); a new section on the working-copy model.
- `vignettes/duckdb.Rmd:489-495`: `store_sync(st)` to an empty bucket becomes `store_sync(st, all = TRUE)`.
- `vignettes/articles/testing.Rmd`: lines 90-91 and 243 (sync repairs; mention `test-copy-on-read.R`).
- `README.Rmd`: one sentence on copy on read where secondary locations are mentioned; no edit (and no `build_readme()`) if they are not mentioned. `bench/spatial.R:547` (`all = TRUE`; not run). `bench/cloud.R` needs no change.
- `.docs/plans/0001-rcs-package.md`: lines 31, 72, 224, 252, 253, so they match D-A2 and D-B1/D-B2.

- [ ] Describe: the working-copy model (local secondary = working copy of a cloud primary); copy on read with its targets (D-B1), the 2 GB limit, `copy =`, `copy_on_read =`; that samples, glimpses and lazy reads stay remote; restricted sync, `all = TRUE`, the empty-secondary notice. Vignettes write only below `tempdir()`.
- [ ] Render each edited vignette with `devtools::load_all()` first, then `rmarkdown::render(<file>, output_dir = <folder under tempdir()>, envir = new.env())` in the same session, so the source package is used; it must run without error. Render `README.Rmd` with `devtools::build_readme()`.
- [ ] Report the files changed, the render results, `session closed`.

#### WP7-V. Documentation check (verifier, Opus, fresh session)

- [ ] Read the doc diff against D-A2, D-A4, D-A6, D-A7, D-B1, D-B2, D-B6. Render the edited vignettes as WP7 does and read the output of every chunk that calls `store_sync()` or `store_read()`: it must agree with the prose around it. `grep` the repo (outside `.docs/` except plan 0001) for remaining claims that a plain `store_sync()` copies missing datasets or repairs any secondary.
- [ ] PASS or FAIL, `session closed`.

### WP8. Release (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" and "Outcome", and sets the status to `done`, before the writer commits, so both go in one commit.
- [ ] One writer (Opus):
  - sets `Version: 0.0.0.9007` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed (`store_read.Rd`, `store_sync.Rd`, `store_connect.Rd`, `store_sample.Rd`, `store_glimpse.Rd`, `store_open.Rd`, `store_duckdb.Rd`, `store_write.Rd`, `store_status.Rd`, `rcs-package.Rd`, and any other the diff explains);
  - runs `testthat::test_local(filter = "copy-on-read|^sync$|^read$")` once more; no `*.new.md` under `tests/testthat/_snaps/`;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `DESCRIPTION`, `README.Rmd`, `README.md`, the edited vignettes and bench script, `.docs/plans/0001-rcs-package.md`, this plan);
  - commits with no email address and no AI attribution, for example `Plan 0005: store_read() copies datasets up to 2 GB to local secondaries of a cloud primary; store_sync() refreshes only the datasets a secondary holds (all = TRUE for every dataset); version 0.0.0.9007`;
  - does **not** push;
  - reports the commit hash, `git show --stat HEAD`, `git status` (clean), and `session closed`.
- [ ] The orchestrator checks the `git show --stat HEAD` list against the expected paths, then reports to the owner in a few bullets: what changed in sync and in reads, the tests with counts, the WP6 table, open questions.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- `store_status()` still reports datasets a secondary never held as `"missing"`. With the working-copy model a separate status (for example `"not held"`) might read better. Not in this plan.
- `store_rebuild()` of a secondary that holds only an old version of a dataset makes it the current entry (D-B6). Documented here; a marker for "history only" could avoid it. Not in this plan.
- The random-operations model uses `all = TRUE`, so it never exercises the restricted default.

## Results

### Facts established before execution (plan verification, 2026-11-27)

- **D-B6 probe.** An old version's files, unchanged manifest and history rows (with the primary's `replaced`) were placed in a secondary (a) holding the dataset at the current version and (b) not holding it. In both: `expect_store_valid()` passes; `store_check()` is unchanged (`ok` / `missing`); `store_read(version = <old>)` reads from the secondary; `store_prune(keep = 1)` keeps the rows and `keep = 0` removes files and manifest cleanly. `store_rebuild()`: (a) unchanged; (b) the old version becomes the current entry. A manifest rewritten with a new `written` makes `store_rebuild()` promote the old version even in (a): hence "copy the manifest unchanged". Duplicate history rows pass the invariants but must be avoided.
- **Test level.** `testthat::test_local()` and `devtools::test()` both run at level `default`. `^sync$`: 28 tests, about 150 s. `crash-points`: about 85 s.
- **Progress bar.** With `cli.progress_show_after = 0` and `rcs.quiet = FALSE`, `capture_messages()` gets one line per file, for example `<root>/s ===============>---------------  1/2 files`. At width 80 the path truncates the counter: use `local_reproducible_output(width = 300)`. The "files sent" line carries bytes and seconds: transform them in snapshots.
- **`copy =` today.** `store_read(st, "<name>", copy = FALSE)` (or `"yes"`) fails with a simple error, `filter expressions must be either an expression or a list of expressions`.
- **Random-operations model.** It checks reads through primary-only connections; it needs only `all = TRUE` at `helper-model.R:289, 369, 458`.

### Execution

(Filled in by the orchestrator: WP1's lists and answers, then each WP's verdict and counts.)

## Outcome

(Filled in at WP8.)
