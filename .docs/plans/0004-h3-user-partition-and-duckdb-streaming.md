# User `h3_p<r>` partitions on update; streaming lazy DuckDB table writes by partition

- **Date:** 2026-11-23
- **Author:** Eduard Bukin
- **Status:** done

## Goal

When this plan is done:

1. **Part A (bug 1).** `mode = "update"` works on every dataset partitioned by a user column, whatever its name. That includes `h3_p<r>` columns, character or `integer64`, on tables and on geospatial data. The values of a user partition column are taken as given: never recomputed and never compared with the computed parent. The catalog records whether a partition is the automatic `"h3"` one or a user column. Datasets written with `partition = "h3"` behave exactly as before. The update message shows character `h3_p<r>` values correctly.
2. **Part B (bug 2).** A partitioned write of a lazy DuckDB **table** (not geospatial) streams one partition at a time. Peak DuckDB memory plus spill is bounded by about the largest partition, not by the whole input. A test shows this under a DuckDB memory cap, and a benchmark shows it at scale. The files are identical to those of the materialising path and of the same rows written from R (same version).
3. Every change is test-driven: the tests are written first and shown to fail for the stated reason (red), then the code makes them pass (green). A separate verifier confirms each step.
4. Version `0.0.0.9004`, committed and pushed after the owner's OK.

Bug record and reproduction: `.docs/notes/0002-bug-h3-user-partition-update-and-duckdb-streaming.md`. Read it first.

## Context

### Cause (established 2026-11-23, see the note)

- The catalog field `partition` holds the written column names. Both `partition = "h3"` (automatic; written as `h3_p<res>`, resolution chosen by `max_files`) and a user column called `h3_p3` give `"h3_p3"`.
- `stage_update()` in `R/write.R` (~line 630) guesses from the name: `is_h3 <- length(old_partition) == 1 && grepl("^h3_p[0-9]+$", old_partition)`. It then requires `partition = "h3"`, drops and re-plans the column with `partition_plan(data, "h3", h3_max_res = res_old)`, and lets the update re-partition when `max_files` is exceeded (`repartition && !is_h3`). It does this even for `kind == "table"`.
- `partition_plan_h3()` / `check_supplied_partition()` in `R/files.R` (~lines 180–240) compare a supplied `h3_p<r>` column with the computed parents. A character column always "differs".
- `format_partition()` in `R/write.R` (~line 1107) renders any `h3_p<r>` value with `h3_as_hex(bit64::as.integer64(...))`. A character value gives `NA` plus a warning.
- `stage_duckdb()` in `R/write-duckdb.R` (~line 129) calls `duckdb_materialise()`, which copies the whole query into `rcs_write_<random>` with a `.rcs_tmp` row number (D37). The key check (`duckdb_check_key()`), the distinct partition values, the stream `ORDER BY partition, key, .rcs_tmp` (`duckdb_write_files()`) and the serialization check (`duckdb_check_files()`, run later from `store_write()` step 8 through `plan$check`, D40) all read that copy.

### What exists that this plan builds on

- `schema_optional` in `R/schema.R` is how a catalog column was added before (`geocode_engine`, plan 0002). A catalog file without the column reads with `NA`, validates, and is written back with it. `tests/testthat/test-catalog.R` (~line 424) shows how a test fakes an old catalog file.
- Catalog entries are built in `files_meta()` / `files_finish()` (`R/files.R` ~lines 483–630, 726), `R/catalog.R` (~line 627), and the DuckDB stagers (`R/write-duckdb.R`). Every place that passes `geocode_engine =` is a place that must pass the new field. Grep `geocode_engine =` in `R/` for the full map; it includes `R/sync.R` and `R/history.R` if they build entries.
- The meaning of each catalog column is documented in `.docs/plans/0001-rcs-package.md`, section "Catalog schema" (~line 75).
- `"update"` from a lazy DuckDB table aborts by design (D36, `check_duckdb_mode()`). That stays: this plan does not add DuckDB updates.
- Plan 0003 (geocoding) is active and edits `R/geo-encode.R`. This plan does not touch that file, but it starts only after plan 0003 is committed (WP0), so that the version numbers and the test baselines are clean.

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh Opus session) runs **no code**: no R, and no Bash that builds, tests or edits. It may read files and git state (`git status`, `git diff`, `git log`). It spawns every work package as an Agent with `model: "opus"`, checks each report against the acceptance criteria, ticks the steps, and fills in "Results" and "Outcome". It edits only this plan file.
- **TDD cycle per part.** (1) A **test writer** adds the tests only: no change under `R/`. (2) A **red verifier** confirms in a fresh session that each new test fails for the reason stated in this plan. Tests marked "guard" must pass already. (3) A **code writer** changes `R/` until the tests pass. It may not weaken a test; a test it believes wrong goes back to the orchestrator with the reason. (4) A **green verifier** reads the diff with no prior conclusions, runs the tests and regressions, and runs a mutation check.
- Writers and verifiers are separate agents. Verifiers never edit files. Each verifier gets the acceptance criteria and the paths, not the writer's conclusions.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report ends with `session closed`. If one does not, the orchestrator sends a small agent to `quit()` that session.
- Part A and Part B edit overlapping files (`R/write.R`, the catalog builders, `R/write-duckdb.R`), so their writers run strictly in sequence, in the main working tree. Only WP3 (read-only diagnosis) may run in parallel with Part A.
- Never run the whole suite (more than 10 minutes). Use `devtools::load_all()` and `testthat::test_local(filter = "...")`.
- Tests use only data from `rcs_sim_*()` or small frames built in code (as in the existing tests). Stores go under `tempdir()`/`withr::local_tempdir()`. The bigger DuckDB tables in Part B are built inside DuckDB from `rcs_sim_table()` rows (D-B5).
- R style: `r-lib:r-testthat`, `r-lib:r-cli`, `r-lib:r-tidyverse-style`. Messages use cli only, with error classes as in the surrounding code (`rcs_error_argument`, `rcs_error_key`, `rcs_error_check`). Internal helpers get the comment / `@noRd` block the file already uses.
- No commit and no push before the owner's OK (WP6).

### Decisions taken (do not ask the owner about these)

Part A:

