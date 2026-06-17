#' Warp a remote GeoTIFF / COG, streaming only the pixels GDAL needs
#'
#' A remote, overview-aware `gdalwarp`. cptkirk works out which source pixels
#' the requested warp will touch, streams only those tiles over `async-tiff`
#' (at the appropriate overview level), stages them as an in-memory GDAL
#' source, then hands the warp to GDAL via [gdalraster::warp()]. Every actual
#' resampling / reprojection decision is GDAL's; cptkirk only sizes the fetch.
#'
#' The target grid follows the `gdalwarp` API. Pass the geometry-defining
#' options as named arguments (`t_srs`, `te`, `tr`, `ts`, `r`) and/or hand any
#' additional raw `gdalwarp` flags through `cl_arg`; the full set is forwarded
#' to [gdalraster::warp()].
#'
#' @param src Path/URL to a source GeoTIFF / COG, a [cog_source()] handle, or a
#'   **character vector of several** sources to mosaic (each tile's overlapping
#'   window is fetched and the set is reprojected/mosaicked in one warp;
#'   non-overlapping tiles are skipped). Passing a [cog_source()] reuses its
#'   already-open handle, skipping the metadata re-read -- worthwhile when
#'   warping many AOIs from the same source.
#' @param dst Output filename (a regular path, a `/vsimem/` path, or anything
#'   GDAL can write). The format is inferred by GDAL or set with `-of` in
#'   `cl_arg`.
#' @param t_srs Target SRS (e.g. `"EPSG:3857"`). If `NULL`, the source CRS is
#'   used (no reprojection).
#' @param te Target extent `c(xmin, ymin, xmax, ymax)`, in `te_srs` if given,
#'   otherwise in `t_srs`. When supplied this is the AOI that drives the fetch.
#' @param te_srs SRS of `te` (defaults to `t_srs`).
#' @param tr Target resolution `c(xres, yres)` in target CRS units.
#' @param ts Target size `c(width, height)` in pixels.
#' @param r Resampling method (`"near"`, `"bilinear"`, `"cubic"`, ...).
#' @param bands 1-based source bands to read (default: all). Subsetting happens
#'   during the fetch, so only those bands' bytes are streamed.
#' @param cl_arg Character vector of extra raw `gdalwarp` flags, forwarded
#'   verbatim to [gdalraster::warp()] (e.g. `c("-overwrite", "-wo",
#'   "NUM_THREADS=ALL_CPUS")`).
#' @param overview Force a 1-based IFD/overview level instead of auto-selecting
#'   from the output resolution. `1` = full resolution.
#' @param margin Source-pixel margin added around the computed window to cover
#'   the resampling kernel and reprojection slop (default 8).
#' @param io_concurrency Max in-flight tile fetches (default: a small
#'   CPU-derived value). Bump for cloud reads.
#' @param max_bytes Safety limit (bytes) on the in-memory window staged before
#'   warping (`width * height * bands * <dtype bytes>`). Default 2e9 (2 GB).
#'   Warping a whole large multi-band raster at native resolution will exceed
#'   this on purpose; narrow the request or raise the limit.
#' @param num_threads Value for GDAL's warp `NUM_THREADS` warp option and the
#'   `GDAL_NUM_THREADS` config (default `"ALL_CPUS"`), parallelising the
#'   resampling computation and GeoTIFF (de)compression. `NULL` leaves them
#'   unset. GDAL's `-multi` (threaded warp I/O) may be passed via `cl_arg`;
#'   warps always run silently (no progress callback), so it is safe.
#' @param warp_memory Warp working memory in MB (GDAL `-wm`). Default: ~25% of
#'   system RAM, clamped to 256-2048 MB. Bigger means fewer, larger chunks.
#' @param cache_max GDAL block cache in MB for this call. Default: ~25% of RAM,
#'   clamped to 256-2000 MB. Restored to the previous value afterwards.
#' @param co Character vector of GDAL output creation options, e.g.
#'   `c("COMPRESS=ZSTD", "TILED=YES", "NUM_THREADS=ALL_CPUS")`.
#' @param config Named character vector / list of extra GDAL config options to
#'   set for the duration of the call (restored on exit).
#' @param skip_nosource If `TRUE` (default), pass `SKIP_NOSOURCE=YES` +
#'   `INIT_DEST` so the warper skips output chunks with no source coverage
#'   (e.g. nodata margins from reprojection). No effect when output is fully
#'   covered. Ignored on the copy fast-path.
#' @return The `dst` path, invisibly.
#' @export
warp_remote <- function(src, dst,
                        t_srs = NULL, te = NULL, te_srs = NULL,
                        tr = NULL, ts = NULL, r = "near",
                        bands = NULL, cl_arg = character(0),
                        overview = NULL, margin = 8L,
                        io_concurrency = NULL, max_bytes = 2e9,
                        num_threads = "ALL_CPUS", warp_memory = NULL,
                        cache_max = NULL, co = NULL, config = NULL,
                        skip_nosource = TRUE) {
  rlang::check_required(src)
  rlang::check_required(dst)
  if (!rlang::is_string(dst)) {
    cli::cli_abort("{.arg dst} must be a single output path string.")
  }

  # Scope GDAL speed config to this call (restored on exit).
  .local_gdal_speed(
    opts = c(
      list(
        GDAL_NUM_THREADS = num_threads,
        GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR"
      ),
      as.list(config)
    ),
    cache_bytes = if (!is.null(cache_max)) cache_max * 1e6 else .default_cache_bytes(),
    .envir = environment()
  )

  if (!is.null(te)) {
    te <- as.numeric(te)
    if (!rlang::is_double(te, n = 4L)) {
      cli::cli_abort("{.arg te} must be {.code c(xmin, ymin, xmax, ymax)}.")
    }
  }

  # --- plan each tile's window (R/PROJ), then fetch + stage -----------------
  # A `cog_source` reuses its already-open handle (no re-read of metadata or
  # IFDs) -- valuable when warping many AOIs from the same source. A URL (or
  # vector of URLs) is opened concurrently for the mosaic.
  bands0 <- if (is.null(bands)) integer(0) else as.integer(bands)
  io <- io_concurrency %||% 16L
  reuse <- inherits(src, "cog_source")
  urls <- if (reuse) src$src else as.character(src)
  metas <- if (reuse) list(cog_meta(src$ptr)) else cog_meta_many(urls)
  plans <- Map(function(u, mm) {
    .plan_from_meta(u, mm, t_srs = t_srs, te = te, te_srs = te_srs, tr = tr,
                    ts = ts, bands = bands, overview = overview, margin = margin,
                    max_bytes = max_bytes)
  }, urls, metas)
  plans <- Filter(Negate(is.null), plans)
  if (!length(plans)) {
    cli::cli_abort(c(
      "Requested extent does not overlap any source raster.",
      "i" = "Check {.arg te} (and {.arg te_srs}/{.arg t_srs}) cover the source footprint(s)."
    ))
  }
  n <- length(plans)
  nodata <- plans[[1]]$nodata
  if (reuse) {
    # single source: fetch from the open handle (no re-open).
    p <- plans[[1]]
    ws <- list(cog_fetch_window_raw(
      src$ptr, level = p$level, xoff = p$xoff, yoff = p$yoff,
      xsize = p$xsize, ysize = p$ysize, bands = bands0,
      fill = nodata %||% 0, io_concurrency = io
    ))
  } else {
    # One global concurrency budget across all tiles' tile-fetches (object
    # stores throttle past ~16; raise on a fast, stable link).
    g <- function(k) vapply(plans, `[[`, if (k == "src") character(1) else integer(1), k)
    ws <- cog_fetch_windows_raw(
      srcs = g("src"), level = g("level"), xoff = g("xoff"), yoff = g("yoff"),
      xsize = g("xsize"), ysize = g("ysize"), bands = bands0,
      fill = nodata %||% 0, io_concurrency = io
    )
  }
  staged <- Map(function(w, p) .stage_vsimem_vrt(w, p$win_gt, p$src_wkt, nodata = p$nodata),
                ws, plans)
  on.exit(
    for (f in unlist(lapply(staged, `[[`, "files"))) {
      try(gdalraster::vsi_unlink(f), silent = TRUE)
    },
    add = TRUE
  )
  vrts <- vapply(staged, `[[`, character(1), "vrt")
  t_srs_warp <- t_srs %||% plans[[1]]$crs

  # --- copy fast-path (single source, no reprojection/resolution change) ----
  # The staged window (fetched with zero margin) *is* the answer. translate()
  # (GDALCreateCopy) writes it straight out -- no warp transformer/resampler,
  # orientation-agnostic (handles south-up sources).
  if (n == 1L && isTRUE(plans[[1]]$is_copy)) {
    if (file.exists(dst)) unlink(dst)
    targs <- if (length(co)) as.vector(rbind("-co", co)) else character(0)
    gdalraster::translate(vrts, dst, cl_arg = targs, quiet = TRUE)
    return(invisible(dst))
  }

  # --- assemble gdalwarp args + hand the (mosaic) warp to GDAL --------------
  args <- character(0)
  if (!is.null(te))     args <- c(args, "-te", .numarg(te))
  if (!is.null(te_srs)) args <- c(args, "-te_srs", te_srs)
  if (!is.null(tr))     args <- c(args, "-tr", .numarg(tr))
  if (!is.null(ts))     args <- c(args, "-ts",
                                   format(as.integer(round(as.numeric(ts))),
                                          scientific = FALSE, trim = TRUE))
  if (!is.null(r))      args <- c(args, "-r", r)
  # Skip output chunks with no source coverage (e.g. nodata margins created by
  # reprojection). Paired with INIT_DEST so skipped chunks are initialised.
  if (isTRUE(skip_nosource) && !any(grepl("SKIP_NOSOURCE", cl_arg, fixed = TRUE))) {
    args <- c(args, "-wo", "SKIP_NOSOURCE=YES")
    if (!any(grepl("INIT_DEST", cl_arg, fixed = TRUE))) {
      args <- c(args, "-wo", if (!is.null(nodata)) "INIT_DEST=NO_DATA" else "INIT_DEST=0")
    }
  }
  # -multi (threaded warp I/O) passes through untouched: warps always run
  # silently here (no R progress callback), so warp threads never call back
  # into R -- the thing that otherwise crashes -multi.
  # Parallelise the warp computation (not I/O) unless the caller set it.
  if (!is.null(num_threads) && !any(grepl("NUM_THREADS", cl_arg, fixed = TRUE))) {
    args <- c(args, "-wo", paste0("NUM_THREADS=", num_threads))
  }
  # Generous warp working memory (one big chunk beats many small ones).
  wm <- warp_memory %||% .default_warp_mem()
  if (!is.null(wm) && !any(cl_arg == "-wm")) {
    args <- c(args, "-wm", as.character(wm))
  }
  # Output creation options.
  if (length(co)) {
    args <- c(args, as.vector(rbind("-co", co)))
  }
  args <- c(args, cl_arg)

  gdalraster::warp(src_files = vrts,
                   dst_filename = dst,
                   t_srs = t_srs_warp,
                   cl_arg = args,
                   quiet = TRUE)

  invisible(dst)
}

