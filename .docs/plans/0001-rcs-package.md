# rcs: an R package for catalog-first cloud and local storage

- **Date:** 2026-11-20
- **Author:** Eduard Bukin
- **Status:** active; wave 0 done and contracts reviewed on 2026-11-20; waves 1 to 6 running (see `.docs/handoffs/0002-waves-1-to-6.md`)

## Goal

An installable R package, `rcs` (R Cloud Storage), that enables seamless cloud-based and local storage of data from R, mainly in Parquet, with native support for tabular, geospatial vector and raster data. A user connects to one store, kept in one primary location and any number of secondary ones (local folders and Google Cloud Storage in this version). They inspect what it holds, stream pieces, samples or whole datasets, and write datasets that land in every location with verified checksums. Every operation starts from the store's catalog. The package is developed and tested only on simulated, neutral data, and passes `R CMD check` with no errors, warnings or notes.

## Context

- This plan is the complete record of the design; nothing else is needed to implement it. Starting code is in `recycled/` (see its `README.md`); delete that folder once absorbed.
- The project folder was initialised with the workspace conventions in `CLAUDE.md` (`.docs/`, `output/`, `.claude/`); these, `recycled/` and every `.gitkeep` go into `.Rbuildignore` in wave 0. Wave 0 also runs `git init` if the folder is not a repository yet, because parallel agents need worktrees, and adds the remote `https://github.com/EBukin/rcs`.
- Conventions:
  - Package layout: `R/` holds the functions, one topic per file, roxygen-documented; tests in `tests/testthat/` (testthat 3rd edition); long-form docs in `vignettes/`; benchmarks in `bench/` (in `.Rbuildignore`).
  - User-facing messages use cli (`cli_abort()`, `cli_warn()`, `cli_inform()`, progress bars with `cli_progress_*()`), never bare `stop()`, `warning()`, `message()`.
  - Tidyverse style; follow the `r-lib:*` skills (`r-package-development`, `r-testthat`, `r-cli`, `r-lifecycle`).
  - All R work goes through the `run-r` skill (Positron MCP); every agent starts and closes its own R session; at most 3 R sessions at once.
  - Parallel agents are isolated: each works in its own git worktree and branch. A new R session starts in the project folder, not in the worktree, so every agent passes its worktree path explicitly (`devtools::load_all("<worktree>")`, `devtools::test("<worktree>")`) and never calls `setwd()`, `devtools::document()` or `devtools::install()`. `NAMESPACE`, `man/` and `DESCRIPTION` are never committed by a parallel agent; the orchestrator merges the branches at the end of a wave, runs `devtools::document()` once, and applies the `DESCRIPTION` changes the agents asked for in their reports. Without this, three agents running `devtools::document()` and `devtools::load_all()` in one folder overwrite each other's `NAMESPACE` and load each other's half-written files.
- Neutrality rule: code, tests, examples, documentation, data and commit messages contain no reference to any real country, region, organisation or person, and nothing personal. Simulated data are placed in open ocean (see "Simulated data"). Time zones follow the practice of the pins package: every timestamp the package writes (catalogs, manifests) is stored in UTC and shown in the session's local zone; test data use `UTC` and the session's local zone (`tz = ""`), never a named place. The only exception is the package author's name and address in `DESCRIPTION` (`Authors@R`: Eduard Bukin, edwardbukin@gmail.com, roles `aut`, `cre`, `cph`) and the name in `LICENSE`. Licence: MIT (`usethis::use_mit_license()`).

## Vocabulary

| Term | Meaning |
|---|---|
| store | A named collection of datasets, independent of where they are kept. |
| location | One place holding a full or partial copy of a store: a local folder or `gs://bucket[/prefix]`. Each location holds its own catalog. Any other prefix aborts with "not supported yet". |
| backend | The technology behind a location, inferred from the address prefix: `local` or `gcs`. |
| primary | The location that is the source of truth. Exactly one per connection. Writes go there first. |
| secondary | Any other location of the connection. May hold all or some datasets. |
| connection | The R object returned by `store_connect()`, class `rcs_store`. Nothing about it is saved anywhere; each user's script or `.Renviron` decides which locations it has. |
| catalog | Three Parquet files at the root of each location: `_catalog.parquet` (one row per dataset), `_files.parquet` (one row per data file of the current versions), `_history.parquet` (file lists of earlier versions). |
| manifest | One small JSON file per dataset version, `<dataset>/_manifest-<version>.json`: the catalog entry and the file rows of that version. Immutable. The catalog files can be rebuilt from manifests. |
| dataset | One logical table, named by its path without extension, e.g. `sales/daily` or `polygons`. Stored as one file or as up to `max_files` partition files. |
| entry | A dataset's row in `_catalog.parquet`. |
| version | Identifier of a dataset's content: the first 16 hex characters of the MD5 of the sorted lines `<partition_values>|<file md5>` of its files. Two copies are the same when their versions match. |
| kind | `table`, `geospatial` or `raster`, set automatically from the class of the data written. |
| history | Earlier versions of a dataset, kept as immutable files listed in `_history.parquet`; can be switched off for a store, a connection or one dataset, and pruned. |

## Design

### Principles

1. Catalog first. Every function acts only on datasets and files the catalog names. Directory listing is used only by `store_prune()`, `store_rebuild()` and tests.
2. The primary's catalog is the truth. A secondary copy is current when its version equals the primary's. Versions are compared from catalogs; files are not re-hashed on every call.
3. Reads stream through Arrow file systems (local, GCS); filters and column selection are pushed down so that only needed files and row groups are fetched.
4. Data files are immutable. Every write creates new files with names that contain the dataset version; the catalog is switched to them last. Readers holding an older catalog keep working; old files are history until pruned.
5. Files describe themselves. Each Parquet data file carries the dataset's metadata in its key-value metadata, and each version has a manifest, so catalogs can be rebuilt.
6. Writes land in every location and are verified by MD5.
7. Writing is deterministic. The embedded metadata holds no timestamp, no version and no totals, so the same data written twice gives the same file MD5s and the same version; such a write is reported as "unchanged" and uploads nothing.
8. Native verbs where they exist: lazy queries use dplyr verbs and `dplyr::collect()`.

### Connecting

```r
st <- store_connect(primary = "~/data/my-store")
st <- store_connect(primary = "gs://my-bucket/store", secondary = "~/data/my-store")
st <- store_connect(primary = "gs://my-bucket/store",
                    secondary = c("~/data/my-store", "gs://other-bucket/store"))
st <- store_connect()                 # STORE_PRIMARY, STORE_SECONDARY from the environment
st <- store_connect(env = "OTHER")    # OTHER_PRIMARY, OTHER_SECONDARY
store_create("~/data/new-store")      # initialise an empty location (empty catalogs)
```

- `store_connect(primary = NULL, secondary = NULL, env = "STORE", history = NULL, create = FALSE)`. When `primary` is `NULL`, it is read from `<env>_PRIMARY`; `secondary` from `<env>_SECONDARY`, several separated by `;`. A missing primary aborts with a message naming the variables.
- Reads `_catalog.parquet`, then `_files.parquet`, of every location, in that order. A location without catalogs aborts unless `create = TRUE`, which initialises it (also available as `store_create(location, history = FALSE)`). An unreachable secondary gives a warning and is marked unavailable; an unreachable primary aborts with the backend's authentication hint.
- Returns `rcs_store`. The object has reference semantics: it wraps an environment holding `primary` and `secondary` (each an `rcs_location`: `uri`, `backend`, `catalog`, `files`, `token` = MD5 of `_catalog.parquet` as read, `available`), `history`, `connected_at`. Functions that change a location update the object in place, so the same `st` can be used for several writes in a row.
- History setting, three levels. Store: `store_create(history = )` saves the store's default in `_store.json` at the location root (`{"history": false}`); history is off unless switched on; the primary's file counts. Connection: `store_connect(history = TRUE/FALSE)` overrides the store default for this connection; `NULL` uses it. Dataset: `store_write(history = TRUE/FALSE)` is recorded in the dataset's entry and overrides both, so one dataset can keep history in a store or connection that keeps none, and the reverse; `NULL` leaves the entry's setting as it is. The effective setting of a write is the dataset's if set, else the connection's if given, else the store's.
- With history off (the default), a write deletes the replaced files right after the catalog switch: a reader that connected earlier gets a clear error telling it to refresh, `store_read(version = )` knows only the current version, and an `update` that drops rows cannot be undone. Nothing prunes automatically when history is on; old versions stay until `store_prune()`.
- `store_refresh(st)` re-reads all catalogs, updates the object and returns it invisibly.
- Freshness: read functions use the catalogs held by the connection. Write functions (`store_write()`, `store_sync()`, `store_copy()`, `store_delete()`, `store_prune()`, `store_rebuild()`) re-read the catalogs of the locations they touch before doing anything else.
- File lookup, used by every read: the files of dataset `d` at version `v` are the rows of `_files.parquet` with that dataset and version; if there are none, the rows of `_history.parquet` (read on demand); if there are none either, the location's catalogs are re-read once; then abort. This makes a read correct while another process is between its catalog writes.

