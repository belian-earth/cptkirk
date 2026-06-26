#' Inspect a (remote) GeoTIFF / COG
#'
#' Reads only the GeoTIFF header and IFDs over a remote-capable reader
#' (local path, `http(s)://`, `s3://`, `gs://`, `az://`) and returns its
#' georeferencing and structure. No pixel data is fetched.
#'
#' Pass several sources to inspect a set at once -- the metadata reads run
#' concurrently, and the result is a `cog_info_list` whose print method
#' summarises the set (shared vs varying CRS / resolution / bands, and combined
#' extent) -- handy for vetting tiles before a mosaic. Convert either form to a
#' tidy one-row-per-source data frame with [as.data.frame()] (or
#' `as.data.frame = TRUE`).
#'
#' @param src Path/URL to a GeoTIFF / Cloud-Optimised GeoTIFF, a [cog_source()]
#'   handle, or a **character vector of several** sources.
#' @param as.data.frame If `TRUE`, return the one-row-per-source data frame
#'   (see [as.data.frame.cog_info()]) instead of the `cog_info` object(s).
#'   Default `FALSE`.
#' @return For a single source, a list of class `cog_info` with `width`,
#'   `height`, `n_bands`, `dtype` (GDAL type name), `nodata`, `geotransform`
#'   (GDAL corner-based affine, length 6), `crs` (a string GDAL can import),
#'   `band_names`, and the per-level pixel sizes `level_width` / `level_height`
#'   (level 1 = full resolution, the rest overviews) plus their `tile_width` /
#'   `tile_height`. For several sources, a `cog_info_list` of such objects. With
#'   `as.data.frame = TRUE`, a data frame of one row per source.
#' @export
cog_info <- function(src, as.data.frame = FALSE) {
  rlang::check_required(src)
  rlang::check_bool(as.data.frame)

  res <- if (is.character(src) && length(src) > 1L) {
    kv <- .auth_kv()
    metas <- cog_meta_many(src, kv$keys, kv$vals)
    items <- Map(function(s, m) {
      m$src <- s
      structure(m, class = c("cog_info", "list"))
    }, src, metas)
    structure(unname(items), class = "cog_info_list")
  } else {
    h <- .as_cog_source(src)
    out <- cog_meta(h$ptr)
    out$src <- h$src
    structure(out, class = c("cog_info", "list"))
  }

  if (isTRUE(as.data.frame)) as.data.frame(res) else res
}

#' @export
print.cog_info_list <- function(x, ...) {
  n <- length(x)
  crs <- vapply(x, function(e) e$crs %||% NA_character_, character(1))
  res <- vapply(x, function(e) abs(e$geotransform[2]), numeric(1))
  nb  <- vapply(x, function(e) as.integer(e$n_bands), integer(1))
  dt  <- vapply(x, function(e) e$dtype, character(1))
  lv  <- vapply(x, function(e) as.integer(e$n_levels), integer(1))
  one <- function(v) length(unique(v)) == 1L

  cli::cli_rule(left = "{.strong cog_info} ({.val {n}} sources)")
  cli::cli_dl(c(
    "crs"        = if (one(crs)) (crs[1] %||% "<none>")
                   else "{.emph mixed} ({length(unique(crs))} distinct)",
    "bands"      = if (one(nb) && one(dt)) sprintf("%d %s", nb[1], dt[1]) else "{.emph varies}",
    "resolution" = if (one(res)) .fmt_num(res[1])
                   else sprintf("%s - %s", .fmt_num(min(res)), .fmt_num(max(res))),
    "overviews"  = if (one(lv)) as.character(lv[1] - 1L)
                   else sprintf("%d - %d", min(lv) - 1L, max(lv) - 1L)
  ))
  if (one(crs) && !is.na(crs[1])) {
    bb <- do.call(rbind, lapply(x, function(e) .full_src_bbox(e$geotransform, e$width, e$height)))
    ext <- c(min(bb[, 1]), min(bb[, 2]), max(bb[, 3]), max(bb[, 4]))
    ext_str <- paste(trimws(vapply(ext, .fmt_num, character(1))), collapse = ", ")
    cli::cli_text("{.field combined extent}: {ext_str}")
  } else {
    cli::cli_text("{.field combined extent}: {.emph mixed CRS}")
  }
  invisible(x)
}

# One tidy row of summary metadata for a single cog_info object.
.cog_info_row <- function(e) {
  bb <- .full_src_bbox(e$geotransform, e$width, e$height)
  data.frame(
    src = e$src %||% NA_character_,
    width = e$width, height = e$height, n_bands = e$n_bands,
    dtype = e$dtype, nodata = e$nodata %||% NA_real_, crs = e$crs %||% NA_character_,
    res_x = abs(e$geotransform[2]), res_y = abs(e$geotransform[6]),
    xmin = bb[1], ymin = bb[2], xmax = bb[3], ymax = bb[4],
    n_levels = e$n_levels,
    tile_width = e$tile_width[1] %||% NA_integer_,
    tile_height = e$tile_height[1] %||% NA_integer_,
    stringsAsFactors = FALSE
  )
}

#' Tidy one-row-per-source summary of `cog_info` metadata
#'
#' Flattens [cog_info()] output to a data frame with columns `src`, `width`,
#' `height`, `n_bands`, `dtype`, `nodata`, `crs`, `res_x`, `res_y`, `xmin`,
#' `ymin`, `xmax`, `ymax`, `n_levels`, `tile_width`, `tile_height`. The
#' per-overview detail (`level_width` etc.) is collapsed to `n_levels`; inspect
#' a single source for the full vector.
#'
#' @param x A `cog_info` or `cog_info_list` from [cog_info()].
#' @param row.names,optional Unused; present for `as.data.frame()` generic
#'   compatibility.
#' @param ... Unused.
#' @return A data frame, one row per source.
#' @export
as.data.frame.cog_info <- function(x, row.names = NULL, optional = FALSE, ...) {
  .cog_info_row(x)
}

#' @rdname as.data.frame.cog_info
#' @export
as.data.frame.cog_info_list <- function(x, row.names = NULL, optional = FALSE, ...) {
  do.call(rbind, lapply(x, .cog_info_row))
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
