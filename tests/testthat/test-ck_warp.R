# The recommended helper: named te/tr/ts/r/bands + cptkirk's defaults. Most
# tests compare ck_warp's output to gdalraster's own warp of the same fixture;
# a correct pipeline is bit-identical to GDAL given the exact (`-et 0`)
# transformer.

test_that("copy fast-path round-trips the source pixels and grid", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "copy.tif")
  ck_warp(f, d)   # no t_srs/tr/ts -> identity copy path (translate)

  expect_equal(raster_dim(d), raster_dim(f))
  for (b in 1:3) expect_equal(read_band(d, b), read_band(f, b))
  expect_equal(cog_info(d)$geotransform, cog_info(f)$geotransform, tolerance = 1e-6)
})

test_that("ck_warp writes compressed, tiled output by default", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  compression <- function(p) {
    ds <- methods::new(gdalraster::GDALRaster, p)
    on.exit(ds$close(), add = TRUE)
    ds$getMetadataItem(band = 0L, "COMPRESSION", "IMAGE_STRUCTURE")
  }
  d1 <- file.path(dir, "z.tif")
  d2 <- file.path(dir, "u.tif")
  ck_warp(f, d1)               # default co -> DEFLATE + TILED + ...
  ck_warp(f, d2, co = NULL)    # opt out -> uncompressed
  expect_match(compression(d1), "DEFLATE")
  expect_identical(compression(d2), "")
  # the tiled default output re-reads through cptkirk's tiling-requiring reader
  expect_no_error(cog_info(d1))
})

test_that("band subset selects and reorders bands", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "sub.tif")
  ck_warp(f, d, bands = c(3L, 1L))

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
  ck_warp(f, d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
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
  ck_warp(f, d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
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
  ck_warp(f,   d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
          cl_arg = c("-et", "0"))
  ck_warp(src, d2, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
          cl_arg = c("-et", "0"))
  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))

  # copy fast-path also works through a reused handle
  d3 <- file.path(dir, "hcopy.tif")
  ck_warp(src, d3)
  for (b in 1:3) expect_equal(read_band(d3, b), read_band(f, b))
})

test_that("multi-source mosaic matches gdalraster::warp of the same tiles", {
  dir <- withr::local_tempdir()
  ab <- fx_pair(dir, nx = 128L, ny = 128L, res = 10)
  m <- cog_info(ab[1]); gt <- m$geotransform
  te <- c(gt[1], gt[4] - 128 * 10, gt[1] + 256 * 10, gt[4])   # spans both tiles
  tr <- c(10, 10)
  d1 <- file.path(dir, "km.tif"); d2 <- file.path(dir, "gm.tif")
  ck_warp(ab, d1, t_srs = m$crs, te = te, tr = tr, r = "near",
          cl_arg = c("-et", "0"))
  gdal_ref_warp(ab, d2, m$crs, te, tr, r = "near")

  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("ck_warp aligns to the tr grid by default (-tap); tap=FALSE opts out", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")   # not tr-aligned
  tr <- c(15, 15)

  # default: tap on -> bit-identical to gdalraster::warp WITH -tap (and cptkirk
  # must fetch enough source to cover the outward-snapped grid).
  d1 <- file.path(dir, "tap.tif")
  ck_warp(f, d1, t_srs = "EPSG:3857", te = te, tr = tr, r = "near",
          cl_arg = c("-et", "0"))
  ref_tap <- gdal_ref_warp(f, file.path(dir, "ref_tap.tif"), "EPSG:3857", te, tr,
                           r = "near", tap = TRUE)
  expect_equal(raster_dim(d1), raster_dim(ref_tap))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(ref_tap, b))

  # tap = FALSE: raw grid -> bit-identical to gdalraster::warp WITHOUT -tap.
  d2 <- file.path(dir, "raw.tif")
  ck_warp(f, d2, t_srs = "EPSG:3857", te = te, tr = tr, r = "near", tap = FALSE,
          cl_arg = c("-et", "0"))
  ref_raw <- gdal_ref_warp(f, file.path(dir, "ref_raw.tif"), "EPSG:3857", te, tr,
                           r = "near", tap = FALSE)
  expect_equal(raster_dim(d2), raster_dim(ref_raw))
  for (b in 1:3) expect_equal(read_band(d2, b), read_band(ref_raw, b))

  # tap actually changed the grid (te was not tr-aligned).
  expect_false(isTRUE(all.equal(cog_info(d1)$geotransform,
                                cog_info(d2)$geotransform)))
})

test_that("-ts (output size) matches gdalraster::warp", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  sx <- gt[1] + c(40, 150) * gt[2]
  sy <- gt[4] + c(40, 130) * gt[6]
  te <- gdalraster::transform_bounds(c(min(sx), min(sy), max(sx), max(sy)),
                                     m$crs, "EPSG:3857")
  d1 <- file.path(dir, "k.tif"); d2 <- file.path(dir, "g.tif")
  ck_warp(f, d1, t_srs = "EPSG:3857", te = te, ts = c(96L, 80L), r = "near",
          cl_arg = c("-et", "0"))
  gdalraster::warp(
    f, d2, t_srs = "EPSG:3857",
    cl_arg = c("-te", formatC(te, format = "f", digits = 10), "-ts", "96", "80",
               "-r", "near", "-et", "0",
               "-wo", "SKIP_NOSOURCE=YES", "-wo", "INIT_DEST=NO_DATA", "-overwrite"),
    quiet = TRUE
  )
  expect_equal(raster_dim(d1)[1:2], c(96L, 80L))
  expect_equal(raster_dim(d1), raster_dim(d2))
  for (b in 1:3) expect_equal(read_band(d1, b), read_band(d2, b))
})

test_that("tr takes precedence over ts (with a warning)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 160 * gt[6], gt[1] + 192 * gt[2], gt[4])
  d <- file.path(dir, "o.tif")
  # both supplied -> warn, use tr (10 m over a 1920 m span -> 192 px), ignore ts
  expect_warning(
    ck_warp(f, d, t_srs = m$crs, te = te, tr = c(10, 10), ts = c(5, 5),
            r = "near", tap = FALSE),
    "ignoring"
  )
  expect_equal(raster_dim(d)[1:2], c(192L, 160L))
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
  ck_warp(cog, d, t_srs = m$crs, te = te, tr = c(40, 40), r = "near")
  expect_equal(raster_dim(d)[1:2], c(128L, 128L))
})
