# the integrity check passes on a valid store and downloads no data file

    Code
      out <- store_check(st, "sales/daily")
    Message
      v 2 files checked in 2 locations: no problem found.

# an altered data file is named

    Code
      store_check(fx$st, "daily")
    Condition
      Error in `store_check()`:
      ! `store_check()` found 1 problem.
      x sales/daily/year=2023/part-<version>.parquet: its MD5 <md5> differs from the catalog's <md5>; it is not a readable Parquet file [<root>]

# a missing data file is named

    Code
      store_check(fx$st, "sales/daily")
    Condition
      Error in `store_check()`:
      ! `store_check()` found 1 problem.
      x sales/daily/year=2023/part-<version>.parquet: the file is missing [<root>]

# a wrong MD5 in _files.parquet is named

    Code
      store_check(fx$st, "summary")
    Condition
      Error in `store_check()`:
      ! `store_check()` found 3 problems.
      x sales/summary/part-<version>.parquet: its MD5 <md5> differs from the catalog's <md5> [<root>]
      x _files.parquet: the version of sales/summary is not the hash of its file rows [<root>]
      x sales/summary/_manifest-<version>.json: the manifest differs from the catalog [<root>]

# a manifest that disagrees with the catalog is named

    Code
      store_check(fx$st, "summary")
    Condition
      Error in `store_check()`:
      ! `store_check()` found 1 problem.
      x sales/summary/_manifest-<version>.json: the manifest differs from the catalog [<root>]

# a truncated _catalog.parquet is named

    Code
      store_check(fx$st, "summary")
    Condition
      Error in `store_check()`:
      ! `store_check()` found 1 problem.
      x _catalog.parquet: the catalogs cannot be read: '_catalog.parquet' of '<root>/secondary1' is not a readable Parquet file. [<root>/secondary1]

# locations are chosen by address; a location without the dataset is reported

    Code
      store_check(fx$st, "summary", locations = file.path(dirname(fx$primary), "elsewhere"))
    Condition
      Error in `store_check()`:
      ! '<root>/elsewhere' is not an available location of this connection.
    Code
      store_check(fx$st, "summary", n = 0)
    Condition
      Error in `store_check()`:
      ! `n` must be a positive whole number.
    Code
      store_check(fx$st, "nothing")
    Condition
      Error in `store_check()`:
      ! No dataset "nothing" in the store.

# the serialization check compares sampled rows with x

    Code
      out <- store_check(s$st, "sales/daily", x = s$x)
    Message
      v 2 files checked in 2 locations: no problem found.

---

    Code
      store_check(s$st, "sales/daily", x = altered)
    Condition
      Error in `store_check()`:
      ! `store_check()` found 4 problems.
      x sales/daily/year=2023/part-<version>.parquet: columns qty, note differ from x [<root>/primary]
      x sales/daily/year=2024/part-<version>.parquet: columns qty, note differ from x [<root>/primary]
      x sales/daily/year=2023/part-<version>.parquet: columns qty, note differ from x [<root>/secondary1]
      x sales/daily/year=2024/part-<version>.parquet: columns qty, note differ from x [<root>/secondary1]

# store_write(check = TRUE) aborts before uploading when a staged file differs

    Code
      store_write(s$st, s$x, "sales/copy", title = "Copy", description = "d", key = c("shop_id", "date", "product"))
    Condition
      Error in `store_write()`:
      ! The serialization check of the staged files failed; nothing was uploaded.
      x sales/copy/part-<version>.parquet: column qty differs from x

