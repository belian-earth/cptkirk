# The thin warp_remote(): a streaming sibling of gdalraster::warp(). Geometry
# is passed through cl_arg verbatim; output must match gdalraster::warp of the
# same source.

test_that("warp_remote (cl_arg form) is bit-identical to gdalraster::warp", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  cl <- c("-te", formatC(te, format = "f", digits = 6),
          "-tr", "15", "15", "-r", "near", "-et", "0",
          "-wo", "INIT_DEST=NO_DATA", "-wo", "SKIP_NOSOURCE=YES", "-overwrite")
  d1 <- file.path(dir, "thin.tif"); d2 <- file.path(dir, "g.tif")
  warp_remote(f, d1, t_srs = "EPSG:3857", cl_arg = cl)
  gdal_ref_warp(f, d2, "EPSG:3857", te, c(15, 15), r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("warp_remote copy path round-trips with no t_srs", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "copy.tif")
  warp_remote(f, d)   # t_srs = "" -> identity copy path

  expect_equal(raster_dim(d), raster_dim(f))
  for (b in 1:3) expect_equal(read_band(d, b), read_band(f, b))
})

test_that("warp_remote parses -ts (size) from cl_arg to size the output", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 160 * gt[6], gt[1] + 192 * gt[2], gt[4])
  d <- file.path(dir, "ts.tif")
  warp_remote(f, d, t_srs = m$crs,
              cl_arg = c("-te", formatC(te, format = "f", digits = 6),
                         "-ts", "96", "80", "-r", "near"))
  expect_equal(raster_dim(d)[1:2], c(96L, 80L))
})
