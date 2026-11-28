# store_read() copies a dataset to an empty local secondary of a cloud primary, then reads from the copy

    Code
      invisible(store_read(fx$st, "sales/daily"))
    Message
      i Copying "sales/daily" (version <version>, 2 files, <bytes>) from '<root>/primary' to '<root>/secondary1' before reading.
      v 2/2 files sent to '<root>/secondary1' (<bytes>) in <time>, MD5 verified.
      i Reading "sales/daily" from secondary <root>/secondary1.

# store_read() does not copy above rcs.copy_on_read_max_bytes and says how to copy

    Code
      invisible(store_read(fx$st, "sales/daily"))
    Message
      i "sales/daily" needs <bytes>, above the <bytes> limit for copying on read (`rcs.copy_on_read_max_bytes`). Reading from '<root>/primary'.
        Use `copy = TRUE`, or `store_sync(st, datasets = "sales/daily")`, to copy it.

# store_read() of an old version copies nothing by default and says so; copy = TRUE adds it to the secondaries' history

    Code
      invisible(store_read(st, "sales/daily", version = old))
    Message
      i Read version <version> of "sales/daily" from '<root>/primary'; old versions are not copied to secondary locations.
        Use `copy = TRUE` to copy it.

# store_read() does not replace a secondary holding a newer version, and says so

    Code
      invisible(store_read(st, "sales/daily"))
    Message
      ! '<root>/secondary1' holds a newer version of "sales/daily"; it is not replaced. See `store_sync()`.

