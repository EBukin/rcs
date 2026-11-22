# rcs, second round: lazy reads, DuckDB, credentials, geospatial transforms, sync, robust geocoding

- **Date:** 2026-11-21
- **Author:** Eduard Bukin
- **Status:** in execution; waves 0-1 done (2026-11-21)

## Goal

The package `rcs`, as built by plan 0001, gains eight features. Every design decision is taken here, so that an orchestrating session runs the plan wave by wave without asking the project owner anything except on failure:

1. `store_open()` is the documented way to work with a dataset: lazy, and printed like a dbplyr table (a header plus the first rows).
2. DuckDB works on a store with one call: every dataset becomes a view (no data copied), optionally in a local `.duckdb` file that also holds the user's own tables. `store_tables()` lists the datasets of a store or the tables of a DuckDB connection. `store_intersects()` works on DuckDB tables. `store_write()` writes a DuckDB table to every location of a store without loading it into R; geospatial data passes through R in batches.
3. R types (factor, ordered, difftime, `integer64`, H3 cells) are restored only when data lands in R, from the metadata the catalog already holds, also for DuckDB results, and through an exported function for any data frame.
4. H3 cells are stored as 64-bit integers and printed as hex; `rcs_h3_hex()` converts any cell vector, in R and inside DuckDB.
5. Credentials are set per connection, once, and reach every client (Arrow, the JSON API, GDAL, DuckDB) without environment variables; `store_auth_check()` tests each client on each location.
6. Geospatial preparation is a set of in-memory verbs (`rcs_geo_add()`, `rcs_geo_index()`, `rcs_geo_strip()`), so a dataset goes from raw to deploy-ready and back without reading or writing; `store_write()` accepts prepared data and stores extra parent-cell columns.
7. `store_sync()` syncs from any location to the others, deletes datasets the source no longer holds when asked, and stops at conflicts.
8. Geometries that are valid in the plane but invalid on the sphere are geocoded correctly: per-row repair, a check of every repair, a planar fallback, a warning that names the rows, and a geocoding engine recorded per dataset.

The package passes `devtools::check(cran = TRUE)` with 0 errors, 0 warnings and 0 notes, and the whole suite passes at `RCS_TEST_LEVEL=full` against `gs://rcs-test`.

## Context

- Plan 0001 (`.docs/plans/0001-rcs-package.md`) and its handoff (`.docs/handoffs/0002-waves-1-to-6.md`) describe the package as it stands; every rule, contract and gotcha there still holds unless this plan changes it explicitly. Each work package names the sections of them it must read.
- The features were prototyped on 2026-11-21 in `dev/prototype/` (simulated data, locally and against `gs://rcs-test`). The prototypes are reference code, not package code: they override namespace bindings, use a global registry for credentials and skip edge cases. Each work package names the prototype it may read. Wave 11 deletes them.
- Inherited conventions (plan 0001, "Context"): one topic per file in `R/`, roxygen everywhere, cli for every message, tidyverse style and the `r-lib:*` skills, all R work through the `run-r` skill with one Positron R session per agent (at most 3 at once), worktrees for parallel agents, the neutrality rule, no CI workflow, commit messages without e-mail address and without AI attribution, explicit paths when staging.
- **No benchmarks.** Nothing under `bench/` is run, no file under `bench/results/` changes, `bench/quick.R` is not run, the performance budget of plan 0001 is not re-measured, and no `vignettes/articles/benchmark-*.Rmd` is edited. Speed is guarded by work counters in ordinary tests only. Several `bench/` scripts call internals this plan changes (`gcs_reset_clients()`, `geo_encode()`); they are not re-validated, and "Outcome" says so. `gcs_reset_clients()` keeps its name and meaning (clear cached clients) so that they still load.

### Facts found while prototyping and reviewing

Checked on 2026-11-21 with R 4.6.2 (Windows), arrow 26.0.1, duckdb 2.0.0, dbplyr 2.6.0, pillar 1.11.1, sf 1.1.3, s2 (as installed), terra 1.9-50, GDAL 3.12.1, gargle 1.7.0, httr2 1.3.0. Each is a rule for implementers.

DuckDB:

1. DuckDB returns `BIGINT` as double unless the connection is made with `DBI::dbConnect(duckdb::duckdb(), bigint = "integer64")`; a double cannot hold an H3 cell exactly. Every connection the package makes uses `bigint = "integer64"`; a connection passed in by the user without it aborts.
2. `dplyr::tbl(con, I("schema.table"))` and `dbplyr::in_schema()` fail in duckdb 2.0.0; `dplyr::tbl(con, DBI::Id(schema = , table = ))` works (it prints an S4 method note once per session).
3. dbplyr forbids `$` on a lazy table. Package fields on a dbplyr table are read with `.subset2(x, "rcs")` and set by `unclass()`, assign, restore the class. They survive `filter()`, `select()`, `mutate()`.
4. `duckdb::duckdb_register_arrow()` aborts when the name is registered; unregister first (`duckdb::duckdb_unregister_arrow()`, errors ignored).
5. A database file `work.duckdb` is attached as catalog `work`; a schema `work` inside it is then ambiguous. The in-memory database is catalog `memory`.
6. Views over `read_parquet([...])` persist in a `.duckdb` file and work after reopening with `DBI::dbConnect()`; views over Arrow registrations do not survive closing. A view stores query text only.
7. DuckDB 2.0.0 reads the package's GeoParquet `geometry` column as `GEOMETRY('<PROJJSON>')` through `read_parquet()` even without the `spatial` extension; R receives it as a list of raw vectors identical to `ST_AsWKB(geometry)` (WKB). Through an Arrow registration it stays `BLOB`. `INSTALL spatial` and `INSTALL httpfs` download extensions on first use (network).
8. On the package's paths (`h3_p3=<cell>`, `h3_p3=null`) `read_parquet()` with automatic hive detection gave the same types (`BIGINT`) and nulls as `hive_partitioning = false`; views still set `hive_partitioning = false`, because partition values in paths are URL-encoded strings.
9. Filters on a view over an Arrow registration are pushed into the Arrow scan.
10. DuckDB 2.0.0 accepts `CREATE SECRET <name> (TYPE gcs, BEARER_TOKEN '<token>', SCOPE 'gs://<bucket>[/prefix]')`; `read_parquet('gs://...')` and `COPY ... TO 'gs://...'` then work against `gs://rcs-test`. `PROVIDER credential_chain` needs the `aws` extension, which is not published for the R build on Windows. A secret without `PERSISTENT` lives only in its connection.

Credentials:

11. `arrow::GcsFileSystem$create(access_token = , expiration = )` works with a token of the gcloud application-default login; it does not renew it.
12. Token of an `authorized_user` file: POST to `https://oauth2.googleapis.com/token` with `grant_type = refresh_token`. Service-account key: `gargle::credentials_service_account(scopes = "https://www.googleapis.com/auth/cloud-platform", path = )`. `https://oauth2.googleapis.com/tokeninfo?access_token=` returns the account e-mail when the token has that scope.
13. GDAL `/vsigs/` opened and read a raster with each of: `GS_OAUTH2_REFRESH_TOKEN` + `GS_OAUTH2_CLIENT_ID` + `GS_OAUTH2_CLIENT_SECRET`; `GOOGLE_APPLICATION_CREDENTIALS` set as a GDAL config option to the `authorized_user` file; `GDAL_HTTP_HEADERS = "Authorization: Bearer <token>"`. Set with `terra::setGDALconfig(option, value)`; `terra::setGDALconfig("KEY=")` sets the value `"NA"`, so clear with `terra::setGDALconfig("KEY", "")`. A `SpatRaster` reads tiles lazily, so the options must stay set while it is used. GDAL caches a failed open: the same path keeps failing in that session.

R and the package:

14. An S3 method defined in a test for a class whose method exists in the namespace is not used (`UseMethod()` finds the namespace function by name first): tests use `testthat::local_mocked_s3_method()` or `local_mocked_bindings()`. R6 methods (`GcsFileSystem$create`), `terra::setGDALconfig()`, httr2 calls and the clock cannot be mocked directly: the package calls them through the internal wrappers named in "Contracts".
15. A column of class `c("rcs_h3", "integer64")` made the serialization check fail in the prototype. Root cause: the prototype's `as.character.rcs_h3()` returned hex, and `as.character()` of `integer64` is the package's canonical decimal conversion (`partition_values_json()`, `row_to_list()`, `normalise_key()`, `normalise_values()`, `format_partition()`). The class therefore has no `as.character()` method.
16. bit64's `unique()`, `sort()`, `rep()`, `[[` and `c()` drop a subclass; vctrs double dispatch does not inherit, so `rcs_h3` needs `vec_ptype2()`/`vec_cast()` with itself and with `integer64`.
17. `geo_as_s2(g)` validates a whole chunk: one invalid geometry sends every row of the chunk through `s2::s2_rebuild()`, silently. Inside rows never reach s2 (their cell comes from the box corners).
18. Planar-valid, sphere-invalid polygons (verified, EPSG:4326, each crosses resolution-5 cell edges, 11 cells touched):
    - duplicated consecutive vertex: `POLYGON((-27.2 7.1, -26.9 7.1, -26.9 7.1, -26.9 7.4, -27.2 7.4, -27.2 7.1))` (s2: "Loop 0: Edge 1 is degenerate (duplicate vertex)");
    - spike almost touching an edge: `POLYGON((-27.2 7.1, -26.9 7.1, -26.9 7.4, -27.05 7.4, -27.05 7.1000000001, -27.06 7.4, -27.2 7.4, -27.2 7.1))` (s2: "Edge 0 crosses edge 3").
    Two vertices 1e-9 degrees apart are valid on the sphere (not a usable fixture). `s2_rebuild()` keeps both polygons whole.
19. Comparing the s2 area of a rebuilt polygon with the planar area in EPSG:6933 differs by about 4e-3 even for a faithful rebuild (sphere against ellipsoid), above the tolerance 1e-3. Converting the rebuilt geography back to WKB (`s2::s2_as_binary()`) and measuring both it and the original in EPSG:6933 under `sf_use_s2(FALSE)` gives a relative difference of about 1e-14 for faithful rebuilds, also for long edges. That is the comparison D31 uses.
20. Long edges: for `POLYGON((-40 10, -15 10, -15 12, -40 12, -40 10))` (valid in both readings) the sphere touches 2,691 resolution-5 cells and the plane 2,656; 229 cells only on the sphere, 194 only in the plane, and 42 planar cells lie beyond the first ring of the sphere's cells. Planar candidate cells must therefore come from boundary points densified along straight edges.
21. The package keeps extra user columns named `h3_p<r>` on write (only `.rcs_id`, `h3`, `bbox` are reserved); with `partition = "h3"` the write's own `h3_p<r>` silently replaces a user column of the same name.
22. `store_status()` reports `extra` and `newer`; `store_copy(st, dataset, from, to)` copies one dataset between any two locations (version, MD5, write guard); `store_delete()` removes a dataset from every location. `unit_needed()` copies when the entry differs, also at the same version (title, history setting).
23. `entry_metadata_json()` embeds every catalog field not in `entry_not_embedded`, with `NA` as `null`: a new catalog column changes the file MD5 of every dataset unless it is left out when `NA`. `manifest_from_json()` and `entry_from_metadata_json()` tolerate a missing key (`row_from_list()`); `schema_as_tibble()` aborts on a missing column.
24. `files_stage()` builds the entry, the embedded `rcs` JSON and the manifest rows; `geo_metadata()` needs the geometry types and box of the rows of each file; `files_write_parquet()` writes with `compression = "zstd"` and `chunk_size = rows_per_group`.

