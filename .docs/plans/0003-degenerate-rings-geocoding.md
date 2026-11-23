# Geocoding: degenerate rings, rebuilds that stay invalid, planar fallback on rows invalid in the plane

- **Date:** 2026-11-22
- **Author:** Eduard Bukin
- **Status:** done

## Goal

`store_write()` (and every other caller of `geo_encode()` / `geo_h3_rows()`: `rcs_geo_add()`, `rcs_geo_index()`, the DuckDB geo write, `geo_cells_touched()`) never aborts on a polygon because of its rings. Concretely, when this plan is done:

1. **A.** Rings that densifying collapses to fewer than 4 points (degenerate holes: near-identical points, zero-area spikes) are dropped from the copy used for the interior fill, in both the sphere path and the planar path. They do not change any cell. Fix already drafted (Appendix A); this plan reviews it, hardens it and tests it thoroughly.
2. **B.** Under `geocode_engine = "auto"`, a rebuilt copy that is **still invalid on the sphere** is not faithful: the row falls back to the plane, with the existing D32 warning. Today `geo_rebuild_faithful()` checks only the measure, so row 341 of the bug report was "rebuilt" by an `s2_rebuild()` that did nothing.
3. **C.** The planar engine (explicit `"planar"`, and the `"auto"` fallback) works on rows that are invalid in the plane too (for example a bowtie hole). It makes them valid in the plane first instead of aborting with a GEOS `TopologyException`.
4. Every change has regression tests on synthetic geometry only. The relevant test files pass in a fresh session. An end-to-end acceptance run on the reporter's datasets (read in place, never copied into the repo) succeeds: `admin/adm6_koatuu` (18,730 rows) and `admin/adm7_zone` (77,225 rows).
5. Version `0.0.0.9003`; committed and pushed after the owner's OK.

## Context

### The bug report (summary)

`store_write(st, y, "repro", title = "t", description = "t", key = "adm6_id")` with the default engine aborts:

```
Error in FUN(X[[i]], ...): polygons require at least 4 points
```

Stack: `store_write -> stage_full -> geo_encode -> geo_h3_rows -> geo_h3_chunk -> geo_crossing_rows -> geo_touched_hex(g[sphere], geog = geog[sphere]) -> geo_touched_normal -> sf::st_cast(polygons, "MULTIPOLYGON") -> close_polygon_or_multipolygon`. With `geocode_engine = "planar"` the write works. Whole datasets fail after 7+ minutes.

Reporter's data (diagnosis and acceptance only; never commit it, never copy it under the repo):

- `C:/Users/EB2/noSyncDocs/ukrCadastreReharvest/data-store/admin/adm6_koatuu.parquet`: 18,730 rows; WKB in column `geometry`, EPSG:4326; key `adm6_id`; 5,538 rows invalid on the sphere.
- `C:/Users/EB2/noSyncDocs/ukrCadastreReharvest/data-store/admin/adm7_zone.parquet`: 77,225 rows; 4,665 invalid on the sphere; key unknown, so inspect the columns (e.g. `adm7_id`); without a key, write without one.
- Row 341 alone: `C:/Users/EB2/AppData/Local/Temp/claude/a1723126e4f050a8/74ce6590-ed8b-4740-bfae-b4f860186722/scratchpad/adm6_koatuu_341.parquet`. That folder may be gone; if so, take `adm6_id == 341` from the full file (row 2148).
- Reading: `y <- arrow::read_parquet(path); y$geometry <- sf::st_as_sfc(structure(lapply(y$geometry, as.raw), class = "WKB"), crs = 4326); y <- sf::st_as_sf(tibble::as_tibble(y))`.
- Rows of interest, all in oblast UA05 (`adm1_id`/oblast column: check the name): 341 (fails), 342 (ok, "geocoded in the plane" warning), 343 (valid), 354, 363 (invalid on the sphere, not tested).
- The reporter says: all 713 UA05 rows fail together; the 369 sphere-invalid UA05 rows succeed together, although row 341 is among them. Not reproduced so far (see facts).

### Facts established on 2026-11-22 (reproduction agent and verifier)

1. Root cause of A: `R/geo-encode.R`, `geo_touched_normal()`, the densifying line `dense_long <- with_s2(sf::st_segmentize(geo_sfc(g[long]), spacing))`. For lon/lat input `sf::st_segmentize()` calls `lwgeom::st_geod_segmentize()`, not s2, so `with_s2()` has no effect there. lwgeom drops repeated or near-repeated consecutive vertices, so a closed ring of 4 near-identical points, or a spike A,B,A,A, comes back with 1 to 3 points.
2. `sf::st_cast(polygons, "MULTIPOLYGON")` then aborts. If the input is already `sfc_MULTIPOLYGON`, `st_cast` is a no-op and `h3o::sfc_to_cells()` panics instead (`User function panicked: sfc_to_cells_`). So the fix belongs before both calls.
3. `wk::wk_coords(dense)` (boundary cells) is fine with collapsed rings.
4. A applies to valid, rebuilt and fallback rows alike, whenever the polygon is wider than the resolution's edge (the interior branch `big`). Synthetic trigger: a 0.2 x 0.15 degree box at 30E 48N with a hole of 3 points 1e-13 degrees apart. Holes with points 1e-11 degrees apart or more survive lwgeom. A 5 km box does not trigger it.
5. Row 341: one POLYGON, 365 rings, 2,805 vertices, valid in GEOS, invalid on s2 (`Loop 182: Edge 1 crosses edge 4`). It takes the **rebuilt** path: `geo_rebuild_faithful()` returns TRUE, but `s2_rebuild()` returns the same 2,440 points and the copy is still invalid with the same reason (B). Its collapsing rings: ring 33 (4 points identical to ~1e-14), rings 100, 161, 251 (spikes 3 to 13 m, zero area).
6. `geo_planar_rows()` densifies with `geo_densify_planar()` (`st_segmentize` with no CRS → GDAL), which keeps degenerate rings at 4 points. So the planar path is not affected by A today; the helper there is protection against WKB that is already short.
7. C: a polygon with a bowtie hole is invalid on the sphere and in the plane. Under `"auto"` it falls back to the plane and aborts with `TopologyException: side location conflict` (GEOS, in `geo_planar_rows()`: `sf::st_intersects()` or `geo_planar_parts()` / `sf::st_intersection()`).
8. A hole of exactly identical points, or a spike, is invalid on s2. `s2_rebuild()` drops it, so `store_write()` passes. But `geo_cells_touched()`, which goes through `geo_as_s2()` and has no faithful check, still failed before the fix.
9. Chunk dependence: one bad row aborts its whole chunk, because the cast runs once over all big polygons of the chunk. The reporter's "the 369 succeed together" was not reproduced: row 341 fails alongside POLYGON, MULTIPOLYGON and sub-cell companions. The reporter ran version 0.0.0.9000 (chunking was different before `rcs.chunk_size = 1e4`).
10. With the draft fix (Appendix A), in a fresh session: `testthat::test_local(filter = "geo-(cells|encode|engine)")` gives 8,929 passed, 0 failed, 0 warnings, 0 skipped. The synthetic repro works (4 cells, write succeeds). Row 341 under `"auto"` writes, with warning `1 rebuilt by s2, 0 geocoded in the plane after a failed rebuild check`, and 3 index rows (shares 0.058, 0.892, 0.050).
11. `s2::s2_segmentize()` is not exported in s2 1.1.3. Densifying the rebuilt geography does not help: the synthetic is valid and never rebuilt.

