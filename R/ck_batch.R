#' Fetch many grouped sources through one pool, with structure-preserving output
#'
#' `ck_batch()` takes a **list of groups** of source URLs -- e.g. one group per
#' acquisition, each group the band-level asset URLs for that acquisition -- and
#' fetches the same area-of-interest window from **every asset across every
#' group through a single global concurrency pool**. One pool over the whole job
#' saturates the network far better than reading each group separately, and the
#' returned paths mirror the input structure so onward tasks know which output is
#' which.
#'
#' Output granularity is set by `stack`:
#' * `stack = FALSE` (default): one file **per band**. The return value mirrors
#'   the full nested input -- a list (one element per group) of character vectors
#'   (one path per band). This is what tools that bundle bands themselves (e.g.
#'   vrtility's per-timestamp VRTs) expect.
#' * `stack = TRUE`: one band-separated file **per group** (see [ck_stack()]).
#'   The return value is a character vector, one path per group.
#'
#' A single AOI (`te` / `t_srs` / `tr` / `ts`) applies to the whole batch; each
#' source clips it to its own grid, so groups on different tiles are fine.
#'
#' @inheritParams ck_stack
#' @param src A list; each element a character vector of source URLs/paths that
#'   belong together (typically one acquisition's band assets). List names (and
#'   inner vector names) are used to name outputs; see `dst`.
#' @param stack Logical. `FALSE` (default) writes one file per band; `TRUE`
#'   stacks each group's bands into one file.
#' @param parallel Whether to warp + write the outputs across **ambient mirai
#'   daemons** (the fetch always uses cptkirk's single pool). `NULL` (default)
#'   auto-enables it when the \pkg{mirai} and \pkg{mori} packages are installed
#'   *and* daemons are running (`mirai::daemons(n)`); `TRUE` requires them and
#'   errors otherwise; `FALSE` forces the serial path. Fetched window buffers are
#'   shared to the daemons zero-copy via \pkg{mori} (no per-worker serialisation),
#'   and each daemon warps single-threaded. Set daemons up yourself; cptkirk uses
#'   whatever pool is already running and does not spawn or tear down daemons.
#' @param r Resampling method (used only on the warp path). Either a single
#'   method for the whole batch, a flat vector of length equal to the total
#'   number of assets, or a list mirroring `src` for a per-band method (e.g.
#'   `"near"` for mask bands, `"bilinear"` for reflectance).
#' @param num_threads GDAL warp threads per asset. Defaults to `1` (unlike
#'   [ck_warp()]): assets are warped one at a time over small windows, where
#'   per-warp thread spin-up costs more than it saves -- `"ALL_CPUS"` was
#'   measured ~8x slower for this many-small-files pattern.
#' @param dst Output location. Either an explicit path structure matching the
#'   output (a list of character vectors when `stack = FALSE`, a character vector
#'   of length `length(src)` when `stack = TRUE`), **or** a single string used as
#'   a path *template*: unique output paths are derived from it using the group
#'   names (and band names) of `src`, falling back to positional indices when
#'   names are absent. May be a `/vsi*` path. Defaults to a temp-file template.
#' @return The output paths, mirroring the input structure: a list of character
#'   vectors when `stack = FALSE`, a named character vector when `stack = TRUE`.
#'   Groups (or bands) whose source did not overlap the AOI are `NA`.
#' @seealso [ck_stack()] for a single group.
#' @export
ck_batch <- function(src, dst = fs::file_temp(ext = "tif"), stack = FALSE,
                     t_srs = NULL, te = NULL, te_srs = NULL,
                     tr = NULL, ts = NULL, tap = TRUE,
                     r = c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                           "average", "rms", "mode", "max", "min", "med",
                           "q1", "q3", "sum"),
                     bands = NULL, parallel = NULL, cl_arg = character(0),
                     num_threads = 1L, warp_memory = "auto",
                     cache_max = "auto",
                     co = c("COMPRESS=DEFLATE", "TILED=YES",
                            "NUM_THREADS=ALL_CPUS", "BIGTIFF=IF_SAFER"),
                     config = NULL, skip_nosource = TRUE,
                     overview = NULL, margin = 8L,
                     io_concurrency = 16L, max_bytes = NULL, sanitise = TRUE) {
  rlang::check_required(src)
  if (!is.list(src) || !length(src) ||
      !all(vapply(src, is.character, logical(1)))) {
    cli::cli_abort(c(
      "{.arg src} must be a non-empty list of character vectors.",
      "i" = "Each element is one output group (e.g. an acquisition's band URLs)."
    ))
  }
  rlang::check_bool(stack)
  r_flat <- .resolve_per_src_r(r, src)            # one method per asset
  args <- .stack_validate(t_srs, te, te_srs, tr, ts, tap, r_flat[1], bands, cl_arg,
                          num_threads, warp_memory, cache_max, co, config,
                          skip_nosource, overview, margin, io_concurrency,
                          max_bytes, sanitise, band_names = NULL)
  cl_base <- .strip_cl_arg(args$cl, "-r")         # per-source -r injected below
  dst_paths <- .resolve_batch_dst(dst, src, stack)

  .local_gdal_speed(
    opts = c(list(GDAL_NUM_THREADS = num_threads), as.list(config)),
    cache_bytes = .resolve_speed(cache_max, .default_cache_bytes, scale = 1e6),
    .envir = environment()
  )

  # Open every source ONCE (concurrently), then STREAM each fetched window back
  # to R as it lands: the warp/write overlaps the fetch, peak memory is bounded
  # (windows are dispatched and freed as they arrive), and each header is read
  # once -- not twice as a separate meta-then-fetch pass would.
  all_urls <- unlist(src, use.names = FALSE)
  use_par <- .batch_use_parallel(parallel)
  cp <- .batch_collect_plan(all_urls, t_srs = t_srs, te = te, te_srs = te_srs,
                            tr = args$tr, ts = args$ts, bands = bands,
                            cl_arg = cl_base, overview = overview, margin = margin,
                            max_bytes = args$max_bytes, sanitise = sanitise)
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
    fill = cp$nodata %||% 0, io_concurrency = args$io
  )

  .batch_stream_run(src, dst_paths, stack, cp$plans, session, r_flat, cl_base,
                    cp$t_srs_warp, cp$nodata, skip_nosource, use_par)
}

