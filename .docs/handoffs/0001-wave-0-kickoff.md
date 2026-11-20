# Handoff: start the implementation of rcs with wave 0

- **Date:** 2026-11-20
- **Author:** Eduard Bukin
- **Plan:** `.docs/plans/0001-rcs-package.md`

## Where things stand

Build the R package `rcs` as the plan describes. This session does wave 0 only (skeleton and contracts), then stops for the project owner's review.

- **Done:** the design, reviewed, with every design question decided (plan 0001). The project folder is initialised: `CLAUDE.md`, `.claude/` (settings, commit hook, plugins), `.docs/`, empty `R/`, `vignettes/`, `output/`. Starting code is in `recycled/` (see its `README.md`); it was never run after editing.
- **In progress:** nothing.
- **Not started:** all code. No `DESCRIPTION`, no git repository.

## Files touched

- `.docs/plans/0001-rcs-package.md`: the plan; read it in full before anything else.
- `recycled/*.R`, `recycled/README.md`: code to absorb, mapped to work packages and target files.
- `CLAUDE.md`: working conventions; they override defaults.

## Next steps

1. Read `CLAUDE.md`, the whole plan and `recycled/README.md`.
2. Check that the `run-r` tools answer (`mcp__positron__*`). If not, follow the `run-r` skill to connect them; this needs the project owner once. Start your own R session and close it at the end.
3. `git init` on branch `main`, add the remote `https://github.com/EBukin/rcs`. Wave 0 works directly in the project folder; worktrees start with wave 1.
4. Do work package 0 exactly as the plan lists it: the files it owns, `Imports` and `Suggests`, `.Rbuildignore`, MIT licence, author. Install missing packages as they are needed, into the normal library. Install nothing for S3, Azure or Google Drive.
5. Fix the contracts and write them down. For every function named in `R/hooks.R`, every backend generic, `trace_count()`, and the constructors in `R/objects.R` and `R/schema.R`: arguments, their types, the return value, and what it aborts on, in roxygen. These are what five later waves build against in parallel; an agent must be able to implement or call each one from its documentation alone. Where the plan leaves a signature open, decide it, and list each such decision in your report.
6. Write the test infrastructure of wave 0: `helper-levels.R` (`skip_below_level()`, `RCS_TEST_LEVEL`), `helper-sim.R`, tests for schemas, simulated data and the work counters; `bench/harness.R`.
7. Acceptance: `devtools::document()`, `devtools::test()` and `devtools::check()` pass with no errors, warnings or notes; the simulated-data tests prove that the box contains a resolution-0 cell edge and that every coordinate is where the plan says.
8. Tick wave 0 in the plan. Write `.docs/handoffs/0002-waves-1-to-6.md` for a new session with no context: where things stand, the contracts and where they are documented, the decisions you took, how to verify, and the orchestration procedure (below).
9. Commit with explicit paths (`recycled/` included), push to `main`. If the push is refused, report it and do not force.
10. Stop. Report: what was built, test and check output, every contract decision, deviations from the plan, anything in the plan that proved wrong or unclear. End with `session closed`.

Orchestration procedure to put into handoff 0002, for waves 1 to 6:

- The session's agent orchestrates and writes no package code itself. For each wave it launches one subagent per work package, in parallel, each with `model: "opus"` and `isolation: "worktree"`, at most 3 at once.
- Each subagent's brief names: its work package, the plan, the files it owns, the contract documentation, the rule that it passes its worktree path to `devtools::load_all()` and `devtools::test()` and never calls `setwd()`, `devtools::document()` or `devtools::install()`, the `run-r` lifecycle, and the report format (built, test results, deviations, `DESCRIPTION` changes needed, `session closed`).
- After a wave: merge the branches, apply the `DESCRIPTION` changes, run `devtools::document()`, the whole test suite at `RCS_TEST_LEVEL=default` and `devtools::check()`; fix or send back what fails; tick the packages in the plan; commit and push. Then start the next wave without asking. Stop only when the suite still fails after one round of fixes, or when a subagent reports that the plan is wrong.
- Before wave 6 ask the project owner for the list of forbidden terms for the neutrality scan; it is never written to a file in the repository.

## How to verify

```r
devtools::document()
devtools::test()     # all pass, none skipped except those needing a missing Suggests package
devtools::check()    # 0 errors, 0 warnings, 0 notes
```

```
git status           # clean
git log --oneline    # the wave 0 commit, pushed
```

## Gotchas

Decisions already made; do not reopen them:

- Backends are `local` and `gcs` only. Test bucket: `gs://rcs-test`, used under a random prefix that each run removes.
- History is off by default; it can be set for the store, the connection and one dataset, and the dataset's setting wins, then the connection's, then the store's. No automatic pruning.
- No `h3_cell` column. `.rcs_id` on every geospatial dataset. A manifest per dataset version. The connection object updates in place.
- `update` warns with row counts and never aborts on shrinking partitions. Writes go to all locations; there is no `locations` argument.
- Geometries across the antimeridian or around a pole are supported.
- No CI workflow.

Neutrality: nothing in the repository, commit messages included, names a real country, region, organisation or person, or a named time zone. The only exception is the author's name and address in `DESCRIPTION` and the name in `LICENSE`. Commit messages carry no e-mail address and no AI attribution; a hook enforces it.

Things that looked right and were not (all checked in R, see "Verified facts" in the plan):

- `h3o::h3_from_xy(x, y, resolution)` takes latitude first. With longitude first it returns a valid cell in the wrong place, without error.
- An H3 index does not fit a double; never pass or accept a cell as a plain numeric.
- A cell is not inside its parent. The cell of a point at a resolution is computed from the point, never as the parent of a finer cell.
- Arrow returns a small-valued int64 column as `integer` unless `arrow.int64_downcast` is `FALSE`, and returns difftime in seconds.
- Do not lower Arrow's thread pools (`arrow::set_cpu_count(1)`, `arrow::set_io_thread_count(1)`): a dataset scan then deadlocked the R session and it had to be restarted.
- GDAL's `/vsigs/` did not find the application-default credentials that Arrow uses on the same machine.
- The first simulated-data box of the design contained no resolution-0 edge; the plan's box (longitude −30 to −24, latitude 6 to 9) does. Test it, do not assume it.
