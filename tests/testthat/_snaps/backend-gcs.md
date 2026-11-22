# be_auth_hint() names the credential in use and how to pass another

    Code
      cli::cli_abort(c("Cannot reach the location.", hint))
    Condition
      Error:
      ! Cannot reach the location.
      i Credentials in use: an access token given to rcs_auth_gcs(token = ), not renewed.
      i Pass other credentials with `auth` of `store_connect()` or `store_create()`: a key file path, `rcs_auth_gcs(key = )`, `rcs_auth_gcs(token = )` or `rcs_auth_gcs(fun = )`.
      i Without `auth`, the default lookup uses `GOOGLE_APPLICATION_CREDENTIALS`, else the login of `gcloud auth application-default login`; see `rcs_auth_gcs()`.

