# Warp a remote GeoTIFF / COG (a streaming sibling of gdalraster::warp)

A near drop-in for
[`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
that reads its source(s) remotely. The call shape is the same – `src`,
`dst`, `t_srs`, and a raw `gdalwarp` argument vector in `cl_arg` – but
instead of letting GDAL pull the source over `/vsicurl`, cptkirk works
out which pixels the request touches and streams just those tiles over
the Rust `async-tiff` reader (at the appropriate overview level), stages
them in `/vsimem`, then hands the warp to GDAL. Output is identical to
[`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
of the same source.

## Usage

``` r
warp_remote(
  src,
  dst,
  t_srs = "",
  cl_arg = NULL,
  quiet = TRUE,
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
  handle, or a character vector of several sources to mosaic. A
  [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  reuses its already-open handle, skipping the metadata re-read.

- dst:

  Output filename (a regular path, `/vsimem/`, or anything GDAL can
  write). The format is inferred by GDAL or set with `-of` in `cl_arg`.

- t_srs:

  Target SRS (e.g. `"EPSG:3857"`), as in
  [`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html).
  `""` (the default) or `NULL` means no reprojection (source CRS).

- cl_arg:

  Character vector of raw `gdalwarp` flags, forwarded verbatim to
  [`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
  (e.g.
  `c("-te", "0", "0", "100", "100", "-tr", "10", "10", "-r", "bilinear")`).
  cptkirk parses `-te`/`-te_srs`/`-tr`/`-ts` from it purely to size the
  fetch.

- quiet:

  If `TRUE` (default), the GDAL warp runs without a progress callback.
  Unlike
  [`gdalraster::warp()`](https://firelab.github.io/gdalraster/reference/warp.html)
  this defaults to `TRUE`: a progress callback invoked from GDAL's
  worker threads (e.g. with `-multi`) can crash the R session.

- overview:

  Force a 1-based IFD/overview level instead of auto-selecting from the
  output resolution. `1` = full resolution.

- margin:

  Source-pixel margin added around the computed window to cover the
  resampling kernel and reprojection slop (default 8).

- io_concurrency:

  Number of concurrent tile reads – the width of the single global fetch
  pool shared across all source tiles (default 16).

- max_bytes:

  Safety ceiling (bytes) on the staged in-memory window. `NULL`
  (default) uses ~1/3 of system RAM.

- sanitise:

  If `TRUE` (default), validate `cl_arg` (and `t_srs`) against a tiny
  metadata-derived stand-in *before* fetching, so a bad CRS, resampling
  method, creation option or unknown flag fails in milliseconds instead
  of after a remote read. Set `FALSE` to skip the check.

## Value

The `dst` path, invisibly.

## Details

This is the faithful low-level interface: it adds none of cptkirk's
performance opinions and forwards `cl_arg` to GDAL verbatim. For the
recommended, batteries-included helper (named `te`/`tr`/`ts`/`r`/`bands`
arguments, multi-threading, `SKIP_NOSOURCE`, band-subset streaming, ...)
use
[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md).

## See also

[`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
for the recommended helper with named arguments and cptkirk's defaults.
