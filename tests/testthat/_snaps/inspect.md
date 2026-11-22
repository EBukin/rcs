# store_status(from = ) needs an address of the connection

    Code
      store_status(fx$st, from = "elsewhere/location")
    Condition
      Error in `store_status()`:
      ! `from` must be the address of a location of this connection, not "elsewhere/location".
      i Its locations: '<root>/primary', '<root>/secondary1', and '<root>/secondary2'.

# printed, store_status() names the source

    Code
      print(store_status(fx$st))
    Output
      Source: <root>/primary
      Locations: [1] <root>/secondary1
                 [2] <root>/secondary2
      # A tibble: 4 x 8
        dataset       location status  newer primary_version  location_version primary_updated     location_updated   
        <chr>         <chr>    <chr>   <chr> <chr>            <chr>            <dttm>              <dttm>             
      1 sales/daily   [1]      same    <NA>  <version> <version> 2026-01-31 12:00:00 2026-01-31 12:00:00
      2 sales/summary [1]      same    <NA>  <version> <version> 2026-01-31 12:00:00 2026-01-31 12:00:00
      3 sales/daily   [2]      differs <NA>  <version> <version> 2026-01-31 12:00:00 2026-01-31 12:00:00
      4 sales/summary [2]      missing <NA>  <version> <NA>             2026-01-31 12:00:00 NA                 
    Code
      print(store_status(fx$st, from = fx$secondary[[2]]))
    Output
      Source: <root>/secondary2
      Locations: [1] <root>/primary
                 [2] <root>/secondary1
      # A tibble: 4 x 8
        dataset       location status  newer primary_version  location_version primary_updated     location_updated   
        <chr>         <chr>    <chr>   <chr> <chr>            <chr>            <dttm>              <dttm>             
      1 sales/daily   [1]      differs <NA>  <version> <version> 2026-01-31 12:00:00 2026-01-31 12:00:00
      2 sales/summary [1]      extra   <NA>  <NA>             <version> NA                  2026-01-31 12:00:00
      3 sales/daily   [2]      differs <NA>  <version> <version> 2026-01-31 12:00:00 2026-01-31 12:00:00
      4 sales/summary [2]      extra   <NA>  <NA>             <version> NA                  2026-01-31 12:00:00

# store_datasets() checks its arguments

    Code
      store_datasets(fx$st, kind = "vector")
    Condition
      Error in `store_datasets()`:
      ! `kind` must be one of "table", "geospatial", or "raster", not "vector".
    Code
      store_datasets(fx$st, pattern = 1)
    Condition
      Error in `store_datasets()`:
      ! `pattern` must be a single non-empty string, not a number.
    Code
      store_datasets(fx$st, index = NA)
    Condition
      Error in `store_datasets()`:
      ! `index` must be `TRUE` or `FALSE`, not `NA`.
    Code
      store_datasets("not a store")
    Condition
      Error in `store_datasets()`:
      ! `st` must be a store connection made by `store_connect()`.
      x It is a string.

# print() shows locations and datasets grouped by folder

    Code
      print(st)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary      local  <root>/primary
        secondary 1  local  <root>/secondary1
        secondary 2  local  <root>/secondary2
      History: off (store default)
      Datasets: 3
        name       kind   rows    size  files  updated           1  2
        top        table    10  3.2 kB      1  2026-01-31 12:00  =  =
        sales/
          daily    table   240  1.2 kB      2  2026-01-31 12:00  =  !=
          summary  table    40  2.2 kB      1  2026-01-31 12:00  =  -
      Secondary copies: = same, != differs, - missing, ? unavailable.

---

    Code
      print(st)
    Output
      ── rcs store ───────────────────────────────────────────────────────────────────
      Locations:
        primary      local  <root>/primary
        secondary 1  local  <root>/secondary1
        secondary 2  local  <root>/secondary2
      History: off (store default)
      Datasets: 3
        name       kind   rows    size  files  updated           1  2
        top        table    10  3.2 kB      1  2026-01-31 12:00  =  =
        sales/
          daily    table   240  1.2 kB      2  2026-01-31 12:00  =  ≠
          summary  table    40  2.2 kB      1  2026-01-31 12:00  =  –
      Secondary copies: = same, ≠ differs, – missing, ? unavailable.

