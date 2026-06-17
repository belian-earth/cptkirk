# The argument sanitiser validates the warp request against a tiny stand-in
# *before* any fetch, so bad args fail fast rather than after a remote read.

test_that("an unparseable CRS is rejected (structural layer)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  expect_error(ck_warp(f, o, t_srs = "EPSG:999999"), "CRS")
  expect_error(warp_remote(f, o, t_srs = "EPSG:999999"), "CRS")
})

test_that("an empty/degenerate extent is rejected", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  # xmax < xmin
  expect_error(ck_warp(f, o, t_srs = "EPSG:3857", te = c(10, 0, 1, 5),
                       tr = c(1, 1)), "empty")
})

test_that("a bad resampling method is caught by the GDAL probe", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  expect_error(
    warp_remote(f, o, t_srs = "EPSG:3857", cl_arg = c("-r", "definitely_not_a_method")),
    "rejected the warp arguments"
  )
})

test_that("an unknown flag / output driver is caught by the GDAL probe", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  # a typo'd flag
  expect_error(
    warp_remote(f, o, cl_arg = c("-overwirte")),
    "rejected the warp arguments"
  )
  # an unrecognised output driver
  expect_error(
    warp_remote(f, o, cl_arg = c("-of", "NOT_A_REAL_DRIVER")),
    "rejected the warp arguments"
  )
})

test_that("sanitise = FALSE skips the pre-flight check", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  d <- file.path(dir, "ns.tif")
  # valid request, but with the check off: still produces the right output
  expect_no_error(
    ck_warp(f, d, t_srs = "EPSG:3857", te = te, tr = c(15, 15), r = "near",
            sanitise = FALSE)
  )
  expect_equal(raster_dim(d)[3], m$n_bands)
})
