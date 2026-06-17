# Package index

## Warping

Stream, mosaic and reproject/resample remote (Cloud-Optimised) GeoTIFFs
onto a target grid, following the gdalwarp argument interface.

- [`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
  : Warp a remote GeoTIFF / COG with cptkirk's defaults (recommended)
- [`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md)
  : Warp a remote GeoTIFF / COG (a streaming sibling of
  gdalraster::warp)

## Inspection

Read a source’s structure and georeferencing, or open it once and reuse
the handle across calls.

- [`cog_info()`](https://belian-earth.github.io/cptkirk/reference/cog_info.md)
  : Inspect a (remote) GeoTIFF / COG
- [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  : Open a (remote) GeoTIFF / COG once and reuse it
