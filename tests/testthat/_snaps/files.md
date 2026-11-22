# partition_plan() uses an equal h3_p<r> column of the data, aborts on a different one

    Code
      partition_plan(wrong, "h3", max_files = 3, h3_max_res = 5L)
    Condition
      Error:
      ! The column h3_p4 of `x` differs from the partition column the write computes (12 rows).
      i With `partition = "h3"` the write partitions by h3_p4.
      i Remove the column with `rcs_geo_strip()`, or prepare it with `rcs_geo_add()` from the same cells.

