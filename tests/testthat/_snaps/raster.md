# a query outside the raster aborts

    Code
      raster_open(be_new(dir), out$files$path, intersects = far)
    Condition
      Error in `raster_open()`:
      ! The query does not overlap the raster 'grids/sim/part-<version>.tif'.
      i Query box: xmin -20, ymin 7, xmax -19, ymax 8.
      i Raster extent: xmin -30, ymin 6, xmax -24, ymax 9.

# raster_stage() aborts on unusable rasters

    Code
      stage_sim_raster(no_crs)
    Condition
      Error in `raster_stage()`:
      ! The raster has no coordinate reference system.
      i Set one with `terra::crs(x) <- ...`.

# an explicit datatype is used, and values or nodata that do not fit abort

    Code
      stage_sim_raster(too_large, datatype = "INT1U")
    Condition
      Error in `raster_stage()`:
      ! The values do not fit the data type "INT1U".
      x Values found: 0 to 300.
      i "INT1U" holds 0 to 255.

---

    Code
      stage_sim_raster(whole, datatype = "INT8S")
    Condition
      Error in `raster_stage()`:
      ! `datatype` must be `NULL` or one of "INT1U", "INT2U", "INT2S", "INT4U", "INT4S", "FLT4S", or "FLT8S".
      x Not "INT8S".

# the active label column is the legend; the other columns are dropped with a message

    Code
      out <- stage_sim_raster(x)
    Message
      Only the codes and the active labels of a categorical layer are stored. Dropped:
      * cover: name_fr

# staging a file-backed raster warns when the staging drive looks too small

    Code
      out <- stage_sim_raster(x, dir = dir)
    Condition
      Warning:
      The staging drive may be too small to write this raster.
      i Free: 1 B. Estimated need: 3.0 kB.
      i Staging folder: '<staging>'
      i Set another folder with `options(rcs.staging_dir = )`.

