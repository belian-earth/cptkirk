# Warp a remote GeoTIFF / COG with cptkirk's defaults (recommended)

The recommended, batteries-included entry point. `ck_warp()` takes the
grid-defining `gdalwarp` options as named arguments (`t_srs`, `te`,
`tr`, `ts`, `r`, `bands`), layers on cptkirk's performance defaults
(multi-threaded warp, generous warp memory and block cache,
`SKIP_NOSOURCE`), and streams only the pixels the request touches over
`async-tiff` before handing the warp to GDAL via
[`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html).
For a faithful, defaults-free sibling of
[`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html),
see
[`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md).

## Usage

``` r
ck_warp(
  src,
  dst,
  t_srs = NULL,
  te = NULL,
  te_srs = NULL,
  tr = NULL,
  ts = NULL,
  r = c("near", "bilinear", "cubic", "cubicspline", "lanczos", "average", "rms", "mode",
    "max", "min", "med", "q1", "q3", "sum"),
  bands = NULL,
  cl_arg = character(0),
  num_threads = "ALL_CPUS",
  warp_memory = "auto",
  cache_max = "auto",
  co = NULL,
  config = NULL,
  skip_nosource = TRUE,
  overview = NULL,
  margin = 8L,
  io_concurrency = 16L,
  max_bytes = NULL,
  sanitise = TRUE
)
```

## Arguments

- src:

  Path/URL to a source GeoTIFF / COG, a
  [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  handle, or a **character vector of several** sources to mosaic (each
  tile's overlapping window is fetched and the set is
  reprojected/mosaicked in one warp; non-overlapping tiles are skipped).
  Passing a
  [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  reuses its already-open handle, skipping the metadata re-read –
  worthwhile when warping many AOIs from the same source.

- dst:

  Output filename (a regular path, a `/vsimem/` path, or anything GDAL
  can write). The format is inferred by GDAL or set with `-of` in
  `cl_arg`.

- t_srs:

  Target SRS (e.g. `"EPSG:3857"`). If `NULL`, the source CRS is used (no
  reprojection).

- te:

  Target extent `c(xmin, ymin, xmax, ymax)`, in `te_srs` if given,
  otherwise in `t_srs`. When supplied this is the AOI that drives the
  fetch.

- te_srs:

  SRS of `te` (defaults to `t_srs`).

- tr:

  Target resolution `c(xres, yres)` in target CRS units.

- ts:

  Target size `c(width, height)` in pixels.

- r:

  Resampling method, one of `"near"` (default), `"bilinear"`, `"cubic"`,
  `"cubicspline"`, `"lanczos"`, `"average"`, `"rms"`, `"mode"`, `"max"`,
  `"min"`, `"med"`, `"q1"`, `"q3"`, `"sum"`. Matched with
  [`rlang::arg_match()`](https://rlang.r-lib.org/reference/arg_match.html),
  so a typo reports the valid set. (A method added by a newer GDAL than
  this list knows can still be passed via `cl_arg`.)

- bands:

  1-based source bands to read (default: all). Subsetting happens during
  the fetch, so only those bands' bytes are streamed.

- cl_arg:

  Character vector of extra raw `gdalwarp` flags, forwarded verbatim to
  [`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
  (e.g. `c("-et", "0")`). These are merged with the flags cptkirk builds
  from the named arguments above.

- num_threads:

  Value for GDAL's warp `NUM_THREADS` warp option and the
  `GDAL_NUM_THREADS` config (default `"ALL_CPUS"`), parallelising the
  resampling computation and GeoTIFF (de)compression. `NULL` sets
  neither, deferring to the ambient `GDAL_NUM_THREADS` (env / session).

- warp_memory:

  Warp working memory in MB (GDAL `-wm`). `"auto"` (default) uses ~25%
  of system RAM, clamped to 256-2048 MB (bigger means fewer, larger
  chunks); `NULL` defers to GDAL's own default; a number sets it
  explicitly.

- cache_max:

  GDAL block cache in MB for this call. `"auto"` (default) uses ~25% of
  RAM, clamped to 256-2000 MB; `NULL` defers to the ambient
  `GDAL_CACHEMAX` (env /
  [`gdalraster::set_config_option()`](https://firelab.github.io/gdalraster/reference/set_config_option.html));
  a number sets it explicitly. Any value is restored to the previous
  setting afterwards.

- co:

  Character vector of GDAL output creation options, e.g.
  `c("COMPRESS=ZSTD", "TILED=YES", "NUM_THREADS=ALL_CPUS")`.

- config:

  Named character vector / list of extra GDAL config options to set for
  the duration of the call (restored on exit).

- skip_nosource:

  If `TRUE` (default), pass `SKIP_NOSOURCE=YES` + `INIT_DEST` so the
  warper skips output chunks with no source coverage (e.g. nodata
  margins from reprojection). No effect when output is fully covered.
  Ignored on the copy fast-path.

- overview:

  Force a 1-based IFD/overview level instead of auto-selecting from the
  output resolution. `1` = full resolution.

- margin:

  Source-pixel margin added around the computed window to cover the
  resampling kernel and reprojection slop (default 8).

- io_concurrency:

  Number of concurrent tile reads – the width of the single global fetch
  pool shared across all source tiles. Default 16, which suits object
  stores that throttle around that many simultaneous range requests
  (e.g. S3 / source.coop). Raise (24-32) on a fast, stable link; lower
  if a store rate-limits.

- max_bytes:

  Safety ceiling (bytes) on the staged in-memory window
  (`width * height * bands * <native dtype bytes>`). `NULL` (default)
  uses ~1/3 of system RAM. It only guards against the foot-gun of
  warping a whole large multi-band raster at native resolution; narrow
  the request, coarsen `tr`/`ts`, or raise this to allow it.

- sanitise:

  If `TRUE` (default), validate the warp arguments against a tiny
  metadata-derived stand-in *before* fetching, so a bad CRS, resampling
  method, creation option or unknown flag fails in milliseconds instead
  of after a remote read. Set `FALSE` to skip the check.

## Value

The `dst` path, invisibly.

## Details

Every actual resampling / reprojection decision is GDAL's; cptkirk only
sizes and saturates the fetch.

## See also

[`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md)
for the thin
[`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
sibling.