### Catalog schema

`_catalog.parquet`, one row per dataset:

| Column | Type | Content |
|---|---|---|
| `dataset` | string | name, e.g. `sales/daily` |
| `kind` | string | `table`, `geospatial`, `raster` |
| `title`, `description` | string | required at write |
| `source`, `inputs` | string | optional provenance |
| `key` | list<string> | key columns, empty when none |
| `sorted_by` | list<string> | sort order |
| `partition` | list<string> | partition columns, empty when one file |
| `columns` | string | JSON array of `{name, type, r_type, description}`; `r_type` holds what Arrow does not restore by itself (see "Types") |
| `version` | string | 16 hex chars |
| `n_files`, `rows`, `bytes` | int64 | totals |
| `crs` | string | PROJJSON; geospatial and raster only |
| `bbox` | struct<xmin, ymin, xmax, ymax> | overall extent, in the data CRS |
| `h3_res` | int32 | geocode resolution; geospatial only, NA when written with `geocode = FALSE` |
| `index_of` | string | for an index table, the dataset it indexes |
| `history` | bool | dataset-level history setting; NA when not set |
| `writer`, `r_version`, `rcs_version` | string | provenance of the write; `writer` is `Sys.info()[["user"]]` only if `getOption("rcs.record_writer", FALSE)`, otherwise NA |
| `created`, `updated` | timestamp (UTC) | first write, last write |

`_files.parquet`, one row per data file of each dataset's current version:

| Column | Type | Content |
|---|---|---|
| `dataset`, `version` | string | `version` is the dataset version the row belongs to (not the version in the file name, which is the version at which the file was created) |
| `path` | string | relative to the location root, forward slashes |
| `partition_values` | string | JSON object, e.g. `{"year": 2024}`; `{}` for one-file datasets |
| `rows`, `bytes` | int64 | |
| `md5` | string | hex |
| `bbox` | struct | file extent; geospatial only |
| `h3_min`, `h3_max` | int64 | range of `h3` cells in the file; geospatial only |
| `created` | timestamp | |

`_history.parquet` has the same columns plus `replaced` (timestamp). It holds, for every superseded version that has not been pruned, the complete file list of that version, including files that are still part of the current version. A file is deleted only when no row of `_files.parquet` or `_history.parquet` names it.

Manifest `<dataset>/_manifest-<version>.json`: `{entry: <the catalog row>, files: [<the file rows>], written: <UTC timestamp>}`. Written with the data files, before any catalog file.

File names: `<dataset>/part-<version>.parquet` for one-file datasets; `<dataset>/<col>=<value>[/<col>=<value>]/part-<version>.parquet` for partitioned ones (values URL-encoded). Rasters: `<dataset>/part-<version>.tif`. `<version>` is the dataset version at which the file was created; the name is given after the version is computed, so the name is not part of what is hashed. Partition columns also stay inside the files with their full types; datasets are opened from the explicit file list and the paths are never parsed for values.

Reserved names: a dataset name may not end in `__h3` (index tables) and no path segment may start with `_`.

Order of catalog writes in a location: `_history.parquet`, `_files.parquet`, `_catalog.parquet`. Order of reads: `_catalog.parquet`, `_files.parquet`.

### Writing

```r
store_write(st, x, "sales/daily",
  title = "Daily sales", description = "Simulated daily sales by shop and product.",
  key = c("shop_id", "date", "product"), partition = "year")
```

`store_write(st, x, dataset, title, description, key = NULL, partition = NULL, mode = c("create", "replace", "update"), h3_res = 5L, geocode = TRUE, max_files = 50L, history = NULL, source = NULL, inputs = NULL, columns = NULL, check = TRUE, rows_per_group = 50000L)`

- `columns`: named character vector, column name to description.
- `geocode = FALSE` (geospatial only): no `h3`, no index table, `h3_res` NA; `partition = "h3"` aborts; the spatial filter then uses bounding boxes only.

Steps, in order:

