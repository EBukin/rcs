# be_auth_hint() names each client

    Code
      cli::cli_abort(c("Cannot reach the location.", hint))
    Condition
      Error:
      ! Cannot reach the location.
      i Arrow (reading and transfers) uses Google's default credentials: `GOOGLE_APPLICATION_CREDENTIALS` (a service-account key file), or `gcloud auth application-default login`.
      i The JSON API (MD5 of stored files) uses the same credentials through gargle with the scope "cloud-platform"; it needs the packages gargle and httr2.
      i GDAL (`/vsigs/`, rasters) does not find the credentials of `gcloud auth application-default login` by itself: set `GOOGLE_APPLICATION_CREDENTIALS` to a service-account key or to that credentials file, or set `GS_OAUTH2_REFRESH_TOKEN`, `GS_OAUTH2_CLIENT_ID` and `GS_OAUTH2_CLIENT_SECRET`.

