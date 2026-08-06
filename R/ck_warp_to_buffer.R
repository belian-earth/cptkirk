#' Warp a remote GeoTIFF / COG into a raw native-dtype pixel buffer
#'
#' `ck_warp_to_buffer()` is [ck_warp()] with the final destination changed from a
#' GeoTIFF file to an **in-memory raw buffer**: it streams only the tiles the
#' request touches, warps them with GDAL (the same engine, sanitiser and fetch
#' defaults as [ck_warp()]) onto a fixed target grid, and fills a raw R vector in
#' place through a GDAL `MEM` `DATAPOINTER` dataset --- no GeoTIFF intermediate.
#'
#' The target grid is defined exactly by `te` + `ts`: the output is a `ts[1]` x
#' `ts[2]` (width x height) grid spanning `te`, so callers get back the precise
#' grid they asked for (no `-tap` snapping). The buffer holds the pixels
#' **band-sequentially (BSQ)**: band 1's full `ny` x `nx` plane, then band 2's,
#' and so on; each plane is **row-major** with row 0 the northern edge; samples
#' are in the source's **native data type** and host byte order. This is the
#' layout a downstream engine (garry) uploads and fuses a decode onto.
#'
#' @inheritParams ck_warp
#' @param te Target extent `c(xmin, ymin, xmax, ymax)` (required), in `te_srs` if
#'   given, otherwise in `t_srs`. Defines the buffer's geographic footprint.
#' @param ts Target size `c(width, height)` in pixels (required). Defines the
#'   buffer's dimensions exactly. `tr` is not accepted here: the buffer must be
#'   allocated at a known pixel size, so the grid is pinned by `ts`.
#' @param dtype Optional output data type as a GDAL type name (e.g.
#'   `"Float32"`). `NULL` (default) keeps the source's native type, so the
#'   caller receives the raw codes; set it to have GDAL convert during the warp.
#' @param fill Value written to output pixels no source covers (and used to
#'   pre-fill the buffer). `NULL` (default) uses the source nodata, falling back
#'   to `0`. Returned as `nodata` so the caller can mask untouched pixels ---
#'   important for integer types, which have no `NaN`.
#' @param max_bytes Safety ceiling (bytes) on the returned buffer, sized as
#'   `width * height * bands * <dtype bytes>`. `NULL` (default) uses ~1/3 of
#'   system RAM.
#' @return A list describing the filled buffer:
#'   \describe{
#'     \item{data}{the raw vector, `nx * ny * nbands * <dtype bytes>` bytes, BSQ.}
#'     \item{nx, ny}{output width and height in pixels.}
#'     \item{nbands}{number of bands (after any `bands` subset).}
#'     \item{dtype}{GDAL data-type name of the samples.}
#'     \item{nodata}{the `fill` value (untouched-pixel sentinel).}
#'     \item{geotransform}{the 6-element output geotransform (in the target CRS).}
#'     \item{crs}{the target CRS as WKT.}
#'   }
#' @seealso [ck_warp()] to write a warped file, [ck_read()] for an R array.
#' @export
ck_warp_to_buffer <- function(src, t_srs = NULL, te, ts, te_srs = NULL,
                              r = c("near", "bilinear", "cubic", "cubicspline",
                                    "lanczos", "average", "rms", "mode", "max",
                                    "min", "med", "q1", "q3", "sum"),
                              bands = NULL, dtype = NULL, fill = NULL,
                              cl_arg = character(0),
                              num_threads = "ALL_CPUS", warp_memory = "auto",
                              cache_max = "auto", config = NULL,
                              overview = NULL, margin = 8L,
                              io_concurrency = 16L, max_bytes = NULL,
                              sanitise = TRUE) {
  rlang::check_required(src)
  rlang::check_required(te)
  rlang::check_required(ts)
  .check_src(src)
  rlang::check_string(t_srs, allow_null = TRUE)
  rlang::check_string(te_srs, allow_null = TRUE)
  .check_num_vec(te, 4L, "c(xmin, ymin, xmax, ymax)")
  .check_num_vec(ts, 2L, "c(width, height)", positive = TRUE)
  r <- rlang::arg_match(r)
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

  te <- as.numeric(te)
  nx <- as.integer(round(as.numeric(ts)[1])); ny <- as.integer(round(as.numeric(ts)[2]))
  io <- io_concurrency %||% 16L
  max_bytes <- max_bytes %||% .default_max_bytes()

  # Scope GDAL speed config to this call (restored on exit). GDAL >= 3.10 gates
  # opening a MEM:::DATAPOINTER dataset behind GDAL_MEM_ENABLE_OPEN.
  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads, GDAL_MEM_ENABLE_OPEN = "YES"),
             as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )

  # Warp options only -- the destination grid is pinned by the MEM dataset we
  # build below, so no -te/-tr/-ts/-tap here (they would be ignored, and -tap
  # would fight the exact grid the caller asked for). Geometry (te/ts) is still
  # passed to .warp_collect for window planning and overview selection.
  warp_cl <- c("-r", r)
  if (!is.null(num_threads) && !any(grepl("NUM_THREADS", cl_arg, fixed = TRUE))) {
    warp_cl <- c(warp_cl, "-wo", paste0("NUM_THREADS=", num_threads))
  }
  wm <- .resolve_speed(warp_memory, .default_warp_mem)
  if (!is.null(wm) && !any(cl_arg == "-wm")) warp_cl <- c(warp_cl, "-wm", as.character(wm))
  warp_cl <- c(warp_cl, cl_arg)

  # Front of the pipeline: sanitise, read metadata, plan each source's window,
  # stream the native bytes. Identical to ck_warp() up to the final warp.
  cl <- .warp_collect(src, t_srs = t_srs, te = te, te_srs = te_srs, tr = NULL,
                      ts = as.numeric(ts), bands = bands, cl_arg = warp_cl,
                      dst = "/vsimem/ckbuf_probe.tif", overview = overview,
                      margin = margin, io = io, max_bytes = max_bytes,
                      sanitise = sanitise)

  t_srs_eff <- cl$t_srs_warp                       # t_srs, or the source CRS
  t_wkt <- gdalraster::srs_to_wkt(t_srs_eff)

  # Destination grid: te expressed in the target CRS, pinned to ts pixels.
  te_tgt <- if (!is.null(te_srs) && !.srs_identity(te_srs, t_srs_eff)) {
    gdalraster::transform_bounds(te, te_srs, t_srs_eff)
  } else {
    te
  }
  gt <- c(te_tgt[1], (te_tgt[3] - te_tgt[1]) / nx, 0,
          te_tgt[4], 0, -(te_tgt[4] - te_tgt[2]) / ny)

  out_dtype <- dtype %||% cl$ws[[1]]$dtype
  bytes <- .dtype_bytes(out_dtype)
  nbands <- cl$ws[[1]]$n_bands
  fill_val <- fill %||% cl$nodata %||% 0

  # Buffer safety ceiling on the returned allocation.
  est <- as.numeric(nx) * as.numeric(ny) * as.numeric(nbands) * bytes
  if (est > max_bytes) {
    cli::cli_abort(c(
      "Output buffer would be {.val {round(est / 1e9, 2)}} GB ({.val {nx}} x {.val {ny}} x {.val {nbands}} px, {.field {out_dtype}}).",
      "i" = "Coarsen {.arg ts}, narrow {.arg te}, select fewer {.arg bands}, or raise {.arg max_bytes}."
    ))
  }

  vrts <- .warp_stage(cl$ws, cl$plans, environment())
  .warp_vrts_to_buffer(vrts, nx = nx, ny = ny, nbands = nbands,
                       out_dtype = out_dtype, fill_val = fill_val, gt = gt,
                       t_wkt = t_wkt, t_srs_warp = t_srs_eff, warp_cl = warp_cl)
}

