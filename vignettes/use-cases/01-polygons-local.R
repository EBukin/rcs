# Use case 1: large polygons in a local store
#
# Write a few large polygons (think: the regions of a small country) to a
# local store, with and without geocoding, then read them back: whole, by
# columns, and by area.
#
# Data: simulated by rcs_sim_polygons(), in open ocean. Everything is
# written below tempdir().

devtools::load_all()
library(sf)
library(dplyr)

# 1. Data -----------------------------------------------------------------

# Rows 1 to 3 of the simulated polygons are large shapes (a rectangle over
# more than 100 H3 cells, a polygon with many vertices, one with a hole).
# Together with the multipolygons 5 to 7 they stand in for regions.
polys <- rcs_sim_polygons(100, seed = 1)
regions <- polys[polys$id %in% c(1:3, 5:7), ]
regions$name <- paste0("region_", regions$id)
regions

plot(st_geometry(regions), col = sf.colors(nrow(regions)), axes = TRUE)

# 2. Local store ----------------------------------------------------------

root <- file.path(tempdir(), "use-case-01")
unlink(root, recursive = TRUE)
st <- store_connect(root, create = TRUE)
st

# 3. Write with geocoding (default) ---------------------------------------

# Adds h3 (main cell), bbox and an index table of every cell each region
# touches.
store_write(
  st,
  regions,
  "admin/regions",
  title = "Regions",
  description = "Large simulated polygons standing in for regions.",
  key = "id"
)

# Same rows, finer cells.
store_write(
  st,
  regions,
  "admin/regions_r7",
  title = "Regions, H3 resolution 7",
  description = "Large simulated polygons, geocoded at resolution 7.",
  key = "id",
  h3_res = 7
)

store_open(st, "admin/regions") |> glimpse()
store_open(st, "admin/regions_r7") |> glimpse()

# 4. Write without geocoding ----------------------------------------------

# Bounding boxes only: no h3 column, no index table.
store_write(
  st,
  regions,
  "admin/regions_plain",
  title = "Regions, no H3",
  description = "Large simulated polygons, bounding boxes only.",
  key = "id",
  geocode = FALSE
)

store_open(st, "admin/regions_plain") |> glimpse()

# 5. Inspect the store ----------------------------------------------------

print(st, index = TRUE)
store_describe(st, "admin/regions")
store_glimpse(st, "admin/regions")

# 6. Read back -------------------------------------------------------------

back <- store_read(st, "admin/regions")
back

# Attributes only.
store_read(st, "admin/regions", columns = c(id, name, area), geometry = FALSE)

# Round trip: same attributes and geometries as written.
back_clean <- rcs_geo_strip(back)
back_clean <- back_clean[order(back_clean$id), names(regions)]
all.equal(
  st_drop_geometry(back_clean),
  st_drop_geometry(regions),
  check.attributes = FALSE
)
identical(
  st_as_binary(st_geometry(back_clean)),
  st_as_binary(st_geometry(regions))
)

# 7. Read by area -----------------------------------------------------------

area <- st_as_sfc(st_bbox(
  c(xmin = -28, ymin = 7, xmax = -27, ymax = 8),
  crs = st_crs(4326)
))
hit <- store_read(st, "admin/regions", intersects = area)
hit$name

plot(st_geometry(regions), border = "grey60", axes = TRUE)
plot(st_geometry(hit), col = "steelblue", add = TRUE)
plot(area, border = "red", lwd = 2, add = TRUE)

# Same answer from the store without H3.
setequal(
  hit$id,
  store_read(st, "admin/regions_plain", intersects = area)$id
)

# 8. Geocoding in memory, no store ----------------------------------------

rcs_geo_add(regions, h3_res = 5, parents = 3)
rcs_geo_index(regions, "id", h3_res = 5)

# 9. Manual geocoding of a survey ------------------------------------------

