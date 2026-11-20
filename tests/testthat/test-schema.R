example_entry <- function(dataset = "shapes/polygons", ...) {
  args <- utils::modifyList(
    list(
      dataset = dataset, kind = "geospatial",
      title = "Polygons", description = "Simulated polygons.",
      version = "0123456789abcdef", n_files = 2, rows = 10, bytes = 2048,
      columns = columns_to_json(columns_spec("id", "int32")),
      key = "id", sorted_by = c("h3", "id"), partition = "h3_p2",
      crs = "{\"type\":\"GeographicCRS\"}",
      bbox = c(xmin = -30, ymin = 6, xmax = -24, ymax = 9),
      h3_res = 5L, history = TRUE,
      created = as.POSIXct("2026-01-02 03:04:05.123456", tz = "UTC")
    ),
    list(...)
  )
  do.call(new_entry, args)
}

example_files <- function(dataset = "shapes/polygons", version = "0123456789abcdef") {
  values <- c(partition_values_json(list(h3_p2 = "a")), partition_values_json(list(h3_p2 = "b")))
  new_file_rows(
    dataset = dataset, version = version,
    path = c(
      data_file_path(dataset, version, list(h3_p2 = "a")),
      data_file_path(dataset, version, list(h3_p2 = "b"))
    ),
    partition_values = values,
    rows = c(4, 6), bytes = c(1000, 1048),
    md5 = c("d41d8cd98f00b204e9800998ecf8427e", "9e107d9d372bb6826bd81d3542a419d6"),
    bbox = bbox_df(c(-30, -27), c(6, 6), c(-27, -24), c(9, 9)),
    # cells of resolution 5: far above 2^53
    h3_min = bit64::as.integer64(c("599686042433355775", "599686043507097599")),
    h3_max = bit64::as.integer64(c("599686043507097599", "599686044580839423")),
    created = as.POSIXct("2026-01-02 03:04:05.123456", tz = "UTC")
  )
}

test_that("the catalog schema has the columns of the plan", {
  expect_identical(
    names(catalog_schema()),
    c(
      "dataset", "kind", "title", "description", "source", "inputs", "key",
      "sorted_by", "partition", "columns", "version", "n_files", "rows", "bytes",
      "crs", "bbox", "h3_res", "index_of", "history", "writer", "r_version",
      "rcs_version", "created", "updated"
    )
  )
  types <- vapply(catalog_schema()$fields, function(f) f$type$ToString(), character(1))
  names(types) <- names(catalog_schema())
  expect_identical(types[["key"]], "list<item: string>")
  expect_identical(types[["rows"]], "int64")
  expect_identical(types[["h3_res"]], "int32")
  expect_identical(types[["history"]], "bool")
  expect_identical(types[["created"]], "timestamp[us, tz=UTC]")
  expect_identical(
    types[["bbox"]],
    "struct<xmin: double, ymin: double, xmax: double, ymax: double>"
  )
})

test_that("the files and history schemas have the columns of the plan", {
  expect_identical(
    names(files_schema()),
    c(
      "dataset", "version", "path", "partition_values", "rows", "bytes", "md5",
      "bbox", "h3_min", "h3_max", "created"
    )
  )
  expect_identical(names(history_schema()), c(names(files_schema()), "replaced"))
  expect_identical(history_schema()$GetFieldByName("replaced")$type$ToString(), "timestamp[us, tz=UTC]")
  expect_identical(files_schema()$GetFieldByName("h3_min")$type$ToString(), "int64")
  expect_true(schema_get("files")$Equals(files_schema()))
  expect_true(schema_get("catalog")$Equals(catalog_schema()))
  expect_true(schema_get("history")$Equals(history_schema()))
  expect_error(schema_get("other"))
})

test_that("empty tables are valid and have the schema's columns", {
  for (which in c("catalog", "files", "history")) {
    empty <- schema_empty(which)
    expect_equal(nrow(empty), 0)
    expect_identical(names(empty), names(schema_get(which)))
    expect_no_error(schema_validate(empty, which))
    expect_true(schema_as_arrow(empty, which)$schema$Equals(schema_get(which)))
  }
  expect_identical(catalog_empty(), schema_empty("catalog"))
  expect_identical(files_empty(), schema_empty("files"))
  expect_identical(history_empty(), schema_empty("history"))
})

test_that("new_entry() builds a valid row with the documented types", {
  entry <- example_entry()
  expect_equal(nrow(entry), 1)
  expect_no_error(schema_validate(entry, "catalog"))
  expect_s3_class(entry$rows, "integer64")
  expect_identical(entry$key, list("id"))
  expect_identical(entry$partition, list("h3_p2"))
  expect_identical(entry$bbox$xmax, -24)
  expect_identical(entry$updated, entry$created)
  expect_identical(entry$r_version, as.character(getRversion()))
  expect_identical(entry$rcs_version, as.character(utils::packageVersion("rcs")))

  plain <- example_entry("sales", kind = "table", key = character(), bbox = NULL, crs = NA, h3_res = NA, history = NA)
  expect_identical(plain$key, list(character()))
  expect_true(all(is.na(plain$bbox)))
  expect_true(is.na(plain$history))
  expect_true(is.na(plain$crs))
})

