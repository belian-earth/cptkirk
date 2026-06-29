#' Stack many sources into one band-separated raster (buildvrt -separate)
#'
#' `ck_stack()` fetches a window from several sources through cptkirk's single
#' global concurrency pool (every source opened concurrently, every tile fetched
#' through one io budget) and writes them **stacked as separate bands**: source
#' *i* contributes consecutive band(s) of the output, in input order. It is the
#' streaming-remote analogue of `gdalbuildvrt -separate` followed by a
#' materialising read.
#'
#' This differs from passing several sources to [ck_warp()], which *mosaics*
#' them (overlapping pixels blend, last source wins). Use `ck_stack()` to bring,
#' e.g., the per-band single-band assets of one acquisition into a single
#' multi-band raster.
#'
#' Two internal paths, chosen automatically:
#' * **Stack** (the usual case -- sources already share a grid and no
#'   reprojection/resolution change is requested): the fetched native windows are
#'   stacked directly with `-separate` and written out. Sources are assumed
#'   aligned; supply `t_srs`/`te`/`tr` to force a common grid otherwise.
#' * **Warp-then-stack**: when a reprojection or resolution change is requested,
#'   each source is warped to the common target grid first, then stacked, so the
#'   bands register exactly.
#'
#' @inheritParams ck_warp
#' @param r Resampling method (used only on the warp path; a native-window copy
#'   ignores it). Either a single method applied to every source, or a vector of
#'   length `length(src)` giving a per-source method (e.g. `"near"` for a mask
#'   band, `"bilinear"` for reflectance).
#' @param band_names Optional character vector naming the output bands, length
#'   equal to the total number of output bands (sum of selected bands across
#'   sources). `NULL` (default) derives a name per band from the source file
#'   name (a `_b<k>` suffix is added for multi-band sources). Names are written
#'   as GDAL band descriptions; they carry identity only, not data.
#' @return `dst`, invisibly. `dst` may be a file path or any `/vsi*` path GDAL
#'   can write (e.g. `/vsimem/stack.tif`).
#' @seealso [ck_stack_read()] for the array-returning sugar, [ck_warp()] to
#'   mosaic instead of stack.
#' @export
ck_stack <- function(src, dst,
                     t_srs = NULL, te = NULL, te_srs = NULL,
                     tr = NULL, ts = NULL, tap = TRUE,
                     r = c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                           "average", "rms", "mode", "max", "min", "med",
                           "q1", "q3", "sum"),
                     bands = NULL, band_names = NULL, cl_arg = character(0),
                     num_threads = "ALL_CPUS", warp_memory = "auto",
                     cache_max = "auto",
                     co = c("COMPRESS=DEFLATE", "TILED=YES",
                            "NUM_THREADS=ALL_CPUS", "BIGTIFF=IF_SAFER"),
                     config = NULL, skip_nosource = TRUE,
                     overview = NULL, margin = 8L,
                     io_concurrency = 16L, max_bytes = NULL, sanitise = TRUE) {
  rlang::check_required(src)
  rlang::check_required(dst)
  .check_src(src)
  if (!rlang::is_string(dst)) {
    cli::cli_abort("{.arg dst} must be a single output path string.")
  }
  r_each <- .resolve_resampling(r, length(src))
  args <- .stack_validate(t_srs, te, te_srs, tr, ts, tap, r_each[1], bands, cl_arg,
                          num_threads, warp_memory, cache_max, co, config,
                          skip_nosource, overview, margin, io_concurrency,
                          max_bytes, sanitise, band_names)

  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads), as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )
  .stack_engine(src, dst, t_srs = t_srs, te = te, te_srs = te_srs, tr = args$tr,
                ts = args$ts, bands = bands, cl_arg = .strip_cl_arg(args$cl, "-r"),
                r_each = r_each, band_names = band_names,
                overview = overview, margin = margin, io = args$io,
                max_bytes = args$max_bytes, skip_nosource = skip_nosource,
                sanitise = sanitise)
  invisible(dst)
}

