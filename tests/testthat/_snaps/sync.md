# store_sync() checks its arguments

    Code
      store_sync(st, datasets = 1)
    Condition
      Error in `store_sync()`:
      ! `datasets` must be `NULL` or a character vector of dataset names, not a number.
    Code
      store_sync(st, datasets = "nothing")
    Condition
      Error in `store_sync()`:
      ! No dataset "nothing" in the store.
      i The store holds no datasets.
    Code
      store_sync(st, to = paths[[1]])
    Condition
      Error in `store_sync()`:
      ! `to` names the primary location '<root>/primary'.
      i `store_sync()` copies from the primary to secondary locations; use `store_copy()` to copy into the primary.
    Code
      store_sync(st, to = "elsewhere")
    Condition
      Error in `store_sync()`:
      ! `to` must be the address of a location of this connection, not "elsewhere".
      i Its locations: '<root>/primary' and '<root>/secondary1'.
    Code
      store_sync(st, dry_run = NA)
    Condition
      Error in `store_sync()`:
      ! `dry_run` must be `TRUE` or `FALSE`, not `NA`.
    Code
      store_sync(list())
    Condition
      Error in `store_sync()`:
      ! `st` must be a store connection made by `store_connect()`.
      x It is an empty list.

# store_sync() copies missing and differing datasets; a dry run changes nothing

    Code
      dry <- store_sync(st, dry_run = TRUE)
    Message
      i Dry run: nothing is changed.
      i Syncing 2 datasets from the primary '<root>/primary' to 2 secondary locations.
      v secondary  <root>/secondary1  up to date
      * secondary  <root>/secondary2  would copy 2 datasets, 3 files (<bytes>): "sales/daily", "sales/summary"

---

    Code
      out <- store_sync(st)
    Message
      i Syncing 2 datasets from the primary '<root>/primary' to 2 secondary locations.
      v secondary  <root>/secondary1  up to date
      v secondary  <root>/secondary2  2 datasets, 3/3 files sent  <bytes>  <time>
      v MD5 identical for 3 files sent to 1 location. Catalogs updated.

---

    Code
      again <- store_sync(st)
    Message
      i Syncing 2 datasets from the primary '<root>/primary' to 2 secondary locations.
      v secondary  <root>/secondary1  up to date
      v secondary  <root>/secondary2  up to date
      v Every secondary location is up to date.

# a secondary failing during store_sync() warns, is reported behind, and the next call completes it

    Code
      out <- store_sync(st)
    Message
      i Syncing 1 dataset from the primary '<root>/primary' to 2 secondary locations.
    Condition
      Warning:
      Syncing the secondary location '<root>/secondary1' failed; it is behind.
      i Run `store_sync()` again: files already sent are reused.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call <n> (be_put).
    Message
      x secondary  <root>/secondary1  behind: Injected failure at backend call <n> (be_put).
      v secondary  <root>/secondary2  1 dataset, 2/2 files sent  <bytes>  <time>
      v MD5 identical for 2 files sent to 1 location. Catalogs updated.
      ! 1 secondary location is behind; run `store_sync()` again once it can be reached.

# store_copy() checks its arguments

    Code
      store_copy(st, "sales", from = paths[[1]], to = paths[[1]])
    Condition
      Error in `store_copy()`:
      ! `from` and `to` name the same location '<root>/primary'.
    Code
      store_copy(st, "sales", from = "elsewhere", to = paths[[2]])
    Condition
      Error in `store_copy()`:
      ! `from` must be the address of a location of this connection, not "elsewhere".
      i Its locations: '<root>/primary' and '<root>/secondary1'.
    Code
      store_copy(st, "sales", from = paths[[1]], to = paths[[2]])
    Condition
      Error in `store_copy()`:
      ! No dataset "sales" in '<root>/primary'.
    Code
      store_copy(st, 1, from = paths[[1]], to = paths[[2]])
    Condition
      Error in `store_copy()`:
      ! `dataset` must be a single non-empty string, not a number.

# store_copy() copies between any two locations, into the primary too

    Code
      out <- store_copy(st, "daily", from = paths[[2]], to = paths[[3]])
    Message
      i Copying "sales/daily" (version <version>, 2 files) from '<root>/secondary1' to '<root>/secondary2'.
      v 2/2 files sent (<bytes>) in <time>, MD5 verified. Catalogs of '<root>/secondary2' updated.

