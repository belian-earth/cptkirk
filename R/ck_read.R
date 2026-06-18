#' Warp a remote GeoTIFF / COG straight into an R array
#'
#' `ck_read()` is [ck_warp()] that hands back pixels instead of writing a file:
#' it streams only the tiles the request touches, warps them with GDAL (the same
#' engine, sanitiser and defaults as [ck_warp()]), and returns the result as a
#' base-R matrix or array. Use it for quick extraction and inspection without
#' round-tripping through a file on disk.
#'
#' Two internal paths, chosen automatically:
#' * **Warp** (the usual case -- a reprojection / resolution change is
#'   requested): the result is materialised in an uncompressed `/vsimem`
#'   GeoTIFF and read back with `gdalraster`.
#' * **Native window** (no `t_srs`/`tr`/`ts`, single source): the fetched native
#'   bytes are decoded straight to an R array, with no GDAL round-trip at all.
#'
#' @inheritParams ck_warp
#' @param max_bytes Safety ceiling (bytes) on the **returned array**, sized as
#'   `nrow * ncol * nbands * 8` (R stores numerics as f64). `NULL` (default)
#'   uses ~1/3 of system RAM. Coarsen `tr`/`ts`, narrow `te`, select fewer
#'   `bands`, or raise this to read a larger window.
#' @return A numeric matrix (single band) or array with dimensions
#'   `[nrow, ncol, nband]` (multi-band), carrying `geotransform`, `crs` and
#'   (when set) `nodata` attributes so it is self-describing and convertible to
#'   other raster classes. The R type follows the output data type (integer or
#'   double).
#' @seealso [ck_warp()] to write a warped file instead.
#' @export
ck_read <- function(src,
                    t_srs = NULL, te = NULL, te_srs = NULL,
                    tr = NULL, ts = NULL, tap = TRUE,
                    r = c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                          "average", "rms", "mode", "max", "min", "med",
                          "q1", "q3", "sum"),
                    bands = NULL, cl_arg = character(0),
                    num_threads = "ALL_CPUS", warp_memory = "auto",
                    cache_max = "auto", config = NULL, skip_nosource = TRUE,
                    overview = NULL, margin = 8L,
                    io_concurrency = 16L, max_bytes = NULL, sanitise = TRUE) {
  rlang::check_required(src)
  .check_src(src)
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
  .check_config(config)
  rlang::check_bool(skip_nosource)
  .check_fetch_args(overview, margin, io_concurrency, max_bytes, sanitise)

  ts <- .resolve_tr_ts(tr, ts)
  if (!is.null(te)) te <- as.numeric(te)
  io <- io_concurrency %||% 16L
  max_bytes <- max_bytes %||% .default_max_bytes()

  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads), as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )

  # No creation options: the warp target is a throwaway uncompressed /vsimem
  # GeoTIFF we read straight back, so compressing it would be pure waste.
  args <- .assemble_warp_args(te, te_srs, tr, ts, r, tap,
                              num_threads, warp_memory, co = NULL, cl_arg)

  cl <- .warp_collect(src, t_srs = t_srs, te = te, te_srs = te_srs, tr = tr,
                      ts = ts, bands = bands, cl_arg = args,
                      dst = "/vsimem/ckread_probe.tif", overview = overview,
                      margin = margin, io = io, max_bytes = max_bytes,
                      sanitise = sanitise)

  # Native-window fast path: no reprojection -> decode the fetched bytes
  # directly to an R array, no GDAL.
  if (cl$n == 1L && isTRUE(cl$plans[[1]]$is_copy)) {
    p <- cl$plans[[1]]; w <- cl$ws[[1]]
    .guard_out_bytes(w$xsize, w$ysize, w$n_bands, max_bytes)
    arr <- .window_to_array(w, p)
    if (!is.null(arr)) return(arr)
    # Exotic dtype readBin can't represent: read the staged VRT via gdalraster
    # (still the native grid, no warp).
    vrts <- .warp_stage(cl$ws, cl$plans, environment())
    return(.vsimem_to_array(vrts[1L], max_bytes))
  }

  # Warp path: stage -> warp to an uncompressed /vsimem GeoTIFF -> read back.
  vrts <- .warp_stage(cl$ws, cl$plans, environment())
  out <- sprintf("/vsimem/%s.tif", basename(tempfile("ckread_")))
  withr::defer(try(gdalraster::vsi_unlink(out), silent = TRUE))
  warp_args <- c(args, .skip_nosource_args(args, skip_nosource, cl$nodata))
  gdalraster::warp(src_files = vrts, dst_filename = out, t_srs = cl$t_srs_warp,
                   cl_arg = warp_args, quiet = TRUE)
  .vsimem_to_array(out, max_bytes)
}

