# Copy on read to secondary locations; sync restricted to the datasets a secondary already holds

- **Date:** 2026-11-26
- **Author:** Eduard Bukin
- **Status:** draft

## Goal

When this plan is done:

1. **Part A (sync).** `store_sync()` to secondary locations, without `datasets`, refreshes only the datasets each secondary already holds. It says that only those were synced, how many datasets and how much data (files, bytes) a full sync would add, and that `all = TRUE` copies everything. `datasets = ` still copies the named datasets whether or not a secondary holds them. A sync whose target is the primary (`from = <secondary>`) still sends everything.
2. **Part B (copy on read).** `store_read()` of the current version of a dataset that a reachable secondary lacks, or holds at an older version, first copies the whole dataset to that secondary with the existing copy code, with a progress bar and a message, then reads from the copy. It does not copy when the download exceeds 2 GB (`rcs.copy_on_read_max_bytes`), for old versions, or when the connection or the call turns it off. In every one of those cases it reads only what it needs from the primary and says how to copy. `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` never copy.
3. Every change is test-driven: the tests are written first and shown to fail for the stated reason (red), then the code makes them pass (green). A separate verifier confirms each step.
4. The new code paths are shown to be efficient by work counters (`rcs_trace()`) and a short timing script. The full benchmark (`bench/`) is **not** re-run.
5. Version `0.0.0.9005`, committed (not pushed) once everything is green.

Decision record: `.docs/notes/0003-local-copy-on-read-and-restricted-sync.md`. Read it first. Its decisions are final; the decisions below only make them precise.

## Context

### What exists that this plan builds on

