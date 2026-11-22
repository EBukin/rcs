# store_duckdb() and store_tables(): views over a store's datasets in an
# in-memory DuckDB database (plan 0002, D10-D15, D19, D22).

# A local store with a secondary: a one-file table (`summary`, view
# `main.summary`), a table partitioned by year (`sales/daily`), and a
# geospatial dataset partitioned by "h3" with empty geometries (so an
# `h3_p<r>=null` partition) and its index table.
duckdb_test_store <- function(frame = parent.frame()) {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  withr::local_options(rcs.quiet = TRUE, .local_envir = frame)
  root <- withr::local_tempdir(.local_envir = frame)
  st <- store_connect(file.path(root, "primary"), file.path(root, "secondary"), create = TRUE)
  store_write(st, rcs_sim_table(200, seed = 1), "sales/daily",
    title = "Daily", description = "Simulated daily table.",
    key = c("shop_id", "date", "product"), partition = "year"
  )
  store_write(st, rcs_sim_table(50, seed = 2), "summary",
    title = "Summary", description = "Simulated table."
  )
  p <- rcs_sim_polygons(60, seed = 1)
  p$geometry[60] <- sf::st_polygon()
  store_write(st, p, "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.",
    partition = "h3", max_files = 5
  )
  st
}

duckdb_test_views <- c("main.summary", "sales.daily", "shapes.polygons", "shapes.polygons__h3")

# Views and tables of the connection outside the internal schemas.
duckdb_objects <- function(con, fun = c("duckdb_views", "duckdb_tables")) {
  fun <- match.arg(fun)
  name <- if (fun == "duckdb_views") "view_name" else "table_name"
  sql <- paste0(
    "SELECT schema_name || '.' || ", name, " AS x FROM ", fun, "() ",
    "WHERE NOT internal AND schema_name NOT IN ('information_schema', 'pg_catalog')"
  )
  sort(DBI::dbGetQuery(con, sql)$x, method = "radix")
}

duckdb_rows <- function(con, table) {
  out <- DBI::dbGetQuery(con, paste("SELECT * FROM", table))
  tibble::as_tibble(out)
}

quoted_view <- function(view) {
  parts <- strsplit(view, ".", fixed = TRUE)[[1]]
  paste0('"', parts[[1]], '"."', parts[[2]], '"')
}

# The DuckDB name of an Arrow type, for the types the package writes.
arrow_duckdb_type <- function(type) {
  s <- type$ToString()
  if (startsWith(s, "dictionary<values=string")) {
    return("VARCHAR")
  }
  if (startsWith(s, "timestamp")) {
    return(if (grepl("tz=", s, fixed = TRUE)) "TIMESTAMP WITH TIME ZONE" else "TIMESTAMP")
  }
  if (startsWith(s, "list<")) {
    return(paste0(arrow_duckdb_type(type$value_type), "[]"))
  }
  if (startsWith(s, "struct<")) {
    fields <- vapply(type$fields(), function(f) paste(f$name, arrow_duckdb_type(f$type)), character(1))
    return(paste0("STRUCT(", paste(fields, collapse = ", "), ")"))
  }
  switch(s,
    int32 = "INTEGER",
    int64 = "BIGINT",
    double = "DOUBLE",
    string = "VARCHAR",
    bool = "BOOLEAN",
    "date32[day]" = "DATE",
    binary = "BLOB",
    s
  )
}

# (a) ----------------------------------------------------------------------------

