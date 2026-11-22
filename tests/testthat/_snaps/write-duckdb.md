# more partitions than max_files abort before anything is staged

    Code
      duck_write(s$st, tbl, key = duck_key, partition = "date", max_files = 3)
    Condition
      Error in `store_write()`:
      ! Partitioning by date gives 91 files, more than `max_files` = 3.
      i Partition by a coarser column, or raise `max_files`.

# duplicate keys abort naming the first duplicates, nothing staged

    Code
      duck_write(s$st, tbl, key = duck_key)
    Condition
      Error in `store_write()`:
      ! The key shop_id, date, and product does not identify the rows: 7 key values repeat.
      x shop_id = 3, date = 2024-01-11, product = p08
      x shop_id = 7, date = 2023-11-03, product = p11
      x shop_id = 4, date = 2023-02-02, product = p03
      x shop_id = 2, date = 2023-11-20, product = p09
      x shop_id = 10, date = 2024-02-24, product = p07
      i And 2 more.

