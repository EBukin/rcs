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

# store_intersects() combines with other verbs and with a second query

    Code
      q
    Output
      <rcs_query> shapes/polygons (geospatial, current)
      Location: primary
      Files:    10 of 44
      Spatial:  2 queries, no cell filter, box test, exact test in collect()
      Columns:  id, area

---

    Code
      q2
    Output
      <rcs_query> polygons (geospatial, current)
      Location: primary
      Files:    1 of 1
      Spatial:  1 query, no cell filter, box test, candidate set (exact = FALSE)
      Columns:  id, area, cat, bbox, geometry

---

    Code
      loose <- dplyr::collect(q2)
    Message
      i Spatial filter: `exact = FALSE`, so the result is the candidate set.
        It holds every intersecting row and may hold rows that do not intersect the query.