test_that("new_entry() records the writer only when asked", {
  expect_true(is.na(example_entry()$writer))
  withr::local_options(rcs.record_writer = TRUE)
  expect_identical(example_entry()$writer, Sys.info()[["user"]])
})

test_that("new_entry() rejects invalid values", {
  expect_error(example_entry("Sales"), class = "rcs_error_dataset_name")
  expect_error(example_entry("sales__h3"), class = "rcs_error_dataset_name")
  expect_no_error(example_entry("sales__h3", kind = "table", index_of = "sales"))
  expect_error(example_entry(kind = "image"))
  expect_error(example_entry(title = ""), class = "rcs_error_argument")
  expect_error(example_entry(description = NA_character_), class = "rcs_error_argument")
  expect_error(example_entry(version = "xyz"), class = "rcs_error_schema")
})

test_that("new_file_rows() builds valid rows and refuses numeric cells", {
  files <- example_files()
  expect_equal(nrow(files), 2)
  expect_no_error(schema_validate(files, "files"))
  expect_identical(files$dataset, rep("shapes/polygons", 2))
  expect_identical(
    files$path[[1]],
    "shapes/polygons/h3_p2=a/part-0123456789abcdef.parquet"
  )
  one <- new_file_rows("sales", "0123456789abcdef", "sales/part-0123456789abcdef.parquet",
    "{}", 5, 100, "d41d8cd98f00b204e9800998ecf8427e")
  expect_true(is.na(one$h3_min))
  expect_true(all(is.na(one$bbox)))
  expect_error(
    new_file_rows("sales", "0123456789abcdef", "p", "{}", 5, 100, "d41d8cd98f00b204e9800998ecf8427e",
      h3_min = 599686042433355775, h3_max = 599686042433355775),
    class = "rcs_error_argument"
  )
})

test_that("schema_validate() names what is wrong", {
  entry <- example_entry()
  expect_error(schema_validate(list(), "catalog"), class = "rcs_error_schema")
  expect_error(schema_validate(entry[-1], "catalog"), class = "rcs_error_schema")
  expect_error(schema_validate(entry[rev(names(entry))], "catalog"), class = "rcs_error_schema")

  wrong_type <- entry
  wrong_type$rows <- 10
  expect_error(schema_validate(wrong_type, "catalog"), "rows", class = "rcs_error_schema")
  wrong_list <- entry
  wrong_list$key <- list(1)
  expect_error(schema_validate(wrong_list, "catalog"), "key", class = "rcs_error_schema")
  wrong_zone <- entry
  wrong_zone$created <- as.POSIXct("2026-01-01", tz = "")
  expect_error(schema_validate(wrong_zone, "catalog"), "created", class = "rcs_error_schema")
  wrong_kind <- entry
  wrong_kind$kind <- "image"
  expect_error(schema_validate(wrong_kind, "catalog"), "kind", class = "rcs_error_schema")

  twice <- vctrs::vec_rbind(entry, entry)
  expect_error(schema_validate(twice, "catalog"), "unique", class = "rcs_error_schema")

  files <- example_files()
  expect_error(
    schema_validate(vctrs::vec_rbind(files, files), "files"),
    "twice", class = "rcs_error_schema"
  )
  no_md5 <- files
  no_md5$md5[[1]] <- NA
  expect_error(schema_validate(no_md5, "files"), "md5", class = "rcs_error_schema")
  expect_error(schema_validate(files, "history"), class = "rcs_error_schema")
})

test_that("catalog tables survive Parquet unchanged", {
  catalog <- vctrs::vec_rbind(
    example_entry(),
    example_entry("sales", kind = "table", key = character(), bbox = NULL, crs = NA, h3_res = NA, history = NA)
  )
  files <- example_files()
  history <- files
  history$replaced <- as.POSIXct("2026-02-03 04:05:06.654321", tz = "UTC")
  tables <- list(catalog = catalog, files = files, history = history)

  for (which in names(tables)) {
    path <- withr::local_tempfile(fileext = ".parquet")
    arrow::write_parquet(schema_as_arrow(tables[[which]], which), path)
    read <- arrow::read_parquet(path, as_data_frame = FALSE)
    expect_true(read$schema$Equals(schema_get(which)))
    expect_identical(schema_as_tibble(read, which), tables[[which]])
  }
})

test_that("small int64 values stay integer64 and cells keep every digit", {
  files <- example_files()
  path <- withr::local_tempfile(fileext = ".parquet")
  arrow::write_parquet(schema_as_arrow(files, "files"), path)
  back <- schema_as_tibble(arrow::read_parquet(path, as_data_frame = FALSE), "files")
  expect_s3_class(back$rows, "integer64")
  expect_identical(as.character(back$h3_min), c("599686042433355775", "599686043507097599"))
})

test_that("schema_as_tibble() accepts extra columns in any order and rejects missing ones", {
  files <- example_files()
  shuffled <- as.data.frame(files[rev(names(files))])
  shuffled$extra <- 1
  expect_identical(schema_as_tibble(shuffled, "files"), files)
  expect_error(schema_as_tibble(files[-3], "files"), "path", class = "rcs_error_schema")
})