# print() shows the history setting, unavailable locations and limits the list

    Code
      print(st, n = 1)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary      local  <root>/primary
        secondary 1  local  <root>/secondary1 (unavailable)
      History: off (this connection; store default on)
      Datasets: 2
        name     kind   rows    size  files  updated           1
        sales/
          daily  table   240  1.2 kB      2  2026-01-31 12:00  ?
        ... and 1 more; see store_datasets().
      Secondary copies: = same, != differs, - missing, ? unavailable.

# print() of an empty store and of index tables

    Code
      print(st)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary  local  <root>/empty
      History: off (store default)
      Datasets: none

---

    Code
      print(fx$st)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary  local  <root>/primary
      History: off (store default)
      Datasets: 1 (1 index table hidden)
        name        kind        rows    size  files  updated
        shapes/
          polygons  geospatial    60  1.2 kB     44  2026-01-31 12:00
    Code
      print(fx$st, index = TRUE)
    Output
      -- rcs store -------------------------------------------------------------------
      Locations:
        primary  local  <root>/primary
      History: off (store default)
      Datasets: 2
        name            kind        rows    size  files  updated
        shapes/
          polygons      geospatial    60  1.2 kB     44  2026-01-31 12:00
          polygons__h3  table        331  2.2 kB      1  2026-01-31 12:00