# Decide whether to use the ambient mirai daemon pool. NULL = auto (on iff
# mirai + mori installed and daemons running); TRUE = require; FALSE = serial.
.batch_use_parallel <- function(parallel) {
  if (isFALSE(parallel)) return(FALSE)
  have <- requireNamespace("mirai", quietly = TRUE) &&
    requireNamespace("mori", quietly = TRUE)
  daemons_up <- function() {
    have && isTRUE(tryCatch(mirai::status()$connections > 0, error = function(e) FALSE))
  }
  if (isTRUE(parallel)) {
    if (!have) {
      cli::cli_abort("{.code parallel = TRUE} needs the {.pkg mirai} and {.pkg mori} packages.")
    }
    if (!daemons_up()) {
      cli::cli_abort(c("{.code parallel = TRUE} needs running daemons.",
                       "i" = "Start them with {.run mirai::daemons(n)}."))
    }
    return(TRUE)
  }
  daemons_up()
}

# Open all sources once and plan each window (no fetch). Mirrors .warp_collect's
# meta + sanitise + plan, but via the open-once handle that the stream reuses.
.batch_collect_plan <- function(src, t_srs, te, te_srs, tr, ts, bands, cl_arg,
                                overview, margin, max_bytes, sanitise) {
  if (isTRUE(sanitise)) {
    .check_warp_geometry(t_srs = t_srs, te = te, te_srs = te_srs, tr = tr, ts = ts)
  }
  kv <- .auth_kv()
  opened <- cog_sources_open(src, kv$keys, kv$vals)
  metas <- opened$metas
  if (isTRUE(sanitise)) {
    .probe_warp(metas[[1]], t_srs = t_srs, cl_arg = cl_arg,
                dst = "/vsimem/ckbatch_probe.tif")
  }
  # Sources on the same grid (e.g. every acquisition of one MGRS tile) yield an
  # identical window plan, but `.plan_from_meta` runs a PROJ `transform_bounds`
  # per source -- the dominant prep cost. Compute the plan once per unique grid
  # signature and reuse it, attaching each source's own URL (used for band
  # names).
  sig_of <- function(m) {
    paste0(paste(m$geotransform, collapse = ","), "|", m$crs %||% "", "|",
           paste(m$level_width, collapse = ","), "|", paste(m$level_height, collapse = ","))
  }
  cache <- new.env(parent = emptyenv())
  plans <- lapply(seq_along(src), function(i) {
    m <- metas[[i]]
    s <- sig_of(m)
    cached <- get0(s, envir = cache, inherits = FALSE)
    if (is.null(cached)) {
      cached <- list(val = .plan_from_meta(src[i], m, t_srs = t_srs, te = te,
        te_srs = te_srs, tr = tr, ts = ts, bands = bands, overview = overview,
        margin = margin, max_bytes = max_bytes))
      assign(s, cached, envir = cache)
    }
    p <- cached$val
    if (is.null(p)) return(NULL)
    p$src <- src[i]    # grid/window shared; src identifies this asset
    p
  })
  surv <- Filter(Negate(is.null), plans)
  list(ptr = opened$ptr, plans = plans,
       nodata = if (length(surv)) surv[[1]]$nodata else NULL,
       t_srs_warp = t_srs %||% (if (length(surv)) surv[[1]]$crs else NULL))
}

