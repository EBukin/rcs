# Demo of the prototypes: lazy print, DuckDB, geo transforms, credentials.
# Run from the project root in a fresh session. Writes only below tempdir().

devtools::load_all()
for (f in c("print", "h3", "duckdb", "geo", "auth")) source(file.path("dev/prototype", paste0(f, ".R")))

st <- store_connect(file.path(tempdir(), "rcs-proto"), create = TRUE)
store_write(st, rcs_sim_table(500, seed = 1), "sales/daily", title = "Daily sales",
  description = "Simulated.", key = c("shop_id", "date", "product"), partition = "year")

# 1. Lazy by default, printed like a dbplyr table ----------------------------
q <- store_open(st, "daily")
q                                              # header + first 10 rows
q |> dplyr::filter(year == 2024, qty > 40) |> dplyr::select(shop_id, date, qty)
q |> dplyr::filter(year == 2024) |> dplyr::collect()   # rows into R only here

# 2. DuckDB ------------------------------------------------------------------
raw <- rcs_sim_polygons(200, seed = 3)
store_write(st, raw, "geo/polygons", title = "Polygons", description = "Simulated.")

con <- store_duckdb(st)                        # every dataset as a lazy view
DBI::dbGetQuery(con, "SELECT year, count(*) n FROM sales.daily GROUP BY year")
store_open(st, "daily", engine = "duckdb") |>  # dbplyr
  dplyr::filter(year == 2024) |> dplyr::count(product, sort = TRUE)

con2 <- store_duckdb(st, mode = "native", spatial = TRUE)
DBI::dbGetQuery(con2, "SELECT p.id, count(*) cells FROM geo.polygons p
  JOIN geo.polygons__h3 i USING (\".rcs_id\") GROUP BY 1 ORDER BY 2 DESC LIMIT 3")

# 3. Geo transforms, both ways -------------------------------------------------
prepared <- raw |> geo_add(h3_res = 6, parents = c(2, 4))
geo_index(prepared, id = "id", h3_res = 6)
identical(geo_strip(prepared), raw)
store_write(st, prepared, "geo/polygons6", title = "Polygons r6", description = "Simulated.")
back <- store_open(st, "polygons6") |> dplyr::collect()
all.equal(geo_strip(back) |> dplyr::arrange(id), raw, check.attributes = FALSE)

# 4. H3 cells: integer on disk, hex on screen --------------------------------
back$h3[1:3]                                   # <rcs_h3> printed as hex
store_open(st, "polygons6", engine = "duckdb", con = con) |>
  dplyr::mutate(cell = rcs_h3_hex(h3)) |> dplyr::select(id, h3, cell) |> head(3)

# 5. Credentials, on a bucket ---------------------------------------------------
uri <- paste0("gs://rcs-test/proto-", format(Sys.time(), "%Y%m%d%H%M%S"))
g <- store_connect(uri, create = TRUE)         # default: the gcloud login, once
proto_store_auth(be_new(uri))                  # the credential, token renewed automatically
store_write(g, rcs_sim_raster(seed = 4), "grid/dem", title = "DEM", description = "Simulated.")
store_auth_check(g)                            # arrow, json_api, gdal, duckdb
# other credentials: store_connect(uri, auth = "key.json" | token | function() token)
be <- be_new(uri); be_delete(be, be_list(be)$path)

DBI::dbDisconnect(con); DBI::dbDisconnect(con2)
unlink(file.path(tempdir(), "rcs-proto"), recursive = TRUE)
