# Recycled code

Code carried over from earlier work, made neutral and cut down to what the plan
(`.docs/plans/0001-rcs-package.md`) can use. Every file is a starting point: it
was edited by hand and **not run** after editing. Each file's header lists what
the plan changes. Delete this folder once its contents have been absorbed.

`%||%` is used in two files; it is in base R from 4.4.0.

## Where each function goes

| File here | Function | Work package | Target file | Use |
|---|---|---|---|---|
| `parquet-write.R` | `files_write_parquet()` | C | `R/files.R` | Staging writer: WKB geometry column, key-value metadata, zstd, row groups. |
| `parquet-write.R` | `files_columns_json()` | C | `R/files.R` | `columns` JSON (name, Arrow type, description). |
| `parquet-write.R` | `geo_metadata()`, `geo_type_names()` | B | `R/geo-encode.R` | GeoParquet `geo` footer; extend to 1.1 with PROJJSON and `covering`. |
| `parquet-write.R` | `check_key_unique()`, `sort_rows()` | C | `R/files.R` | Key check and sorting before writing. |
| `catalog-rebuild.R` | `catalog_scan_local()` | C (used by G) | `R/catalog.R` | Rebuild catalog rows from file footers. |
| `md5.R` | `md5_file()`, `md5_hex_to_base64()`, `format_bytes()` | 0 | `R/utils.R` | MD5 in hex and base64; sizes in messages. |
| `sync-plan.R` | `sync_compare()` | G (states also D) | `R/sync.R` | Compare two sides by MD5, size as fallback. |
| `sync-plan.R` | `sync_plan()`, `sync_report()`, `sync_verify()` | G | `R/sync.R` | Plan, dry-run report, catalogs last, verify after the run. |
| `h3-reference.R` | `ref_cells_intersecting()`, `ref_cells_per_row()`, `ref_cell_largest()` | B, F | `tests/testthat/helper-geo-reference.R` | Brute-force references for `h3`, index rows and covering cells. Tests only. |
| `gcloud-cli.R` | `gcloud_run()`, `gcloud_path()`, `gcloud_list()` | A | `R/backend-gcs.R` | Only if transfers fall back to the `gcloud` CLI; otherwise drop. |
| `h3-int64.R` | `h3_hex_to_int64()`, `h3_int64_to_hex()` | B | `R/geo-h3.R` | New in the review, not recycled. Cell conversion; notes on two h3o traps. |

## Deliberately not carried over

| What | Why |
|---|---|
| A dictionary of column descriptions | Specific to the earlier data. Descriptions come from the `columns` argument. |
| Recording a git commit and a script path in the metadata | The catalog schema has no such fields, and the code depended on a project-root helper. |
| A fixed local store folder and a bucket name read from one environment variable | Replaced by `store_connect()` and `<env>_PRIMARY` / `<env>_SECONDARY`. |
| An uploader tied to one cloud client | Replaced by the backend generics (`be_put()`, `be_md5()`). |
| Check that coordinates lie on a rounding grid | Not part of the storage design. |
| Geocodes from a point on the surface, and list columns of all cells touched | Replaced by the largest-overlap cell and the index table. Arrow cannot filter list columns. |
| Polygon cleaning (repair, cast to multipolygon) | Changes the user's data; a store must write what it is given. |
| Coverage checks (gaps, overlaps, nesting) and coordinate rounding | Unrelated to storage. |

## Findings carried over

- Arrow reads `gs://` with application-default credentials.
- `arrow::open_dataset()` needs the full `gs://` URL for a single file; a `filesystem$path()` is treated as a folder.
- Arrow's dplyr cannot filter list columns ("Expression not supported in Arrow"; confirmed again in the review).
- DuckDB reads `gs://` only with HMAC keys.
