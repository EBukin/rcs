# Rasters: smallest data type, nodata, COG options, class legend, disk-safe staging; primary-only writes

- **Date:** 2026-11-27
- **Author:** Eduard Bukin
- **Status:** draft

## Goal

When this plan is done:

1. **Part A (raster files).** `store_write()` of a `terra::SpatRaster` writes a Cloud Optimized GeoTIFF that:
   - keeps the source's data type, or uses the smallest type that holds the values (a Byte map stays `INT1U`);
   - carries a NoData value, given with `nodata =`, kept from the source, or chosen automatically;
   - is written with creation options suited to cloud reads (DEFLATE, predictor, 512 × 512 blocks, `BIGTIFF=IF_SAFER`, NEAREST overviews for integers), which `gdal =` overrides;
   - accepts categorical layers: the codes go into the TIFF, the legend goes into the manifest, `store_read()` restores it, and no `.aux.xml` file is ever written;
   - is staged without an uncompressed intermediate, with every temp file below the staging folder, and with a warning when the staging drive looks too small.
   The manifest records per layer: data type, nodata, resolution, dimensions and the legend. Writing stays deterministic.
2. **Part B (primary-only writes).** `store_write(locations = "primary")` writes a dataset to the primary only. The catalog records it. `store_status()` and `store_datasets()` report `"primary only"` instead of `"missing"`; `store_sync(all = TRUE)` and copy on read leave such a dataset alone unless it is named.
3. Every change is test-driven: tests first, shown to fail for the stated reason (red), then the code (green). A separate verifier confirms each step.
4. Peak staging disk use is measured on a simulated 25,000 × 25,000 `INT1U` raster and recorded in "Results".
5. Each part is released as its own development version and committed (not pushed).

Report, measurements and the format decision: `.docs/notes/0004-raster-categorical-cog-and-primary-only.md`. Read it first. Its decisions are final: COG is the only raster format, and time series are out of scope.

## Context

### What exists that this plan builds on

- **Staging a raster.** `raster_stage()` in `R/raster.R` (~line 100). It checks `x` (CRS, values, unique layer names, no categorical layer), writes `part.tif` in a temp folder below `dir` with `terra::writeRaster(x, tmp, filetype = "COG", datatype = <"INT4S" | "FLT8S">)`, hashes it, renames it to `<dataset>/part-<version>.tif`, and builds the entry and the file row. `columns$type` is `terra::datatype()` of the written file; `r_type` is `list(class = "SpatRaster", resolution, dim)`.
- **Opening a raster.** `raster_open(be, path, intersects)` in `R/raster.R` (~line 211): `terra::rast(be_gdal_path(be, path))`, then a crop to the query box. Called from `store_read()` (`R/read.R` ~line 161) and `store_glimpse()` (~line 360).
- **Write pipeline.** `store_write()` in `R/write.R` (~line 274) builds `args` and calls `stage_raster()` (~line 584), which calls `raster_stage()` and writes the manifest. The primary is landed by `land_primary()`, then every secondary by `land_secondary()` (~line 1657) in the loop at ~line 376. Result rows come from `write_result()` / `write_result_row()`.
- **Serialization check.** `check_staged()` (`R/write.R` ~line 1260) calls `check_serialization()`, which for a raster calls `check_raster_values(be, entry, files, x, n)` (`R/check.R` ~line 462): `n` random cells of the file against `x`, compared with `terra::extract()`. `store_check(x = )` uses the same function.
- **Columns specification.** `columns_spec()`, `columns_to_json()`, `columns_from_json()` in `R/schema.R` (~lines 520–605). The list fields kept as JSON arrays are named in two places: `c("levels", "resolution", "dim")`.
- **Optional catalog columns.** `partition_auto` (plan 0004) shows how one is added: `catalog_schema()` (`R/schema.R` ~line 61), `schema_optional` (~line 140), `entry_omitted_when_na` (~line 667), `new_entry()` (~line 416), and every builder that passes `partition_auto =` (grep it in `R/`).
- **Status.** `location_status()` in `R/inspect.R` (~line 27) gives `"same"`, `"differs"`, `"missing"`, `"extra"`, `"unavailable"`; `store_status()`, `store_datasets()` and the print of a connection (~line 417, `symbols`) use it. `r_type` is rendered for `store_describe()` at ~line 537.
- **Staging folder.** `rcs_option("rcs.staging_dir")`, default `tempdir()` (`R/utils.R` ~line 24); documented in `R/rcs-package.R` and in `store_write()` ("Staged files need free room…", `R/write.R` ~line 89).
- **Tests.** `tests/testthat/test-raster.R` stages on local paths without `store_write()` (helper `stage_sim_raster()`); it expects `INT4S` / `FLT8S` and the refusal of categorical layers. Rasters also appear in `test-write.R`, `test-read.R`, `test-check.R`, `test-inspect.R`, `test-integration.R`, `test-hooks.R`, `test-auth.R`, `test-schema.R`, and in the snapshots `raster.md`, `read.md`, `write.md`, `inspect.md`.
- **Docs that describe rasters:** `vignettes/geospatial.Rmd`, `vignettes/locations.Rmd`, `vignettes/rcs.Rmd`, `README.Rmd`, and `.docs/plans/0001-rcs-package.md` (section "Rasters" ~line 287, the `r_type` notes ~line 443, the "Catalog schema" table ~line 75).
- **Plan 0005** (copy on read; sync restricted to the datasets a secondary holds) is a draft on 2026-11-27. Part B builds on it. Part A does not.

### Facts measured (note 0004)

- `writeRaster(filetype = "COG")` writes an intermediate `spat_*.tif` in terra's temp folder (R's `tempdir()`): uncompressed and 4 bytes per cell today; compressed and small when a data type and `gdal` options are given. Peak about 3.6 times the output.
- `sf::gdal_utils("translate", …, "-of", "COG")` from a file writes only a small `.ovr.tmp` next to the output. Peak about 1.5 times the output.
- A categorical layer written by `writeRaster()` creates `<file>.aux.xml` and changes the TIFF's bytes. `terra::set.cats()` on an opened file creates nothing.
- `terra::datatype()` is `""` in memory and the source type when file-backed. `terra::NAflag()` does not report a source file's NoData tag.

### Rules for this plan (on top of CLAUDE.md)

