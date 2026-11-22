# Handoff: execute plan 0002 (lazy reads, DuckDB, credentials, geospatial transforms, sync, robust geocoding)

- **Date:** 2026-11-21
- **Author:** Eduard Bukin
- **Plan:** `.docs/plans/0002-lazy-duckdb-auth-geo-sync.md`

## Where things stand

The package `rcs` (plan 0001) is complete on `main`. Plan 0002 adds eight features in twelve waves (0–11, 24 work packages). This session orchestrates the whole plan and writes no package code except wave 0.

- **Done:**
  - Prototypes of every feature in `dev/prototype/`, tested on simulated data locally and against `gs://rcs-test`.
  - Plan 0002 written, reviewed twice by an independent agent (all findings applied), and the seven owner decisions taken.
  - All of it committed on branch `prototype/lazy-duckdb-auth-geo` (not merged, not pushed).
- **In progress:** nothing.
- **Not started:** every work package, wave 0 included.

## Files touched

- `.docs/plans/0002-lazy-duckdb-auth-geo-sync.md`: the plan. Everything needed is in it: facts, decisions D1–D46, owner decisions, contracts, orchestration rules, work packages with owned files and acceptance tests.
- `dev/prototype/*.R`: reference prototypes, sourced after `devtools::load_all()`. They override namespace bindings; never copy them into `R/` as they are. They are deleted in wave 11.
  - `print.R`: the dbplyr-style print.
  - `h3.R`: the `rcs_h3` class. Its `as.character()` method is wrong (fact 15).
  - `duckdb.R` and `duckdb-intersects.R`: DuckDB views, tables and the spatial filter.
  - `auth.R`: credentials. It keeps them in a registry keyed by root; the package stores them in the backend.
  - `geo.R`: the geo verbs.
  - `demo.R`: runs all of the above.
- `.Rbuildignore`: `^dev$` added.

## How to verify

Before wave 0, in an R session of your own (`run-r` skill), from the project folder on `main` after the merge:

```r
devtools::document()
devtools::test()                 # RCS_TEST_LEVEL unset = default; must pass with 0 failures
devtools::check(cran = TRUE)     # 0 errors, 0 warnings, 0 notes
```

```
git log --oneline -3             # the plan commit on top of a5d65a5 (Website: built site kept in docs/ ...)
git status                       # clean
```

GCS works with the gcloud application-default login of this machine; the test bucket is `gs://rcs-test`. Always use a random prefix and remove it afterwards.

## Next steps

1. Read `CLAUDE.md`, the whole plan 0002, and the sections of plan 0001 and of `.docs/handoffs/0002-waves-1-to-6.md` that wave 0 needs ("Context", "Gotchas").
2. Merge `prototype/lazy-duckdb-auth-geo` into `main` and push (wave 0, step 1; pushing after every wave is approved, D45).
3. Run wave 0 yourself, then waves 1 to 11 by the plan's "Orchestration" section:
   - implementer, then verifier, per package;
   - the wave gate;
   - a "Results of wave N" block in the plan, then commit and push.
   Do not ask the owner between waves. Stop only on the conditions in "Wave gate", step 5.
4. Keep the plan's status line and checkboxes current. When the plan is done, fill its "Outcome".

## Gotchas

- **Decisions are final.** Owner decisions 1–7 and D1–D46 are not to be reopened. If code proves a decision impossible, stop and report.
- **No benchmarks at all:**
  - nothing in `bench/` is run;
  - `bench/results/` and the benchmark articles are not touched;
  - `bench/quick.R` is not run.
- **Agent budget:** 150k–200k tokens per implementer or verifier run. Follow the plan's reading rules: owned files, functions by grep, the named prototype, and only the named sections of plan 0001.
- **Agent rules:** agents never run `devtools::document()` and never commit `NAMESPACE`, `man/` or `DESCRIPTION`. The orchestrator does both at the gate.
- **S3 methods:** new methods work under `load_all()` before `document()`, so a wrong roxygen tag shows only at the gate's `R CMD check`.
- **DuckDB, facts 1–10 of the plan:**
  - Connect with `bigint = "integer64"`.
  - Build tables with `dplyr::tbl(con, DBI::Id(schema = , table = ))`, not `I()`.
  - dbplyr forbids `$` on lazy tables.
  - `INSTALL spatial` and `INSTALL httpfs` need the network on first use; tests skip through `local_duckdb_spatial()`.
- **GDAL settings are process-wide and stay set** while a raster is in use. A failed open is cached for the rest of the R session, so GDAL tests restore their settings with `withr::defer()`.
- **Neutrality scan (wave 11):** a subagent derives the patterns itself (owner decision 6). The patterns are never committed.
- **R sessions:** at most 3 at once, each agent in its own. Never use the user's console.
