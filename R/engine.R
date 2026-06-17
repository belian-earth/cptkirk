# Shared warp engine + argument sanitiser.
#
# Both public entry points -- the thin gdalraster sibling [warp_remote()] and
# the opinionated helper [ck_warp()] -- funnel into `.warp_engine()`. The
# caller resolves the geometry (named args, or parsed from `cl_arg`) and hands
# over the *final* gdalwarp argument vector; the engine reads metadata,
# sanitises the args against a tiny stand-in (before any fetch), plans each
# source's pixel window, streams the bytes, stages them in `/vsimem`, and lets
# GDAL perform the warp. It reimplements none of GDAL's warp logic.

# Number of value tokens that follow known multi-token gdalwarp/translate flags.
.CL_ARITY <- c("-te" = 4L, "-tr" = 2L, "-ts" = 2L, "-te_srs" = 1L, "-r" = 1L,
               "-of" = 1L, "-ot" = 1L, "-co" = 1L, "-wo" = 1L, "-wm" = 1L,
               "-s_srs" = 1L, "-t_srs" = 1L, "-srcnodata" = 1L,
               "-dstnodata" = 1L, "-et" = 1L)

# First value(s) of a flag in a gdalwarp arg vector (NULL if absent).
.cl_val <- function(cl, flag, n = .CL_ARITY[[flag]]) {
  i <- which(cl == flag)
  if (!length(i)) return(NULL)
  i <- i[1]
  if (i + n > length(cl)) {
    cli::cli_abort("{.code {flag}} expects {n} value{?s} in {.arg cl_arg}.")
  }
  cl[(i + 1L):(i + n)]
}

# Every occurrence's value(s) for a repeatable flag (e.g. -co), as a list.
.cl_all <- function(cl, flag, n = .CL_ARITY[[flag]]) {
  idx <- which(cl == flag)
  lapply(idx, function(i) {
    if (i + n > length(cl)) {
      cli::cli_abort("{.code {flag}} expects {n} value{?s} in {.arg cl_arg}.")
    }
    cl[(i + 1L):(i + n)]
  })
}

# Drop one or more flags (and their value tokens) from a gdalwarp arg vector.
.cl_strip <- function(cl, flags) {
  drop <- integer(0); i <- 1L
  while (i <= length(cl)) {
    if (cl[i] %in% flags) {
      n <- .CL_ARITY[[cl[i]]]; if (is.null(n) || is.na(n)) n <- 0L
      drop <- c(drop, i:(i + n)); i <- i + n + 1L
    } else {
      i <- i + 1L
    }
  }
  if (length(drop)) cl[-drop] else cl
}

# Pull the geometry the engine needs for planning out of a raw cl_arg vector
# (the thin sibling's job). cl_arg itself is still handed to GDAL verbatim.
.cl_geom <- function(cl_arg) {
  num <- function(v) if (is.null(v)) NULL else as.numeric(v)
  list(te = num(.cl_val(cl_arg, "-te", 4L)),
       te_srs = .cl_val(cl_arg, "-te_srs", 1L),
       tr = num(.cl_val(cl_arg, "-tr", 2L)),
       ts = num(.cl_val(cl_arg, "-ts", 2L)))
}

# Output-format options (translate understands these too) for the copy path.
.translate_out_args <- function(cl) {
  out <- character(0)
  of <- .cl_val(cl, "-of", 1L); if (!is.null(of)) out <- c(out, "-of", of)
  ot <- .cl_val(cl, "-ot", 1L); if (!is.null(ot)) out <- c(out, "-ot", ot)
  for (co in .cl_all(cl, "-co", 1L)) out <- c(out, "-co", co)
  out
}

# Format numbers as gdalwarp CLI tokens without scientific notation.
.numarg <- function(x) formatC(as.numeric(x), format = "f", digits = 10)

