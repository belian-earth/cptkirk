#' Inspect a (remote) GeoTIFF / COG
#'
#' Reads only the GeoTIFF header and IFDs over a remote-capable reader
#' (local path, `http(s)://`, `s3://`, `gs://`, `az://`) and returns its
#' georeferencing and structure. No pixel data is fetched.
#'
#' @param src Path or URL to a GeoTIFF / Cloud-Optimised GeoTIFF, or a
#'   [cog_source()] handle.
#' @return A list (class `cog_info`) with `width`, `height`, `n_bands`,
#'   `dtype` (GDAL type name), `nodata`, `geotransform` (GDAL corner-based
#'   affine, length 6), `crs` (a string GDAL can import), `band_names`, and the
#'   per-level pixel sizes `level_width` / `level_height` (level 1 = full
#'   resolution, the rest overviews) plus their `tile_width` / `tile_height`.
#' @export
cog_info <- function(src) {
  rlang::check_required(src)
  h <- .as_cog_source(src)
  out <- cog_meta(h$ptr)
  out$src <- h$src
  structure(out, class = c("cog_info", "list"))
}

#' @export
print.cog_info <- function(x, ...) {
  res_x <- abs(x$geotransform[2])
  res_y <- abs(x$geotransform[6])
  res <- if (isTRUE(all.equal(res_x, res_y))) {
    .fmt_num(res_x)
  } else {
    paste0(.fmt_num(res_x), " x ", .fmt_num(res_y))
  }
  px <- prod(as.numeric(c(x$width, x$height)))

  cli::cli_rule(left = "{.strong cog_info}")
  cli::cli_text("{.url {x$src}}")
  cli::cli_dl(c(
    "size"       = "{.val {x$width}} x {.val {x$height}} px ({.val {round(px/1e6, 1)}} Mpx)",
    "bands"      = "{.val {x$n_bands}} {.field {x$dtype}}",
    "resolution" = "{res} (CRS units)",
    "crs"        = "{x$crs %||% '<none>'}",
    "nodata"     = "{if (is.null(x$nodata)) '<none>' else format(x$nodata)}",
    "overviews"  = "{.val {x$n_levels - 1L}} ({paste0(x$level_width, 'x', x$level_height, collapse = ', ')})"
  ))

  # cli_vec truncates long vectors itself, respecting the output's colour
  # support (no raw ANSI leaks when colour is off).
  bn <- cli::cli_vec(x$band_names, list("vec-trunc" = 8L))
  cli::cli_text("{.field band names}: {.val {bn}}")
  invisible(x)
}

# Compact number formatting for display (no scientific notation, trimmed).
.fmt_num <- function(v) {
  formatC(v, format = "fg", digits = 6, drop0trailing = TRUE)
}
