#' Warp a remote GeoTIFF / COG (a streaming sibling of gdalraster::warp)
#'
#' A near drop-in for [gdalraster::warp()] that reads its source(s) remotely.
#' The call shape is the same -- `src`, `dst`, `t_srs`, and a raw `gdalwarp`
#' argument vector in `cl_arg` -- but instead of letting GDAL pull the source
#' over `/vsicurl`, cptkirk works out which pixels the request touches and
#' streams just those tiles over the Rust `async-tiff` reader (at the
#' appropriate overview level), stages them in `/vsimem`, then hands the warp to
#' GDAL. Output is identical to [gdalraster::warp()] of the same source.
#'
#' This is the faithful low-level interface: it adds none of cptkirk's
#' performance opinions and forwards `cl_arg` to GDAL verbatim. For the
#' recommended, batteries-included helper (named `te`/`tr`/`ts`/`r`/`bands`
#' arguments, multi-threading, `SKIP_NOSOURCE`, band-subset streaming, ...) use
#' [ck_warp()].
#'
#' @param src Path/URL to a source GeoTIFF / COG, a [cog_source()] handle, or a
#'   character vector of several sources to mosaic. A [cog_source()] reuses its
#'   already-open handle, skipping the metadata re-read.
#' @param dst Output filename (a regular path, `/vsimem/`, or anything GDAL can
#'   write). The format is inferred by GDAL or set with `-of` in `cl_arg`.
#' @param t_srs Target SRS (e.g. `"EPSG:3857"`), as in [gdalraster::warp()].
#'   `""` (the default) or `NULL` means no reprojection (source CRS).
#' @param cl_arg Character vector of raw `gdalwarp` flags, forwarded verbatim to
#'   [gdalraster::warp()] (e.g. `c("-te", "0", "0", "100", "100", "-tr", "10",
#'   "10", "-r", "bilinear")`). cptkirk parses `-te`/`-te_srs`/`-tr`/`-ts` from
#'   it purely to size the fetch.
#' @param quiet If `TRUE` (default), the GDAL warp runs without a progress
#'   callback. Unlike [gdalraster::warp()] this defaults to `TRUE`: a progress
#'   callback invoked from GDAL's worker threads (e.g. with `-multi`) can crash
#'   the R session.
#' @param overview Force a 1-based IFD/overview level instead of auto-selecting
#'   from the output resolution. `1` = full resolution.
#' @param margin Source-pixel margin added around the computed window to cover
#'   the resampling kernel and reprojection slop (default 8).
#' @param io_concurrency Number of concurrent tile reads -- the width of the
#'   single global fetch pool shared across all source tiles (default 16).
#' @param max_bytes Safety ceiling (bytes) on the staged in-memory window.
#'   `NULL` (default) uses ~1/3 of system RAM.
#' @param sanitise If `TRUE` (default), validate `cl_arg` (and `t_srs`) against
#'   a tiny metadata-derived stand-in *before* fetching, so a bad CRS,
#'   resampling method, creation option or unknown flag fails in milliseconds
#'   instead of after a remote read. Set `FALSE` to skip the check.
#' @return The `dst` path, invisibly.
#' @seealso [ck_warp()] for the recommended helper with named arguments and
#'   cptkirk's defaults.
#' @export
warp_remote <- function(src, dst, t_srs = "", cl_arg = NULL, quiet = TRUE,
                        overview = NULL, margin = 8L,
                        io_concurrency = 16L, max_bytes = NULL,
                        sanitise = TRUE) {
  rlang::check_required(src)
  rlang::check_required(dst)
  if (!rlang::is_string(dst)) {
    cli::cli_abort("{.arg dst} must be a single output path string.")
  }
  cl_arg <- cl_arg %||% character(0)
  # gdalraster::warp takes t_srs positionally; "" / NULL means "no override".
  t_srs <- if (is.null(t_srs) || !nzchar(t_srs)) NULL else t_srs

  g <- .cl_geom(cl_arg)
  .warp_engine(src, dst, t_srs = t_srs, te = g$te, te_srs = g$te_srs,
               tr = g$tr, ts = g$ts, bands = NULL, cl_arg = cl_arg,
               overview = overview, margin = margin,
               io = io_concurrency %||% 16L,
               max_bytes = max_bytes %||% .default_max_bytes(),
               quiet = quiet, skip_nosource = FALSE, sanitise = sanitise)
}