- **Orchestrator** (a fresh session) runs **no code**: no R, and no Bash that builds, tests or edits. It may read files and git state (`git status`, `git diff`, `git log`). It spawns every work package as an Agent, checks each report against the acceptance criteria, ticks the steps, and fills in "Results" and "Outcome". It edits only this plan file.
- **TDD cycle per part.** (1) A **test writer** adds tests only, with no change under `R/`. (2) A **red verifier** confirms in a fresh session that each new test fails for the reason stated here, and that tests marked "guard" pass already. (3) A **code writer** changes `R/` until the tests pass. It may not weaken a test; a test it believes wrong goes back to the orchestrator with the reason. (4) A **green verifier** reads the diff with no prior conclusions, runs the tests and regressions, and runs a mutation check.
- Writers and verifiers are separate agents. Verifiers never edit files. Each verifier gets the decisions, the acceptance criteria and the paths, not the writer's conclusions.
- **Existing tests whose expectations change** because of a decision here are edited by the test writer of that part, in the smallest way, and listed in its report. The changes allowed are named in the steps (A-E1 to A-E4, and WP1's lists). Never delete an expectation that a decision does not overturn. The red verifier checks each edit against the list.
- All R work goes through the `execute:run-r` skill. Each agent starts its own Positron R session and quits it; the owner's console is never touched. At most 3 R sessions at once. Every report ends with `session closed`. If one does not, the orchestrator sends a small agent to `quit()` that session.
- Never run the whole suite (more than 10 minutes). Use `devtools::load_all()` and `testthat::test_local(filter = "...")`.
- Tests use only data from `rcs_sim_*()` or small rasters built in code from it. Every folder goes under `withr::local_tempdir()`. Raster tests start with `skip_if_not_installed("terra")`.
- R style: `r-lib:r-testthat`, `r-lib:r-cli`, `r-lib:r-tidyverse-style`. Messages use cli only, with the classes of the surrounding code (`rcs_error_raster`, `rcs_error_argument`). Internal helpers get the comment / `@noRd` block the file already uses.
- A failed verification goes back to the writer of that step (resumed if possible) with the verifier's findings, then the verification is repeated. After three failed rounds the orchestrator stops and reports to the owner.
- Commits are staged by explicit paths, with no email address and no AI attribution. **No push** unless the owner asks.

### Parallel schedule

Writers of code run strictly in sequence, because Parts A and B both edit `R/write.R`, `R/read.R`, `R/inspect.R` and `R/schema.R`. The table gives what may run at the same time (at most 3 R sessions).

| Stage | Runs in parallel | Waits for |
|---|---|---|
| 1 | WP1 (survey A) ∥ WP6 (survey B, only if Part B runs) | WP0 |
| 2 | WP2 (tests A) | WP1 |
| 3 | WP2-V | WP2 |
| 4 | WP3 (code A) ∥ WP7 (tests B: new test file only) | WP2-V; WP7 also WP6 |
| 5 | WP3-V ∥ WP7-V (the checks that need no Part A code) | WP3; WP7 |
| 6 | WP4 (measurement) ∥ WP5-docs (docs A) | WP3-V |
| 7 | WP5 (release A) | WP4, WP5-docs |
| 8 | WP7 edits to existing test files, then WP8 (code B) | WP5, WP7-V |
| 9 | WP8-V | WP8 |
| 10 | WP9 (docs B, release B) | WP8-V |

### Decisions taken (do not ask the owner about these)

Part A, new arguments of `store_write()`, placed after `crs`: `datatype = NULL`, `nodata = NULL`, `gdal = NULL`. Given for an `x` that is not a `SpatRaster`, each aborts with `rcs_error_argument` ("applies to rasters only"). `raster_stage()` takes the same three arguments; `stage_raster()` passes them on.

- **D-A1. Supported data types:** `INT1U`, `INT2U`, `INT2S`, `INT4U`, `INT4S`, `FLT4S`, `FLT8S`. One type for all layers of a dataset, as a GeoTIFF requires. Any other `datatype` value aborts with `rcs_error_argument` and lists the seven.
- **D-A2. Choosing the type** (first rule that applies):
  1. `datatype` is given: that type.
  2. Every layer is file-backed (`terra::datatype(x)` has no `""`), all layers have the same type, and it is one of the seven: that type. So a Byte source stays `INT1U` and an `FLT4S` source stays `FLT4S`, with no pass over the cells.
  3. Every layer is integer (`terra::is.int(x)`): the first of `INT1U`, `INT2U`, `INT2S`, `INT4U`, `INT4S` whose range holds the smallest and largest value of all layers (`terra::minmax(x, compute = TRUE)`, missing cells ignored) and still leaves room for the nodata value of D-A3. When none does: `FLT8S`.
  4. Otherwise `FLT8S`. In-memory doubles are never narrowed to `FLT4S` silently; `datatype = "FLT4S"` asks for it.
- **D-A3. Nodata.** One value for all layers. First rule that applies:
  1. `nodata` is given: one finite number, representable in the chosen type (a whole number inside the type's range for integer types). Otherwise abort with `rcs_error_argument`. Cells that hold this value are missing when read back; this is the purpose (a map whose `0` means "outside") and the roxygen says so.
  2. A flag set on `x` in the session (`terra::NAflag(x)` finite). Layers with different flags abort with `rcs_error_raster` and ask for `nodata`.
  3. The NoData tag of the source file, when `x` is file-backed (read by the method WP1 fixes). Bands with different tags abort as in 2.
  4. Integer type chosen by D-A2 rule 3: the type's default flag, `255` (`INT1U`), `65535` (`INT2U`), `-32768` (`INT2S`), `4294967295` (`INT4U`), `-2147483648` (`INT4S`). D-A2 rule 3 picks a type whose range holds the values **without** that flag (for `INT1U`: values in 0–254).
  5. Integer type from D-A2 rule 1 or 2 with none of the above: when `x` has missing cells (`terra::global(x, "isNA")` > 0 in any layer, computed only in this case), the type's default flag, and it aborts with `rcs_error_raster` if a value equals that flag; with no missing cells, no NoData tag is written.
  6. Float types: no tag; missing cells are `NaN` in the file, as today.
  The value is always passed to GDAL explicitly (never left to terra's default) and recorded per layer as `r_type$nodata` (a number; the field is absent when there is none).
- **D-A4. Values must fit.** With an explicit `datatype` of an integer type, the smallest and largest value (`terra::minmax(x, compute = TRUE)`) must lie in the type's range and `x` must be all integer; otherwise abort with `rcs_error_raster`, naming the range found and the type. `datatype = "FLT4S"` on doubles is allowed (it rounds; see D-A9).
- **D-A5. GDAL creation options.** Defaults, as `KEY=VALUE`: `COMPRESS=DEFLATE`, `PREDICTOR=YES`, `BLOCKSIZE=512`, `BIGTIFF=IF_SAFER`, `OVERVIEW_RESAMPLING=NEAREST` for an integer type and `OVERVIEW_RESAMPLING=AVERAGE` for a float type. `gdal` is `NULL` or a character vector of `KEY=VALUE` strings (anything else aborts with `rcs_error_argument`); a key given there replaces the default of the same key (keys compared in upper case), and other keys are added. The final options are sorted by key before use, so the order given does not change the file. One internal function, `raster_gdal_options(datatype, gdal)`, returns them. No option is recorded in the catalog: GDAL keeps them in the file. A dataset written again after this plan gets a new version even when its cells are unchanged, because the bytes differ; the roxygen of `store_write()` says so.
- **D-A6. Categorical layers are accepted.** For each layer with `terra::is.factor()`:
  - the legend is the active category (`terra::cats()` and `terra::activeCat()`): the code column and the active label column. Other columns of the category table are dropped, with one `rcs_inform()` line naming them;
  - codes must be whole numbers, unique and not missing; labels must not be missing. Otherwise abort with `rcs_error_raster`;
  - the layer is written **without** its categories: staging works on a copy of `x` whose levels are removed (`levels(copy) <- NULL`; `x` itself is never changed), so the TIFF holds codes only and no `.aux.xml` appears. After writing, `raster_stage()` asserts that the temp folder holds exactly one file and aborts (internal error) otherwise;
  - the legend is recorded in the layer's `r_type`: `values` (the codes, numbers), `levels` (the labels, character, same order as `values`, sorted by code) and `levels_name` (the name of the label column). Add `"values"` to the two field lists in `columns_to_json()` / `columns_from_json()`;
  - a categorical layer counts as integer for D-A2. The same raster with and without its categories gives the same file and the same version; only the manifest differs. The entry's `columns` differ, so the catalog is updated (see how `resolve_target()` treats "the same version with another entry", `R/write.R` ~line 1220).
- **D-A7. Reading restores the legend.** `raster_open()` gets a fourth argument `columns = NULL`, the spec tibble of the entry (`columns_from_json(entry$columns)`). For each layer whose `r_type` has `values`, it calls `terra::set.cats(r, layer = i, value = <data frame with the columns value and levels_name>)` before any crop. Both callers in `R/read.R` pass the entry's columns. The type and the NoData tag come from the file itself. Nothing is written next to the file; a read from a read-only or remote location must work.
- **D-A8. Describing.** `store_describe()` shows a raster layer as, for example, `raster layer (12 x 16 cells, nodata 0, 5 classes)`; the two additions appear only when recorded (`R/inspect.R` ~line 537).
- **D-A9. Serialization check.** `check_raster_values()` compares what a read would return:
  - both sides are compared as codes, never as labels (WP1 names the `terra::extract()` call that returns codes for a categorical `x`);
  - reference cells equal to the entry's `r_type$nodata` count as missing;
  - for a stored type `FLT4S`, values are equal when they differ by at most `1e-6` relative (`abs(a - b) <= 1e-6 * pmax(1, abs(b))`); all other types compare exactly, as today.
- **D-A10. Two ways to write the file**, chosen inside one internal function `raster_write(x, file, datatype, nodata, options)`:
  - **Translate path**, `sf::gdal_utils("translate", source, file, options = c("-of", "COG", "-ot", <GDAL type name>, "-a_nodata", <value> (when there is one), "-norat", "-co", <option> …))`. Used when `x` is an unchanged view of one file: one source file for all layers, no layer in memory, no window (`terra::window()`), same dimensions, extent, layer count and layer names as `terra::rast(<that file>)`, and the layers in band order. After it, any `<file>.aux.xml` is deleted. GDAL type names: `Byte`, `UInt16`, `Int16`, `UInt32`, `Int32`, `Float32`, `Float64`.
  - **terra path**, `terra::writeRaster(copy, file, filetype = "COG", datatype = , NAflag = , gdal = , overwrite = TRUE)`, for everything else (in memory, computed, renamed, cropped, several sources).
  - Both paths must give a file that reads back with the same values, type, NoData tag, layer names, 512 blocks and overviews. They need not give the same bytes. Each path is deterministic for the same input.
  - **Fallback rule.** If WP1 finds that the translate path cannot keep the layer names, cannot be made deterministic, or leaves category data in the TIFF that `-norat` does not remove, the plan uses the terra path only. The orchestrator records the branch in "Results" before WP2, and tests A-T15 and the translate half of A-T14 are dropped.
- **D-A11. Temp files stay in the staging folder.** During `raster_write()`, terra's temp folder is the temp folder `raster_stage()` already makes below `dir` (`terra::terraOptions(tempdir = , print = FALSE)`), and the previous value is restored on exit, also after an error. The temp folder is removed on exit as today.
- **D-A12. Free space.** Before writing, `raster_stage()` warns (class `rcs_warning_staging_space`, `cli_warn()`) when the free space of the staging drive is below the estimate. Estimate: for a file-backed `x`, 2 times the size of its source files; for an in-memory `x`, no check. Free space comes from one internal function `disk_free(path)` that returns bytes, or `NA` when it cannot tell (then no warning). It uses `ps::ps_disk_usage()` when the ps package is installed (add `ps` to `Suggests`); WP1 confirms the call on Windows. The warning names the folder, the free space and the estimate (`format_bytes()`), and says to set `options(rcs.staging_dir = )`. It never aborts.
- **D-A13. Unchanged.** One file per dataset; no partition, key or update; the CRS, extent and layer-name rules; `rows` = cells; the version is `version_hash("{}", md5)`; `rcs_sim_raster()` is not changed.
- **D-A14. Version.** Part A is released as the next development version after the one in `DESCRIPTION` at WP0 (`0.0.0.9005` if plan 0005 is not released yet, else `0.0.0.9006`). There is no NEWS.md; do not create one.

Part B, primary-only writes (runs only when plan 0005 is `done`; see WP0):

- **D-B1. New argument `store_write(locations = NULL)`**, placed after `gdal`. `"primary"`: write to the primary only. `"all"`: write to every location. `NULL`: keep the dataset's stored setting; `"all"` for a new dataset. Anything else aborts with `rcs_error_argument`. It applies to every kind of dataset.
- **D-B2. New optional catalog column `primary_only`** (`arrow::boolean()`, after `partition_auto`), added the way `partition_auto` was: `catalog_schema()`, `schema_optional$catalog`, `entry_omitted_when_na`, `new_entry()`, and every entry builder. `TRUE` for a primary-only dataset, `NA` otherwise (never `FALSE`), so that the manifests and catalogs of all other datasets keep their bytes. The index table of a geospatial dataset carries the same value. `locations = "all"` on a primary-only dataset sets it back to `NA` and writes everywhere.
- **D-B3. Writing.** With the setting resolved to primary-only, the secondaries are not landed and not contacted beyond the catalog refresh `store_write()` already does. Each secondary gets a result row with status `"primary only"`, `files` `NA`, `uploaded` 0, `bytes` 0. A secondary that already holds the dataset is left as it is; one `rcs_inform()` line names it and says that `store_sync(st, datasets = "<name>")` updates it.
- **D-B4. Status.** In `location_status()`, a dataset the target lacks whose source entry has `primary_only` `TRUE` has status `"primary only"` instead of `"missing"`. A target that holds it is compared as any other (`"same"` / `"differs"`). `store_status()`, `store_datasets()` and the print of a connection use the new value (its own symbol and legend entry in the print; the count of missing datasets no longer includes it). `store_check()` is unchanged.
- **D-B5. Sync.** `store_sync(all = TRUE)` does not copy a primary-only dataset to a secondary that lacks it; it is reported with the datasets not copied (plan 0005, D-A3/D-A4), with one line that names `datasets =` as the way to copy it. `store_sync(datasets = "<name>")` and `store_copy()` copy it. The default sync (plan 0005, D-A2) needs no change: it never copies a dataset a secondary lacks, and refreshes one it holds.
- **D-B6. Copy on read.** `store_read()` does not copy a primary-only dataset to a secondary that lacks it, whatever its size (plan 0005, D-B2 gains this condition). It reads from the primary and informs once: `"<name>" is kept in the primary only; reading from <uri>. Use copy = TRUE to copy it.` `copy = TRUE` copies. A secondary that holds an older version is refreshed as plan 0005 says.
- **D-B7. Version.** Part B is released as the next development version after Part A's.

## Steps

### WP0. Preflight (orchestrator, no code)

- [ ] `git status` is clean (this plan and note 0004 are committed). Otherwise ask the owner.
- [ ] Read `DESCRIPTION` and the status line of `.docs/plans/0005-copy-on-read-and-restricted-sync.md`. Record both in "Results".
  - Plan 0005 `done`: Parts A and B both run.
  - Plan 0005 `draft`: only Part A runs (WP1–WP5). After WP5 the orchestrator leaves this plan `active`, writes in "Results" that Part B waits for plan 0005, and reports to the owner.
  - Plan 0005 `active` (being executed by someone else): stop and report to the owner; both plans edit `R/read.R` and `R/write.R`.
- [ ] Set this plan's status to `active`.

### Part A. Raster files

#### WP1. Survey A (investigator, may run R; no edits to the repo)

Scripts and files go in the agent's scratchpad. Each answer is a fact with the code that showed it.

- [ ] **Source NoData tag (D-A3 rule 3).** Find a reliable way to read the NoData tag of each band of a file-backed `SpatRaster`'s source (candidates: `terra::describe(file, options = "json")` parsed with jsonlite; `sf::gdal_utils("info", file, options = "-json")`). Test on files with a tag of 0, with another tag, and without a tag, for `INT1U` and `FLT4S`. Name the function to write (input, output).
- [ ] **File-backed detection (D-A2 rule 2, D-A10).** Show what `terra::datatype()`, `terra::sources()` (with `bands = TRUE`), `terra::inMemory()` and `terra::window()` return for: a raster read from a file; one layer subset of it; a renamed one; a cropped one; a computed one (`x * 1L`); `c()` of two files; one with `levels<-` set; one with `NAflag<-` set. Give the exact condition for "an unchanged view of one file".
- [ ] **Translate path (D-A10).** With `sf::gdal_utils("translate")` and the D-A5 options on a stripped LZW `INT1U` source without a NoData tag: confirm type, `-a_nodata`, 512 blocks, overviews, band descriptions (layer names) kept, the same MD5 on two runs, and no `.aux.xml` (also when the source has its own `.aux.xml` with categories, with `-norat`). Compare the values with the terra path. State the branch of the fallback rule.
- [ ] **Removing levels (D-A6).** Confirm that `levels(copy) <- NULL` on a file-backed raster reads no cells and leaves `x` and its source untouched, that the written TIFF has the same MD5 as the one written from the raster without categories, and that no `.aux.xml` appears. Show how to get codes, labels and the label column name from `terra::cats()` / `terra::activeCat()`.
- [ ] **Restoring levels (D-A7).** Confirm that `terra::set.cats()` on a raster opened from a file writes nothing next to it, that `terra::crop()` keeps the categories, that `terra::datatype()` still reports the file's type, and that it works on a multi-layer raster with one categorical layer.
- [ ] **Codes in the check (D-A9).** Name the `terra::extract()` call (or other) that returns codes, not labels, for a categorical raster at given cell numbers.
- [ ] **Temp folder (D-A11).** Confirm that `terra::terraOptions(tempdir = )` moves the `spat_*.tif` intermediate of `writeRaster(filetype = "COG")`, how to read the current value, and that restoring it works. Say where GDAL puts `.ovr.tmp`.
- [ ] **Free space (D-A12).** Confirm `ps::ps_disk_usage()` (or the right call) returns free bytes for a folder on Windows; give the code of `disk_free()`.
- [ ] **Overview resampling test.** Find a way for a test to see the resampling of the overviews (candidates: `terra::rast(file, opts = "OVERVIEW_LEVEL=0")`; the `OVERVIEW_RESAMPLING` item in `terra::describe()`), and a small raster (at least 1,100 × 1,100 cells) on which NEAREST and GDAL's default differ.
- [ ] **Existing tests and snapshots.** List every test and snapshot that depends on `INT4S` for integers, on the refusal of categorical layers, on the text `raster layer (… cells)`, or on a raster file's MD5 or version, with file, line and the smallest edit.
- [ ] Report the facts, the D-A10 branch, the lists, and `session closed`. The orchestrator copies them into "Results".

#### WP2. Red tests for Part A (test writer)

Files: `tests/testthat/test-raster.R` (new tests under a comment `# Plan 0006: types, nodata, options, legend, staging`), `tests/testthat/test-write.R`, `test-read.R`, `test-check.R`, `test-inspect.R` (one group each, under the same comment), `tests/testthat/helper-sim.R`. No change under `R/`.

Helper, in `helper-sim.R`: `sim_landcover(nrow = 60, ncol = 80, seed = 1, file = NULL, legend = FALSE)`. It returns the layer `cover` of `rcs_sim_raster()` as whole numbers 1–5, named `cover`, with a band of `0` two cells wide around the edge ("outside the map"). With `file`, it is written there as a plain stripped LZW `INT1U` GeoTIFF with no NoData tag and returned file-backed. With `legend = TRUE`, the levels `data.frame(value = 1:5, label = c("water", "forest", "crop", "grass", "bare"))` are set.

Each `test_that()` is named by the behaviour; its comment states the expected red reason.

- [ ] **A-T1 (red).** In-memory whole numbers 1–5 with missing cells: stored type `INT1U`, `r_type$nodata` 255, values and missing cells equal after stage and open. Red: `INT4S`.
- [ ] **A-T2 (red).** The type follows the range (D-A2 rule 3), one small raster each: largest value 254 → `INT1U`; 255 → `INT2U`; smallest −5 → `INT2S`; largest 70,000 → `INT4U`; smallest −70,000 → `INT4S`. Each round-trips. Red: all `INT4S`.
- [ ] **A-T3 (guard).** In-memory doubles stay `FLT8S` and round-trip exactly.
- [ ] **A-T4 (red).** File-backed `sim_landcover(file = )` with `nodata = 0`: `terra::describe()` of the staged file shows `Type=Byte` and `NoData Value=0`; the edge cells read as missing; `r_type$nodata` is 0; the stored type is `INT1U`. Red: unused argument `nodata`.
- [ ] **A-T5 (red + guard).** A file-backed `FLT4S` source stays `FLT4S` (red: `FLT8S`). A file-backed `INT4S` source with small values stays `INT4S` (guard).
- [ ] **A-T6 (red).** A file-backed `INT2S` source with a NoData tag of −1 and no `nodata` argument: the tag is kept and recorded. A flag set with `terra::NAflag(x) <- 9` wins over the source tag; `nodata = 7` wins over both.
- [ ] **A-T7 (red).** Explicit `datatype`: `"FLT4S"` on in-memory doubles is stored as `FLT4S`; `"INT1U"` with a value of 300 aborts with `rcs_error_raster`; `"INT1U"` on doubles with fractions aborts with `rcs_error_raster`; `"INT8S"` and `1L` abort with `rcs_error_argument`; `nodata = 300` with `INT1U`, `nodata = 0.5` with an integer type, `nodata = NA` and `nodata = c(0, 1)` abort with `rcs_error_argument`. Snapshot one message of each class.
- [ ] **A-T8 (red).** An explicit type with missing cells (D-A3 rule 5): `datatype = "INT2S"` on in-memory values 1–5 with missing cells is stored as `INT2S` with nodata −32768 and round-trips; `datatype = "INT1U"` on in-memory values that include 255 and missing cells aborts with `rcs_error_raster`; `datatype = "INT1U"` on in-memory values 0–255 without missing cells is stored with no NoData tag (`r_type` has no `nodata`).
- [ ] **A-T9 (red).** Layout, on a 1,100 × 1,100 `sim_landcover()`: `terra::describe()` shows `Block=512x512`, `COMPRESSION=DEFLATE`, `LAYOUT=COG` and overviews; the overviews hold only the class codes of the raster (WP1's method), on WP1's raster where averaging would give other values. Red: block size or resampling of GDAL's defaults (state which in the comment after running).
- [ ] **A-T10 (red).** `gdal = c("COMPRESS=LZW", "BLOCKSIZE=256")` gives `COMPRESSION=LZW` and `Block=256x256` and keeps the other defaults; `gdal = c("blocksize=256")` equals `"BLOCKSIZE=256"`; the order of `gdal` does not change the MD5; `gdal = "COMPRESS"`, `gdal = 1` and `gdal = NA_character_` abort with `rcs_error_argument`.
- [ ] **A-T11 (red).** `sim_landcover(legend = TRUE)` is accepted. The staging folder holds exactly the data file (no `.aux.xml`, listed with `all.files = TRUE`). The layer's `r_type` has `values` 1:5, `levels` the five labels and `levels_name` `"label"`. The MD5 and the version equal those of `sim_landcover()` without the legend. A round trip of `columns_to_json()` / `columns_from_json()` keeps the three fields with their types. `x` still has its levels afterwards. Red: categorical layers abort.
- [ ] **A-T12 (red).** Bad legends abort with `rcs_error_raster`: a duplicated code, a missing label. A category table with a third column informs once, naming the dropped column (snapshot), and stores the active one; with `terra::activeCat(x) <- 2` the second label column is the one stored.
- [ ] **A-T13 (red).** `raster_open(be, path, columns = <spec>)` returns a categorical raster: `terra::is.factor()` is `TRUE`, `terra::cats()` equals the legend, `terra::datatype()` is `INT1U`. With `intersects`, the cropped raster keeps the categories. Without `columns`, the raster holds codes. The folder of the file holds no new file after opening. A three-layer raster with one categorical layer restores that layer only.
- [ ] **A-T14 (red).** Staging. After staging a file-backed and an in-memory raster, R's `tempdir()` holds no new `spat_*` file and the staging folder holds only the data file; `terra::terraOptions(print = FALSE)$tempdir` is what it was before, also after a staging that aborts (`datatype = "INT1U"` with a value of 300). With `disk_free()` mocked (`local_mocked_bindings()`) to return 1, staging a file-backed raster warns with class `rcs_warning_staging_space` and still writes; mocked to `NA`, and for an in-memory raster, no warning. Snapshot the warning with the folder masked.
- [ ] **A-T15 (red; dropped under the fallback branch).** The path taken, seen by mocking `raster_write_translate()` and `raster_write_terra()` (or the names WP3 is told to use: fix them here and in WP3) with counting wrappers: the translate path for `sim_landcover(file = )` unchanged; the terra path for an in-memory raster, a renamed one, a cropped one, one layer of a three-layer file, and one with a legend whose source has other layer names. Both paths read back with equal values, type, NoData tag and names.
- [ ] **A-T16 (red + guard).** Determinism: two stagings give the same MD5 and version for (a) file-backed `INT1U` with `nodata = 0` and a legend, (b) in-memory `INT1U`, (c) `FLT4S`. Another `nodata` gives another version.
- [ ] **A-T17 (red), `test-write.R` / `test-read.R`.** Through the public functions, with a primary and a local secondary: `store_write(st, sim_landcover(file = , legend = TRUE), "grids/cover", …, nodata = 0)`, then `store_read()`: categorical, `INT1U`, edge cells missing, values equal as codes; the same from the secondary; `store_read(intersects = <box>)` keeps the categories. The manifest file read from disk (`jsonlite`) holds for the layer: type `INT1U`, nodata 0, resolution, dim, values and levels. A second identical write uploads nothing. `datatype`, `nodata` or `gdal` given with a data frame aborts with `rcs_error_argument` (snapshot one).
- [ ] **A-T18 (red), `test-check.R`.** The serialization check passes for the write of A-T17 (reference cells equal to nodata count as missing; codes compared with codes) and for `datatype = "FLT4S"` on in-memory doubles; `store_check(st, "grids/cover", x = <the raster>)` reports `"ok"`; with one cell of the reference changed inside the sampled cells (set `n` to the number of cells of a small raster) it reports `"failed"`.
- [ ] **A-T19 (red), `test-inspect.R`.** Snapshot of `store_describe()` for the dataset of A-T17: the layer line shows the cells, `nodata 0` and `5 classes`. A plain float raster shows neither addition (guard on the existing snapshot text).
- [ ] **A-T20 (level `full`, GCS; skipped otherwise).** Extend "a raster opens from GCS through /vsigs/": a staged `sim_landcover(file = , legend = TRUE)` with `nodata = 0`, opened with `columns` and `intersects`, is categorical, `INT1U`, with equal values.
- [ ] **Edits to existing tests** (the only ones allowed; plus those on WP1's list that follow from the same decisions):
  - **A-E1.** "integer layers are stored as integers": the expected type becomes the one D-A2 rule 3 gives for that raster (compute it from the values in the test; do not hard-code a guess).
  - **A-E2.** "raster_stage() aborts on unusable rasters": the categorical expectation and its snapshot are removed; A-T11 replaces them. Every other expectation stays.
  - **A-E3.** Snapshots that show a raster's version, bytes or the layer description: regenerated only after WP3, by the code writer, and reviewed by WP3-V line by line.
  - **A-E4.** Tests that compare a raster file's bytes or MD5 with a fixed value: none are expected; any found by WP1 are reported, not edited.
- [ ] Run `testthat::test_local(filter = "raster")`, then `^write$`, `^read$`, `check`, `inspect`, `integration`, `hooks`, `schema` separately. Report each new test red or green with the first line of its failure, the edited tests, and `session closed`.

#### WP2-V. Red verification (verifier, fresh session)

- [ ] Read only the test diff, D-A1–D-A14, the D-A10 branch in "Results" and note 0004. Check that the tests encode the decisions, that no test depends on another test's state, that every folder is under `withr::local_tempdir()`, and that no test uses data other than `rcs_sim_*()`.
- [ ] Check the edits to existing tests against A-E1–A-E4 and WP1's list: nothing else was removed or weakened.
- [ ] Run the same filters. Every red test fails for the reason in its comment, not for a setup error; every guard passes; every untouched existing test passes. `git diff --stat -- R/` is empty.
- [ ] PASS or FAIL with reasons, then `session closed`.

#### WP3. Code for Part A (code writer)

Files: `R/raster.R`, `R/write.R` (the three arguments, their checks, `stage_raster()`, roxygen), `R/read.R` (pass the columns to `raster_open()`), `R/check.R` (D-A9), `R/inspect.R` (D-A8), `R/schema.R` (`"values"` in the two field lists; the `r_type` table in the roxygen), `R/utils.R` (`disk_free()`), `DESCRIPTION` (`ps` in `Suggests`).

- [ ] D-A1–D-A13, with these internal functions in `R/raster.R`, each with a comment or `@noRd` block: `raster_datatype(x, datatype, nodata)` (D-A2, D-A4), `raster_nodata(x, datatype, nodata)` (D-A3), `raster_source_nodata(x)` (WP1's method), `raster_gdal_options(datatype, gdal)` (D-A5), `raster_legend(x)` (D-A6; a list per layer or `NULL`), `raster_is_file_view(x)` (WP1's condition), `raster_write()`, `raster_write_translate()`, `raster_write_terra()` (D-A10, D-A11). Update the header comment of the file (the rules list) to the new rules.
- [ ] Roxygen of `store_write()`: the three arguments; in the raster bullet of the details, the type rule, the nodata rule (with the sentence that cells holding the nodata value read back as missing), the default options and how `gdal` overrides them, categorical layers, that only COG is written, that a raster written before this version gets a new version when written again, and the staging note (temp files below `rcs.staging_dir`; free room of about twice the output; the warning). Roxygen of `store_read()`: a categorical raster is returned with its categories. Do not run `devtools::document()` yet (WP5 does).
- [ ] Run `testthat::test_local(filter = "raster")` and the regression filters of WP2 until green. Do not edit tests, except to regenerate the snapshots of A-E3 (`testthat::snapshot_accept()` for those files only), listing every changed snapshot line in the report.
- [ ] Report: diff summary, counts per filter, the snapshot changes, `session closed`.

#### WP3-V. Green verification (verifier, fresh session)

- [ ] Read the `R/` diff with no prior conclusions against D-A1–D-A13. Look for: a pass over all cells where rule 2 of D-A2 should avoid one; `x` modified by the caller's reference (levels removed from the user's object); terra's temp folder not restored after an error; an `.aux.xml` that can survive; nodata left to terra's default; options applied in the order given; `raster_open()` writing next to the file; bare `stop()` / `warning()` / `message()`.
- [ ] Review every changed snapshot line (A-E3): each change follows from a decision.
- [ ] Run, each separately, reporting counts and failures verbatim: `raster`, `^write$`, `^read$`, `check`, `inspect`, `schema`, `integration`, `hooks`, `sim`, `catalog`, `^sync$`.
- [ ] Mutation check, in the R session only (never edit files), with `local_mocked_bindings()` or `assignInNamespace()`:
  - `raster_datatype()` always returns `"INT4S"`: A-T1, A-T2, A-T4, A-T5 must fail.
  - `raster_nodata()` always returns `NULL`: A-T1, A-T4, A-T6 must fail.
  - `raster_gdal_options()` returns `character()`: A-T9, A-T10 must fail.
  - `raster_legend()` returns `NULL` for every layer: A-T11, A-T13, A-T17, A-T19 must fail.
  - `raster_is_file_view()` always `FALSE` (when the translate path is in use): A-T15 must fail; every other raster test must still pass.
  Report which tests failed; a mutation no test catches is reported as a gap.
- [ ] PASS or FAIL, then `session closed`.

#### WP4. Measurement (verifier, own session; after WP3-V; parallel with WP5-docs)

Script in the agent's scratchpad; nothing written to `bench/` or `output/`. Simulated data only.

- [ ] Build a file-backed `INT1U` raster of 25,000 × 25,000 cells in EPSG:32636 at 10 m, stripped, LZW, without a NoData tag: a 250 × 250 raster of whole numbers 0–27 (seeded), enlarged 100 times with `terra::disagg(filename = , datatype = "INT1U")`.
- [ ] Stage it with `raster_stage(nodata = 0)` into a staging folder of its own, with a legend of 27 classes. While it runs, a background process (`callr::r_bg()`, development only) records every 0.2 s the total size of the files below the staging folder and of new files in R's `tempdir()` outside it. Record: seconds, output bytes, peak bytes in the staging folder, peak bytes outside it. Remove terra's temp files between runs (`terra::tmpFiles(remove = TRUE)`), so one run does not count another's files.
- [ ] The same for the raster read into memory (`terra::rast()` then `+ 0L`, or `terra::toMemory()`), which takes the terra path.
- [ ] Check the staged file: `Type=Byte`, `NoData Value=0`, `Block=512x512`, overviews, and equal values against the source on 1e5 random cells.
- [ ] Expected: output within 1.5 times the source file; nothing new outside the staging folder; peak in the staging folder at most 2 times the output on the translate path. The terra path's peak is reported as measured (about 3.6 times in note 0004); it is documented, not a failure.
- [ ] Report the table, PASS or FAIL against the expectations, `session closed`. On FAIL the orchestrator routes back to WP3.

#### WP5-docs. Documentation for Part A (writer; after WP3-V; parallel with WP4)

Files: `vignettes/geospatial.Rmd`, `README.Rmd` (only if it describes raster types), `.docs/plans/0001-rcs-package.md` (section "Rasters", the `r_type` notes; mark the edits "(changed in plan 0006)").

- [ ] In the raster section of `vignettes/geospatial.Rmd`: a class map made from `rcs_sim_raster()[["cover"]]` with levels, written with `nodata`, read back with its categories and with `intersects`; one paragraph on the data type rule, one on `gdal =` (ZSTD as the example), one on staging room. Vignettes write only below `tempdir()`.
- [ ] Render the edited vignette to a folder under `tempdir()` with `rmarkdown::render()`; it must run without error. Run `devtools::build_readme()` if `README.Rmd` changed.
- [ ] Report the files changed, the render results, `session closed`.

#### WP5. Release A (orchestrator + one writer)

- [ ] The orchestrator fills in "Results" for Part A (WP1 facts, verdicts and counts, the WP4 table) before the writer commits. If Part B does not run (WP0), it leaves the status `active` and writes why.
- [ ] One writer:
  - sets the version of D-A14 in `DESCRIPTION`;
  - runs `devtools::document()` and checks that only the expected `man/` files changed (`store_write.Rd`, `store_read.Rd`, and any other the diff explains);
  - runs `testthat::test_local(filter = "raster|^write$|^read$|check|inspect")` once more;
  - stages explicit paths only (the changed `R/*.R`, `tests/testthat/*.R`, `tests/testthat/_snaps/*.md`, `man/*.Rd`, `DESCRIPTION`, the edited vignette, `README.Rmd` and `README.md` if changed, `.docs/plans/0001-rcs-package.md`, this plan);
  - commits with no email address and no AI attribution, for example `Plan 0006, part A: rasters keep the smallest data type, carry nodata and a class legend, COG options through gdal =, disk-safe staging; version 0.0.0.900x`;
  - does **not** push; reports the commit hash, `git status` (clean), and `session closed`.
- [ ] The orchestrator reports to the owner in a few bullets: what changed, the tests with counts, the WP4 table, whether Part B runs.

### Part B. Primary-only writes (only when plan 0005 is done)

#### WP6. Survey B (investigator, may run R; no edits to the repo; may run with WP1)

- [ ] **Where the flag goes.** List every place that passes `partition_auto =` or lists the optional catalog columns (grep in `R/` and `tests/`), and the tests that fake an old catalog (`tests/testthat/test-catalog.R`). These are the places `primary_only` must reach.
- [ ] **Invariants.** Read `tests/testthat/helper-invariants.R`, `helper-model.R` and `store_check()`: say which invariants assume that every secondary receives every write, and what each needs so that a primary-only dataset passes.
- [ ] **Plan 0005's code.** Name the function that decides which units a sync sends per target (D-A2 of plan 0005), the helper that sizes what is not copied, the message block, and the copy-on-read gate in `R/read.R`, with lines. Say where D-B5 and D-B6 of this plan hook in.
- [ ] **Status vocabulary.** List every place and every test and snapshot that enumerates the status values (`"same"`, `"differs"`, `"missing"`, …), including the print symbols in `R/inspect.R` and the roxygen of `store_status()` and `store_datasets()`.
- [ ] **Docs.** List the sections of `vignettes/locations.Rmd` and `README.Rmd` that describe which locations a write reaches.
- [ ] Report the lists and `session closed`.

#### WP7. Red tests for Part B (test writer)

Files: new `tests/testthat/test-primary-only.R` (may be written while WP3 runs). Edits to existing test files wait until WP5 has committed. No change under `R/`.

Setup: a primary and one or two local secondaries under `withr::local_tempdir()`; datasets from `rcs_sim_table()`, `rcs_sim_points()` (with an index table) and `rcs_sim_raster(nrow = 20, ncol = 20)`.

- [ ] **B-T1 (red).** `store_write(…, locations = "primary")` for a table: the primary holds it; the secondary's catalog and folder do not (list the folder); the result row of the secondary has status `"primary only"`, `uploaded` 0, `bytes` 0. Red: unused argument.
- [ ] **B-T2 (red).** The primary's catalog entry has `primary_only` `TRUE`; a dataset written without `locations` has `NA`, and its manifest JSON on disk has no `primary_only` field (guard on the bytes of ordinary manifests); the manifest of the primary-only dataset has the field. A catalog file without the column (faked as `test-catalog.R` does for `partition_auto`) reads with `NA` and validates.
- [ ] **B-T3 (red).** `store_status()` and `store_datasets()` give `"primary only"` for it and `"missing"` for a dataset removed from the secondary by hand. Snapshot the print of the connection and of `store_status()`.
- [ ] **B-T4 (red).** A later `store_write(mode = "replace")` without `locations` stays primary-only; with `locations = "all"` it lands in the secondary and the entry's `primary_only` is `NA`. `locations = "secondary"`, `NA` and `c("all", "primary")` abort with `rcs_error_argument` (snapshot one).
- [ ] **B-T5 (red).** A secondary that already holds the dataset: a `replace` with `locations = "primary"` leaves the secondary's files and catalog as they were, informs once (snapshot), and `store_status()` gives `"differs"`.
- [ ] **B-T6 (red).** A geospatial dataset with an index table: neither reaches the secondary; both entries carry the flag.
- [ ] **B-T7 (red).** A raster written with `locations = "primary"`: `store_read()` returns it from the primary with the D-B6 message (snapshot), and the secondary stays without it; `store_read(copy = TRUE)` copies it.
- [ ] **B-T8 (red).** `store_sync()` (default) copies nothing of it; `store_sync(all = TRUE)` copies every other dataset and not this one, lists it in `skipped`, and prints the line of D-B5 (snapshot); `store_sync(datasets = "<name>")` copies it, after which `store_status()` gives `"same"` and a default sync keeps it refreshed after a new primary-only write.
- [ ] **B-T9 (guard).** With no secondary, `locations = "primary"` writes exactly what a normal write does apart from the flag.
- [ ] **B-T10 (red).** Efficiency: with `rcs_trace()`, a primary-only write makes no `bytes_up` and no upload call to the secondary.
- [ ] Apply the edits WP6 listed to existing tests (status vocabulary, invariants), after WP5.
- [ ] Run `testthat::test_local(filter = "primary-only")`, then `^write$`, `inspect`, `^sync$`, `copy-on-read`, `catalog`, `schema`, `integration`, `random-operations` separately. Report the red/green table, the edited tests, `session closed`.

#### WP7-V. Red verification (verifier, fresh session)

- [ ] As WP2-V, for D-B1–D-B7 and WP6's lists. Check that B-T1 fails because of the missing argument and not a setup error, and that every edit to an existing test follows from WP6's list.
- [ ] PASS or FAIL, `session closed`.

#### WP8. Code for Part B (code writer; after WP5 and WP7-V)

Files: `R/write.R`, `R/schema.R`, the entry builders WP6 listed, `R/inspect.R`, `R/sync.R`, `R/read.R`.

- [ ] D-B1–D-B6. Roxygen: `store_write()` (the argument; a paragraph "Primary-only datasets" on what status, sync and reads do with them), `store_status()` and `store_datasets()` (the new status value), `store_sync()` (what `all = TRUE` leaves out), `store_read()` (no copy on read). Do not run `devtools::document()` yet.
- [ ] Run `testthat::test_local(filter = "primary-only")` and the regression filters of WP7 until green. Do not edit tests, except to regenerate snapshots whose change follows from D-B4, listed in the report.
- [ ] Report: diff summary, counts, `session closed`.

#### WP8-V. Green verification (verifier, fresh session)

- [ ] Read the diff against D-B1–D-B6. Look for: `primary_only` written as `FALSE`; a manifest or catalog of an ordinary dataset whose bytes changed; a backend call to a secondary during a primary-only write; `all = TRUE` copying a primary-only dataset; the default sync no longer refreshing a held copy; an old catalog without the column failing to read.
- [ ] Run, each separately: `primary-only`, `^write$`, `^read$`, `copy-on-read`, `^sync$`, `inspect`, `catalog`, `schema`, `history`, `integration`, `crash-points`, `random-operations`, `raster`.
- [ ] Mutation check (session only): the write ignores the setting (lands every secondary): B-T1, B-T5, B-T6, B-T10 must fail. `location_status()` ignores the flag: B-T3 must fail. The sync rule ignores the flag: B-T8 must fail. Report which failed and any gap.
- [ ] PASS or FAIL, `session closed`.

#### WP9. Docs and release B (one writer, then the orchestrator)

- [ ] Writer: in `vignettes/locations.Rmd`, a short section on primary-only datasets (when to use them: large rasters read through the bucket; what status, sync and reads do); the "Catalog schema" table of `.docs/plans/0001-rcs-package.md` gains the `primary_only` row, marked "(added in plan 0006)". Render the vignette under `tempdir()`.
- [ ] The orchestrator fills in "Results" for Part B and "Outcome", and sets the status to `done`, before the commit.
- [ ] Writer: sets the version of D-B7; runs `devtools::document()` and checks the changed `man/` files; runs `testthat::test_local(filter = "primary-only|^write$|^sync$|inspect")`; stages explicit paths; commits, for example `Plan 0006, part B: store_write(locations = "primary") keeps a dataset in the primary only; status, sync and copy on read respect it; version 0.0.0.900x`; does **not** push; reports the hash, `git status`, `session closed`.
- [ ] The orchestrator reports to the owner: what changed, the tests with counts, open questions.

## Open questions

Not blocking. The orchestrator records any new ones here for the owner.

- The national maps themselves (11.8e9 cells, read from `gs://`) cannot be tested in the package, which holds no raw data. After Part A, the owner writes one map from the downstream project and checks the output size, `Type=Byte`, `NoData Value=0`, and a windowed `store_read(intersects = )`.
- Colours of a legend (the QGIS `.qml` palette) are not stored. They could go next to `levels` in `r_type` later.
- Reading a `.qml` legend into a data frame is left to the downstream project.
- Time series (a multi-band stack or a cube format) are out of scope (note 0004).
- A translate path for rasters that are a renamed or subset view of one file would cut the terra path's peak (about 3.6 times the output). Not in this plan.

## Results

(Filled in by the orchestrator: WP0 facts, WP1 and WP6 facts and the D-A10 branch, then each WP's verdict and counts, and the WP4 table.)

## Outcome

(Filled in at WP9, or at WP5 when Part B waits for plan 0005.)