# Survey: simulated household points in the same box (id, value, cat).
survey <- rcs_sim_points(2000, seed = 2)
survey <- rename(survey, hh_id = id, income = value, stratum = cat)
survey

# 9.1 Cells: main cell at resolution 7, parents at 5 and 3, and bbox.
survey_geo <- rcs_geo_add(survey, h3_res = 7, parents = c(5, 3))
survey_geo
class(survey_geo$h3)

# Hex strings, for joins with other H3 tools.
rcs_h3_hex(survey_geo$h3[1:5])
store_h3_hex(st_drop_geometry(survey_geo)[1:5, ])

# Households per cell of resolution 5.
survey_geo |>
  st_drop_geometry() |>
  count(h3_p5, sort = TRUE)

# 9.2 Index table: the cells each geometry touches. Points touch one cell,
# so with crossing_only = FALSE every household gets one line, share 1.
rcs_geo_index(survey, "hh_id", h3_res = 7, crossing_only = FALSE)

# The regions, by contrast, cross many cells: share of area per cell.
regions_cells <- rcs_geo_index(regions, "id", h3_res = 5, crossing_only = FALSE)
regions_cells
count(regions_cells, id)

# 9.3 Households to regions through cells (no geometry test): a household
# is in every region that touches its cell of resolution 5. Coarse but
# cheap; check it against the exact spatial join below.
by_cell <- survey_geo |>
  st_drop_geometry() |>
  select(hh_id, h3_p5) |>
  inner_join(
    select(regions_cells, region_id = id, h3_p5 = h3, share),
    by = "h3_p5",
    relationship = "many-to-many"
  )
by_cell

exact <- st_join(survey, select(regions, region_id = id), left = FALSE)
nrow(exact)
n_distinct(by_cell$hh_id)

# 9.4 Back to the raw form.
identical(rcs_geo_strip(survey_geo), survey)

# 10. Writing without repeated geocoding -----------------------------------

# 10.1 Prepared data. store_write() accepts survey_geo, but recomputes h3
# and bbox to check them: the geocoding runs twice (once above, once here).
# h3_res is taken from the cells; h3_p5 and h3_p3 are stored as columns.
store_write(
  st,
  survey_geo,
  "survey/households",
  title = "Survey households",
  description = "Simulated household points, prepared in memory.",
  key = "hh_id"
)
store_open(st, "survey/households") |> glimpse()

# The same data again: geocoded once more to compare, nothing is uploaded
# (status "unchanged").
store_write(
  st,
  survey_geo,
  "survey/households2",
  title = "Survey households",
  description = "Simulated household points, prepared in memory.",
  key = "hh_id",
  mode = "replace",
  geocode = TRUE
)

# 10.2 Geocode once, in the store. Write the raw data and let the write
# geocode; afterwards read the cells back instead of calling rcs_geo_add()
# again.
store_write(
  st,
  survey,
  "survey/households_raw",
  title = "Survey households, raw",
  description = "Simulated household points, geocoded by the write.",
  key = "hh_id",
  h3_res = 7
)


cells <- store_read(
  st,
  "survey/households_raw",
  columns = c(hh_id, h3),
  geometry = FALSE
)
cells

# 10.3 New households: mode = "update" geocodes only the rows passed, with
# the dataset's resolution and engine.
wave_2 <- rcs_sim_points(200, seed = 3) |>
  rename(hh_id = id, income = value, stratum = cat) |>
  mutate(hh_id = hh_id + 100000L)
store_write(
  st,
  wave_2,
  "survey/households_raw",
  title = "Survey households, raw",
  description = "Simulated household points, geocoded by the write.",
  mode = "replace"
)
store_describe(st, "survey/households_raw")

# 10.4 No geocoding at all on write: geocode = FALSE stores the bbox only.
# Cells computed in memory can still be kept as an ordinary column, under a
# name other than h3 (a column h3 with geocode = FALSE aborts).
survey_cells <- survey_geo |>
  rename(cell_r7 = h3) |>
  rcs_geo_strip("bbox")
