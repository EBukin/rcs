# store_status(), store_datasets(), the print and store_describe() report "primary only"

    Code
      print(st)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary      local  <root>/primary
        secondary 1  local  <root>/secondary1
      History: off (store default)
      Datasets: 2
        name       kind   rows     size  files  updated           1
        sales/
          daily    table    30  <bytes>      2  <date>  -
          summary  table    15  <bytes>      2  <date>  P
      Secondary copies: = same, != differs, - missing, P primary only, ? unavailable.
    Code
      print(store_status(st))
    Output
      Source: <root>/primary
      Locations: [1] <root>/secondary1
      # A tibble: 2 x 8
        dataset       location status       newer primary_version  location_version primary_updated     location_updated
        <chr>         <chr>    <chr>        <chr> <chr>            <chr>            <dttm>              <dttm>          
      1 sales/daily   [1]      missing      <NA>  <version> <NA>             <date> NA              
      2 sales/summary [1]      primary only <NA>  <version> <NA>             <date> NA              
    Code
      print(store_describe(st, "sales/summary"), n = 0)
    Output
      -- sales/summary ---------------------------------------------------------------
      Daily sales
      Simulated daily sales.
      
      Kind        table
      Version     <version>
      Rows        15
      Files       2
      Size        <bytes>
      Key         shop_id, date, product
      Partition   year
      Sorted by   shop_id, date, product
      Source      -
      Inputs      -
      History     not set (the connection's setting applies)
      Created     <date> UTC
      Updated     <date> UTC
      Written by  R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary                      <root>/primary
        secondary 1  P primary only  <root>/secondary1
      
      Columns (7):
        name     type                                     r_type              description
        shop_id  int32
        date     date32[day]
        year     int32
        product  dictionary<values=string, indices=int8>  factor (20 levels)
        qty      int32
        price    double
        note     string
      
      Files (2):
        path  partition  rows  size
        ... and 2 more.

# a primary-only dataset stays so on later writes until locations = "all"; bad values abort

    Code
      write("secondary")
    Condition
      Error in `store_write()`:
      ! `locations` must be "primary", "all" or `NULL`.
      x It is "secondary".

# a primary-only replace leaves a secondary that holds the dataset as it was, and says so once

    Code
      invisible(replace(g_sim(30, 3)))
    Message
      i Replacing "sales/daily": 30 rows in 1 file.
      v primary    <root>/primary     1/1 files sent  <bytes>  <time>
      i secondary  <root>/secondary1  kept in the primary only
      i '<root>/secondary1' holds "sales/daily" and is not updated by this primary-only write.
        Use `store_sync(st, datasets = "sales/daily")` to update it.
      v MD5 identical for 1 file in 1 location. Catalogs updated.

# store_read() of a primary-only raster reads from the cloud primary and says so; copy = TRUE copies it

    Code
      invisible(store_read(st, "grids/sim"))
    Message
      i "grids/sim" is kept in the primary only; reading from '<root>/primary'.
        Use `copy = TRUE` to copy it.

# store_sync(all = TRUE) leaves a primary-only dataset out; datasets = copies it, and a default sync then keeps it fresh

    Code
      invisible(store_sync(st, all = TRUE))
    Message
      i Syncing 3 datasets from the primary '<root>/primary' to 1 secondary location.
      v secondary  <root>/secondary1  up to date
      i '<root>/secondary1': 1 primary-only dataset not copied (2 files, <bytes>).
        Use `store_sync(st, datasets = )` to copy them.
      v Every secondary location is up to date.

