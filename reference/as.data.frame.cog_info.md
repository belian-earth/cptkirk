# Tidy one-row-per-source summary of `cog_info` metadata

Flattens
[`cog_info()`](https://belian-earth.github.io/cptkirk/reference/cog_info.md)
output to a data frame with columns `src`, `width`, `height`, `n_bands`,
`dtype`, `nodata`, `crs`, `res_x`, `res_y`, `xmin`, `ymin`, `xmax`,
`ymax`, `n_levels`, `tile_width`, `tile_height`. The per-overview detail
(`level_width` etc.) is collapsed to `n_levels`; inspect a single source
for the full vector.

## Usage

``` r
# S3 method for class 'cog_info'
as.data.frame(x, row.names = NULL, optional = FALSE, ...)

# S3 method for class 'cog_info_list'
as.data.frame(x, row.names = NULL, optional = FALSE, ...)
```

## Arguments

- x:

  A `cog_info` or `cog_info_list` from
  [`cog_info()`](https://belian-earth.github.io/cptkirk/reference/cog_info.md).

- row.names, optional:

  Unused; present for
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) generic
  compatibility.

- ...:

  Unused.

## Value

A data frame, one row per source.
