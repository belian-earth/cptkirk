# ck_warp's performance knobs are tri-state: "auto" (cptkirk default), NULL
# (defer to the ambient env/session), or an explicit number.

test_that(".resolve_speed maps the three states correctly", {
  expect_null(.resolve_speed(NULL, function() 999))            # defer
  expect_equal(.resolve_speed("auto", function() 999), 999)    # cptkirk default
  expect_equal(.resolve_speed(100, function() 999), 100)       # explicit
  expect_equal(.resolve_speed(100, function() 999, scale = 1e6), 1e8)  # MB -> bytes
})

test_that("ck_warp restores GDAL config regardless of knob state", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  withr::local_envvar(GDAL_NUM_THREADS = "3")
  before <- gdalraster::get_config_option("GDAL_NUM_THREADS")

  ck_warp(f, file.path(dir, "a.tif"))                          # all defaults
  ck_warp(f, file.path(dir, "b.tif"),
          num_threads = NULL, cache_max = NULL, warp_memory = NULL)  # all deferred
  ck_warp(f, file.path(dir, "c.tif"), cache_max = 128, warp_memory = 64)

  expect_equal(gdalraster::get_config_option("GDAL_NUM_THREADS"), before)
})

test_that("deferring knobs still produces correct output", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  d1 <- file.path(dir, "def.tif"); d2 <- file.path(dir, "g.tif")
  ck_warp(f, d1, t_srs = "EPSG:3857", te = te, tr = c(15, 15), r = "near",
          cl_arg = c("-et", "0"),
          num_threads = NULL, cache_max = NULL, warp_memory = NULL)
  gdal_ref_warp(f, d2, "EPSG:3857", te, c(15, 15), r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})
