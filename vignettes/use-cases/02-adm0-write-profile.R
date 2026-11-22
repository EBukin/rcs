# Use case 2: where the time goes when one large country polygon is saved
#
# Load the national boundary (adm0, one multipolygon of about 170,000
# vertices) and save it to a local store below tempdir(), with and without
# geocoding, at two H3 resolutions, with each geocoding engine and with H3
# partitions. Each write is timed and profiled with Rprof(); the profile is
# summarised by the package's own functions.
#
# Data: an external GeoParquet file outside the package (path below), read
# with arrow. Not run on CRAN or in checks.

devtools::load_all()
library(sf)
library(dplyr)

# 1. Data -----------------------------------------------------------------

adm0_file <- "C:/Users/EB2/noSyncDocs/ukrCadastreReharvest/data-store/admin/adm0_country.parquet"

# GDAL on this machine has no Parquet driver, so read with arrow and build
# the geometry from WKB. Only the raw attributes are kept: the file's own
# H3 and bbox columns are what the write recomputes.
raw <- as.data.frame(arrow::read_parquet(adm0_file))
adm0 <- st_sf(
  raw[c("adm0_id", "adm0_name_eng", "area_km2")],
  geometry = st_as_sfc(structure(raw$geometry, class = "WKB"), crs = 4326)
)
adm0
nrow(st_coordinates(adm0))

# 2. Local store ----------------------------------------------------------

root <- file.path(tempdir(), "use-case-02")
unlink(root, recursive = TRUE)
st <- store_connect(root, create = TRUE)

# 3. Timing and profiling helpers -----------------------------------------

# Run `expr` under Rprof(); return elapsed seconds and the profile.
profile_run <- function(expr, interval = 0.01) {
  out <- tempfile(fileext = ".Rprof")
  gc()
  Rprof(out, interval = interval, memory.profiling = FALSE)
  t0 <- proc.time()[["elapsed"]]
  force(expr)
  elapsed <- proc.time()[["elapsed"]] - t0
  Rprof(NULL)
  list(seconds = elapsed, prof = summaryRprof(out)$by.total)
}

# Total time per function, kept to the package's functions and a few
# workhorses from other packages, ordered by total time.
profile_top <- function(p, n = 15) {
  ours <- c(ls(asNamespace("rcs"), all.names = TRUE))
  fun <- gsub('"', "", rownames(p$prof))
  keep <- fun %in% ours |
    grepl("^(h3o|sf|s2|arrow|nanoparquet|duckdb|DBI)::|^(st_|s2_|h3_|write_parquet|read_parquet|dbExecute|dbGetQuery)", fun)
  tibble(
    fun = fun,
    total_s = p$prof$total.time,
    total_pct = round(100 * p$prof$total.time / p$seconds, 1),
    self_s = p$prof$self.time
  )[keep, ] |>
    arrange(desc(total_s)) |>
    head(n)
}

# One write per scenario: a new dataset name, so every write stages and
# lands a fresh version.
write_adm0 <- function(name, ...) {
  store_write(
    st, adm0, paste0("admin/", name),
    title = "Country boundary",
    description = "National boundary, one multipolygon.",
    key = "adm0_id",
    ...
  )
}

scenarios <- list(
  plain         = list(geocode = FALSE),
  h3_r5         = list(),
  h3_r5_s2      = list(geocode_engine = "s2"),
  h3_r5_planar  = list(geocode_engine = "planar"),
  h3_r6         = list(h3_res = 6),
  h3_r5_nocheck = list(check = FALSE),
  h3_r6_part    = list(h3_res = 6, partition = "h3")
)

# 4. Run --------------------------------------------------------------------

runs <- list()
for (s in names(scenarios)) {
  cat("\n==", s, "==\n")
  runs[[s]] <- profile_run(do.call(write_adm0, c(list(s), scenarios[[s]])))
}

# 5. Results ----------------------------------------------------------------

# Elapsed seconds per scenario.
timings <- tibble(
  scenario = names(runs),
  seconds = vapply(runs, function(r) r$seconds, numeric(1))
)
timings

# Where the time goes, per scenario.
for (s in names(runs)) {
  cat("\n==", s, sprintf("(%.1f s) ==\n", runs[[s]]$seconds))
  print(profile_top(runs[[s]]), n = 15)
}

# What each write stored: index-table rows per resolution.
print(st, index = TRUE)

# 6. Geocoding alone, in memory -------------------------------------------

# The same work outside store_write(), to separate it from staging and
# landing.
system.time(rcs_geo_add(adm0, h3_res = 5))
system.time(rcs_geo_index(adm0, "adm0_id", h3_res = 5))
system.time(rcs_geo_index(adm0, "adm0_id", h3_res = 6))

# 7. Clean up -------------------------------------------------------------

unlink(root, recursive = TRUE)
