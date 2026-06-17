#' Open a (remote) GeoTIFF / COG once and reuse it
#'
#' Opens the source over a remote-capable reader (local path, `http(s)://`,
#' `s3://`, `gs://`, `az://`), reading the header and all IFDs a single time.
#' The returned handle can be passed to [cog_info()] and [warp_remote()] in
#' place of a URL, so repeated warps of the same raster (e.g. many AOIs, or a
#' set of rasters) pay the metadata round-trips only once.
#'
#' @param src Path or URL to a GeoTIFF / Cloud-Optimised GeoTIFF.
#' @return An object of class `cog_source` wrapping an open handle.
#' @section Authentication:
#' Remote object-store sources (`s3://`, `gs://`, `az://`) authenticate from the
#' **process environment**, using the variable names `object_store` documents
#' (e.g. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
#' `AWS_REGION`; `GOOGLE_SERVICE_ACCOUNT`; `AZURE_STORAGE_ACCOUNT_NAME`). With no
#' static credentials the builders fall back to the platform chain (web-identity,
#' ECS, EC2 instance metadata). For public buckets set `AWS_SKIP_SIGNATURE=true`
#' (or just use the `https://` URL). Credentials are never passed through R, so
#' they stay out of scripts and logs. This is independent of GDAL's `/vsi*`
#' credential settings, which cptkirk does not use for reading.
#' @export
cog_source <- function(src) {
  rlang::check_required(src)
  if (!rlang::is_string(src)) {
    cli::cli_abort("{.arg src} must be a single path or URL string.")
  }
  structure(list(ptr = cog_open(src), src = src), class = "cog_source")
}

#' @export
print.cog_source <- function(x, ...) {
  cli::cli_text("{.cls cog_source} {.url {x$src}}")
  invisible(x)
}

# Resolve a `src` argument (URL string or a cog_source) to a handle.
.as_cog_source <- function(src) {
  if (inherits(src, "cog_source")) return(src)
  if (rlang::is_string(src)) return(cog_source(src))
  cli::cli_abort(
    "{.arg src} must be a path/URL string or a {.fn cog_source} object."
  )
}
