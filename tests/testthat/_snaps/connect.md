# a missing primary aborts naming the environment variables

    Code
      store_connect(env = "MINE")
    Condition
      Error in `store_connect()`:
      ! No primary location given.
      i Pass `primary`, or set the environment variable `MINE_PRIMARY` (and `MINE_SECONDARY` for secondary locations, separated by `;`).

# arguments are checked

    Code
      store_connect(1)
    Condition
      Error in `store_connect()`:
      ! `primary` must be a single non-empty string, not a number.
    Code
      store_connect("a", secondary = c("b", NA))
    Condition
      Error in `store_connect()`:
      ! `secondary` must be a character vector of addresses without missing or empty values, not a character vector.
    Code
      store_connect("a", history = "yes")
    Condition
      Error in `store_connect()`:
      ! `history` must be `TRUE` or `FALSE`, not a string.
    Code
      store_connect("a", create = NA)
    Condition
      Error in `store_connect()`:
      ! `create` must be `TRUE` or `FALSE`, not `NA`.
    Code
      store_connect("s3://bucket/store")
    Condition
      Error in `be_new()`:
      ! Locations of the form "s3://" are not supported yet.
      i Use a local folder or "gs://bucket/prefix".

# a location named twice aborts

    Code
      store_connect(dir, secondary = paste0(dir, "/"))
    Condition
      Error in `store_connect()`:
      ! The location '<root>' is named twice.

# a location without catalogs aborts unless create = TRUE

    Code
      store_connect(primary)
    Condition
      Error in `store_connect()`:
      ! The primary location '<root>/new' holds no store catalogs.
      i Initialise it with `store_create()` or connect with `create = TRUE`.

---

    Code
      store_connect(primary, secondary)
    Condition
      Error in `store_connect()`:
      ! The secondary location '<root>/copy' holds no store catalogs.
      i Initialise it with `store_create()` or connect with `create = TRUE`.

# an unreachable secondary warns and is marked unavailable

    Code
      st <- store_connect(fx$primary, fx$secondary)
    Condition
      Warning:
      The secondary location '<root>/secondary1' is not available; it is skipped.
      i Run `store_refresh()` to try it again.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call 1 (be_exists).

# an unreachable primary aborts with the authentication hint

    Code
      store_connect(fx$primary)
    Condition
      Error in `store_connect()`:
      ! Cannot reach the primary location '<root>/primary'.
      i Local folder '<root>/primary': the session needs read and write permission on it.
      Caused by error in `abort_stub()`:
      ! Injected failure at backend call 1 (be_exists).

# an unreachable primary on GCS aborts with the hint of every client

    Code
      store_connect("gs://example-bucket/store", auth = rcs_auth_gcs(token = "some-token"))
    Condition
      Error in `store_connect()`:
      ! Cannot reach the primary location 'gs://example-bucket/store'.
      i Credentials in use: an access token given to rcs_auth_gcs(token = ), not renewed.
      i Pass other credentials with `auth` of `store_connect()` or `store_create()`: a key file path, `rcs_auth_gcs(key = )`, `rcs_auth_gcs(token = )` or `rcs_auth_gcs(fun = )`.
      i Without `auth`, the default lookup uses `GOOGLE_APPLICATION_CREDENTIALS`, else the login of `gcloud auth application-default login`; see `rcs_auth_gcs()`.
      Caused by error in `location_exists()`:
      ! Injected: no route to the bucket.

# store_create() initialises an empty store once

    Code
      uri <- store_create(location, history = TRUE)
    Message
      v Created an empty store in '<root>/store'.

---

    Code
      store_create(location)
    Condition
      Error in `store_create()`:
      ! '<root>/store' already holds a store.
      i Connect to it with `store_connect()`.

# store_refresh() marks a secondary unavailable when it cannot be reached

    Code
      store_refresh(st)
    Condition
      Warning:
      The secondary location '<root>/secondary2' is not available; it is skipped.
      i It holds no store catalogs.
      i Run `store_refresh()` to try it again.

# store_connect() announces an empty secondary of a non-empty primary, once

    Code
      again <- store_connect(fx$primary, secondary = empty)
    Message
      i Secondary '<root>/empty' is empty.
        Use `store_sync(st, all = TRUE)` to copy every dataset, or `store_sync(st, datasets = )` to copy some.

# auth = is checked

    Code
      store_connect("gs://bucket/store", auth = 1)
    Condition
      Error in `store_connect()`:
      ! `auth` must be `NULL`, an object made by `rcs_auth_gcs()` or the path of a key file, not a number.
    Code
      store_connect("gs://bucket/store", auth = list("gs://bucket/store", "x"))
    Condition
      Error in `store_connect()`:
      ! A list given to `auth` must be named by address.
    Code
      store_connect("gs://bucket/store", auth = list(`gs://other/store` = "key.json"))
    Condition
      Error in `store_connect()`:
      ! `auth` names an address not given in the call: "gs://other/store".
      i Name each credential by its address exactly as given to `primary` or `secondary`.
    Code
      store_connect("gs://bucket/store", auth = list(`gs://bucket/store` = 1))
    Condition
      Error in `store_connect()`:
      ! `auth[["gs://bucket/store"]]` must be `NULL`, an object made by `rcs_auth_gcs()` or the path of a key file, not a number.
    Code
      store_create("gs://bucket/store", auth = TRUE)
    Condition
      Error in `store_create()`:
      ! `auth` must be `NULL`, an object made by `rcs_auth_gcs()` or the path of a key file, not `TRUE`.