- **Choosing where a read comes from.** `choose_location()` in `R/resolve.R` (~line 92) picks, among available locations holding the dataset at the primary's version: local backends first, then the primary, then other secondaries. For an old `version` it checks `_history.parquet` and `be_exists()`. It informs `Reading "<dataset>" from secondary <uri>.` It makes no backend call for the current version.
- **Read entry point.** `read_target()` in `R/read.R` (~line 21) resolves the name, calls `choose_location()`, and finds entry and files. `store_read()` (~line 131), `store_sample()` (~line 237) and `store_glimpse()` (~line 339) all call it. `store_open()` is in `R/query.R`, `store_duckdb()` in `R/duckdb.R`.
- **Copying one dataset.** `store_copy()` in `R/sync.R` (~line 755) refreshes both locations' catalogs, builds a unit with `sync_unit()` (the dataset plus its index table), writes fresh manifests (`sync_fresh_manifests()`), and lands it with `land_location()` (`R/write.R` ~line 1435). `land_location()` sends only the files the target lacks (path + MD5 against its files and history), verifies MD5, puts manifests, then switches the catalogs under the write lock. Its upload goes through `upload_verified()` (`R/write.R` ~line 1374), which already shows a cli progress bar. On failure, `landed_anyway()` handles errors raised after the catalog switch.
- **Sync.** `store_sync()` (`R/sync.R` ~line 113) builds the units from the source (`sync_dataset_names()`; `NULL` = every dataset of the source that is not an index table), then plans per target with `sync_plan()` (~line 376): what to copy, conflicts (the target is newer, without `force`), overwrites, deletions. Output goes through `sync_header()`, `sync_line()`, `sync_footer()`. The result tibble is built by `sync_result()` / `sync_result_row()` / `sync_empty()`.
- **Connection object.** `new_store()` and `validate_store()` in `R/objects.R` (~line 109); the documented field table is above them (~line 91). `store_connect()` in `R/connect.R` (~line 68).
- **Options.** Defaults in `rcs_option()` (`R/utils.R` ~line 14–30), documented in the table in `R/rcs-package.R`. Grep `rcs.duckdb_stream` for every place an option is listed.
- **Bytes.** The catalog and file rows carry `bytes` (`R/schema.R`). `format_bytes()` (`R/utils.R` ~line 409) uses decimal units (1 GB = 1e9 bytes).
- **Work counters.** `R/trace.R`; counters in use include `backend_call`, `catalog_read`, `file_open`, `bytes_up`, `bytes_down`. Tests read them with `rcs_trace()` / `rcs_trace_reset()`.
- **Tests that depend on today's behaviour.** `store_sync(` appears in `tests/testthat/test-sync.R` (54 calls), `test-integration.R` (9), `test-crash-points.R` (3), `test-catalog.R` (2) and `helper-model.R` (4; the model of `test-random-operations.R`). Tests that read while a secondary is connected expect no copy. WP1 lists them exactly.
- **Docs that describe sync or secondaries:** `vignettes/locations.Rmd`, `vignettes/duckdb.Rmd`, `README.Rmd`; `bench/cloud.R` and `bench/spatial.R` call sync (they are not run in this plan; WP1 says whether they need `all = TRUE` to keep their meaning).

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh Opus session) runs **no code**: no R, and no Bash that builds, tests or edits. It may read files and git state (`git status`, `git diff`, `git log`). It spawns every work package as an Agent with `model: "opus"`, checks each report against the acceptance criteria, ticks the steps, and fills in "Results" and "Outcome". It edits only this plan file.
- **TDD cycle per part.** (1) A **test writer** adds tests only, with no change under `R/`. (2) A **red verifier** confirms in a fresh session that each new test fails for the reason stated in this plan, and that tests marked "guard" pass already. (3) A **code writer** changes `R/` until the tests pass. It may not weaken a test; a test it believes wrong goes back to the orchestrator with the reason. (4) A **green verifier** reads the diff with no prior conclusions, runs the tests and regressions, and runs a mutation check.
- Writers and verifiers are separate agents. Verifiers never edit files. Each verifier gets the acceptance criteria and the paths, not the writer's conclusions.
- **Existing tests whose expectations change** because of a decision here (full-sync default, reads that now copy) are edited by the test writer of that part, in the smallest way: add `all = TRUE`, `copy = FALSE` or `copy_on_read = FALSE`, so that the test keeps checking what it checked before. Never delete an expectation. The red verifier checks each such edit against WP1's list.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report ends with `session closed`. If one does not, the orchestrator sends a small agent to `quit()` that session.
- **Parallelism.** Part A code (`R/sync.R`) and Part B code (`R/read.R`, `R/resolve.R`, `R/objects.R`, `R/connect.R`, and helpers in `R/sync.R`) both touch `R/sync.R`, so the **code writers run strictly in sequence** (WP3 before WP5). The Part B test writer (WP4) may run in parallel with the Part A code writer (WP3), because its tests go in a new file. Part B tests that edit existing test files touched by Part A wait until WP3-V passes. WP6 (efficiency) and WP7 (docs) may run in parallel: they write different files.
- Never run the whole suite (more than 10 minutes). Use `devtools::load_all()` and `testthat::test_local(filter = "...")`.
- Tests use only data from `rcs_sim_*()` or small frames built in code. Every location goes under `withr::local_tempdir()`. Secondaries in tests are local folders; one test uses the stub backend (`helper-backend-stub.R`) for an unreachable secondary.
- R style: `r-lib:r-testthat`, `r-lib:r-cli`, `r-lib:r-tidyverse-style`. Messages use cli only, with the classes of the surrounding code (`rcs_error_argument`, `rcs_warning_secondary_behind`, ...). Internal helpers get the comment / `@noRd` block the file already uses.
- **No full benchmark.** Efficiency is shown by WP6 only.
- Commit at the end (WP8), staged by explicit paths. **No push** unless the owner asks.

### Decisions taken (do not ask the owner about these)

Part A, `store_sync()`:

