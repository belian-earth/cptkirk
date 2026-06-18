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

test_that("cog_info on several sources returns a cog_info_list", {
  dir <- withr::local_tempdir()
  ab <- fx_pair(dir)                       # two adjacent tiles, same CRS
  info <- cog_info(ab)
  expect_s3_class(info, "cog_info_list")
  expect_length(info, 2L)
  expect_s3_class(info[[1]], "cog_info")
  expect_no_error(print(info))             # combined summary prints
})

test_that("a single source is unchanged (object, not list)", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  info <- cog_info(f)
  expect_s3_class(info, "cog_info")
  expect_false(inherits(info, "cog_info_list"))
  expect_type(info$geotransform, "double")   # list access still works
})

test_that("as.data.frame gives one tidy row per source", {
  dir <- withr::local_tempdir()
  ab <- fx_pair(dir)
  cols <- c("src", "width", "height", "n_bands", "dtype", "nodata", "crs",
            "res_x", "res_y", "xmin", "ymin", "xmax", "ymax",
            "n_levels", "tile_width", "tile_height")

  df <- as.data.frame(cog_info(ab))
  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 2L)
  expect_named(df, cols)
  expect_equal(df$src, ab)

  one <- as.data.frame(cog_info(ab[1]))
  expect_equal(nrow(one), 1L)
  expect_named(one, cols)

  expect_equal(cog_info(ab, as.data.frame = TRUE), df)   # arg matches the method
})

test_that("the data frame row matches the source geometry", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  m <- cog_info(f)
  row <- as.data.frame(m)
  expect_equal(row$width, m$width)
  expect_equal(row$res_x, abs(m$geotransform[2]))
  expect_equal(c(row$xmin, row$ymin, row$xmax, row$ymax),
               .full_src_bbox(m$geotransform, m$width, m$height))
})
