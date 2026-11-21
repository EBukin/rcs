# Work counters of the last call

With `options(rcs.trace = TRUE)` the package records the work done by
each call of one of its functions: backend calls, catalog files read,
data files opened, row groups, candidate and returned rows, and bytes
transferred. `rcs_trace()` returns the records of the last call;
`rcs_trace_reset()` clears them. Counting is deterministic and costs
nothing when the option is off.

## Usage

``` r
rcs_trace()

rcs_trace_reset()
```

## Value

`rcs_trace()` returns a tibble with one row per counter, detail and
location:

- `call`: the function that was called, `NA` for work done outside one;

- `counter`: `backend_call`, `catalog_read`, `file_open`,
  `row_groups_total`, `row_groups_overlap`, `rows_candidate`,
  `rows_returned`, `bytes_up` or `bytes_down`;

- `detail`: the backend operation, the catalog file or the data file;

- `location`: the address of the location, `NA` when there is none;

- `n`: the count.

It has zero rows when nothing was recorded. `rcs_trace_reset()` returns
`NULL`, invisibly.

## Examples

``` r
withr::with_options(list(rcs.trace = TRUE), {
  rcs_trace_reset()
  rcs_trace()
})
#> # A tibble: 0 × 5
#> # ℹ 5 variables: call <chr>, counter <chr>, detail <chr>, location <chr>,
#> #   n <dbl>
```