test_that("store_duckdb() makes one view per dataset, named by D12, in both modes", {
  st <- duckdb_test_store()
  for (mode in c("native", "arrow")) {
    con <- local_duckdb()
    before <- Sys.time()
    out <- store_duckdb(st, con = con, mode = mode)
    expect_identical(out, con)
    expect_identical(duckdb_objects(con, "duckdb_views"), duckdb_test_views)
    expect_identical(intersect(duckdb_objects(con, "duckdb_tables"), duckdb_test_views), character())
    expect_setequal(duckdb_objects(con, "duckdb_tables"), c("rcs.store", "rcs.views"))

    views <- duckdb_rows(con, "rcs.views")
    views <- views[order(views$view, method = "radix"), ]
    expect_identical(names(views), c("view", "dataset", "version", "location", "mode", "refreshed"))
    expect_identical(views$view, duckdb_test_views)
    expect_identical(
      views$dataset,
      c("summary", "sales/daily", "shapes/polygons", "shapes/polygons__h3")
    )
    catalog <- st$primary$catalog
    expect_identical(views$version, catalog$version[match(views$dataset, catalog$dataset)])
    expect_identical(views$location, rep(st$primary$uri, 4))
    expect_identical(views$mode, rep(mode, 4))
    expect_s3_class(views$refreshed, "POSIXct")
    expect_true(all(abs(as.numeric(views$refreshed) - as.numeric(before)) < 60))

    stores <- duckdb_rows(con, "rcs.store")
    expect_identical(stores$role, c("primary", "secondary"))
    expect_identical(stores$uri, store_uris(st))

    # The H3 macro of D10 is there.
    expect_true(nrow(DBI::dbGetQuery(con, "SELECT * FROM duckdb_functions() WHERE function_name = 'rcs_h3_hex'")) > 0)
  }
})

test_that("store_duckdb() makes its own in-memory connection and names the views", {
  st <- duckdb_test_store()
  withr::local_options(rcs.quiet = FALSE)
  expect_snapshot(con <- store_duckdb(st))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_s4_class(con, "duckdb_connection")
  expect_identical(DBI::dbGetQuery(con, "SELECT current_database() AS d")$d, "memory")
  expect_identical(duckdb_objects(con, "duckdb_views"), duckdb_test_views)
  expect_s3_class(DBI::dbGetQuery(con, "SELECT 9007199254740993::BIGINT AS x")$x, "integer64")
  expect_silent(withr::with_options(list(rcs.quiet = TRUE), store_duckdb(st, con = con)))
})

# (b) ----------------------------------------------------------------------------

test_that("native views have the Arrow column types and the same rows as store_open()", {
  st <- duckdb_test_store()
  con <- local_duckdb()
  con_arrow <- local_duckdb()
  store_duckdb(st, con = con)
  store_duckdb(st, con = con_arrow, mode = "arrow")
  sums <- c(
    "summary" = "shop_id", "sales/daily" = "shop_id",
    "shapes/polygons" = "id", "shapes/polygons__h3" = "share"
  )
  for (dataset in names(sums)) {
    view <- quoted_view(duckdb_view_name(dataset) |> paste(collapse = "."))
    target <- read_target(st, dataset)
    schema <- query_open_files(target$location, target$files$path)$schema
    described <- DBI::dbGetQuery(con, paste("DESCRIBE", view))
    expect_identical(described$column_name, names(schema), info = dataset)
    expected <- vapply(schema$fields, function(f) arrow_duckdb_type(f$type), character(1))
    keep <- described$column_name != "geometry"
    expect_identical(described$column_type[keep], expected[keep], info = dataset)
    if (dataset == "shapes/polygons") {
      expect_match(described$column_type[!keep], "^GEOMETRY")
      expect_identical(described$column_type[described$column_name == "h3_p1"], "BIGINT")
    }

    data <- dplyr::collect(store_open(st, dataset))
    column <- sums[[dataset]]
    for (k in list(con, con_arrow)) {
      got <- DBI::dbGetQuery(k, paste0("SELECT count(*) AS n, sum(", column, ") AS s FROM ", view))
      expect_equal(as.numeric(got$n), nrow(data), info = dataset)
      expect_equal(as.numeric(got$s), sum(as.numeric(data[[column]])), info = dataset)
    }
  }

  # BIGINT comes back as integer64; the SQL macro gives the hex of R.
  h3 <- DBI::dbGetQuery(con, 'SELECT h3, rcs_h3_hex(h3) AS hex FROM "shapes"."polygons__h3" ORDER BY h3')
  expect_s3_class(h3$h3, "integer64")
  expect_identical(h3$hex, rcs_h3_hex(h3$h3))
  poly <- DBI::dbGetQuery(con, 'SELECT h3, h3_p1, rcs_h3_hex(h3) AS hex FROM "shapes"."polygons" ORDER BY id')
  expect_s3_class(poly$h3_p1, "integer64")
  expect_identical(poly$hex, rcs_h3_hex(poly$h3))
  empties <- sum(sf::st_is_empty(dplyr::collect(store_open(st, "shapes/polygons"))))
  expect_gte(empties, 1L)
  expect_identical(sum(is.na(poly$h3_p1)), empties)
})

