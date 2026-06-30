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

  # ONE pooled fetch across every asset in every group -- the saturation lever.
  all_urls <- unlist(src, use.names = FALSE)
  cl <- .warp_collect(all_urls, t_srs = t_srs, te = te, te_srs = te_srs,
                      tr = args$tr, ts = args$ts, bands = bands, cl_arg = cl_base,
                      dst = "/vsimem/ckbatch_probe.tif", overview = overview,
                      margin = margin, io = args$io, max_bytes = args$max_bytes,
                      sanitise = sanitise)
  # Map fetched windows (and per-asset resampling) back to their source URL;
  # non-overlapping sources were dropped during planning and are absent here.
  keys <- vapply(cl$plans, `[[`, character(1), "src")
  plan_by <- stats::setNames(cl$plans, keys)
  ws_by <- stats::setNames(cl$ws, keys)
  r_by <- stats::setNames(r_flat, all_urls)

  assemble1 <- function(urls, dst1) {
    keep <- urls[urls %in% keys]
    if (!length(keep)) return(NA_character_)
    .stack_assemble(ws_by[keep], plan_by[keep], dst1, cl_arg = cl_base,
                    t_srs_warp = cl$t_srs_warp, nodata = cl$nodata,
                    band_names = NULL, skip_nosource = skip_nosource,
                    envir = environment(), r_each = unname(r_by[keep]))
  }

  if (stack) {
    out <- vapply(seq_along(src),
                  function(g) assemble1(src[[g]], dst_paths[[g]]), character(1))
    stats::setNames(out, names(dst_paths))
  } else {
    Map(function(urls, ds) {
      vapply(seq_along(urls), function(j) assemble1(urls[j], ds[[j]]), character(1))
    }, src, dst_paths)
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