# Drain the streaming fetch, assembling each output as soon as its window(s)
# land -- serially or dispatched to daemons -- so warp/write overlaps the fetch.
# stack = FALSE: one output per source (assemble on arrival). stack = TRUE:
# accumulate a group's windows, assemble when its last surviving source lands.
.batch_stream_run <- function(src, dst_paths, stack, plans, session, r_flat,
                              cl_base, t_srs_warp, nodata, skip_nosource, use_par) {
  ng <- length(src)
  grp_of <- rep(seq_len(ng), lengths(src))                 # group per source
  surv <- !vapply(plans, is.null, logical(1))
  need <- vapply(seq_len(ng), function(gi) sum(surv[grp_of == gi]), integer(1))
  dst_src <- if (!stack) unlist(dst_paths, use.names = FALSE) else NULL

  if (use_par) {
    # Daemons need cptkirk's internals + mori's ALTREP class on deserialise.
    mirai::everywhere({
      if (!"cptkirk" %in% loadedNamespaces()) library(cptkirk)
      requireNamespace("mori", quietly = TRUE)
    })
  }
  dispatch <- function(ws_u, pl_u, dst1, r_u) {
    if (use_par) {
      mirai::mirai(
        cptkirk:::.stack_assemble(ws_u, pl_u, dst1, cl_arg = cl_base,
          t_srs_warp = t_srs_warp, nodata = nodata, band_names = NULL,
          skip_nosource = skip_nosource, envir = environment(), r_each = r_u),
        ws_u = ws_u, pl_u = pl_u, dst1 = dst1, r_u = r_u, cl_base = cl_base,
        t_srs_warp = t_srs_warp, nodata = nodata, skip_nosource = skip_nosource)
    } else {
      .stack_assemble(ws_u, pl_u, dst1, cl_arg = cl_base, t_srs_warp = t_srs_warp,
        nodata = nodata, band_names = NULL, skip_nosource = skip_nosource,
        envir = environment(), r_each = r_u)
    }
  }

  out <- vector("list", length(grp_of))        # one slot per source (stack=FALSE)
  acc_ws <- vector("list", ng); acc_pl <- vector("list", ng)
  acc_r <- vector("list", ng); have <- integer(ng)

  repeat {
    rcv <- cog_fetch_take(session)
    if (is.null(rcv)) break
    if (!is.null(rcv$error)) next              # source failed -> its output stays NA
    si <- rcv$index
    w <- list(bytes = rcv$bytes, xsize = rcv$xsize, ysize = rcv$ysize,
              n_bands = rcv$n_bands, dtype = rcv$dtype,
              bytes_per_sample = rcv$bytes_per_sample, byte_order = rcv$byte_order)
    if (use_par) w$bytes <- mori::share(w$bytes)
    pl <- plans[[si]]
    gi <- grp_of[si]
    if (!stack) {
      out[[si]] <- dispatch(list(w), list(pl), dst_src[si], r_flat[si])
    } else {
      have[gi] <- have[gi] + 1L
      acc_ws[[gi]] <- c(acc_ws[[gi]], list(w))
      acc_pl[[gi]] <- c(acc_pl[[gi]], list(pl))
      acc_r[[gi]] <- c(acc_r[[gi]], r_flat[si])
      if (have[gi] >= need[gi]) {
        out[[gi]] <- dispatch(acc_ws[[gi]], acc_pl[[gi]], dst_paths[[gi]], acc_r[[gi]])
        # Free the buffers WITHOUT shrinking the list (`[[<- NULL` would reindex).
        acc_ws[gi] <- list(NULL); acc_pl[gi] <- list(NULL)
      }
    }
  }

  collect1 <- function(x) {
    if (is.null(x)) return(NA_character_)
    v <- if (inherits(x, "mirai")) mirai::collect_mirai(x) else x
    if (is.character(v) && length(v) == 1L) v else NA_character_
  }
  if (stack) {
    stats::setNames(vapply(out[seq_len(ng)], collect1, character(1)), names(src))
  } else {
    paths <- vapply(out, collect1, character(1))
    stats::setNames(utils::relist(paths, src), names(src))
  }
}