# Plan one source tile's fetch window from its (already-read) metadata `m`.
# Pure geometry -- no I/O. Returns NULL if the requested extent doesn't overlap
# this tile (so it's skipped in a mosaic), else the window spec for the fetch.
.plan_from_meta <- function(url, m, t_srs, te, te_srs, tr, ts, bands, overview,
                            margin, max_bytes) {
  if (is.null(m$crs)) {
    cli::cli_abort("Could not resolve a source CRS from {.val {url}}.")
  }
  gt <- m$geotransform
  W <- m$level_width[1]; H <- m$level_height[1]
  is_copy <- is.null(tr) && is.null(ts) && .srs_identity(t_srs, m$crs)
  margin_eff <- if (is_copy) 0L else margin

  src_bbox <- if (!is.null(te)) {
    extent_srs <- te_srs %||% t_srs %||% m$crs
    if (identical(extent_srs, m$crs)) te else gdalraster::transform_bounds(te, extent_srs, m$crs)
  } else {
    .full_src_bbox(gt, W, H)
  }

  inv <- gdalraster::inv_geotransform(gt)
  px <- function(x, y) c(inv[1] + x * inv[2] + y * inv[3],
                         inv[4] + x * inv[5] + y * inv[6])
  corners <- rbind(px(src_bbox[1], src_bbox[2]), px(src_bbox[1], src_bbox[4]),
                   px(src_bbox[3], src_bbox[2]), px(src_bbox[3], src_bbox[4]))
  cmin <- apply(corners, 2, min); cmax <- apply(corners, 2, max)

  t_srs_eff <- t_srs %||% m$crs
  tgt_bbox <- if (!is.null(te)) {
    if (!is.null(te_srs) && !identical(te_srs, t_srs_eff)) {
      gdalraster::transform_bounds(te, te_srs, t_srs_eff)
    } else te
  } else if (identical(t_srs_eff, m$crs)) {
    src_bbox
  } else {
    gdalraster::transform_bounds(src_bbox, m$crs, t_srs_eff)
  }
  lvl <- if (!is.null(overview)) as.integer(overview) else .pick_overview(m, src_bbox, tgt_bbox, tr, ts)
  lvl <- max(1L, min(lvl, m$n_levels))
  fx <- W / m$level_width[lvl]; fy <- H / m$level_height[lvl]

  oxoff <- max(0L, as.integer(floor(min(cmin[1], cmax[1]) / fx)) - margin_eff)
  oyoff <- max(0L, as.integer(floor(min(cmin[2], cmax[2]) / fy)) - margin_eff)
  oxend <- min(m$level_width[lvl],  as.integer(ceiling(max(cmin[1], cmax[1]) / fx)) + margin_eff)
  oyend <- min(m$level_height[lvl], as.integer(ceiling(max(cmin[2], cmax[2]) / fy)) + margin_eff)
  if (oxend <= oxoff || oyend <= oyoff) return(NULL)   # no overlap: skip this tile
  oxs <- oxend - oxoff; oys <- oyend - oyoff

  n_sel <- if (is.null(bands)) m$n_bands else length(bands)
  est <- as.numeric(oxs) * as.numeric(oys) * n_sel * .dtype_bytes(m$dtype)
  if (est > max_bytes) {
    cli::cli_abort(c(
      "Fetch window for {.val {url}} would materialise {.val {round(est / 1e9, 2)}} GB ({.field {m$dtype}}).",
      "i" = "Narrow {.arg te}, coarsen {.arg tr}/{.arg ts}, select fewer {.arg bands}, or raise {.arg max_bytes}."
    ))
  }

  ovr_gt <- gt
  ovr_gt[2] <- gt[2] * fx; ovr_gt[3] <- gt[3] * fx
  ovr_gt[5] <- gt[5] * fy; ovr_gt[6] <- gt[6] * fy
  win_gt <- ovr_gt
  win_gt[1] <- ovr_gt[1] + oxoff * ovr_gt[2] + oyoff * ovr_gt[3]
  win_gt[4] <- ovr_gt[4] + oxoff * ovr_gt[5] + oyoff * ovr_gt[6]

  list(src = url, level = lvl, xoff = oxoff, yoff = oyoff,
       xsize = oxs, ysize = oys, win_gt = win_gt,
       src_wkt = gdalraster::srs_to_wkt(m$crs),
       nodata = m$nodata, is_copy = is_copy, crs = m$crs)
}

