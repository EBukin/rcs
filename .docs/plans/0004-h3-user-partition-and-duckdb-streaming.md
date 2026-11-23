# User `h3_p<r>` partitions on update; streaming lazy DuckDB table writes by partition

- **Date:** 2026-11-23
- **Author:** Eduard Bukin
- **Status:** draft

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

- [ ] Plan 0003 is `done` and committed (`git log` shows its release commit; `DESCRIPTION` says `0.0.0.9003`). If not, stop: report to the owner and wait.
- [ ] `git status` is clean apart from this plan and note 0002. Otherwise ask the owner.
- [ ] Set this plan's status to `active`.

### Part A. User `h3_p<r>` partitions on update

#### WP1. Red tests for Part A (test writer, Opus)

Files: `tests/testthat/test-write.R` (update section; put the new tests together under a comment `# Plan 0004: user h3_p<r> partitions`), `tests/testthat/test-catalog.R` (legacy file), `tests/testthat/test-write.R` or the file that tests `format_partition()` (grep it). No change under `R/`.

Each `test_that()` is named by the behaviour. Its comment states the expected red reason, which the red verifier checks.

- [ ] **A-T1 (red).** Table, character `h3_p3` (the note's `x`/`y`): create with `partition = "h3_p3"`, then update with `partition = "h3_p3"`. Success; reading back gives the 7 rows with `h3_p3` unchanged and character; the catalog has `partition = "h3_p3"` and `partition_auto = FALSE`. Red: "Stored partition: h3".
- [ ] **A-T2 (red).** Same as T1, update without `partition`. Red: `partition = "h3"` needs geocoded geospatial data.
- [ ] **A-T3 (red).** sf points (build them in code, or take a few from `rcs_sim_points()`) with a character `h3_p3` in which at least one row deliberately differs from its computed res-3 parent. Create with `partition = "h3_p3"`. Then update with rows that add a new partition and replace an existing one, (a) with `partition = "h3_p3"` and (b) without it. Success. Every row's `h3_p3` reads back exactly as written, the deliberate mismatch included. The file set matches the partition values; `partition_auto = FALSE`. Red: (a) "Stored partition: h3"; (b) "differs from the partition column the write computes".
- [ ] **A-T4 (red).** Same as T3 with `h3_p3` as `rcs_h3` (`new_rcs_h3(...)`) and a deliberate mismatch, update with and without `partition`. The values are kept. Red: (a) "Stored partition: h3"; (b) "differs from the partition column".
- [ ] **A-T5 (guard, passes now).** sf with `partition = "h3"`: create, update with `partition = "h3"` and update without it. Same files and messages as before; the catalog partition is `h3_p<r>`. Plus a red part: `partition_auto` is `TRUE`.
- [ ] **A-T6 (guard, passes now).** sf with `partition = "h3"` and an update that exceeds `max_files` re-partitions to a coarser resolution as before. Find the existing test of this; if one exists, reference it in a comment instead of duplicating it.
- [ ] **A-T7 (red).** Mismatches abort with class `rcs_error_argument`: an automatic dataset updated with `partition = "h3_p5"` (its own written column), and a user `h3_p3` dataset updated with `partition = "h3"`. Snapshot the two messages with `expect_snapshot(error = TRUE)`; the `i` line names the stored partition as given on create. Red: the first currently aborts with "Stored partition: h3" (same text, so the snapshot is new), the second currently passes the comparison and fails later with a different error. The red verifier checks the reason, not just a failure.
- [ ] **A-T8 (red).** Legacy catalog, following the `geocode_engine` test in `test-catalog.R` (~line 424): write three datasets, then rewrite `_catalog.parquet` without `partition_auto`.
  - (i) A table with character `h3_p3`: update without `partition` succeeds.
  - (ii) An sf with automatic `"h3"`: update without `partition` behaves as automatic.
  - (iii) An sf with a user `rcs_h3` `h3_p3` holding a deliberate mismatch: update with `partition = "h3_p3"` succeeds, keeps the values, and the catalog afterwards says `FALSE`.
  - After any write, the catalog file has the column.
  - Red: (i) and (iii) as in T1/T4; the column assertions because it does not exist.
- [ ] **A-T9 (red).** `format_partition('{"h3_p3":"831e5afffffffff"}')` is `"h3_p3 = 831e5afffffffff"`, with no warning (`expect_no_warning`). An automatic `integer64` value still renders as hex, matching the existing expectation. Snapshot the update message of A-T1 (`expect_snapshot()` with `rcs.quiet = FALSE`). Red: `NA` plus a coercion warning.
- [ ] **A-T10 (red).** `partition_is_auto()` unit tests covering every row of D-A2.
- [ ] Run `testthat::test_local(filter = "^write$|catalog")` (or the filters that select exactly these files). Report each new test as red or green, with the first line of its failure.
- [ ] Report: test names, file and line, the red/green table, `session closed`.

#### WP1-V. Red verification (verifier, Opus, fresh session)

- [ ] Read only the test diff, D-A1–D-A8 and the note. Check that the tests encode the decisions and the reporter's acceptance criteria 1–3, and that no test depends on another test's state.
- [ ] Run the same filters. Every test marked red fails, and fails for the reason in its comment; every guard passes. `git diff --stat -- R/` is empty.
- [ ] PASS or FAIL with reasons, then `session closed`. On FAIL, the orchestrator resumes the WP1 writer with the findings and repeats WP1-V.

#### WP2. Code for Part A (code writer, Opus)

Files: `R/schema.R`, `R/files.R`, `R/write.R`, `R/catalog.R`, `R/write-duckdb.R` (only to record the flag), `R/sync.R` / `R/history.R` if they build entries, `.docs/plans/0001-rcs-package.md` (the catalog table only).

- [ ] D-A1: add the column to the schema and to `schema_optional`; thread `partition_auto` through `files_meta()` and every builder that sets `geocode_engine`. Set it in `stage_full()` (from `identical(a$partition, "h3")` before it is resolved), in `stage_duckdb()` (`FALSE`), in `stage_duckdb_geo()` (`TRUE` for `"h3"`), and in the index stagers.
- [ ] D-A2: `partition_is_auto()`.
- [ ] D-A3, D-A4: rewrite the partition block of `stage_update()` around the resolved flag. Keep the variable names that the rest of the function uses, or rename them consistently. The comment above the block cites plan 0004.
- [ ] D-A6: `format_partition()`.
- [ ] D-A8: roxygen of `store_write()`; the "Catalog schema" row in plan 0001. Do not run `devtools::document()` yet (WP6 does).
- [ ] Run `testthat::test_local(filter = "^write$|catalog|schema")` until green. Do not edit tests; a test thought wrong goes to the orchestrator.
- [ ] Report: diff summary per file, counts, `session closed`.

#### WP2-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the `R/` diff with no prior conclusions against D-A1–D-A8. Look in particular for any remaining name-based `grepl("^h3_p...")` decision on the write or update path that should use the flag instead. The read-side classifier and `rcs_geo_strip()` stay name-based on purpose.
- [ ] Run, each separately, reporting counts and failures verbatim: `^write$`, `catalog`, `schema`, `sync`, `history`, `write-duckdb`, `geo-verbs`, `read`, `integration`, `random-operations`, `crash-points`. One file over 10 minutes may run as a pre-approved long job in the agent's own session.
- [ ] Re-run the note's reproduction (table and sf; scratch script under the agent's scratchpad) and confirm every row of its table now behaves as the plan says.
- [ ] Mutation check, in the R session only (never edit files): with `local_mocked_bindings()` or `assignInNamespace()`, make `partition_is_auto()` return the old name-based answer. A-T1–A-T4, A-T8 and A-T10 must fail. Restore `format_partition()` to the old body: A-T9 must fail. Report which tests failed.
- [ ] PASS or FAIL, then `session closed`. On FAIL, route to the WP2 writer (resume it if possible) and repeat WP2-V.

