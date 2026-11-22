# Credentials for Google Cloud Storage

Describes how the package reaches Google Cloud Storage. Pass the result
(or a key file path) to the `auth` argument of
[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md)
or
[`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md);
without `auth`, every Google Cloud Storage location uses
`rcs_auth_gcs()`, the default lookup.

## Usage

``` r
rcs_auth_gcs(key = NULL, token = NULL, fun = NULL)

# S3 method for class 'rcs_auth_gcs'
print(x, ...)
```

## Arguments

- key:

  Path to a JSON key file of type `"service_account"` or
  `"authorized_user"` (such as the file written by
  `gcloud auth application-default login`).

- token:

  An OAuth access token with the scope `cloud-platform`. Not renewed.

- fun:

  A function of no arguments returning an access token, or a list with
  `access_token` and `expires_in` (seconds). Called again when the token
  it gave is about to expire.

- x:

  An `rcs_auth_gcs` object.

- ...:

  Ignored.

## Value

An object of class `rcs_auth_gcs`: a list with `source`, `type` (the key
file's type, or `NA`), `file` (or `NA`) and the environment `cache`.
Aborts with class `rcs_error_argument` for invalid arguments and with
`rcs_error_backend` for a missing or unusable key file.
[`print()`](https://rdrr.io/r/base/print.html) shows the source, type,
file, identity and validity of the token, and returns `x` invisibly.

## Details

Give at most one of `key`, `token` and `fun`. With none, the default
lookup is a chain in which the first variable that is set decides:

1.  when the environment variable `GOOGLE_APPLICATION_CREDENTIALS` is
    set, the file it names and only that file (a missing file aborts
    with class `rcs_error_backend`);

2.  else, when `CLOUDSDK_CONFIG` is set,
    `application_default_credentials.json` in that folder only (gcloud's
    folder is not tried);

3.  else the same file in gcloud's folder (`%APPDATA%/gcloud` on
    Windows, `~/.config/gcloud` elsewhere), written once by
    `gcloud auth application-default login`;

4.  ambient credentials, when the file of step 2 or 3 does not exist:
    Arrow and the JSON API then use Google's own defaults (on Google
    Cloud, the metadata server).

Access tokens of a key file or a function are renewed five minutes
before they expire, so a long session never signs in again. A token
given with `token` cannot be renewed: it lasts as long as its issuer
allows (usually one hour).

Asking for the same source again returns the same object, with its
token. Printing the object never contacts the network and never shows a
secret; the identity (the account's e-mail) is known after the first
token.

## Clients

One credential serves every client of a location: Arrow (data files),
the JSON API (MD5 checksums), GDAL (rasters through `/vsigs/`) and
DuckDB
([`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)).
Tokens, refresh tokens, client secrets and functions stay inside the
object: they are never written to files, catalogs or logs, nor put in
environment variables.

- GDAL's options are process-wide. Reading a raster gives GDAL the
  credential of its location (a user login as the three `GS_OAUTH2_*`
  options, a service account as the GDAL option
  `GOOGLE_APPLICATION_CREDENTIALS`, a token or a function as an
  `Authorization` header), for every GDAL read of the R process. The
  first switch to another credential warns (class
  `rcs_warning_gdal_credential`): a raster opened earlier reads its
  tiles lazily and may fail with the new credential.

- DuckDB gets a temporary secret holding a token, in its connection
  only; call
  [`store_duckdb()`](https://ebukin.github.io/rcs/reference/store_duckdb.md)
  again after about an hour of DuckDB work on a bucket to refresh it.

- Ambient credentials work for Arrow and the JSON API only.

[`store_auth_check()`](https://ebukin.github.io/rcs/reference/store_auth_check.md)
tries every client on every location.

## See also

[`store_connect()`](https://ebukin.github.io/rcs/reference/store_connect.md),
[`store_create()`](https://ebukin.github.io/rcs/reference/store_create.md),
[`store_auth_check()`](https://ebukin.github.io/rcs/reference/store_auth_check.md);
[`vignette("locations")`](https://ebukin.github.io/rcs/articles/locations.md)
for a walk-through.

## Examples

``` r
# The default lookup; nothing is contacted until data is read.
rcs_auth_gcs()
#> <rcs_auth_gcs>
#> Source:   the application-default login of gcloud (default lookup)
#> Type:     authorized_user
#> File:     ~/AppData/Roaming/gcloud/application_default_credentials.json
#> Identity: known after the first token
#> Token:    none yet

# A token obtained elsewhere (here a placeholder)
auth <- rcs_auth_gcs(token = "<access token>")
auth
#> <rcs_auth_gcs>
#> Source:   an access token given to rcs_auth_gcs(token = )
#> Identity: known after the first token
#> Token:    given by the caller, not renewed
```
