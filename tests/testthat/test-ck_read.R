# ck_read() returns pixels as an R matrix/array. The native-window path decodes
# fetched bytes directly (no GDAL); the warp path goes through /vsimem.

# Drop ck_read's georef attributes, keeping only dim, for value comparisons.
bare <- function(x) `attributes<-`(x, list(dim = dim(x)))

test_that("ck_read native window returns pixels directly, self-describing", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f)
  a <- ck_read(f)                       # full raster, native grid -> readBin path

  expect_equal(dim(a), c(m$height, m$width, m$n_bands))
  for (b in 1:3) {
    expect_equal(a[, , b],
                 matrix(read_band(f, b), nrow = m$height, ncol = m$width, byrow = TRUE))
  }
  expect_equal(attr(a, "geotransform"), m$geotransform, tolerance = 1e-6)
  expect_true(gdalraster::srs_is_same(attr(a, "crs"), m$crs))
  expect_equal(attr(a, "nodata"), m$nodata)
})

test_that("ck_read single band returns a matrix", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f)
  a <- ck_read(f, bands = 2L)
  expect_true(is.matrix(a))
  expect_equal(dim(a), c(m$height, m$width))
  expect_equal(bare(a), matrix(read_band(f, 2L), nrow = m$height, ncol = m$width, byrow = TRUE))
})

test_that("ck_read warp path matches ck_warp output read back", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  a <- ck_read(f, t_srs = "EPSG:3857", te = te, tr = c(15, 15), r = "near",
               cl_arg = c("-et", "0"))
  # reference: ck_warp the same request to a file (same tap default), read back
  d <- file.path(dir, "w.tif")
  ck_warp(f, d, t_srs = "EPSG:3857", te = te, tr = c(15, 15), r = "near",
          co = NULL, cl_arg = c("-et", "0"))
  rd <- raster_dim(d)   # c(nx, ny, nbands)
  expect_equal(dim(a), c(rd[2], rd[1], rd[3]))
  for (b in 1:3) {
    expect_equal(a[, , b], matrix(read_band(d, b), nrow = rd[2], ncol = rd[1], byrow = TRUE))
  }
  expect_true(gdalraster::srs_is_same(attr(a, "crs"), "EPSG:3857"))
})

test_that("ck_read guards the returned array size (f64)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f)
  # native bytes (Int16) fit, but the f64 array (8 bytes/px) does not
  native <- m$width * m$height * m$n_bands * 2
  f64    <- m$width * m$height * m$n_bands * 8
  cap <- (native + f64) / 2            # passes the fetch guard, trips the output guard
  expect_error(ck_read(f, max_bytes = cap), "[Rr]eturned array")
})

test_that("ck_read falls back to gdalraster for dtypes readBin can't represent", {
  dir <- withr::local_tempdir()
  f <- gen_tif(file.path(dir, "u32.tif"), nx = 96L, ny = 80L, nbands = 1L,
               dtype = "UInt32", nodata = NULL)
  m <- cog_info(f)
  expect_identical(.readbin_spec("UInt32"), NULL)   # would take the fallback
  a <- ck_read(f, bands = 1L)
  expect_equal(dim(a), c(m$height, m$width))
  expect_equal(bare(a), matrix(read_band(f, 1L), nrow = m$height, ncol = m$width, byrow = TRUE))
})