### Code map (line numbers at the draft state; re-check, they drift)

- `R/geo-encode.R`
  - `geo_touched_hex()` ~181, `geo_touched_normal()` ~216 (densify ~227, interior fill ~237–248)
  - `geo_drop_short_rings()` ~265 (draft)
  - `geo_cells_touched()` ~355
  - `geo_h3_chunk()` ~394
  - `geo_crossing_rows()` ~457 (rebuild loop, `geo_rebuild_faithful()` call)
  - `geo_rebuild()` ~516, `geo_rebuild_faithful()` ~527, `geo_planar_measure()`
  - `geo_planar_rows()` ~583, `geo_planar_parts()`
  - `geo_h3_rows()` ~709
  - `geo_densify_planar()` ~1120
- `R/intersects.R` ~583: the read side's own rebuild loop (D35). Check whether B should apply there for consistency (decision B3).
- `R/write.R` ~975: `warn_geo_rebuild()` (D32 warning, class `rcs_warning_s2_rebuild`); roxygen of `store_write()` ~122 describes the engines.
- Tests:
  - `tests/testthat/test-geo-cells.R` (draft regression tests at the end of the "h3o's intersect mode" block)
  - `tests/testthat/test-geo-engine.R` (engines, fallback, mocked `geo_rebuild`)
  - `tests/testthat/helper-geo-invalid.R` (WKT builders, `local_s2()`)
  - `test-geo-encode.R`, `test-geo-verbs.R`, `test-write-duckdb-geo.R`, `test-write.R` (warnings), `test-intersects.R`
- Design: plan 0002 (`.docs/plans/0002-lazy-duckdb-auth-geo-sync.md`), decisions D30–D35 and facts 17–20; `.docs/notes/0001-plan-0002-limitations.md`.

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh Opus session): runs **no code at all**: no R, no Bash commands that build, test or edit. It may read files (Read, Grep, Glob) and read git state (`git status`, `git diff`, `git log`). It spawns every work package as an Agent with `model: "opus"`, reviews the reports against the acceptance criteria below, ticks the steps in this plan, and fills in "Results" and "Outcome". It edits only this plan file.
- **Writers** (Opus subagents) implement one work package each and run their own tests. **Verifiers** (separate Opus subagents) never edit code and work in a fresh R session. Each verifier gets the acceptance criteria and the paths, not the writer's conclusions.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report ends with `session closed`; if not, the orchestrator sends a small agent to `quit()` it.
- WP1, WP2 and WP3 all edit `R/geo-encode.R`, so they run strictly in sequence, in the main working tree (no worktrees). Only WP5's two acceptance runs run in parallel (read-only).
- Never run the whole test suite (it takes more than 10 minutes). Use `devtools::load_all()` and `testthat::test_local(filter = "...")`.
- Tests and examples use only synthetic geometry built in code or `rcs_sim_*()` data. The reporter's files are read in place for diagnosis and acceptance only; stores go under `tempdir()`.
- R style: `r-lib:*` skills (`r-testthat`, `r-cli`, `r-tidyverse-style`); messages with cli only; internal helpers documented with a comment block and `@noRd` roxygen where the file already does that.
- No commit and no push before the owner's OK (WP6).

### Decisions taken (do not ask the owner about these)

- **A1.** Keep the draft approach: drop rings with fewer than 4 points from the densified polygons before `st_cast()` in both `geo_touched_normal()` and `geo_planar_rows()`. Keep `dense` itself unchanged for boundary coordinates. A polygon whose outer ring is short is dropped whole; an element left with no polygon becomes an empty POLYGON/MULTIPOLYGON. Rings of 4+ points with zero area are kept (h3o handles them).
- **A2.** Fix `with_s2()` around `st_segmentize()` only if it is misleading: either remove it with a comment saying lwgeom does the geodesic densifying for lon/lat, or keep it and say why. No behaviour change.
- **B1.** In `geo_rebuild_faithful()`, a copy that `s2::s2_is_valid()` judges invalid (or `NA`) is not faithful → `FALSE`. Under `"auto"` that sends the row to the planar fallback, which the existing D32 warning already reports ("geocoded in the plane after a failed rebuild check").
- **B2.** Engine `"s2"` is unchanged: D31 says the rebuild result is used. Only `"auto"` gains the check. Rows whose box spans 180 degrees or more keep their current rule.
- **B3.** The read side (`R/intersects.R`, the `"auto"` read engine) must stay consistent with the write side. If it calls `geo_rebuild_faithful()` or its own equivalent, apply the same rule; if it does not, leave it and record why in "Results".
- **C1.** In `geo_planar_rows()`, each row that `sf::st_is_valid()` judges invalid in the plane (under `sf_use_s2(FALSE)`) is repaired with `sf::st_make_valid()` (GEOS, default method) before the touch test and the shares. The repaired copy is used only for geocoding; the stored geometry is never changed. If the repair changes the dimension (e.g. a polygon becomes a GEOMETRYCOLLECTION), keep the parts of the original dimension (`sf::st_collection_extract()`). If the repair is empty, the row gets no cells (`h3` NA), like an empty geometry.
- **C2.** No new warning class and no change to the D32 warning text: such rows are already named as fallbacks under `"auto"`. Under explicit `"planar"`, the repair is silent but documented in the roxygen of `store_write()` (`geocode_engine` parameter) and in the comment of `geo_planar_rows()`. Run `devtools::document()` in WP6 if roxygen changed.
- **D1.** Version `0.0.0.9003`. There is no NEWS.md; do not create one.

