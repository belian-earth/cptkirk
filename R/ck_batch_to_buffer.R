#' Fetch many grouped sources through one pool, into raw pixel buffers
#'
#' `ck_batch_to_buffer()` is [ck_batch()] with the per-output destination changed
#' from a GeoTIFF file to an **in-memory raw buffer**, exactly as
#' [ck_warp_to_buffer()] is [ck_warp()] with that change. It streams every asset
#' across every group through one global concurrency pool, and warps each output
#' into a raw band-sequential (BSQ) buffer via a GDAL `MEM` `DATAPOINTER` dataset
#' --- no GeoTIFF intermediate to encode and decode.
#'
#' Each per-tile buffer covers only that tile's warped footprint, snapped to the
#' shared `te`/`ts` (or `te`/`tr`) pixel lattice, so the tiles of a group tile the
#' target grid exactly and a consumer can mosaic them by georeference. Buffers are
#' therefore sized to their footprint, not to the whole area of interest.
#'
#' A target grid is required: pass `te` and one of `ts` / `tr`. Unlike
#' [ck_batch()], there is no file-copy path --- a buffer must be allocated at a
#' known pixel size.
#'
#' @inheritParams ck_batch
#' @inheritParams ck_warp_to_buffer
#' @param te Target extent `c(xmin, ymin, xmax, ymax)` (required), in `te_srs` if
#'   given, otherwise in `t_srs`. Defines the AOI and the shared lattice origin.
#' @param ts Target size `c(width, height)` in pixels for the full AOI grid; with
#'   `te` it sets the lattice resolution. Give either `ts` or `tr`.
#' @param tr Target resolution `c(xres, yres)` in target CRS units. Give either
#'   `tr` or `ts`.
#' @param max_bytes Safety ceiling (bytes) on the **running sum** of all
#'   allocated buffers across the batch (they are resident, raw and uncompressed,
#'   at once). `NULL` (default) uses ~1/3 of system RAM.
#' @return The buffer descriptors, mirroring the input structure. Each leaf is
#'   the list [ck_warp_to_buffer()] returns
#'   (`data`, `nx`, `ny`, `nbands`, `dtype`, `nodata`, `geotransform`, `crs`), or
#'   `NA` where a source did not overlap the AOI or its fetch failed (the latter
#'   warns). `stack = FALSE` (default) returns a list of lists of descriptors;
#'   `stack = TRUE` returns one descriptor per group (its sources stacked BSQ).
#' @seealso [ck_batch()] to write files, [ck_warp_to_buffer()] for a single source.
#' @export
ck_batch_to_buffer <- function(src, stack = FALSE,
                               t_srs = NULL, te = NULL, te_srs = NULL,
                               tr = NULL, ts = NULL,
                               r = c("near", "bilinear", "cubic", "cubicspline",
                                     "lanczos", "average", "rms", "mode", "max",
                                     "min", "med", "q1", "q3", "sum"),
                               bands = NULL, dtype = NULL, fill = NULL,
                               cl_arg = character(0),
                               num_threads = 1L, warp_memory = "auto",
                               cache_max = "auto", config = NULL,
                               overview = NULL, margin = 8L,
                               io_concurrency = 16L, prefetch = NULL,
                               max_bytes = NULL, sanitise = TRUE) {
  rlang::check_required(src)
  if (!is.list(src) || !length(src) ||
      !all(vapply(src, is.character, logical(1)))) {
    cli::cli_abort(c(
      "{.arg src} must be a non-empty list of character vectors.",
      "i" = "Each element is one output group (e.g. an acquisition's band URLs)."
    ))
  }
  rlang::check_bool(stack)
  rlang::check_string(t_srs, allow_null = TRUE)
  rlang::check_string(te_srs, allow_null = TRUE)
  .check_num_vec(te, 4L, "c(xmin, ymin, xmax, ymax)")
  .check_num_vec(tr, 2L, "c(xres, yres)", positive = TRUE)
  .check_num_vec(ts, 2L, "c(width, height)", positive = TRUE)
  .check_bands(bands)
  rlang::check_string(dtype, allow_null = TRUE)
  if (!is.null(fill) && (!rlang::is_scalar_double(fill) &&
                           !rlang::is_scalar_integerish(fill) || is.na(fill))) {
    cli::cli_abort("{.arg fill} must be a single non-missing number.")
  }
  cl_arg <- cl_arg %||% character(0)
  .check_chr(cl_arg)
  .check_threads(num_threads)
  .check_speed(warp_memory)
  .check_speed(cache_max)
  .check_config(config)
  .check_fetch_args(overview, margin, io_concurrency, max_bytes, sanitise)

  # A buffer must be allocated at a known pixel size, so the target grid must be
  # pinned: te plus exactly one of ts / tr (no file-copy path).
  if (is.null(te) || (is.null(ts) && is.null(tr))) {
    cli::cli_abort(c(
      "{.fn ck_batch_to_buffer} needs a pinned target grid.",
      "i" = "Pass {.arg te} and one of {.arg ts} / {.arg tr}."
    ))
  }
  if (!is.null(ts) && !is.null(tr)) {
    cli::cli_abort("Pass either {.arg tr} or {.arg ts}, not both.")
  }
  .check_warp_geometry(t_srs = t_srs, te = te, te_srs = te_srs, tr = tr, ts = ts)

  r_flat <- .resolve_per_src_r(r, src)
  te <- as.numeric(te)
  io <- io_concurrency %||% 16L
  max_bytes <- max_bytes %||% .default_max_bytes()

  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads, GDAL_MEM_ENABLE_OPEN = "YES"),
             as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )

  # Warp options only (no -te/-tr/-ts/-tap/-co): the per-tile MEM grid pins the
  # destination. Per-source -r is injected in the assembler. Geometry (te/ts/tr)
  # still drives planning + overview selection via .batch_collect_plan.
  warp_cl <- character(0)
  if (!is.null(num_threads) && !any(grepl("NUM_THREADS", cl_arg, fixed = TRUE))) {
    warp_cl <- c(warp_cl, "-wo", paste0("NUM_THREADS=", num_threads))
  }
  wm <- .resolve_speed(warp_memory, .default_warp_mem)
  if (!is.null(wm) && !any(cl_arg == "-wm")) warp_cl <- c(warp_cl, "-wm", as.character(wm))
  warp_cl <- c(warp_cl, cl_arg)

  all_urls <- unlist(src, use.names = FALSE)
  cp <- .batch_collect_plan(all_urls, t_srs = t_srs, te = te, te_srs = te_srs,
                            tr = tr, ts = if (is.null(ts)) NULL else as.numeric(ts),
                            bands = bands, cl_arg = warp_cl, overview = overview,
                            margin = margin, max_bytes = max_bytes,
                            sanitise = sanitise)
  keep <- which(!vapply(cp$plans, is.null, logical(1)))
  if (!length(keep)) {
    cli::cli_abort(c(
      "Requested extent does not overlap any source raster.",
      "i" = "Check {.arg te} (and {.arg te_srs}/{.arg t_srs}) cover the source footprint(s)."
    ))
  }
  ps <- cp$plans[keep]
  g <- function(k) vapply(ps, `[[`, integer(1), k)
  session <- cog_fetch_stream_begin(
    cp$ptr, idx = as.integer(keep),
    level = g("level"), xoff = g("xoff"), yoff = g("yoff"),
    xsize = g("xsize"), ysize = g("ysize"),
    bands = if (is.null(bands)) integer(0) else as.integer(bands),
    fill = cp$nodata %||% 0, io_concurrency = io,
    prefetch = if (is.null(prefetch)) -1L else as.integer(prefetch)
  )

  grid <- .buffer_lattice(te, te_srs, tr, ts, cp$t_srs_warp)
  .batch_stream_run_to_buffer(src, stack, cp$plans, session, r_flat, warp_cl,
                              cp$t_srs_warp, cp$nodata, grid, dtype, fill,
                              max_bytes)
}

