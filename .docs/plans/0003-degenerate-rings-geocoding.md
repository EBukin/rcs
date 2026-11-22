# Geocoding: degenerate rings, rebuilds that stay invalid, planar fallback on rows invalid in the plane

- **Date:** 2026-11-22
- **Author:** Eduard Bukin
- **Status:** active

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

- [ ] Read CLAUDE.md, this plan, and plan 0002's D30–D35.
- [ ] `git status` / `git diff`: the working tree on `main` holds exactly the draft of Appendix A (`R/geo-encode.R`, `tests/testthat/test-geo-cells.R`), on top of the commit that added this plan. If the draft is missing, WP1 re-applies it from Appendix A first. If anything else is modified, stop and ask the owner.

### WP1. Fix A: review, harden and test (writer, Opus)

Files: `R/geo-encode.R`, `tests/testthat/test-geo-cells.R` (and `test-geo-encode.R` for the `geo_encode()` level).

- [ ] Review `geo_drop_short_rings()` for correctness and style:
  - POLYGON and MULTIPOLYGON elements; XY, XYZ, XYM, XYZM (`dim` from the class);
  - empty elements;
  - an `sfc` with no short ring at all, which must be returned identical (same object: no bbox or precision change);
  - speed: the `vapply`/`rapply` scan over every big polygon must stay negligible. Time it on `rcs_sim_polygons(1e4)` before and after, and report the numbers; do not add a benchmark file.
- [ ] Apply decision A2.
- [ ] Tests (synthetic only), each `test_that()` named by its behaviour:
  1. The draft test of a polygon with a 1e-13 degree hole: cells identical to the same polygon without the hole, as POLYGON and as MULTIPOLYGON; `store_write()` succeeds.
  2. A zero-area spike hole A,B,A,A (a few metres long) and a hole of 4 near-identical points (1e-14), in the same polygon: same cells as without the holes.
  3. A MULTIPOLYGON wider than a cell, where one part is a degenerate polygon whose outer ring collapses: same cells as without that part, no h3o panic.
  4. Several rows in one chunk, one degenerate: the other rows' cells and shares are identical to writing them without it (one bad row no longer aborts the chunk).
  5. The same geometry through `geo_encode()` under `"auto"`, `"s2"` and `"planar"`, and at `h3_res` 5 and 7: no error, and the cells equal the hole-free geometry's.
  6. A property test, seeded with `withr::with_seed()`: take 50 rows of `rcs_sim_polygons()` wider than a res-5 edge, inject 1–3 degenerate holes at random interior points of each (both kinds above), and require `geo_cells_touched()` and `geo_encode()` cells and shares to equal those of the untouched rows.
  7. Unit tests of `geo_drop_short_rings()`: the draft cases, plus XYZ, an element without short rings returned identical, and an all-short element becoming empty.
- [ ] Run `testthat::test_local(filter = "geo-(cells|encode|engine)")`. Report the counts and paste any failure verbatim.
- [ ] Report: diff summary, test names, counts, timing numbers, `session closed`.

### WP1-V. Verify A (verifier, Opus, fresh session)

- [ ] Read the diff with no prior conclusions. Check the acceptance criteria: no ring under 4 points can reach `st_cast()` or `h3o::sfc_to_cells()` at either site; `dense` is unchanged for boundary points; no cell changes for normal data.
- [ ] Run `testthat::test_local(filter = "geo-(cells|encode|engine|h3)")`.
- [ ] Re-run the minimal repro of Appendix B: it must succeed.
- [ ] Mutation check: temporarily make the helper a no-op **in the R session only** (e.g. `assignInNamespace` or `local_mocked_bindings` in a scratch script; never edit the file). The new tests must fail. Report which ones.
- [ ] Report PASS or FAIL with the reasons, then `session closed`. On FAIL, the orchestrator sends the findings to a writer (resume the WP1 writer if possible) and repeats WP1-V.

