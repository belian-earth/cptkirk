# Inspect a (remote) GeoTIFF / COG

Reads only the GeoTIFF header and IFDs over a remote-capable reader
(local path, `http(s)://`, `s3://`, `gs://`, `az://`) and returns its
georeferencing and structure. No pixel data is fetched.

## Usage

``` r
cog_info(src)
```

## Arguments

- src:

  Path or URL to a GeoTIFF / Cloud-Optimised GeoTIFF, or a
  [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  handle.

## Value

A list (class `cog_info`) with `width`, `height`, `n_bands`, `dtype`
(GDAL type name), `nodata`, `geotransform` (GDAL corner-based affine,
length 6), `crs` (a string GDAL can import), `band_names`, and the
per-level pixel sizes `level_width` / `level_height` (level 1 = full
resolution, the rest overviews) plus their `tile_width` / `tile_height`.
