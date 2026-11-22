# H3 cells as hex, integer64 and H3 give the same rows; a plain number aborts

    Code
      store_read(fx$st, "polygons", intersects = 599686042433355776)
    Condition
      Error in `store_read()`:
      ! `intersects` must be an <sf>, <sfc> or <bbox> object, or H3 cells.
      Caused by error in `geo_covering()`:
      ! `intersects` must hold H3 cells as hex strings, <integer64> or <H3>, not a number.
      i A plain number cannot hold an H3 cell: it would be rounded to another cell.

---

    Code
      store_read(fx$st, "polygons", intersects = "not a cell")
    Condition
      Error in `store_read()`:
      ! `intersects` must be an <sf>, <sfc> or <bbox> object, or H3 cells.
      Caused by error in `geo_covering()`:
      ! `intersects` holds 1 value that is not a valid H3 cell.
      x First: "not a cell".

# a cell finer than the stored resolution informs, and gives the exact rows

    Code
      got <- store_read(fx$st, "polygons", intersects = hex)
    Message
      i The query holds cells finer than the stored resolution 5; the cell filter works at resolution 5.

# exact = FALSE and geometry = FALSE return the candidate set with a message

    Code
      loose <- store_read(fx$st, "polygons", intersects = q, exact = FALSE)
    Message
      i Spatial filter: `exact = FALSE`, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

---

    Code
      flat <- store_read(fx$st, "polygons", intersects = q, geometry = FALSE)
    Message
      i Spatial filter: the geometry is not read, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

# a spatial filter on a table aborts

    Code
      store_read(fx$st, "sales/daily", intersects = sq(-28, 7, -27, 8))
    Condition
      Error in `store_read()`:
      ! A spatial filter needs a geospatial dataset.
      x "sales/daily" is a table.

---

    Code
      store_intersects(store_open(fx$st, "sales/daily"), sq(-28, 7, -27, 8), exact = NA)
    Condition
      Error in `store_intersects()`:
      ! `exact` must be `TRUE` or `FALSE`, not `NA`.

# an invalid query geometry aborts before any file is read

    Code
      store_read(st, "polygons", intersects = bow_tie)
    Condition
      Error in `store_read()`:
      ! The query geometry is not valid on the sphere (s2).
      x Edge 0 crosses edge 2.
      i Repair it with `sf::st_make_valid()`.

---

    Code
      store_intersects(store_open(st, "polygons"), bow_tie)
    Condition
      Error in `store_intersects()`:
      ! The query geometry is not valid in the plane.
      x Self-intersection[-27.5 7.5].
      i Repair it with `sf::st_make_valid()`.

# store_intersects() combines with other verbs and with a second query

    Code
      print(dplyr::arrange(q, id))
    Output
      # Dataset:  shapes/polygons [?? x 2] (geospatial)
      # Location: primary (local)
      # Version:  04391513 (current)
      # Files:    10 of 44 (pruned)
      # Spatial:  2 queries, no cell filter, box test, exact test in collect()
      # Filter:   (with spatial predicate)
            id      area
         <int>     <dbl>
       1     3 6755.    
       2     4   30.1   
       3     5    0.392 
       4     7    0.391 
       5    14    0.187 
       6    21    0.0480
       7    23    0.326 
       8    24    0.467 
       9    37    0.378 
      10    38    0.0617
      # i more rows may exist
      # i Use `collect()` to read the rows into R.

---

    Code
      print(dplyr::arrange(q2, id))
    Output
      # Dataset:  polygons [?? x 5] (geospatial)
      # Location: primary (local)
      # Version:  d5bef4b8 (current)
      # Files:    1 of 1
      # Spatial:  1 query, no cell filter, box test, candidate set (exact = FALSE)
      # Filter:   (with spatial predicate)
            id       area cat   bbox$xmin $ymin $xmax $ymax                   geometry
         <int>      <dbl> <chr>     <dbl> <dbl> <dbl> <dbl>             <GEOMETRY [°]>
       1     1 46041.     c         -29.8  6.1  -27.3  7.6  POLYGON ((-29.8 6.1, -27.~
       2     3  6755.     b         -26.6  6.2  -25.8  7    POLYGON ((-26.6 6.2, -25.~
       3     4    30.1    d         -29    8.5  -26.3  8.50 POLYGON ((-29 8.5, -26.27~
       4     5     0.392  b         -26.8  7.29 -26.7  7.30 MULTIPOLYGON (((-26.75391~
       5     6     0.392  b         -28.0  7.73 -27.9  7.76 MULTIPOLYGON (((-27.96559~
       6     7     0.391  d         -26.4  8.28 -25.9  8.54 MULTIPOLYGON (((-26.42263~
       7     8     4.90   e         -27.6  7.49 -27.6  7.51 POLYGON ((-27.59022 7.49,~
       8    10     0.0861 e         -27.6  6.87 -27.6  6.87 POLYGON ((-27.62964 6.871~
       9    13     0.0306 d         -28.6  7.15 -28.6  7.16 POLYGON ((-28.58083 7.154~
      10    14     0.187  d         -26.2  8.27 -26.2  8.27 POLYGON ((-26.15558 8.268~
      # i more rows
      # i Use `collect()` to read the rows into R.

---

    Code
      loose <- dplyr::collect(q2)
    Message
      i Spatial filter: `exact = FALSE`, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

# (e) an explicit exact_engine overrides the dataset's engine

    Code
      store_read(st, "eng/auto", intersects = engine_point(), exact_engine = "sphere")
    Condition
      Error in `store_read()`:
      ! `exact_engine` must be `NULL` or one of "s2", "planar", and "session".
      x It is "sphere".

---

    Code
      store_intersects(store_open(st, "eng/auto"), engine_point(), exact_engine = NA)
    Condition
      Error in `store_intersects()`:
      ! `exact_engine` must be `NULL` or one of "s2", "planar", and "session".
      x It is `NA`.

# (h) the query validity check follows the engine, and advises planar

    Code
      store_read(st, "eng/auto", intersects = dup)
    Condition
      Error in `store_read()`:
      ! The query geometry is not valid on the sphere (s2).
      x Loop 0: Edge 1 is degenerate (duplicate vertex).
      i Repair it with `sf::st_make_valid()`.
      i Or test in the plane with `exact_engine = "planar"`.

---

    Code
      store_intersects(store_open(st, "eng/s2"), dup)
    Condition
      Error in `store_intersects()`:
      ! The query geometry is not valid on the sphere (s2).
      x Loop 0: Edge 1 is degenerate (duplicate vertex).
      i Repair it with `sf::st_make_valid()`.
      i Or test in the plane with `exact_engine = "planar"`.

---

    Code
      store_read(st, "eng/old", intersects = dup)
    Condition
      Error in `store_read()`:
      ! The query geometry is not valid on the sphere (s2).
      x Loop 0: Edge 1 is degenerate (duplicate vertex).
      i Repair it with `sf::st_make_valid()`.

