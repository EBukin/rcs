# Bug: update refused on datasets partitioned by a user `h3_p<r>` column; large lazy DuckDB writes cannot stream

- **Date:** 2026-11-23
- **Author:** Eduard Bukin
- **Summary:** a downstream report of two problems (update on a user `h3_p3` partition aborts; lazy DuckDB writes materialise and sort the whole table), reproduced on 2026-11-23; fix planned in `.docs/plans/0004-h3-user-partition-and-duckdb-streaming.md`.

## Instruction (verbatim)

> Record a new bug, investigate it and come up with a plan on fixing it through the TDD and orchestration:

The bug report as received (reporter's version: 0.0.0.9001; Windows 11, R 4.6.2, local store):

> ### Context
>
> A downstream project writes parcel tables (23.5M rows) to an rcs store, keyed by `id` and partitioned by a user-supplied column `h3_p3`. `h3_p3` is the H3 resolution-3 cell of each parcel, but for 2,950 border parcels the user deliberately assigns the nearest allowed cell instead of the computed parent. So `h3_p3` is a user partition column, not one rcs should recompute.
>
> Two problems together make it impossible to write a wide table (23.5M rows × 79 double columns, about 15 GB uncompressed) on a 32 GB RAM machine with about 21 GB of free disk.
>
> ### Bug 1: update aborts on any dataset partitioned by a column named `h3_p<r>`
>
> ```r
> x <- data.frame(id = 1:5, v = rnorm(5),
>                 h3_p3 = c(rep("831e5afffffffff", 3), rep("831e5cfffffffff", 2)))
> store_write(st, x, "t/plain", key = "id", partition = "h3_p3", mode = "create")
> y <- data.frame(id = 6:7, v = rnorm(2), h3_p3 = "831e5cfffffffff")
> store_write(st, y, "t/plain", key = "id", partition = "h3_p3", mode = "update")
> ```
>
> Actual: `An update keeps the partitioning of "t/plain". ℹ Stored partition: h3. Use mode = "replace" to change it.` Same for sf datasets. With `partition` left out, an sf update aborts with `The column h3_p3 of x differs from the partition column the write computes (5 rows)`, even when every row's `h3_p3` equals its computed parent. Renaming the column to `p3` makes the update succeed, so the trigger is the column name.
>
> Expected: an update keeps the partition stored in the catalog (`h3_p3`); a user-supplied `h3_p<r>` column is taken as given, not recomputed or compared to the computed parent.
>
> ### Bug 2 (or a missing feature): lazy DuckDB writes materialise the whole table and sort it, with no streaming option
>
> - `store_write()` accepts only a data.frame, an sf object, a SpatRaster or a lazy DuckDB table.
> - `duckdb_materialise()` always runs `CREATE TEMPORARY TABLE rcs_write_x AS SELECT *, row_number() OVER () AS ".rcs_tmp" FROM (<query>)`; key, partition and serialization checks and the write read that table; `duckdb_write_files()` then runs `ORDER BY h3_p3, id, .rcs_tmp` over all rows.
> - The temp table and the sort exist at the same time. On a 1.26M-row × 81-column subset the temp table alone was 958 MB against 835 MB of raw data.
> - Files are staged in R's temp folder and then copied into the store, so the output sits on disk twice.
> - `SET preserve_insertion_order = false` makes the write fail the serialization check ("columns id, … differ from x").
> - Scaled to 23.5M rows: about 37 GB of DuckDB memory plus spill, plus about 13 GB of files. The full write failed with `Out of Memory Error: failed to offload data block of size 256.0 KiB (5.5 GiB/5.5 GiB used)` (`memory_limit` 12 GB, spill cap 6 GB). A data.frame input peaked at about 3× the data size in R.
>
> Expected, either: (a) Bug 1 fixed, so the caller can write partition by partition with `"create"` then `"update"`; or (b) `store_write()` streams a lazy table one partition at a time instead of materialising and sorting the whole input. Also worth considering: stage directly in the store, and make the serialization check work with `preserve_insertion_order = false`.
>
> ### Acceptance criteria
>
> 1. The reproduction succeeds for plain and sf data; the catalog still says `h3_p3`.
> 2. An sf update with a user `h3_p3` that differs from the computed parent for some rows keeps those values unchanged.
> 3. Existing behaviour for `partition = "h3"` (automatic) is unchanged.
> 4. Tests cover 1–3.
> 5. If streaming (b) is implemented: peak DuckDB memory plus spill bounded by roughly the largest partition; a test or benchmark shows this.

## Note

### Reproduced on 2026-11-23 (0.0.0.9002, `main` at `d3e3ebc`, own R session, store under `tempdir()`)

| Case | Result |
|---|---|
| table, character `h3_p3`, create | OK; catalog `partition = "h3_p3"` |
| table, update with `partition = "h3_p3"` | `An update keeps the partitioning … Stored partition: h3` |
| table, update without `partition` | `` `partition = "h3"` needs geocoded geospatial data. `` |
| table, same data with column `p3` | create and update OK |
| sf points, character `h3_p3` (one row not the parent), update with `partition` | `Stored partition: h3` |
| sf, same, update without `partition` | `The column h3_p3 of x differs from the partition column the write computes (2 rows)` |
| sf, `rcs_h3` (integer64) `h3_p3` equal to the parents, update with `partition = "h3_p3"` | `Stored partition: h3` |
| sf, same, update without `partition` | OK, but treated as the automatic partition (recomputed) |
| sf, `partition = "h3"`, update with `"h3"` or without | OK (catalog `h3_p5`) |

A further defect found while investigating: `format_partition('{"h3_p3":"831e5afffffffff"}')` returns `"h3_p3 = NA"` with the warning `NAs introduced by coercion to integer64 range`. It renders every `h3_p<r>` value as an integer64 cell, so the update message would show `NA` for a character user column.

### Cause

- The catalog records the written column (`"h3_p3"`) for both an automatic `partition = "h3"` and a user column of that name. Nothing in the catalog says which one it was.
- `stage_update()` (`R/write.R`, ~line 630) decides by name alone: `is_h3 <- grepl("^h3_p[0-9]+$", old_partition)`, then expects `partition = "h3"` and re-plans with `partition_plan(data, "h3")`, which recomputes the parents and calls `check_supplied_partition()` (`R/files.R`); a character column never passes that check.
- It does this for tables too, although a table can never have an automatic partition.
- Bug 2: `stage_duckdb()` (`R/write-duckdb.R`) materialises the whole query (`duckdb_materialise()`) and every later step reads that copy; `"update"` from a lazy table aborts by design (D36). The staging folder is `getOption("rcs.staging_dir")`, so moving it to the store's drive avoids a cross-drive copy but not the double footprint.

### Workaround until the fix ships

- Rename the column (e.g. `p3`) before writing; update then works for tables and sf.