- **D-A1. New catalog column `partition_auto`** (`arrow::boolean()`, added to `catalog_schema()` after `partition` and to `schema_optional$catalog`). `TRUE`: the partition was chosen by `partition = "h3"`. `FALSE`: the partition columns are user columns. `NA`: no partition, or a catalog written before this plan. Written on every create and replace. An update rewrites it with the resolved value (D-A2). The internal index tables (`stage_index()`, `duckdb_stage_index()`, written with `partition = "h3"` when large) get `TRUE`.
- **D-A2. Resolving an existing dataset's partition**, in one helper, `partition_is_auto(entry, spec)` (in `R/write.R` or `R/files.R`, next to the partition code):
  - `partition_auto` not `NA`: use it.
  - `NA` (legacy) and no partition: `NA`.
  - `NA` and `kind == "table"`: `FALSE` (a table can never have the automatic partition).
  - `NA` and geospatial: `TRUE` only if there is exactly one partition column, it matches `^h3_p[0-9]+$`, and its stored type is a cell (`integer64` / `rcs_h3` in `spec`). Otherwise `FALSE`. This keeps the old behaviour for genuine automatic datasets.
- **D-A3. The `partition` argument on update** is compared with the stored partition as it would be given on create: `"h3"` when automatic, else the column names.
  - It may be left out: the stored partition is used.
  - A legacy dataset inferred automatic (D-A2, `NA`) that receives exactly its stored column names (e.g. `partition = "h3_p3"`) is taken as a user partition. That is the only way to rescue a legacy user `integer64` `h3_p3`. The entry is then written with `FALSE`.
  - A dataset whose catalog says `TRUE` and receives `"h3_p3"`, or says `FALSE` and receives `"h3"`, aborts. The abort is as today, class `rcs_error_argument`, and the `i` line names the stored partition as it would be given: `"h3"` (written as `h3_p5`), or `h3_p3`.
- **D-A4. A user partition is never recomputed.** On the sf path of `stage_update()`, when the partition is a user one: no `supplied_partition` dance, `check_update_columns()` treats the column like any other stored column, and `partition_plan(data, <columns>)` is called with the column names, never `"h3"`. `check_supplied_partition()` is reached only for `partition = "h3"`. Exceeding `max_files` aborts as for any user column (the existing `repartition && !is_h3` branch, keyed on the resolved flag).
- **D-A5. Create is unchanged apart from recording the flag**: `partition = "h3"` gives `TRUE`; any column names give `FALSE`, even `"h3_p3"` whose values equal the parents. The D27 behaviour (a supplied column named as the chosen automatic partition must equal the computed parents) stays for `partition = "h3"` only.
- **D-A6. `format_partition()`** renders a `h3_p<r>` value as a hex cell only when the JSON value is a number (an `integer64` written as a JSON number or numeric string of digits). A character value such as `"831e5afffffffff"` is shown as it is, with no warning. Decide by the value's form, not by the catalog, so that `store_history()` and other callers need no entry.
- **D-A7. Reading is unchanged.** `h3_classify()` already converts only `integer64` columns, so a character user `h3_p3` stays character. An `integer64` user `h3_p3` read as `rcs_h3` is fine: it holds cells.
- **D-A8. Docs.** `store_write()` roxygen, section "Modes" / `partition`: on update, `partition` may be left out; if given it must be what was given on create (`"h3"` or the column names); user `h3_p<r>` columns are kept as given. Add the `partition_auto` row to the "Catalog schema" table of `.docs/plans/0001-rcs-package.md`, marked "(added in plan 0004)". Editing that table is allowed; the plan files are never renamed.

Part B:

- **D-B1. When to stream.** A lazy DuckDB **table** write (no `geometry` column) with a non-empty user `partition` streams by partition. Without `partition` it materialises as today: one file needs the whole sort anyway. A geospatial lazy write is unchanged (out of scope, see "Open questions"). Opt-out: `options(rcs.duckdb_stream = FALSE)`, default `TRUE`. Add it with the other `rcs.*` options and their documentation (grep `rcs.duckdb_batch_rows` for the places).
- **D-B2. Streamed steps**, with `q` the rendered SQL of `x`, run as a subquery and never copied whole:
  1. `DESCRIBE SELECT * FROM (q) LIMIT 0`, for the columns, the types, the dropped package columns and `check_duckdb_types()`, as today.
  2. `SELECT DISTINCT <partition> FROM (q)` → `partition_plan()` on the distinct values (same checks and messages as today). Order the groups as `partition_plan()` orders them.
  3. Global key check without a copy: `SELECT <key>, count(*) FROM (q) GROUP BY <key> HAVING count(*) > 1 LIMIT 6`, plus the `NA`-key check. Same messages and classes as `duckdb_check_key()`; refactor that function to take a `FROM` clause rather than duplicate it.
  4. For each partition: `CREATE TEMPORARY TABLE rcs_write_<random>_part AS SELECT *, row_number() OVER () AS ".rcs_tmp" FROM (q) WHERE <col> IS NOT DISTINCT FROM ? AND ...`. Bind the values as parameters, never pasted as text; the types are integer, double, VARCHAR, DATE, BOOLEAN and BIGINT. Then write that partition's file with the existing `duckdb_write_files()` (`ORDER BY key, .rcs_tmp`). Then run the serialization check of that file against that table (D-B3). Then drop the table before the next partition. The drop is deferred to the end of `store_write()` as well, so a failure leaves no table.
  5. One progress bar over all rows (the total is the sum of the per-partition counts; the bar may grow its total as partitions arrive).
