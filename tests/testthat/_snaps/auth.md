# key files of both types are accepted, other types abort

    Code
      rcs_auth_gcs(key = other)
    Condition
      Error in `rcs_auth_gcs()`:
      ! '<dir>/other.json' holds credentials of type "external_account".
      i Use a key file of type "service_account" or "authorized_user", a token or a function.
    Code
      rcs_auth_gcs(key = broken)
    Condition
      Error in `rcs_auth_gcs()`:
      ! '<dir>/broken.json' is not a JSON credential file.
    Code
      rcs_auth_gcs(key = file.path(dir, "none.json"))
    Condition
      Error in `rcs_auth_gcs()`:
      ! No credential file at '<dir>/none.json'.

# rcs_auth_gcs() takes at most one argument, each checked

    Code
      rcs_auth_gcs(key = "a.json", token = "abc")
    Condition
      Error in `rcs_auth_gcs()`:
      ! Give at most one of `key`, `token` and `fun`, not `key` and `token`.
    Code
      rcs_auth_gcs(token = "abc", fun = function() "x")
    Condition
      Error in `rcs_auth_gcs()`:
      ! Give at most one of `key`, `token` and `fun`, not `token` and `fun`.
    Code
      rcs_auth_gcs(token = 1)
    Condition
      Error in `rcs_auth_gcs()`:
      ! `token` must be a single non-empty string, not a number.
    Code
      rcs_auth_gcs(key = c("a", "b"))
    Condition
      Error in `rcs_auth_gcs()`:
      ! `key` must be a single non-empty string, not a character vector.
    Code
      rcs_auth_gcs(fun = "not a function")
    Condition
      Error in `rcs_auth_gcs()`:
      ! `fun` must be a function of no arguments, not a string.

# print() shows source, type, file, identity and validity, never a secret

    Code
      print(auth)
    Output
      <rcs_auth_gcs>
      Source:   a key file
      Type:     authorized_user
      File:     <dir>/user.json
      Identity: known after the first token
      Token:    none yet

---

    Code
      print(auth)
    Output
      <rcs_auth_gcs>
      Source:   a key file
      Type:     authorized_user
      File:     <dir>/user.json
      Identity: someone@example.com
      Token:    valid for about 40 min, renewed automatically

---

    Code
      print(rcs_auth_gcs(token = "ya29-fake-access"))
    Output
      <rcs_auth_gcs>
      Source:   an access token given to rcs_auth_gcs(token = )
      Identity: known after the first token
      Token:    given by the caller, not renewed
    Code
      print(rcs_auth_gcs(fun = function() "x"))
    Output
      <rcs_auth_gcs>
      Source:   a function given to rcs_auth_gcs(fun = )
      Identity: known after the first token
      Token:    none yet

---

    Code
      print(rcs_auth_gcs())
    Output
      <rcs_auth_gcs>
      Source:   ambient credentials (default lookup, no credential file found)
      Identity: known after the first token
      Token:    none yet

