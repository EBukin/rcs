# resolve_dataset() messages are stable

    Code
      resolve_dataset(st, "weekly")
    Condition
      Error:
      ! The name "weekly" is ambiguous.
      i It is the last part of "sales/weekly" and "other/weekly"; use the full name.
    Code
      resolve_dataset(st, "polygon")
    Condition
      Error:
      ! No dataset "polygon" in the store.
      i Closest names: "polygons" and "shapes/polygons".

# choose_location() is quiet with rcs.quiet and checks the dataset

    Code
      withr::with_options(list(rcs.quiet = FALSE), invisible(choose_location(st,
        "sales/daily")))
    Message
      i Reading "sales/daily" from secondary <tempdir>/second.

