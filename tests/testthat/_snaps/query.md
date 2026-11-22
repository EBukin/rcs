# store_open() returns a lazy query without opening files

    Code
      store_open(fx$st, "nothing")
    Condition
      Error in `store_open()`:
      ! No dataset "nothing" in the store.

# an unfiltered query prints a header, the first rows and the rows left

    Code
      q
    Output
      # Dataset:  sales/summary [40 x 15] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    1 of 1
         shop_id date        year product   qty  price promo grade delivered      big
           <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
       1       1 2023-05-24  2023 p15         3 150.   FALSE low   2023-05-26    8e 2
       2       4 2023-04-05  2023 p17        36   8.99 FALSE low   2023-04-14    9e15
       3       7 2023-07-23  2023 p13        21  88.4  FALSE high  2023-08-02    9e15
       4      19 2023-05-28  2023 p04        44  29.6  FALSE high  2023-06-07    9e15
       5      11 2024-02-16  2024 p15        37  88.7  TRUE  low   2024-02-18    9e15
       6       2 2024-01-09  2024 p07        39  57.2  FALSE high  2024-01-17    9e15
       7       2 2023-05-30  2023 p17        42  NA    FALSE low   2023-06-06    9e15
       8      17 2024-02-01  2024 p03         4 137.   FALSE mid   2024-02-03    6e 2
       9       7 2023-11-09  2023 p05        44 159.   FALSE low   2023-11-17    9e15
      10      19 2023-06-24  2023 p19        12 108.   FALSE low   2023-06-30    9e15
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i 30 more rows
      # i Use `collect()` to read the rows into R.

# a filtered or shortened query prints ?? rows, the filter and the pruned files

    Code
      filtered
    Output
      # Dataset:  sales/daily [?? x 4] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    1 of 2 (pruned)
      # Filter:   ((year == 2024) and (qty > 20))
         shop_id date         qty price
           <int> <date>     <int> <dbl>
       1       1 2024-01-14    42 188. 
       2       1 2024-02-27    30 180. 
       3       1 2024-05-20    48  90.4
       4       1 2024-08-18    25  12.2
       5       1 2024-12-24    43 195. 
       6       2 2024-06-30    42 116. 
       7       2 2024-12-25    49  57.2
       8       3 2024-01-03    24  81.6
       9       3 2024-01-11    21  48.2
      10       3 2024-06-09    41  45.2
      # i more rows
      # i Use `collect()` to read the rows into R.

---

    Code
      short
    Output
      # Dataset:  sales/summary [?? x 15] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    1 of 1
        shop_id date        year product   qty  price promo grade delivered      big
          <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
      1       1 2023-05-24  2023 p15         3 150.   FALSE low   2023-05-26    8e 2
      2       4 2023-04-05  2023 p17        36   8.99 FALSE low   2023-04-14    9e15
      3       7 2023-07-23  2023 p13        21  88.4  FALSE high  2023-08-02    9e15
      4      19 2023-05-28  2023 p04        44  29.6  FALSE high  2023-06-07    9e15
      5      11 2024-02-16  2024 p15        37  88.7  TRUE  low   2024-02-18    9e15
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i Use `collect()` to read the rows into R.