### WP2. Fix B: a rebuild that stays invalid is not faithful (writer, Opus)

Files: `R/geo-encode.R` (`geo_rebuild_faithful()` and its comment), possibly `R/intersects.R` (B3), `tests/testthat/test-geo-engine.R`, `tests/testthat/helper-geo-invalid.R`.

- [ ] Implement B1. Keep `tryCatch(..., error = function(e) FALSE)`.
- [ ] Apply B3 and record what you found.
- [ ] Tests:
  1. With `testthat::local_mocked_bindings(geo_rebuild = function(geog) geog)` (identity, so the copy stays invalid), the invalid rows of `geo_with_invalid()` fall back to the plane under `"auto"` (they appear in `fallback`, not `rebuilt`). Their cells equal `geo_planar_rows()` of those rows, and the warning class is `rcs_warning_s2_rebuild`.
  2. Same mock, engine `"s2"`: the rows count as rebuilt (B2 unchanged).
  3. If you can build one cheaply, a synthetic polygon that is invalid on s2 and whose real `s2_rebuild()` stays invalid (e.g. a sliver hole whose edges cross on the sphere but not in the plane, like row 341's loop 182). Add it to `helper-geo-invalid.R` and test the real path without mocks. If you cannot within reasonable effort, say so; the mocked test is enough.
  4. The existing tests in `test-geo-engine.R` still pass unchanged. If any expectation changes, explain why it is correct under B1.
- [ ] Run `testthat::test_local(filter = "geo-(engine|encode|verbs)")`, plus `filter = "intersects"` if B3 changed code.
- [ ] Report: diff summary, B3 finding, counts, `session closed`.

### WP2-V. Verify B (verifier, Opus, fresh session)

- [ ] Review the diff against B1–B3 and D31. Run `testthat::test_local(filter = "geo-(engine|encode|verbs|cells)")`, plus `"intersects"` if `R/intersects.R` changed.
- [ ] Row 341 (read in place) under `"auto"`: it must now write as a planar fallback (warning: `0 rebuilt by s2, 1 geocoded in the plane ...` or equivalent). Report the warning and the index rows verbatim.
- [ ] PASS or FAIL, then `session closed`.

### WP3. Fix C: the planar engine on rows invalid in the plane (writer, Opus)

Files: `R/geo-encode.R` (`geo_planar_rows()`), `R/write.R` (roxygen only, C2), `tests/testthat/test-geo-engine.R`, `tests/testthat/helper-geo-invalid.R`.

- [ ] Reproduce first: a polygon wider than a res-5 edge with a bowtie hole (invalid in GEOS and on s2), under `"auto"` and `"planar"`. Record the exact error.
- [ ] Implement C1 and C2. Repair once per row, only where `st_is_valid()` is FALSE or NA, so valid rows pay one validity check and nothing else. Use the repaired copy for the candidates, the touch test and `geo_planar_parts()`.
- [ ] Tests:
  1. The bowtie-hole polygon under `"planar"` and under `"auto"`: no error. The cells equal those of `sf::st_make_valid()` of the polygon geocoded under `"planar"`. Shares sum to 1. The stored geometry read back is the original, byte-identical WKB.
  2. A self-intersecting outer ring (figure eight) wider than a cell: same expectations.
  3. Valid rows in the same chunk are unchanged (cells and shares identical to writing them alone).
  4. A row whose repair is empty or of lower dimension (e.g. a zero-area polygon wider than a cell, if GEOS repairs it to a line): no error, and the documented behaviour of C1.
- [ ] Run `testthat::test_local(filter = "geo-(engine|encode|cells|verbs)")`.
- [ ] Report: the reproduction error, diff summary, counts, `session closed`.

### WP3-V. Verify C (verifier, Opus, fresh session)

- [ ] Review the diff against C1–C2. Run `testthat::test_local(filter = "geo-(engine|encode|cells|verbs|h3)")`.
- [ ] Re-run Appendix B and the WP3 bowtie repro.
- [ ] PASS or FAIL, then `session closed`.

### WP4. Regression on everything that geocodes (verifier, Opus, fresh session)

- [ ] `devtools::load_all()`, then each separately (so a failure is attributable), reporting counts and failures verbatim:
  - `testthat::test_local(filter = "geo-")`
  - `testthat::test_local(filter = "write-duckdb-geo")`
  - `testthat::test_local(filter = "^write$")`, or the filter that selects `test-write.R` alone
  - `testthat::test_local(filter = "intersects")`
  - `testthat::test_local(filter = "read")`
- [ ] Not the full suite. A file over 10 minutes may be run as a pre-approved long job in the agent's own session.
- [ ] Style pass on the changed lines only, with the `r-lib:r-tidyverse-style` skill, read-only: report issues, do not edit.
- [ ] PASS or FAIL, then `session closed`. On FAIL, the orchestrator routes it to the writer of the work package concerned, then repeats that WP's verification and WP4.

### WP5. Acceptance on the reporter's data (two verifiers in parallel, Opus, fresh sessions, read-only)

Each agent writes to a store under its own `tempdir()`, uses the default engine `"auto"` and default options, runs as a long job, and reports elapsed time, the D32 warning verbatim (counts and first keys), the number of rows written and of index rows, and any error verbatim.

- [ ] **WP5a.** `adm6_koatuu.parquet`, all 18,730 rows, key `adm6_id`. Then the UA05 subsets of the report (all 713; the 369 sphere-invalid; the 344 valid) and rows 341, 342, 343, 354, 363 alone. Every write must succeed.
- [ ] **WP5b.** `adm7_zone.parquet`, all 77,225 rows (key: inspect the columns). It must succeed.
- [ ] Optional, non-blocking, in WP5a's session after its runs: explain the reporter's chunk dependence (fact 9). For example, run the 369-row and 713-row UA05 sets on a git worktree at `8b3fa5f` (pre-fix; `devtools::load_all()` from that worktree, in the agent's own session; remove the worktree after) and look at which rows reach the interior branch. A short explanation in the report is enough.
- [ ] If either run fails, the orchestrator has a diagnosis agent reduce the failing row to a synthetic reproduction, then routes it back through the WP concerned (new test included) and repeats WP4 and the failing WP5 run.

### WP6. Report, then release on the owner's OK (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" below, then reports to the owner in a few bullets: cause, the fixes A/B/C, tests run with counts, acceptance results with times. It then **waits for the owner's OK**.
- [ ] On OK, one writer agent (Opus):
  - sets `Version: 0.0.0.9003` in `DESCRIPTION`;
  - runs `devtools::document()` if roxygen changed (C2) and checks that only the expected `man/` files changed;
  - stages explicit paths only (`R/geo-encode.R`, `R/write.R` if changed, `R/intersects.R` if changed, the changed `tests/testthat/*.R`, `DESCRIPTION`, the changed `man/*.Rd`, this plan);
  - commits with a message that has no email address and no AI attribution, e.g. `Geocoding: drop rings collapsed by densifying; rebuilds that stay invalid fall back to the plane; planar engine repairs rows invalid in the plane; version 0.0.0.9003`;
  - pushes `main`;
  - reports the commit hash, `git status` (clean) and `session closed` if it opened R.
- [ ] The orchestrator sets this plan's status to `done` and fills in "Outcome". It does not commit that edit separately unless the owner asks; include it in the release commit by finishing "Outcome" before the writer commits.

## Open questions

- None blocking. If WP5 shows a failure that A–C do not cover, the orchestrator decides whether it is in scope: is it the same abort class, geocoding on polygons? If not, it records it here for the owner.

## Results

Filled in by the orchestrator per work package: PASS/FAIL, counts, deviations from the decisions (with the reason), timings.

## Outcome

Filled in when the status becomes done or superseded.

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
