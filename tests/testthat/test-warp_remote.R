test_that("copy fast-path round-trips the source pixels and grid", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "copy.tif")
  warp_remote(f, d)   # no t_srs/tr/ts -> identity copy path (translate)

  expect_equal(raster_dim(d), raster_dim(f))
  for (b in 1:3) expect_equal(read_band(d, b), read_band(f, b))
  expect_equal(cog_info(d)$geotransform, cog_info(f)$geotransform, tolerance = 1e-6)
})

test_that("band subset selects and reorders bands", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "sub.tif")
  warp_remote(f, d, bands = c(3L, 1L))

  expect_equal(raster_dim(d)[3], 2L)
  expect_equal(read_band(d, 1), read_band(f, 3))
  expect_equal(read_band(d, 2), read_band(f, 1))
})

test_that("reproject is bit-identical to gdalraster::warp (north-up)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  # a sub-window strictly inside the footprint -> output fully covered
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  tr <- c(15, 15)
  d1 <- file.path(dir, "k.tif"); d2 <- file.path(dir, "g.tif")
  warp_remote(f, d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
              cl_arg = c("-et", "0"))
  gdal_ref_warp(f, d2, "EPSG:3857", te, tr, r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("south-up source reprojects identically to gdalraster::warp", {
  dir <- withr::local_tempdir()
  f <- fx_south(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  tr <- c(15, 15)
  d1 <- file.path(dir, "k.tif"); d2 <- file.path(dir, "g.tif")
  warp_remote(f, d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
              cl_arg = c("-et", "0"))
  gdal_ref_warp(f, d2, "EPSG:3857", te, tr, r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("a cog_source handle gives the same result as the URL", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  tr <- c(15, 15)
  src <- cog_source(f)
  d1 <- file.path(dir, "url.tif"); d2 <- file.path(dir, "handle.tif")
  warp_remote(f,   d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
              cl_arg = c("-et", "0"))
  warp_remote(src, d2, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
              cl_arg = c("-et", "0"))
  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))

  # copy fast-path also works through a reused handle
  d3 <- file.path(dir, "hcopy.tif")
  warp_remote(src, d3)
  for (b in 1:3) expect_equal(read_band(d3, b), read_band(f, b))
})

test_that("multi-source mosaic matches gdalraster::warp of the same tiles", {
  dir <- withr::local_tempdir()
  ab <- fx_pair(dir, nx = 128L, ny = 128L, res = 10)
  m <- cog_info(ab[1]); gt <- m$geotransform
  te <- c(gt[1], gt[4] - 128 * 10, gt[1] + 256 * 10, gt[4])   # spans both tiles
  tr <- c(10, 10)
  d1 <- file.path(dir, "km.tif"); d2 <- file.path(dir, "gm.tif")
  warp_remote(ab, d1, t_srs = m$crs, te = te, tr = tr, r = "near",
              cl_arg = c("-et", "0"))
  gdal_ref_warp(ab, d2, m$crs, te, tr, r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("overview selection produces correct dims on a COG", {
  dir <- withr::local_tempdir()
  cog <- fx_cog(dir, nx = 512L, ny = 512L)
  m <- cog_info(cog)
  expect_gt(m$n_levels, 1L)        # COG has overviews
  gt <- m$geotransform
  te <- c(gt[1], gt[4] + 512 * gt[6], gt[1] + 512 * gt[2], gt[4])
  d <- file.path(dir, "ov.tif")
  # coarse output (40 m from 10 m) -> an overview is selected
  warp_remote(cog, d, t_srs = m$crs, te = te, tr = c(40, 40), r = "near")
  expect_equal(raster_dim(d)[1:2], c(128L, 128L))
})