## Steps

### WP0. Preflight (orchestrator, no code)

- [x] Read CLAUDE.md, this plan, and plan 0002's D30–D35.
- [x] `git status` / `git diff`: the working tree on `main` holds exactly the draft of Appendix A (`R/geo-encode.R`, `tests/testthat/test-geo-cells.R`), on top of the commit that added this plan. If the draft is missing, WP1 re-applies it from Appendix A first. If anything else is modified, stop and ask the owner.

### WP1. Fix A: review, harden and test (writer, Opus)

Files: `R/geo-encode.R`, `tests/testthat/test-geo-cells.R` (and `test-geo-encode.R` for the `geo_encode()` level).

- [x] Review `geo_drop_short_rings()` for correctness and style:
  - POLYGON and MULTIPOLYGON elements; XY, XYZ, XYM, XYZM (`dim` from the class);
  - empty elements;
  - an `sfc` with no short ring at all, which must be returned identical (same object: no bbox or precision change);
  - speed: the `vapply`/`rapply` scan over every big polygon must stay negligible. Time it on `rcs_sim_polygons(1e4)` before and after, and report the numbers; do not add a benchmark file.
- [x] Apply decision A2.
- [x] Tests (synthetic only), each `test_that()` named by its behaviour:
  1. The draft test of a polygon with a 1e-13 degree hole: cells identical to the same polygon without the hole, as POLYGON and as MULTIPOLYGON; `store_write()` succeeds.
  2. A zero-area spike hole A,B,A,A (a few metres long) and a hole of 4 near-identical points (1e-14), in the same polygon: same cells as without the holes.
  3. A MULTIPOLYGON wider than a cell, where one part is a degenerate polygon whose outer ring collapses: same cells as without that part, no h3o panic.
  4. Several rows in one chunk, one degenerate: the other rows' cells and shares are identical to writing them without it (one bad row no longer aborts the chunk).
  5. The same geometry through `geo_encode()` under `"auto"`, `"s2"` and `"planar"`, and at `h3_res` 5 and 7: no error, and the cells equal the hole-free geometry's.
  6. A property test, seeded with `withr::with_seed()`: take 50 rows of `rcs_sim_polygons()` wider than a res-5 edge, inject 1–3 degenerate holes at random interior points of each (both kinds above), and require `geo_cells_touched()` and `geo_encode()` cells and shares to equal those of the untouched rows.
  7. Unit tests of `geo_drop_short_rings()`: the draft cases, plus XYZ, an element without short rings returned identical, and an all-short element becoming empty.
- [x] Run `testthat::test_local(filter = "geo-(cells|encode|engine)")`. Report the counts and paste any failure verbatim.
- [x] Report: diff summary, test names, counts, timing numbers, `session closed`.

### WP1-V. Verify A (verifier, Opus, fresh session)

- [x] Read the diff with no prior conclusions. Check the acceptance criteria: no ring under 4 points can reach `st_cast()` or `h3o::sfc_to_cells()` at either site; `dense` is unchanged for boundary points; no cell changes for normal data.
- [x] Run `testthat::test_local(filter = "geo-(cells|encode|engine|h3)")`.
- [x] Re-run the minimal repro of Appendix B: it must succeed.
- [x] Mutation check: temporarily make the helper a no-op **in the R session only** (e.g. `assignInNamespace` or `local_mocked_bindings` in a scratch script; never edit the file). The new tests must fail. Report which ones.
- [x] Report PASS or FAIL with the reasons, then `session closed`. On FAIL, the orchestrator sends the findings to a writer (resume the WP1 writer if possible) and repeats WP1-V.

### WP2. Fix B: a rebuild that stays invalid is not faithful (writer, Opus)

Files: `R/geo-encode.R` (`geo_rebuild_faithful()` and its comment), possibly `R/intersects.R` (B3), `tests/testthat/test-geo-engine.R`, `tests/testthat/helper-geo-invalid.R`.