# (c) ----------------------------------------------------------------------------

test_that("datasets = upserts its rows only; datasets = NULL drops views of deleted datasets", {
  st <- duckdb_test_store()
  con <- local_duckdb()
  store_duckdb(st, con = con, datasets = "summary")
  expect_identical(duckdb_objects(con, "duckdb_views"), "main.summary")
  expect_identical(duckdb_rows(con, "rcs.views")$view, "main.summary")
  expect_identical(duckdb_rows(con, "rcs.store")$uri, store_uris(st))

  # A short name; the index table comes along.
  store_duckdb(st, con = con, datasets = "polygons")
  expect_identical(
    duckdb_objects(con, "duckdb_views"),
    c("main.summary", "shapes.polygons", "shapes.polygons__h3")
  )
  expect_identical(
    sort(duckdb_rows(con, "rcs.views")$view, method = "radix"),
    c("main.summary", "shapes.polygons", "shapes.polygons__h3")
  )

  # Deleted from the store: datasets = given drops nothing ...
  store_delete(st, "summary", confirm = "summary")
  store_duckdb(st, con = con, datasets = "sales/daily")
  expect_identical(duckdb_objects(con, "duckdb_views"), c(
    "main.summary", "sales.daily", "shapes.polygons", "shapes.polygons__h3"
  ))
  expect_identical(nrow(duckdb_rows(con, "rcs.views")), 4L)

  # ... datasets = NULL drops the view and its row.
  store_duckdb(st, con = con)
  expect_identical(duckdb_objects(con, "duckdb_views"), duckdb_test_views[-1])
  expect_identical(
    sort(duckdb_rows(con, "rcs.views")$view, method = "radix"),
    duckdb_test_views[-1]
  )
})

test_that("a second store on the same connection aborts", {
  st <- duckdb_test_store()
  other <- store_connect(withr::local_tempdir(), create = TRUE)
  store_write(other, rcs_sim_table(10, seed = 3), "other",
    title = "Other", description = "Simulated table."
  )
  con <- local_duckdb()
  store_duckdb(st, con = con)
  expect_error(store_duckdb(other, con = con), class = "rcs_error_duckdb")
  expect_snapshot(store_duckdb(other, con = con), error = TRUE, transform = function(x) {
    x <- gsub(st$primary$uri, "<primary>", x, fixed = TRUE)
    gsub(other$primary$uri, "<other>", x, fixed = TRUE)
  })
  expect_identical(duckdb_objects(con, "duckdb_views"), duckdb_test_views)
})

# (d) ----------------------------------------------------------------------------

test_that("duckdb_view_name() maps a dataset name to a schema and a table", {
  expect_identical(duckdb_view_name("sales/daily"), c(schema = "sales", table = "daily"))
  expect_identical(duckdb_view_name("a/b/c"), c(schema = "a", table = "b__c"))
  expect_identical(duckdb_view_name("x"), c(schema = "main", table = "x"))
  expect_identical(
    duckdb_view_name("shapes/polygons__h3"),
    c(schema = "shapes", table = "polygons__h3")
  )
})

test_that("view names that collide, schema rcs and database names abort before any view", {
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  withr::local_options(rcs.quiet = TRUE)
  small <- function(names) {
    st <- store_connect(withr::local_tempdir(.local_envir = parent.frame()), create = TRUE)
    for (n in names) {
      store_write(st, rcs_sim_table(5, seed = 1), n, title = "T", description = "Simulated table.")
    }
    st
  }
  cases <- list(
    collision_parts = c("a/b__c", "a/b/c"),
    collision_main = c("main/x", "x"),
    schema_rcs = "rcs/t",
    schema_database = "memory/t",
    schema_system = "system/t"
  )
  for (case in names(cases)) {
    st <- small(cases[[case]])
    con <- local_duckdb()
    expect_error(store_duckdb(st, con = con), class = "rcs_error_duckdb", info = case)
    expect_identical(duckdb_objects(con, "duckdb_views"), character(), info = case)
  }
  st <- small(c("a/b__c", "a/b/c"))
  con <- local_duckdb()
  expect_snapshot(store_duckdb(st, con = con), error = TRUE)
  st <- small("rcs/t")
  expect_snapshot(store_duckdb(st, con = con), error = TRUE)
  st <- small("memory/t")
  expect_snapshot(store_duckdb(st, con = con), error = TRUE)
})

