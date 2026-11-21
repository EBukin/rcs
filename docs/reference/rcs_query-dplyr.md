# dplyr verbs for lazy queries

Methods of the dplyr generics for queries made by
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md).
The verbs are applied by Arrow when the query runs; `collect()` returns
R data (see
[`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md)),
`compute()` keeps the rows in memory as Arrow data and returns a query
on them, `pull()` collects one column, and `glimpse()` collects the
first rows and shows them.

## Usage

``` r
# S3 method for class 'rcs_query'
filter(.data, ..., .by = NULL, .preserve = FALSE)

# S3 method for class 'rcs_query'
select(.data, ...)

# S3 method for class 'rcs_query'
mutate(.data, ...)

# S3 method for class 'rcs_query'
rename(.data, ...)

# S3 method for class 'rcs_query'
arrange(.data, ..., .by_group = FALSE)

# S3 method for class 'rcs_query'
distinct(.data, ..., .keep_all = FALSE)

# S3 method for class 'rcs_query'
head(x, n = 6L, ...)

# S3 method for class 'rcs_query'
collect(x, ...)

# S3 method for class 'rcs_query'
compute(x, ...)

# S3 method for class 'rcs_query'
pull(.data, var = -1, name = NULL, ...)

# S3 method for class 'rcs_query'
glimpse(x, width = NULL, ...)
```

## Arguments

- .data, x:

  A query made by
  [`store_open()`](https://ebukin.github.io/rcs/reference/store_open.md).

- ...:

  Arguments of the dplyr verb.

- .by, .preserve, .by_group, .keep_all, width, var, name, n:

  As in dplyr.

## Value

`collect()`: a tibble or an `sf` object. `pull()`: a vector.
`glimpse()`: `x`, invisibly. Every other verb: an `rcs_query`.

## Details

A filter on partition columns opens only the files of the matching
partitions when it comes before any other verb that changes those
columns. A pending spatial filter
([`store_intersects()`](https://ebukin.github.io/rcs/reference/store_intersects.md))
applies to the rows of the dataset; its exact test runs in `collect()`
on the rows the query returns, so a
[`head()`](https://rdrr.io/r/utils/head.html) before `collect()` may
give fewer rows than asked for.
