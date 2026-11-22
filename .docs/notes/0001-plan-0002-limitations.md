# Outcomes and known limitations of plan 0002, to address in the next round

- **Date:** 2026-11-22
- **Author:** Eduard Bukin
- **Summary:** what plan 0002 left open: seven code limitations, the benchmarks not re-run, and a local path in the git history.

## Instruction (verbatim)

> Make a note of those outcomes and limitations. That requires attention in the second round.

## Note

Plan 0002 (`.docs/plans/0002-lazy-duckdb-auth-geo-sync.md`) was finished on 2026-11-22. Final state:

- Whole suite at `full` with GCS: 20,767 expectations, 0 failed.
- Coverage 95.4%.
- `devtools::check(cran = TRUE)` 0/0/0.

The items below need attention in the next round. Details are in the plan's "Results of wave N" and "Outcome".

### Code limitations

1. **Case collisions on Windows.** Partition values that differ only by case (`"A"`, `"a"`) map to the same folder on a case-insensitive file system and collide.
2. **Temporary DuckDB cell tables.** Above 10,000 cells, the DuckDB spatial filter puts the cells in a temporary table `rcs_cells_*`. The table stays on the connection until the connection closes.
3. **`ts_local` time zone differs by engine.** A timestamp without time zone comes back with time zone `"UTC"` from DuckDB and `""` from Arrow. The values are equal.
4. **BIGINT literals in DuckDB arrow mode.** DuckDB pushes BIGINT constants into the Arrow scan as doubles. The package works around it with `IN (SELECT unnest([...]::BIGINT[]))`. Filters users write themselves on BIGINT columns in that mode can still be hit.
5. **`"h3"` mixed with other partition columns** aborts for DuckDB input only. The R (`sf`) path accepts it.
6. **False positive in the unsupported-type check.** A struct field named `HUGEINT` in upper case is rejected, because the check reads the type string.
7. **Distinct-cells fetch for the partition map.** When writing from DuckDB with `partition = "h3"`, the distinct cells come from one query. On a large dataset that result can exceed `rcs.duckdb_batch_rows`.

### Other open items

- **Benchmarks not re-run.** `bench/` was neither run nor re-validated in plan 0002. The results in `bench/results/` and the benchmark articles show the state before it.
- **Local path in the git history.** The local temporary folder path, which contains the user name, is still in commit `a5d65a58a` (main) and on the `gh-pages` branch. Tracked files are clean, and the site build now replaces such paths. Removing them from history needs a rewrite and a force push: an owner decision.
- **Owner review of allowed identity items.** These are allowed but recorded:
  - author bylines in `.docs/`;
  - the GitHub handle in `README`, `_pkgdown.yml` and `DESCRIPTION`;
  - future cloud backends named in plan 0001.
