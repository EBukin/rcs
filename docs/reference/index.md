# Package index

## Connect to a store

Create a store and connect to its primary and secondary locations.

- [`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
  : Connect to a store
- [`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md)
  : Initialise an empty store
- [`store_refresh()`](https://ebukin.github.io/rcs/reference/store_refresh.md)
  : Re-read the catalogs of a connection

## See what a store holds

These functions read the catalog only; they open no data file.

- [`print(`*`<rcs_store>`*`)`](https://ebukin.github.io/rcs/reference/print.rcs_store.md)
  : Print a store connection
- [`store_datasets()`](https://ebukin.github.io/rcs/reference/store_datasets.md)
  : List the datasets of a store
- [`store_describe()`](https://ebukin.github.io/rcs/reference/store_describe.md)
  [`print(`*`<rcs_description>`*`)`](https://ebukin.github.io/rcs/reference/store_describe.md)
  : Describe one dataset
- [`store_status()`](https://ebukin.github.io/rcs/reference/store_status.md)
  [`print(`*`<rcs_status>`*`)`](https://ebukin.github.io/rcs/reference/store_status.md)
  : Compare the secondary locations with the primary
- [`store_history()`](https://ebukin.github.io/rcs/reference/store_history.md)
  : List the versions of a dataset

## Write

- [`store_write()`](https://ebukin.github.io/rcs/reference/store_write.md)
  : Write a dataset to a store

## Read

- [`store_read()`](https://ebukin.github.io/rcs/reference/store_read.md)
  : Read a dataset
- [`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)
  : Open a dataset as a lazy query
- [`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md)
  : Add a spatial filter to a lazy query
- [`store_sample()`](https://ebukin.github.io/rcs/reference/store_sample.md)
  : Sample rows of a dataset
- [`store_glimpse()`](https://ebukin.github.io/rcs/reference/store_glimpse.md)
  : A first look at a dataset
- [`store_h3_hex()`](https://ebukin.github.io/rcs/reference/store_h3_hex.md)
  : H3 cells as hex strings
- [`filter(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`select(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`mutate(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`rename(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`arrange(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`distinct(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`head(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`collect(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`compute(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`pull(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  [`glimpse(`*`<rcs_query>`*`)`](https://ebukin.github.io/rcs/reference/rcs_query-dplyr.md)
  : dplyr verbs for lazy queries

## Check and maintain

Verify stored files, keep secondary locations up to date, remove old
versions.

- [`store_check()`](https://ebukin.github.io/rcs/reference/store_check.md)
  : Check a stored dataset
- [`store_sync()`](https://ebukin.github.io/rcs/reference/store_sync.md)
  : Bring secondary locations up to date
- [`store_copy()`](https://ebukin.github.io/rcs/reference/store_copy.md)
  : Copy one dataset between two locations
- [`store_delete()`](https://ebukin.github.io/rcs/reference/store_delete.md)
  : Delete a dataset
- [`store_rebuild()`](https://ebukin.github.io/rcs/reference/store_rebuild.md)
  : Rebuild the catalogs of a location
- [`store_prune()`](https://ebukin.github.io/rcs/reference/store_prune.md)
  : Remove old versions and orphan files

## Simulated data

Generators of the simulated data used in examples, vignettes and tests.

- [`rcs_sim_table()`](https://ebukin.github.io/rcs/reference/rcs_sim_table.md)
  : Simulated table of daily sales
- [`rcs_sim_polygons()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
  [`rcs_sim_points()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
  [`rcs_sim_lines()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
  [`rcs_sim_raster()`](https://ebukin.github.io/rcs/reference/rcs_sim_polygons.md)
  : Simulated geospatial data

## Work counters

- [`rcs_trace()`](https://ebukin.github.io/rcs/reference/rcs_trace.md)
  [`rcs_trace_reset()`](https://ebukin.github.io/rcs/reference/rcs_trace.md)
  : Work counters of the last call