# print() of a description

    Code
      print(store_describe(fx$st, "sales/daily"))
    Output
      -- sales/daily -----------------------------------------------------------------
      Daily sales
      Simulated daily sales by shop and product.
      
      Kind        table
      Version     <version>
      Rows        240
      Files       2
      Size        1.2 kB
      Key         shop_id, date, product
      Partition   year
      Sorted by   shop_id, date, product
      Source      -
      Inputs      -
      History     not set (the connection's setting applies)
      Created     2026-01-31 12:00:00 UTC
      Updated     2026-01-31 12:00:00 UTC
      Written by  R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary                  <root>/primary
        secondary 1  = same      <root>/secondary1
        secondary 2  != differs  <root>/secondary2
      
      Columns (15):
        name       type                                              r_type                     description
        shop_id    int32
        date       date32[day]
        year       int32
        product    dictionary<values=string, indices=int8>           factor (20 levels)
        qty        int32
        price      double
        promo      bool
        grade      dictionary<values=string, indices=int8, ordered>  ordered factor (3 levels)
        delivered  date32[day]
        big        int64                                             integer64
        wait       double                                            difftime (hours)
        note       string
        tags       list<item: string>                                list
        ts         timestamp[us, tz=UTC]
        ts_local   timestamp[us]
      
      Files (2):
        path                                                 partition      rows    size
        sales/daily/year=2023/part-<version>.parquet  {"year":2023}   125  5.7 kB
        sales/daily/year=2024/part-<version>.parquet  {"year":2024}   115  5.7 kB

---

    Code
      print(store_describe(fx$st, "summary"), n = 0)
    Output
      -- sales/summary ---------------------------------------------------------------
      Sales summary
      A small simulated table in one file.
      
      Kind        table
      Version     <version>
      Rows        40
      Files       1
      Size        2.2 kB
      Key         -
      Partition   -
      Sorted by   -
      Source      -
      Inputs      -
      History     not set (the connection's setting applies)
      Created     2026-01-31 12:00:00 UTC
      Updated     2026-01-31 12:00:00 UTC
      Written by  R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary                 <root>/primary
        secondary 1  = same     <root>/secondary1
        secondary 2  - missing  <root>/secondary2
      
      Columns (15):
        name       type                                              r_type                     description
        shop_id    int32
        date       date32[day]
        year       int32
        product    dictionary<values=string, indices=int8>           factor (20 levels)
        qty        int32
        price      double
        promo      bool
        grade      dictionary<values=string, indices=int8, ordered>  ordered factor (3 levels)
        delivered  date32[day]
        big        int64                                             integer64
        wait       double                                            difftime (hours)
        note       string
        tags       list<item: string>                                list
        ts         timestamp[us, tz=UTC]
        ts_local   timestamp[us]
      
      Files (1):
        path  partition  rows  size
        ... and 1 more.

# print() of a geospatial description and of its index table

    Code
      print(d, n = 3)
    Output
      -- shapes/polygons -------------------------------------------------------------
      Polygons
      Simulated polygons in open ocean.
      
      Kind         geospatial
      Version      <version>
      Rows         60
      Files        44
      Size         2.2 kB
      Key          -
      Partition    h3_p4
      Sorted by    h3, .rcs_id
      Source       -
      Inputs       -
      CRS          WGS 84 (EPSG:4326)
      Extent       xmin -29.81534, ymin 6.086176, xmax -24.28045, ymax 8.929905
      H3 res       5
      Index table  shapes/polygons__h3
      History      not set (the connection's setting applies)
      Created      2026-01-31 12:00:00 UTC
      Updated      2026-01-31 12:00:00 UTC
      Written by   R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary    <root>/primary
      
      Columns (8):
        name      type                                                            r_type     description
        id        int32
        area      double
        cat       string
        .rcs_id   int64                                                           integer64
        h3        int64                                                           integer64
        h3_p4     int64                                                           integer64
        bbox      struct<xmin: double, ymin: double, xmax: double, ymax: double>
        geometry  binary
      
      Files (44):
        path                                                                    partition                       rows    size
        shapes/polygons/h3_p4=595993035204984831/part-<version>.parquet  {"h3_p4":"595993035204984831"}     1  5.7 kB
        shapes/polygons/h3_p4=595993043794919423/part-<version>.parquet  {"h3_p4":"595993043794919423"}     2  5.7 kB
        shapes/polygons/h3_p4=595993060974788607/part-<version>.parquet  {"h3_p4":"595993060974788607"}     1  5.7 kB
        ... and 41 more.
    Code
      print(store_describe(fx$st, "shapes/polygons__h3"))
    Output
      -- shapes/polygons__h3 ---------------------------------------------------------
      Index of shapes/polygons
      H3 index table of shapes/polygons
      
      Kind        table
      Version     <version>
      Rows        331
      Files       1
      Size        3.2 kB
      Key         -
      Partition   -
      Sorted by   h3, .rcs_id
      Source      -
      Inputs      -
      Index of    shapes/polygons
      History     not set (the connection's setting applies)
      Created     2026-01-31 12:00:00 UTC
      Updated     2026-01-31 12:00:00 UTC
      Written by  R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary    <root>/primary
      
      Columns (4):
        name     type    r_type     description
        .rcs_id  int64   integer64
        h3       int64   integer64
        h3_main  int64   integer64
        share    double
      
      Files (1):
        path                                               partition  rows    size
        shapes/polygons__h3/part-<version>.parquet  {}          331  5.7 kB
    Code
      print(store_describe(fx$st, "polygons"), n = 0)
    Output
      -- polygons --------------------------------------------------------------------
      Polygons without geocodes
      Simulated polygons, geocode = FALSE.
      
      Kind        geospatial
      Version     <version>
      Rows        60
      Files       1
      Size        1.2 kB
      Key         -
      Partition   -
      Sorted by   .rcs_id
      Source      -
      Inputs      -
      CRS         WGS 84 (EPSG:4326)
      Extent      xmin -29.81534, ymin 6.086176, xmax -24.28045, ymax 8.929905
      H3 res      none (no geocodes)
      History     not set (the connection's setting applies)
      Created     2026-01-31 12:00:00 UTC
      Updated     2026-01-31 12:00:00 UTC
      Written by  R 4.6.2, rcs 0.0.0.9000
      
      Locations:
        primary    <root>/primary
      
      Columns (6):
        name      type                                                            r_type     description
        id        int32
        area      double
        cat       string
        .rcs_id   int64                                                           integer64
        bbox      struct<xmin: double, ymin: double, xmax: double, ymax: double>
        geometry  binary
      
      Files (1):
        path  partition  rows  size
        ... and 1 more.

