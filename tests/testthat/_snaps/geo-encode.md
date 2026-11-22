# geo_decode() handles zero rows and a data frame of geometry only

    Code
      geo_decode(data.frame(a = 1), out$crs)
    Condition
      Error in `geo_decode()`:
      ! `data` has no geometry column.

# geo_encode() aborts on missing CRS, reserved names and bad arguments

    Code
      geo_encode(dplyr_free_rename(x, "cat", "h3"))
    Condition
      Error in `geo_encode()`:
      ! `x` has a column with a reserved name: h3.
      i Rename it; the package adds .rcs_id, h3 and bbox itself.

---

    Code
      geo_encode(sf::st_set_crs(x, NA))
    Condition
      Error in `geo_encode()`:
      ! `x` has no coordinate reference system.

# geocode_engine and tol are checked

    Code
      geo_encode(x, geocode_engine = "sphere")
    Condition
      Error in `geo_encode()`:
      ! `geocode_engine` must be one of "auto", "s2", or "planar", not "sphere".

---

    Code
      geo_encode(x, tol = -1)
    Condition
      Error in `geo_encode()`:
      ! `tol` must be one finite number not below 0.

