# rcs_geo_add() checks its arguments

    Code
      rcs_geo_add(raw, h3_res = 5L, parents = c(2L, 5L))
    Condition
      Error in `rcs_geo_add()`:
      ! `parents` must be whole numbers from 0 to 4 (below `h3_res` = 5).
      x Not below `h3_res`: 5.

# rcs_geo_add() warns naming the row numbers of rebuilt rows

    Code
      invisible(rcs_geo_add(x, h3_res = 5L, geocode_engine = "s2"))
    Condition
      Warning:
      Geocoding `x`: 2 rows are invalid on the sphere.
      i 2 rebuilt by s2, 0 geocoded in the plane after a failed rebuild check.
      * Rebuilt: row 21; row 22.

