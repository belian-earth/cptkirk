#' @title cptkirk: Warp-Speed Remote GDAL Warping of Cloud-Optimised GeoTIFFs
#'
#' @description
#' A remote, overview-aware `gdalwarp`. cptkirk works out which source pixels a
#' requested warp will touch, streams only those tiles over the Rust
#' [async-tiff](https://github.com/developmentseed/async-tiff) reader (high
#' remote-read saturation, at the appropriate overview level), stages them as an
#' in-memory GDAL source, then hands the actual reprojection and resampling to
#' GDAL via `gdalraster` --- following the `gdalwarp` argument interface.
#'
#' @section Warping:
#' Two entry points onto the same engine:
#' - [ck_warp()] --- the recommended, batteries-included helper: named
#'   `t_srs` / `te` / `tr` / `ts` / `r` / `bands` arguments plus cptkirk's
#'   performance defaults (multi-threading, generous warp memory and cache,
#'   `SKIP_NOSOURCE`, band-subset streaming).
#' - [warp_remote()] --- a faithful, defaults-free sibling of
#'   [gdalraster::warp()]: same `src` / `dst` / `t_srs` / `cl_arg` call shape,
#'   but the source is streamed remotely. Forwards `cl_arg` to GDAL verbatim.
#' - [ck_read()] --- [ck_warp()] that returns the result as an R matrix/array
#'   instead of writing a file, for quick extraction and inspection.
#'
#' @section Stacking and batch:
#' The same engine drives many sources through one saturating pool:
#' - [ck_stack()] / [ck_stack_read()] --- fetch one window from N sources and
#'   write (or return) them as separate bands of a single output: the
#'   `gdalbuildvrt -separate` analogue, as opposed to the mosaic [ck_warp()]
#'   makes from multiple sources.
#' - [ck_batch()] --- reproject/resample a whole list of groups (e.g. a STAC
#'   item list, one group per acquisition) through ONE connection pool and ONE
#'   streaming fetch, writing one file per band or one stacked file per group.
#'   The output mirrors the structure of the input.
#'
#' @section Inspection:
#' - [cog_info()] --- read a source's structure and georeferencing (header and
#'   IFDs only; no pixels fetched)
#' - [cog_source()] --- open a source once and reuse the handle across calls
#'
#' @section How it works:
#' From a `gdalwarp`-style request cptkirk:
#' 1. reprojects the target extent into each source's CRS to find the pixel
#'    window that source must supply;
#' 2. selects the overview level matching the output resolution;
#' 3. streams just those tiles concurrently through `async-tiff` (one global
#'    concurrency pool across all tiles);
#' 4. stages them in `/vsimem` and lets GDAL perform the warp, mosaicking
#'    multiple source tiles in a single pass.
#'
#' Across multiple sources the opens share one connection pool per host --- so a
#' batch pays roughly one TLS handshake per host, not one per source --- and each
#' window is warped as soon as it lands, overlapping the fetches still in flight.
#'
#' It reimplements none of GDAL's warp logic; it only sizes and saturates the
#' fetch. Sources may be local paths or `http(s)://`, `s3://`, `gs://`, `az://`
#' URLs.
#'
#' @keywords internal
"_PACKAGE"

#' @importFrom rlang %||%
NULL
