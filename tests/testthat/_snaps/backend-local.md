# a fresh lock blocks another writer

    Code
      be_lock(be)
    Condition
      Error in `be_lock()`:
      ! Another writer holds the lock of '<root>'.
      i The lock was taken <n> seconds ago; it is taken over after 600 seconds.
      i If no other writer is running, delete the folder '<root>/_lock'.

