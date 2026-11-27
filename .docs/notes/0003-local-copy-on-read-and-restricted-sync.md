# Copy on read to secondary locations, and sync restricted to datasets they already hold

- **Date:** 2026-11-26
- **Author:** Eduard Bukin
- **Summary:** `store_read()` copies a dataset of up to 2 GB to the secondary locations before reading it; lazy reads, samples and glimpses stay remote; a plain sync to a secondary refreshes only what it already holds and says what a full sync would add.

## Instruction (verbatim)

> I propose we roll out this behavior into a more restricted form, so that by default we only sync what has been used already. Two aspects. One: the user provides local and remote storage, local is empty, and the data is in remote. The user wants to read data from certain files from the remote storage. Once it is read from the remote for analysis, it is automatically stored in a local version, and the user is informed about it. I think that we need to caution against syncing the entire storage by default. How to do that?
>
> Do you propose to have a local cache, on top of the local version? I want to avoid it. I want to cache only if the local place is provided.
>
> Streaming the data should be from remote if there is no local copy; reading should sync the data by default, with progress.
>
> `store_sync()` should message the user that only datasets in the location are synced, and inform them to pass the argument to sync all if needed, telling the size of the full sync. Is it possible to use sample and glimpse without a full download?
>
> They should keep avoiding a full download. Read should have a data size threshold for downloading: if it is above 2 GB, it does not load this data.
>
> Any secondary. Old version does not copy anything unless it is specified explicitly. Propose a parameter and a message that old versions are not copied. I agree with the rest of the points.

## Note

Decisions:

- **No separate cache.** Copies go only to the secondary locations the user passes to `store_connect(secondary = )`, any of them, local or cloud. With no secondary, reads go to the primary as today and nothing is written elsewhere.
- **`store_read()`, current version.** When a secondary lacks the dataset or holds an older version, the read first copies the whole dataset there with the existing copy code (only missing files, MD5-verified, catalog switched last), shows a progress bar, informs the user, then reads from the copy. On by default; `store_connect(copy_on_read = FALSE)` turns it off for the connection.
- **Size threshold: 2 GB.** When the bytes to download exceed `getOption("rcs.copy_on_read_max_bytes")` (default 2 GB), the read does not copy. It reads only what it needs from the primary and informs the user of the size and how to copy (`store_read(copy = TRUE)` or `store_sync(st, datasets = "<name>")`). Filters do not change this rule.
- **`store_read()`, old version (`version =`).** Never copied by default. The read comes from wherever the version is held and informs, for example:
  `ℹ Read version 3f9a… of "sales/daily" from <primary>; old versions are not copied to <secondary>. Use `copy = TRUE` to copy it.`
  A copied old version is recorded in the secondary's history, not as its current version.
- **New argument `store_read(copy = NULL)`.** `NULL` follows the rules above (connection setting, 2 GB limit, no old versions). `TRUE` copies regardless of size or version. `FALSE` never copies.
- **Lazy or streamed reads** (`store_open()`, `store_duckdb()`), **`store_sample()`** (a few random row groups) and **`store_glimpse()`** (the first row group of one file) never copy. They read from the primary when no secondary holds a current copy.
- **`store_sync()` to secondaries**, without `datasets`, refreshes only the datasets each one already holds. It informs that only those were synced, how many datasets and how much data (files, bytes) a full sync would add, and that `all = TRUE` syncs everything. A separate `all` argument, not `datasets = "all"`, so that a dataset named `all` stays addressable. A sync to the primary (`from = <secondary>`) still sends everything, so offline work reaches the primary.
- **Unavailable secondary:** nothing is copied there; the read goes on from the primary.
