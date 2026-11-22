# print() shows the class, the length and hex

    Code
      print(x)
    Output
      <rcs_h3[6]>
      [1] 85283473fffffff 85283447fffffff 8528340bfffffff 8428347ffffffff
      [5] NA              <invalid>      

---

    Code
      print(new_rcs_h3())
    Output
      <rcs_h3[0]>

# tibbles and sf print cells as hex

    Code
      print(x)
    Output
      # A tibble: 6 x 2
           id h3             
        <int> <h3>           
      1     1 85283473fffffff
      2     2 85283447fffffff
      3     3 8528340bfffffff
      4     4 8428347ffffffff
      5     5 NA             
      6     6 <invalid>      

---

    Code
      print(p)
    Output
      Simple feature collection with 4 features and 4 fields
      Geometry type: POINT
      Dimension:     XY
      Bounding box:  xmin: -28.40695 ymin: 6.605046 xmax: -24.55075 ymax: 8.834026
      Geodetic CRS:  WGS 84
      # A tibble: 4 x 5
           id value cat               geometry h3             
      * <int> <dbl> <chr>          <POINT [°]> <h3>           
      1     1 105.  b     (-28.40695 6.605046) 85283473fffffff
      2     2  87.7 a     (-27.76726 8.695169) 85283447fffffff
      3     3 107.  e     (-26.56288 8.834026) 8528340bfffffff
      4     4 111.  e     (-24.55075 7.982393) 8428347ffffffff

---

    Code
      print(df_sf)
    Output
      Simple feature collection with 4 features and 2 fields
      Geometry type: POINT
      Dimension:     XY
      Bounding box:  xmin: -28.40695 ymin: 6.605046 xmax: -24.55075 ymax: 8.834026
      Geodetic CRS:  WGS 84
        id              h3                   geometry
      1  1 85283473fffffff POINT (-28.40695 6.605046)
      2  2 85283447fffffff POINT (-27.76726 8.695169)
      3  3 8528340bfffffff POINT (-26.56288 8.834026)
      4  4 8428347ffffffff POINT (-24.55075 7.982393)

# rcs_h3_hex() warns for doubles and validates them

    Code
      rcs_h3_hex(d)
    Condition
      Warning:
      `x` is a double: cells above 2^53 may have lost their last bits.
      i Read cells as <integer64>, for DuckDB with `DBI::dbConnect(duckdb::duckdb(), bigint = "integer64")`.
      Error in `rcs_h3_hex()`:
      ! `x` holds 1 value that is not a valid H3 cell.
      x First: "599686042433355776".

# rcs_h3_hex() aborts on values that are not cells

    Code
      rcs_h3_hex(c("85283473fffffff", "not a cell"))
    Condition
      Error in `rcs_h3_hex()`:
      ! `x` holds 1 value that is not a valid H3 cell.
      x First: "not a cell".

