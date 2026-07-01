# Fetch many grouped sources through one pool, with structure-preserving output

`ck_batch()` takes a **list of groups** of source URLs – e.g. one group
per acquisition, each group the band-level asset URLs for that
acquisition – and fetches the same area-of-interest window from **every
asset across every group through a single global concurrency pool**. One
pool over the whole job saturates the network far better than reading
each group separately, and the returned paths mirror the input structure
so onward tasks know which output is which.

## Usage

``` r
ck_batch(
  src,
  dst = tempfile(fileext = ".tif"),
  stack = FALSE,
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
  num_threads = 1L,
  warp_memory = "auto",
  cache_max = "auto",
  co = c("COMPRESS=DEFLATE", "TILED=YES", "NUM_THREADS=ALL_CPUS", "BIGTIFF=IF_SAFER"),
  config = NULL,
  skip_nosource = TRUE,
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

- dst:

  Output location. Either an explicit path structure matching the output
  (a list of character vectors when `stack = FALSE`, a character vector
  of length `length(src)` when `stack = TRUE`), **or** a single string
  used as a path *template*: unique output paths are derived from it
  using the group names (and band names) of `src`, falling back to
  positional indices when names are absent. May be a `/vsi*` path.
  Defaults to a temp-file template.

- stack:

  Logical. `FALSE` (default) writes one file per band; `TRUE` stacks
  each group's bands into one file.

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

  Resampling method (used only on the warp path). Either a single method
  for the whole batch, a flat vector of length equal to the total number
  of assets, or a list mirroring `src` for a per-band method (e.g.
  `"near"` for mask bands, `"bilinear"` for reflectance).

- bands:

  1-based source bands to read (default: all). Subsetting happens during
  the fetch, so only those bands' bytes are streamed.

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

- co:

  GDAL output creation options, defaulting to a cloud-friendly GeoTIFF
  set:
  `c("COMPRESS=DEFLATE", "TILED=YES", "NUM_THREADS=ALL_CPUS", "BIGTIFF=IF_SAFER")`
  — losslessly compressed, tiled (so the output can be re-read by
  cptkirk and any other COG reader), compressed in parallel, and
  promoted to BigTIFF when it might exceed 4 GB. Pass your own to
  override (e.g. add `"PREDICTOR=2"` for integer data, or
  `"COMPRESS=ZSTD"` on a GDAL built with it), or `NULL` for no creation
  options. These target the GTiff/COG drivers; set `co` yourself for
  other output formats.

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

- prefetch:

  Streaming buffer depth: how many completed windows may queue ahead of
  the warp before the fetch pool throttles. `NULL` (default) uses
  `io_concurrency`. A larger value lets the fetch run further ahead to
  absorb consumer (warp) jitter and sustain network saturation, at the
  cost of more buffered windows held in memory (≈ `prefetch` × window
  size).

- max_bytes:

  Safety ceiling (bytes) on the staged in-memory window
  (`width * height * bands * <native dtype bytes>`). `NULL` (default)
  uses ~1/3 of system RAM. It only guards against the foot-gun of
  warping a whole large multi-band raster at native resolution; narrow
  the request, coarsen `tr`/`ts`, or raise this to allow it.

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

The output paths, mirroring the input structure: a list of character
vectors when `stack = FALSE`, a named character vector when
`stack = TRUE`. Outputs are `NA` when the source did not overlap the
AOI, or when its fetch failed (the latter emits a warning; for
`stack = TRUE` a single failed band leaves the whole group `NA`).

## Details

Output granularity is set by `stack`:

- `stack = FALSE` (default): one file **per band**. The return value
  mirrors the full nested input – a list (one element per group) of
  character vectors (one path per band). This is what tools that bundle
  bands themselves (e.g. vrtility's per-timestamp VRTs) expect.

- `stack = TRUE`: one band-separated file **per group** (see
  [`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md)).
  The return value is a character vector, one path per group.

A single AOI (`te` / `t_srs` / `tr` / `ts`) applies to the whole batch;
each source clips it to its own grid, so groups on different tiles are
fine.

## Parallel warp

The fetch always uses cptkirk's single connection pool. The per-output
warp + write is dispatched across an **ambient mirai daemon pool** when
one is running (mirai and mori installed and `mirai::daemons(n)`
active), and runs inline otherwise. This helps when the warp/write backs
up behind the fetch (slow links, large or many-band warps). There is no
argument: start daemons to enable, `mirai::daemons(0)` to disable.
Fetched window buffers are handed to daemons zero-copy via mori, and
each daemon warps single-threaded. cptkirk never spawns or tears down
daemons.

## See also

[`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md)
for a single group.