# The shared target lattice: origin (te top-left in the target CRS), pixel size
# (rx, ry), and the full-AOI pixel dims that bound each tile's clipped window.
# Derived from te + (ts | tr); every tile snaps to this grid so a group's tiles
# tile it exactly.
.buffer_lattice <- function(te, te_srs, tr, ts, t_srs_warp) {
  te_tgt <- if (!is.null(te_srs) && !.srs_identity(te_srs, t_srs_warp)) {
    gdalraster::transform_bounds(te, te_srs, t_srs_warp)
  } else {
    te
  }
  if (!is.null(ts)) {
    nx_full <- as.integer(round(as.numeric(ts)[1]))
    ny_full <- as.integer(round(as.numeric(ts)[2]))
    rx <- (te_tgt[3] - te_tgt[1]) / nx_full
    ry <- (te_tgt[4] - te_tgt[2]) / ny_full
  } else {
    rx <- abs(as.numeric(tr)[1]); ry <- abs(as.numeric(tr)[2])
    nx_full <- as.integer(ceiling((te_tgt[3] - te_tgt[1]) / rx))
    ny_full <- as.integer(ceiling((te_tgt[4] - te_tgt[2]) / ry))
  }
  list(te_tgt = te_tgt, rx = rx, ry = ry, nx_full = nx_full, ny_full = ny_full,
       t_wkt = gdalraster::srs_to_wkt(t_srs_warp), t_srs_warp = t_srs_warp)
}