- **D-B3. The serialization check moves into the loop** for streamed writes: right after each file, with the same sampling as `duckdb_check_file()`. `plan$check` then returns the collected per-file results, so `store_write()` step 8 reports them exactly as today. With `check = FALSE` the in-loop check is skipped. The writer reads how `check` reaches `stage_duckdb()` (`a$...`) and passes it through if it does not yet.
- **D-B4. Determinism.** The streamed files must equal the materialised ones byte for byte (same `version`). With a key, `ORDER BY key` is total. Without a key, the order within a partition is the input order restricted to the partition. That holds when the query is deterministic and DuckDB preserves insertion order (the default). Document in the roxygen "DuckDB input" section: the query runs `2 + P` times (P partitions), so it must be deterministic and is best a scan of stored files or views. Writing without a key under `preserve_insertion_order = false` is not deterministic. WP3 settles what happens then (D-B6).
- **D-B5. Test data for the memory test.** Built inside DuckDB: `rcs_sim_table()` rows registered with `duckdb::duckdb_register()`, then multiplied with `CROSS JOIN range(k)` into a wide synthetic table with a new unique `id` and a partition column of P values. No raw data. WP3 calibrates the sizes.
- **D-B6. `preserve_insertion_order = false`.** WP3 first finds why the check fails today ("columns id, … differ from x"). If the cause is a check that compares rows by position on an unordered scan, fix the check to compare rows ordered by key, or by `.rcs_tmp` when there is no key, in both paths. If the write itself is non-deterministic without a key, abort early with a clear `cli_abort()` when the connection has `preserve_insertion_order = false` and there is no key. Read the setting with `SELECT current_setting('preserve_insertion_order')`. The WP3 report decides which, and the orchestrator records it in "Results" before WP4.
- **D-B7. Staging.** Not changed in this plan. The roxygen "DuckDB input" section says that setting `options(rcs.staging_dir = )` to a folder on the store's drive avoids a cross-drive copy, and that staged files need room equal to the output.

- **D-V. Version `0.0.0.9004`.** There is no NEWS.md; do not create one.

## Steps

### WP0. Preflight (orchestrator, no code)

- [x] Plan 0003 is `done` and committed (`git log` shows its release commit; `DESCRIPTION` says `0.0.0.9003`). If not, stop: report to the owner and wait.
- [x] `git status` is clean apart from this plan and note 0002. Otherwise ask the owner.
- [x] Set this plan's status to `active`.

### Part A. User `h3_p<r>` partitions on update

#### WP1. Red tests for Part A (test writer, Opus)

Files: `tests/testthat/test-write.R` (update section; put the new tests together under a comment `# Plan 0004: user h3_p<r> partitions`), `tests/testthat/test-catalog.R` (legacy file), `tests/testthat/test-write.R` or the file that tests `format_partition()` (grep it). No change under `R/`.

Each `test_that()` is named by the behaviour. Its comment states the expected red reason, which the red verifier checks.

- [x] **A-T1 (red).** Table, character `h3_p3` (the note's `x`/`y`): create with `partition = "h3_p3"`, then update with `partition = "h3_p3"`. Success; reading back gives the 7 rows with `h3_p3` unchanged and character; the catalog has `partition = "h3_p3"` and `partition_auto = FALSE`. Red: "Stored partition: h3".
- [x] **A-T2 (red).** Same as T1, update without `partition`. Red: `partition = "h3"` needs geocoded geospatial data.
- [x] **A-T3 (red).** sf points (build them in code, or take a few from `rcs_sim_points()`) with a character `h3_p3` in which at least one row deliberately differs from its computed res-3 parent. Create with `partition = "h3_p3"`. Then update with rows that add a new partition and replace an existing one, (a) with `partition = "h3_p3"` and (b) without it. Success. Every row's `h3_p3` reads back exactly as written, the deliberate mismatch included. The file set matches the partition values; `partition_auto = FALSE`. Red: (a) "Stored partition: h3"; (b) "differs from the partition column the write computes".
- [x] **A-T4 (red).** Same as T3 with `h3_p3` as `rcs_h3` (`new_rcs_h3(...)`) and a deliberate mismatch, update with and without `partition`. The values are kept. Red: (a) "Stored partition: h3"; (b) "differs from the partition column".
- [x] **A-T5 (guard, passes now).** sf with `partition = "h3"`: create, update with `partition = "h3"` and update without it. Same files and messages as before; the catalog partition is `h3_p<r>`. Plus a red part: `partition_auto` is `TRUE`.
- [x] **A-T6 (guard, passes now).** sf with `partition = "h3"` and an update that exceeds `max_files` re-partitions to a coarser resolution as before. Find the existing test of this; if one exists, reference it in a comment instead of duplicating it.
- [x] **A-T7 (red).** Mismatches abort with class `rcs_error_argument`: an automatic dataset updated with `partition = "h3_p5"` (its own written column), and a user `h3_p3` dataset updated with `partition = "h3"`. Snapshot the two messages with `expect_snapshot(error = TRUE)`; the `i` line names the stored partition as given on create. Red: the first currently aborts with "Stored partition: h3" (same text, so the snapshot is new), the second currently passes the comparison and fails later with a different error. The red verifier checks the reason, not just a failure.
- [x] **A-T8 (red).** Legacy catalog, following the `geocode_engine` test in `test-catalog.R` (~line 424): write three datasets, then rewrite `_catalog.parquet` without `partition_auto`.
  - (i) A table with character `h3_p3`: update without `partition` succeeds.
  - (ii) An sf with automatic `"h3"`: update without `partition` behaves as automatic.
  - (iii) An sf with a user `rcs_h3` `h3_p3` holding a deliberate mismatch: update with `partition = "h3_p3"` succeeds, keeps the values, and the catalog afterwards says `FALSE`.
  - After any write, the catalog file has the column.
  - Red: (i) and (iii) as in T1/T4; the column assertions because it does not exist.
- [x] **A-T9 (red).** `format_partition('{"h3_p3":"831e5afffffffff"}')` is `"h3_p3 = 831e5afffffffff"`, with no warning (`expect_no_warning`). An automatic `integer64` value still renders as hex, matching the existing expectation. Snapshot the update message of A-T1 (`expect_snapshot()` with `rcs.quiet = FALSE`). Red: `NA` plus a coercion warning.
- [x] **A-T10 (red).** `partition_is_auto()` unit tests covering every row of D-A2.
- [x] Run `testthat::test_local(filter = "^write$|catalog")` (or the filters that select exactly these files). Report each new test as red or green, with the first line of its failure.
- [x] Report: test names, file and line, the red/green table, `session closed`.

#### WP1-V. Red verification (verifier, Opus, fresh session)

- [x] Read only the test diff, D-A1–D-A8 and the note. Check that the tests encode the decisions and the reporter's acceptance criteria 1–3, and that no test depends on another test's state.
- [x] Run the same filters. Every test marked red fails, and fails for the reason in its comment; every guard passes. `git diff --stat -- R/` is empty.
- [x] PASS or FAIL with reasons, then `session closed`. On FAIL, the orchestrator resumes the WP1 writer with the findings and repeats WP1-V.

#### WP2. Code for Part A (code writer, Opus)

Files: `R/schema.R`, `R/files.R`, `R/write.R`, `R/catalog.R`, `R/write-duckdb.R` (only to record the flag), `R/sync.R` / `R/history.R` if they build entries, `.docs/plans/0001-rcs-package.md` (the catalog table only).

- [x] D-A1: add the column to the schema and to `schema_optional`; thread `partition_auto` through `files_meta()` and every builder that sets `geocode_engine`. Set it in `stage_full()` (from `identical(a$partition, "h3")` before it is resolved), in `stage_duckdb()` (`FALSE`), in `stage_duckdb_geo()` (`TRUE` for `"h3"`), and in the index stagers.
- [x] D-A2: `partition_is_auto()`.
- [x] D-A3, D-A4: rewrite the partition block of `stage_update()` around the resolved flag. Keep the variable names that the rest of the function uses, or rename them consistently. The comment above the block cites plan 0004.
- [x] D-A6: `format_partition()`.
- [x] D-A8: roxygen of `store_write()`; the "Catalog schema" row in plan 0001. Do not run `devtools::document()` yet (WP6 does).
- [x] Run `testthat::test_local(filter = "^write$|catalog|schema")` until green. Do not edit tests; a test thought wrong goes to the orchestrator.
- [x] Report: diff summary per file, counts, `session closed`.

#### WP2-V. Green verification (verifier, Opus, fresh session)

- [x] Read the `R/` diff with no prior conclusions against D-A1–D-A8. Look in particular for any remaining name-based `grepl("^h3_p...")` decision on the write or update path that should use the flag instead. The read-side classifier and `rcs_geo_strip()` stay name-based on purpose.
- [x] Run, each separately, reporting counts and failures verbatim: `^write$`, `catalog`, `schema`, `sync`, `history`, `write-duckdb`, `geo-verbs`, `read`, `integration`, `random-operations`, `crash-points`. One file over 10 minutes may run as a pre-approved long job in the agent's own session.
- [x] Re-run the note's reproduction (table and sf; scratch script under the agent's scratchpad) and confirm every row of its table now behaves as the plan says.
- [x] Mutation check, in the R session only (never edit files): with `local_mocked_bindings()` or `assignInNamespace()`, make `partition_is_auto()` return the old name-based answer. A-T1–A-T4, A-T8 and A-T10 must fail. Restore `format_partition()` to the old body: A-T9 must fail. Report which tests failed.
- [x] PASS or FAIL, then `session closed`. On FAIL, route to the WP2 writer (resume it if possible) and repeat WP2-V.