# Warp already-staged /vsimem raw VRTs into a pre-filled raw BSQ buffer via a
# GDAL MEM `DATAPOINTER` dataset laid over the R vector, returning the buffer
# descriptor. Shared by ck_warp_to_buffer() and ck_batch_to_buffer()'s per-output
# assembler. `gt`/`t_wkt` define the exact output grid; `warp_cl` carries the
# resampling + warp options (NO geometry flags -- the grid is the MEM dataset's).
# The caller stages `vrts` (and schedules their cleanup) and scopes
# GDAL_MEM_ENABLE_OPEN (the >=3.10 gate for opening a MEM:::DATAPOINTER dataset).
.warp_vrts_to_buffer <- function(vrts, nx, ny, nbands, out_dtype, fill_val,
                                 gt, t_wkt, t_srs_warp, warp_cl) {
  # Self-scope the >=3.10 MEM:::DATAPOINTER open gate so this works whether it
  # runs in the caller's session or an ambient mirai daemon (a separate process
  # the caller's .local_gdal_speed does not reach).
  old_mem <- gdalraster::get_config_option("GDAL_MEM_ENABLE_OPEN")
  gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")
  on.exit(gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", old_mem), add = TRUE)

  bytes <- .dtype_bytes(out_dtype)
  npx <- as.numeric(nx) * as.numeric(ny)
  ntot <- npx * nbands

  # Pre-fill with `fill_val` so pixels no source covers come back as the sentinel
  # (GDAL warp leaves uncovered output pixels untouched when INIT_DEST is not
  # set). For dtypes readBin/writeBin can't represent, fall back to a zeroed
  # buffer + GDAL INIT_DEST.
  spec <- .readbin_spec(out_dtype)
  init_dest <- character(0)
  if (!is.null(spec) && fill_val != 0) {
    buf <- writeBin(rep(.as_dtype_r(fill_val, spec), ntot), raw(),
                    size = spec$size, endian = .Platform$endian)
  } else {
    buf <- raw(ntot * bytes)
    if (fill_val != 0) init_dest <- c("-wo", paste0("INIT_DEST=", .numarg(fill_val)))
  }

  # Destination: a MEM dataset over the R buffer, band-sequential (the
  # PIXEL/LINE/BAND offsets give BSQ). GEOTRANSFORM is set via the object, not
  # the DSN, because its commas would clash with the DSN option separator.
  ptr <- gdalraster::get_data_ptr(buf)    # exported since 2.6.1.9001
  dsn <- sprintf(
    "MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=%d,DATATYPE=%s,PIXELOFFSET=%d,LINEOFFSET=%d,BANDOFFSET=%.0f",
    as.character(ptr), nx, ny, nbands, out_dtype,
    bytes, nx * bytes, npx * bytes)
  o <- methods::new(gdalraster::GDALRaster, dsn, FALSE)
  o$setGeoTransform(gt)
  o$setProjection(t_wkt)
  for (b in seq_len(nbands)) try(o$setNoDataValue(b, fill_val), silent = TRUE)

  ok <- tryCatch({
    gdalraster::warp(src_files = vrts, dst_filename = o, t_srs = t_srs_warp,
                     cl_arg = c(warp_cl, init_dest), quiet = TRUE)
    TRUE
  }, error = function(e) { try(o$close(), silent = TRUE); stop(e) })
  o$close()

  list(data = buf, nx = as.integer(nx), ny = as.integer(ny),
       nbands = as.integer(nbands), dtype = out_dtype, nodata = fill_val,
       geotransform = gt, crs = t_wkt)
}

# Coerce a fill value to the R type that writeBin(spec$size, spec$what) expects.
.as_dtype_r <- function(x, spec) {
  if (identical(spec$what, "integer")) as.integer(x) else as.double(x)
}
