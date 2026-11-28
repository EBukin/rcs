test_location <- function(name, ...) {
  new_location(file.path(tempdir(), "rcs-objects", name), ...)
}

test_that("new_location() builds a valid location with empty catalogs", {
  location <- test_location("a")
  expect_s3_class(location, "rcs_location")
  expect_named(location, c("uri", "backend", "catalog", "files", "token", "available"))
  expect_identical(location$uri, location$backend$uri)
  expect_identical(location$backend$type, "local")
  expect_identical(location$catalog, catalog_empty())
  expect_identical(location$files, files_empty())
  expect_true(is.na(location$token))
  expect_true(location$available)

  remote <- new_location("gs://bucket/store", available = FALSE)
  expect_identical(remote$backend$type, "gcs")
  expect_false(remote$available)
})

test_that("validate_location() rejects malformed objects", {
  location <- test_location("a")
  expect_invisible(validate_location(location))
  expect_error(validate_location(unclass(location)), class = "rcs_error_object")
  expect_error(validate_location("gs://bucket"), class = "rcs_error_object")
  broken <- location
  broken$available <- NA
  expect_error(validate_location(broken), class = "rcs_error_object")
  broken <- location
  broken$token <- NULL
  expect_error(validate_location(broken), class = "rcs_error_object")
  broken <- location
  broken$catalog <- tibble::tibble(dataset = "a")
  expect_error(validate_location(broken), class = "rcs_error_schema")
  expect_error(new_location("s3://bucket"), class = "rcs_error_unsupported_location")
})

test_that("new_store() holds the documented fields", {
  primary <- test_location("a")
  st <- new_store(primary, list(test_location("b"), test_location("c")))
  expect_s3_class(st, "rcs_store")
  expect_true(is.environment(st))
  expect_setequal(ls(st), c("primary", "secondary", "history", "store_history", "connected_at", "copy_on_read"))
  expect_identical(st$primary, primary)
  expect_length(st$secondary, 2)
  expect_null(st$history)
  expect_false(st$store_history)
  expect_identical(attr(st$connected_at, "tzone"), "UTC")
  expect_identical(new_store(primary)$secondary, list())
  expect_null(names(new_store(primary, list(x = test_location("b")))$secondary))
})

test_that("validate_store() rejects malformed connections", {
  primary <- test_location("a")
  expect_invisible(validate_store(new_store(primary)))
  st <- "not a store"
  expect_error(validate_store(st), "store_connect", class = "rcs_error_object")
  expect_error(validate_store(list(primary = primary)), class = "rcs_error_object")
  expect_error(new_store(test_location("a", available = FALSE)), "not available", class = "rcs_error_object")
  expect_error(new_store(primary, list(test_location("a"))), "twice", class = "rcs_error_object")
  expect_error(new_store(primary, list("b")), class = "rcs_error_object")
  expect_error(new_store(primary, test_location("b")), class = "rcs_error_object")
  expect_error(new_store(primary, history = NA), "history", class = "rcs_error_object")
  expect_error(new_store(primary, store_history = NULL), "store_history", class = "rcs_error_object")
  expect_error(new_store(primary, connected_at = "now"), "connected_at", class = "rcs_error_object")
})

test_that("store_locations() lists the primary first", {
  st <- new_store(
    test_location("a"),
    list(test_location("b", available = FALSE), test_location("c"))
  )
  uris <- store_uris(st)
  expect_length(uris, 3)
  expect_identical(vapply(store_locations(st), function(l) l$uri, character(1)), uris)
  expect_identical(
    vapply(store_locations(st, available_only = TRUE), function(l) l$uri, character(1)),
    uris[c(1, 3)]
  )
  expect_identical(store_locations(new_store(test_location("a")))[[1]]$uri, uris[[1]])
})

test_that("store_set_location() changes the connection in place", {
  st <- new_store(test_location("a"), list(test_location("b"), test_location("c")))
  same <- st
  change <- function(connection) {
    updated <- connection$secondary[[2]]
    updated$token <- "d41d8cd98f00b204e9800998ecf8427e"
    store_set_location(connection, updated)
  }
  expect_invisible(change(st))
  expect_identical(same$secondary[[2]]$token, "d41d8cd98f00b204e9800998ecf8427e")
  expect_true(is.na(same$secondary[[1]]$token))

  primary <- st$primary
  primary$token <- "9e107d9d372bb6826bd81d3542a419d6"
  store_set_location(st, primary)
  expect_identical(same$primary$token, "9e107d9d372bb6826bd81d3542a419d6")
  expect_no_error(validate_store(st))

  expect_error(store_set_location(st, test_location("z")), "not a location", class = "rcs_error_object")
  expect_error(store_set_location(st, "b"), class = "rcs_error_object")
})

test_that("the dataset's history setting wins, then the connection's, then the store's", {
  primary <- test_location("a")
  cases <- expand.grid(
    store = c(FALSE, TRUE), connection = c(NA, FALSE, TRUE), dataset = c(NA, FALSE, TRUE)
  )
  for (i in seq_len(nrow(cases))) {
    case <- cases[i, ]
    st <- new_store(
      primary,
      history = if (is.na(case$connection)) NULL else case$connection,
      store_history = case$store
    )
    expected <- if (!is.na(case$dataset)) {
      case$dataset
    } else if (!is.na(case$connection)) {
      case$connection
    } else {
      case$store
    }
    expect_identical(effective_history(st, case$dataset), expected)
  }
  expect_false(effective_history(new_store(primary)))
})

test_that("new_query() builds a valid query", {
  st <- new_store(test_location("a"))
  entry <- new_entry(
    "sales", "table", "Sales", "Simulated sales.", "0123456789abcdef",
    n_files = 1, rows = 3, bytes = 100, columns = "[]"
  )
  files <- new_file_rows(
    "sales", entry$version, data_file_path("sales", entry$version), "{}",
    3, 100, "d41d8cd98f00b204e9800998ecf8427e"
  )
  table <- arrow::arrow_table(x = 1:3)
  query <- new_query(st, entry, st$primary, files, table)
  expect_s3_class(query, "rcs_query")
  expect_named(query, c("store", "entry", "location", "files", "query", "spatial", "geometry"))
  expect_null(query$spatial)
  expect_true(query$geometry)
  expect_identical(query$store, st)
  expect_invisible(validate_query(query))

  lazy <- new_query(st, entry, st$primary, files, dplyr::filter(table, x > 1), geometry = FALSE)
  expect_s3_class(lazy$query, "arrow_dplyr_query")

  expect_error(new_query(st, entry, st$primary, files, data.frame(x = 1)), "store_open", class = "rcs_error_object")
  expect_error(new_query(list(), entry, st$primary, files, table), class = "rcs_error_object")
  expect_error(new_query(st, entry[0, ], st$primary, files, table), class = "rcs_error_object")
  expect_error(new_query(st, entry, st$primary, files, table, spatial = "x"), class = "rcs_error_object")
  expect_error(new_query(st, entry, st$primary, files[-1], table), class = "rcs_error_schema")
  expect_error(validate_query(unclass(query)), class = "rcs_error_object")
})