### Part B. Streaming lazy DuckDB table writes

#### WP3. Diagnosis and calibration (investigator, Opus, read-only; may run in parallel with WP1–WP2)

No edits to the repo; scripts go in the agent's scratchpad.

- [ ] **Memory today.** Build a synthetic table inside DuckDB (D-B5), for example 4e6 rows × 20 double columns plus `id` and a partition column of 16 values. Write it with the current code under `SET memory_limit = '<m>'`, `SET temp_directory = '<tmp>'` and `SET max_temp_directory_size = '<t>'`. Find small `m`/`t` values at which the current path fails with an out-of-memory error while one partition alone would fit (try writing one partition's rows only). The test must run in under 60 s, so report sizes, settings and timings that make a test fast and robust, and a second, larger set for the benchmark.
- [ ] **preserve_insertion_order.** Reproduce "columns id, … differ from x" with `SET preserve_insertion_order = false` on a keyed and an unkeyed synthetic table. Find the exact line and the cause (check comparing by position? write order changing?). Recommend the D-B6 branch.
- [ ] **Re-scan cost.** Time `SELECT DISTINCT`, the `GROUP BY key` check and one filtered partition over a parquet-backed view of the synthetic table. Report whether filter pushdown makes the per-partition scans cheap.
- [ ] Report the facts, the recommended test parameters, the D-B6 branch, and `session closed`. The orchestrator copies the facts into "Results" and fixes the parameters for WP4.

#### WP4. Red tests for Part B (test writer, Opus)

Files: `tests/testthat/test-write-duckdb.R` (use `helper-duckdb.R`'s helpers), no change under `R/`.

- [ ] **B-T1 (red).** Under the WP3 memory/spill caps, a partitioned keyed write of the synthetic table succeeds. Assert row count, file count = P, and that the read-back equals the DuckDB table (sorted by `id`). `skip_on_cran()`. Red: DuckDB out-of-memory error, wrapped or not. Assert that it is the memory error, not some other failure.
- [ ] **B-T2 (red, after D-B1).** With `options(rcs.duckdb_stream = FALSE)` the same write fails as today. Red: the option does not exist, so it currently fails the same way; mark this test's red reason as "same failure as today; becomes a guard after WP5".
- [ ] **B-T3 (guard).** Equality across paths, on uncapped small data (`rcs_sim_table(2000)`, partitions `year` and a two-column partition, keyed and unkeyed): the streamed write, the write with `rcs.duckdb_stream = FALSE` and the same rows collected and written from R give the same catalog `version` and identical file MD5s. It passes now trivially (both DuckDB modes are the same code) and must stay green.
- [ ] **B-T4 (guard).** A duplicate key across two partitions aborts with the same class and snapshot message as today. An `NA` key aborts the same way.
- [ ] **B-T5 (red).** No `rcs_write_%` table is left on the connection after a successful streamed write, nor after a failure in the middle (mock the file writer to fail on the second partition with `local_mocked_bindings()`). Query `duckdb_tables()` / `information_schema.tables`. Red: the per-partition tables do not exist yet, so to be red, assert that during a streamed write the largest temp table never exceeds one partition's rows. The writer may do this with a mocked `duckdb_write_files()` that records `SELECT count(*)` of the table it reads.
- [ ] **B-T6 (red or guard, per D-B6).** `preserve_insertion_order = false`: keyed write succeeds and equals the default write; unkeyed write either succeeds identically or aborts with the new clear message, as WP3 decided.
- [ ] **B-T7 (guard).** A non-partitioned lazy write and a geospatial lazy write are unchanged (an existing test may cover this; reference it).
- [ ] **B-T8 (red).** Partition values of each supported type (integer, double, VARCHAR with a quote and a space, DATE, BOOLEAN, BIGINT) round-trip through the streamed path, binding values as parameters (a value like `O'Brien` must work).
- [ ] Run `testthat::test_local(filter = "write-duckdb")`; report the red/green table and `session closed`.

#### WP4-V. Red verification (verifier, Opus, fresh session)

- [ ] As WP1-V, for D-B1–D-B7 and the reporter's criterion 5. Check in particular that B-T1 fails with the memory error and not with something else, and that it runs in under 60 s.
- [ ] PASS or FAIL, `session closed`.

#### WP5. Code for Part B (code writer, Opus)

Files: `R/write-duckdb.R`, the option defaults and their docs (grep `rcs.duckdb_batch_rows`), `R/write.R` roxygen ("DuckDB input"), possibly `R/write.R` step 8 if `check` must be passed through.

- [ ] D-B1–D-B4, D-B6 (the branch WP3 chose), D-B7 (roxygen only).
- [ ] Keep `stage_duckdb()` readable: split it into `stage_duckdb_materialised()` (today's body) and `stage_duckdb_streamed()`, sharing the describe/type/key/partition helpers. No behaviour change for the materialised path.
- [ ] Run `testthat::test_local(filter = "write-duckdb")` until green. Do not edit tests.
- [ ] Report: diff summary, counts, the B-T1 timing, `session closed`.

#### WP5-V. Green verification (verifier, Opus, fresh session)

- [ ] Read the diff against D-B1–D-B7. Look for SQL built by pasting values; for a temp table that can leak; and for a path where `check = FALSE` still checks, or `check = TRUE` skips the check.
- [ ] Run, each separately: `write-duckdb`, `write-duckdb-geo`, `duckdb`, `duckdb-tbl`, `duckdb-file`, `^write$`, `query`, `integration`.
- [ ] Mutation check (session only): force the materialised path from `stage_duckdb()` (mock the stream decision to `FALSE`): B-T1 and B-T5 must fail. Make the in-loop check a no-op: some test must fail. If none does, report it as a gap.
- [ ] PASS or FAIL, `session closed`.

#### WP5-B. Benchmark (verifier, Opus, own session, long job pre-approved; after WP5-V passes)

- [ ] Add `bench/write-stream.R`, in the style of `bench/write.R` and `bench/harness.R`. It uses the WP3 large parameters (a synthetic table of several GB built in DuckDB, P = 16–32 partitions, keyed by `id`) with a capped `memory_limit` and `max_temp_directory_size` (the cap is below the whole table and above the largest partition). It runs streamed and materialised, records success/failure, wall time, rows, the largest partition's size, and DuckDB memory sampled after each partition (`SELECT sum(memory_usage_bytes) FROM duckdb_memory()`) plus the size of the temp folder. Results go to `output/tables/bench-write-stream.csv`.
- [ ] Expected: streamed succeeds and its peak memory plus spill is on the order of the largest partition; materialised fails or peaks near the whole table. Report the table. If streamed does not meet the bound, report FAIL with the numbers. The orchestrator then decides whether to route back to WP5.
- [ ] `session closed`.

### WP6. Report, then release on the owner's OK (orchestrator + one writer)

- [ ] The orchestrator fills in "Results", then reports to the owner in a few bullets: cause, Part A fix, Part B design, tests with counts, the benchmark table. It then **waits for the owner's OK**.
- [ ] On OK, one writer (Opus):
  - sets `Version: 0.0.0.9004` in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed;
  - runs `testthat::test_local(filter = "^write$|catalog|write-duckdb")` once more;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `bench/write-stream.R`, `output/tables/bench-write-stream.csv`, `DESCRIPTION`, `.docs/plans/0001-rcs-package.md`, this plan, note 0002);
  - commits with no email address and no AI attribution, e.g. `Plan 0004: user h3_p<r> partitions keep their values on update (catalog partition_auto); lazy DuckDB table writes stream by partition; version 0.0.0.9004`;
  - pushes `main`;
  - reports the commit hash, `git status` (clean) and `session closed`.
- [ ] The orchestrator sets the status to `done` and fills in "Outcome" before the writer commits, so both go in one commit.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- **Streaming geospatial lazy writes** (and `partition = "h3"` from DuckDB, which needs the global cell map first). Out of scope; the reporter's wide table is a plain table. Proposed follow-up plan.
- **`"update"` from a lazy DuckDB table** (D36). Still aborts. With Part A done, a caller can write partition by partition from R (`collect()` one partition, `"create"` then `"update"`). Each update of a table re-reads the keys of the kept files (`check_key_across()`), which is O(rows) per update. Worth measuring if the owner wants this route documented.
- **Staging footprint.** The output still sits on disk twice (staging plus store). A streamed write could upload each file as soon as it is staged and checked, because nothing is visible before the catalog switch. That changes the stage→check→upload order of `store_write()`, so it needs an owner decision.
- **Arrow Dataset / parquet path input.** Not requested as a must; not planned.

## Results

Filled in by the orchestrator per work package: PASS/FAIL, counts, deviations from the decisions (with the reason), timings, WP3 facts.

## Outcome

Filled in when the status becomes done or superseded.
