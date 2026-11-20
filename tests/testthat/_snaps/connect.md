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
      store_connect("gs://example-bucket/store")
    Condition
      Error in `store_connect()`:
      ! Cannot reach the primary location 'gs://example-bucket/store'.
      i Arrow (reading and transfers) uses Google's default credentials: `GOOGLE_APPLICATION_CREDENTIALS` (a service-account key file), or `gcloud auth application-default login`.
      i The JSON API (MD5 of stored files) uses the same credentials through gargle with the scope "cloud-platform"; it needs the packages gargle and httr2.
      i GDAL (`/vsigs/`, rasters) does not find the credentials of `gcloud auth application-default login` by itself: set `GOOGLE_APPLICATION_CREDENTIALS` to a service-account key or to that credentials file, or set `GS_OAUTH2_REFRESH_TOKEN`, `GS_OAUTH2_CLIENT_ID` and `GS_OAUTH2_CLIENT_SECRET`.
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

