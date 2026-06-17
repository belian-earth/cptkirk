# Open a (remote) GeoTIFF / COG once and reuse it

Opens the source over a remote-capable reader (local path, `http(s)://`,
`s3://`, `gs://`, `az://`), reading the header and all IFDs a single
time. The returned handle can be passed to
[`cog_info()`](https://belian-earth.github.io/cptkirk/reference/cog_info.md)
and
[`warp_remote()`](https://belian-earth.github.io/cptkirk/reference/warp_remote.md)
in place of a URL, so repeated warps of the same raster (e.g. many AOIs,
or a set of rasters) pay the metadata round-trips only once.

## Usage

``` r
cog_source(src)
```

## Arguments

- src:

  Path or URL to a GeoTIFF / Cloud-Optimised GeoTIFF.

## Value

An object of class `cog_source` wrapping an open handle.

## Authentication

Remote object-store sources (`s3://`, `gs://`, `az://`) authenticate
from the **process environment**, using the variable names
`object_store` documents (e.g. `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`;
`GOOGLE_SERVICE_ACCOUNT`; `AZURE_STORAGE_ACCOUNT_NAME`). With no static
credentials the builders fall back to the platform chain (web-identity,
ECS, EC2 instance metadata). For public buckets set
`AWS_SKIP_SIGNATURE=true` (or just use the `https://` URL). Credentials
are never passed through R, so they stay out of scripts and logs. This
is independent of GDAL's `/vsi*` credential settings, which cptkirk does
not use for reading.
