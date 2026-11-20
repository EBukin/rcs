# hex, integer64 and H3 queries give the same covering

    Code
      geo_covering(6.2e+17, 5L, crs)
    Condition
      Error in `geo_covering()`:
      ! `intersects` must hold H3 cells as hex strings, <integer64> or <H3>, not a number.
      i A plain number cannot hold an H3 cell: it would be rounded to another cell.

# covering aborts on a shape without CRS or an empty shape

    Code
      geo_covering(sf::st_sfc(sf::st_polygon(), crs = 4326), 5L, crs)
    Condition
      Error in `geo_covering()`:
      ! The query shape is empty.