# The clipped target-grid window covering the union of `plans`' source windows:
# transform each window's source-CRS bbox to the target CRS, union, snap OUTWARD
# to the lattice, and clip to the full AOI. Returns list(nx, ny, gt, t_wkt,
# t_srs_warp), or NULL if the union does not intersect the AOI.
.target_window_on_lattice <- function(plans, grid) {
  tb <- NULL
  for (p in plans) {
    wg <- p$win_gt; W <- p$xsize; H <- p$ysize
    cx <- c(0, W, 0, W); cy <- c(0, 0, H, H)
    sx <- wg[1] + cx * wg[2] + cy * wg[3]
    sy <- wg[4] + cx * wg[5] + cy * wg[6]
    sb <- c(min(sx), min(sy), max(sx), max(sy))
    b <- if (.srs_identity(grid$t_srs_warp, p$crs)) sb
         else gdalraster::transform_bounds(sb, p$crs, grid$t_srs_warp)
    tb <- if (is.null(tb)) b else
      c(min(tb[1], b[1]), min(tb[2], b[2]), max(tb[3], b[3]), max(tb[4], b[4]))
  }
  ox <- grid$te_tgt[1]; oy <- grid$te_tgt[4]; rx <- grid$rx; ry <- grid$ry
  col0 <- max(0L, as.integer(floor((tb[1] - ox) / rx)))
  col1 <- min(grid$nx_full, as.integer(ceiling((tb[3] - ox) / rx)))
  row0 <- max(0L, as.integer(floor((oy - tb[4]) / ry)))
  row1 <- min(grid$ny_full, as.integer(ceiling((oy - tb[2]) / ry)))
  if (col1 <= col0 || row1 <= row0) return(NULL)
  list(nx = col1 - col0, ny = row1 - row0,
       gt = c(ox + col0 * rx, rx, 0, oy - row0 * ry, 0, -ry),
       t_wkt = grid$t_wkt, t_srs_warp = grid$t_srs_warp)
}

# Assemble already-fetched windows into buffer descriptor(s) at the pre-computed
# `geom` (target grid window). stack = FALSE: one window -> one descriptor.
# stack = TRUE: each source is warped into its own buffer on the shared `geom`,
# then the BSQ planes are concatenated in source order into one descriptor.
.stack_assemble_to_buffer <- function(ws, plans, geom, cl_arg, t_srs_warp,
                                       nodata, dtype, fill, envir, r_each = NULL) {
  vrts <- .warp_stage(ws, plans, envir)
  descs <- lapply(seq_along(vrts), function(i) {
    out_dtype <- dtype %||% ws[[i]]$dtype
    nb <- ws[[i]]$n_bands
    fill_val <- fill %||% plans[[i]]$nodata %||% nodata %||% 0
    warp_cl <- if (is.null(r_each)) cl_arg else c(cl_arg, "-r", r_each[[i]])
    .warp_vrts_to_buffer(vrts[[i]], nx = geom$nx, ny = geom$ny, nbands = nb,
                         out_dtype = out_dtype, fill_val = fill_val, gt = geom$gt,
                         t_wkt = geom$t_wkt, t_srs_warp = t_srs_warp,
                         warp_cl = warp_cl)
  })
  if (length(descs) == 1L) return(descs[[1]])
  list(data = do.call(c, lapply(descs, `[[`, "data")),
       nx = geom$nx, ny = geom$ny,
       nbands = sum(vapply(descs, `[[`, integer(1), "nbands")),
       dtype = descs[[1]]$dtype, nodata = descs[[1]]$nodata,
       geotransform = geom$gt, crs = geom$t_wkt)
}