#' Stack many sources straight into an R array
#'
#' `ck_stack_read()` is [ck_stack()] that hands back pixels instead of writing a
#' file: it stacks the sources as separate bands (see [ck_stack()]) into an
#' uncompressed `/vsimem` raster and reads it back as a base-R array.
#'
#' @inheritParams ck_stack
#' @param max_bytes Safety ceiling (bytes) on the **returned array**, sized as
#'   `nrow * ncol * nbands * 8`. `NULL` (default) uses ~1/3 of system RAM.
#' @return A numeric array with dimensions `[nrow, ncol, nband]` (or a matrix for
#'   a single output band), carrying `geotransform`, `crs` and (when set)
#'   `nodata` attributes. Band names are not preserved on the array.
#' @seealso [ck_stack()] to write a file instead.
#' @export
ck_stack_read <- function(src,
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
  r_each <- .resolve_resampling(r, length(src))
  args <- .stack_validate(t_srs, te, te_srs, tr, ts, tap, r_each[1], bands, cl_arg,
                          num_threads, warp_memory, cache_max, co = NULL, config,
                          skip_nosource, overview, margin, io_concurrency,
                          max_bytes, sanitise, band_names = NULL)

  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads), as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )
  out <- sprintf("/vsimem/%s.tif", basename(tempfile("ckstackrd_")))
  withr::defer(try(gdalraster::vsi_unlink(out), silent = TRUE))
  .stack_engine(src, out, t_srs = t_srs, te = te, te_srs = te_srs, tr = args$tr,
                ts = args$ts, bands = bands, cl_arg = .strip_cl_arg(args$cl, "-r"),
                r_each = r_each, band_names = NULL,
                overview = overview, margin = margin, io = args$io,
                max_bytes = args$max_bytes, skip_nosource = skip_nosource,
                sanitise = sanitise)
  .vsimem_to_array(out, args$max_bytes)
}

# Shared validation + arg assembly for ck_stack / ck_stack_read.
.stack_validate <- function(t_srs, te, te_srs, tr, ts, tap, r, bands, cl_arg,
                            num_threads, warp_memory, cache_max, co, config,
                            skip_nosource, overview, margin, io_concurrency,
                            max_bytes, sanitise, band_names) {
  rlang::check_string(t_srs, allow_null = TRUE)
  rlang::check_string(te_srs, allow_null = TRUE)
  .check_num_vec(te, 4L, "c(xmin, ymin, xmax, ymax)")
  .check_num_vec(tr, 2L, "c(xres, yres)", positive = TRUE)
  .check_num_vec(ts, 2L, "c(width, height)", positive = TRUE)
  rlang::check_bool(tap)
  .check_bands(bands)
  cl_arg <- cl_arg %||% character(0)
  .check_chr(cl_arg)
  .check_threads(num_threads)
  .check_speed(warp_memory)
  .check_speed(cache_max)
  .check_chr(co, allow_null = TRUE)
  .check_config(config)
  rlang::check_bool(skip_nosource)
  if (!is.null(band_names)) .check_chr(band_names)
  .check_fetch_args(overview, margin, io_concurrency, max_bytes, sanitise)

  ts <- .resolve_tr_ts(tr, ts)
  if (!is.null(te)) te <- as.numeric(te)
  list(
    tr = tr, ts = ts,
    io = io_concurrency %||% 16L,
    max_bytes = max_bytes %||% .default_max_bytes(),
    cl = .assemble_warp_args(te, te_srs, tr, ts, r, tap, num_threads,
                             warp_memory, co = co, cl_arg = cl_arg)
  )
}

# Fetch (pooled) one group of sources, then assemble them into `dst`.
.stack_engine <- function(src, dst, t_srs, te, te_srs, tr, ts, bands, cl_arg,
                          band_names, overview, margin, io, max_bytes,
                          skip_nosource = TRUE, sanitise = TRUE, r_each = NULL) {
  cl <- .warp_collect(src, t_srs = t_srs, te = te, te_srs = te_srs, tr = tr,
                      ts = ts, bands = bands, cl_arg = cl_arg, dst = dst,
                      overview = overview, margin = margin, io = io,
                      max_bytes = max_bytes, sanitise = sanitise)
  .stack_assemble(cl$ws, cl$plans, dst, cl_arg = cl_arg,
                  t_srs_warp = cl$t_srs_warp, nodata = cl$nodata,
                  band_names = band_names, skip_nosource = skip_nosource,
                  envir = environment(), r_each = r_each)
}

# Allowed GDAL resampling methods (shared by ck_stack / ck_batch).
.r_methods <- c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                "average", "rms", "mode", "max", "min", "med",
                "q1", "q3", "sum")

# Validate every element of a resampling vector against the allowed methods.
.check_r_methods <- function(rf) {
  bad <- setdiff(unique(rf), .r_methods)
  if (length(bad)) {
    cli::cli_abort("Unknown {.arg r} method{?s}: {.val {bad}}.")
  }
  rf
}

