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
#' @param r Resampling method (used only on the warp path). Either a single
#'   method for the whole batch, a flat vector of length equal to the total
#'   number of assets, or a list mirroring `src` for a per-band method (e.g.
#'   `"near"` for mask bands, `"bilinear"` for reflectance).
#' @param sanitise Logical. Both modes open every source once over one shared
#'   connection pool per host (so the batch pays ~one TLS handshake, not one per
#'   source). `TRUE` (default) validates the request and plans/verifies every
#'   source's grid (handles mixed grids). `FALSE` is a trusted fast path: it
#'   plans the window from a **single** source and assumes all sources share that
#'   grid, skipping per-source planning and the probe. Use it only when the
#'   inputs are known to share one grid (e.g. assets of one MGRS tile); off-grid
#'   sources may fail or, if their extent happens to contain the window, return
#'   wrong pixels.
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
#'   Outputs are `NA` when the source did not overlap the AOI, or when its fetch
#'   failed (the latter emits a warning; for `stack = TRUE` a single failed band
#'   leaves the whole group `NA`).
#' @seealso [ck_stack()] for a single group.
#' @export
ck_batch <- function(src, dst = tempfile(fileext = ".tif"), stack = FALSE,
                     t_srs = NULL, te = NULL, te_srs = NULL,
                     tr = NULL, ts = NULL, tap = TRUE,
                     r = c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                           "average", "rms", "mode", "max", "min", "med",
                           "q1", "q3", "sum"),
                     bands = NULL, cl_arg = character(0),
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

  # Open every source ONCE, sharing one connection pool per host (OpenCache on
  # the Rust side) so the batch pays ~one TLS handshake, not one per source. Then
  # stream windows from the open handles as they land -- warp/write overlaps the
  # remaining fetches and memory is bounded. `sanitise = FALSE` only changes
  # PLANNING (one grid, trusted) -- see .batch_collect_plan.
  all_urls <- unlist(src, use.names = FALSE)
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
                    cp$t_srs_warp, cp$nodata, skip_nosource)
}

# Open all sources once (one shared connection pool per host) and plan each
# window (no fetch). The handle is reused by the streaming fetch.
#
# sanitise = TRUE: validate, plan EVERY source's grid (cached by grid signature
# so the PROJ transform runs once per unique grid, not per source), handles mixed
# grids. sanitise = FALSE: plan the window from the FIRST source only and assume
# every source shares that grid -- skips per-source planning and the probe.
.batch_collect_plan <- function(src, t_srs, te, te_srs, tr, ts, bands, cl_arg,
                                overview, margin, max_bytes, sanitise) {
  if (isTRUE(sanitise)) {
    .check_warp_geometry(t_srs = t_srs, te = te, te_srs = te_srs, tr = tr, ts = ts)
  }
  kv <- .auth_kv()
  opened <- cog_sources_open(src, kv$keys, kv$vals)
  metas <- opened$metas

  plan1 <- function(i) {
    .plan_from_meta(src[i], metas[[i]], t_srs = t_srs, te = te, te_srs = te_srs,
                    tr = tr, ts = ts, bands = bands, overview = overview,
                    margin = margin, max_bytes = max_bytes)
  }

  if (!isTRUE(sanitise)) {
    # Trusted: one grid for the whole batch. Plan from the first source, reuse
    # the window for all (off-grid sources fail their fetch -> NA, rather than
    # silently wrong, unless an identical-size off-grid tile -- caller's call).
    w <- plan1(1L)
    if (is.null(w)) {
      cli::cli_abort(c(
        "The first source does not overlap {.arg te}.",
        "i" = "{.code sanitise = FALSE} assumes all sources share one grid; check the AOI, or use the default."
      ))
    }
    plans <- lapply(src, function(u) { w$src <- u; w })
    return(list(ptr = opened$ptr, plans = plans, nodata = w$nodata,
                t_srs_warp = t_srs %||% w$crs))
  }

  .probe_warp(metas[[1]], t_srs = t_srs, cl_arg = cl_arg,
              dst = "/vsimem/ckbatch_probe.tif")
  plans <- .plan_sources(src, metas, t_srs = t_srs, te = te, te_srs = te_srs,
                         tr = tr, ts = ts, bands = bands, overview = overview,
                         margin = margin, max_bytes = max_bytes)
  surv <- Filter(Negate(is.null), plans)
  list(ptr = opened$ptr, plans = plans,
       nodata = if (length(surv)) surv[[1]]$nodata else NULL,
       t_srs_warp = t_srs %||% (if (length(surv)) surv[[1]]$crs else NULL))
}