# a geospatial query prints geometry and cells in hex

    Code
      sorted
    Output
      # Dataset:  shapes/polygons [?? x 4] (geospatial)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    44 of 44
            id h3                    area                                     geometry
         <int> <h3>                 <dbl>                               <GEOMETRY [°]>
       1     1 857c4bd3fffffff 46041.     POLYGON ((-29.8 6.1, -27.3 6.1, -27.3 7.6, ~
       2     2 8556494bfffffff  4487.     POLYGON ((-25.18752 8.2, -25.21461 8.36477,~
       3     3 857c5ab3fffffff  6755.     POLYGON ((-26.6 6.2, -25.8 6.2, -25.8 7, -2~
       4     4 85565813fffffff    30.1    POLYGON ((-29 8.5, -26.27514 8.5, -26.27514~
       5     5 857c5b47fffffff     0.392  MULTIPOLYGON (((-26.75391 7.293398, -26.749~
       6     6 85565903fffffff     0.392  MULTIPOLYGON (((-27.96559 7.733237, -27.961~
       7     7 8556483bfffffff     0.391  MULTIPOLYGON (((-26.42263 8.281812, -26.418~
       8     8 85565937fffffff     4.90   POLYGON ((-27.59022 7.49, -27.57022 7.49, -~
       9     9 NA                 NA                                     POLYGON EMPTY
      10    10 857c594ffffffff     0.0861 POLYGON ((-27.62964 6.871498, -27.62699 6.8~
      # i more rows
      # i Use `collect()` to read the rows into R.

# a spatial filter prints its description and a footer that allows more rows

    Code
      print(q, n = 3)
    Output
      # Dataset:  shapes/polygons [?? x 3] (geospatial)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    29 of 44 (pruned)
      # Spatial:  1 query, no cell filter, box test, exact test in collect()
      # Filter:   (with spatial predicate)
           id    area                                                         geometry
        <int>   <dbl>                                                    <POLYGON [°]>
      1     1 46041.         ((-29.8 6.1, -27.3 6.1, -27.3 7.6, -29.8 7.6, -29.8 6.1))
      2     3  6755.  ((-26.6 6.2, -25.8 6.2, -25.8 7, -26.6 7, -26.6 6.2), (-26.35 6~
      3     4    30.1 ((-29 8.5, -26.27514 8.5, -26.27514 8.500904, -29 8.500904, -29~
      # i more rows may exist
      # i Use `collect()` to read the rows into R.

# a query with no rows prints its header and 0 rows

    Code
      none
    Output
      # Dataset:  sales/daily [?? x 15] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    0 of 2 (pruned)
      # Filter:   (year == 1999)
      # i 15 variables: shop_id <int>, date <date>, year <int>, product <fct>,
      #   qty <int>, price <dbl>, promo <lgl>, grade <ord>, delivered <date>,
      #   big <int64>, wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i 0 rows

# print() takes the number of rows from n or from rcs.print_rows

    Code
      print(q, n = 3)
    Output
      # Dataset:  sales/summary [40 x 15] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    1 of 1
        shop_id date        year product   qty  price promo grade delivered      big
          <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
      1       1 2023-05-24  2023 p15         3 150.   FALSE low   2023-05-26    8e 2
      2       4 2023-04-05  2023 p17        36   8.99 FALSE low   2023-04-14    9e15
      3       7 2023-07-23  2023 p13        21  88.4  FALSE high  2023-08-02    9e15
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i 37 more rows
      # i Use `collect()` to read the rows into R.

---

    Code
      print(q, n = 0)
    Condition
      Error in `print()`:
      ! `n` must be a whole number of at least 1.

# a long filter is cut to the console width

    Code
      q
    Output
      # Dataset:  sales/summary [?? x 15] (table)
      # Location: primary (local)
      # Version:  <version> (current)
      # Files:    1 of 1
      # Filter:   (is_in(shop_id, {value_set=int32:[ 1, 2, 3, 4, 5, 6, ...
         shop_id date        year product   qty  price promo grade delivered      big
           <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
       1       1 2023-05-24  2023 p15         3 150.   FALSE low   2023-05-26    8e 2
       2       4 2023-04-05  2023 p17        36   8.99 FALSE low   2023-04-14    9e15
       3       7 2023-07-23  2023 p13        21  88.4  FALSE high  2023-08-02    9e15
       4      19 2023-05-28  2023 p04        44  29.6  FALSE high  2023-06-07    9e15
       5      11 2024-02-16  2024 p15        37  88.7  TRUE  low   2024-02-18    9e15
       6       2 2024-01-09  2024 p07        39  57.2  FALSE high  2024-01-17    9e15
       7       2 2023-05-30  2023 p17        42  NA    FALSE low   2023-06-06    9e15
       8      17 2024-02-01  2024 p03         4 137.   FALSE mid   2024-02-03    6e 2
       9       7 2023-11-09  2023 p05        44 159.   FALSE low   2023-11-17    9e15
      10      19 2023-06-24  2023 p19        12 108.   FALSE low   2023-06-30    9e15
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i more rows
      # i Use `collect()` to read the rows into R.

# a lazy query reads from the location store_read() would read from

    Code
      q <- store_open(st, "sales/summary")
    Message
      i Reading "sales/summary" from secondary <secondary1>.

---

    Code
      q
    Output
      # Dataset:  sales/summary [40 x 15] (table)
      # Location: secondary 1 (local)
      # Version:  <version> (current)
      # Files:    1 of 1
         shop_id date        year product   qty  price promo grade delivered      big
           <int> <date>     <int> <fct>   <int>  <dbl> <lgl> <ord> <date>     <int64>
       1       1 2023-05-24  2023 p15         3 150.   FALSE low   2023-05-26    8e 2
       2       4 2023-04-05  2023 p17        36   8.99 FALSE low   2023-04-14    9e15
       3       7 2023-07-23  2023 p13        21  88.4  FALSE high  2023-08-02    9e15
       4      19 2023-05-28  2023 p04        44  29.6  FALSE high  2023-06-07    9e15
       5      11 2024-02-16  2024 p15        37  88.7  TRUE  low   2024-02-18    9e15
       6       2 2024-01-09  2024 p07        39  57.2  FALSE high  2024-01-17    9e15
       7       2 2023-05-30  2023 p17        42  NA    FALSE low   2023-06-06    9e15
       8      17 2024-02-01  2024 p03         4 137.   FALSE mid   2024-02-03    6e 2
       9       7 2023-11-09  2023 p05        44 159.   FALSE low   2023-11-17    9e15
      10      19 2023-06-24  2023 p19        12 108.   FALSE low   2023-06-30    9e15
      # i 5 more variables: wait <drtn>, note <chr>, tags <list>, ts <dttm>,
      #   ts_local <dttm>
      # i 30 more rows
      # i Use `collect()` to read the rows into R.

# verbs abort as dplyr does, with the query's message

    Code
      dplyr::filter(q, qty > 1, .by = shop_id)
    Condition
      Error in `dplyr::filter()`:
      ! `.by` is not supported for <rcs_query>.

---

    Code
      store_intersects("not a query", 1)
    Condition
      Error in `store_intersects()`:
      ! `q` must be a query made by `store_open()`.

