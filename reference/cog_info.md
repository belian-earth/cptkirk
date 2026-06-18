# Inspect a (remote) GeoTIFF / COG

Reads only the GeoTIFF header and IFDs over a remote-capable reader
(local path, `http(s)://`, `s3://`, `gs://`, `az://`) and returns its
georeferencing and structure. No pixel data is fetched.

## Usage

``` r
cog_info(src, as.data.frame = FALSE)
```

## Arguments

- src:

  Path/URL to a GeoTIFF / Cloud-Optimised GeoTIFF, a
  [`cog_source()`](https://belian-earth.github.io/cptkirk/reference/cog_source.md)
  handle, or a **character vector of several** sources.

- as.data.frame:

  If `TRUE`, return the one-row-per-source data frame (see
  [`as.data.frame.cog_info()`](https://belian-earth.github.io/cptkirk/reference/as.data.frame.cog_info.md))
  instead of the `cog_info` object(s). Default `FALSE`.

## Value

For a single source, a list of class `cog_info` with `width`, `height`,
`n_bands`, `dtype` (GDAL type name), `nodata`, `geotransform` (GDAL
corner-based affine, length 6), `crs` (a string GDAL can import),
`band_names`, and the per-level pixel sizes `level_width` /
`level_height` (level 1 = full resolution, the rest overviews) plus
their `tile_width` / `tile_height`. For several sources, a
`cog_info_list` of such objects. With `as.data.frame = TRUE`, a data
frame of one row per source.

## Details

Pass several sources to inspect a set at once – the metadata reads run
concurrently, and the result is a `cog_info_list` whose print method
summarises the set (shared vs varying CRS / resolution / bands, and
combined extent) – handy for vetting tiles before a mosaic. Convert
either form to a tidy one-row-per-source data frame with
[`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) (or
`as.data.frame = TRUE`).