test_that("a connection without bigint = 'integer64' and bad arguments abort", {
  st <- duckdb_test_store()
  con <- local_duckdb(bigint = "numeric")
  expect_error(store_duckdb(st, con = con), class = "rcs_error_duckdb")
  expect_snapshot(store_duckdb(st, con = con), error = TRUE)
  expect_identical(duckdb_objects(con, "duckdb_views"), character())
  expect_snapshot(store_duckdb(st, con = "not a connection"), error = TRUE)
  expect_snapshot(store_duckdb(st, datasets = "nothing"), error = TRUE)
  good <- local_duckdb()
  expect_snapshot(store_duckdb(st, path = "x.duckdb", con = good), error = TRUE)
  expect_snapshot(store_duckdb("not a store"), error = TRUE)
})

# (e) ----------------------------------------------------------------------------

test_that("store_tables() lists a store's datasets with their view names", {
  st <- duckdb_test_store()
  got <- store_tables(st)
  expected <- store_datasets(st)
  expect_identical(got[names(expected)], expected)
  expect_identical(names(got), c(names(expected), "duckdb_view"))
  expect_identical(got$duckdb_view, c("sales.daily", "shapes.polygons", "main.summary"))
})

test_that("store_tables() lists the views and user tables of a connection", {
  st <- duckdb_test_store()
  con <- local_duckdb()
  store_duckdb(st, con = con)
  DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
  DBI::dbExecute(con, "CREATE VIEW mine_view AS SELECT a FROM mine")

  got <- store_tables(con)
  expect_s3_class(got, "tbl_df")
  expect_identical(names(got), c("schema", "name", "type", "dataset", "version"))
  expect_identical(
    paste(got$schema, got$name, sep = "."),
    c("main.mine", "main.mine_view", "main.summary", "sales.daily", "shapes.polygons", "shapes.polygons__h3")
  )
  expect_identical(got$type, c("table", "view", "view", "view", "view", "view"))
  catalog <- st$primary$catalog
  expect_identical(got$dataset, c(NA, NA, "summary", "sales/daily", "shapes/polygons", "shapes/polygons__h3"))
  expect_identical(got$version, catalog$version[match(got$dataset, catalog$dataset)])

  with_st <- store_tables(con, st)
  expect_identical(names(with_st), c(names(got), "current"))
  expect_identical(with_st$current, c(NA, NA, TRUE, TRUE, TRUE, TRUE))

  # A new version of `summary` in the store: its view is behind.
  store_write(st, rcs_sim_table(60, seed = 4), "summary",
    title = "Summary", description = "Simulated table.", mode = "replace"
  )
  expect_identical(store_tables(con, st)$current, c(NA, NA, FALSE, TRUE, TRUE, TRUE))
})

test_that("store_tables() lists a plain DuckDB connection and rejects other input", {
  st <- duckdb_test_store()
  con <- local_duckdb()
  DBI::dbWriteTable(con, "mine", data.frame(a = 1:3))
  got <- store_tables(con, st)
  expect_identical(got$name, "mine")
  expect_identical(got$type, "table")
  expect_identical(got$dataset, NA_character_)
  expect_identical(got$version, NA_character_)
  expect_identical(got$current, NA)
  empty <- store_tables(local_duckdb())
  expect_identical(nrow(empty), 0L)
  expect_identical(names(empty), c("schema", "name", "type", "dataset", "version"))

  expect_error(store_tables(1), class = "rcs_error_argument")
  expect_error(store_tables(data.frame(a = 1)), class = "rcs_error_argument")
  expect_snapshot(store_tables(1), error = TRUE)
  expect_snapshot(store_tables(con, st = "x"), error = TRUE)
})

# (f) ----------------------------------------------------------------------------

