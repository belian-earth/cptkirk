#' Warp a remote GeoTIFF / COG with cptkirk's defaults (recommended)
#'
#' The recommended, batteries-included entry point. `ck_warp()` takes the
#' grid-defining `gdalwarp` options as named arguments (`t_srs`, `te`, `tr`,
#' `ts`, `r`, `bands`), layers on cptkirk's performance defaults (multi-threaded
#' warp, generous warp memory and block cache, `SKIP_NOSOURCE`), and streams
#' only the pixels the request touches over `async-tiff` before handing the
#' warp to GDAL via [gdalraster::warp()]. For a faithful, defaults-free sibling
#' of [gdalraster::warp()], see [warp_remote()].
#'
#' Every actual resampling / reprojection decision is GDAL's; cptkirk only sizes
#' and saturates the fetch.
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
#' @param tr Target resolution `c(xres, yres)` in target CRS units. Takes
#'   precedence over `ts`: if both are given, `ts` is ignored (with a warning).
#' @param ts Target size `c(width, height)` in pixels. Ignored if `tr` is also
#'   supplied.
#' @param tap If `TRUE` (default) and `tr` is given, align output pixel
#'   boundaries to the `tr` grid (gdalwarp `-tap`), anchored at the CRS origin,
#'   so outputs at the same resolution share a grid and stack cleanly. This
#'   snaps the output extent outward, so it is no longer exactly `te`. No effect
#'   with `ts` or on the copy path. An explicit `-tap` in `cl_arg` is always
#'   honoured. (`warp_remote()` never adds this; pass `-tap` yourself.)
#' @param r Resampling method, one of `"near"` (default), `"bilinear"`,
#'   `"cubic"`, `"cubicspline"`, `"lanczos"`, `"average"`, `"rms"`, `"mode"`,
#'   `"max"`, `"min"`, `"med"`, `"q1"`, `"q3"`, `"sum"`. Matched with
#'   [rlang::arg_match()], so a typo reports the valid set. (A method added by a
#'   newer GDAL than this list knows can still be passed via `cl_arg`.)
#' @param bands 1-based source bands to read (default: all). Subsetting happens
#'   during the fetch, so only those bands' bytes are streamed.
#' @param cl_arg Character vector of extra raw `gdalwarp` flags, forwarded
#'   verbatim to [gdalraster::warp()] (e.g. `c("-et", "0")`). These are merged
#'   with the flags cptkirk builds from the named arguments above.
#' @param num_threads Value for GDAL's warp `NUM_THREADS` warp option and the
#'   `GDAL_NUM_THREADS` config (default `"ALL_CPUS"`), parallelising the
#'   resampling computation and GeoTIFF (de)compression. `NULL` sets neither,
#'   deferring to the ambient `GDAL_NUM_THREADS` (env / session).
#' @param warp_memory Warp working memory in MB (GDAL `-wm`). `"auto"`
#'   (default) uses ~25% of system RAM, clamped to 256-2048 MB (bigger means
#'   fewer, larger chunks); `NULL` defers to GDAL's own default; a number sets
#'   it explicitly.
#' @param cache_max GDAL block cache in MB for this call. `"auto"` (default)
#'   uses ~25% of RAM, clamped to 256-2000 MB; `NULL` defers to the ambient
#'   `GDAL_CACHEMAX` (env / `gdalraster::set_config_option()`); a number sets it
#'   explicitly. Any value is restored to the previous setting afterwards.
#' @param co Character vector of GDAL output creation options, e.g.
#'   `c("COMPRESS=ZSTD", "TILED=YES", "NUM_THREADS=ALL_CPUS")`.
#' @param config Named character vector / list of extra GDAL config options to
#'   set for the duration of the call (restored on exit).
#' @param skip_nosource If `TRUE` (default), pass `SKIP_NOSOURCE=YES` +
#'   `INIT_DEST` so the warper skips output chunks with no source coverage
#'   (e.g. nodata margins from reprojection). No effect when output is fully
#'   covered. Ignored on the copy fast-path.
#' @param overview Force a 1-based IFD/overview level instead of auto-selecting
#'   from the output resolution. `1` = full resolution.
#' @param margin Source-pixel margin added around the computed window to cover
#'   the resampling kernel and reprojection slop (default 8).
#' @param io_concurrency Number of concurrent tile reads -- the width of the
#'   single global fetch pool shared across all source tiles. Default 16, which
#'   suits object stores that throttle around that many simultaneous range
#'   requests (e.g. S3 / source.coop). Raise (24-32) on a fast, stable link;
#'   lower if a store rate-limits.
#' @param max_bytes Safety ceiling (bytes) on the staged in-memory window
#'   (`width * height * bands * <native dtype bytes>`). `NULL` (default) uses
#'   ~1/3 of system RAM. It only guards against the foot-gun of warping a whole
#'   large multi-band raster at native resolution; narrow the request, coarsen
#'   `tr`/`ts`, or raise this to allow it.
#' @param sanitise If `TRUE` (default), validate the warp arguments against a
#'   tiny metadata-derived stand-in *before* fetching, so a bad CRS, resampling
#'   method, creation option or unknown flag fails in milliseconds instead of
#'   after a remote read. Set `FALSE` to skip the check.
#' @return The `dst` path, invisibly.
#' @seealso [warp_remote()] for the thin [gdalraster::warp()] sibling.
#' @export
ck_warp <- function(src, dst,
                    t_srs = NULL, te = NULL, te_srs = NULL,
                    tr = NULL, ts = NULL, tap = TRUE,
                    r = c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                          "average", "rms", "mode", "max", "min", "med",
                          "q1", "q3", "sum"),
                    bands = NULL, cl_arg = character(0),
                    num_threads = "ALL_CPUS", warp_memory = "auto",
                    cache_max = "auto", co = NULL, config = NULL,
                    skip_nosource = TRUE,
                    overview = NULL, margin = 8L,
                    io_concurrency = 16L, max_bytes = NULL, sanitise = TRUE) {
  rlang::check_required(src)
  rlang::check_required(dst)
  .check_src(src)
  if (!rlang::is_string(dst)) {
    cli::cli_abort("{.arg dst} must be a single output path string.")
  }
  rlang::check_string(t_srs, allow_null = TRUE)
  rlang::check_string(te_srs, allow_null = TRUE)
  .check_num_vec(te, 4L, "c(xmin, ymin, xmax, ymax)")
  .check_num_vec(tr, 2L, "c(xres, yres)", positive = TRUE)
  .check_num_vec(ts, 2L, "c(width, height)", positive = TRUE)
  rlang::check_bool(tap)
  r <- rlang::arg_match(r)
  .check_bands(bands)
  cl_arg <- cl_arg %||% character(0)
  .check_chr(cl_arg)
  .check_threads(num_threads)
  .check_speed(warp_memory)
  .check_speed(cache_max)
  .check_chr(co, allow_null = TRUE)
  .check_config(config)
  rlang::check_bool(skip_nosource)
  .check_fetch_args(overview, margin, io_concurrency, max_bytes, sanitise)

  # tr is the primary resolution control: if both are given, tr wins.
  if (!is.null(tr) && !is.null(ts)) {
    cli::cli_warn("Both {.arg tr} and {.arg ts} supplied; using {.arg tr} and ignoring {.arg ts}.")
    ts <- NULL
  }

  if (!is.null(te)) te <- as.numeric(te)
  io <- io_concurrency %||% 16L
  max_bytes <- max_bytes %||% .default_max_bytes()

  # Scope GDAL speed config to this call (restored on exit). Each knob defers
  # to the ambient env/session value when set to NULL (GDAL_NUM_THREADS is
  # simply omitted; the cache is left untouched).
  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads), as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )

  # Assemble the gdalwarp argument vector from the named options + cptkirk's
  # performance defaults; the engine handles SKIP_NOSOURCE/INIT_DEST (which
  # depend on the source nodata) once metadata is read.
  args <- character(0)
  if (!is.null(te))     args <- c(args, "-te", .numarg(te))
  if (!is.null(te_srs)) args <- c(args, "-te_srs", te_srs)
  if (!is.null(tr))     args <- c(args, "-tr", .numarg(tr))
  if (!is.null(ts))     args <- c(args, "-ts",
                                   format(as.integer(round(as.numeric(ts))),
                                          scientific = FALSE, trim = TRUE))
  if (!is.null(r))      args <- c(args, "-r", r)
  # Align output pixels to the tr grid (anchored at the CRS origin) by default,
  # so outputs at the same resolution share a grid and stack cleanly. Only
  # meaningful with tr; an explicit -tap in cl_arg is left as-is.
  if (isTRUE(tap) && !is.null(tr) && !any(cl_arg == "-tap")) {
    args <- c(args, "-tap")
  }
  if (!is.null(num_threads) && !any(grepl("NUM_THREADS", cl_arg, fixed = TRUE))) {
    args <- c(args, "-wo", paste0("NUM_THREADS=", num_threads))
  }
  wm <- .resolve_speed(warp_memory, .default_warp_mem)
  if (!is.null(wm) && !any(cl_arg == "-wm")) {
    args <- c(args, "-wm", as.character(wm))
  }
  if (length(co)) {
    args <- c(args, as.vector(rbind("-co", co)))
  }
  args <- c(args, cl_arg)

  .warp_engine(src, dst, t_srs = t_srs, te = te, te_srs = te_srs, tr = tr,
               ts = ts, bands = bands, cl_arg = args, overview = overview,
               margin = margin, io = io, max_bytes = max_bytes, quiet = TRUE,
               skip_nosource = skip_nosource, sanitise = sanitise)
}
