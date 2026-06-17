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
#' - [warp_remote()] --- stream, mosaic and reproject/resample remote
#'   (Cloud-Optimised) GeoTIFFs onto a target grid, following the `gdalwarp`
#'   argument interface (`t_srs` / `te` / `tr` / `ts` / `r` / `bands` / `cl_arg`)
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
#' It reimplements none of GDAL's warp logic; it only sizes and saturates the
#' fetch. Sources may be local paths or `http(s)://`, `s3://`, `gs://`, `az://`
#' URLs.
#'
#' @keywords internal
"_PACKAGE"

#' @importFrom rlang %||%
NULL