1. Refresh the catalogs of all locations (a write always goes to the primary and every available secondary; there is no argument to choose locations). Validate: dataset name matches `^[a-z0-9_]+(/[a-z0-9_]+)*$` and is not reserved; `title` and `description` non-empty; if the name exists in the primary catalog and `mode = "create"`, abort showing the existing entry (title, rows, updated) and the two other modes. Two datasets may share their last segment (e.g. `polygons` and `shapes/polygons`); the short name then refers to neither, and reads need the full names.
2. Kind: `sf` → `geospatial`; `terra::SpatRaster` → `raster` (see "Rasters"); data frame → `table`. Other classes abort. Zero rows are allowed only with `partition = NULL`.
3. Key: optional. When given, its columns must exist and be unique together; duplicates abort with the first five offending key values. Partition columns may not contain NA; the one exception is `partition = "h3"`, where rows without a cell (empty geometries, `h3` NA) form one partition of their own, with the value `null` in `partition_values` and in the path.
4. Geospatial preparation (see "Geospatial encoding"): `.rcs_id`, geocodes, `bbox` struct, index table rows.
5. Partitioning: `partition = NULL` writes one file; `partition = c("col", ...)` splits by those columns; `partition = "h3"` (geospatial only) splits by the H3 parent of `h3` at the finest resolution `r <= h3_res` whose number of non-empty groups is at most `max_files`, written as the column `h3_p<r>`. More than `max_files` groups abort: for column partitioning, suggesting a coarser column; for `h3`, when even resolution 0 has too many groups, suggesting a larger `max_files`.
6. Sort rows: geospatial by `h3`, then key (or `.rcs_id`); tables by key; nothing otherwise.
7. Write files to a local staging folder (`getOption("rcs.staging_dir", tempdir())`), partition by partition so that only one partition is serialised at a time; zstd compression, `rows_per_group` rows per row group, with the key-value metadata: `rcs` (JSON of the catalog entry without `version`, totals, `bbox`, `history`, `writer`, `r_version`, `rcs_version`, `created`, `updated`), and for geospatial data `geo` (GeoParquet 1.1, below). Compute MD5, rows, bytes, extent per file; compute the version; name the files; write the manifest. If the version equals the current version in the primary, report "unchanged", bring secondaries that differ up to date (step 9) and stop.
8. Serialization check (`check = TRUE`, see `store_check()`): compare sampled rows of the staged files with `x`. Abort on difference, before anything leaves the machine.
9. For each location, primary first, then secondaries in the given order, with a cli progress line per location:
   - upload the files of the new version that the location lacks (compared by path and MD5 with that location's `_files.parquet` and `_history.parquet`), each with up to 3 attempts and increasing waits; local targets are written under a temporary name and renamed;
   - verify MD5 of every uploaded file (see "Backends");
   - upload the manifest;
   - under the write guard, write `_history.parquet`, `_files.parquet` and `_catalog.parquet`, in that order.
   If the primary fails at any point before its `_catalog.parquet` is written, stop; no catalog of any location has changed, and uploaded files are orphans (removed by `store_prune()`, reused by a retry). If a secondary fails, warn, continue with the next, and report it as behind in the summary; `store_sync()` repairs it.
10. History: the file list of the replaced version moves to `_history.parquet` (nothing is copied; files are immutable). When the effective history setting (see "Connecting") is off, files no longer named by any row are deleted after the catalog switch, and the replaced version's manifest with them.
11. Update the connection object, then print the summary:

```
ℹ Writing "polygons": 5,012,334 rows in 12 files (partition h3_p2)
✔ primary   gs://my-bucket/store   12/12 files  2.1 GB  3m 10s
✔ secondary ~/data/my-store        12/12 files          25s
✔ MD5 identical for 12 files in 2 locations. Catalogs updated.
```

Modes:

- `create` (default): the dataset must not exist.
- `replace`: the whole dataset is replaced by `x`. Columns, partitioning, key and kind may change. A geospatial dataset's index table is replaced or removed in the same call.
- `update`: only for partitioned datasets (otherwise abort and suggest `replace`).
  - The partitions whose values occur in `x` are replaced entirely by the rows of `x` for those values; partitions absent from `x` are kept; new values add partitions.
  - Columns and types must equal the existing schema (abort listing differences).
  - With a key, the key must stay unique across the whole dataset: the key columns of the kept partitions are read and compared with `x`; duplicates abort with the first five values and the partitions they sit in.
  - Before writing, a message lists every replaced partition with old and new row counts, because rows of a replaced partition that are missing from `x` disappear. The message is the only protection; there is no abort and no `force` argument.
  - If the update makes `partition = "h3"` exceed `max_files`, the whole dataset is re-partitioned at the next coarser parent resolution (existing partitions are read and rewritten; the partition column changes name) and a message says so.
  - For geospatial data, new rows get `.rcs_id` values above the dataset's current maximum, and the index table is updated for the replaced partitions.
  - A secondary receives the files of the new version it lacks, whatever version it held before (step 9), so a secondary that missed an earlier write becomes complete.

Write guard: step 1 takes a token per location, the MD5 of its `_catalog.parquet`. Just before a location's catalog files are written, the MD5 is read again; a difference aborts ("another writer changed this location; nothing was changed; run the call again"). Local locations additionally hold a lock folder `_lock` (created with `dir.create()`, holding a timestamp, removed on exit; a lock older than `getOption("rcs.lock_timeout", 600)` seconds is taken over with a warning). On cloud backends the guard leaves a short race window: two writers in the same moment can still lose one catalog update. This is accepted for the first version; conditional writes are a later improvement.

### Geospatial encoding

Columns added to an `sf` object (all before `geometry`):

| Column | Type | Content |
|---|---|---|
| `.rcs_id` | int64 | row identifier, unique within the dataset, assigned in written order; dropped on read unless asked for |
| `h3` | int64 | the cell at resolution `h3_res` holding the largest part of the geometry |
| `bbox` | struct<xmin, ymin, xmax, ymax> double | bounding box in the data CRS |
| `geometry` | binary | WKB |

- `h3_res` defaults to 5 and is recorded in the catalog. Cells are stored as int64 only; `store_h3_hex()` converts to the hex string form on read when wanted.
- Cells given by the user (anywhere in the package) are hex strings, `bit64::integer64` or `h3o` `H3` vectors. A plain numeric aborts: an H3 index does not fit a double and would be rounded to another cell.
- The data may be in any CRS; geocodes are computed on a copy transformed to EPSG:4326, and its bounding boxes are those of the transformed geometries (not transformed corners). The CRS is written as PROJJSON in the catalog and in the `geo` metadata.
- Geometries that cross the antimeridian or contain a pole are supported. They are detected on the EPSG:4326 copy (a bounding box wider than 180° of longitude, or a pole inside the shape under spherical geometry), are always crossing rows, and their cells are found on the spherical shape (`sf::sf_use_s2(TRUE)` locally; split at ±180° where the H3 function needs planar parts). Their `bbox` is the plain box of their coordinates, which may span all longitudes: bounding-box pruning is weak for these rows and the index table carries them. Query shapes of this kind are handled the same way, and for them the bounding-box test of the spatial filter is skipped.
- The H3 hierarchy is not geometrically nested: a cell is not contained in its parent. Measured in the review: for 7.1% of random points, the parent (resolution 5) of the point's resolution-6 cell is not the point's resolution-5 cell. Therefore the cell of a point at a resolution is always computed from the point, never as the parent of a finer cell, wherever a geometric claim is made. Parents are used only for grouping (`h3_p<r>` partitions).
- Inside and crossing rows: take the four corners of each bounding box (EPSG:4326) and their cells at `h3_res`. A row whose four corners fall in one cell is treated as lying inside that cell ("inside row"; see "Open questions" on edge curvature); every other row is a "crossing row". Vectorised, in chunks of `getOption("rcs.chunk_size", 1e5)` rows. No cell of another resolution is stored: an inside row is described by its `h3`, a crossing row by the index table.
- Cells a geometry touches at `h3_res` (used for `h3` and for the index table): the H3 polygon-to-cells function in the containment mode that returns every cell intersecting the shape (in `h3o`: `sfc_to_cells(x, resolution, containment = "intersect")`), applied to the geometry itself; for lines and points, the cells of the vertices plus the cells along each segment. If the chosen H3 package lacks that mode: cells whose centre is inside the geometry, plus the first ring around the cells of boundary points taken every half cell edge length. Cells of vertices and bounding-box corners alone are not enough (a large polygon with four vertices touches hundreds of cells).
- Computing `h3`: for inside rows, that cell. For crossing rows, intersect the geometry with the cells it touches and take the cell with the largest intersection (area for polygons, length for lines; for points and ties, the smallest cell id). Parallel over chunks with `mirai` when `getOption("rcs.workers", 1) > 1`.
- Index table `<dataset>__h3` (stored next to the dataset, e.g. `shapes/polygons__h3`), kind `table`, `index_of = dataset`, written in the same call: only crossing rows; columns `.rcs_id`, `h3` (each cell touched), `h3_main` (the row's `h3`), `share` (fraction of area or length in that cell); sorted by `h3`, then `.rcs_id`. One file unless it exceeds `rows_per_group * 100` rows, then partitioned by the H3 parent of `h3` like a dataset with `partition = "h3"`. Index tables are hidden from `store_datasets()` and `print()` unless `index = TRUE`, cannot be written directly, and are replaced and deleted with their dataset.
- GeoParquet 1.1 `geo` metadata: `version "1.1.0"`, `primary_column "geometry"`, `columns.geometry = {encoding "WKB", geometry_types [...], crs <PROJJSON>, bbox [...], covering {bbox {xmin ["bbox","xmin"], ymin ["bbox","ymin"], xmax ["bbox","xmax"], ymax ["bbox","ymax"]}}}`.
- H3 implementation: decided in work package B by a benchmark between `h3o` and `h3jsr`. Known facts (see "Verified facts"): `h3o` has every function needed but exchanges cells as hex strings, so int64 conversion is the package's own code; `h3o::h3_from_xy()` takes latitude first.

### Reading

```r
store_glimpse(st, "sales/daily")
store_read(st, "sales/daily", year >= 2023, product == "p07", columns = c(shop_id, date, qty))
store_read(st, "shapes/polygons", intersects = query_polygon)
store_read(st, "shapes/polygons", intersects = "8556f183fffffff")   # any H3 cell: hex string, integer64 or H3 vector
store_read(st, "shapes/polygons", geometry = FALSE)
store_read(st, "shapes/polygons", version = "b81d0c4e2a7f9913")

store_open(st, "shapes/polygons") |>
  dplyr::filter(area > 10) |>
  dplyr::select(id, area) |>
  dplyr::collect()

store_sample(st, "shapes/polygons", n = 500, cat == "a", seed = 42)
```

- `store_read(st, dataset, ..., columns = NULL, intersects = NULL, geometry = TRUE, version = NULL, exact = TRUE)`: `...` are dplyr filter expressions; `columns` uses tidyselect; `geometry = FALSE` drops the WKB column before collecting; returns `sf` for geospatial data with geometry, a tibble otherwise. Of the columns the package added, a read drops `.rcs_id` and returns `h3`, `bbox` and `h3_p<r>`.
- `store_open(st, dataset, version = NULL)` returns a lazy query of class `rcs_query`, wrapping an Arrow dataset built from the file list (never from listing). Methods for dplyr generics: `filter`, `select`, `mutate`, `rename`, `arrange`, `distinct`, `head`, `glimpse`, `collect`, `compute`, `pull`, plus `print`. `collect()` turns WKB into `sf` with the catalog CRS and restores R types (see "Types"). `store_intersects(q, y, exact = TRUE)` adds a spatial filter to a lazy query.
- `store_sample(st, dataset, n = 1000, ..., columns = NULL, seed = NULL, geometry = TRUE, version = NULL)`: picks row groups at random across files, with probability proportional to their rows (rows are sorted spatially, so the first rows would cover one area only), reads only those, applies the filters, then samples `n` rows; when the filters leave fewer than `n`, further row groups are read until `n` rows are found or the dataset is exhausted. It is a cluster sample, and the documentation says so. Reproducible with `seed`, which does not change the global random stream (`withr::with_seed()`).
- `store_glimpse(st, dataset)`: catalog facts (kind, rows, files, version, key, partition, CRS) and `dplyr::glimpse()` of the first row group.
- `version = <old version>`: the file list comes from `_history.parquet`, and the entry (columns, key, CRS, kind) from that version's manifest. A location is eligible only if it still holds every file of the version.
- Dataset names: full name, or the last segment when it is unique among datasets that are not index tables; an ambiguous or unknown name aborts listing the closest names (`agrep()`).
- Location choice: for each read, among available locations whose catalog version of the dataset equals the primary's: local backends first, then the primary, then other secondaries. Reading from a secondary prints `ℹ Reading "polygons" from secondary ~/data/my-store.`; reading from the primary prints nothing. `options(rcs.quiet = TRUE)` silences it.
- Partition pruning: filter expressions whose symbols are all partition columns are evaluated on `_files.parquet` `partition_values` first, so only matching files are opened.

Spatial filter (`intersects`), for geospatial datasets:

1. Query shape. `sf`/`sfc`/`bbox` objects, or H3 cells of any resolution, which are converted to their cell polygons. Before any change of CRS the shape is densified (`sf::st_segmentize()`), because straight edges become curves; the query's bounding box in the data CRS is the box of the densified, transformed shape.
2. Covering cells at `h3_res`: every cell that intersects the query shape, by the same "cells a geometry touches" function as in "Geospatial encoding", plus their first ring. The ring absorbs the small differences between planar and geodesic edges. For a query cell finer than `h3_res`, a message says the stored resolution is coarser.
3. File pruning: keep files whose `bbox` intersects the query's bounding box and whose `h3_min`–`h3_max` range overlaps the range of the covering cells.
4. Candidate rows, pushed down to Arrow: (`h3` in the covering cells, or `.rcs_id` in the index-table rows whose `h3` is in the covering cells, restricted to the files and `h3` values given by their `h3_main`) and `bbox` overlapping the query's bounding box (`bbox$xmin <= qxmax & bbox$xmax >= qxmin & ...`). For datasets written with `geocode = FALSE`, the `bbox` test alone.
5. Exact test (`exact = TRUE` and geometry read): `sf::st_intersects()` with the query shape in the data CRS, under the user's `sf::sf_use_s2()` setting. With `exact = FALSE` or `geometry = FALSE` the result is the candidate set, and a message says so.

Completeness argument, to be kept true by any change: an inside row lies in its `h3` cell, so it can only intersect the query if that cell does, and the cell is then in the covering. A crossing row has an index row for every cell it touches, so it is found if any of them is in the covering.

Which combination of these steps is fastest is measured in work package M; the defaults may change after it, the completeness argument may not.

### Types

Types that must survive a round trip, and are tested: logical, integer, double, character (UTF-8, including non-ASCII), factor (levels and order, including unused levels) and ordered factor, Date, POSIXct with time zone, difftime, `bit64::integer64`, list columns of atomic vectors, NA in every type, a zero-row data frame, `sf` geometries (POINT, LINESTRING, POLYGON, MULTIPOLYGON, mixed, empty geometry).

Arrow does not restore all of these by itself (see "Verified facts"). The `columns` JSON therefore records `r_type` for: difftime (with units), `integer64`, factor (with levels, for zero-row files), plain list. Reads run with `options(arrow.int64_downcast = FALSE)` set locally (`withr::local_options()`), and `collect()` restores the recorded types.

### Inspecting and maintaining

| Function | Does |
|---|---|
| `print(st)` | Locations with backend and availability; datasets grouped by folder: name, kind, rows, size, files, updated, and per secondary `=`, `≠` or `–` (same, differs, missing). |
| `store_datasets(st, pattern = NULL, kind = NULL, index = FALSE)` | The primary catalog as a tibble with one `in_<n>` column per secondary (numbered in connection order; the addresses are an attribute). |
| `store_describe(st, dataset)` | Full entry: title, description, provenance, key, partition, CRS, extent, `h3_res`, columns table, files table. No data file opened. Print method. |
| `store_status(st)` | Per dataset and location, from catalogs only: `same`, `missing`, `differs`. For `differs`, a column `newer` says which side has the later `updated` (a hint only: clocks differ between machines). Datasets found only in a secondary are listed as `extra`. |
| `store_sync(st, datasets = NULL, to = NULL, dry_run = FALSE)` | Copies datasets from the primary to secondaries (default: all secondaries, all datasets that are missing or differ), file by file (only files the target lacks), MD5-verified, catalog last. Index tables travel with their dataset. Never deletes. |
| `store_copy(st, dataset, from, to)` | Copies one dataset between any two locations of the connection. |
| `store_delete(st, dataset, confirm, history = FALSE)` | Aborts unless `confirm` equals the full dataset name. Removes the entry (and its index table) from every location's catalog first, then the files of the current version, and with `history = TRUE` also history files and manifests. |
| `store_check(st, dataset, x = NULL, n = 20, columns = NULL, locations = "all", error = TRUE)` | With `x`: serialization check. For each file, reads `n` random rows (one random row group per file) and compares them, column by column, with the matching rows of `x` (matched by key, or by `.rcs_id`, or by row order for keyless tables), as `identical()` after normalisation (tibble vs data frame, WKB for geometry). Without `x`: integrity check: catalog MD5 vs backend MD5 for every file in each location, rows and schema from the Parquet footers. Returns a tibble of results invisibly; aborts on failure unless `error = FALSE`. Called by `store_write(check = TRUE)` on the staged files. |
| `store_history(st, dataset)` | Versions with date, rows, bytes, and whether all files are still present. |
| `store_prune(st, dataset = NULL, keep = 1, before = NULL, dry_run = FALSE)` | Removes history versions beyond the last `keep` or older than `before`, deletes files and manifests no remaining row names, and orphan files not named by any catalog (found by listing). Orphans younger than one hour are kept: they may belong to a write in progress. |
| `store_rebuild(st, location)` | Rebuilds a location's catalogs from its manifests: for each dataset, the manifest with the latest `written` whose files all exist is current, earlier ones are history. A dataset without a manifest is rebuilt from the `rcs` metadata of its Parquet files when all its files carry one file version; otherwise it is reported and skipped. |

### Backends

Internal interface, one S3 class per backend, `R/backend.R` defines the generics:

| Generic | Does |
|---|---|
| `be_new(uri)` | Parses the address, returns the backend object. |
| `be_arrow_fs(be)` | An Arrow FileSystem and base path for streaming. |
| `be_gdal_path(be, path)` | A path GDAL can open (`/vsigs/...`, local path). |
| `be_get(be, path, dest)` | Downloads one file to a local path. |
| `be_put(be, src, path)` | Uploads one local file. |
| `be_delete(be, paths)` | Deletes files. |
| `be_md5(be, paths)` | MD5 of stored files, from backend metadata when available, else by download and hashing. |
| `be_list(be, prefix)` | Lists files; used only by `store_prune()`, `store_rebuild()` and tests. |
| `be_exists(be, path)` | |
| `be_auth_hint(be)` | Text shown when access fails: which credentials each client of this backend needs. |

| Backend | Streaming reads | Transfers | MD5 source | Package (Suggests unless noted) |
|---|---|---|---|---|
| `local` | Arrow `LocalFileSystem` | file copy to a temporary name, then rename | `digest` (Imports) | – |
| `gcs` | Arrow `GcsFileSystem` (application-default credentials) | decided in work package A | object `md5Hash` | `googleCloudStorageR` or the JSON API through `gargle`/`httr2` |

- Requirement on every `be_put()`: after it returns, `be_md5()` gives the file's MD5 without downloading it. Work package A checks this on the test bucket for the transfer method it chooses and records the result.
- Credentials. GCS is reached by up to three clients (Arrow for streaming, GDAL for rasters, an API client for transfers and metadata), each with its own credential lookup. Each backend file documents, and `be_auth_hint()` prints, what each client needs. On connection, `be_new()` checks the clients the session will need and reports the first that fails. Known case: GDAL's `/vsigs/` did not find the application-default credentials that Arrow uses on the same machine.
- Network failures: every transfer is retried up to 3 times with increasing waits; a file already at the target with the right MD5 is not sent again, so a failed call can simply be repeated.

### Rasters

- `store_write()` with a `terra::SpatRaster` writes a Cloud Optimized GeoTIFF (`terra::writeRaster(filetype = "COG")`) to the staging folder, one file per dataset (no partitioning, `mode` `create` or `replace` only), with the catalog entry (`kind = "raster"`, CRS, extent, resolution, layer names and types in `columns`). The manifest describes the file; no metadata is embedded in the TIFF.
- `store_read()` on a raster returns a `SpatRaster` opened through `be_gdal_path()`, so only the tiles needed are read. `intersects` crops to the query's bounding box.
- Filters in `...`, `columns`, `geometry` and `exact` do not apply to rasters and abort when given. `store_open()` and `store_sample()` abort for rasters.

### Simulated data

All tests, examples and vignettes use generated data only, created by functions in `R/sim.R` (exported as `rcs_sim_*()` for examples and vignettes):

- `rcs_sim_table(n, seed)`: a "daily sales" panel: `shop_id` (int), `date` (Date), `year` (int), `product` (factor `p01`–`p20`, one level unused), `qty` (int), `price` (double), `big` (`integer64`, small and large values), `wait` (difftime, hours), `note` (character with ASCII, accented and non-Latin characters), `tags` (list column), `ts` (POSIXct UTC) and `ts_local` (POSIXct in the session's zone, `tz = ""`), plus `promo` (logical), `grade` (ordered factor) and `delivered` (Date); NA in every column except `shop_id`, `date`, `product` and `year`, which serve as key and partition.
- `rcs_sim_polygons(n, seed, crossing_share = 0.1, special = FALSE)`: polygons in open ocean, longitude −30 to −24, latitude 6 to 9, EPSG:4326, columns `id`, `area`, `cat`: mostly small squares and hexagons (0.01–0.5 km²), a share deliberately crossing H3 resolution-5 cell edges (built from cell boundary vertices), a few large polygons spanning many cells (one of them a four-vertex rectangle covering more than 100 cells), a long thin polygon (about 300 km by 100 m), multipolygons, one polygon crossing the resolution-0 cell edge that runs through the box (between longitude −29.4 and −25.7), one empty geometry. With `special = TRUE`, two more rows outside the box, both in open ocean: a polygon across the antimeridian (longitude 179 to −179, latitude 6 to 9) and a polygon around the north pole (above latitude 88).
- `rcs_sim_points(n, seed)`, `rcs_sim_lines(n, seed)`: same area.
- `rcs_sim_raster(seed)`: a 3-layer `SpatRaster`, 1000 × 1000 cells, same area.
- A second CRS case: the same polygons in a projected CRS (UTM zone 26N, EPSG:32626, which covers longitude −30 to −24).

### Testing

Two rules hold throughout: every algorithm is tested against a slow, independent reference, and every operation on a store is followed by an invariant check.

- testthat 3rd edition; every exported function and every backend generic has tests. Tests that need a Suggests package skip without it.
- Test levels, chosen by the environment variable `RCS_TEST_LEVEL` and applied with `skip_below_level()` (`tests/testthat/helper-levels.R`):
  - `cran` (the default on CRAN and when unset under `R CMD check`): unit tests, no network, small data, a few seconds per file;
  - `default` (the default under `devtools::test()`): adds the local integration suite and seeded property tests of about 200 cases each;
  - `full`: adds property runs of 2,000 cases, the random-operation test and the suite against `RCS_TEST_GCS`.
- Store invariants: `expect_store_valid(st)` (`tests/testthat/helper-invariants.R`) is called after every step of every integration test and asserts, for every available location:
  - every file named by `_files.parquet` and `_history.parquet` exists, with the recorded bytes and MD5, and its Parquet footer has the recorded rows;
  - every entry's `version` equals the hash of its file rows, and `n_files`, `rows`, `bytes` equal their sums;
  - a manifest exists for every version in the catalogs and agrees with them; no path is named by two datasets;
  - with history off, no file exists that the catalogs do not name (apart from orphans left by an injected failure, which `store_prune()` must then remove);
  - every index table agrees with its dataset: every `.rcs_id` exists and every `h3_main` equals the row's `h3`;
  - every secondary is identical to the primary for a dataset or is reported as `missing` or `differs` by `store_status()`.
- Crash-point matrix: for each of `store_write()` (every mode), `store_sync()`, `store_delete()` and `store_prune()`, the operation is first run with a counting stub to learn its number of backend calls N, then run N times with the stub failing at call 1, 2, ..., N, on the primary and on a secondary. After every failure the invariants hold and readers see either the old or the new version, never a mixture; repeating the call succeeds and transfers only what is missing.
- Random-operation test: seeded sequences of 50 operations (create, replace, update, delete, sync, copy, prune, rebuild, injected failure, history switched at each level) run against a plain in-memory model (a named list of data frames per location). After every step the invariants hold and `store_read()` of every dataset from every location equals the model. A failing run prints its seed and the operation list for replay.
- Reference oracles live in test helpers and share no code with the package: brute-force `h3`, index rows and covering cells; `sf::st_filter()` for spatial reads; `identical()` after normalisation for round trips.
- Round-trip matrix: every type of "Types" × one file or partitioned × table or geospatial × local or GCS (GCS at level `full`).
- Detection tests: an altered data file, a missing data file, a truncated `_catalog.parquet`, a `_files.parquet` naming a wrong MD5 and a manifest that disagrees with the catalog are each caught by `store_check()` with a message naming the file.
- Messages: snapshot tests (`expect_snapshot()`, reproducible output) for every print method, every summary and every abort.
- No CI workflow: checks run locally and in work package L.
- Integration tests run a primary and two secondaries as three local folders (`withr::local_tempdir()`), covering: one location only; primary plus secondaries; partial secondaries; write in each mode; update with re-partitioning; history on and off; prune; rebuild; sync; delete.
- Failure and concurrency tests, with a backend stub that errors on a chosen call:
  - failure of the primary during upload, and between `_files.parquet` and `_catalog.parquet`: no catalog changed, a repeated call succeeds and uploads only what is missing;
  - failure of a secondary mid-write: warning, summary says behind, `store_sync()` repairs it;
  - a transient error on the first two attempts of one file: the write succeeds;
  - an upload that silently alters a file: MD5 verification aborts;
  - write guard: catalog changed between the start of a write and its catalog switch;
  - two writes in a row on the same connection object, without `store_refresh()`;
  - a reader that connected before a write reads the old version correctly after it (history on), and gets a clear error with history off;
  - history setting: store default, connection override and dataset override, in each combination, including a dataset that keeps history on a connection that keeps none;
  - a read while only `_history.parquet` and `_files.parquet` of a write have been switched;
  - a stale local lock is taken over; a fresh one blocks.
- Catalog tests: version is the same for the same data written twice (determinism) and differs when one value changes; `update` on a secondary that missed the previous write leaves it complete; `update` that would duplicate a key across partitions aborts; `store_read(version = )` after an `update` and after a `replace` that changed the columns; prune never deletes a file still named by a kept version; rebuild after re-partitioning returns the current version; reserved names abort; short-name resolution with and without ambiguity; index tables hidden, replaced and deleted with their dataset.
- Spatial correctness:
  - `h3` equals the brute-force largest-overlap cell for every simulated row; index rows equal brute-force `st_intersects` with the cell grid for crossing rows;
  - covering cells equal or contain the brute-force set of intersecting cells for 200 random query shapes, including thin strips, large rectangles with four vertices, shapes with holes, and single points;
  - property test: for 200 random query shapes and cells of resolutions 2–9 over the simulated polygons, `store_read(intersects = q)` returns exactly the rows of `sf::st_filter(all, q)` (with `exact = TRUE`), and a superset with `exact = FALSE`; repeated for the projected CRS, for partitioned and unpartitioned datasets, for `geocode = FALSE`, for points and lines, and with `sf::sf_use_s2()` on and off;
  - antimeridian and pole: the two special rows get the brute-force `h3` and index rows (spherical geometry), are returned by queries on either side of ±180° and at the pole, by a query that itself crosses the antimeridian, and are not returned by a query in the main box;
  - a numeric H3 cell aborts; hex, `integer64` and `H3` inputs give the same result;
  - the cell of a point is never taken from a parent: a test with a point whose resolution-6 cell's parent differs from its resolution-5 cell.
- Serialization: round trip of `rcs_sim_table()` and every geometry type is identical, for one file and for partitioned datasets; zero-row data frame; `integer64` holding only small values; `store_check()` detects a deliberately altered file.
- Interoperability (skipped when the tool is missing): DuckDB (`duckdb` + `spatial` extension) reads a written geospatial file, reports the geometry column as a geometry type with the CRS, and a filter on the `bbox` struct fields returns the rows of the same filter in R. GDAL (`sf::st_read()`) reads the file when its Parquet driver is present; common Windows builds lack it, so this test usually skips there.
- Cloud backend: the same integration suite against Google Cloud Storage when `RCS_TEST_GCS` is set; skipped otherwise and on CRAN. The test bucket is `gs://rcs-test` (dedicated, empty); each run works under a random prefix and removes it.
- Coverage at least 90% overall and 80% for every file (`covr::package_coverage()`), `R CMD check --as-cran` clean. Examples and vignettes write only below `tempdir()`.

### Performance

Speed is treated as behaviour: counted where it can be counted, measured and published where it has to be timed.

Work counters (`R/trace.R`). With `options(rcs.trace = TRUE)` the package records, per call of an exported function: backend calls by generic and location, catalog files read, data files opened, row groups in those files and row groups whose statistics overlap the pushed-down filter (computed from the Parquet footers), candidate rows (before the exact spatial test) and rows returned, bytes uploaded and downloaded. `rcs_trace()` returns the records of the last call as a tibble; `rcs_trace_reset()` clears them. Counting costs nothing when the option is off. Counters are deterministic, so they are asserted in ordinary tests:

- `print()`, `store_datasets()`, `store_describe()`, `store_status()` and `store_history()` open no data file and make no backend call after connecting;
- `store_glimpse()` opens one file;
- a filter on partition columns opens only the files of the matching partitions;
- a spatial query opens only files whose `bbox` and `h3` range match, and its overlapping row groups are a small, stated share of all row groups on the simulated data;
- candidate rows per returned row stay below a stated bound for query cells of resolutions 5 to 9;
- a read served by a local secondary makes no call to the primary;
- a repeated identical write uploads no data file; an `update` uploads only the files of the replaced partitions; `store_sync()` on an identical secondary transfers nothing;
- `store_check()` without `x` downloads no data file on a backend that reports MD5.

Benchmarks. Scripts in `bench/` run the measurements; `bench/harness.R` gives them one way to time (`bench::mark()`, at least 5 repetitions, cold and warm runs marked), to read the work counters, and to save results to `bench/results/<name>.parquet` with package versions, CPU model, cores, RAM, OS, storage type, date and commit, and no user or machine name. Results are committed. Articles in `vignettes/articles/` (built by pkgdown, excluded from the package build) read the stored results and never run a benchmark themselves; each shows the script's own code (`knitr::read_chunk()`), and has the sections Question, Setup, Results, Verdict and Limits.

| Article | Question | Compared with | Package |
|---|---|---|---|
| `benchmark-h3.Rmd` | Which H3 package, and what does geocoding cost per row? | `h3o` against `h3jsr` | B |
| `benchmark-write.Rmd` | Where does write time go: geocode, sort, serialise, check, upload, verify? | 1 against 4 workers; local against GCS | J |
| `benchmark-read.Rmd` | What does the package add on top of Arrow for full reads, column subsets, key filters and partition filters? | `arrow::read_parquet()` and `arrow::open_dataset()` on the same files | J |
| `benchmark-cloud.Rmd` | Streaming against download, cold connect, cost of MD5 verification and of sync | a local copy of the same store | J |
| `benchmark-scale.Rmd` | How do time, memory and staging disk grow from 1e5 to 5e6 polygons? | – | J |
| `benchmark-spatial.Rmd` | Which filter steps pay off (file pruning, cell filter, index table, bbox pushdown, exact test), at which `h3_res`, row-group size and sort order? | bbox struct only; DuckDB spatial on the same files; read everything, then `sf::st_filter()` | M |

Performance budget. The first full run of J and M fixes a number for each line below and writes it into this table; until then the lines are targets without numbers. `bench/quick.R` repeats a small version of every benchmark on 1e5 rows in a few minutes and fails when a time is more than 20% above, or a counter is above, the stored baseline `bench/results/baseline.parquet`.

| Measure | Budget |
|---|---|
| `store_connect()` to a local store and to GCS, catalog of 100 datasets | set by J |
| Full read and filtered read through `store_read()` relative to raw Arrow on the same files | set by J |
| Write throughput, rows per second, tables and polygons, 1 worker | set by J |
| Peak memory of a write relative to the size of `x` in memory | set by J |
| Spatial query, cell of resolution 7 on 5e6 polygons, local and GCS cold | set by M |
| Candidate rows per returned row, query cells of resolutions 5 to 9 | set by M |
| Share of row groups overlapping a resolution-7 query | set by M |

## Verified facts

Checked on 2026-11-20 with R 4.6.2 on Windows, arrow 26.0.1, h3o 0.3.0, h3jsr 1.3.1, sf 1.1.3 and terra 1.9-50 (both GDAL 3.12.1), duckdb 2.0.0. Re-check when versions change.

- Arrow exports `AzureFileSystem`, `az_container()` and `arrow_with_azure()` from 26.0.0; in the Windows binary `arrow_with_azure()` is `FALSE`.
- Arrow's dplyr accepts `bbox$xmin`-style filters on struct fields; on a file sorted by that field they ran as fast as a filter on a sorted flat column and about twice as fast as an unprunable filter of the same selectivity (local disk, timing only; work package M measures it on a remote file system).
- Arrow returns an int64 column whose values all fit 32 bits as `integer` unless `options(arrow.int64_downcast = FALSE)`; returns difftime in seconds whatever the units written; returns list columns as `arrow_list`; loses factor levels in a zero-row file; keeps factor levels (including unused ones), ordered factors and time zones otherwise; cannot filter list columns.
- `h3o` 0.3.0 has point to cell (`h3_from_points()`, `h3_from_xy()`), parents and children (`get_parents()`, `get_children()`), cell boundary (`sf::st_as_sfc()` on an `H3` vector), `grid_disk()` and `sfc_to_cells()` with `containment = "centroid"`, `"intersect"`, `"covers"`. Cells are a list of external pointers exchanged as hex strings; there is no int64 form. `h3_from_xy(x, y, resolution)` takes latitude first. About 8 s per million points, against about 25 s for `h3jsr::point_to_cell()`.
- DuckDB 2.0.0 with `spatial` reads a GeoParquet 1.1 file written by Arrow with the `geo` metadata above as `GEOMETRY('EPSG:4326')`. Explicit filters on `bbox.xmin` etc. are pushed into the Parquet scan; `ST_Intersects()` and `&&` are not.
- terra writes a COG (`LAYOUT=COG`, 512 × 512 blocks, overviews) and reads it back; two writes of the same raster give the same MD5. GDAL recognises `/vsigs/`, `/vsis3/`, `/vsiaz/` and reads through `/vsicurl/`. Neither sf's nor terra's Windows GDAL has the Parquet driver.
- No CRAN package is named `rcs`. `rms::rcs()` is a widely used function (restricted cubic splines).

## Work packages and order

Each package lists the files it owns. No two packages running at the same time own the same file, and none needs the output of a package of its own wave. Wave 0 is run by the session's own agent; from wave 1 on, an orchestrating session launches one subagent per package with `model: "opus"`. Each agent: reads this plan, works in its own git worktree and its own R session (`run-r` lifecycle), runs its tests, and reports what it built, test results, deviations, `DESCRIPTION` changes it needs, and ends with `session closed`. Shared contracts (object shapes, schemas, generics, hook signatures) are fixed in wave 0; later packages do not change them without updating this plan. After each wave the orchestrator merges, runs `devtools::document()` and the whole test suite, commits and pushes to `https://github.com/EBukin/rcs` (`URL` and `BugReports` in `DESCRIPTION` point there). The orchestrator stops after wave 0 and waits for the project owner's review of the contracts; after that the waves run through, stopping only when the test suite fails after a merge.

Wave 0, one agent:

- [x] **0. Skeleton and contracts.** Owns `DESCRIPTION`, `NAMESPACE` (roxygen), `R/rcs-package.R`, `R/schema.R` (catalog, files, history column specs as Arrow schemas, manifest shape, constructors for empty catalogs, validation), `R/objects.R` (constructors and validators for `rcs_store`, `rcs_location`, `rcs_query`), `R/backend.R` (generics, `be_new()` dispatch on prefix), `R/hooks.R` (signatures, as stubs that abort "not implemented", of the functions other packages will fill and call across packages: `geo_encode()`, `geo_decode()`, `geo_cells_touched()`, `geo_covering()`, `raster_stage()`, `raster_open()`, `files_read_row_groups()`, `resolve_dataset()`, `choose_location()`; each stub is deleted by the package that implements the function in its own file), `R/utils.R` (cli helpers, name validation, version hash, MD5 helpers), `R/trace.R` (work counters, `rcs_trace()`, `rcs_trace_reset()`, and the internal `trace_count()` every later package calls), `R/sim.R`, `bench/harness.R`, `tests/testthat/helper-sim.R`, `tests/testthat/helper-levels.R`, `tests/testthat/test-trace.R`, `tests/testthat/test-schema.R`, `tests/testthat/test-sim.R`, `.Rbuildignore`, `LICENSE`, `README.Rmd` (stub). Imports: `arrow`, `cli`, `digest`, `dplyr`, `jsonlite`, `rlang`, `tibble`, `tidyselect`, `vctrs`, `withr`, `bit64`, `sf`, `wk`; Suggests: `testthat (>= 3.0.0)`, `h3o`, `h3jsr`, `terra`, `mirai`, `duckdb`, `googleCloudStorageR`, `covr`, `bench`, `knitr`, `rmarkdown`. Geospatial functions abort with an install hint when the H3 package is missing. Acceptance: `devtools::check()` passes with stubs; simulated data generators tested, including that the box contains a resolution-0 edge and that every coordinate is inside the box.

Contracts fixed in wave 0 (documented in roxygen above each function; summary and decisions in `.docs/handoffs/0002-waves-1-to-6.md`). They add to this plan:

- Hooks beyond the list above, each a stub in `R/hooks.R`: `h3_as_int64()`, `h3_as_hex()`, `h3_parent()` and `geo_metadata()` (implemented by B), `files_row_groups()` (implemented by C).
- Backend generics beyond the table in "Backends": `be_init()` (called by `be_new()`, which is a plain function), `be_lock()` and `be_unlock()` (the local lock; no-ops by default).
- `geo_encode()` also sorts the rows into written order and assigns `.rcs_id` (step 6 of "Writing" for geospatial data).
- Internal trace API: `local_trace()` at the top of every exported function, `trace_count()` for the work; backend generics count themselves.
- `rcs_sim_table()` has three more columns (`promo`, `grade`, `delivered`) so that every type of "Types" occurs, and holds no missing value in `shop_id`, `date`, `product` and `year`, which serve as key and partition.

Results of wave 1 (2026-11-20). They add to this plan and correct it where they differ:

- A, GCS transfers: objects uploaded through Arrow's `GcsFileSystem` carry `md5Hash` (checked with a 3 MB and a 40 MB file), so uploads stay on Arrow and `be_md5()` reads `md5Hash` through the JSON API (`gargle` + `httr2`, scope `cloud-platform`) without a download. `googleCloudStorageR` is not used.
- A, deviation: the GCS clients are checked at first use, not in `be_new()`, because parsing an address must contact nothing (decision 13 of the handoff) and must work offline. `store_connect()` reads the catalog at once, so an unreachable primary still aborts there with the authentication hint. No `be_init()` method exists for either class.
- A, credentials: Arrow uses the application-default login; GDAL's `/vsigs/` works only once `GOOGLE_APPLICATION_CREDENTIALS` points to the application-default credentials file; `be_auth_hint()` says so.
- B, H3 package: `h3o` (2.6 to 15 times faster than `h3jsr`, identical cells; `vignettes/articles/benchmark-h3.Rmd`). `s2` becomes an import.
- B, cells a geometry touches: `h3o::sfc_to_cells(containment = "intersect")` is not usable for it: it returns no cell for a small polygon inside one cell and 71 of 338 cells for the pole row. The fallback of "Geospatial encoding" is used instead (cells of boundary points every third of an edge length, their first ring, cells whose centre is inside), each candidate tested with s2.
- B, antimeridian and pole rows: splitting at ±180° does not repair the pole row. Rows whose box spans 180° of longitude or more get their cells by descending the H3 hierarchy from resolution 0, each candidate tested with s2; both special rows then equal the brute-force reference.
- B, inside rows: of 197,600 inside rows (latitudes 5 to 85, widths 0.5 to 15 km, resolution 5) none had a boundary point in another cell. A cheap guard (`geo_edge_points()`) tests extra points along the edge nearest the equator when the bend of that parallel could exceed 1 cm.
- B, `geo_covering()` takes the union of the cells of the spherical shape and of the shape densified along its straight edges in degrees, then the first ring, so that the covering is complete under both `sf::sf_use_s2()` settings.
- B, facts: `h3o::h3_from_strings()` crashes on an invalid string, so cells are validated by the package's own code first; `sf::st_as_binary()` drops Z from a mixed XY/XYZ column.
- C: duplicate keys abort with class `c("rcs_error_key", "rcs_error_argument")`; the `null` partition of `partition = "h3"` counts as one group towards `max_files`; `h3_min` and `h3_max` are filled for every file with an `integer64` column `h3`, index tables included. Arrow's Parquet readers index leaf columns (a `bbox` struct takes four), and give no row count per row group from the footer.
- Every double written to JSON (manifest, `geo` metadata) is written with 17 significant digits so that it is read back unchanged.

Wave 1, three agents in parallel:

- [x] **A. Local and GCS backends.** Owns `R/backend-local.R`, `R/backend-gcs.R`, `tests/testthat/test-backend-local.R`, `tests/testthat/test-backend-gcs.R`, `tests/testthat/helper-backend-stub.R` (a backend that wraps `local` and errors or corrupts on a chosen call; used by E and G). All generics, the local lock; GCS tests gated by `RCS_TEST_GCS`, set to `gs://rcs-test`, a dedicated, empty test bucket; the agent may write and delete there, under a random prefix. Decide the GCS transfer method: check on a test bucket that objects uploaded through Arrow carry `md5Hash`; if not, upload through the JSON API and record the deviation. Document the credentials each client needs.
- [x] **B. Geospatial encoding.** Owns `R/geo-h3.R`, `R/geo-encode.R`, `tests/testthat/test-geo-*.R`, `tests/testthat/helper-geo-reference.R`, `bench/h3-backends.R`, `vignettes/articles/benchmark-h3.Rmd`. Inside and crossing rows, antimeridian and pole rows, `h3`, cells touched, covering cells, index-table rows, `bbox` struct, WKB, GeoParquet 1.1 metadata, decoding to `sf`, cell conversion between hex, int64 and `H3`. Benchmark `h3o` against `h3jsr` on 1e5 and 1e6 simulated polygons and pick one. Measure how often an inside row has a boundary point in another cell, by row size and latitude (see "Open questions"). Acceptance: the spatial correctness tests on `h3`, index rows and covering cells.
- [x] **C. Catalog I/O and file writing.** Owns `R/catalog.R`, `R/files.R`, `R/resolve.R`, `tests/testthat/test-catalog.R`, `tests/testthat/test-files.R`, `tests/testthat/test-resolve.R`, `tests/testthat/helper-store.R` (builds a fixture store in three local folders from the simulated data, without `store_write()`; used by D, E, F, G), `tests/testthat/helper-invariants.R` (`expect_store_valid()`). Read and write the three catalog files and manifests through a backend, in the fixed order; file lookup with the history fallback; build an entry and file rows from staged files; Parquet writing with key-value metadata, sorting, row groups, partition splitting (columns and `h3` auto resolution), version hash; `files_read_row_groups()`; rebuild from manifests and file metadata; `resolve_dataset()` (names) and `choose_location()`. Tested against the local file system directly, so it does not need A.

Wave 2, two agents in parallel (after wave 1):

- [ ] **D. Connect and inspect.** Owns `R/connect.R`, `R/inspect.R`, `tests/testthat/test-connect.R`, `tests/testthat/test-inspect.R`, `tests/testthat/_snaps/connect.md`, `tests/testthat/_snaps/inspect.md`. `store_connect()`, `store_create()`, `store_refresh()`, `print.rcs_store()`, `store_datasets()`, `store_describe()`, `store_status()`.
- [ ] **I. Rasters.** Owns `R/raster.R`, `tests/testthat/test-raster.R`. `raster_stage()` (COG in the staging folder, entry, file row) and `raster_open()` (through `be_gdal_path()`, cropping by `intersects`), tested on local paths without `store_write()`.

Wave 3, two agents in parallel (after wave 2):

- [ ] **E. Write pipeline.** Owns `R/write.R`, `R/check.R`, `R/history.R`, `tests/testthat/test-write.R`, `tests/testthat/test-check.R`, `tests/testthat/test-history.R`. `store_write()` (all modes and kinds, staging, upload to every location with progress and retries, MD5 verification, write guard), `store_check()`, `store_history()`, `store_prune()`.
- [ ] **F. Read pipeline.** Owns `R/read.R`, `R/query.R`, `R/intersects.R`, `tests/testthat/test-read.R`, `tests/testthat/test-query.R`, `tests/testthat/test-intersects.R`. `store_open()`, `rcs_query` dplyr methods and `collect()` with type restoring, `store_read()` (all kinds), `store_sample()`, `store_glimpse()`, `store_intersects()`, partition pruning, spatial filter, property test of spatial correctness. Uses the fixture store of `helper-store.R`, so it does not depend on E.

Wave 4, three agents in parallel (after wave 3):

- [ ] **G. Sync, copy, delete, rebuild.** Owns `R/sync.R`, `tests/testthat/test-sync.R`, `tests/testthat/test-integration.R`. `store_sync()`, `store_copy()`, `store_delete()`, `store_rebuild()`; and `tests/testthat/test-crash-points.R`, `tests/testthat/test-random-operations.R`: the full integration suite with three local locations, the failure and concurrency tests, the crash-point matrix, the random-operation test, and raster and geospatial datasets written and read through the public functions.
- [ ] **J. Benchmarks: write, read, cloud, scale.** Owns `bench/write.R`, `bench/read.R`, `bench/cloud.R`, `bench/scale.R`, `bench/quick.R`, `bench/results/`, and the articles `benchmark-write.Rmd`, `benchmark-read.Rmd`, `benchmark-cloud.Rmd`, `benchmark-scale.Rmd` in `vignettes/articles/`. Runs them on this machine and against `gs://rcs-test`, fills its lines of the performance budget, stores the baseline. Reports every case where the package is slower than its comparison, with the cause if found.
- [ ] **K. Documentation.** Owns `README.Rmd`, `vignettes/rcs.Rmd` (getting started, local store), `vignettes/locations.Rmd` (primary and secondaries, environment variables, authentication per client), `vignettes/geospatial.Rmd`, `vignettes/articles/testing.Rmd` (how the package is tested: levels, invariants, crash points, oracles, how to run each level), `_pkgdown.yml` (lists the six benchmark articles by the names in "Performance"). Only simulated data.

Wave 5, one agent (after wave 4):

- [ ] **M. Spatial benchmark and tuning.** Owns `bench/spatial.R`, `vignettes/articles/benchmark-spatial.Rmd`; may change defaults in any file, being alone in its wave. On 1e6 and 5e6 simulated polygons, partitioned and not, local and GCS: time, work counters and candidate rows for each combination of file pruning, cell filter, index table, bbox pushdown and exact test; query cells of resolutions 3 to 9 and polygons of three sizes; `h3_res` 4, 5, 6; row-group sizes 2e4, 5e4, 1e5; a secondary sort key inside `h3` (a finer cell before the key); against the three comparisons of the table. Sets the defaults that the results support, updates this plan, fills its lines of the performance budget, updates the baseline. The completeness argument of "Reading" may not be weakened; the whole test suite must pass after any change.

Wave 6:

- [ ] **L. Final verification** (one agent). Fresh session: `devtools::document()`, `devtools::check(cran = TRUE)`, the test suite at `RCS_TEST_LEVEL=full`, `bench/quick.R` against the baseline, coverage, the neutrality scan (a search of the whole repository, git history included, for a list of forbidden terms that the project owner gives to this agent at run time; the list is never stored in the repository), and the cloud integration suite where test locations exist. Reports pass or fail per item.

## Later development, not part of this plan

Amazon S3, Azure Blob Storage and Google Drive backends. Nothing is installed or written for them now; the backend generics are the extension point. Notes for that work:

- S3: uploads through Arrow's output stream are multipart by default and their `ETag` is then not an MD5; upload with a single `PutObject` and `Content-MD5`, or store the MD5 as object metadata.
- Azure: Arrow's `AzureFileSystem` is not built on Windows; reads there need a download cache or GDAL's `/vsiaz/`.
- Google Drive: no streaming through Arrow or GDAL; needs a download cache keyed by MD5; paths resolve by name, so duplicate names in a folder must abort.
- Conditional catalog writes (GCS generation match, S3 `If-Match`) to close the write guard's race window.

## Open questions

None. Every design question was decided on 2026-11-20. Work package B checked the two technical points below; the outcome is under "Results of wave 1" (no violation for inside rows; the pole row needed another remedy than the one named here):

- Inside rows: the four-corners test treats the bounding box as lying inside the cell, although box edges along parallels and cell edges along great circles differ slightly. In the review, none of 97,429 random boxes up to 0.08° wide with four corners in one resolution-5 cell had a boundary point in another cell, and the first ring of the covering absorbs small errors. B measures it at higher latitudes and for larger rows; if a violation is found, rows whose box comes closer to a cell edge than the measured error become crossing rows.
- Antimeridian and pole rows: whether the chosen H3 package returns the right cells for such shapes, checked against the brute-force reference; if not, B splits the shapes at ±180° before asking for cells.

## Outcome

