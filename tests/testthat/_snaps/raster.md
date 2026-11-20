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

---

    Code
      stage_sim_raster(categorical)
    Condition
      Error in `raster_stage()`:
      ! Categorical layers cannot be stored: class.
      i Store the codes, e.g. with `terra::as.int()`, and the categories as a table.