test_that("the columns specification round-trips with every r_type", {
  spec <- columns_spec(
    name = c("id", "wait", "big", "product", "grade", "tags", "empty", "height"),
    type = c("int32", "duration[s]", "int64", "dictionary<values=string, indices=int8>",
      "dictionary<values=string, indices=int8, ordered>", "list<item: string>",
      "dictionary<values=string, indices=int8>", "double"),
    r_type = list(
      NULL,
      list(class = "difftime", units = "hours"),
      list(class = "integer64"),
      list(class = "factor", levels = c("p01", "p02"), ordered = FALSE),
      list(class = "factor", levels = "only", ordered = TRUE),
      list(class = "list"),
      list(class = "factor", levels = character(), ordered = FALSE),
      list(class = "SpatRaster", resolution = c(0.006, 0.003), dim = c(1000L, 1000L))
    ),
    description = c("Identifier", NA, NA, "Product code", NA, NA, NA, NA)
  )
  json <- columns_to_json(spec)
  expect_type(json, "character")
  expect_length(json, 1)
  expect_identical(columns_from_json(json), spec)
  expect_identical(columns_to_json(columns_from_json(json)), json)

  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_null(parsed[[1]]$r_type)
  expect_null(parsed[[2]]$description)
  expect_identical(parsed[[5]]$r_type$levels, list("only"))

  empty <- columns_spec()
  expect_identical(columns_from_json(columns_to_json(empty)), empty)
  expect_error(columns_spec("a", c("x", "y")))
})

test_that("the embedded metadata leaves out what changes between writes", {
  entry <- example_entry()
  json <- entry_metadata_json(entry)
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_false(any(c("version", "n_files", "rows", "bytes", "writer", "created", "updated") %in% names(parsed)))
  expect_identical(parsed$dataset, "shapes/polygons")
  expect_identical(parsed$key, list("id"))
  expect_identical(parsed$bbox$xmin, -30L)

  later <- example_entry(
    version = "fedcba9876543210", rows = 99, n_files = 7, bytes = 1,
    created = as.POSIXct("2027-01-01", tz = "UTC")
  )
  expect_identical(entry_metadata_json(later), json)
  expect_false(identical(entry_metadata_json(example_entry(title = "Other")), json))

  back <- entry_from_metadata_json(json)
  expect_identical(names(back), names(entry))
  kept <- setdiff(names(entry), c("version", "n_files", "rows", "bytes", "writer", "created", "updated"))
  expect_identical(back[kept], entry[kept])
  expect_true(is.na(back$version))
  expect_true(is.na(back$rows))
})

test_that("a manifest round-trips through JSON", {
  manifest <- new_manifest(
    example_entry(), example_files(),
    written = as.POSIXct("2026-03-04 05:06:07.000001", tz = "UTC")
  )
  expect_s3_class(manifest, "rcs_manifest")
  json <- manifest_to_json(manifest)
  expect_identical(manifest_from_json(json), manifest)

  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_named(parsed, c("entry", "files", "written"))
  expect_identical(parsed$written, "2026-03-04T05:06:07.000001Z")
  expect_identical(parsed$entry$rows, "10")
  expect_identical(parsed$files[[1]]$h3_min, "599686042433355775")
  expect_identical(parsed$entry$created, "2026-01-02T03:04:05.123456Z")
  expect_type(parsed$entry$columns, "character")
})

test_that("a manifest keeps missing values", {
  entry <- example_entry("sales", kind = "table", key = character(), sorted_by = character(),
    partition = character(), bbox = NULL, crs = NA, h3_res = NA, history = NA, n_files = 1)
  files <- new_file_rows("sales", entry$version, data_file_path("sales", entry$version),
    "{}", 10, 2048, "d41d8cd98f00b204e9800998ecf8427e",
    created = as.POSIXct("2026-01-02 03:04:05", tz = "UTC"))
  manifest <- new_manifest(entry, files, written = as.POSIXct("2026-03-04 05:06:07", tz = "UTC"))
  expect_identical(manifest_from_json(manifest_to_json(manifest)), manifest)
})

test_that("a manifest must be consistent", {
  entry <- example_entry()
  expect_error(new_manifest(entry, example_files(version = "aaaaaaaaaaaaaaaa")), class = "rcs_error_schema")
  expect_error(new_manifest(entry, example_files(dataset = "other")), class = "rcs_error_schema")
  expect_error(new_manifest(entry[0, ], example_files()[0, ]), class = "rcs_error_schema")
  expect_error(new_manifest(entry, example_files()[-1]), class = "rcs_error_schema")
})

test_that("bbox_df() and bbox_na() give the struct's columns", {
  expect_identical(names(bbox_df(1, 2, 3, 4)), c("xmin", "ymin", "xmax", "ymax"))
  expect_type(bbox_df(1L, 2L, 3L, 4L)$xmin, "double")
  expect_equal(nrow(bbox_na(3)), 3)
  expect_true(all(is.na(bbox_na(3))))
})