# Drain the streaming fetch, assembling (warp + write) each output as soon as its
# window(s) land, so the warp/write overlaps the fetches still in flight.
# stack = FALSE: one output per source (assemble on arrival). stack = TRUE:
# accumulate a group's windows, assemble when its last surviving source lands.
.batch_stream_run <- function(src, dst_paths, stack, plans, session, r_flat,
                              cl_base, t_srs_warp, nodata, skip_nosource) {
  ng <- length(src)
  grp_of <- rep(seq_len(ng), lengths(src))                 # group per source
  band_of <- unlist(lapply(src, seq_along), use.names = FALSE)  # band pos in group
  surv <- !vapply(plans, is.null, logical(1))
  need <- vapply(seq_len(ng), function(gi) sum(surv[grp_of == gi]), integer(1))
  dst_src <- if (!stack) unlist(dst_paths, use.names = FALSE) else NULL

  dispatch <- function(ws_u, pl_u, dst1, r_u) {
    .stack_assemble(ws_u, pl_u, dst1, cl_arg = cl_base, t_srs_warp = t_srs_warp,
      nodata = nodata, band_names = NULL, skip_nosource = skip_nosource,
      envir = environment(), r_each = r_u)
  }

  out <- vector("list", length(grp_of))        # one slot per source (stack=FALSE)
  acc <- vector("list", ng); have <- integer(ng)  # per-group accumulators
  failed <- list()                                # (index, error) of failed fetches

  repeat {
    rcv <- cog_fetch_take(session)
    if (is.null(rcv)) break
    if (!is.null(rcv$error)) {
      # Distinct from a non-overlapping source (which has a NULL plan and is
      # never streamed): this source was planned but its fetch failed. Record it
      # and warn at the end rather than silently returning NA. For stack = TRUE a
      # failed band leaves have[gi] < need[gi], so that whole group stays NA.
      failed[[length(failed) + 1L]] <- list(src = plans[[rcv$index]]$src %||% NA_character_,
                                            error = rcv$error)
      next
    }
    si <- rcv$index
    w <- list(bytes = rcv$bytes, xsize = rcv$xsize, ysize = rcv$ysize,
              n_bands = rcv$n_bands, dtype = rcv$dtype,
              bytes_per_sample = rcv$bytes_per_sample, byte_order = rcv$byte_order)
    pl <- plans[[si]]
    gi <- grp_of[si]
    if (!stack) {
      out[[si]] <- dispatch(list(w), list(pl), dst_src[si], r_flat[si])
    } else {
      # Windows arrive in completion order; keep each with its band position so
      # the stacked output is in source band order, not arrival order.
      have[gi] <- have[gi] + 1L
      acc[[gi]] <- c(acc[[gi]], list(list(bw = band_of[si], w = w, pl = pl,
                                          r = r_flat[si])))
      if (have[gi] >= need[gi]) {
        e <- acc[[gi]][order(vapply(acc[[gi]], `[[`, integer(1), "bw"))]
        out[[gi]] <- dispatch(lapply(e, `[[`, "w"), lapply(e, `[[`, "pl"),
                              dst_paths[[gi]], vapply(e, `[[`, character(1), "r"))
        acc[gi] <- list(NULL)                 # free without reindexing the list
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
    if (is.character(x) && length(x) == 1L) x else NA_character_
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