.warp_engine <- function(src, dst, t_srs, te, te_srs, tr, ts, bands,
                         cl_arg, overview, margin, io, max_bytes,
                         quiet = TRUE, skip_nosource = FALSE, sanitise = TRUE) {
  bands0 <- if (is.null(bands)) integer(0) else as.integer(bands)

  # Sanitise (1/2): structural checks on the geometry -- CRS parse, extent,
  # resolution, output dimensions. These need no source, so they run before the
  # header read: a malformed request fails with zero remote contact.
  if (isTRUE(sanitise)) {
    .check_warp_geometry(t_srs = t_srs, te = te, te_srs = te_srs, tr = tr, ts = ts)
  }

  reuse <- inherits(src, "cog_source")
  urls <- if (reuse) src$src else as.character(src)
  metas <- if (reuse) list(cog_meta(src$ptr)) else cog_meta_many(urls)

  # Sanitise (2/2): probe the GDAL options against a tiny synthetic in-memory
  # raster built from the header metadata (no pixels fetched), catching a bad
  # resampling method / creation option / driver / unknown flag before the
  # fetch rather than after a multi-second remote read.
  if (isTRUE(sanitise)) {
    .probe_warp(metas[[1]], t_srs = t_srs, cl_arg = cl_arg, dst = dst)
  }

  # --- plan each tile's window (R/PROJ), then fetch + stage -----------------
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
  # orientation-agnostic (handles south-up sources). Warp-only flags (-wo, -wm,
  # -multi, ...) don't affect an identity copy, so only output-format options
  # (-of/-ot/-co) carry over.
  if (n == 1L && isTRUE(plans[[1]]$is_copy)) {
    if (file.exists(dst)) unlink(dst)
    gdalraster::translate(vrts, dst, cl_arg = .translate_out_args(cl_arg),
                          quiet = quiet)
    return(invisible(dst))
  }

  # --- hand the (mosaic) warp to GDAL ---------------------------------------
  warp_args <- cl_arg
  # Skip output chunks with no source coverage (e.g. nodata margins from
  # reprojection); paired with INIT_DEST so skipped chunks are initialised.
  # Done here because the right INIT_DEST value depends on the source nodata,
  # which is only known once metadata is read.
  if (isTRUE(skip_nosource) && !any(grepl("SKIP_NOSOURCE", cl_arg, fixed = TRUE))) {
    warp_args <- c(warp_args, "-wo", "SKIP_NOSOURCE=YES")
    if (!any(grepl("INIT_DEST", cl_arg, fixed = TRUE))) {
      warp_args <- c(warp_args, "-wo",
                     if (!is.null(nodata)) "INIT_DEST=NO_DATA" else "INIT_DEST=0")
    }
  }
  gdalraster::warp(src_files = vrts, dst_filename = dst, t_srs = t_srs_warp,
                   cl_arg = warp_args, quiet = quiet)
  invisible(dst)
}