# Resolve `r` to a length-`n` per-source vector. Accepts the multi-choice
# default (treated as unspecified -> the first method), a single method, or a
# length-`n` vector (one per source).
.resolve_resampling <- function(r, n) {
  if (length(r) == length(.r_methods) && all(r == .r_methods)) {
    r <- .r_methods[1] # the unspecified formal default
  }
  if (length(r) == 1L) {
    return(rep(.check_r_methods(r), n))
  }
  if (length(r) != n) {
    cli::cli_abort(c(
      "{.arg r} must be a single method or one per source ({.val {n}}).",
      "i" = "Got {.val {length(r)}}."
    ))
  }
  .check_r_methods(r)
}

# Remove a one-value flag (e.g. "-r near") from an assembled cl_arg vector.
.strip_cl_arg <- function(cl, flag) {
  i <- which(cl == flag)
  if (!length(i)) return(cl)
  cl[-sort(unique(c(i, i + 1L)))]
}

# Stage already-fetched windows, stack them as separate bands, and materialise
# to `dst`. Shared by ck_stack (one group) and ck_batch (per output group).
#
# Stack path: every source is a native copy on its own grid -> stack as-is
# (sources assumed aligned). Warp-then-stack: a reprojection/resolution change
# was requested, so bring each source onto the common grid before stacking.
.stack_assemble <- function(ws, plans, dst, cl_arg, t_srs_warp, nodata,
                            band_names, skip_nosource, envir, r_each = NULL) {
  vrts <- .warp_stage(ws, plans, envir)
  all_copy <- all(vapply(plans, function(p) isTRUE(p$is_copy), logical(1)))
  tmp <- character(0)
  # Resampling only applies on the warp path; a native-window copy ignores it.
  # `r_each` (one method per source) overrides the `-r` in `cl_arg` per source.
  tiles <- if (all_copy) {
    vrts
  } else {
    vapply(seq_along(vrts), function(i) {
      ra <- if (is.null(r_each)) cl_arg else c(cl_arg, "-r", r_each[[i]])
      warp_args <- c(ra, .skip_nosource_args(ra, skip_nosource, nodata))
      o <- sprintf("/vsimem/%s.tif", basename(tempfile("ckstack_t_")))
      gdalraster::warp(src_files = vrts[[i]], dst_filename = o,
                       t_srs = t_srs_warp, cl_arg = warp_args, quiet = TRUE)
      o
    }, character(1))
  }
  if (!all_copy) tmp <- tiles
  sep <- sprintf("/vsimem/%s.vrt", basename(tempfile("ckstack_sep_")))
  on.exit(for (f in c(tmp, sep)) try(gdalraster::vsi_unlink(f), silent = TRUE),
          add = TRUE)

  gdalraster::buildVRT(sep, tiles, cl_arg = "-separate", quiet = TRUE)
  if (!grepl("^/vsi", dst)) {
    if (file.exists(dst)) unlink(dst)
    dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
  }
  gdalraster::translate(sep, dst, cl_arg = .translate_out_args(cl_arg), quiet = TRUE)
  .set_stack_band_names(dst, plans, ws, band_names)
  invisible(dst)
}

# Write per-band GDAL descriptions identifying each source (and band, for
# multi-band sources). Output band order matches buildVRT -separate: each
# source's bands consecutively, in plan order.
.set_stack_band_names <- function(dst, plans, ws, band_names) {
  nb_each <- vapply(ws, `[[`, integer(1), "n_bands")
  total <- sum(nb_each)
  labels <- if (!is.null(band_names)) {
    if (length(band_names) != total) {
      cli::cli_abort(c(
        "{.arg band_names} must have length {.val {total}} (total output bands).",
        "i" = "Got {.val {length(band_names)}}."
      ))
    }
    band_names
  } else {
    unlist(Map(function(p, nb) {
      base <- tools::file_path_sans_ext(basename(sub("\\?.*$", "", p$src)))
      if (nb == 1L) base else paste0(base, "_b", seq_len(nb))
    }, plans, nb_each), use.names = FALSE)
  }
  ds <- methods::new(gdalraster::GDALRaster, dst, read_only = FALSE)
  on.exit(ds$close(), add = TRUE)
  for (b in seq_len(total)) ds$setDescription(b, labels[b])
  invisible(NULL)
}
