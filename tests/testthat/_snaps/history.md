# store_prune() removes history beyond keep, never a file a kept version names

    Code
      dry <- store_prune(st, keep = 1, dry_run = TRUE)
    Message
      v Would remove 2 history versions and 4 files (<bytes>) in 2 locations.

---

    Code
      out <- store_prune(st, keep = 1)
    Message
      v Removed 2 history versions and 4 files (<bytes>) in 2 locations.

---

    Code
      store_prune(st)
    Message
      v Nothing to prune.

# store_prune(before = ) removes versions replaced before a time

    Code
      store_prune(st, keep = -1)
    Condition
      Error in `store_prune()`:
      ! `keep` must be a whole number of at least 0.
    Code
      store_prune(st, before = "not a time")
    Condition
      Error in `store_prune()`:
      ! `before` must be one time, a date or a string such as "2026-01-31".

