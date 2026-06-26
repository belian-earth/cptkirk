# GDAL-style auth, translated to object_store.
#
# cptkirk fetches bytes through object_store, not GDAL's /vsi* layer, so it does
# not automatically honour the GDAL credential variables a user's setup already
# relies on. Most carry identical names in both worlds (AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, AWS_REGION, GOOGLE_APPLICATION_-
# CREDENTIALS, AZURE_STORAGE_ACCESS_KEY, ...) and the Rust side forwards them
# verbatim. A handful diverge in name or value; those -- and only those, none of
# which are secrets -- are translated here so an existing GDAL configuration is a
# drop-in. Secrets continue to flow straight from the environment into Rust,
# never through R.
#
# Settings are read from the environment OR GDAL's in-process config
# (gdalraster::set_config_option()), env taking precedence, so a session that
# configured GDAL programmatically rather than via the shell still works.

# Read a GDAL setting: environment first, then GDAL in-process config. "" if unset.
.gdal_opt <- function(name) {
  v <- Sys.getenv(name, unset = "")
  if (nzchar(v)) return(v)
  cfg <- tryCatch(gdalraster::get_config_option(name), error = function(e) "")
  if (is.null(cfg) || is.na(cfg)) "" else cfg
}

# Normalise a GDAL boolean (YES/NO/TRUE/FALSE/ON/OFF/1/0) to object_store
# "true"/"false". NA for an empty or unrecognised value (caller drops it).
.gdal_bool <- function(v) {
  u <- toupper(trimws(v))
  if (u %in% c("YES", "TRUE", "ON", "1")) "true"
  else if (u %in% c("NO", "FALSE", "OFF", "0")) "false"
  else NA_character_
}

# Build the object_store options translated from divergent GDAL settings.
# Returns a named character vector (object_store key -> value); empty if nothing
# needs translating. Backend-agnostic: keys are fully qualified (aws_*/azure_*/
# google_*) so passing the whole set to any URL is safe -- object_store applies
# only the keys its scheme's builder recognises and ignores the rest.
.os_auth_opts <- function() {
  opt <- character(0)
  set <- function(k, v) {
    if (length(v) == 1L && !is.na(v) && nzchar(v)) opt[[k]] <<- v
  }

  ## ---- AWS / S3 ----
  https <- .gdal_bool(.gdal_opt("AWS_HTTPS"))           # GDAL default: YES
  endpoint <- .gdal_opt("AWS_S3_ENDPOINT")              # host[:port], no scheme
  if (nzchar(endpoint)) {
    if (!grepl("^https?://", endpoint, ignore.case = TRUE)) {
      scheme <- if (identical(https, "false")) "http://" else "https://"
      endpoint <- paste0(scheme, endpoint)
    }
    set("aws_endpoint", endpoint)
  }
  if (identical(https, "false")) set("aws_allow_http", "true")

  set("aws_skip_signature", .gdal_bool(.gdal_opt("AWS_NO_SIGN_REQUEST")))
  set("aws_virtual_hosted_style_request", .gdal_bool(.gdal_opt("AWS_VIRTUAL_HOSTING")))

  payer <- tolower(trimws(.gdal_opt("AWS_REQUEST_PAYER")))   # GDAL: "requester"
  if (nzchar(payer)) {
    set("aws_request_payer", if (payer %in% c("requester", "true", "yes")) "true" else "false")
  }

  ## ---- Azure ----
  set("azure_storage_account_name", .gdal_opt("AZURE_STORAGE_ACCOUNT"))
  set("azure_skip_signature", .gdal_bool(.gdal_opt("AZURE_NO_SIGN_REQUEST")))
  if (nzchar(.gdal_opt("AZURE_STORAGE_CONNECTION_STRING"))) {
    cli::cli_warn(c(
      "!" = "{.envvar AZURE_STORAGE_CONNECTION_STRING} is not supported by cptkirk.",
      "i" = "Set {.envvar AZURE_STORAGE_ACCOUNT} with {.envvar AZURE_STORAGE_ACCESS_KEY} (or a SAS token) instead."
    ), .frequency = "once", .frequency_id = "ck_auth_azure_connstr")
  }

  ## ---- GCS ----
  set("google_skip_signature", .gdal_bool(.gdal_opt("GS_NO_SIGN_REQUEST")))
  if (nzchar(.gdal_opt("GS_ACCESS_KEY_ID")) || nzchar(.gdal_opt("GS_SECRET_ACCESS_KEY"))) {
    cli::cli_warn(c(
      "!" = "GCS HMAC keys ({.envvar GS_ACCESS_KEY_ID}/{.envvar GS_SECRET_ACCESS_KEY}) are not supported by cptkirk.",
      "i" = "Use {.envvar GOOGLE_APPLICATION_CREDENTIALS} (a service-account JSON) instead."
    ), .frequency = "once", .frequency_id = "ck_auth_gcs_hmac")
  }

  opt
}

# Split the translated options into the parallel key/value character vectors the
# extendr open entrypoints expect. Always returns character vectors (never NULL),
# so an empty option set is passed cleanly across the ABI.
.auth_kv <- function() {
  o <- .os_auth_opts()
  if (length(o)) {
    list(keys = names(o), vals = unname(o))
  } else {
    list(keys = character(0), vals = character(0))
  }
}
