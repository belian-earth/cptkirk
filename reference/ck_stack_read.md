# Stack many sources straight into an R array

`ck_stack_read()` is
[`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md)
that hands back pixels instead of writing a file: it stacks the sources
as separate bands (see
[`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md))
into an uncompressed `/vsimem` raster and reads it back as a base-R
array.

## Usage

``` r
ck_stack_read(
  src,
  t_srs = NULL,
  te = NULL,
  te_srs = NULL,
  tr = NULL,
  ts = NULL,
  tap = TRUE,
  r = c("near", "bilinear", "cubic", "cubicspline", "lanczos", "average", "rms", "mode",
    "max", "min", "med", "q1", "q3", "sum"),
  bands = NULL,
  cl_arg = character(0),
  num_threads = "ALL_CPUS",
  warp_memory = "auto",
  cache_max = "auto",
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

  Target resolution `c(xres, yres)` in target CRS units. Takes
  precedence over `ts`: if both are given, `ts` is ignored (with a
  warning).

- ts:

  Target size `c(width, height)` in pixels. Ignored if `tr` is also
  supplied.

- tap:

  If `TRUE` (default) and `tr` is given, align output pixel boundaries
  to the `tr` grid (gdalwarp `-tap`), anchored at the CRS origin, so
  outputs at the same resolution share a grid and stack cleanly. This
  snaps the output extent outward, so it is no longer exactly `te`. No
  effect with `ts` or on the copy path. An explicit `-tap` in `cl_arg`
  is always honoured.
  ([`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md)
  never adds this; pass `-tap` yourself.)

- r:

  Resampling method (used only on the warp path; a native-window copy
  ignores it). Either a single method applied to every source, or a
  vector of length `length(src)` giving a per-source method (e.g.
  `"near"` for a mask band, `"bilinear"` for reflectance).

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

  Safety ceiling (bytes) on the **returned array**, sized as
  `nrow * ncol * nbands * 8`. `NULL` (default) uses ~1/3 of system RAM.

- sanitise:

  If `TRUE` (default), validate the warp arguments against a tiny
  metadata-derived stand-in *before* fetching, so a bad CRS, resampling
  method, creation option or unknown flag fails in milliseconds instead
  of after a remote read. Set `FALSE` to skip the check.

## Value

A numeric array with dimensions `[nrow, ncol, nband]` (or a matrix for a
single output band), carrying `geotransform`, `crs` and (when set)
`nodata` attributes. Band names are not preserved on the array.

## See also

[`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md)
to write a file instead.
