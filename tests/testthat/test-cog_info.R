test_that("cog_info reports structure matching GDAL (north-up)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f)
  ds <- methods::new(gdalraster::GDALRaster, f)
  withr::defer(ds$close())

  expect_s3_class(m, "cog_info")
  expect_equal(m$width, ds$getRasterXSize())
  expect_equal(m$height, ds$getRasterYSize())
  expect_equal(m$n_bands, ds$getRasterCount())
  expect_equal(m$dtype, "Int16")
  expect_equal(m$nodata, -9999)
  expect_equal(m$geotransform, ds$getGeoTransform(), tolerance = 1e-6)
  expect_true(gdalraster::srs_is_same(m$crs, ds$getProjection()))
})

test_that("cog_info preserves a south-up geotransform like GDAL", {
  dir <- withr::local_tempdir()
  f <- fx_south(dir)
  m <- cog_info(f)
  ds <- methods::new(gdalraster::GDALRaster, f)
  withr::defer(ds$close())

  expect_equal(m$geotransform, ds$getGeoTransform(), tolerance = 1e-6)
  expect_gt(m$geotransform[6], 0)   # positive N-S term = south-up
})

test_that("cog_source opens once and is reusable", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  src <- cog_source(f)
  expect_s3_class(src, "cog_source")
  expect_identical(cog_info(src)$width, cog_info(f)$width)
})
