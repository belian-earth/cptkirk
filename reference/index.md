# Package index

## Warping

Stream, mosaic and reproject/resample remote (Cloud-Optimised) GeoTIFFs
onto a target grid, following the gdalwarp argument interface.

- [`ck_warp()`](https://belian-earth.github.io/cptkirk/reference/ck_warp.md)
  : Warp a remote GeoTIFF / COG with cptkirk's defaults (recommended)
- [`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md)
  : Warp a remote GeoTIFF / COG (a streaming sibling of
  gdalraster::warp)
- [`ck_read()`](https://belian-earth.github.io/cptkirk/reference/ck_read.md)
  : Warp a remote GeoTIFF / COG straight into an R array

## Stacking & batch

Drive many sources through one saturating pool: stack sources as
separate bands of one output, or reproject/resample a whole list of
groups (e.g. a STAC item list, one group per acquisition) in a single
streaming fetch.

- [`ck_stack()`](https://belian-earth.github.io/cptkirk/reference/ck_stack.md)
  : Stack many sources into one band-separated raster (buildvrt
  -separate)
- [`ck_stack_read()`](https://belian-earth.github.io/cptkirk/reference/ck_stack_read.md)
  : Stack many sources straight into an R array
- [`ck_batch()`](https://belian-earth.github.io/cptkirk/reference/ck_batch.md)
  : Fetch many grouped sources through one pool, with
  structure-preserving output

## Inspection

Read a source’s structure and georeferencing, or open it once and reuse
the handle across calls.

- [`cog_info()`](https://belian-earth.github.io/cptkirk/reference/cog_info.md)
  : Inspect a (remote) GeoTIFF / COG

- [`as.data.frame(`*`<cog_info>`*`)`](https://belian-earth.github.io/cptkirk/reference/as.data.frame.cog_info.md)
  [`as.data.frame(`*`<cog_info_list>`*`)`](https://belian-earth.github.io/cptkirk/reference/as.data.frame.cog_info.md)
  :

  Tidy one-row-per-source summary of `cog_info` metadata

- [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  : Open a (remote) GeoTIFF / COG once and reuse it