# Drain the streaming fetch into buffer descriptors, one per output, computing
# each output's clipped lattice window in the parent (so the running-memory
# ceiling can be enforced before allocation) and warping on arrival --- overlaps
# with in-flight fetches, and dispatches across an ambient mirai pool if running.
# Mirrors .batch_stream_run (the file variant); kept separate so ck_batch is
# untouched. See that function for the accumulation/ordering rationale.
.batch_stream_run_to_buffer <- function(src, stack, plans, session, r_flat,
                                         cl_base, t_srs_warp, nodata, grid,
                                         dtype, fill, max_bytes) {
  ng <- length(src)
  grp_of <- rep(seq_len(ng), lengths(src))
  band_of <- unlist(lapply(src, seq_along), use.names = FALSE)
  surv <- !vapply(plans, is.null, logical(1))
  need <- vapply(seq_len(ng), function(gi) sum(surv[grp_of == gi]), integer(1))

  # Running sum of allocated buffer bytes; all descriptors are resident at once.
  alloc <- 0
  guard_alloc <- function(geom, nb_total, out_dtype) {
    add <- as.numeric(geom$nx) * as.numeric(geom$ny) * nb_total *
      .dtype_bytes(out_dtype)
    alloc <<- alloc + add
    if (alloc > max_bytes) {
      cli::cli_abort(c(
        "Batch buffers would total {.val {round(alloc / 1e9, 2)}} GB, over {.arg max_bytes}.",
        "i" = "Coarsen {.arg ts}/{.arg tr}, narrow {.arg te}, select fewer {.arg bands}, raise {.arg max_bytes}, or use {.fn ck_batch} (compressed files)."
      ))
    }
  }

  use_par <- .batch_use_parallel()
  if (use_par) {
    mirai::everywhere({
      if (!"cptkirk" %in% loadedNamespaces()) library(cptkirk)
      requireNamespace("mori", quietly = TRUE)
    })
  }
  dispatch <- function(ws_u, pl_u, geom_u, r_u) {
    if (use_par) {
      mirai::mirai(
        getFromNamespace(".stack_assemble_to_buffer", "cptkirk")(ws_u, pl_u,
          geom_u, cl_arg = cl_base, t_srs_warp = t_srs_warp, nodata = nodata,
          dtype = dtype, fill = fill, envir = environment(), r_each = r_u),
        ws_u = ws_u, pl_u = pl_u, geom_u = geom_u, r_u = r_u, cl_base = cl_base,
        t_srs_warp = t_srs_warp, nodata = nodata, dtype = dtype, fill = fill)
    } else {
      .stack_assemble_to_buffer(ws_u, pl_u, geom_u, cl_arg = cl_base,
        t_srs_warp = t_srs_warp, nodata = nodata, dtype = dtype, fill = fill,
        envir = environment(), r_each = r_u)
    }
  }

  out <- vector("list", length(grp_of))
  acc <- vector("list", ng); have <- integer(ng)
  failed <- list()

  repeat {
    rcv <- cog_fetch_take(session)
    if (is.null(rcv)) break
    if (!is.null(rcv$error)) {
      failed[[length(failed) + 1L]] <- list(src = plans[[rcv$index]]$src %||% NA_character_,
                                            error = rcv$error)
      next
    }
    si <- rcv$index
    w <- list(bytes = rcv$bytes, xsize = rcv$xsize, ysize = rcv$ysize,
              n_bands = rcv$n_bands, dtype = rcv$dtype,
              bytes_per_sample = rcv$bytes_per_sample, byte_order = rcv$byte_order)
    if (use_par) w$bytes <- mori::share(w$bytes)
    pl <- plans[[si]]
    gi <- grp_of[si]
    if (!stack) {
      geom <- .target_window_on_lattice(list(pl), grid)
      if (!is.null(geom)) {
        guard_alloc(geom, w$n_bands, dtype %||% w$dtype)
        out[[si]] <- dispatch(list(w), list(pl), geom, r_flat[si])
      }
    } else {
      have[gi] <- have[gi] + 1L
      acc[[gi]] <- c(acc[[gi]], list(list(bw = band_of[si], w = w, pl = pl,
                                          r = r_flat[si])))
      if (have[gi] >= need[gi]) {
        e <- acc[[gi]][order(vapply(acc[[gi]], `[[`, integer(1), "bw"))]
        pls <- lapply(e, `[[`, "pl")
        geom <- .target_window_on_lattice(pls, grid)
        if (!is.null(geom)) {
          nb_tot <- sum(vapply(e, function(x) x$w$n_bands, integer(1)))
          guard_alloc(geom, nb_tot, dtype %||% e[[1]]$w$dtype)
          out[[gi]] <- dispatch(lapply(e, `[[`, "w"), pls, geom,
                                vapply(e, `[[`, character(1), "r"))
        }
        acc[gi] <- list(NULL)
      }
    }
  }

  if (length(failed)) {
    srcs <- vapply(failed, `[[`, character(1), "src")
    cli::cli_warn(c(
      "!" = "{length(failed)} source{?s} failed to fetch; affected output{?s} {?is/are} {.val NA}.",
      "i" = "First failure: {.file {srcs[1]}} ({failed[[1]]$error})",
      "i" = "This is distinct from a source that simply did not overlap the AOI."
    ))
  }

  collect1 <- function(x) {
    if (is.null(x)) return(NA)
    v <- if (inherits(x, "mirai")) mirai::collect_mirai(x) else x
    if (is.list(v) && !is.null(v$data)) v else NA
  }
  if (stack) {
    stats::setNames(lapply(out[seq_len(ng)], collect1), names(src))
  } else {
    leaves <- lapply(out, collect1)
    res <- lapply(seq_len(ng), function(gi) {
      stats::setNames(leaves[grp_of == gi], names(src[[gi]]))
    })
    stats::setNames(res, names(src))
  }
}
