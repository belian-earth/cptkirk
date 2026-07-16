# Fetch many grouped sources through one pool, into raw pixel buffers

`ck_batch_to_buffer()` is
[`ck_batch()`](https://belian-earth.github.io/cptkirk/reference/ck_batch.md)
with the per-output destination changed from a GeoTIFF file to an
**in-memory raw buffer**, exactly as
[`ck_warp_to_buffer()`](https://belian-earth.github.io/cptkirk/reference/ck_warp_to_buffer.md)
is
[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
with that change. It streams every asset across every group through one
global concurrency pool, and warps each output into a raw
band-sequential (BSQ) buffer via a GDAL `MEM` `DATAPOINTER` dataset — no
GeoTIFF intermediate to encode and decode.

## Usage

``` r
ck_batch_to_buffer(
  src,
  stack = FALSE,
  t_srs = NULL,
  te = NULL,
  te_srs = NULL,
  tr = NULL,
  ts = NULL,
  r = c("near", "bilinear", "cubic", "cubicspline", "lanczos", "average", "rms", "mode",
    "max", "min", "med", "q1", "q3", "sum"),
  bands = NULL,
  dtype = NULL,
  fill = NULL,
  cl_arg = character(0),
  num_threads = 1L,
  warp_memory = "auto",
  cache_max = "auto",
  config = NULL,
  overview = NULL,
  margin = 8L,
  io_concurrency = 16L,
  prefetch = NULL,
  max_bytes = NULL,
  sanitise = TRUE
)
```

## Arguments

- src:

  A list; each element a character vector of source URLs/paths that
  belong together (typically one acquisition's band assets). List names
  (and inner vector names) are used to name outputs; see `dst`.

- stack:

  Logical. `FALSE` (default) writes one file per band; `TRUE` stacks
  each group's bands into one file.

- t_srs:

  Target SRS (e.g. `"EPSG:3857"`). If `NULL`, the source CRS is used (no
  reprojection).

- te:

  Target extent `c(xmin, ymin, xmax, ymax)` (required), in `te_srs` if
  given, otherwise in `t_srs`. Defines the AOI and the shared lattice
  origin.

- te_srs:

  SRS of `te` (defaults to `t_srs`).

- tr:

  Target resolution `c(xres, yres)` in target CRS units. Give either
  `tr` or `ts`.

- ts:

  Target size `c(width, height)` in pixels for the full AOI grid; with
  `te` it sets the lattice resolution. Give either `ts` or `tr`.

- r:

  Resampling method (used only on the warp path). Either a single method
  for the whole batch, a flat vector of length equal to the total number
  of assets, or a list mirroring `src` for a per-band method (e.g.
  `"near"` for mask bands, `"bilinear"` for reflectance).

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

  GDAL warp threads per asset. Defaults to `1` (unlike
  [`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)):
  assets are warped one at a time over small windows, where per-warp
  thread spin-up costs more than it saves – `"ALL_CPUS"` was measured
  ~8x slower for this many-small-files pattern.

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

- prefetch:

  Streaming buffer depth: how many completed windows may queue ahead of
  the warp before the fetch pool throttles. `NULL` (default) uses
  `io_concurrency`. A larger value lets the fetch run further ahead to
  absorb consumer (warp) jitter and sustain network saturation, at the
  cost of more buffered windows held in memory (≈ `prefetch` × window
  size).

- max_bytes:

  Safety ceiling (bytes) on the **running sum** of all allocated buffers
  across the batch (they are resident, raw and uncompressed, at once).
  `NULL` (default) uses ~1/3 of system RAM.

- sanitise:

  Logical. Both modes open every source once over one shared connection
  pool per host (so the batch pays ~one TLS handshake, not one per
  source). `TRUE` (default) validates the request and plans/verifies
  every source's grid (handles mixed grids). `FALSE` is a trusted fast
  path: it plans the window from a **single** source and assumes all
  sources share that grid, skipping per-source planning and the probe.
  Use it only when the inputs are known to share one grid (e.g. assets
  of one MGRS tile); off-grid sources may fail or, if their extent
  happens to contain the window, return wrong pixels.

## Value

The buffer descriptors, mirroring the input structure. Each leaf is the
list
[`ck_warp_to_buffer()`](https://belian-earth.github.io/cptkirk/reference/ck_warp_to_buffer.md)
returns (`data`, `nx`, `ny`, `nbands`, `dtype`, `nodata`,
`geotransform`, `crs`), or `NA` where a source did not overlap the AOI
or its fetch failed (the latter warns). `stack = FALSE` (default)
returns a list of lists of descriptors; `stack = TRUE` returns one
descriptor per group (its sources stacked BSQ).

## Details

Each per-tile buffer covers only that tile's warped footprint, snapped
to the shared `te`/`ts` (or `te`/`tr`) pixel lattice, so the tiles of a
group tile the target grid exactly and a consumer can mosaic them by
georeference. Buffers are therefore sized to their footprint, not to the
whole area of interest.

A target grid is required: pass `te` and one of `ts` / `tr`. Unlike
[`ck_batch()`](https://belian-earth.github.io/cptkirk/reference/ck_batch.md),
there is no file-copy path — a buffer must be allocated at a known pixel
size.

## See also

[`ck_batch()`](https://belian-earth.github.io/cptkirk/reference/ck_batch.md)
to write files,
[`ck_warp_to_buffer()`](https://belian-earth.github.io/cptkirk/reference/ck_warp_to_buffer.md)
for a single source.