# Abort if the returned R array (assumed f64) would exceed `max_bytes`.
.guard_out_bytes <- function(nx, ny, nb, max_bytes) {
  est <- as.numeric(nx) * as.numeric(ny) * as.numeric(nb) * 8
  if (est > max_bytes) {
    cli::cli_abort(c(
      "Returned array would be {.val {round(est / 1e9, 2)}} GB in R ({.val {nx}} x {.val {ny}} x {.val {nb}} px, f64).",
      "i" = "Coarsen {.arg tr}/{.arg ts}, narrow {.arg te}, select fewer {.arg bands}, or raise {.arg max_bytes}."
    ))
  }
  invisible(NULL)
}

# readBin spec (what/size/signed) for the native dtypes R can represent
# directly; everything else returns NULL so the caller falls back to GDAL.
.readbin_spec <- function(dtype) {
  switch(dtype,
    Byte    = list(what = "integer", size = 1L, signed = FALSE),
    Int8    = list(what = "integer", size = 1L, signed = TRUE),
    UInt16  = list(what = "integer", size = 2L, signed = FALSE),
    Int16   = list(what = "integer", size = 2L, signed = TRUE),
    Int32   = list(what = "integer", size = 4L, signed = TRUE),
    Float32 = list(what = "double",  size = 4L, signed = TRUE),
    Float64 = list(what = "double",  size = 8L, signed = TRUE),
    NULL
  )
}

# Decode a fetched native window (band-sequential, row-major) straight to an R
# array. Returns NULL for dtypes readBin can't represent (caller falls back).
.window_to_array <- function(w, plan) {
  spec <- .readbin_spec(w$dtype)
  if (is.null(spec)) return(NULL)
  endian <- if (grepl("MSB|BIG", toupper(w$byte_order))) "big" else "little"
  npx <- as.numeric(w$xsize) * as.numeric(w$ysize)
  v <- readBin(w$bytes, what = spec$what, n = npx * w$n_bands,
               size = spec$size, signed = spec$signed, endian = endian)
  .as_cog_array(v, w$ysize, w$xsize, w$n_bands, plan$win_gt, plan$crs, plan$nodata)
}

# Read a /vsimem GDAL dataset (the warped result, or a native-grid VRT) into an
# R array via gdalraster, applying the output-size guard first.
.vsimem_to_array <- function(path, max_bytes) {
  ds <- methods::new(gdalraster::GDALRaster, path)
  on.exit(ds$close(), add = TRUE)
  nx <- ds$getRasterXSize(); ny <- ds$getRasterYSize(); nb <- ds$getRasterCount()
  .guard_out_bytes(nx, ny, nb, max_bytes)
  rd <- function(b) {
    ds$read(band = b, xoff = 0L, yoff = 0L, xsize = nx, ysize = ny,
            out_xsize = nx, out_ysize = ny)
  }
  v <- if (nb == 1L) rd(1L) else unlist(lapply(seq_len(nb), rd), use.names = FALSE)
  nodata <- tryCatch({
    z <- ds$getNoDataValue(1L)
    if (length(z) != 1L || is.na(z)) NULL else z
  }, error = function(e) NULL)
  .as_cog_array(v, ny, nx, nb, ds$getGeoTransform(), ds$getProjection(), nodata)
}

# Reshape a flat band-sequential, row-major vector into a matrix (1 band) or
# `[nrow, ncol, nband]` array, attaching georeferencing attributes.
.as_cog_array <- function(v, ny, nx, nb, gt, crs, nodata) {
  ny <- as.integer(ny); nx <- as.integer(nx); nb <- as.integer(nb)
  npx <- as.numeric(nx) * as.numeric(ny)
  if (nb == 1L) {
    arr <- matrix(v, nrow = ny, ncol = nx, byrow = TRUE)
  } else {
    arr <- array(if (is.integer(v)) NA_integer_ else NA_real_, dim = c(ny, nx, nb))
    for (b in seq_len(nb)) {
      seg <- v[((b - 1) * npx + 1):(b * npx)]
      arr[, , b] <- matrix(seg, nrow = ny, ncol = nx, byrow = TRUE)
    }
  }
  attr(arr, "geotransform") <- gt
  attr(arr, "crs") <- crs
  if (!is.null(nodata) && !is.na(nodata)) attr(arr, "nodata") <- nodata
  arr
}