# TRUE when the target CRS is effectively the source CRS (no reprojection).
.srs_identity <- function(t_srs, src_crs) {
  if (is.null(t_srs) || identical(t_srs, src_crs)) return(TRUE)
  isTRUE(tryCatch(gdalraster::srs_is_same(t_srs, src_crs), error = function(e) FALSE))
}

# Full source extent (corner-based) as c(xmin, ymin, xmax, ymax).
.full_src_bbox <- function(gt, W, H) {
  cx <- c(0, W, 0, W); cy <- c(0, 0, H, H)
  x <- gt[1] + cx * gt[2] + cy * gt[3]
  y <- gt[4] + cx * gt[5] + cy * gt[6]
  c(min(x), min(y), max(x), max(y))
}

# Choose the finest overview whose decimation factor does not exceed the
# decimation implied by the requested output resolution. `src_bbox` is the
# fetch region in source CRS units; `tgt_bbox` is the matching extent in target
# CRS units. Falls back to full resolution when neither `tr` nor `ts` pins the
# output resolution (GDAL then uses ~native resolution anyway).
.pick_overview <- function(m, src_bbox, tgt_bbox, tr, ts) {
  src_px  <- abs(m$geotransform[2])
  tgt_span <- tgt_bbox[3] - tgt_bbox[1]
  src_span <- src_bbox[3] - src_bbox[1]
  scale <- if (tgt_span != 0) src_span / tgt_span else 1  # src units / target unit

  out_px_tgt <- if (!is.null(tr)) abs(as.numeric(tr)[1])
                else if (!is.null(ts)) tgt_span / as.numeric(ts)[1]
                else NA_real_
  out_px_src <- out_px_tgt * scale

  if (!is.finite(out_px_src)) return(1L)
  decim <- out_px_src / src_px
  if (!is.finite(decim) || decim < 1) return(1L)
  factors <- m$level_width[1] / m$level_width   # >= 1, increasing
  ok <- which(factors <= decim)
  if (length(ok) == 0L) 1L else max(ok)
}

# Format numbers as gdalwarp CLI tokens without scientific notation.
.numarg <- function(x) formatC(as.numeric(x), format = "f", digits = 10)