# Resolve `r` to one resampling method per asset (flatten order of `src`).
# Accepts a single method (recycled), a flat vector of length == total assets,
# or a list mirroring `src` (per-band). Validated against the allowed methods.
.resolve_per_src_r <- function(r, src) {
  if (is.list(r)) {
    if (length(r) != length(src) || !all(lengths(r) == lengths(src))) {
      cli::cli_abort("List {.arg r} must match the structure of {.arg src} (same group and band lengths).")
    }
    return(.check_r_methods(unlist(r, use.names = FALSE)))
  }
  .resolve_resampling(r, length(unlist(src)))
}

# Resolve `dst` to a path structure matching the requested output: a character
# vector (one per group) when stack = TRUE, a list of character vectors
# (mirroring `src`) when stack = FALSE. An explicit structure is used verbatim;
# a single string is treated as a template and expanded from group/band names.
.resolve_batch_dst <- function(dst, src, stack) {
  ng <- length(src)
  gnames <- names(src) %||% as.character(seq_len(ng))
  gnames[!nzchar(gnames)] <- as.character(seq_len(ng))[!nzchar(gnames)]

  # Explicit structures: used as given.
  if (is.list(dst)) {
    if (stack) {
      cli::cli_abort("With {.code stack = TRUE}, {.arg dst} must be a character vector or a single template string, not a list.")
    }
    if (length(dst) != ng || !all(lengths(dst) == lengths(src))) {
      cli::cli_abort("List {.arg dst} must match the structure of {.arg src} (same group and band lengths).")
    }
    return(stats::setNames(dst, names(src)))
  }
  if (!is.character(dst)) {
    cli::cli_abort("{.arg dst} must be a path string, a character vector, or a list of paths.")
  }
  n_out <- if (stack) ng else length(unlist(src))
  if (length(dst) == n_out && length(dst) != 1L) {
    # Explicit flat vector, one path per output unit.
    if (stack) return(stats::setNames(dst, names(src)))
    return(utils::relist(dst, src))
  }
  if (length(dst) != 1L) {
    cli::cli_abort(c(
      "{.arg dst} must be a single template string or one path per output.",
      "i" = "Expected length 1 or {.val {n_out}}, got {.val {length(dst)}}."
    ))
  }

  # Template: derive unique names from the base path + group/band names.
  dir  <- dirname(dst)
  stem <- tools::file_path_sans_ext(basename(dst))
  ext  <- tools::file_ext(dst); if (!nzchar(ext)) ext <- "tif"
  if (stack) {
    stats::setNames(file.path(dir, sprintf("%s_%s.%s", stem, gnames, ext)),
                    names(src))
  } else {
    out <- lapply(seq_len(ng), function(g) {
      bn <- names(src[[g]]) %||% as.character(seq_along(src[[g]]))
      bn[!nzchar(bn)] <- as.character(seq_along(src[[g]]))[!nzchar(bn)]
      file.path(dir, sprintf("%s_%s_%s.%s", stem, gnames[g], bn, ext))
    })
    stats::setNames(out, names(src))
  }
}