# Sanitiser, layer 1: structural checks on the requested geometry -- CRS parse,
# extent ordering, resolution positivity, output dimensions. Needs no source,
# so it runs before the header read. Aborts on the first problem.
.check_warp_geometry <- function(t_srs, te, te_srs, tr, ts) {
  chk_srs <- function(s, arg) {
    if (!is.null(s) && nzchar(s)) {
      tryCatch(
        gdalraster::srs_to_wkt(s),
        error = function(e) cli::cli_abort(
          "{.arg {arg}} is not a CRS GDAL can parse: {.val {s}}.", parent = e
        )
      )
    }
  }
  chk_srs(t_srs, "t_srs")
  chk_srs(te_srs, "te_srs")

  if (!is.null(te)) {
    if (length(te) != 4L || anyNA(te)) {
      cli::cli_abort("{.arg te} must be {.code c(xmin, ymin, xmax, ymax)}.")
    }
    if (te[3] <= te[1] || te[4] <= te[2]) {
      cli::cli_abort("{.arg te} is empty: need {.code xmax > xmin} and {.code ymax > ymin}.")
    }
  }
  if (!is.null(tr) && (length(tr) != 2L || anyNA(tr) || any(tr <= 0))) {
    cli::cli_abort("{.arg tr} must be two positive numbers {.code c(xres, yres)}.")
  }
  if (!is.null(ts) && (length(ts) != 2L || anyNA(ts) || any(ts <= 0))) {
    cli::cli_abort("{.arg ts} must be two positive sizes {.code c(width, height)}.")
  }
  if (!is.null(tr) && !is.null(ts)) {
    cli::cli_abort("Pass either {.arg tr} or {.arg ts}, not both.")
  }
  # Output dimensions must fit GDAL's signed-int raster size limit.
  if (!is.null(te)) {
    dims <- if (!is.null(tr)) {
      c(ceiling((te[3] - te[1]) / tr[1]), ceiling((te[4] - te[2]) / abs(tr[2])))
    } else if (!is.null(ts)) {
      as.numeric(ts)
    } else {
      NULL
    }
    if (!is.null(dims) && any(dims >= .Machine$integer.max)) {
      cli::cli_abort(c(
        "Output grid would be {.val {dims[1]}} x {.val {dims[2]}} px, beyond GDAL's size limit.",
        "i" = "Coarsen {.arg tr}/{.arg ts} or shrink {.arg te}."
      ))
    }
  }

  invisible(TRUE)
}

# Sanitiser, layer 2: run the real warp arguments against a tiny synthetic
# stand-in to surface anything GDAL itself would reject (bad resampling
# method, invalid creation option, unknown flag, unrecognised driver). The
# stand-in is a 4x4 raster built in /vsimem from the header metadata (its CRS,
# dtype and band count, so creation-option checks stay faithful) -- NO source
# pixels are fetched. Geometry flags are stripped so the probe output stays
# tiny. Aborts with the GDAL message on failure.
.probe_warp <- function(m, t_srs, cl_arg, dst) {
  ext <- .full_src_bbox(m$geotransform, m$level_width[1], m$level_height[1])
  gt <- c(ext[1], (ext[3] - ext[1]) / 4, 0, ext[4], 0, -(ext[4] - ext[2]) / 4)

  id <- basename(tempfile("cptkirk_probe_"))
  psrc <- sprintf("/vsimem/%s_src.tif", id)
  of <- .cl_val(cl_arg, "-of", 1L)
  pext <- if (!is.null(of)) "out" else {
    e <- tools::file_ext(dst); if (nzchar(e)) e else "tif"
  }
  pdst <- sprintf("/vsimem/%s_dst.%s", id, pext)
  on.exit({
    try(gdalraster::vsi_unlink(psrc), silent = TRUE)
    try(gdalraster::vsi_unlink(pdst), silent = TRUE)
  }, add = TRUE)

  ds <- gdalraster::create("GTiff", psrc, 4L, 4L, m$n_bands, m$dtype,
                           return_obj = TRUE)
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt(m$crs))
  if (!is.null(m$nodata)) {
    for (b in seq_len(m$n_bands)) try(ds$setNoDataValue(b, m$nodata), silent = TRUE)
  }
  ds$close()

  # Geometry flags removed so the probe output stays tiny; the unique /vsimem
  # destination needs no -overwrite (and adding one could duplicate the
  # caller's own).
  probe_args <- .cl_strip(cl_arg, c("-te", "-te_srs", "-tr", "-ts"))
  tryCatch(
    gdalraster::warp(psrc, pdst, t_srs = t_srs %||% m$crs,
                     cl_arg = probe_args, quiet = TRUE),
    error = function(e) cli::cli_abort(c(
      "GDAL rejected the warp arguments (checked before any data was fetched).",
      "x" = conditionMessage(e),
      "i" = "Fix the offending {.arg cl_arg}/option; no remote data was downloaded."
    ), parent = e)
  )
  invisible(TRUE)
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