test_that("native and arrow views work on the test bucket", {
  skip_below_level("full")
  uri <- Sys.getenv("RCS_TEST_GCS")
  skip_if(!nzchar(uri), "RCS_TEST_GCS is not set.")
  skip_if_not(arrow::arrow_with_gcs(), "Arrow is built without GCS.")
  skip_if_not_installed("gargle")
  skip_if_not_installed("httr2")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("DBI")
  con <- local_duckdb()
  httpfs <- function(sql) tryCatch(is.numeric(DBI::dbExecute(con, sql)), error = function(e) FALSE)
  if (!httpfs("LOAD httpfs")) {
    skip_if_offline()
    if (!httpfs("INSTALL httpfs") || !httpfs("LOAD httpfs")) {
      skip("The DuckDB httpfs extension cannot be installed or loaded.")
    }
  }
  before <- as.list(Sys.getenv())
  withr::local_options(rcs.quiet = TRUE)
  gcs_reset_clients()
  prefix <- paste0("rcs-test-", paste(sample(c(letters, 0:9), 12, TRUE), collapse = ""))
  be <- be_new(paste0(sub("/+$", "", uri), "/", prefix))
  withr::defer({
    left <- be_list(be)$path
    if (length(left) > 0) be_delete(be, left)
    expect_identical(be_list(be)$path, character())
  })
  store_create(be$uri)
  st <- store_connect(be$uri)
  store_write(st, rcs_sim_table(100, seed = 1), "sales/daily",
    title = "Daily", description = "Simulated table.", partition = "year"
  )
  store_write(st, rcs_sim_polygons(30, seed = 1), "shapes/polygons",
    title = "Polygons", description = "Simulated polygons.", partition = "h3", max_files = 3
  )

  store_duckdb(st, con = con)
  secrets <- DBI::dbGetQuery(con, "SELECT name, scope FROM duckdb_secrets()")
  expect_true(paste0("rcs_", md5_string(be$uri)) %in% secrets$name)
  con_arrow <- local_duckdb()
  store_duckdb(st, con = con_arrow, mode = "arrow")
  expect_identical(nrow(DBI::dbGetQuery(con_arrow, "SELECT name FROM duckdb_secrets()")), 0L)
  sums <- c("sales/daily" = "shop_id", "shapes/polygons" = "id", "shapes/polygons__h3" = "share")
  for (dataset in names(sums)) {
    view <- quoted_view(paste(duckdb_view_name(dataset), collapse = "."))
    data <- dplyr::collect(store_open(st, dataset))
    column <- sums[[dataset]]
    for (k in list(con, con_arrow)) {
      got <- DBI::dbGetQuery(k, paste0("SELECT count(*) AS n, sum(", column, ") AS s FROM ", view))
      expect_equal(as.numeric(got$n), nrow(data), info = dataset)
      expect_equal(as.numeric(got$s), sum(as.numeric(data[[column]])), info = dataset)
    }
  }
  expect_identical(as.list(Sys.getenv()), before)
})

# (g) ----------------------------------------------------------------------------

test_that("spatial = TRUE adds geom to geospatial views in arrow mode", {
  st <- duckdb_test_store()
  con <- local_duckdb_spatial()
  store_duckdb(st, con = con, mode = "arrow", spatial = TRUE)
  described <- DBI::dbGetQuery(con, 'DESCRIBE "shapes"."polygons"')
  expect_identical(utils::tail(described$column_name, 1), "geom")
  expect_match(described$column_type[described$column_name == "geom"], "^GEOMETRY")
  expect_identical(described$column_type[described$column_name == "geometry"], "BLOB")
  expect_false("geom" %in% DBI::dbGetQuery(con, 'DESCRIBE "sales"."daily"')$column_name)
  expect_false("geom" %in% DBI::dbGetQuery(con, 'DESCRIBE "shapes"."polygons__h3"')$column_name)
  got <- DBI::dbGetQuery(con, 'SELECT count(*) AS n FROM "shapes"."polygons" WHERE ST_IsEmpty(geom)')
  empties <- sum(sf::st_is_empty(dplyr::collect(store_open(st, "shapes/polygons"))))
  expect_equal(as.numeric(got$n), empties)

  # Native views carry GEOMETRY already; spatial adds no column.
  con_native <- local_duckdb_spatial()
  store_duckdb(st, con = con_native, spatial = TRUE)
  described <- DBI::dbGetQuery(con_native, 'DESCRIBE "shapes"."polygons"')
  expect_false("geom" %in% described$column_name)
  expect_match(described$column_type[described$column_name == "geometry"], "^GEOMETRY")
})
