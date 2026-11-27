# Handoff: kick off plan 0005 (copy on read; restricted sync)

- **Date:** 2026-11-26
- **Author:** Eduard Bukin
- **Plan:** `.docs/plans/0005-copy-on-read-and-restricted-sync.md`

## Where things stand

Task: run plan 0005 as its orchestrator. `store_read()` copies datasets of up to 2 GB to the secondary locations before reading. `store_sync()` to secondaries refreshes only the datasets they already hold (`all = TRUE` for every dataset). Version `0.0.0.9005`.

- **Done:** the decisions (note 0003) and the full plan (plan 0005), committed together with this handoff. Package at `0.0.0.9004` (plan 0004 released).
- **In progress:** nothing.
- **Not started:** every work package, WP0 to WP8.

## Prompt for the orchestrator

> You are the orchestrator of `.docs/plans/0005-copy-on-read-and-restricted-sync.md`. Read `CLAUDE.md`, note `.docs/notes/0003-local-copy-on-read-and-restricted-sync.md`, then the whole plan. Follow its "Rules for this plan" exactly. You run no code and edit only the plan file. Spawn every work package as an Agent with `model: "opus"`, in the order and with the parallelism the plan allows (at most 3 R sessions at once). Give each agent its WP text, the decisions it needs and the paths, and give verifiers no writer conclusions. Check each report against its acceptance criteria, tick the steps, and record facts and verdicts in "Results". Every report must end with `session closed`; if one does not, send a small agent to `quit()` that session. Do not ask the owner about decisions the plan already takes. Stop and ask only when the plan says so or a verifier fails twice on the same WP. Finish with WP8: commit, no push, then report to the owner.

## Files touched

- `.docs/notes/0003-local-copy-on-read-and-restricted-sync.md`: the owner's decisions, quoted verbatim.
- `.docs/plans/0005-copy-on-read-and-restricted-sync.md`: the plan.
- `.docs/handoffs/0004-plan-0005-kickoff.md`: this file.

## How to verify

- Start: `git log -1 --oneline` shows the commit that adds plan 0005; `grep Version DESCRIPTION` gives `0.0.0.9004`; `git status` is clean.
- End: the plan's status is `done` with "Results" and "Outcome" filled; `git log -1` shows the `Plan 0005: ...` commit; `DESCRIPTION` says `0.0.0.9005`; `git status` is clean; `testthat::test_local(filter = "copy-on-read|^sync$|^read$")` passes.

## Next steps

1. WP0 preflight, then WP1 survey (its D-B6 finding goes in "Results" before WP4).
2. Part A: WP2 → WP2-V → WP3 → WP3-V. WP4 (Part B red tests, in the new file) may run in parallel with WP3.
3. Part B: WP4-V → WP5 (after WP3-V) → WP5-V.
4. WP6 (efficiency) and WP7 (docs) in parallel.
5. WP8: version bump, `devtools::document()`, commit by explicit paths, no push, report.

## Gotchas

- Decisions in note 0003 and in the plan's "Decisions taken" are final. In particular: any secondary counts, not only local ones; there is no separate cache; old versions copy only with `copy = TRUE`; the limit is 2 GB decimal (`2e9`); `all = TRUE` and not `datasets = "all"`, so that a dataset named `all` stays addressable.
- Many existing tests assume a full sync or reads that do not copy. They get minimal edits (`all = TRUE`, `copy = FALSE`, `copy_on_read = FALSE`), never deleted expectations. WP1 lists them.
- `helper-model.R` models sync for `test-random-operations.R`. Changing the default changes the model.
- Do not re-run `bench/`. WP6's short script is the only efficiency check.
- Never run the whole test suite (it takes more than 30 minutes); use filters.