- **D-A1. New argument `all = FALSE`**, placed after `datasets`. `TRUE` restores today's behaviour (every dataset of the source to every target). `all = TRUE` together with non-`NULL` `datasets` aborts with `rcs_error_argument`. `all` must be a flag (`check_flag()`).
- **D-A2. Default scope per target.** With `datasets = NULL` and `all = FALSE`, a target that is a **secondary** receives only the units whose dataset it already holds in its catalog, at any version. A target that is the **primary** (only when `from` is a secondary) receives every unit, as today. The rule lives in `sync_plan()` (or a helper it calls), per target. `delete = TRUE` is unchanged: deletions are not restricted by this rule.
- **D-A3. What was not copied.** For each secondary target, the units skipped by D-A2 are "not copied". Their size is the number and the bytes of the files of those units (index tables included) that the target does not already hold. It is computed from the catalogs held by the connection (source files table against the target's files and history, by path + MD5, as `land_location()` matches them) with **no backend call**. The result tibble gets two new columns, after `conflicts`: `skipped` (list of dataset names) and `skipped_bytes` (numeric). `files`/`bytes` keep their meaning (files sent).
- **D-A4. Message.** After the per-target lines and before the footer, when any secondary skipped datasets, one block per call (`rcs_inform()`, so `rcs.quiet` silences it):

  ```
  ℹ Synced only the datasets already in each secondary location.
  ℹ <secondary uri>: 41 datasets not copied (1,204 files, 86.3 GB).
    Use `store_sync(st, all = TRUE)` to copy every dataset.
  ```

  One `<uri>` line per secondary that skipped something; counts with `format_count()`, size with `format_bytes()`. With `dry_run = TRUE` the same block appears with "would be" wording, or the same wording; the writer picks one and snapshots it. No block when nothing was skipped.
- **D-A5. Status.** A target whose only difference from the source is skipped datasets has status `"same"` (nothing copied), not `"to sync"`.

Part B, copy on read:

- **D-B1. Where copies go.** To every secondary that is **available** at the time of the read and lacks the dataset or holds an **older** version of it. "Older" means: the secondary's entry has another version and its `updated` is not later than the primary's. A secondary holding a version updated later than the primary's (the sync conflict case) is never overwritten by a read: it is skipped, and the message suggests `store_sync()`. Copies go in connection order, each with `land_location()` on the unit built as `store_copy()` builds it (refactor `store_copy()`'s body into an internal helper both use; do not duplicate it).
- **D-B2. When `store_read()` copies.** Only when all hold: the read is of the current version (`version` is `NULL` or equals the primary's version); the connection's `copy_on_read` is `TRUE`; the call's `copy` is not `FALSE`; at least one secondary needs the copy (D-B1); and the bytes to download do not exceed the limit (D-B3), unless `copy = TRUE`. Filters, `columns` and `intersects` do not change the rule. Raster datasets follow the same rule (their one file counts).
- **D-B3. Limit.** New option `rcs.copy_on_read_max_bytes`, default `2e9` (2 GB, decimal as `format_bytes()`). The bytes measured are those of the files (dataset and index table) that the secondary needing the most lacks, computed from the held catalogs with no backend call (reuse the D-A3 helper). Above the limit: no copy.
- **D-B4. New argument `store_read(copy = NULL)`**, placed after `version`. `NULL` follows D-B2. `TRUE` copies regardless of the limit, the connection setting and the version (old versions: D-B6). `FALSE` never copies. Anything else aborts with `rcs_error_argument`.
- **D-B5. New argument `store_connect(copy_on_read = TRUE)`**, a flag, stored on the connection as `st$copy_on_read` (add it to `new_store()`, `validate_store()` and the field table in `R/objects.R`). `store_refresh()` keeps it. When `FALSE`, reads neither copy nor print a hint.
- **D-B6. Old versions.** `store_read(version = <old>)` never copies by default and informs:

  ```
  ℹ Read version 3f9a1c0d2b4e5f60 of "sales/daily" from <uri>; old versions are not copied to secondary locations.
    Use `copy = TRUE` to copy it.
  ```

  With `copy = TRUE`, the old version's files and manifest are copied to each available secondary that lacks them, and its file rows are recorded in that secondary's `_history.parquet`, **not** as its current version. The secondary's current entry (if any) is unchanged. WP1 checks how this fits the invariants (`helper-invariants.R`, `store_check()`, `store_prune()`, `store_rebuild()`), in particular when the secondary does not hold the dataset at all. If a history row without a current entry breaks an invariant, `copy = TRUE` for an old version copies only to secondaries that hold the dataset, and for the others informs that the old version cannot be copied there. WP1's finding decides; the orchestrator records it in "Results" before WP4.
- **D-B7. Messages** (all through `rcs_inform()`; texts are the writer's, snapshotted, close to these):
  - Copy: `ℹ Copying "sales/daily" (version <v>, 12 files, 340 MB) from <primary> to <secondary> before reading.` then the existing progress bar of `upload_verified()`, then `✔ 12/12 files sent (340 MB) in 4.2 s, MD5 verified.` The existing `Reading "sales/daily" from secondary <uri>.` line follows from `choose_location()`.
  - Above the limit: `ℹ "sales/daily" needs 3.4 GB, above the 2 GB limit for copying on read (`rcs.copy_on_read_max_bytes`). Reading from <primary>.` then `Use `copy = TRUE`, or `store_sync(st, datasets = "sales/daily")`, to copy it.`
  - Newer secondary skipped: `! <secondary> holds a newer version of "sales/daily"; it is not replaced. See `store_sync()`.` (inform, not warn).
- **D-B8. Failure of the copy.** A copy that fails (backend error of a write class) does not fail the read: a warning of class `rcs_warning_secondary_behind` says the copy failed and that the next read or `store_sync()` will retry, and the read goes on from the primary. Errors that are not write-class errors propagate, as in `sync_location()`. A failure after the catalog switch is handled with `landed_anyway()`.
- **D-B9. Order inside `store_read()`.** The copy runs before the location is chosen, so the read then comes from the fresh copy through the existing `choose_location()` order. Implement it as a step in `read_target()` gated by an argument (for example `copy = FALSE` by default), which only `store_read()` sets. `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` do not set it and are unchanged.
- **D-B10. Catalog freshness.** The copy step uses the catalogs held by the connection to decide whether a copy is needed (no backend call when nothing is needed). When it copies, it refreshes the source and that target first (as `store_copy()` does) and leaves `st` updated in place.
- **D-B11. No secondary.** With no secondary location, nothing changes from today: no message, no write anywhere.

- **D-V. Version `0.0.0.9005`.** There is no NEWS.md; do not create one.

## Steps

### WP0. Preflight (orchestrator, no code)

- [ ] `git log -1` shows plan 0004's release commit and `DESCRIPTION` says `0.0.0.9004`. Otherwise stop and report to the owner.
- [ ] `git status` is clean (this plan, note 0003 and handoff 0004 were committed with the plan). Otherwise ask the owner.
- [ ] Set this plan's status to `active`.

### WP1. Survey (investigator, Opus, may run R; no edits to the repo)

Scripts go in the agent's scratchpad.

- [ ] **Sync-dependent tests.** List every test (file, line, `test_that` name) whose expectations rely on `store_sync()` copying datasets a secondary does not hold, including `helper-model.R` and the random-operations model. For each, say which edit keeps its meaning (`all = TRUE`, or a named `datasets`).
- [ ] **Read-dependent tests.** List every test that reads (`store_read()`) with a secondary connected and asserts something a copy would change: the secondary's catalog, `store_status()`, trace counters, "Reading from secondary" lines, snapshots, crash points. For each, the minimal edit (`copy = FALSE` on the call, or `copy_on_read = FALSE` on the connection).
- [ ] **Old version into history (D-B6).** Read `helper-invariants.R`, `store_check()`, `store_prune()`, `catalog_rebuild()` and `files_unreferenced()`. Try, in a scratch store, appending an old version's rows to a secondary's `_history.parquet` (by the existing catalog helpers) (a) where the secondary holds the dataset at another version and (b) where it does not hold it. Report what breaks, and recommend the D-B6 branch.
- [ ] **Bytes to download.** Confirm that the files table and history of a location give path, MD5 and bytes for every file, so D-A3/D-B3 need no backend call. Name the helper to write (inputs, output).
- [ ] **Progress bar.** Confirm that `upload_verified()`'s progress bar shows during a copy to a local secondary, and how a test can see it (for example `options(cli.progress_show_after = 0, cli.dynamic = FALSE)` with `expect_snapshot()`), or say it cannot be seen reliably.
- [ ] **Benches and docs.** Say whether `bench/cloud.R` and `bench/spatial.R` need `all = TRUE` to keep measuring what they measure. List the sections of `vignettes/locations.Rmd`, `vignettes/duckdb.Rmd` and `README.Rmd` that describe sync or secondaries.
- [ ] Report the lists, the D-B6 recommendation, and `session closed`. The orchestrator copies the facts into "Results".

### Part A. Sync restricted to datasets a secondary holds

#### WP2. Red tests for Part A (test writer, Opus)

Files: `tests/testthat/test-sync.R` (new tests together under a comment `# Plan 0005: sync restricted to held datasets`), and the existing tests on WP1's sync list (minimal edits only). No change under `R/`.

Each `test_that()` is named by the behaviour; its comment states the expected red reason.

- [ ] **A-T1 (red).** Primary with three datasets; a secondary holding one of them at an older version. Default `store_sync()` brings that one to the primary's version and copies neither of the other two. The result has `skipped` = the two names and `skipped_bytes` = the sum of their file bytes from the primary's files table. Red: both are copied; the columns do not exist.
- [ ] **A-T2 (red).** Snapshot of the message of A-T1 with `rcs.quiet = FALSE` (D-A4), and of a sync where nothing was skipped (no block). Red: no block.
- [ ] **A-T3 (red, then guard).** `all = TRUE` copies every dataset, and the resulting catalogs equal what a full sync gives today (compare versions and file sets). Red: unused argument `all`.
- [ ] **A-T4 (guard).** `datasets = "<name>"` copies that dataset to a secondary that does not hold it.
- [ ] **A-T5 (red).** `all = TRUE` with `datasets` aborts with `rcs_error_argument`; `all = NA` and `all = "yes"` abort. Snapshot the first message.
- [ ] **A-T6 (red + guard).** Work written on a secondary (a new dataset and an update of an existing one) and `store_sync(st, from = <secondary>)`: the primary receives both (guard); a second secondary that does not hold the new dataset does not receive it (red).
- [ ] **A-T7 (red).** Empty secondary, default sync: nothing copied, status `"same"`, `skipped` lists every dataset, the message gives the full size.
- [ ] **A-T8 (red).** `dry_run = TRUE` reports the restricted plan and the skipped datasets with their size, and changes nothing on disk (compare the secondary's catalogs before and after).
- [ ] **A-T9 (guard).** `delete = TRUE` deletes from a secondary the datasets the source no longer holds, as before.
- [ ] **A-T10 (red).** Efficiency: with `rcs_trace()`, a default sync to a secondary that holds one dataset makes no more backend calls and catalog reads than `store_sync(st, datasets = "<that one>")`. Red: today the default copies the others, so the counts are higher.
- [ ] Apply the minimal edits to the existing tests on WP1's sync list.
- [ ] Run `testthat::test_local(filter = "^sync$")`, then each of `integration`, `crash-points`, `catalog`, `random-operations` separately. Report each new test red or green with the first line of its failure; report that every edited existing test still passes.
- [ ] Report: test names, file and line, the red/green table, the edited tests, `session closed`.

#### WP2-V. Red verification (verifier, Opus, fresh session)

- [ ] Read only the test diff, D-A1–D-A5 and note 0003. Check that the tests encode the decisions, and that no test depends on another test's state.
- [ ] Check each edit to an existing test against WP1's list: only `all = TRUE` or `datasets =` was added; no expectation removed or weakened.
- [ ] Run the same filters. Every red test fails for the reason in its comment; every guard passes; every edited existing test passes. `git diff --stat -- R/` is empty.
- [ ] PASS or FAIL with reasons, then `session closed`. On FAIL, the orchestrator resumes the WP2 writer with the findings and repeats WP2-V.

#### WP3. Code for Part A (code writer, Opus)

Files: `R/sync.R`.

- [ ] D-A1–D-A5. Write the D-A3 size helper so Part B can reuse it (inputs: source files rows of some units, target location; output: files and bytes the target lacks). Update the roxygen of `store_sync()`: the new argument, the default scope, the new result columns, an example with `all = TRUE`. Do not run `devtools::document()` yet (WP8 does).
- [ ] Run `testthat::test_local(filter = "^sync$")` and the regression filters of WP2 until green. Do not edit tests; a test thought wrong goes to the orchestrator.
- [ ] Report: diff summary, counts, `session closed`.

#### WP3-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the `R/` diff with no prior conclusions against D-A1–D-A5. Look for: a backend call added to the size computation; a primary target wrongly restricted; deletions changed; `dry_run` writing anything.
- [ ] Run, each separately, reporting counts and failures verbatim: `^sync$`, `integration`, `crash-points`, `catalog`, `history`, `inspect`, `random-operations`, `connect`.
- [ ] Mutation check, in the R session only (never edit files): with `local_mocked_bindings()` or `assignInNamespace()`, make the D-A2 rule return every unit (today's behaviour): A-T1, A-T6 (red part), A-T7, A-T10 must fail. Make the size helper return 0: A-T1 and A-T2 must fail. Report which tests failed.
- [ ] PASS or FAIL, then `session closed`. On FAIL, route to the WP3 writer (resume it if possible) and repeat WP3-V.

### Part B. Copy on read

#### WP4. Red tests for Part B (test writer, Opus; may run in parallel with WP3)

Files: new `tests/testthat/test-copy-on-read.R`. The edits to existing tests on WP1's read list wait until WP3-V has passed if they are in a file WP2 edited. No change under `R/`.

Helpers: a primary and one or two local secondaries under `withr::local_tempdir()`, connected with `store_connect(primary, secondary = ...)`. Datasets from `rcs_sim_table()`, `rcs_sim_points()` / `rcs_sim_polygons()` (with an index table), and the raster simulator if it exists.

- [ ] **B-T1 (red).** Empty secondary: `store_read()` returns the same data as a read with no secondary; afterwards the secondary's catalog holds the dataset at the primary's version, with the same file MD5s. Snapshot the messages with `rcs.quiet = FALSE` (copy line, sent line, "Reading from secondary" line). Red: the secondary stays empty.
- [ ] **B-T2 (red, or skipped with the reason WP1 gave).** The progress bar shows during the copy (WP1's method).
- [ ] **B-T3 (red).** A second read of the same dataset copies nothing and transfers no file: `bytes_up` is 0 and no copy message appears; it reads from the secondary. Red: the first read never copied, so the second does not read from the secondary.
- [ ] **B-T4 (red).** After the dataset is updated on the primary (`mode = "update"` changing one partition), the next read copies the new version and sends only the changed files (assert the sent count against the changed partitions).
- [ ] **B-T5 (red).** With `options(rcs.copy_on_read_max_bytes = <below the dataset's size>)`: no copy; the data equal a read from the primary; the message of D-B7 is snapshotted. The same with a filter (`...`) and with `columns`.
- [ ] **B-T6 (red).** `copy = TRUE` copies above the limit; `copy = FALSE` never copies (with an empty secondary); `copy = "yes"` and `copy = NA` abort with `rcs_error_argument`.
- [ ] **B-T7 (red).** `store_connect(..., copy_on_read = FALSE)`: no copy, no hint message; `st$copy_on_read` is `FALSE`; `store_refresh()` keeps it. `copy_on_read = "no"` aborts.
- [ ] **B-T8 (guard).** No secondary: `store_read()` writes nothing outside the primary (list the temp folder before and after) and prints no copy line.
- [ ] **B-T9 (red).** Old version (store with history; two versions): `store_read(version = <old>)` copies nothing, returns the old data, and informs as in D-B6 (snapshot). With `copy = TRUE`, the branch WP1 chose: the old version's files and manifest land in the secondary, its history holds the version's rows, its current entry is unchanged, and a following `store_read(version = <old>)` reads from the secondary (inform line). When WP1 restricted D-B6, also test the "cannot be copied there" message.
- [ ] **B-T10 (guard).** `store_sample()`, `store_glimpse()`, `store_open()` (both engines, if DuckDB is installed; `skip_if_not_installed("duckdb")`) and `store_duckdb()` copy nothing: the secondary's catalog is unchanged.
- [ ] **B-T11 (red).** Unreachable secondary (stub backend, or a secondary made unavailable at connection): the read succeeds from the primary, copies nothing and raises no error.
- [ ] **B-T12 (red).** A secondary holding a version updated later than the primary's: the read does not replace it, reads from the primary, and informs as in D-B7 (snapshot).
- [ ] **B-T13 (red).** Two secondaries, both empty: one read copies to both; both catalogs hold the version.
- [ ] **B-T14 (red).** A geospatial dataset with an index table: the index table travels with the copy (the secondary's catalog has the index entry). A raster dataset (if the simulator exists, else skip with reason): copied as one file.
- [ ] **B-T15 (red).** The copy fails (mock the landing helper with `local_mocked_bindings()` to raise a write-class error): the read returns the data from the primary, a `rcs_warning_secondary_behind` warning is raised, and the secondary's catalog is unchanged. A non-write error from the mock propagates.
- [ ] **B-T16 (red).** Efficiency: with `rcs_trace()`, deciding that no copy is needed (secondary already current) adds no `backend_call` and no `catalog_read` compared with the same read with `copy = FALSE`.
- [ ] Apply the minimal edits to the existing tests on WP1's read list.
- [ ] Run `testthat::test_local(filter = "copy-on-read")`, then each of `^read$`, `resolve`, `integration`, `crash-points`, `query`, `duckdb`, `connect`, `objects` separately. Report the red/green table, the edited tests, and `session closed`.

#### WP4-V. Red verification (verifier, Opus, fresh session)

- [ ] As WP2-V, for D-B1–D-B11 and the D-B6 branch in "Results". Check in particular that B-T1 fails because nothing is copied (not because of a setup error), that B-T16 measures the right counters, and that every edit to an existing test only adds `copy = FALSE` or `copy_on_read = FALSE`.
- [ ] PASS or FAIL, `session closed`.

#### WP5. Code for Part B (code writer, Opus; after WP3-V)

Files: `R/read.R`, `R/resolve.R` (only if needed), `R/sync.R` (refactor `store_copy()`'s body into a shared helper; the D-A3 helper is reused), `R/objects.R`, `R/connect.R`, `R/utils.R` (option default), `R/rcs-package.R` (option table), and any place WP1 found that lists the options.

- [ ] D-B1–D-B11. Keep `read_target()` readable: the copy step is one internal function (for example `copy_before_read(st, name, version, copy, call)`), documented with `@noRd`, that returns nothing and updates `st` in place.
- [ ] Roxygen: `store_read()` (argument `copy`, a section "Copy to secondary locations" with the rule, the limit, old versions, how to turn it off); `store_connect()` (argument `copy_on_read`); `store_sample()`, `store_glimpse()`, `store_open()` and `store_duckdb()` say in one sentence that they never copy. Do not run `devtools::document()` yet.
- [ ] Run `testthat::test_local(filter = "copy-on-read")` and the regression filters of WP4 until green. Do not edit tests.
- [ ] Report: diff summary, counts, `session closed`.

#### WP5-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the diff against D-B1–D-B11. Look for: a backend call when no copy is needed; a copy from `store_sample()`/`store_glimpse()`/lazy reads; a newer secondary overwritten; a failed copy that fails the read; a duplicated copy body instead of the shared helper; the limit compared with the wrong bytes.
- [ ] Run, each separately: `copy-on-read`, `^read$`, `^sync$`, `resolve`, `integration`, `crash-points`, `query`, `duckdb`, `duckdb-tbl`, `connect`, `objects`, `history`, `random-operations`.
- [ ] Mutation check (session only): make the copy step a no-op: B-T1, B-T3, B-T4, B-T9 (copy part), B-T13 must fail. Make the limit check always pass: B-T5 must fail. Ignore `copy_on_read`: B-T7 must fail. Report which failed; any mutation no test catches is reported as a gap.
- [ ] PASS or FAIL, `session closed`.

### WP6. Efficiency check (verifier, Opus, own session; after WP5-V; parallel with WP7)

No full benchmark. Script in the agent's scratchpad; nothing written to `bench/` or `output/`.

- [ ] Primary and secondary local folders under `tempdir()`, a dataset of about 1e6 rows from `rcs_sim_table()` partitioned into about 10 files. Measure with `bench::mark()` or `system.time()` (5 runs each, median):
  1. `store_read()` with no secondary (baseline);
  2. the first `store_read()` with an empty secondary (copy + read);
  3. the second `store_read()` (secondary current);
  4. `store_read(copy = FALSE)` with the secondary current.
- [ ] Expected: (3) and (4) within 1.2 times (1) (reading local files; no extra work); (2) about (1) plus a copy of the files (report the copy time against a plain `file.copy()` of the same files; within 2 times). `rcs_trace()` for (3) shows `bytes_up` 0 and no `catalog_read` beyond (4).
- [ ] Default `store_sync()` against a secondary holding 1 of 20 small datasets: time and counters equal (within noise) to `store_sync(datasets = "<that one>")`; the skipped-size computation adds no backend call.
- [ ] Report the table, PASS or FAIL against the expectations, `session closed`. On FAIL the orchestrator decides whether to route back to WP5.

### WP7. Documentation (writer, Opus; after WP5-V; parallel with WP6)

Files: `vignettes/locations.Rmd`, `vignettes/duckdb.Rmd` (only if WP1 listed it), `README.Rmd`, `bench/cloud.R` and `bench/spatial.R` (only the `all = TRUE` edits WP1 asked for; not run), `.docs/plans/0001-rcs-package.md` (the section describing sync and reads from secondaries, so it matches D-A2 and D-B2).

- [ ] Describe: the working-copy model (secondary = working copy, primary = full store); copy on read with the 2 GB limit, `copy =`, `copy_on_read =`; that samples, glimpses and lazy reads stay remote; restricted sync and `all = TRUE`. Vignettes write only below `tempdir()`.
- [ ] Render `vignettes/locations.Rmd` (and any other edited vignette) to a folder under `tempdir()` with `rmarkdown::render()`; it must run without error. Render `README.Rmd` with `devtools::build_readme()`.
- [ ] Report the files changed, the render results, `session closed`.

### WP8. Release (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" and "Outcome", and sets the status to `done`, before the writer commits, so both go in one commit.
- [ ] One writer (Opus):
  - sets `Version: 0.0.0.9005` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed (`store_read.Rd`, `store_sync.Rd`, `store_connect.Rd`, `store_sample.Rd`, `store_glimpse.Rd`, `store_open.Rd`, `store_duckdb.Rd`, `rcs-package.Rd`, and any other the diff explains);
  - runs `testthat::test_local(filter = "copy-on-read|^sync$|^read$")` once more;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `DESCRIPTION`, `README.Rmd`, `README.md`, the edited vignettes and bench scripts, `.docs/plans/0001-rcs-package.md`, this plan);
  - commits with no email address and no AI attribution, for example `Plan 0005: store_read() copies datasets up to 2 GB to secondary locations; store_sync() refreshes only the datasets a secondary holds (all = TRUE for every dataset); version 0.0.0.9005`;
  - does **not** push;
  - reports the commit hash, `git status` (clean), and `session closed`.
- [ ] The orchestrator reports to the owner in a few bullets: what changed in sync and in reads, the tests with counts, the WP6 table, open questions.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- `store_status()` still reports datasets a secondary never held as `"missing"`. With the working-copy model a separate status (for example `"not held"`) might read better. Not in this plan.

## Results

(Filled in by the orchestrator: WP1 facts and the D-B6 branch, then each WP's verdict and counts.)

## Outcome

(Filled in at WP8.)