### Part B. Streaming lazy DuckDB table writes

#### WP3. Diagnosis and calibration (investigator, Opus, read-only; may run in parallel with WP1–WP2)

No edits to the repo; scripts go in the agent's scratchpad.

- [x] **Memory today.** Build a synthetic table inside DuckDB (D-B5), for example 4e6 rows × 20 double columns plus `id` and a partition column of 16 values. Write it with the current code under `SET memory_limit = '<m>'`, `SET temp_directory = '<tmp>'` and `SET max_temp_directory_size = '<t>'`. Find small `m`/`t` values at which the current path fails with an out-of-memory error while one partition alone would fit (try writing one partition's rows only). The test must run in under 60 s, so report sizes, settings and timings that make a test fast and robust, and a second, larger set for the benchmark.
- [x] **preserve_insertion_order.** Reproduce "columns id, … differ from x" with `SET preserve_insertion_order = false` on a keyed and an unkeyed synthetic table. Find the exact line and the cause (check comparing by position? write order changing?). Recommend the D-B6 branch.
- [x] **Re-scan cost.** Time `SELECT DISTINCT`, the `GROUP BY key` check and one filtered partition over a parquet-backed view of the synthetic table. Report whether filter pushdown makes the per-partition scans cheap.
- [x] Report the facts, the recommended test parameters, the D-B6 branch, and `session closed`. The orchestrator copies the facts into "Results" and fixes the parameters for WP4.

#### WP4. Red tests for Part B (test writer, Opus)

Files: `tests/testthat/test-write-duckdb.R` (use `helper-duckdb.R`'s helpers), no change under `R/`.

- [x] **B-T1 (red).** Under the WP3 memory/spill caps, a partitioned keyed write of the synthetic table succeeds. Assert row count, file count = P, and that the read-back equals the DuckDB table (sorted by `id`). `skip_on_cran()`. Red: DuckDB out-of-memory error, wrapped or not. Assert that it is the memory error, not some other failure.
- [x] **B-T2 (red, after D-B1).** With `options(rcs.duckdb_stream = FALSE)` the same write fails as today. Red: the option does not exist, so it currently fails the same way; mark this test's red reason as "same failure as today; becomes a guard after WP5".
- [x] **B-T3 (guard).** Equality across paths, on uncapped small data (`rcs_sim_table(2000)`, partitions `year` and a two-column partition, keyed and unkeyed): the streamed write, the write with `rcs.duckdb_stream = FALSE` and the same rows collected and written from R give the same catalog `version` and identical file MD5s. It passes now trivially (both DuckDB modes are the same code) and must stay green.
- [x] **B-T4 (guard).** A duplicate key across two partitions aborts with the same class and snapshot message as today. An `NA` key aborts the same way.
- [x] **B-T5 (red).** No `rcs_write_%` table is left on the connection after a successful streamed write, nor after a failure in the middle (mock the file writer to fail on the second partition with `local_mocked_bindings()`). Query `duckdb_tables()` / `information_schema.tables`. Red: the per-partition tables do not exist yet, so to be red, assert that during a streamed write the largest temp table never exceeds one partition's rows. The writer may do this with a mocked `duckdb_write_files()` that records `SELECT count(*)` of the table it reads.
- [x] **B-T6 (red or guard, per D-B6).** `preserve_insertion_order = false`: keyed write succeeds and equals the default write; unkeyed write either succeeds identically or aborts with the new clear message, as WP3 decided.
- [x] **B-T7 (guard).** A non-partitioned lazy write and a geospatial lazy write are unchanged (an existing test may cover this; reference it).
- [x] **B-T8 (red).** Partition values of each supported type (integer, double, VARCHAR with a quote and a space, DATE, BOOLEAN, BIGINT) round-trip through the streamed path, binding values as parameters (a value like `O'Brien` must work).
- [x] Run `testthat::test_local(filter = "write-duckdb")`; report the red/green table and `session closed`.

#### WP4-V. Red verification (verifier, Opus, fresh session)

- [x] As WP1-V, for D-B1–D-B7 and the reporter's criterion 5. Check in particular that B-T1 fails with the memory error and not with something else, and that it runs in under 60 s.
- [x] PASS or FAIL, `session closed`.

#### WP5. Code for Part B (code writer, Opus)

Files: `R/write-duckdb.R`, the option defaults and their docs (grep `rcs.duckdb_batch_rows`), `R/write.R` roxygen ("DuckDB input"), possibly `R/write.R` step 8 if `check` must be passed through.

- [x] D-B1–D-B4, D-B6 (the branch WP3 chose), D-B7 (roxygen only).
- [x] Keep `stage_duckdb()` readable: split it into `stage_duckdb_materialised()` (today's body) and `stage_duckdb_streamed()`, sharing the describe/type/key/partition helpers. No behaviour change for the materialised path.
- [x] Run `testthat::test_local(filter = "write-duckdb")` until green. Do not edit tests.
- [x] Report: diff summary, counts, the B-T1 timing, `session closed`.

#### WP5-V. Green verification (verifier, Opus, fresh session)

- [x] Read the diff against D-B1–D-B7. Look for SQL built by pasting values; for a temp table that can leak; and for a path where `check = FALSE` still checks, or `check = TRUE` skips the check.
- [x] Run, each separately: `write-duckdb`, `write-duckdb-geo`, `duckdb`, `duckdb-tbl`, `duckdb-file`, `^write$`, `query`, `integration`.
- [x] Mutation check (session only): force the materialised path from `stage_duckdb()` (mock the stream decision to `FALSE`): B-T1 and B-T5 must fail. Make the in-loop check a no-op: some test must fail. If none does, report it as a gap.
- [x] PASS or FAIL, `session closed`.

#### WP5-B. Benchmark (verifier, Opus, own session, long job pre-approved; after WP5-V passes)

- [x] Add `bench/write-stream.R`, in the style of `bench/write.R` and `bench/harness.R`. It uses the WP3 large parameters (a synthetic table of several GB built in DuckDB, P = 16–32 partitions, keyed by `id`) with a capped `memory_limit` and `max_temp_directory_size` (the cap is below the whole table and above the largest partition). It runs streamed and materialised, records success/failure, wall time, rows, the largest partition's size, and DuckDB memory sampled after each partition (`SELECT sum(memory_usage_bytes) FROM duckdb_memory()`) plus the size of the temp folder. Results go to `output/tables/bench-write-stream.csv`.
- [x] Expected: streamed succeeds and its peak memory plus spill is on the order of the largest partition; materialised fails or peaks near the whole table. Report the table. If streamed does not meet the bound, report FAIL with the numbers. The orchestrator then decides whether to route back to WP5.
- [x] `session closed`.

### WP6. Report, then release on the owner's OK (orchestrator + one writer)

- [x] The orchestrator fills in "Results", then reports to the owner in a few bullets: cause, Part A fix, Part B design, tests with counts, the benchmark table. It then **waits for the owner's OK**.
- [ ] On OK, one writer (Opus):
  - sets `Version: 0.0.0.9004` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed;
  - runs `testthat::test_local(filter = "^write$|catalog|write-duckdb")` once more;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `bench/write-stream.R`, `output/tables/bench-write-stream.csv`, `DESCRIPTION`, `.docs/plans/0001-rcs-package.md`, this plan, note 0002);
  - commits with no email address and no AI attribution, e.g. `Plan 0004: user h3_p<r> partitions keep their values on update (catalog partition_auto); lazy DuckDB table writes stream by partition; version 0.0.0.9004`;
  - pushes `main`;
  - reports the commit hash, `git status` (clean) and `session closed`.
- [x] The orchestrator sets the status to `done` and fills in "Outcome" before the writer commits, so both go in one commit.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- **Streaming geospatial lazy writes** (and `partition = "h3"` from DuckDB, which needs the global cell map first). Out of scope; the reporter's wide table is a plain table. Proposed follow-up plan.
- **`"update"` from a lazy DuckDB table** (D36). Still aborts. With Part A done, a caller can write partition by partition from R (`collect()` one partition, `"create"` then `"update"`). Each update of a table re-reads the keys of the kept files (`check_key_across()`), which is O(rows) per update. Worth measuring if the owner wants this route documented.
- **Staging footprint.** The output still sits on disk twice (staging plus store). A streamed write could upload each file as soon as it is staged and checked, because nothing is visible before the catalog switch. That changes the stage→check→upload order of `store_write()`, so it needs an owner decision.
- **Arrow Dataset / parquet path input.** Not requested as a must; not planned.
- **(Added by the orchestrator, 2026-11-23) Version change for partitioned datasets.** `partition_auto` (TRUE/FALSE) is embedded in the parquet metadata, so from 0.0.0.9004 every partitioned dataset rewritten with the same data gets a new MD5 and version. Unpartitioned datasets are unchanged (the flag is omitted when `NA`). The alternative is to keep the flag in the catalog and manifest only; a rebuild would then fall back to D-A2 inference.
- **(Added) D-B6 Option A.** Every lazy DuckDB write forces `preserve_insertion_order = true` for its duration and restores the caller's value afterwards. The alternative was to abort when the setting is `false`.
- **(Added) `NA` key values.** A single `NA` key is accepted today, from R and from DuckDB alike; only a repeated one aborts. The plan assumed a check that does not exist. Should an `NA` key abort?
- **(Added) `check_results()` fails open** (`R/write-duckdb.R:291`): a problem whose partition name does not match a file would be reported "ok". No such case exists today; a small hardening fix is possible.

## Results

Filled in by the orchestrator per work package: PASS/FAIL, counts, deviations from the decisions (with the reason), timings, WP3 facts.

- **WP0 (2026-11-23):** PASS. Plan 0003 `done`, committed in `5f9ed1e`; `DESCRIPTION` 0.0.0.9003; tree clean at `fe68904`.
- **WP1 (2026-11-23):** written; tests only, `R/` unchanged.
  - `test-write.R`: A-T1–A-T7, A-T9 and A-T10 at lines ~385–620, with helpers at ~291–383. `test-catalog.R`: A-T8 (i)–(iii) at ~585–630, sharing the fixture `local_legacy_partition_store()`.
  - `^write$`: 52 tests, 11 fail, all of them new. `^catalog$`: 25 tests, 3 fail, all new. Every test marked red fails for the reason the plan gives; no existing test fails.
  - A-T5 is split into a guard (green; it adds a new snapshot section to `_snaps/write.md`) and a red test for `partition_auto = TRUE`.
  - A-T6 refers to the existing test "an update of partition = \"h3\" beyond max_files re-partitions the dataset" rather than duplicating it.
  - A-T7 and the A-T9 message test have no snapshot yet: explicit expectations stop them before the snapshot runs. Their snapshots appear on the first green run, and WP2/WP2-V must review them.
  - A-T9 lives in `test-write.R`, because no test file covered `format_partition()` before.
- **WP1-V (2026-11-23):** PASS.
  - `^write$`: 52 tests, 11 red. `^catalog$`: 25 tests, 3 red. Every failure matches its stated reason; the guards pass; `R/` is empty in the diff.
  - Gaps it found, routed back to the WP1 writer: D-A4 (a user `h3_p3` that exceeds `max_files` aborts); the `partition_auto` value right after create (D-A1/D-A5); the A-T5 dataset misnamed `points/user`.
- **WP1, follow-up (2026-11-23):** three tests added to `test-write.R`, all red because `partition_auto` does not exist yet.
  - Line ~654 (D-A4, 4 cases): expects `rcs_error_argument` with the existing user-column message `Partitioning by h3_p3 would give N files, more than max_files`. Today it gets `Stored partition: h3`, or `rcs_error_prepared` "differs from …".
  - Line ~688 (D-A1/D-A5): after create, the flag is `NA` with no partition, `FALSE` for `year`, `FALSE` for an sf `h3_p3` equal to its parents, `TRUE` for `"h3"`.
  - Line ~710 (D-A1, index): 150 `rcs_sim_polygons()` with `rows_per_group = 1` give an `h3_p3`-partitioned index table, which must say `TRUE`.
  - The A-T5 dataset is renamed `points/auto` and its snapshot re-recorded.
  - Not covered: `duckdb_stage_index()`, whose tests live in `test-write-duckdb-geo.R`, outside WP1's files.
  - `^write$`: 55 tests, 14 red. `^catalog$`: 25 tests, 3 red.
- **WP1-V, follow-up round (2026-11-23):** PASS.
  - The three new tests fail for their stated reasons, the guard passes, and the snapshots are unchanged by the run.
  - The D-A4 message is the existing user-column abort at `R/write.R` ~718–725. While red, only the first two of its four cases run; that is accepted.
  - Minor, accepted: the title of the create-flag test says "TRUE for \"h3\"", but that TRUE is asserted by the test at l. ~518.
- **WP2 (2026-11-23):** code in place, not green on first pass.
  - Counts: `^write$` 4 of 444 expectations fail, `catalog` 4 of 150, `schema` 2 of 146, `write-duckdb` 0 of 273.
  - The writer reported four test-side errors and left the tests as they were. The orchestrator checked them and routed them to the test writer:
    1. **Plan error.** A-T1, A-T2 and A-T8 (i) expected 7 rows. An update replaces every partition present in `x` (roxygen "Modes"), so the result is 5 rows, ids 1–3 and 6–7. The "7 rows" in A-T1 above is wrong.
    2. The A-T8 fixture stripped the flag only from `_catalog.parquet`, not from the manifests, so `expect_store_valid` failed. A real legacy store has the flag nowhere.
    3. `test-schema.R:39` hardcodes the catalog column list.
    4. `test-schema.R:385` (geocode_engine omitted when `NA`). **Deviation, accepted:** `partition_auto` is also omitted from embedded metadata and manifests when `NA` (`entry_omitted_when_na`). This keeps the files of unpartitioned datasets byte-identical to earlier versions (D30).
  - The new snapshots read correctly:
    - A-T7: `i Stored partition: "h3" (written as h3_p5).` and `i Stored partition: h3_p3.`
    - A-T9: `* h3_p3 = 831e5cfffffffff: 2 rows -> 2 rows`
- **WP1, correction round (2026-11-23):** the four test errors are fixed. With the WP2 code: `schema` 24/24, `catalog` 25/25, `^write$` 55/55.
  - A-T1, A-T2 and A-T8 (i) now expect 5 rows, ids `c(1:3, 6:7)`, with `h3_p3` as given and character.
  - The legacy fixture also strips `partition_auto` from every `_manifest-<version>.json`. The embedded parquet metadata keeps the flag: the store check compares only manifests with the catalog, and rewriting files would change their MD5s.
  - `test-schema.R` gains the column in its list; the omitted-when-`NA` test now covers both `partition_auto` and `geocode_engine`, with checks added and none loosened.
- **WP2-V (2026-11-23):** FAIL, on one stale snapshot only. The Part A logic is clean.
  - Passing filters: `^write$` 445, `catalog` 153, `schema` 148, `sync` 245 (+1 skip), `history` 102, `write-duckdb` 273, `geo-verbs` 97, `integration` 110, `random-operations` 26 (+1 skip), `crash-points` 173 (+5 skips), all with 0 failures.
  - `read`: 1 failure. `_snaps/read.md:43` has `Version: 1ee64570`, now `5ee47480`. Cause, confirmed by mocking: the flag embedded as TRUE/FALSE changes the MD5 and version of partitioned datasets. **Accepted** as a consequence of D-A1 and flagged to the owner: from 0.0.0.9004 every partitioned dataset gets a new version even with the same data. Routed to the WP2 writer to accept the snapshot.
  - `man/store_write.Rd` is not regenerated. Expected: `devtools::document()` runs at WP6.
  - Diff review:
    - No name-based decision remains on the write/update path. The remaining `grepl("^h3_p")` calls are legacy inference in `partition_is_auto()`, the value check in `format_partition()`, and the read side.
    - Every entry builder records the flag, and a rebuild restores it.
    - The D-A3 legacy rescue sits at `R/write.R:649`.
  - The note's reproduction behaves as planned in every row.
  - Mutation (a), name-based `partition_is_auto()`: A-T1, A-T2, A-T3a/b, A-T4a/b, A-T10, A-T7, the A-T9 message test, the D-A4 test and A-T8 (i) fail. A-T8 (ii) and (iii) survive, by design (the mutant gives the same answer; the rescue runs outside the helper).
  - Mutation (b), old `format_partition()`: both A-T9 tests fail.
- **WP2, follow-up, and WP2-V repeat (2026-11-23):** PASS.
  - The `read` snapshot was accepted; its only change is the version hash.
  - Counts: `read` 322/322, `schema` 148/148, `^write$` 445/445, `catalog` 153/153, all with 0 failures. Part A is done.
- **WP4 (2026-11-23):** written; tests only, in `test-write-duckdb.R` from line ~573.
  - Helpers: `duck_wide_view()`, `local_duckdb_capped()`, `duck_write_table_rows()`, `local_writer_spy()`, `duck_md5()`. The spy wraps `duckdb_write_files(...)`, records the size of every `rcs_write_%` table present, and can fail call i.
  - The 17 existing tests stay green. Red now: B-T1 (`duckdb_error` "Out of Memory Error", 1.2 s), B-T5 (one writer call instead of one per partition; 300 > 156 rows), B-T6 (`A path is named twice`) and B-T8 (the spy again, for every type).
  - B-T2 passes already (the OOM). Guards green: B-T3 (34 s), B-T4 (new snapshot section in `_snaps/write-duckdb.md`) and B-T7.
  - B-T6 data: 3e5 rows as a stored table, P = 4. That reproduces 3/3, where 1e5 rows do not.
  - B-T8 values round-trip today. Its red part is the streaming spy; bound parameters are shown only through `O'Brien x` working.
  - **Plan correction (D-B2 step 3, B-T4):** the plan speaks of an "`NA`-key check", but none exists: `duckdb_check_key()` checks repeats only, and a single `NA` key is accepted from R and from DuckDB alike. The guard keeps today's behaviour: a repeated `NULL` key aborts with `rcs_error_key`, and a single `NULL` key writes as from R. No new `NA`-key abort is added.
- **WP4-V (2026-11-23):** PASS.
  - `write-duckdb$`: 25 tests in 2.0 min. The 17 existing tests and the 5 guards pass; the 4 red tests fail for their stated reasons. B-T1 fails with the DuckDB OOM from `duckdb_materialise()` in 1.23 s.
  - The writer spy passes a correct D-B2 implementation and fails the materialised path.
  - Notes: the test cap (100 MB + 50 MB spill) is well above one partition (about 11 MB), so the tight bound of criterion 5 is left to WP5-B. The in-loop footer check on the streamed path has no direct test; the WP5-V mutation check must show one.
- **WP5 (2026-11-23):** code in place.
  - `stage_duckdb()` now dispatches to `stage_duckdb_materialised()` (the old body) or `stage_duckdb_streamed()`. Shared helpers: `duckdb_describe()`, `duckdb_partition_values()`, `duckdb_table_meta()`, `duckdb_check_problem()`, the progress helpers. `duckdb_check_key()` now takes a FROM source.
  - Option A is `duckdb_local_insertion_order()`, deferred to the `store_write()` frame; it covers every lazy write, geospatial included.
  - `check` is now in `args` (`R/write.R`). The option `rcs.duckdb_stream` lives in `R/utils.R` and `R/rcs-package.R`. The roxygen "DuckDB input" section covers D-B4, D-B6 and D-B7.
  - Distinct values come from one `GROUP BY` with counts. Partition values are bound with `params =`. Each partition is staged in its own subfolder.
  - **Deviation (allowed by the brief):** keyed streamed partitions drop `.rcs_tmp` and order by key only. B-T3 shows the MD5s stay identical.
  - Counts: `write-duckdb$` 25 tests, 2 old tests failing (below); B-T1 to B-T8 all pass, B-T1 in 19.7 s under the caps. `write-duckdb-geo` 152/152, `^write$` 445/445, `^utils$` 121/121.
  - The two old failing tests encode the single-copy partitioned write, routed to the WP4 writer:
    - l. ~289 expects one `rcs_write_%` table alive during landing. Its write now runs with `rcs.duckdb_stream = FALSE`, plus a streamed counterpart that expects none.
    - l. ~367 expects one `duckdb_batches()` pass over all rows. It now expects one pass per partition, summing to n.
  - Progress-bar rows are now reported at batch boundaries.
- **WP4, follow-up (2026-11-23):** both old tests are adjusted; `write-duckdb$` passes 269/269 expectations in 25 tests.
- **WP5-V (2026-11-23):** PASS, 0 failures in every filter.
  - Counts: `write-duckdb$` 269, `write-duckdb-geo` 152, `^duckdb$` 136 (+1 GCS skip), `duckdb-tbl` 78, `duckdb-file` 54, `duckdb-intersects` 160, `^write$` 445, `query` 87, `integration` 110.
  - Mutations:
    - (a) Forcing the materialised path fails B-T1, B-T5, B-T8 and the two adapted tests.
    - (b) An in-loop check that never finds a problem fails "check = TRUE detects a staged file altered by the writer", so there is no gap.
    - (c1) Without the `preserve_insertion_order` restore, B-T6 fails.
    - (c2) Without the per-partition drop, 14 tests error.
  - Probes: TIMESTAMP, TIMESTAMPTZ, DECIMAL, FLOAT, SMALLINT and UTINYINT partitions give the same version in both paths. NULL or TIME partitions and zero rows abort the same way in both. An error mid-loop restores the setting and leaves no table.
  - Minor, open (not fixed): `check_results()` (`R/write-duckdb.R:291`) maps problems to files by name. A missing name would read as "ok" (it fails open), but that does not happen today.
- **WP5-B (2026-11-23):** PASS, full size: 2e7 rows × 22 columns, about 3.44 GB, P = 32, keyed. Caps 1GB memory and 2GB spill. DuckDB 2.0.0, 8 cores, 31.8 GB RAM. New files: `bench/write-stream.R` and `output/tables/bench-write-stream.csv`.

  | mode | status | wall s | largest partition | peak memory + spill | ÷ largest partition | ÷ whole table |
  |---|---|---|---|---|---|---|
  | streamed | ok, 32 files | 227 | 625k rows, 107.5 MB | 119 MB (no spill) | 1.11 | 0.035 |
  | materialised | OOM: `failed to offload data block … (1.8 GiB/1.8 GiB used)` | 14 | same | ≥ 583 MB polled; about 2.8 GB from the error (1 GB memory + 1.8 GiB spill) | ≥ 5.4 | ≈ 0.8 |

  - The materialised peak in the CSV (583 MB) is a lower bound: the run fails inside `duckdb_materialise()`, before any sampling point.
- **WP3 (2026-11-23):** done, repo untouched. DuckDB 2.0.0, R 4.6.2, 8 threads. Helper script (not in the repo) had `make_view()`, `caps()`, `probe()`.
  - **Synthetic data (D-B5), as a generator view, not a stored table.** A stored in-memory table counts against `memory_limit` (4e6 rows used 726 MiB), which would distort the caps. Register `rcs_sim_table(1e4)[, c("shop_id","qty","price")]` plus a row index `b = 0..n-1` as `sim_base`, then
    `CREATE VIEW wide_v AS SELECT (b*k + r.range)::BIGINT AS id, ((b*k + r.range) % P)::INTEGER AS part, (price*j + r.range*0.001 + qty)::DOUBLE AS d<j> (j = 1..20) FROM sim_base CROSS JOIN range(k) r`. `id` is unique and deterministic.
  - **Test parameters (B-T1/B-T2):** n = 1e4, k = 100 → 1e6 rows × 22 columns, P = 16 (62,500 rows per partition). Caps: `SET memory_limit = '100MB'; SET max_temp_directory_size = '50MB'; SET temp_directory = <tempdir>`; threads left unset (same result for 1, 2, 4, 8).
    - Today the keyed partitioned write fails in about 1 s, 3/3 repeats, at every thread count and every spill cap from 0 to 150MB. It passes only from `memory_limit` 350MB (3.5× the cap).
    - One partition alone passes from 40MB (2.5× headroom). The global key check passes from 44MB (2.3×; the tightest streamed step). `SELECT DISTINCT` and one filtered temp table pass at 16MB.
    - Uncapped, today's write takes 21 s (17 s with `check = FALSE`). A streamed estimate under the caps (key check, distinct, then 16 one-partition writes) took 30.6 s in total, under the 60 s limit.
    - Error: raw DuckDB, not wrapped: class `duckdb_error`, `error_type == "OUT_OF_MEMORY"`, raised at `duckdb_materialise()` (`R/write-duckdb.R:219`), called from `stage_duckdb()` at line 133. Text: `Out of Memory Error: failed to offload data block of size 256.0 KiB (47.5 MiB/47.6 MiB used). This limit was set by the 'max_temp_directory_size' setting.` Match it with `class = "duckdb_error"` and `regexp = "Out of Memory Error"`.
  - **Benchmark parameters (WP5-B):** n = 1e4, k = 2000 → 2e7 rows × 22 columns (about 3.5 GB raw; 3.8 GiB as a materialised temp table), P = 32 (625k rows, about 110 MB, per partition). Caps: `memory_limit = '1GB'`, `max_temp_directory_size = '2GB'`.
    - Today it fails with the same OOM after 22 s.
    - Each streamed step fits under the caps: key check 1.9 s, distinct 0.6 s, one partition's temp table 0.9 s, one-partition write 9.5 s. Expected streamed total about 5 min.
  - **`preserve_insertion_order = false`:** the cause is the write order, not the check.
    - In DuckDB 2.0.0, a top-level `ORDER BY` reaches R out of order under this setting, through `dbGetQuery`, `duckdb_fetch_record_batch()` and `duckdb_frame()` alike.
    - The affected code: the stream SQL at `R/write-duckdb.R:193`, read by `duckdb_batches()` (line 444); `row_number() OVER ()` at line 220; the check's final `ORDER BY ".rcs_pos"` at lines 1191–1193.
    - What the user sees: with a partition, `Invalid files table. ✖ A path is named twice.` (`rcs_error_schema`), keyed or not. Without a partition, the serialization check fails with "columns … differ from x", keyed or not. With `check = FALSE` the file MD5s change between runs, for keyed writes too.
  - **Re-scan cost** (4e6 rows of parquet, 395 MB):
    - `DISTINCT` takes 0.04 s and the key check 0.28 s.
    - One partition with `row_number()`: 0.3 s when the source is sorted or clustered by `part` (the filter reaches `READ_PARQUET` and 3/33 row groups are read). It takes 2.4 s when `part` is interleaved (no pruning). Without `row_number()`, interleaved takes 0.77 s.
    - Today's full materialisation takes 4.5 s. All of these are small next to the R-side write (about 17–21 s per 1e6 rows).
    - Optional for WP5: with a key, `ORDER BY key` is already total, so `.rcs_tmp` could be dropped for keyed writes, provided the bytes stay identical.
  - **D-B6, chosen branch: deviation, "Option A".** Neither listed branch fixes the cause: comparing by key does not help, because the files themselves are wrong, keyed ones included; aborting only unkeyed writes leaves keyed writes broken. Decision:
    - For the duration of every lazy DuckDB write, materialised and streamed, keyed and unkeyed: read `current_setting('preserve_insertion_order')`, `SET preserve_insertion_order = true`, and restore the caller's value on exit (`withr::defer` or equivalent, on error too).
    - Output is then byte-identical to the default. Document this in the roxygen "DuckDB input" section.
    - B-T6 becomes: under `false`, keyed and unkeyed partitioned writes (and one unpartitioned write) succeed, their files equal the default write's (MD5), and the connection's setting is `false` again afterwards. Red today. Flagged to the owner at WP6; the alternative was to abort whenever the setting is `false`.

## Outcome

Filled in when the status becomes done or superseded.

- **2026-11-23, done.** The owner approved the WP6 report, including the four decisions that depart from the plan text ("Results" and "Open questions"): versions change for partitioned datasets; D-B6 Option A; no `NA`-key abort; 5 rows, not 7, in A-T1. Released as 0.0.0.9004.
- **Part A.** User partition columns, `h3_p<r>` included, are kept as given on update for tables and sf. The catalog records `partition_auto`, and legacy catalogs are resolved by `partition_is_auto()`. The automatic `"h3"` partition is unchanged. `format_partition()` shows character values as they are.
- **Part B.** Partitioned lazy DuckDB table writes stream one partition at a time, byte-identical to the materialised path. Benchmark: 2e7 rows, 32 partitions, under 1GB/2GB caps. Streamed succeeds at 1.11× the largest partition; materialised runs out of memory.
- **Left open:** the items in "Open questions": streaming geospatial writes, DuckDB `"update"`, the staging footprint, `NA` keys, and `check_results()` failing open.
