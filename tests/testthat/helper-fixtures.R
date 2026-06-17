# Local fixture generators + comparison helpers for cptkirk tests.
#
# cptkirk reads sources through async-tiff, which requires *tiled* (Cloud-
# Optimised-style) GeoTIFFs, so all fixtures are written TILED. Pixel values are
# deterministic so reads can be checked exactly. Most tests compare cptkirk's
# output to gdalraster's own warp of the same fixture: cptkirk warps via GDAL
# too (after an async-tiff fetch into /vsimem), so a correct pipeline is
# bit-identical to GDAL given the exact (`-et 0`) transformer.

# Write a tiled GeoTIFF with a deterministic per-band ramp.
gen_tif <- function(path, nx = 192L, ny = 160L, nbands = 3L, dtype = "Int16",
                    gt = c(5e5, 10, 0, 4002560, 0, -10), crs = "EPSG:32631",
                    nodata = -9999, block = 64L) {
  ds <- gdalraster::create(
    "GTiff", path, nx, ny, nbands, dtype,
    options = c("TILED=YES", sprintf("BLOCKXSIZE=%d", block),
                sprintf("BLOCKYSIZE=%d", block)),
    return_obj = TRUE
  )
  on.exit(ds$close(), add = TRUE)
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt(crs))
  npx <- nx * ny
  for (b in seq_len(nbands)) {
    vals <- as.integer((b * 1000L + (seq_len(npx) - 1L)) %% 4000L)
    ds$write(band = b, xoff = 0L, yoff = 0L, xsize = nx, ysize = ny,
             rasterData = vals)
    if (!is.null(nodata)) ds$setNoDataValue(b, nodata)
  }
  path
}

# A north-up fixture in a temp dir.
fx_north <- function(dir, ...) gen_tif(file.path(dir, "north.tif"), ...)

# A south-up fixture (positive N-S geotransform term), like the AEF tiles.
fx_south <- function(dir, ...) {
  gen_tif(file.path(dir, "south.tif"),
          gt = c(5e5, 10, 0, 4000960, 0, 10), ...)
}

# Two horizontally-adjacent tiles sharing an edge (for mosaic tests).
fx_pair <- function(dir, nx = 128L, ny = 128L, res = 10) {
  x0 <- 5e5; ymax <- 4002560
  a <- gen_tif(file.path(dir, "a.tif"), nx = nx, ny = ny,
               gt = c(x0, res, 0, ymax, 0, -res))
  b <- gen_tif(file.path(dir, "b.tif"), nx = nx, ny = ny,
               gt = c(x0 + nx * res, res, 0, ymax, 0, -res))
  c(a, b)
}

# A tiled COG (with internal overviews) for overview-selection tests.
fx_cog <- function(dir, nx = 512L, ny = 512L) {
  plain <- gen_tif(file.path(dir, "plain.tif"), nx = nx, ny = ny, nbands = 1L)
  cog <- file.path(dir, "cog.tif")
  gdalraster::translate(
    plain, cog,
    cl_arg = c("-of", "COG", "-co", "BLOCKSIZE=128",
               "-co", "OVERVIEW_RESAMPLING=NEAREST"),
    quiet = TRUE
  )
  cog
}

# Read a whole band of a raster as a numeric vector (row-major).
read_band <- function(path, band = 1L) {
  ds <- methods::new(gdalraster::GDALRaster, path)
  on.exit(ds$close(), add = TRUE)
  ds$read(band = band, xoff = 0, yoff = 0,
          xsize = ds$getRasterXSize(), ysize = ds$getRasterYSize(),
          out_xsize = ds$getRasterXSize(), out_ysize = ds$getRasterYSize())
}

raster_dim <- function(path) {
  ds <- methods::new(gdalraster::GDALRaster, path)
  on.exit(ds$close(), add = TRUE)
  c(ds$getRasterXSize(), ds$getRasterYSize(), ds$getRasterCount())
}

# gdalraster::warp reference matching cptkirk's defaults, exact transformer.
gdal_ref_warp <- function(src, dst, t_srs, te, tr, r = "near") {
  gdalraster::warp(
    src, dst, t_srs = t_srs,
    cl_arg = c("-te", formatC(te, format = "f", digits = 6),
               "-tr", formatC(tr, format = "f", digits = 6),
               "-r", r, "-et", "0",
               "-wo", "INIT_DEST=NO_DATA", "-wo", "SKIP_NOSOURCE=YES",
               "-overwrite"),
    quiet = TRUE
  )
  dst
}
