# Network-gated tests: skipped on CRAN and when offline. They exercise the
# actual async-tiff remote read path against a small public COG.

remote_cog <- "https://raw.githubusercontent.com/cogeotiff/rio-tiler/main/tests/fixtures/cog.tif"

test_that("cog_info reads a remote COG", {
  skip_if_offline()
  m <- cog_info(remote_cog)
  expect_gt(m$width, 0L)
  expect_gte(m$n_bands, 1L)
  expect_false(is.null(m$crs))
  expect_length(m$geotransform, 6L)
})

test_that("warp_remote streams + warps a remote COG window", {
  skip_if_offline()
  m <- cog_info(remote_cog)
  gt <- m$geotransform
  # a sub-window well inside the footprint
  sx <- gt[1] + c(200, 700) * gt[2]
  sy <- gt[4] + c(200, 700) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  dir <- withr::local_tempdir()
  d <- file.path(dir, "remote.tif")
  warp_remote(remote_cog, d, t_srs = "EPSG:3857", te = te, tr = c(150, 150),
              r = "near")

  expect_equal(raster_dim(d)[3], m$n_bands)
  v <- read_band(d, 1)
  expect_true(any(is.finite(v)))   # real pixels came back, not all nodata
})
