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
  use_par <- .batch_use_parallel(parallel)
  ws <- cl$ws
  if (use_par) {
    # Share each window's byte buffer into OS shared memory; daemons read it
    # zero-copy (mori serialises the buffer as a tiny reference, not a copy).
    ws <- lapply(ws, function(w) { w$bytes <- mori::share(w$bytes); w })
  }
  plan_by <- stats::setNames(cl$plans, keys)
  ws_by <- stats::setNames(ws, keys)
  r_by <- stats::setNames(r_flat, all_urls)

  # One output unit per band (stack = FALSE) or per group (stack = TRUE).
  unit_for <- function(urls, dst1) {
    keep <- urls[urls %in% keys]
    list(ws = unname(ws_by[keep]), plans = unname(plan_by[keep]),
         dst = dst1, r = unname(r_by[keep]), empty = !length(keep))
  }
  units <- if (stack) {
    lapply(seq_along(src), function(g) unit_for(src[[g]], dst_paths[[g]]))
  } else {
    unlist(lapply(seq_along(src), function(g)
      lapply(seq_along(src[[g]]), function(j) unit_for(src[[g]][j], dst_paths[[g]][[j]]))),
      recursive = FALSE)
  }

  paths <- .batch_dispatch(units, cl_base, cl$t_srs_warp, cl$nodata,
                           skip_nosource, use_par)

  if (stack) {
    stats::setNames(paths, names(src))
  } else {
    stats::setNames(utils::relist(paths, src), names(src))
  }
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

# Assemble every output unit -> its path, serially or across daemons. The warp
# stage is the parallelised part; the fetch already ran in one pool upstream.
.batch_dispatch <- function(units, cl_base, t_srs_warp, nodata, skip_nosource, parallel) {
  do_one <- function(u) {
    if (isTRUE(u$empty)) return(NA_character_)
    .stack_assemble(u$ws, u$plans, u$dst, cl_arg = cl_base, t_srs_warp = t_srs_warp,
                    nodata = nodata, band_names = NULL, skip_nosource = skip_nosource,
                    envir = environment(), r_each = u$r)
  }
  if (!parallel) {
    return(vapply(units, do_one, character(1)))
  }
  # Ensure the daemons can resolve cptkirk's internals + mori's ALTREP class.
  mirai::everywhere({
    if (!"cptkirk" %in% loadedNamespaces()) library(cptkirk)
    requireNamespace("mori", quietly = TRUE)
  })
  res <- mirai::mirai_map(
    units,
    function(u, cl_base, t_srs_warp, nodata, skip_nosource) {
      if (isTRUE(u$empty)) return(NA_character_)
      cptkirk:::.stack_assemble(u$ws, u$plans, u$dst, cl_arg = cl_base,
        t_srs_warp = t_srs_warp, nodata = nodata, band_names = NULL,
        skip_nosource = skip_nosource, envir = environment(), r_each = u$r)
    },
    .args = list(cl_base = cl_base, t_srs_warp = t_srs_warp, nodata = nodata,
                 skip_nosource = skip_nosource)
  )
  out <- res[]                      # block for all daemons, results in unit order
  vapply(out, function(x) if (is.character(x)) x else NA_character_, character(1))
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
