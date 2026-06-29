# ck_stack / ck_stack_read: pooled multi-source fetch, stacked as separate
# bands. Offline -- cptkirk reads local tiled fixtures through the same engine.

# A tiled, constant-valued source on a fixed grid (so band identity is checkable
# by value, and sources stack aligned).
const_tif <- function(path, val, nx = 64L, ny = 64L, nbands = 1L,
                      gt = c(5e5, 10, 0, 4002560, 0, -10)) {
  ds <- gdalraster::create("GTiff", path, nx, ny, nbands, "Int16",
    options = c("TILED=YES", "BLOCKXSIZE=32", "BLOCKYSIZE=32"),
    return_obj = TRUE)
  on.exit(ds$close(), add = TRUE)
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32631"))
  for (b in seq_len(nbands)) {
    ds$write(band = b, xoff = 0L, yoff = 0L, xsize = nx, ysize = ny,
             rasterData = rep(as.integer(val * 10L + b), nx * ny))
  }
  path
}

test_that("ck_stack stacks N single-band sources into an N-band raster, in order", {
  dir <- withr::local_tempdir()
  srcs <- vapply(1:3, function(i)
    const_tif(file.path(dir, sprintf("s%d.tif", i)), val = i), character(1))
  dst <- file.path(dir, "stack.tif")

  expect_identical(ck_stack(srcs, dst), dst)
  expect_equal(raster_dim(dst)[3], 3L)
  # band i carries source i's value (i*10 + 1) -> ordering preserved
  for (i in 1:3) expect_true(all(read_band(dst, i) == i * 10L + 1L))
  # default band descriptions are the source file names, in order
  ds <- methods::new(gdalraster::GDALRaster, dst)
  on.exit(ds$close(), add = TRUE)
  expect_equal(vapply(1:3, function(b) ds$getDescription(b), ""),
               c("s1", "s2", "s3"))
})

test_that("multi-band sources flatten with _b suffixes in band names", {
  dir <- withr::local_tempdir()
  srcs <- c(const_tif(file.path(dir, "a.tif"), 1, nbands = 1L),
            const_tif(file.path(dir, "b.tif"), 2, nbands = 2L))
  dst <- file.path(dir, "stack.tif")
  ck_stack(srcs, dst)

  expect_equal(raster_dim(dst)[3], 3L) # 1 + 2 bands
  ds <- methods::new(gdalraster::GDALRaster, dst)
  on.exit(ds$close(), add = TRUE)
  expect_equal(vapply(1:3, function(b) ds$getDescription(b), ""),
               c("a", "b_b1", "b_b2"))
})

test_that("band_names overrides descriptions; wrong length errors", {
  dir <- withr::local_tempdir()
  srcs <- vapply(1:2, function(i)
    const_tif(file.path(dir, sprintf("s%d.tif", i)), val = i), character(1))
  dst <- file.path(dir, "stack.tif")

  ck_stack(srcs, dst, band_names = c("red", "green"))
  ds <- methods::new(gdalraster::GDALRaster, dst)
  on.exit(ds$close(), add = TRUE)
  expect_equal(vapply(1:2, function(b) ds$getDescription(b), ""),
               c("red", "green"))

  expect_error(
    ck_stack(srcs, file.path(dir, "bad.tif"), band_names = c("only-one")),
    "band_names"
  )
})

test_that("ck_stack_read returns a stacked [ny, nx, nband] array", {
  dir <- withr::local_tempdir()
  srcs <- vapply(1:3, function(i)
    const_tif(file.path(dir, sprintf("s%d.tif", i)), val = i), character(1))

  a <- ck_stack_read(srcs)
  expect_equal(dim(a), c(64L, 64L, 3L))    # ny, nx, nband
  for (i in 1:3) expect_true(all(a[, , i] == i * 10L + 1L))
  expect_length(attr(a, "geotransform"), 6L)
})

test_that("ck_stack warps each source to a common grid when t_srs is given", {
  dir <- withr::local_tempdir()
  srcs <- vapply(1:2, function(i)
    const_tif(file.path(dir, sprintf("s%d.tif", i)), val = i), character(1))
  dst <- file.path(dir, "stack3857.tif")

  m <- cog_info(srcs[1]); gt <- m$geotransform
  te <- gdalraster::transform_bounds(
    c(gt[1], gt[4] + 64 * gt[6], gt[1] + 64 * gt[2], gt[4]), m$crs, "EPSG:3857")
  ck_stack(srcs, dst, t_srs = "EPSG:3857", te = te, tr = c(15, 15), r = "near")

  expect_equal(raster_dim(dst)[3], 2L)     # band count preserved through warp
  expect_match(cog_info(dst)$crs, "3857")  # reprojected to the requested CRS
})
