# Warp a remote GeoTIFF / COG into a raw native-dtype pixel buffer

`ck_warp_to_buffer()` is
[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
with the final destination changed from a GeoTIFF file to an **in-memory
raw buffer**: it streams only the tiles the request touches, warps them
with GDAL (the same engine, sanitiser and fetch defaults as
[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md))
onto a fixed target grid, and fills a raw R vector in place through a
GDAL `MEM` `DATAPOINTER` dataset — no GeoTIFF intermediate.

## Usage

``` r
ck_warp_to_buffer(
  src,
  t_srs = NULL,
  te,
  ts,
  te_srs = NULL,
  r = c("near", "bilinear", "cubic", "cubicspline", "lanczos", "average", "rms", "mode",
    "max", "min", "med", "q1", "q3", "sum"),
  bands = NULL,
  dtype = NULL,
  fill = NULL,
  cl_arg = character(0),
  num_threads = "ALL_CPUS",
  warp_memory = "auto",
  cache_max = "auto",
  config = NULL,
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

  Target extent `c(xmin, ymin, xmax, ymax)` (required), in `te_srs` if
  given, otherwise in `t_srs`. Defines the buffer's geographic
  footprint.

- ts:

  Target size `c(width, height)` in pixels (required). Defines the
  buffer's dimensions exactly. `tr` is not accepted here: the buffer
  must be allocated at a known pixel size, so the grid is pinned by
  `ts`.

- te_srs:

  SRS of `te` (defaults to `t_srs`).

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

- dtype:

  Optional output data type as a GDAL type name (e.g. `"Float32"`).
  `NULL` (default) keeps the source's native type, so the caller
  receives the raw codes; set it to have GDAL convert during the warp.

- fill:

  Value written to output pixels no source covers (and used to pre-fill
  the buffer). `NULL` (default) uses the source nodata, falling back to
  `0`. Returned as `nodata` so the caller can mask untouched pixels —
  important for integer types, which have no `NaN`.

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

  Safety ceiling (bytes) on the returned buffer, sized as
  `width * height * bands * <dtype bytes>`. `NULL` (default) uses ~1/3
  of system RAM.

- sanitise:

  If `TRUE` (default), validate the warp arguments against a tiny
  metadata-derived stand-in *before* fetching, so a bad CRS, resampling
  method, creation option or unknown flag fails in milliseconds instead
  of after a remote read. Set `FALSE` to skip the check.

## Value

A list describing the filled buffer:

- data:

  the raw vector, `nx * ny * nbands * <dtype bytes>` bytes, BSQ.

- nx, ny:

  output width and height in pixels.

- nbands:

  number of bands (after any `bands` subset).

- dtype:

  GDAL data-type name of the samples.

- nodata:

  the `fill` value (untouched-pixel sentinel).

- geotransform:

  the 6-element output geotransform (in the target CRS).

- crs:

  the target CRS as WKT.

## Details

The target grid is defined exactly by `te` + `ts`: the output is a
`ts[1]` x `ts[2]` (width x height) grid spanning `te`, so callers get
back the precise grid they asked for (no `-tap` snapping). The buffer
holds the pixels **band-sequentially (BSQ)**: band 1's full `ny` x `nx`
plane, then band 2's, and so on; each plane is **row-major** with row 0
the northern edge; samples are in the source's **native data type** and
host byte order. This is the layout a downstream engine (garry) uploads
and fuses a decode onto.

## See also

[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
to write a warped file,
[`ck_read()`](https://belian-earth.github.io/cptkirk/reference/ck_read.md)
for an R array.