---

    Code
      same <- store_copy(st, "sales/daily", from = paths[[2]], to = paths[[3]])
    Message
      i Copying "sales/daily" (version <version>, 2 files) from '<root>/secondary1' to '<root>/secondary2'.
      v '<root>/secondary2' already holds this version of "sales/daily".

# store_copy() of a dataset only a secondary holds, and a failing copy changes nothing

    Code
      store_copy(st, "here", from = paths[[2]], to = paths[[1]])
    Message
      i Copying "only/here" (version <version>, 2 files) from '<root>/secondary1' to '<root>/primary'.
    Condition
      Error in `store_copy()`:
      ! Copying "only/here" to '<root>/primary' failed.
      i No catalog of '<root>/primary' was changed. Run the call again: files already sent are reused.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call <n> (be_put).

# store_delete() needs the full name in confirm

    Code
      store_delete(st, "daily")
    Condition
      Error in `store_delete()`:
      ! `confirm` must repeat the full name of the dataset to delete.
      i To delete "sales/daily", call `store_delete(st, "sales/daily", confirm = "sales/daily")`.
    Code
      store_delete(st, "daily", confirm = "daily")
    Condition
      Error in `store_delete()`:
      ! `confirm` must repeat the full name of the dataset to delete.
      i To delete "sales/daily", call `store_delete(st, "sales/daily", confirm = "sales/daily")`.
    Code
      store_delete(st, "sales/daily", confirm = "sales/daily", history = "yes")
    Condition
      Error in `store_delete()`:
      ! `history` must be `TRUE` or `FALSE`, not a string.
    Code
      store_delete(st, "sales/daily__h3", confirm = "sales/daily__h3")
    Condition
      Error in `store_delete()`:
      ! "sales/daily__h3" is an index table; it is deleted with its dataset.
      i Delete "sales/daily" instead.
    Code
      store_delete(st, "Bad Name", confirm = "Bad Name")
    Condition
      Error in `store_delete()`:
      ! `dataset` is not a valid dataset name: "Bad Name".
      x Use lower-case letters, digits and `_`, with `/` between folders.

# store_delete() removes the entry everywhere first, then the files

    Code
      out <- store_delete(st, "polygons", confirm = "shapes/polygons")
    Message
      i Deleting "shapes/polygons" and its index table from every location, keeping its history.
      v primary    <root>/primary     4 files deleted  <bytes>
      v secondary  <root>/secondary1  4 files deleted  <bytes>
      v secondary  <root>/secondary2  4 files deleted  <bytes>
      v "shapes/polygons" is removed from 3 locations.

---

    Code
      none <- store_delete(st, "shapes/polygons", confirm = "shapes/polygons")
    Message
      i No location lists "shapes/polygons"; nothing to delete.

# a secondary failing during store_delete() warns; the next call completes it

    Code
      out <- store_delete(st, "sales/daily", confirm = "sales/daily")
    Message
      i Deleting "sales/daily" and its index table from every location, keeping its history.
    Condition
      Warning:
      Deleting "sales/daily" from the secondary location '<root>/secondary2' failed; it still lists it.
      i Run `store_delete()` again.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call <n> (be_lock).
    Message
      v primary    <root>/primary     3 files deleted  <bytes>
      v secondary  <root>/secondary1  3 files deleted  <bytes>
      x secondary  <root>/secondary2  behind: Injected failure at backend call <n> (be_lock).
      v "sales/daily" is removed from 2 locations.
      ! 1 secondary location could not be checked or changed; run `store_delete()` again once it can be reached.

# store_rebuild() restores lost catalogs and keeps the history

    Code
      out <- store_rebuild(st, paths[[2]])
    Message
      v Rebuilt the catalogs of '<root>/secondary1': 2 datasets in 5 files, 1 earlier version.

# store_rebuild() reports what it skips and replaces a damaged catalog

    Code
      out <- store_rebuild(st, paths[[1]])
    Message
      v Rebuilt the catalogs of '<root>/primary': 1 dataset in 2 files, 0 earlier versions.
      ! Skipped 2 items:
      x "sales/summary": Every manifest names missing files. (sales/summary/_manifest-<version>.json)
      x Parquet files without rcs metadata. (stray/part-<version>.parquet)

# store_rebuild() checks its location and takes the write guard

    Code
      store_rebuild(st, "elsewhere")
    Condition
      Error in `store_rebuild()`:
      ! `location` must be the address of a location of this connection, not "elsewhere".
      i Its locations: '<root>/primary'.