- [x] Implement B1. Keep `tryCatch(..., error = function(e) FALSE)`.
- [x] Apply B3 and record what you found.
- [x] Tests:
  1. With `testthat::local_mocked_bindings(geo_rebuild = function(geog) geog)` (identity, so the copy stays invalid), the invalid rows of `geo_with_invalid()` fall back to the plane under `"auto"` (they appear in `fallback`, not `rebuilt`). Their cells equal `geo_planar_rows()` of those rows, and the warning class is `rcs_warning_s2_rebuild`.
  2. Same mock, engine `"s2"`: the rows count as rebuilt (B2 unchanged).
  3. If you can build one cheaply, a synthetic polygon that is invalid on s2 and whose real `s2_rebuild()` stays invalid (e.g. a sliver hole whose edges cross on the sphere but not in the plane, like row 341's loop 182). Add it to `helper-geo-invalid.R` and test the real path without mocks. If you cannot within reasonable effort, say so; the mocked test is enough.
  4. The existing tests in `test-geo-engine.R` still pass unchanged. If any expectation changes, explain why it is correct under B1.
- [x] Run `testthat::test_local(filter = "geo-(engine|encode|verbs)")`, plus `filter = "intersects"` if B3 changed code.
- [x] Report: diff summary, B3 finding, counts, `session closed`.

### WP2-V. Verify B (verifier, Opus, fresh session)

- [x] Review the diff against B1–B3 and D31. Run `testthat::test_local(filter = "geo-(engine|encode|verbs|cells)")`, plus `"intersects"` if `R/intersects.R` changed.
- [x] Row 341 (read in place) under `"auto"`: it must now write as a planar fallback (warning: `0 rebuilt by s2, 1 geocoded in the plane ...` or equivalent). Report the warning and the index rows verbatim.
- [x] PASS or FAIL, then `session closed`.

### WP3. Fix C: the planar engine on rows invalid in the plane (writer, Opus)

Files: `R/geo-encode.R` (`geo_planar_rows()`), `R/write.R` (roxygen only, C2), `tests/testthat/test-geo-engine.R`, `tests/testthat/helper-geo-invalid.R`.

- [x] Reproduce first: a polygon wider than a res-5 edge with a bowtie hole (invalid in GEOS and on s2), under `"auto"` and `"planar"`. Record the exact error.
- [x] Implement C1 and C2. Repair once per row, only where `st_is_valid()` is FALSE or NA, so valid rows pay one validity check and nothing else. Use the repaired copy for the candidates, the touch test and `geo_planar_parts()`.
- [x] Tests:
  1. The bowtie-hole polygon under `"planar"` and under `"auto"`: no error. The cells equal those of `sf::st_make_valid()` of the polygon geocoded under `"planar"`. Shares sum to 1. The stored geometry read back is the original, byte-identical WKB.
  2. A self-intersecting outer ring (figure eight) wider than a cell: same expectations.
  3. Valid rows in the same chunk are unchanged (cells and shares identical to writing them alone).
  4. A row whose repair is empty or of lower dimension (e.g. a zero-area polygon wider than a cell, if GEOS repairs it to a line): no error, and the documented behaviour of C1.
- [x] Run `testthat::test_local(filter = "geo-(engine|encode|cells|verbs)")`.
- [x] Report: the reproduction error, diff summary, counts, `session closed`.

### WP3-V. Verify C (verifier, Opus, fresh session)

- [x] Review the diff against C1–C2. Run `testthat::test_local(filter = "geo-(engine|encode|cells|verbs|h3)")`.
- [x] Re-run Appendix B and the WP3 bowtie repro.
- [x] PASS or FAIL, then `session closed`.

### WP4. Regression on everything that geocodes (verifier, Opus, fresh session)

- [x] `devtools::load_all()`, then each separately (so a failure is attributable), reporting counts and failures verbatim:
  - `testthat::test_local(filter = "geo-")`
  - `testthat::test_local(filter = "write-duckdb-geo")`
  - `testthat::test_local(filter = "^write$")`, or the filter that selects `test-write.R` alone
  - `testthat::test_local(filter = "intersects")`
  - `testthat::test_local(filter = "read")`
- [x] Not the full suite. A file over 10 minutes may be run as a pre-approved long job in the agent's own session.
- [x] Style pass on the changed lines only, with the `r-lib:r-tidyverse-style` skill, read-only: report issues, do not edit.
- [x] PASS or FAIL, then `session closed`. On FAIL, the orchestrator routes it to the writer of the work package concerned, then repeats that WP's verification and WP4.

### WP5. Acceptance on the reporter's data (two verifiers in parallel, Opus, fresh sessions, read-only)

Each agent writes to a store under its own `tempdir()`, uses the default engine `"auto"` and default options, runs as a long job, and reports elapsed time, the D32 warning verbatim (counts and first keys), the number of rows written and of index rows, and any error verbatim.

- [x] **WP5a.** `adm6_koatuu.parquet`, all 18,730 rows, key `adm6_id`. Then the UA05 subsets of the report (all 713; the 369 sphere-invalid; the 344 valid) and rows 341, 342, 343, 354, 363 alone. Every write must succeed.
- [x] **WP5b.** `adm7_zone.parquet`, all 77,225 rows (key: inspect the columns). It must succeed.
- [x] Optional, non-blocking, in WP5a's session after its runs: explain the reporter's chunk dependence (fact 9). For example, run the 369-row and 713-row UA05 sets on a git worktree at `8b3fa5f` (pre-fix; `devtools::load_all()` from that worktree, in the agent's own session; remove the worktree after) and look at which rows reach the interior branch. A short explanation in the report is enough.
- [ ] If either run fails, the orchestrator has a diagnosis agent reduce the failing row to a synthetic reproduction, then routes it back through the WP concerned (new test included) and repeats WP4 and the failing WP5 run.

### WP6. Report, then release on the owner's OK (orchestrator + one writer)

- [x] The orchestrator fills in "Results" below, then reports to the owner in a few bullets: cause, the fixes A/B/C, tests run with counts, acceptance results with times. It then **waits for the owner's OK**.
- [x] On OK, one writer agent (Opus):
  - sets `Version: 0.0.0.9003` in `DESCRIPTION`;
  - runs `devtools::document()` if roxygen changed (C2) and checks that only the expected `man/` files changed;
  - stages explicit paths only (`R/geo-encode.R`, `R/write.R` if changed, `R/intersects.R` if changed, the changed `tests/testthat/*.R`, `DESCRIPTION`, the changed `man/*.Rd`, this plan);
  - commits with a message that has no email address and no AI attribution, e.g. `Geocoding: drop rings collapsed by densifying; rebuilds that stay invalid fall back to the plane; planar engine repairs rows invalid in the plane; version 0.0.0.9003`;
  - pushes `main`;
  - reports the commit hash, `git status` (clean) and `session closed` if it opened R.
- [x] The orchestrator sets this plan's status to `done` and fills in "Outcome". It does not commit that edit separately unless the owner asks; include it in the release commit by finishing "Outcome" before the writer commits.

## Open questions

- None blocking. If WP5 shows a failure that A–C do not cover, the orchestrator decides whether it is in scope: is it the same abort class, geocoding on polygons? If not, it records it here for the owner.

## Results

Filled in by the orchestrator per work package: PASS/FAIL, counts, deviations from the decisions (with the reason), timings.

- **WP0** (2026-11-23): PASS. `main` at `d3e3ebc`; only `R/geo-encode.R` and `tests/testthat/test-geo-cells.R` modified, matching Appendix A (plus one explanatory comment in the draft test).
- **WP1** (2026-11-23): done, pending WP1-V.
  - `geo_drop_short_rings()`: vectorised scan (`wk::wk_count()` + `tabulate(wk::wk_coords()$ring_id)`); a ring with no points also counts as short; an `sfc` with no short ring is returned at once (`identical()`); short elements repaired one by one with `[[<-` (`[<-` rebuilds the whole `sfc`, ~650 ms per 1e4).
  - A2: `with_s2()` around `st_segmentize()` removed, with a comment: sf 1.1.3 calls `lwgeom::st_geod_segmentize()` for lon/lat and never reads `sf_use_s2()`.
  - Tests: 7 blocks, section "Degenerate rings (plan 0003, fix A)" in `test-geo-cells.R` (tests 1–4, 6, 7) and test 5 in `test-geo-encode.R`. Deviations: test 6 scales 50 random rows of `rcs_sim_polygons(60, seed = 4)` to 1.2–3 res-5 edges (only the 5 fixed rows are wide enough); test 3 places the collapsing part inside a 750 m window cut out of the box (a 1e-13 triangle in open space really touches one more cell on the sphere).
  - Writer's mutation check (helper no-op): tests 1–5 error, test 7 fails 15 expectations.
  - `filter = "geo-(cells|encode|engine)"`: 8,998 passed, 0 failed, 0 warnings, 0 skipped (3.8 min).
  - Helper timing on 1e4 densified sim polygons (median): no short ring 225–245 ms → 10–18 ms; 100 short elements 260 → 20 ms; `st_cast()` on the same set 2.9 s.
  - Note: untracked `.docs/notes/0002-…` and `.docs/plans/0004-…` appeared during WP1 (not from this plan); they stay out of this plan's commit.
- **WP1-V** (2026-11-23): PASS. All 5 criteria met (incl. 0-point rings, mixed `sfc_GEOMETRY`, empty elements → `H3[0]`). `filter = "geo-(cells|encode|engine|h3)"`: 9,051 passed, 0 failed, 0 warnings, 0 skipped (3.2 min). Appendix B succeeds (4 cells, write and read-back of 1 row). Mutation (helper = identity): all 7 new tests fail (tests 1, 2, 4, 6, 5: "polygons require at least 4 points"; test 3: `sfc_to_cells_` panic; test 7: 15 expectations). Non-blocking findings:
  - The `geo_planar_rows()` call site has no test that fails without it (fact 6: GDAL densifying keeps 4 points). With WKB that is already short (1-point ring), the planar path now gets past `st_cast()` but aborts in GEOS: `IllegalArgumentException: point array must contain 0 or >1 elements`. Routed to WP3.
  - The bbox is not updated after `[[<-`; harmless, `st_cast()` recomputes it.
  - One line of ~105 characters in the POLYGON branch; routed to WP2 to wrap.
- **WP2** (2026-11-23): done, pending WP2-V.
  - B1: `geo_rebuild_faithful()` starts with `isTRUE(s2::s2_is_empty(copy)) || !isTRUE(s2::s2_is_valid(copy))` → `FALSE`; `tryCatch(..., error = function(e) FALSE)` kept; comment updated.
  - B2: no code change; the only call site (`geo_crossing_rows()`) is guarded by `geocode_engine == "auto" && !special[[i]]`.
  - B3: `exact_keep()` (`R/intersects.R`) has no faithful check: under `"auto"` invalid rows go straight to the plane (except rows spanning 180 degrees or more, B2); under `"s2"` it rebuilds and uses the copy (D31). Nothing to apply; `R/intersects.R` unchanged.
  - `geo_drop_short_rings()`: long line wrapped as an if/else block.
  - Tests in `test-geo-engine.R`: (1) mocked identity rebuild → rows 21, 22 fall back under `"auto"`, cells and shares equal `geo_planar_rows()`, warning class `rcs_warning_s2_rebuild`; (2) same mock under `"s2"` → rebuilt (rows `c(1:20, 22)`: row 21, duplicate vertex, aborts `"s2"` without a real rebuild, as before; B2 leaves it); (3) real synthetic without mocks, `geo_stays_invalid_wkt()` in `helper-geo-invalid.R`: 0.6 x 0.3 degree box with a hole whose vertices sit 5e-5 degrees inside a long edge's bulge, GEOS-valid, s2 `Loop 1: Edge 1 crosses edge 4`, `s2_rebuild()` returns it unchanged; before B1 `"auto"` aborted (`Given edges do not form loops`), now it falls back and matches `"planar"`.
  - Changed expectations (correct under B1): fixture row 22 (spike) is itself a rebuild that stays invalid (`Edge 0 crosses edge 3`), so under `"auto"` it moves from `rebuilt` to `fallback` in two existing tests; `_snaps/write.md` re-recorded: `1 rebuilt by s2, 1 geocoded in the plane …`, `Rebuilt: id = 21.`, `In the plane: id = 22.` (only these lines).
  - `filter = "geo-(engine|encode|verbs)"`: 858 passed, 0 failed, 0 warnings, 0 skipped (40 s). `filter = "^write$"`: before accepting 342 passed / 1 failed (the snapshot only); after 343 passed, 0 failed, 0 warnings, 0 skipped (2.2 min).
- **WP2-V** (2026-11-23): PASS. B1, B2/D31, B3 confirmed independently (read side under `"auto"` sends invalid rows straight to the plane, no rebuild; no faithful-like check elsewhere). Row 22 checked directly: real rebuild stays invalid, so the changed expectations and snapshot are the intended effect of B1. `filter = "geo-(engine|encode|verbs|cells)"`: 9,116 passed, 0 failed, 0 warnings, 0 skipped.
  - Row 341: `data-store/admin/adm6_koatuu.parquet` no longer exists; the scratchpad file `adm6_koatuu_341.parquet` still does (2,805 vertices, 365 rings, `Loop 182`). Under `"auto"`:
    ```
    Geocoding "repro": 1 row is invalid on the sphere.
    ℹ 0 rebuilt by s2, 1 geocoded in the plane after a failed rebuild check.
    • In the plane: adm6_id = 341.
    ```
    Index rows: `851e4013fffffff` 0.05836281848, `851e401bfffffff` 0.89174796354, `851e40c7fffffff` 0.04988921798 (`h3_main` `851e401bfffffff`).
  - The same row from the current partitioned dataset `ukrCadastreReharvest/data-bucket/admin/adm6_koatuu` (2,643 vertices, 325 rings, `Loop 163`): same warning, same 3 cells, shares equal to ~1e-8.
  - The reporter's single-file Parquets are gone; `data-bucket/admin/adm6_koatuu/` and `adm7_zone/` (Hive partitions `adm1_id=…`) replace them for WP5.
- **WP3** (2026-11-23): done, pending WP3-V.
  - Reproduction (0.6 x 0.3 degree box at 30E 48N, bowtie hole; GEOS `Self-intersection[30.1 48.05]`, s2 `Loop 0: Edge 0 crosses edge 2`), same under `"auto"` and `"planar"`, in `geo_planar_parts()` → `sf::st_intersection()`:
    ```
    TopologyException: side location conflict at 30.099999999999998 48.049999999999997. This can occur if the input geometry is invalid.
    ```
  - Short WKB rings at the planar site (WP1-V finding): 1-point hole (`st_is_valid()` NA) → `IllegalArgumentException: point array must contain 0 or >1 elements` in the touch test; 2-point hole (NA) → `Points of LinearRing do not form a closed linestring`; 3-point A,B,A (FALSE) did not abort. `st_make_valid()` itself errors on the 1-point ring.
  - `geo_planar_rows()` starts with `sfc <- geo_planar_valid(geo_sfc(g))`; the copy feeds candidates, touch test and `geo_planar_parts()`. New `geo_planar_valid()`: one vectorised `st_is_valid()` under `without_s2()` (row by row if it errors, error = invalid); FALSE/NA rows repaired; `sfc` rebuilt with `st_sfc()` (`[[<-` does not record a type change); input returned as is when all valid. New `geo_planar_repair()`: `st_make_valid()` (GEOS default); collection → `st_collection_extract()` of the original dimension; empty, failed, or non-collection lower-dimension result → `GEOMETRYCOLLECTION EMPTY` (no cells, `h3` NA).
  - C2: one passage in the `@param geocode_engine` roxygen of `store_write()` and the `geo_planar_rows()` comment; no new warning class; `document()` left to WP6.
  - Deviations (both within C1/A1): when `st_make_valid()` errors (rings of 1–2 points), it retries after `geo_drop_short_rings()`, and a second failure gives no cells instead of an abort; a polygon repaired to a single LINESTRING gets no cells (no part of the original dimension).
  - Helpers in `helper-geo-invalid.R`: `geo_plane_invalid_wkt()`, `geo_plane_collapse_wkt()`, `geo_short_ring_sfc(k)`, `geo_short_ring_box()`. Tests in `test-geo-engine.R`: "rows invalid in the plane are repaired for geocoding, not stored repaired" (bowtie hole, figure eight; `"planar"`/`"auto"`; byte-identical WKB read back); "valid rows are not repaired and keep their cells beside invalid ones"; "a repair of lower dimension keeps the parts of the original dimension"; "the planar engine geocodes WKB polygons with rings of fewer than 4 points" (k = 1, 2, 3). Writer's mutation check (`geo_planar_valid` = identity): all 4 fail.
  - `filter = "geo-(engine|encode|cells|verbs)"`: 9,279 passed, 0 failed, 0 warnings, 0 skipped (~3.6 min).
- **WP3-V, round 1** (2026-11-23): FAIL on one defect; all else passed (9,332 passed, 0 failed, 0 warnings, 0 skipped on `geo-(engine|encode|cells|verbs|h3)`; Appendix B and an own bowtie repro succeed under both engines with identical WKB; mutation: all 4 WP3 tests fail; valid rows: output `identical()` with and without the validity step, `geo_planar_rows()` on 2,000 rows 13.17 s vs 12.80 s).
  - Defect: `geo_planar_repair()` requires `length(st_collection_extract(...)) == 1`, so a repair to a collection with 2+ polygons gives no cells silently. Repro `MULTIPOLYGON(((29.9 47.9, 30.5 48.2, 30.5 47.9, 29.9 48.2, 29.9 47.9)),((31 48, 31.5 48, 31.2 48, 31 48)))` → `GEOMETRYCOLLECTION(LINESTRING, LINESTRING, POLYGON, POLYGON)` → `h3` NA, 0 cells, no warning, under `"planar"` and `"auto"`. Breaks C1. Routed back to the WP3 writer.
- **WP3, fix round** (2026-11-23): the collection branch of `geo_planar_repair()` keeps every non-empty part of the original dimension: none → empty (no cells), one → that part, several → `sf::st_combine(sf::st_cast(parts, type))[[1]]` (MULTIPOLYGON / MULTILINESTRING). New test "a repair into several polygons keeps them all" (`geo_plane_collapse_wkt()` gains `two_parts`, the verifier's repro); cells compared with the planar geocoding of the two extracted polygons, not `planar_of_repaired()`, which would also geocode the lines (3 extra cells that C1 drops). Old rule restored in the session only: only the new test fails. `filter = "geo-(engine|encode|cells|verbs)"`: 9,295 passed, 0 failed, 0 warnings, 0 skipped.
- **WP3-V, round 2** (2026-11-23): PASS. `filter = "geo-(engine|encode|cells|verbs|h3)"`: 9,348 passed, 0 failed, 0 warnings, 0 skipped. Two-polygon repro: 10 cells, shares sum to 1 under `"planar"` and `"auto"` (D32 fallback warning), 10 index rows through `store_write()`, WKB byte-identical, no cell from the flat part. Mutation (old one-part rule): only the new test fails. Bowtie repro and 2,000-row identity check unchanged. Probes for other silent drops (shared-edge boxes, mixed MULTIPOLYGON/POLYGON parts, bowtie plus flat part, MULTILINESTRING with a zero-length part, zero-length LINESTRING) all keep their cells. Remaining no-cell paths are the intended ones (no part of the row's dimension; `st_make_valid()` failing twice).
- **WP4** (2026-11-23): PASS. Each filter run separately after one `load_all()`, 0 failed, 0 warnings, 0 skipped in all; no `.new.md` snapshots:

  | Filter | Files | Passed | Time |
  |---|---|---|---|
  | `geo-` | geo-cells, geo-encode, geo-engine, geo-h3, geo-verbs | 9,348 | 212 s |
  | `write-duckdb-geo` | write-duckdb-geo | 152 | 137 s |
  | `^write$` | write | 343 | 122 s |
  | `intersects` | duckdb-intersects, intersects | 318 | 142 s |
  | `read` | read | 322 | 99 s |

  - Style (read-only): cli compliant, no bare `stop()`/`warning()`/`message()` in `R/` (one `stop()` in a test mock, acceptable), new helpers documented in the file's comment style. Minor: some changed lines exceed 80 characters (the files already have many at HEAD); `make_valid <- function(y) tryCatch(...)` one-liner (`R/geo-encode.R` ~698) and the nested `vapply(without_s2(tryCatch(...)))` (~666) read densely. Not fixed: cosmetic, no behaviour impact.
  - Console note: the `intersects` run prints the sf message "although coordinates are longitude/latitude, st_union assumes that they are planar" twice, from `R/geo-encode.R:1283` (query-shape code, untouched by this plan); pre-existing, not a test failure.
- **WP5b** (2026-11-23): PASS. Input: all 28 partitions of `ukrCadastreReharvest/data-bucket/admin/adm7_zone/` (the single file is gone), rcs columns `.rcs_id`, `h3`, `bbox` dropped; 77,225 rows, all MULTIPOLYGON, EPSG:4326; 3,399 invalid on the sphere by `s2_is_valid()` (plan: ~4,665; this folder is a store rewritten by rcs, not the original file). Key `adm7_id` (unique, no NA). `store_write(..., key = "adm7_id")`, `"auto"`, default options: 629.7 s; 77,225 rows in 1 file (291.7 MB), MD5 check passed; index table 63,897 rows. No error. Warning verbatim:
  ```
  Geocoding "adm7": 2056 rows are invalid on the sphere.
  ℹ 10 rebuilt by s2, 2046 geocoded in the plane after a failed rebuild check.
  • Rebuilt: adm7_id = 4771; adm7_id = 5448; adm7_id = 8661; adm7_id = 30569;
    adm7_id = 31249; and 5 more.
  • In the plane: adm7_id = 2; adm7_id = 69; adm7_id = 70; adm7_id = 72; adm7_id
    = 171; and 2041 more.
  ```
  (2,056 = invalid rows among those geocoded through s2, i.e. crossing rows, D31.) Under B1 almost all invalid crossing rows now fall back to the plane: `s2_rebuild()` rarely makes them valid.
- **WP5a** (2026-11-23): PASS, every write succeeded (`"auto"`, default options, key `adm6_id`). Input: all partitions of `ukrCadastreReharvest/data-bucket/admin/adm6_koatuu/`, rcs columns dropped; 18,730 rows, all MULTIPOLYGON, unique keys; 4,365 invalid on the sphere (plan ~5,538); UA05 713 rows, 289 invalid / 424 valid (plan 369 / 344); row 341 has 325 rings, 2,643 vertices (`Loop 163`), so the data was rewritten since the report.

  | Run | Rows | Index rows | Time (s) | D32 invalid / rebuilt / plane |
  |---|---|---|---|---|
  | all | 18,730 | 30,728 | 675.2 | 3,791 / 11 / 3,780 |
  | UA05 all | 713 | 1,442 | 29.9 | 250 / 2 / 248 |
  | UA05 invalid | 289 | 596 | 34.6 | 250 / 2 / 248 |
  | UA05 valid | 424 | 846 | 12.3 | no warning |
  | 341 | 1 | 3 | 1.8 | 1 / 0 / 1 |
  | 342 | 1 | 2 | 1.0 | 1 / 0 / 1 |
  | 343 | 1 | 2 | 0.8 | no warning |
  | 354 | 1 | 2 | 0.9 | 1 / 0 / 1 |
  | 363 | 1 | 3 | 0.9 | 1 / 0 / 1 |

  Warning of the full run verbatim:
  ```
  Geocoding "all": 3791 rows are invalid on the sphere.
  ℹ 11 rebuilt by s2, 3780 geocoded in the plane after a failed rebuild check.
  • Rebuilt: adm6_id = 985; adm6_id = 1003; adm6_id = 1512; adm6_id = 3738;
    adm6_id = 6460; and 6 more.
  • In the plane: adm6_id = 4; adm6_id = 9; adm6_id = 13; adm6_id = 14; adm6_id =
    16; and 3775 more.
  ```
  - Caveat: on a worktree at `8b3fa5f` (pre-fix) both UA05 sets (713 and 289 rows; 250 invalid, 179 rebuilt, 71 in the plane) and all 713 UA05 rows one at a time also write without error. The rewritten data no longer holds the collapsing rings (row 341 lost 40 rings), so these runs do not exercise fix A. Fix A on real data rests on the original row-341 file (fact 10 and WP2-V, which wrote it with all fixes) and the synthetic tests. Fact 9 (the 369-set success) cannot be reproduced from this data; most likely the 0.0.0.9000 chunking. Worktree removed; `git worktree list` shows only the main tree.
  - Session incident: WP5a's first R session was shared with WP5b, and one WP5a command overwrote WP5b's `y` there. WP5b's result is unaffected: its reported rows (77,225), key (`adm7_id`) and warning keys are adm7 data, not adm6 (18,730).
  - Fix B effect in numbers: UA05 rebuilt / plane went from 179 / 71 (pre-fix) to 2 / 248.

## Outcome

Done 2026-11-23. The owner gave the OK in the session that wrote plan 0004 ("commit everything, push it"); that session ran WP6: version `0.0.0.9003`, `devtools::document()` (only `man/store_write.Rd` changed), one commit with the plan, pushed to `main`.

- Shipped: A (rings collapsed by densifying are dropped before `st_cast()` / `h3o::sfc_to_cells()`, both paths), B (under `"auto"` a rebuild that stays invalid on the sphere falls back to the plane), C (the planar engine repairs rows invalid in the plane for geocoding only; stored geometry unchanged), with the tests listed in "Results".
- Acceptance: WP5a and WP5b passed on the reporter's current partitioned data. That data no longer holds the collapsing rings, so fix A on real data rests on the original row-341 file and the synthetic tests (see WP5a caveat).
- Dropped: nothing. Not reproduced: fact 9 (the reporter's 369-row success), most likely the 0.0.0.9000 chunking.

## Appendix A. Draft fix in the working tree (uncommitted, 2026-11-22)

```diff
--- a/R/geo-encode.R
+++ b/R/geo-encode.R
@@ geo_touched_normal()
-    polygons <- sf::st_cast(polygons, "MULTIPOLYGON")
+    polygons <- sf::st_cast(geo_drop_short_rings(polygons), "MULTIPOLYGON")
     filled <- geo_flatten_cells(h3o::sfc_to_cells(polygons, h3_res, "centroid"))
     interior <- data.frame(from = big[filled$from], cell = filled$hex)
@@ after geo_touched_normal()
+# Polygons (`sfc` of POLYGON or MULTIPOLYGON) without their rings of fewer
+# than 4 points; a polygon whose outer ring is that short is dropped whole.
+# Densifying with `sf::st_segmentize()` (lwgeom, geodesic) removes repeated
+# vertices, so a degenerate ring (a hole of identical points, a spike) can
+# come back with 1 to 3 points, which `sf::st_cast()` and
+# `h3o::sfc_to_cells()` reject. Such a ring holds no area, so it cannot hold
+# a cell centre and dropping it changes no interior cell.
+geo_drop_short_rings <- function(polygons) {
+  short <- vapply(polygons, function(p) any(rapply(unclass(p), nrow, how = "unlist") < 4L), logical(1))
+  fix_polygon <- function(rings) {
+    if (length(rings) == 0 || nrow(rings[[1]]) < 4L) {
+      return(NULL)
+    }
+    rings[vapply(rings, nrow, integer(1)) >= 4L]
+  }
+  for (i in which(short)) {
+    p <- polygons[[i]]
+    dim <- class(p)[[1]]
+    if (inherits(p, "POLYGON")) {
+      rings <- fix_polygon(unclass(p))
+      polygons[[i]] <- if (is.null(rings)) sf::st_polygon(dim = dim) else sf::st_polygon(rings, dim = dim)
+    } else {
+      parts <- Filter(Negate(is.null), lapply(unclass(p), fix_polygon))
+      polygons[[i]] <- sf::st_multipolygon(parts, dim = dim)
+    }
+  }
+  polygons
+}
@@ geo_planar_rows()
-    polygons <- sf::st_cast(polygons, "MULTIPOLYGON")
+    polygons <- sf::st_cast(geo_drop_short_rings(polygons), "MULTIPOLYGON")
```

Tests added at the end of the "h3o's intersect mode alone would miss cells" block of `tests/testthat/test-geo-cells.R`:

```r
test_that("a degenerate hole that densifying collapses does not abort geocoding", {
  skip_if_no_h3()
  outer <- cbind(c(30, 30.2, 30.2, 30, 30), c(48, 48, 48.15, 48.15, 48))
  hole <- cbind(c(30.1, 30.1 + 1e-13, 30.1, 30.1), c(48.07, 48.07, 48.07 + 1e-13, 48.07))
  holed <- sf::st_sfc(sf::st_polygon(list(outer, hole)), crs = 4326)
  plain <- sf::st_sfc(sf::st_polygon(list(outer)), crs = 4326)
  expect_identical(geo_cells_touched(holed, 5L), geo_cells_touched(plain, 5L))
  expect_identical(geo_cells_touched(sf::st_cast(holed, "MULTIPOLYGON"), 5L), geo_cells_touched(plain, 5L))
  st <- store_connect(withr::local_tempdir(), create = TRUE)
  expect_no_error(
    store_write(st, sf::st_sf(id = 1L, geometry = holed), "holed", title = "t", description = "t", key = "id")
  )
})

test_that("geo_drop_short_rings() drops short holes and polygons with a short outer ring", {
  square <- cbind(c(0, 1, 1, 0, 0), c(0, 0, 1, 1, 0))
  dot <- matrix(c(0.5, 0.5), ncol = 2)
  polygons <- sf::st_sfc(
    sf::st_polygon(list(square, dot)),
    sf::st_multipolygon(list(list(dot), list(square, dot))),
    sf::st_polygon(list(dot))
  )
  out <- geo_drop_short_rings(polygons)
  expect_identical(out[[1]], sf::st_polygon(list(square)))
  expect_identical(out[[2]], sf::st_multipolygon(list(list(square))))
  expect_true(sf::st_is_empty(out[[3]]))
})
```

## Appendix B. Minimal synthetic reproduction (fails at 8b3fa5f)

```r
devtools::load_all()
outer <- matrix(c(30, 48, 30.2, 48, 30.2, 48.15, 30, 48.15, 30, 48), ncol = 2, byrow = TRUE)
tri <- matrix(c(30.1, 48.07, 30.1 + 1e-13, 48.07, 30.1, 48.07 + 1e-13, 30.1, 48.07), ncol = 2, byrow = TRUE)
p <- sf::st_sfc(sf::st_polygon(list(outer, tri)), crs = 4326)

nrow(unclass(sf::st_segmentize(p, h3_edge_m[[6]] / 3)[[1]])[[2]]) # 1

geo_cells_touched(p, 5)
#> at 8b3fa5f: Error in FUN(X[[i]], ...): polygons require at least 4 points

st <- store_connect(file.path(tempdir(), "repro-store"), create = TRUE)
store_write(st, sf::st_sf(id = 1L, geometry = p), "repro", title = "t", description = "t", key = "id")
#> at 8b3fa5f: Error in FUN(X[[i]], ...): polygons require at least 4 points
```