## Owner decisions

The review left seven points to the owner, decided on 2026-11-21 and written into the decisions below.

1. Catalog column and versions: `geocode_engine` is left out of the embedded metadata when `NA`, so only geospatial datasets written with an engine get a new version once (D30). Alternative: every dataset gets a new version on its next rewrite.
2. The exact-test argument is named `exact_engine` (D35), so that `engine` keeps one meaning (`store_open(engine = "arrow" | "duckdb")`).
3. Sync conflicts by `updated` (target newer → conflict), plus a warning that lists every target version overwritten when the source is newer (D29). Detection through history is later work.
4. `store_sync(delete = TRUE)` deletes on the primary only with `force = TRUE` (D29).
5. `store_tables()` handles stores and DuckDB connections; any other DBI connection aborts (D19).
6. The neutrality scan of wave 11 needs no input from the owner: a subagent derives the search patterns and runs the scan itself (Y2).
7. Only rows whose cells come from s2 (crossing rows; the read side's candidate rows) are validated on the sphere (D31).

## Decisions

All taken; implementers do not reopen them.

### Lazy reads and printing

- **D1.** `store_open()` is the documented entry point in README and vignettes: open, then dplyr verbs, then `collect()`. `store_read()` stays unchanged in behaviour, documented as the shortcut for open + filter + collect.
- **D2.** `print.rcs_query(x, ..., n = NULL)`: `n` defaults to `rcs_option("rcs.print_rows")` (10). It collects `head(x, n + 1)` (the exact spatial test included) and prints the first `n` rows with pillar under a header; printing opens files, accepted. Header lines (pillar prefixes `# `), in order:
  - `Dataset:  <full name> [<rows> x <cols>] (<kind>)`. `<rows>` is the catalog count with thousands separators only when the query is the source plus at most one `select()`, `rename()` or `mutate()` step, with no Arrow filter, no spatial filter and all files kept; otherwise `??`. `<cols>` counts the columns `collect()` returns (`.rcs_id` excluded; geometry excluded when dropped).
  - `Location: <primary|secondary n> (<local|gcs>)`.
  - `Version:  <first 8 hex> (<current|earlier>)`.
  - `Files:    <kept> of <total>`, plus ` (pruned)` when kept < total.
  - `Spatial:  <spatial_describe()>` when a spatial filter is set.
  - `Filter:   <x$query$filtered_rows$ToString()>`, truncated to the console width with `...`, when an Arrow filter is set and no spatial filter is set; with a spatial filter: exactly `Filter:   (with spatial predicate)`.
  Footer: pillar's own footer lines, then `# ℹ <n> more rows` when the total is known, `# ℹ more rows` when not known and n + 1 rows came back, `# ℹ more rows may exist` instead whenever an exact spatial test is pending (it runs after `head(n + 1)`), then `# ℹ Use `collect()` to read the rows into R.`; a query with no rows prints the header and `# ℹ 0 rows`. Geometry prints as an `sf` column. `print()` returns `x` invisibly.
- **D3.** `print()` of a DuckDB table returned by the package is dbplyr's own print.

### Types

- **D4.** Types are restored only when data lands in R: `collect()` on an `rcs_query` (as today), `collect()` on a DuckDB table made by `store_open(engine = "duckdb")`, and `store_restore_types()`. Inside Arrow and DuckDB, and in files written from DuckDB, values keep storage types.
- **D5.** `store_restore_types(x, st, dataset)` (exported) restores from the catalog's `columns` specification of `dataset` every column of `x` whose name is in the specification and whose storage type is compatible: factor and ordered from character or factor (values outside the levels become `NA` with one `cli_warn()` per column giving the count), difftime from double (recorded units), `integer64` from integer, `integer64`, or double when every value is whole and below 2^53 (else left as is with a warning), list from `arrow_list` or list, H3 cells by D8. Other columns are left unchanged silently. Returns `x` with its class kept (tibble, data frame, `sf`). The match is by name; the help page says that a computed column reusing a source name is restored as that column.
- **D6.** No type metadata is added to Parquet key-value metadata; the catalog and manifests remain the source of `r_type`.

### H3 cells

- **D7.** Class `rcs_h3`: `c("rcs_h3", "integer64")`, the same 64 bits. Internal constructor `new_rcs_h3()`. `format()` gives the 15-character lower-case hex through `h3_int64_to_hex_raw()` with `NA` as `"NA"` and a value that is not a valid cell as `"<invalid>"`; it never aborts. Methods (registered, D44): `format`, `print`, `[`, `[[`, `[<-`, `c`, `rep`, `unique`, `sort`, `rev`; `pillar::pillar_shaft` (left-aligned hex) and `pillar::type_sum` (`h3`); `vctrs::vec_proxy`, `vctrs::vec_restore`, and `vec_ptype2`/`vec_cast` between `rcs_h3` and `rcs_h3` and between `rcs_h3` and `integer64` in both directions (common type `rcs_h3`). No `as.character()` method (fact 15): `as.character()` gives decimals, as for `integer64`. Comparison and arithmetic are those of `integer64`.
- **D8.** `h3_classify(data, entry)` (internal, contract) gives class `rcs_h3` to: `h3`, `h3_main` and every `h3_p<r>` column when `entry$kind == "geospatial"` or `!is.na(entry$index_of)`; and every column whose `r_type` is `list(class = "rcs_h3")`. Called by `collect()` of both engines and by `store_restore_types()`. Datasets written before this plan are covered by the name rule. On write the package's own cell columns (`h3`, `h3_main`, `h3_p<r>` of geospatial datasets and index tables) record `r_type = list(class = "integer64")` whatever their class; any other column of class `rcs_h3` records `r_type = list(class = "rcs_h3")`; both are stored as `int64`. Writing a column as `rcs_h3` or as `integer64` gives identical files, paths and version (only the user-column `r_type` differs, by design, and it is not embedded per file).
- **D9.** `rcs_h3_hex(x)` (exported) gives hex strings for `rcs_h3`, `integer64`, hex strings (validated, lower-cased), `h3o` `H3`, and doubles; a double warns `rcs_warning_h3_double` that values above 2^53 may have lost bits; every input is validated as `h3_as_hex()` does (invalid → `rcs_error_h3_input`); `NA` stays `NA`. `store_h3_hex()` is unchanged.
- **D10.** Every DuckDB connection the package prepares gets `CREATE OR REPLACE MACRO rcs_h3_hex(x) AS lower(printf('%x', x))`.

### DuckDB

- **D11.** `store_duckdb(st, path = NULL, datasets = NULL, mode = c("native", "arrow"), spatial = FALSE, con = NULL)` returns the DuckDB connection invisibly after creating one view per dataset of the primary catalog (rasters excluded, index tables included) and prints one `rcs_inform()` line naming the views. `path` and `con` `NULL`: in-memory database. `path`: a `.duckdb` file, created when missing (D16, D17). `con`: an existing connection, which must have been made with `bigint = "integer64"` (checked with `SELECT 9007199254740993::BIGINT` coming back as `integer64`; else abort `rcs_error_duckdb`); `path` must then be `NULL`. `datasets`: full or short names; their index tables are added automatically. `st` may be missing only with `path` (D16).
- **D12.** `duckdb_view_name(dataset)` (internal, contract): schema = first part of the name, table = the other parts joined with `__`; a one-part name goes to schema `main`. Index tables keep their `__h3` suffix. Aborts (`rcs_error_duckdb`) in `store_duckdb()`: two datasets mapping to one view name (for example `a/b__c` and `a/b/c`, or `main/x` and `x`); a first part `rcs`; a schema equal to `current_database()` or to any database name in `duckdb_databases()` (fact 5).
- **D13.** Modes. `"native"` (default): the view is `SELECT * FROM read_parquet([<file URLs>], hive_partitioning = false)`, the URLs being local absolute paths or `gs://<root>/<path>`; for each GCS location used a secret is created by `auth_duckdb_secret()` (D22). `"arrow"`: `query_open_files()`'s dataset is registered as `rcs_arrow_<schema>__<table>` (re-registered when present, fact 4) and the view selects from it; with `path` set, an `rcs_inform()` says that such views must be refreshed with `store_duckdb()` after reopening. The location of each dataset is the one `choose_location()` picks, as for reads.
- **D14.** `spatial = TRUE` runs `INSTALL spatial; LOAD spatial;` and in `"arrow"` mode adds `ST_GeomFromWKB(geometry) AS geom` to geospatial views. Native views already carry `GEOMETRY` (fact 7).
- **D15.** Tables in schema `rcs` of every prepared connection: `rcs.views` (`view` = `schema.table`, `dataset`, `version`, `location`, `mode`, `refreshed` UTC) and `rcs.store` (`role`, `uri`, in connection order). With `datasets = NULL` both are rewritten and views listed in `rcs.views` whose dataset is no longer in the catalog are dropped. With `datasets` given, only those rows are upserted and nothing is dropped. One store per connection: when `rcs.store` exists and its primary differs from `st`'s, abort `rcs_error_duckdb`. They hold no credential.
- **D16.** Reopening: `store_duckdb(st, path = <same file>)` refreshes the views of the catalog the connection holds (`CREATE OR REPLACE VIEW`), recreates secrets, updates `rcs.*`, and leaves other objects untouched. An existing object with a view's name that is a table, or a view not listed in `rcs.views`, aborts `rcs_error_duckdb` naming it. `store_duckdb(path = <file>)` without `st` reads `rcs.store` from the file, connects with `store_connect(<primary>, <secondaries>)` (default credentials) and refreshes; a file without `rcs.store` aborts. A plain `DBI::dbConnect()` on the file works for the user's tables and for views whose files still exist; this is documented with its limits (stale versions; GCS views need a secret).
- **D17.** Guards: `path` inside the folder of any local location of `st` aborts (a sync would carry it).
- **D18.** `store_open(st, dataset, version = NULL, engine = c("arrow", "duckdb"), con = NULL, mode = "native", spatial = FALSE)`. `engine = "duckdb"`: `version` other than `NULL` aborts; `con = NULL` uses one package-level connection per store (keyed by the primary uri, in-memory, `bigint = "integer64"`, closed by a finalizer and by `store_duckdb_close(st)`, internal), else the given `con` (checked as in D11). It calls `store_duckdb(st, con = , datasets = <dataset>, mode = , spatial = )` quietly and returns `dplyr::tbl(con, DBI::Id(schema = , table = ))` with field `rcs = list(store = st, dataset = <full name>, mode = <mode>, tests = list())` (fact 3) and class `c("rcs_duckdb_tbl", <dbplyr classes>)`. Requires `duckdb`, `DBI`, `dbplyr` (`rlang::check_installed()`).
- **D19.** `store_tables(x, st = NULL)` (exported). `rcs_store`: `store_datasets(x)` plus a column `duckdb_view` (D12 name). DuckDB connection: one row per table and view outside `information_schema`, `pg_catalog` and `rcs`: `schema`, `name`, `type` (`"view"` or `"table"`), `dataset` and `version` (from `rcs.views`, `NA` for user objects), and with `st`: `current` (`TRUE` when the view's version equals the catalog's, `FALSE` when not, `NA` for user objects). Any other input aborts `rcs_error_argument`.
- **D20.** `collect.rcs_duckdb_tbl(x, ...)`: wraps a `GEOMETRY` column `geometry` in `ST_AsWKB()` in the SQL (fact 7), collects through dbplyr, drops `.rcs_id` and `geom`, applies `store_restore_types()` for the dataset, runs pending exact spatial tests (D28) through `exact_keep()` when `geometry` is present (else the same candidate-set `rcs_inform()` as the Arrow path), and returns a tibble, or `sf` with the catalog CRS when `geometry` is present.

### Credentials

- **D21.** `rcs_auth_gcs(key = NULL, token = NULL, fun = NULL)` (exported); at most one argument. None: default lookup: `GOOGLE_APPLICATION_CREDENTIALS` when set, else `$CLOUDSDK_CONFIG/application_default_credentials.json` when `CLOUDSDK_CONFIG` is set, else `%APPDATA%/gcloud/application_default_credentials.json` (Windows) or `~/.config/gcloud/application_default_credentials.json`. When no file exists, the credential is of source `"ambient"`: Arrow uses `GcsFileSystem$create()` defaults, the JSON API `gargle::credentials_app_default()` (metadata server on Google Cloud), and GDAL and DuckDB report "not supported for this source" in `store_auth_check()`. `key`: a JSON file of type `service_account` or `authorized_user` (other types abort `rcs_error_backend`). `token`: an access token (not renewed). `fun`: a function of no arguments returning a token or `list(access_token, expires_in)`. The object (class `rcs_auth_gcs`) is a list with `source`, `type`, `file` and an environment `cache`; token, refresh token, client secret and function live only in `cache`. It renews file and function tokens five minutes before expiry and is cached per source in a package environment (same source → same object). `print()` shows source, type, file, identity (from `cache`, filled after the first token by `auth_tokeninfo()`), validity; it never contacts the network and never shows a secret. Credential values are never logged, written to files or catalogs, or put in environment variables; the only process-wide copy is GDAL's config options (D23).
- **D22.** `store_connect(..., auth = NULL)` and `store_create(location, history = FALSE, auth = NULL)`: `NULL` uses `rcs_auth_gcs()` for every GCS location; an `rcs_auth_gcs` object applies to every GCS location; a string is a key file path; a named list maps addresses (as given) to any of these. `be_new(uri, auth = NULL)`: GCS backends get the field `auth` (local backends get no field). The session caches `the_gcs$fs`, `the_gcs$token` are removed; `gcs_reset_clients()` clears the per-credential caches. Clients: Arrow through `auth_arrow_fs()` (rebuilt when the token changes); JSON API bearer token; DuckDB: `auth_duckdb_secret(auth, con, scope)` creates `CREATE OR REPLACE TEMPORARY SECRET rcs_<md5 of scope> (TYPE gcs, BEARER_TOKEN ..., SCOPE '<gs://bucket/prefix>')`; a failing statement re-aborts `rcs_error_duckdb` without echoing it; `store_duckdb()` refreshes secrets on every call (the documentation says to call it again after an hour of DuckDB work on GCS).
- **D23.** GDAL: `be_gdal_path.rcs_backend_gcs()` sets process-wide GDAL options through `gdal_config()` when the credential differs from the one GDAL holds: `authorized_user` → the three `GS_OAUTH2_*`; `service_account` → `GOOGLE_APPLICATION_CREDENTIALS` as a GDAL config option; token or function → `GDAL_HTTP_HEADERS` bearer; the other options of this list are cleared. Renewing the same credential's token updates the header silently. A switch to another credential warns once per session (`rcs_warning_gdal_credential`).
- **D24.** `store_auth_check(st)` (exported): tibble `location`, `client` (`arrow`, `json_api`, `gdal`, `duckdb`), `ok`, `note`; local locations give one row (`client = "all"`, `ok = TRUE`, `note = "local folder: no credentials needed"`). Probes: Arrow `GetFileInfo()` of `_catalog.parquet`; JSON API `be_md5()` of it; GDAL `terra::rast()` of the first raster file in the location's catalog (none: `ok = NA`, `note = "no raster to test with"`); DuckDB `read_parquet()` count of `_catalog.parquet` with the secret (skipped with `ok = NA` when `duckdb` is not installed). It never aborts for a failing client.
- **D25.** `be_auth_hint()` is rewritten: it names the credential source in use and how to pass another (`auth = `). A rejected token or key aborts `rcs_error_backend` with it.

### Geospatial transforms

- **D26.** Exported verbs; they keep row order and column order of `x` (new columns go immediately before the active geometry column), never contact a store, and warn like D32 naming row numbers:
  - `rcs_geo_add(x, h3_res = 5L, bbox = TRUE, parents = NULL, geocode_engine = c("auto", "s2", "planar"), replace = FALSE)`: adds `h3` (`rcs_h3`), `h3_p<r>` for each `r` in `parents` (each below `h3_res`), `bbox` (data-frame column in the CRS of `x`). A present column with different values aborts `rcs_error_prepared` unless `replace = TRUE`; equal values stay. `h3_res = NULL` adds no cell column.
  - `rcs_geo_index(x, id, h3_res = 5L, geocode_engine = , crossing_only = TRUE)`: `<id>`, `h3`, `h3_main`, `share` (cells `rcs_h3`); `crossing_only = FALSE` adds one line per inside row with `share = 1`.
  - `rcs_geo_strip(x, columns = NULL)`: drops `.rcs_id`, `h3`, `h3_main`, `bbox` and every `h3_p<r>`, and `geom` unless it is the active geometry column; or the named columns.
  - Round trip (tested): for `store_write(st, rcs_geo_add(raw), d, key = k)`, `rcs_geo_strip(collect(store_open(st, d)))` ordered by `k` equals `raw` ordered by `k`: equal attributes after `tibble::as_tibble(sf::st_drop_geometry())`, identical WKB, equal CRS.
- **D27.** `store_write()` with an `sf` holding package columns, in every mode: `.rcs_id` is dropped and reassigned; supplied `h3` and `bbox` are renamed to temporaries, the write computes its own through `geo_encode()` and compares in written order through `geo_encode()$order`; equal → accepted silently; different → abort `rcs_error_prepared` with the count, the first five keys (or row numbers), the engine the write used, and the advice to prepare with the same `geocode_engine` or to call `rcs_geo_strip()` first. When `h3_res` is not given it is taken from the supplied cells; mixed resolutions, or a given `h3_res` that differs, abort `rcs_error_prepared`. `geocode = FALSE` with a supplied `h3` aborts. `h3_p<r>` columns are user columns written as they are, except that with `partition = "h3"` a column equal to the write's chosen partition column serves as it (moved to the standard position after `h3`) and a different one aborts. Raw and prepared writes of the same data give the same version.

### DuckDB spatial filter

- **D28.** `store_intersects(q, y, exact = TRUE, exact_engine = NULL)` dispatches on `q`: `rcs_query` as today plus `exact_engine` (D35); `rcs_duckdb_tbl`: aborts `rcs_error_argument` when `bbox`, `h3` or `.rcs_id` are missing from `colnames(q)` (cells only needed when used); the box test on `bbox` fields (180-degree rule in a geographic CRS); when `spatial_use_cells()` says so, `h3 IN (...) OR ".rcs_id" IN (SELECT ".rcs_id" FROM <index view> WHERE h3 IN (...))`, the cells as integer literals up to 10,000 cells and through a registered temporary table above. `exact = TRUE`: exact test in R at `collect()` with the engine of D35 (rows identical to the Arrow path); `exact = "sql"`: `ST_Intersects(<geometry>, ST_GeomFromText('<WKT>'))` in DuckDB (loads `spatial`; planar; lazy; for every query except antimeridian and pole queries it returns the rows of the Arrow path read with `exact_engine = "planar"`); `exact = FALSE`: candidates, same message as the Arrow path. Several calls combine.

### Sync

- **D29.** `store_sync(st, datasets = NULL, to = NULL, from = NULL, delete = FALSE, force = FALSE, dry_run = FALSE)`. `from`: an address of the connection, default the primary. `to`: addresses, default every other available location (the primary included when `from` is a secondary). Per target, in this order: copies, then deletions. Per selected dataset of the source (index tables travel with their dataset):
  - missing on target → copy; same entry → nothing; entry differs → copy, unless a conflict;
  - conflict: versions differ and the target entry's `updated` is later than the source's. Without `force` it is not copied and is reported; after all targets the call aborts `rcs_error_sync_conflict` listing every conflict, carrying the result tibble in the condition field `result`; copies and deletions made stay. With `force = TRUE` the source is copied over it;
  - versions differ and the source is newer: copied, and one `cli_warn()` (`rcs_warning_sync_overwrite`) per call lists the target versions overwritten (owner decision 3);
  - `delete = TRUE`: datasets on the target and absent from the source (index tables excluded) are deleted on that target exactly as `delete_switch(purge = FALSE)` and `delete_files()` do for one location. On the primary only with `force = TRUE` (owner decision 4); without it they are listed in the result column `kept` and in the summary as "delete on primary needs force". Deletions run also when conflicts were found, and are reported. `datasets` restricts deletions too.
  - Copies use `store_copy()`'s machinery. History settings of the target apply.
  - `dry_run = TRUE` changes nothing and prints per target the copies, deletions and conflicts; status `to sync`.
  - Result, one row per target: `location`, `status` (`synced`, `same`, `behind`, `unavailable`, `conflict` when any conflict, `to sync`), `datasets`, `deleted`, `kept`, `conflicts` (list columns), `files`, `bytes`, `seconds`.
- **D29a.** `store_status(st, from = NULL)`: compared against `from` (default primary); `newer` is `"source"` or `"target"`; column names unchanged (`primary_version`, `primary_updated` describe the source; the help says so); the print names the source.

### Geocoding engines

- **D30.** `store_write(..., geocode_engine = c("auto", "s2", "planar"))`, default `"auto"`, stored in the new catalog column `geocode_engine` (string, after `h3_res`); `NA` for tables, index tables, rasters, `geocode = FALSE`, and datasets written before this plan. Embedded in the Parquet `rcs` metadata and the manifest only when not `NA` (owner decision 1), so tables and older datasets keep their file MD5s and versions. `update`: the stored engine is used; an explicit different `geocode_engine` (detected with `!missing()`) aborts; when the stored engine is `NA`, new rows are geocoded with `"s2"` per row, the entry stays `NA`, and an explicit `geocode_engine` aborts.
- **D31.** Validation and engines per row, for rows whose cells come from s2 (crossing rows; inside rows keep their corner cell for every engine, fact 17). Each such row is validated alone with `s2::s2_is_valid()` (fixes fact 17):
  - valid rows: on the sphere as today (engine `"s2"` and `"auto"`); in the plane for `"planar"`.
  - invalid rows, `"s2"`: `geo_rebuild()` (internal wrapper of `s2::s2_rebuild()`) of that row; the result is used.
  - `"planar"` (all crossing rows): candidate cells from boundary points of `geo_densify_planar(g, h3_edge_m[[h3_res + 1]] / 3 / 111320)`, their first ring, and the cells whose centre lies inside (fact 20); touch test `sf::st_intersects()` of the row with its candidate cell polygons (`sf::st_as_sfc()` of the `H3` cells, EPSG:4326) under `sf_use_s2(FALSE)`; shares: one `sf::st_intersection()` call per row (the row against its touched cell polygons) in EPSG:4326 coordinates under `sf_use_s2(FALSE)`, the parts transformed to EPSG:6933, areas (lines: lengths) normalised to sum to 1; points `1 / n`; the largest share gives `h3`. The planar engine is slow by design; no performance acceptance.
  - `"auto"`, invalid rows: `geo_rebuild()`, then the check: rebuilt copy empty, or `abs(A(rebuilt) / A(original) - 1) > rcs_option("rcs.s2_rebuild_tol")` (default `1e-3`) where `A` is the area (lines: length; points: number of points) of the geometry as WKB (`s2::s2_as_binary()` for the rebuilt copy) in EPSG:6933 under `sf_use_s2(FALSE)` (fact 19), or `A(original)` not positive and finite, or any error or non-finite value while measuring → planar computation for that row; otherwise the rebuilt result.
  - Rows whose box spans 180 degrees or more are geocoded on the sphere for every engine.
  - Deterministic: the same input gives the same cells, shares and version.
- **D32.** Reporting: one `cli_warn()` (`rcs_warning_s2_rebuild`) per write when any row was rebuilt or fell back: counts of rebuilt rows and of planar fallbacks and the first five keys of each group (key columns when the write has a key, else `.rcs_id`), shown before the upload lines.
- **D33.** `geo_covering()` and the completeness argument of plan 0001 are unchanged: the covering already joins the spherical and planar readings.
- **D34.** Projected data (CRS not geographic): geocoding follows D31 on the EPSG:4326 copy and the engine is stored as for geographic data; only the exact test differs: it is always planar in the data CRS, whatever `exact_engine`.
- **D35.** Exact test engine on reads: `store_read(..., exact_engine = NULL)`, `store_intersects(..., exact_engine = NULL)`. `NULL` → from the dataset: `"s2"` → sphere; `"planar"` → plane; `"auto"` → sphere for candidate rows valid on the sphere, plane for the others; `NA` → the session's `sf::sf_use_s2()` as today. Explicit `"s2"`, `"planar"`, `"session"` override. D34 applies to projected data. `check_query_valid()` uses the sphere for `"s2"` and `"auto"` (the abort advises `exact_engine = "planar"`), the plane for `"planar"`, and the session rule for `"session"`/`NA`. `exact_keep(geometry, shape, exact_engine, geographic)` (internal, contract) returns the logical vector of rows that intersect; `spatial_exact()` and `collect.rcs_duckdb_tbl()` call it.

### Writing from DuckDB

- **D36.** `store_write(st, x, ...)` accepts `x` = a lazy table on a DuckDB connection (`tbl_duckdb_connection`, `rcs_duckdb_tbl` included); a lazy table on another DBI backend aborts `rcs_error_argument`. Modes `create` and `replace`; `update` aborts with advice to collect or write in full. Columns `.rcs_id`, `h3`, `bbox`, `geom` in `x` are dropped with one `rcs_inform()` and recomputed; `h3_p<r>` are user columns. No rows are collected into R as a whole; peak R memory is about one batch.
- **D37.** First the query is materialised inside DuckDB: `CREATE TEMPORARY TABLE rcs_write_<random> AS SELECT *, row_number() OVER () AS ".rcs_tmp" FROM (<rendered SQL>)`; every later statement reads that table (the documentation mentions this temporary copy inside DuckDB); it is dropped at the end, also on error. Batches of `rcs_option("rcs.duckdb_batch_rows")` rows (default `5e5`) are fetched through the internal wrapper `duckdb_batches(con, sql, n)` (`duckdb::duckdb_fetch_record_batch()`); each phase reports progress through the internal `write_progress()` (cli bar: rows done of total, batch k of K, time left; silenced by `rcs.quiet`).
- **D38.** Tables: key uniqueness in DuckDB (`GROUP BY <key> HAVING count(*) > 1`, first five in the message, `rcs_error_key`, nothing staged); partition values from `SELECT DISTINCT` (more than `max_files` aborts); rows read `ORDER BY <partition>, <key>, ".rcs_tmp"`; `.rcs_tmp` is dropped from the output. Each output file is written by an `arrow::ParquetFileWriter` with `compression = "zstd"` and the schema metadata `files_stage()` writes; rows are re-buffered so that every row group holds exactly `rows_per_group` rows except the last of a file. File names, file rows, entry and manifest are built by the same code as `files_stage()` (refactored into a shared internal used by both, in `R/files.R`, owned by V). Type mapping: integer, double, varchar, date, boolean pass through; `BIGINT` gets `r_type = list(class = "integer64")`; `TIMESTAMP` is stored without time zone; `TIMESTAMPTZ` as UTC; `HUGEINT`, `UHUGEINT`, `INTERVAL`, `UNION`, `MAP` and other types Arrow cannot write abort `rcs_error_argument` naming the columns. Descriptions from `columns =`.
- **D39.** Geospatial: `x` has a column `geometry` of type `BLOB` (WKB) or `GEOMETRY` (wrapped in `ST_AsWKB()`); the new argument `crs` is required. Pass 1 streams batches through R: per batch `bbox`, `h3`, index rows (engine of D31), the geometry type (`.rcs_gtype`), keyed by `.rcs_tmp`, written as Parquet to the staging folder (data and index separately). Between passes: `SELECT DISTINCT h3` into R; for `partition = "h3"` the resolution is chosen with `partition_plan_h3()`'s rule on the distinct cells and a two-column map `h3 → h3_p<res>` is staged and joined in DuckDB. Pass 2 in DuckDB: `ORDER BY h3 NULLS LAST, <key>, ".rcs_tmp"`, `.rcs_id = row_number()`, index rows remapped by a join on `.rcs_tmp`; per output file one aggregation gives the distinct geometry types and the box for an internal variant of `geo_metadata()` that takes types and extent; the files are streamed as for tables; the index table is staged with `stage_index()`'s naming. The D32 warning covers pass 1.
- **D40.** Check and landing: with `check = TRUE`, per staged file the footer row count equals the rows streamed, and `n` sampled rows equal the same rows fetched from the materialised table (matched by key; geospatial by `.rcs_id`; keyless by `.rcs_tmp`). The plan given to `check_staged()` carries the check function for DuckDB input. Landing is the existing path (every location, MD5, catalog last); DuckDB never uploads.

### Other

- **D41.** New options, read through `rcs_option()`, listed in `R/rcs-package.R`: `rcs.print_rows` (10), `rcs.duckdb_batch_rows` (5e5), `rcs.s2_rebuild_tol` (1e-3).
- **D42.** New condition classes: `rcs_error_duckdb`, `rcs_error_prepared`, `rcs_error_sync_conflict`, `rcs_warning_sync_overwrite`, `rcs_warning_gdal_credential`, `rcs_warning_s2_rebuild`, `rcs_warning_h3_double`. Reused: `rcs_error_key`, `rcs_error_backend`, `rcs_error_h3_input`, `rcs_error_argument`. (`rcs_error_conflict` keeps its write-guard meaning.)
- **D43.** `DESCRIPTION` (applied by the orchestrator): `dbplyr` to `Suggests` in wave 0; `pillar` to `Imports` at the wave 2 gate (O1 reports it; earlier it would give a check note); `duckdb`, `DBI`, `gargle`, `httr2`, `terra` stay in `Suggests`, every use guarded by `rlang::check_installed()` or a skip.
- **D44.** Exports: `store_duckdb`, `store_tables`, `store_restore_types`, `store_auth_check`, `rcs_auth_gcs`, `rcs_h3_hex`, `rcs_geo_add`, `rcs_geo_index`, `rcs_geo_strip`. S3 registrations with roxygen `@export` or `@exportS3Method pkg::generic`: the `rcs_h3` methods of D7; `pillar::tbl_sum` and `pillar::tbl_format_footer` for `rcs_preview`; `dplyr::collect` for `rcs_duckdb_tbl`; `print` for `rcs_auth_gcs`. A reference page documents the `rcs_h3` class.
- **D45.** The orchestrator commits and pushes after every wave (explicit paths, no AI attribution, no e-mail address), as in plan 0001.
- **D46.** `dev/prototype/` and the `^dev$` line of `.Rbuildignore` stay until wave 11.

## Contracts between work packages

Fixed here; a package that needs to change one stops and reports.

| Function (internal unless marked) | Signature and result | Made by | Used by |
|---|---|---|---|
| `geo_encode()` | `(x, h3_res = 5L, geocode = TRUE, key = NULL, id_start = <as today>, geocode_engine = "auto", tol = rcs_option("rcs.s2_rebuild_tol"))` → as today plus `order` (input row of each written row), `rebuilt`, `fallback` (input row numbers) | N1a | N1b, R, DW1 |
| `geo_h3_rows()` | `(g, h3_res, geocode_engine = "auto", tol)` → `h3`, `index`, `rebuilt`, `fallback` (row numbers) | N1a | R, DW1 |
| `geo_rebuild()` | `(geog)` → `s2::s2_rebuild(geog)`; a seam for tests | N1a | N1a tests |
| `files_stage()` | gains `geocode_engine = NA_character_` | N1c | N1b, V |
| `h3_classify()` | `(data, entry)` → `data` | O1 | O2, O3, T3 |
| `new_rcs_h3()` | `(x = bit64::integer64())` → `rcs_h3` | O1 | O2, R, T3 |
| `exact_keep()` | `(geometry, shape, exact_engine, geographic)` → logical | N2 | U, T3 |
| `auth_token()` | `(auth)` → token string | P1 | P2, T1 |
| `auth_arrow_fs()` | `(auth)` → `GcsFileSystem` (built through `auth_arrow_fs_create(token, expiration)`) | P1 | P1 |
| `auth_now()`, `auth_http_token(body)`, `auth_tokeninfo(token)`, `gdal_config(option, value)` | seams for tests | P1 (P2 for `gdal_config`) | P1, P2 |
| `auth_duckdb_secret()` | `(auth, con, scope)` → secret name, invisibly | P2 | T1 |
| `duckdb_exec()` | `(con, sql)` → `DBI::dbExecute()`; a seam for tests | P2 | P2, T1 |
| `duckdb_view_name()` | `(dataset)` → `c(schema = , table = )` | T1 | T2, T3, U |
| `duckdb_batches()` | `(con, sql, n)` → an iterator of Arrow record batches that never exceed `n` rows (larger ones are re-sliced) | V1 | V2, DW1, DW2 |
| `write_progress()` | see D37 | V1 | V2, DW1, DW2 |

## Orchestration

### Roles

- **Orchestrator** (the executing session's main agent): runs wave 0 itself (its only package code: options in `R/utils.R` and `R/rcs-package.R`, `tests/testthat/test-utils.R`, `tests/testthat/helper-duckdb.R`, `tests/testthat/test-interop.R`); for each later wave launches implementers, then verifiers, merges, runs the gate, commits. Keeps this plan's status and checkboxes current.
- **Implementer** (`model: "opus"`, `isolation: "worktree"`): one work package, test-first, own worktree and R session.
- **Verifier** (`model: "opus"`, fresh, in the implementer's worktree after it finished): checks every acceptance item without trusting the report; fixes nothing.
- **Fixer**: a new implementer in the same worktree with the verifier's failure list; then a new verifier. At most two fixer rounds per package and one per gate; then stop and report to the owner.

### Budget per agent

Each implementer or verifier run fits within 150,000 to 200,000 tokens:

- It reads `CLAUDE.md`; in this plan "Context", the facts and decisions its package cites, "Contracts", "Orchestration" and its own package; its owned files; functions it calls (by `grep`, not whole files); the named prototype; the named sections of plan 0001.
- Tests run filtered (`devtools::test("<worktree>", filter = "<regex>")`); the whole suite once at the end at `RCS_TEST_LEVEL=default`; GCS only for the named files at `full`.
- Near the budget: stop at a clean point, commit what passes in the worktree, report what is done and left; the orchestrator sends a follow-up with that report.

### Test-driven development

1. **Red.** Write the acceptance tests first, run them, record that they fail for the expected reason. Commit them in the worktree (`tests: <package> acceptance tests (failing)`).
2. **Green.** Implement until they pass; run the package's other filtered tests; fix regressions.
3. **Refactor.** Names and roxygen (`@noRd` for internal functions; examples for exports, below `tempdir()`, guarded by `@examplesIf rlang::is_installed(...)` for `h3o`, `duckdb`/`DBI`/`dbplyr`; DuckDB examples end with `DBI::dbDisconnect(con, shutdown = TRUE)`); rerun.
4. **Suite.** Whole suite at default; report counts.

Snapshot tests cover every new print, summary line and abort; a changed existing snapshot is named in the report with the reason. Data only from `rcs_sim_*()` or the WKT of fact 18; stores in `withr::local_tempdir()`; skips: `skip_if_not_installed()`, `local_duckdb_spatial()` of `helper-duckdb.R` for `spatial`/`httpfs` (it tries `INSTALL`/`LOAD` and skips on failure), `skip_below_level()` (`"default"` for tests above a few seconds, `"full"` for GCS). Process-wide state (GDAL options, options) is restored with `withr::defer()`.

### Rules for every agent (plan 0001, still binding)

- Pass the worktree path: `devtools::load_all("<worktree>")`, `devtools::test("<worktree>", filter = )`. Never `setwd()`, `devtools::document()`, `devtools::install()`; never commit `NAMESPACE`, `man/`, `DESCRIPTION`; list needed changes in the report. New S3 methods are found under `load_all()` before `document()`; the verifier greps the roxygen tag of every method of D44, because a wrong tag shows only at the gate's check.
- Touch only owned files.
- `run-r` lifecycle: own Positron R session, never the user's; `quit(save = "no")` even after a failure; last line of the report `session closed`.
- GCS: `Sys.setenv(RCS_TEST_GCS = "gs://rcs-test", RCS_TEST_LEVEL = "full")` in the agent's own session for the named files only; random prefix, removed afterwards (`rcs:::be_list()` and `rcs:::be_delete()`).
- `R/` files stay ASCII. No benchmarks.

### Reports

Implementer: files and functions built; the red step; test results (filtered and whole suite, counts); deviations with reasons; `DESCRIPTION` changes; snapshots changed; what in this plan proved wrong; `session closed`.

Verifier: one row per acceptance item (item, how checked, pass or fail, evidence); files changed outside ownership (`git diff --stat main...HEAD`); decisions contradicted; acceptance items without a test; roxygen tags of new methods; `session closed`.

### Wave gate

1. Merge the wave's branches into `main`.
2. Apply `DESCRIPTION` changes; `devtools::document()` once.
3. Fresh R session: search `R/` for non-ASCII bytes; `devtools::test()` at default (whole suite); `devtools::check(cran = TRUE)` 0/0/0.
4. Tick the packages, add "Results of wave N" (deviations, facts, test counts), commit with explicit paths, push.
5. Stop and ask the owner only when the gate fails after one fix round, a verifier reports a contradiction with a decision, or an agent reports the plan wrong. Otherwise start the next wave.

## Work packages and order

At most 3 implementers at once; a wave with more packages runs them in the listed order as slots free up. No two packages of a wave own the same file.

### Wave 0, orchestrator

- [x] **Z. Preparation.**
  1. Merge branch `prototype/lazy-duckdb-auth-geo` into `main` (it holds this plan, `.docs/handoffs/0003-plan-0002-execution.md`, `dev/prototype/` and the `.Rbuildignore` line `^dev$`, committed on 2026-11-21) and push `main`.
  2. Options of D41 in `rcs_option()` (`R/utils.R`) and in the options table of `R/rcs-package.R`; update the option list test in `tests/testthat/test-utils.R`. Condition classes of D42 into the documentation of classes in `R/rcs-package.R` if it lists them.
  3. New `tests/testthat/helper-duckdb.R`: `local_duckdb(bigint = "integer64", .env = parent.frame())` (connection closed with `withr::defer()`), and `local_duckdb_spatial(con)` moved from `tests/testthat/test-interop.R` (that file then calls the helper).
  4. `DESCRIPTION`: `dbplyr` in `Suggests` (D43; `pillar` waits for wave 2); install `dbplyr` if missing.
  5. Fresh session: `devtools::document()`, `devtools::test()` at default, `devtools::check(cran = TRUE)`; record counts as the baseline in "Results of wave 0". Check `gs://rcs-test` with default credentials (create a store under a random prefix, delete it).
  6. Commit and push.

#### Results of wave 0

- Branch `prototype/lazy-duckdb-auth-geo` fast-forwarded into `main` and pushed.
- Options `rcs.print_rows`, `rcs.duckdb_batch_rows`, `rcs.s2_rebuild_tol` in `rcs_option()` and the options table; `R/rcs-package.R` lists no condition classes, so none were added. `dbplyr` in `Suggests` (already installed).
- `helper-duckdb.R`: `local_duckdb()`, and `local_duckdb_spatial(con = NULL, frame = parent.frame())` (loads `spatial` into `con`, or into a new `local_duckdb()` connection when `con` is `NULL`); `test-interop.R` uses it, so its connections are now `bigint = "integer64"`.
- Baseline: `devtools::test()` at default: 29 files, 11,118 expectations, 0 failed, 0 errors, 11 skipped, about 16 minutes. `devtools::check(cran = TRUE)`: 0 errors, 0 warnings, 0 notes.
- `gs://rcs-test` with default credentials: store created, table written and read, prefix removed.
- Gate note: the whole suite takes longer than the 600-second limit of one `execute_code` call; gates and agents run it with `callr::r_bg()` and poll.

### Wave 1: N1a, N1c, P1

- [x] **N1a. Geocoding engines: algorithm.** D31, D32 (counts only), D33, D34; facts 17–20. Prototype: none. Plan 0001: "Geospatial encoding", "Results of wave 1" (B).
  - Owns: `R/geo-encode.R`, `tests/testthat/test-geo-encode.R`, new `tests/testthat/test-geo-engine.R`, new `tests/testthat/helper-geo-invalid.R` (the WKT of facts 18 and 20 as functions), `tests/testthat/test-hooks.R` (pinned `geo_encode` signature updated to the contract), `_snaps/geo-encode.md`.
  - Tests first (at `geo_encode()` and `geo_h3_rows()` level):
    a. Both polygons of fact 18 among 20 valid rows: `"auto"` and `"s2"` report them in `rebuilt`; their `h3` equals the cell holding the largest share of the rebuilt polygon computed by brute force on the sphere (`s2::s2_intersection()` with the cell polygons, `s2::s2_area()`); with `"planar"` it equals the planar brute force (cell polygons intersected under `sf_use_s2(FALSE)`, areas in EPSG:6933); shares sum to 1 (±1e-6). Under `sf_use_s2(TRUE)` and `FALSE`.
    b. The long-edge polygon of fact 20: `"s2"` cells equal `geo_cells_touched()`; `"planar"` cells equal the brute-force planar set (candidates from a ring-4 disk, `st_intersects` under `sf_use_s2(FALSE)`), including the cells beyond the first ring.
    c. With `geo_rebuild()` mocked to return an empty geography, and once to return the complement (`s2::s2_difference(s2::as_s2_geography(TRUE), <row>)`), `"auto"` falls back to planar: row in `fallback`, `h3` not `NA`, shares sum to 1.
    d. A chunk with one invalid row: the valid crossing rows of that chunk have the same cells and shares as when geocoded alone (no chunk-level rebuild).
    e. Determinism: two runs give identical `h3`, index and order.
    f. Inside rows: identical `h3` for the three engines.
    g. Antimeridian and pole rows of `rcs_sim_polygons()`: identical cells for the three engines.
    h. Brute-force reference of `helper-geo-reference.R` for a sample of 200 valid simulated rows under `"auto"` (unchanged results).
  - Acceptance: a–h pass; `test-geo-encode.R`, `test-geo-cells.R`, `test-hooks.R` pass; whole suite at default passes; coverage of `R/geo-encode.R` ≥ 80%.

- [x] **N1c. Geocoding engines: catalog column.** D30 (storage), fact 23. Plan 0001: "Catalog schema", handoff decisions 1–5.
  - Owns: `R/schema.R`, `R/catalog.R`, `R/files.R`, `tests/testthat/test-schema.R`, `tests/testthat/test-catalog.R`, `tests/testthat/test-files.R`, their snapshots. `tests/testthat/helper-store.R` stays unchanged (the default `NA` keeps it valid).
  - Steps: `catalog_schema()` gains `geocode_engine` after `h3_res`; `new_entry()` and `files_stage()` gain the argument (default `NA`); `entry_metadata_json()` leaves the key out when `NA`; `schema_as_tibble()` and `schema_validate()` accept catalog files without the column (filled with `NA`).
  - Tests first: (a) a catalog file written with the old schema (column dropped in the test) is read, validated, rewritten with the column; (b) a manifest and file metadata without the key give `NA`; (c) for a table and a geospatial dataset staged with `geocode_engine = NA`, the `rcs` key-value metadata read from the file footer holds no key `geocode_engine` and equals `to_json(row_to_list(entry, kinds))` over the catalog fields other than `entry_not_embedded` and `geocode_engine`; in the red step the implementer records the file MD5 of `rcs_sim_table(200, seed = 1)` staged by the unchanged code and asserts the same MD5 after the change, in the same session (not a literal in the test file); (d) with `geocode_engine = "auto"` the embedded JSON and the manifest hold it; (e) `store_rebuild()` from manifests and from file metadata keeps it; (f) `store_sync()` and `store_copy()` between an old-format location and a new one work (old catalog rewritten with the column).
  - Acceptance: a–f pass; whole suite at default passes.

- [x] **P1. Credentials: object, Arrow and JSON clients.** D21, D22 (all but the DuckDB part), D25; facts 11, 12, 14. Prototype: `dev/prototype/auth.R` (reference only). Plan 0001: "Backends", "Results of wave 1" (A).
  - Owns: new `R/auth.R`, `R/backend-gcs.R`, `R/backend.R`, `R/connect.R`, `R/objects.R` (only if validators need the field), new `tests/testthat/test-auth.R`, `tests/testthat/test-backend-gcs.R`, `tests/testthat/test-backend.R`, `tests/testthat/test-connect.R`, `_snaps/auth.md`, `_snaps/backend-gcs.md`, `_snaps/connect.md`.
  - Tests first:
    a. Offline with the seams mocked: default lookup order (`GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_CONFIG`, platform path, ambient); key types; a file of another type aborts; at most one argument; same source → identical object; renewal five minutes before expiry (`auth_now()` mocked); token source not renewed (print says so); print never contains the token, refresh token or client secret and makes no network call (snapshot; `auth_http_token` mocked to fail if called).
    b. `str()` of a credential and of a connection shows no secret.
    c. `store_connect(auth = )` with object, path, named list; the GCS backend holds it; a local backend has no `auth` field; two connections to one address with different credentials keep separate Arrow file systems (`auth_arrow_fs_create` mocked).
    d. No environment variable changes (`Sys.getenv()` before and after every test of this file).
    e. `gcs_reset_clients()` clears the caches.
    f. At `full` with `RCS_TEST_GCS`: create a store with default credentials, write and read a table; a token expired by setting the cache expiry in the past is renewed and reads continue; `rcs_auth_gcs(token = "invalid")` aborts `rcs_error_backend` with the new hint; existing GCS tests pass; prefix removed.
  - Acceptance: a–f pass; whole suite at default passes; `R/auth.R` coverage ≥ 80% at default.

#### Results of wave 1

- Worktrees: the harness's own worktree isolation refused to start (drive-letter case of the path), so the orchestrator creates one worktree per package with `git worktree add` under `../rcs-wt/<package>` on branch `p2/<package>`, and agents run without isolation in that folder. Same for every later wave.
- All three verifiers: PASS, no decision contradicted, nothing outside ownership.
- N1a (`R/geo-encode.R`): coverage 94.9%. Deviations accepted by the verifier as completions of D31, now binding:
  - "auto" check: a rebuilt copy larger than a hemisphere on the sphere also falls back (needed by test c: the complement has the same planar WKB area as the original, so the area check alone accepts it; a crossing row's box is under 180 degrees, so a faithful rebuild is never larger than a hemisphere).
  - "s2": a rebuild that errors falls back to planar and is reported in `fallback`.
  - Invalid special rows (box >= 180 degrees) are rebuilt on the sphere for every engine and reported in `rebuilt`; no planar fallback.
  - `rebuilt` and `fallback` never overlap.
  - The rebuilt spike of fact 18 stays `s2_is_valid() == FALSE` and is used as is (its s2 area and intersections are correct).
  - Test (d) cannot fail against the old chunk-level rebuild with this data (cells and shares of valid rows do not change); it is a regression guard. Known gap: the special-row rebuild calls `s2::s2_rebuild()` directly, not through the `geo_rebuild()` seam (no test of an invalid special row whose rebuild errors).
- N1c: red-step MD5 of `rcs_sim_table(200, seed = 1)` staged `4657dfb62cc9c2d4b1a56716a1e3ad24` before and after (verifier reproduced it, and identical MD5s and versions for 50 geospatial files). Added: `schema_validate()` rejects engine values other than `NA`, `auto`, `s2`, `planar`. A rebuild from file metadata writes no manifests (existing behaviour), so `expect_store_valid()` is not called after it.
- P1 (`R/auth.R`, coverage 97.8%): the constructor never contacts the network, so test (f) checks `store_connect(uri, auth = rcs_auth_gcs(token = "invalid"))`. `GOOGLE_APPLICATION_CREDENTIALS` naming a missing file aborts `rcs_error_backend`; `CLOUDSDK_CONFIG` set without a file gives ambient (the gcloud folder is not tried). A plain token gets a nominal 3600 s Arrow expiry. The credential id is kept in `cache$id` (P2 uses it to know which credential GDAL holds). Every `be_new("gs://...")` without `auth` runs the default lookup (local files only). Snapshots `_snaps/backend-gcs.md` and `_snaps/connect.md` changed for the D25 hint; the connect snapshot passes `auth = rcs_auth_gcs(token = "some-token")` so it does not depend on the machine.
- Gate: merges clean; `document()` added `export(rcs_auth_gcs)`, `S3method(print, rcs_auth_gcs)`, `man/rcs_auth_gcs.Rd`, `auth` in `store_connect.Rd` and `store_create.Rd`; no non-ASCII in `R/`. Whole suite at default: 31 files, 11,912 expectations, 0 failed, 0 errors, 13 skipped. `devtools::check(cran = TRUE)`: 0/0/0.

### Wave 2: N1b, O1, P2

- [ ] **N1b. Geocoding engines: write wiring.** D30 (argument and update rules), D32. Plan 0001: "Writing".
  - Owns: `R/write.R`, `R/check.R` (`serialization_reference()` passes `entry$geocode_engine`, `NA` → `"s2"`), `tests/testthat/test-write.R`, `_snaps/write.md`.
  - Tests first: (k) `store_check(st, d, x)` passes for keyless `sf` datasets written with each engine; (d) 10,000 valid rows plus the two polygons of fact 18 repeated 25 times each (shifted by whole degrees of longitude inside the simulation box), `partition = "h3"`: every row in exactly one partition, no `NA` `h3` except empty geometries, index shares per row sum to 1 (±1e-6), `store_check()` passes, `rcs_warning_s2_rebuild` names the first five keys; (e) same data twice → same version; (h) `update` rules of D30 (other engine aborts; `NA` entry: new rows per `"s2"`, explicit argument aborts); `geocode = FALSE` stores `NA`; (i) snapshot of the warning; (j) a store read back with `store_read(intersects = <cell of a rebuilt row>)` returns the row. Level `default` for the 10,000-row test.
  - Acceptance: all pass; whole suite at default passes.

- [ ] **O1. H3 cell class.** D7, D9, D10 (macro text only, used by T1), D8 (`h3_classify()` only); facts 15, 16. Prototype: `dev/prototype/h3.R`.
  - Owns: new `R/h3-type.R`, new `tests/testthat/test-h3-type.R`, new `_snaps/h3-type.md`.
  - Tests first: print and format (vector, tibble, `sf`), `"<invalid>"` and `NA`, never aborting on any 64-bit value; `[`, `[[`, `[<-`, `c`, `rep`, `unique`, `sort`, `rev` keep the class; `dplyr::filter()`, `arrange()`, `left_join()` (with `rcs_h3` and with `integer64` keys), `bind_rows()` keep values and give `rcs_h3`; `as.character()` gives decimals equal to `as.character(bit64::as.integer64(x))`; `rcs_h3_hex()` for every input form, the double warning and the abort; `h3_classify()` rules of D8 including a plain table with an `integer64` column named `h3` (not classed).
  - Acceptance: all pass; whole suite at default passes.

- [ ] **P2. Credentials: GDAL, DuckDB secret, check.** D22 (DuckDB part), D23, D24; fact 13. Prototype: `dev/prototype/auth.R`.
  - Owns: `R/auth.R`, `R/backend-gcs.R` (`be_gdal_path()` only), `tests/testthat/test-auth.R` (new blocks), `tests/testthat/test-raster.R` (its GCS block: drop the skip on `GOOGLE_APPLICATION_CREDENTIALS`), `_snaps/auth.md`.
  - Tests first: (a) offline, `gdal_config()` mocked: options per credential type, clearing, silent token update for the same credential, one warning on a switch; (b) `auth_duckdb_secret()` offline with `duckdb_exec()` mocked: statement shape, scope `gs://bucket/prefix`, `TEMPORARY`, and when the mock throws a message holding the token the re-abort does not contain it; the real creation is tested only in (d); (c) `store_auth_check()` on a local store; (d) at `full`: a store on the test bucket with a table and `rcs_sim_raster(nrow = 50, ncol = 50)`: `store_auth_check()` all `ok`; the raster read and a value computed twice; `test-raster.R` GCS block passes without `GOOGLE_APPLICATION_CREDENTIALS`; no environment variable changed; prefix removed.
  - Acceptance: a–d pass; whole suite at default passes.

### Wave 3: S, S2, O2, O3 (three at a time, in this order)

- [ ] **S. Sync in both directions.** D29, D42 (`rcs_error_sync_conflict`, `rcs_warning_sync_overwrite`); fact 22. Plan 0001: "Inspecting and maintaining", "Results of wave 4" (G).
  - Owns: `R/sync.R`, `tests/testthat/test-sync.R`, `_snaps/sync.md`.
  - Tests first (three local locations; `expect_store_valid()` after every step):
    a. Delete on primary, `store_sync(delete = TRUE)` removes the dataset and its index table from both secondaries; without `delete` they stay and show `extra`.
    b. A write on a connection whose primary is the first secondary (offline work), then `store_sync(from = <that location>)` on the original connection reaches the primary and the second secondary; versions equal; counters: only missing files transferred.
    c. Conflict (both changed, target newer): `rcs_error_sync_conflict` naming it, the condition's `result` holds the tibble, other datasets copied; `force = TRUE` copies. Source newer: copied with the warning listing the overwritten version.
    d. `delete = TRUE` with `from = <secondary>`: deletions on the primary only with `force = TRUE`; without it reported as kept.
    e. `dry_run = TRUE`: copies, deletions, conflicts per target; catalog MD5s unchanged; snapshot.
    f. The result columns `kept` and `conflicts`, and the summary lines.
    g. Failures with the stub of `helper-backend-stub.R`: one injected failure per phase of a `from = <secondary>`, `delete = TRUE` sync (copy, deletion, catalog switch): invariants hold; a repeat completes and transfers only what is missing.
    h. At `full`: (a) and (b) with the test bucket as one secondary.
  - Acceptance: a–h pass; existing sync tests pass; whole suite at default passes.

- [ ] **S2. Status against any location.** D29a.
  - Owns: `R/inspect.R`, `tests/testthat/test-inspect.R`, `_snaps/inspect.md`.
  - Tests first: `store_status(from = <secondary>)` compares every other location with it; `newer` is `"source"` or `"target"`; the print names the source (snapshot); the default (`from = NULL`) gives the same table as before this package; the existing expectations on `"primary"`/`"secondary"` in `test-inspect.R` updated where the source changes.
  - Acceptance: all pass; whole suite at default passes.

- [ ] **O2. H3 class in reads and writes.** D8 (read and write), fact 15. Plan 0001: "Types".
  - Owns: `R/query.R` (`rows_finish()` and the collect path only), `R/files.R` (`files_arrow_schema()`, `files_columns_spec()`, `restore_types()`), `R/read.R` (`store_h3_hex()` accepts `rcs_h3`), and the existing test files whose expectations change because cells come back as `rcs_h3`: `test-read.R`, `test-query.R`, `test-intersects.R`, `test-integration.R`, `test-check.R`, `test-files.R`, `test-random-operations.R`, `test-interop.R`, `test-write.R`, with their snapshots. Expectations are adjusted (compare `bit64::as.integer64()` values, or expect class `rcs_h3`), never weakened.
  - Tests first (new blocks in `test-read.R`/`test-files.R`): geospatial `collect()` gives `rcs_h3` for `h3` and `h3_p<r>`; index tables for `h3` and `h3_main`; a fixture written before this plan too; a plain table with an `integer64` column `h3` stays `integer64`; a user `rcs_h3` column written as `rcs_h3` and as `integer64` gives identical paths, MD5s and version (also as partition column), and reads back as `rcs_h3` / `integer64` respectively; the serialization check passes.
  - Acceptance: all pass; the whole suite at default passes with no expectation removed (verifier compares expectation counts with the wave 2 gate).

- [ ] **O3. Restoring types.** D4, D5. Plan 0001: "Types".
  - Owns: new `R/types.R`, new `tests/testthat/test-types.R`, new `_snaps/types.md`.
  - Tests first: `store_restore_types()` on data read with `arrow::read_parquet()` from the dataset's files (storage types) restores factor (with unused levels), ordered, difftime (hours), `integer64` (small values that Arrow returns as integer), list; values outside the levels warn with the count; incompatible types unchanged; doubles above 2^53 not converted (warning); class of `x` kept for tibble, data frame, `sf`; H3 per `h3_classify()`; unknown dataset aborts `rcs_error_dataset_not_found`.
  - Acceptance: all pass; whole suite at default passes.

### Wave 4: Q, R, N2

- [ ] **Q. Lazy-first printing.** D1, D2. Prototype: `dev/prototype/print.R`.
  - Owns: `R/query.R` (`print.rcs_query()` and helpers only), new `R/preview.R`, `tests/testthat/test-query.R` (print blocks), `_snaps/query.md`.
  - Tests first (snapshots use one kept file or an `arrange()` so that rows are deterministic): unfiltered table (known rows, `n more rows`); filtered (`??`, `Filter:`, `(pruned)`); after `head(5)` (`??`); geospatial (geometry column, `rcs_h3` cells in hex); spatial filter (`Spatial:`, `Filter:   (with spatial predicate)`, footer `more rows may exist`); zero rows; geometry dropped; read from a secondary (`Location: secondary 1 (local)`); `n = 3` and `options(rcs.print_rows = 3)`; a long filter truncated; work counters: printing a filtered query on a partitioned dataset opens only the kept files; `print()` returns `x` invisibly.
  - Acceptance: all pass; whole suite at default passes.

- [ ] **R. Geospatial verbs and prepared writes.** D26, D27; fact 21. Prototype: `dev/prototype/geo.R`.
  - Owns: new `R/geo-verbs.R`, `R/write.R` (geospatial branch of staging), `R/files.R` (partition-column handling of D27), new `tests/testthat/test-geo-verbs.R`, `tests/testthat/test-write.R` (prepared-data blocks), `tests/testthat/test-files.R` (partition blocks), snapshots.
  - Tests first: (a) `rcs_geo_add()` columns, position, order, values against `geo_encode()` mapped through `order`, `h3_parent()`, `geo_bbox_df()`; `replace`; `h3_res = NULL`; parents not below `h3_res` abort; (b) `rcs_geo_index()` against `geo_encode()$index` mapped to `id`; `crossing_only = FALSE`; (c) `rcs_geo_strip(rcs_geo_add(raw))` identical to `raw`; an `sf` whose active geometry column is `geom` keeps it; (d) D26 round trip for points, lines, polygons with a key, with and without `parents`, `partition = "h3"` and `NULL`; (e) prepared writes: equal accepted, tampered `h3` / `bbox` abort naming rows, an engine mismatch aborts and names the write's engine, `h3_res` taken from the cells, mixed resolutions abort, `geocode = FALSE` with `h3` aborts, `update` same handling, `h3_p<r>` stored and read as `rcs_h3`, partition column equal → used, different → abort; raw and prepared writes give the same version; (f) snapshots of the aborts.
  - Acceptance: a–f pass; whole suite at default passes.

- [ ] **N2. Geocoding engines: read side.** D34, D35; owner decision 2. Plan 0001: "Reading", "Results of wave 3" (F), "Results of wave 5" (M), "Results of wave 6".
  - Owns: `R/intersects.R`, `R/read.R`, `tests/testthat/test-intersects.R`, `tests/testthat/test-read.R`, `tests/testthat/test-integration.R` (only expectations that change with the engine), `_snaps/intersects.md`, `_snaps/read.md`.
  - Steps: `exact_engine` argument; `exact_keep()`; per-row choice for `"auto"`; `check_query_valid()` by engine; the spatial property test passes `exact_engine = "session"` so its comparison with `sf::st_filter()` under each `sf_use_s2()` setting keeps its meaning.
  - Tests first: (a) a dataset written with `"planar"` containing the long-edge polygon: the exact test is planar with `sf_use_s2(TRUE)` in the session; (b) written with `"s2"`: on the sphere with `sf_use_s2(FALSE)`; (c) `"auto"` with the polygons of fact 18: tested in the plane, valid rows on the sphere, no s2 error; (d) a dataset written before this plan (engine `NA`): session rule; (e) explicit overrides; (f) for a dataset written with `"auto"` and read with `exact_engine = "planar"`, `store_read(intersects = <bbox | sf | cells>)` returns for the invalid rows the same set as a planar `sf::st_intersects()` on the full data; (g) projected data: planar in the data CRS; (h) `check_query_valid()` per engine and the advice in the abort.
  - Acceptance: a–h pass; the spatial property test passes at default; whole suite at default passes.

### Wave 5: T1, V1

- [ ] **T1. DuckDB views (in memory) and `store_tables()`.** D10–D15, D19, D12 guards, D22 (secrets via P2); facts 1, 4, 5, 7–10. Prototype: `dev/prototype/duckdb.R`.
  - Owns: new `R/duckdb.R`, new `tests/testthat/test-duckdb.R`, new `_snaps/duckdb.md`.
  - Tests first (skip without `duckdb`, `DBI`; `local_duckdb()`): (a) `store_duckdb(st)` on a local store with a table, a table partitioned by `year`, a geospatial dataset partitioned by `"h3"` with an empty geometry (an `h3_p<r>=null` partition) and its index table: views with D12 names in both modes; `duckdb_views()` lists them and `duckdb_tables()` holds none of them; `rcs.views`, `rcs.store` contents; (b) column types of each native view equal the Arrow schema of the dataset for every column except `geometry` (`h3_p<r>` `BIGINT`); counts and an integer sum per view equal `store_open() |> collect()`; BIGINT returns `integer64`; `rcs_h3_hex(h3)` in SQL equals `rcs_h3_hex()` in R; (c) `datasets =` upserts only those rows and drops nothing; `datasets = NULL` drops views of deleted datasets; a second store on the same connection aborts; (d) guards of D12 (collisions, `rcs`, schema equal to a database name) and D11 (`con` without `bigint = "integer64"`); (e) `store_tables()` for a store, a prepared connection (views and a user table), with `st` (`current`), a plain DuckDB connection, and an invalid input; (f) native mode on the test bucket at `full` (secret from `auth_duckdb_secret()`, `local_duckdb_spatial()`-style skip for `httpfs`) and arrow mode: counts of (b); no environment variable changed; (g) `spatial = TRUE` (skip via `local_duckdb_spatial()`): `geom` in arrow mode.
  - Acceptance: a–g pass; whole suite at default passes.

- [ ] **V1. Writing from DuckDB, tables: writer.** D36–D38, D40; fact 24. Prototype: none.
  - Owns: new `R/write-duckdb.R`, `R/write.R` (`write_kind()`, the dispatch, the `check_staged()` branch for DuckDB input), `R/files.R` (the shared internal of D38 extracted from `files_stage()`), new `tests/testthat/test-write-duckdb.R`, new `_snaps/write-duckdb.md`.
  - Builds `duckdb_batches()` and `write_progress()` (contracts), the materialised table, the key and partition checks, the streaming writer for one file and for partitions, the landing.
  - Tests first (skip without `duckdb`, `DBI`, `dbplyr`): b, c, g below.
  - Acceptance: b, c, g pass; whole suite at default passes.

- [ ] **V2. Writing from DuckDB, tables: limits, types, check.** D36–D38, D40 (wave 6, after V1).
  - Owns: `R/write-duckdb.R`, `R/write.R` (the DuckDB branch only), `tests/testthat/test-write-duckdb.R`, `_snaps/write-duckdb.md`.
  - Tests first (level `default` for the large table): a, d, e, f below.
  - Acceptance: a, d, e, f pass; whole suite at default passes.

  Tests of V1 and V2:
    a. A DuckDB table of 1.2e6 rows built from `range()` (integer, double, varchar, date, boolean, bigint, timestamp) written with `options(rcs.duckdb_batch_rows = 2e5)`: a spy wrapping the real `duckdb_batches()` (`local_mocked_bindings()` with a function that calls the original and records `nrow()` of each batch) shows that every batch has at most 2e5 rows, that there are at least `ceiling(1.2e6 / 2e5)` batches per pass, and that no call fetches the whole table; the stored dataset equals the table collected afterwards (ordered by key).
    b. One file and `partition =`, with key; `max_files` exceeded aborts; duplicate keys abort `rcs_error_key` naming the first duplicates, nothing staged; a keyless table written twice gives the same version.
    c. For integer, double, varchar, date and boolean columns: files, catalog rows, manifest and version identical to `store_write()` of the same data collected (same MD5s). If byte identity cannot be reached, the criterion becomes equal rows and an equal entry except `version`, reported as a deviation.
    d. Type mapping of D38 (BIGINT `r_type`, TIMESTAMP, TIMESTAMPTZ, an unsupported type aborts naming the column); `mode = "update"` aborts; a lazy table on a non-DuckDB connection aborts (dbplyr's `memdb` is not available without RSQLite: build the object with `dbplyr::lazy_frame()` and assert the abort); package columns in `x` dropped with the message.
    e. Progress through mocked `write_progress()`: created and updated per batch; not created under `rcs.quiet`.
    f. `check = TRUE` detects an altered staged file (writer mocked to change one value).
    g. Landing in a local primary and a local secondary with MD5 verification; the temporary DuckDB table is gone afterwards, also after an error.

### Wave 6: V2, T2, T3

- [ ] **T2. DuckDB file database and reopening.** D16, D17; facts 5, 6. Prototype: `dev/prototype/duckdb.R`.
  - Owns: `R/duckdb.R`, new `tests/testthat/test-duckdb-file.R`.
  - Tests first: (a) `path`: views and a user table survive closing and reopening with `DBI::dbConnect()` (native); (b) after a new write and a deletion in the store, `store_duckdb(st, path)` adds and drops views, updates `rcs.views`, keeps the user table; (c) `store_duckdb(path = )` without `st` reconnects through `rcs.store`; a file without it aborts; (d) `path` inside a local location aborts; a file stem equal to a used schema aborts; a table or unlisted view with a view's name aborts naming it; (e) arrow mode with `path` informs about refreshing; (f) the local-first workflow: a local store with `auth_token()` and `auth_arrow_fs()` mocked to fail; `store_duckdb()` with a file; an aggregation and a join on `h3` into user tables; a result written back with `store_write()` (from `collect()`); the file reopened; zero calls to the mocked functions; (g) the database file stays under 1 MB after views on a 1e5-row dataset.
  - Acceptance: a–g pass; whole suite at default passes.

- [ ] **T3. DuckDB tables from `store_open()`.** D18, D20, D3; facts 2, 3. Prototype: `dev/prototype/duckdb.R`.
  - Owns: new `R/duckdb-tbl.R`, `R/query.R` (`store_open()` signature and dispatch only), new `tests/testthat/test-duckdb-tbl.R`.
  - Tests first: lazy result; dbplyr verbs keep the `rcs` field; `collect()` restores factor, ordered, difftime, `integer64`, `rcs_h3` and gives `sf` with the catalog CRS from both `BLOB` and `GEOMETRY` columns; `.rcs_id` and `geom` dropped; equals `store_open() |> collect()` for the same dataset (ordered by key); `version =` aborts; the package-level connection is reused per store and closed by `store_duckdb_close()`; a user `con` without `bigint = "integer64"` aborts.
  - Acceptance: all pass; whole suite at default passes.

### Wave 7: DW1, U

- [ ] **DW1. Writing from DuckDB, geospatial, one file.** D39, D31/D32 in batches. Prototype: none.
  - Owns: `R/write-duckdb.R` (geospatial part), `R/geo-encode.R` only for the variant of `geo_metadata()` taking types and extent, new `tests/testthat/test-write-duckdb-geo.R`.
  - Tests first: `rcs_sim_polygons(5000)` and `rcs_sim_points(5000)` loaded into DuckDB as WKB, written with `crs = 4326` in batches of 1,000: data, index table, `geo` metadata and catalog equal those of `store_write()` of the same `sf` (same `h3`, index rows, `.rcs_id` order, same version); the test input holds only integer, double and character attributes; if byte identity cannot be reached, the criterion becomes equal rows and an equal entry except `version`, reported as a deviation; missing `crs` aborts; the polygons of fact 18 warn per D32 with their keys; a spy on `duckdb_batches()` shows batches of at most 1,000 rows.
  - Acceptance: all pass; whole suite at default passes.

- [ ] **U. DuckDB spatial filter.** D28, D35 (through `exact_keep()`). Prototype: `dev/prototype/duckdb-intersects.R`.
  - Owns: new `R/duckdb-intersects.R`, `R/intersects.R` (dispatch at the top of `store_intersects()` only), `R/duckdb-tbl.R` (pending exact test in `collect.rcs_duckdb_tbl()` only), new `tests/testthat/test-duckdb-intersects.R`.
  - Tests first: polygons (2,000) and points (20,000, `partition = "h3"`); queries: 3 H3 cells, a thin diagonal strip (forces cells and index), a polygon with a hole, a bbox, an antimeridian query on the special rows; both modes: `exact = TRUE` returns exactly the rows of the Arrow `store_intersects()`; `exact = FALSE` the same candidate count; `exact = "sql"` (skip via `local_duckdb_spatial()`) the rows of the Arrow path with `exact_engine = "planar"` for every query except the antimeridian one; the SQL holds the index subquery only when `spatial_use_cells()` is `TRUE`; above 10,000 cells a temporary table is used; several calls combine; a table without `bbox` aborts; an aggregate after a pending exact test informs about the candidate set; round trip: for a dataset written by `store_write()` from `sf`, `store_open(engine = "duckdb") |> store_intersects(cells) |> collect()` equals the Arrow read.
  - Acceptance: all pass; whole suite at default passes.

### Wave 8: DW2

- [ ] **DW2. Writing from DuckDB, geospatial, partitions and engines.** D39 (partition map), D30. Prototype: none.
  - Owns: `R/write-duckdb.R`, `tests/testthat/test-write-duckdb-geo.R`, `_snaps/write-duckdb.md`.
  - Tests first: `partition = "h3"` (resolution as `store_write()` chooses; files and version equal to the R path, with V1's fallback criterion; integer, double and character attributes only); `geocode = FALSE`; `geocode_engine = "planar"` stored; input as `GEOMETRY` (skip via `local_duckdb_spatial()`); a dataset written from DuckDB read back with `store_read(intersects = cells)` equals the same read of the dataset written from `sf`.
  - Acceptance: all pass; whole suite at default passes.

### Wave 9: X1

- [ ] **X1. Documentation: README, getting started, DuckDB.** D1, D11–D20, D28, D36–D40, D44. Prototype: `dev/prototype/demo.R`.
  - Owns: `README.Rmd`, `README.md`, `vignettes/rcs.Rmd`, new `vignettes/duckdb.Rmd`, roxygen of `store_duckdb()`, `store_tables()`, `store_open()`, and the whole help of `store_write()` (DuckDB input and geocoding engines sections), `_pkgdown.yml` (articles: `duckdb`).
  - Content: `rcs.Rmd` leads with `store_open()` and its print; `duckdb.Rmd`: views, file database, `store_tables()`, reopening and its limits, spatial filter in DuckDB, writing from DuckDB, the local-first workflow (local store, DuckDB, write back, sync to a bucket later), credentials and the hourly refresh. Chunks needing `duckdb`/`dbplyr` carry `eval = requireNamespace(...)`; chunks needing `spatial`, `httpfs` or GCS are `eval = FALSE`; connections are closed.
  - Acceptance: `devtools::build_vignettes()` succeeds; check 0/0/0; a verifier reads the texts against the decisions (no contradiction).

### Wave 10: X2

- [ ] **X2. Documentation: locations, geospatial, site index.** D21–D27, D29–D35, D44.
  - Owns: `vignettes/locations.Rmd`, `vignettes/geospatial.Rmd`, `vignettes/articles/testing.Rmd` (new test files and helpers), `_pkgdown.yml` (reference index for every export, the `rcs_h3` page, `print.rcs_auth_gcs`), roxygen of `rcs_auth_gcs()`, `store_auth_check()`, `store_sync()`, `store_status()`, `store_restore_types()`, `rcs_h3_hex()`, `rcs_geo_*()`.
  - Content: credentials (`auth =`, sources, renewal, GDAL being process-wide, `store_auth_check()`); sync in both directions, deletion and conflicts; H3 class and `rcs_h3_hex()`; the verbs and the round trip; prepared writes; geocoding engines and `exact_engine`.
  - Acceptance: `devtools::build_vignettes()` succeeds; `pkgdown::check_pkgdown()` passes; check 0/0/0; verifier reading as in X1.

### Wave 11: Y1 and Y2 in parallel, then Y3

- [ ] **Y1. Check and full suite.** Fresh session: `devtools::document()` (no change), `devtools::check(cran = TRUE)` 0/0/0, the whole suite at `RCS_TEST_LEVEL=full` with `RCS_TEST_GCS=gs://rcs-test`, file by file (plan 0001, wave 6). Reports pass or fail per file.
- [ ] **Y2. Coverage and neutrality.** Coverage as in plan 0001 wave 6 (`type = "none"` with `testthat::test_dir()` on the installed package): ≥ 90% overall, ≥ 80% per file. Neutrality scan (owner decision 6): a separate subagent first writes search patterns from the neutrality rule (plan 0001, "Context"): names of real countries, regions, cities, seas named after places where they could identify a place, organisations and people; e-mail addresses other than the author's in `DESCRIPTION`; user names and home paths; machine names; tokens, keys and secrets (`ya29.`, `-----BEGIN`, `client_secret`, `refresh_token` values). It runs them (case-insensitive, word boundaries) over every tracked file, file names, `bench/results/` contents and the content and messages of all commits (`git log -p --all`), reviews each hit, and reports hits with file and line. The patterns are kept only in its session, never committed. A hit that is not a false positive fails Y2.
- [ ] **Y3. End to end and cleanup** (after Y1 and Y2 pass).
  1. Delete `dev/prototype/` and, if `dev/` is then empty, the `^dev$` line of `.Rbuildignore`.
  2. On the test bucket through public functions only: `store_auth_check()`; writes of a table, polygons and a raster; `store_open()` print; DuckDB views in both modes and the spatial filter; DuckDB writes of a table and of polygons; `rcs_geo_add()` round trip; a sync from a local secondary with `delete = TRUE`; prefix removed.
  3. Rebuild the pkgdown site into `docs/` with the existing local build script (it renders stored results only). If it would run a `bench/` file, stop and report.
  4. Fill "Outcome" (including that `bench/` was not re-validated), set the status to done, commit and push.

## Outcome

Filled in when the status becomes done or superseded.