store_write(
  st,
  survey_cells,
  "survey/households_nogeo",
  title = "Survey households, no H3 index",
  description = "Simulated household points with cells as plain columns.",
  key = "hh_id",
  geocode = FALSE
)
store_open(st, "survey/households_nogeo") |> glimpse()

# 10.5 Attributes only: the survey without geometry is a plain table,
# never geocoded; cells travel as columns, the geometry stays elsewhere.
store_write(
  st,
  st_drop_geometry(survey_geo) |> select(-bbox),
  "survey/households_table",
  title = "Survey households, table",
  description = "Simulated household attributes with their H3 cells.",
  key = "hh_id"
)
store_read(st, "survey/households_table")

print(st)

# 11. Clean up -------------------------------------------------------------

unlink(root, recursive = TRUE)

# 12. Map: one region and its hexagons, side by side -----------------------

# Cell polygons from any cell vector (rcs_h3, integer64 or hex) via h3o.
cell_polygons <- function(cells) {
  hex <- rcs_h3_hex(cells)
  st_set_crs(st_as_sfc(h3o::h3_from_strings(hex)), 4326)
}

# Region 1: the large rectangle.
region <- regions[regions$id == 1, ]

# Left: the resolution-5 cells the region touches, by share of its area.
region_cells <- rcs_geo_index(region, "id", h3_res = 5, crossing_only = FALSE)
region_hex <- st_sf(
  share = region_cells$share,
  geometry = cell_polygons(region_cells$h3)
)

# Right: households in the region, counted per resolution-7 cell.
hh_in_region <- st_filter(survey_geo, region)
hh_counts <- hh_in_region |>
  st_drop_geometry() |>
  count(h3, name = "households")
hh_hex <- st_sf(
  households = hh_counts$households,
  geometry = cell_polygons(hh_counts$h3)
)

old_par <- par(mfrow = c(1, 2), mar = c(2, 2, 3, 1))
plot(
  region_hex["share"],
  main = "Region 1: H3 cells (res 5), share of area",
  pal = hcl.colors(9, "YlGnBu", rev = TRUE),
  border = "white",
  key.pos = NULL,
  reset = FALSE,
  axes = TRUE
)
plot(st_geometry(region), border = "red", lwd = 2, add = TRUE)

plot(
  hh_hex["households"],
  main = "Households per H3 cell (res 7)",
  pal = hcl.colors(9, "OrRd", rev = TRUE),
  border = "grey80",
  key.pos = NULL,
  reset = FALSE,
  axes = TRUE
)
plot(st_geometry(region), border = "red", lwd = 2, add = TRUE)
plot(st_geometry(hh_in_region), pch = ".", col = "grey20", add = TRUE)
par(old_par)

# 13. One polygon at three H3 resolutions ----------------------------------

# Every cell the polygon touches, interior included, at a coarse, a middle
# and a fine resolution. Region 1 is a simulated rectangle of more than 100
# cells at resolution 5.
shape <- regions[regions$id == 1, ]

res_cells <- lapply(c(3, 4, 5), function(r) {
  idx <- rcs_geo_index(shape, "id", h3_res = r, crossing_only = FALSE)
  st_sf(
    res = r,
    share = idx$share,
    geometry = cell_polygons(idx$h3)
  )
})
sapply(res_cells, nrow)

old_par <- par(mfrow = c(1, 3), mar = c(2, 2, 3, 1))
for (cells_r in res_cells) {
  plot(
    st_geometry(cells_r),
    col = "lightblue",
    border = "steelblue",
    main = paste0("H3 res ", cells_r$res[1], ": ", nrow(cells_r), " cells"),
    axes = TRUE
  )
  plot(st_geometry(shape), border = "red", lwd = 2, add = TRUE)
}
par(old_par)
