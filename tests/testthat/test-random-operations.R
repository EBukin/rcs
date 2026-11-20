# The random-operation test (plan, "Testing"): seeded sequences of
# operations (create, replace, update, delete, sync, copy, prune, rebuild,
# injected failures, the history setting switched at the store, connection
# and dataset level) on a primary and two secondaries, checked after every
# step against a plain in-memory model: the invariants hold, every location
# lists the datasets of the model, and store_read() of every dataset from
# every location equals the model. A failing run prints its seed and its
# operations; `random_sequence(seed, n_ops)` (helper-model.R) replays it.
#
# Level default runs a few short sequences; level full runs sequences of 50
# operations.

skip_below_level("default")

test_that("short random sequences of operations agree with the model", {
  skip_if(identical(test_level(), "full"), "Level full runs the long sequences.")
  g_no_wait()
  for (seed in c(11L, 12L)) {
    log <- random_sequence(seed, n_ops = 6L)
    expect_length(log, 6L)
  }
})

test_that("random sequences of 50 operations agree with the model", {
  skip_below_level("full")
  g_no_wait()
  for (seed in c(1L, 2L, 3L, 4L)) {
    random_sequence(seed, n_ops = 50L)
  }
})
