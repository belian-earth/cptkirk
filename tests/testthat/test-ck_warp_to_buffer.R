# ck_warp_to_buffer() fills a raw native-dtype buffer on a fixed te/ts grid,
# band-sequential (BSQ), row-major, row 0 = north -- the layout garry consumes.
# It shares ck_warp()'s engine, so covered pixels are bit-identical to ck_read()
# of the same grid (ck_read maps nodata to NA; the buffer carries the raw
# sentinel, so uncovered pixels are reconciled before comparing).

# Reconstruct band `b`'s ny x nx plane from a BSQ buffer of `size`-byte samples.
buf_plane <- function(res, b, size = 2L, signed = TRUE) {
  npx <- res$nx * res$ny
  seg <- res$data[((b - 1) * npx * size + 1):(b * npx * size)]
  matrix(readBin(seg, "integer", size = size, n = npx, signed = signed),
         nrow = res$ny, ncol = res$nx, byrow = TRUE)
}

# ck_read plane with nodata (NA) folded back to the buffer's sentinel.
ref_plane <- function(arr, b, nodata) {
  m <- if (length(dim(arr)) == 3L) arr[, , b] else arr
  m <- matrix(as.integer(m), nrow = nrow(m), ncol = ncol(m))
  m[is.na(m)] <- as.integer(nodata)
  m
}

test_that("buffer is BSQ, native dtype, and matches ck_read on a same-CRS grid", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)                                   # Int16, EPSG:32631
  te <- c(5e5 + 200, 4002560 - 600, 5e5 + 600, 4002560 - 200)
  ts <- c(40L, 40L)

  res <- ck_warp_to_buffer(f, t_srs = "EPSG:32631", te = te, ts = ts, r = "near")

  expect_equal(res$dtype, "Int16")
  expect_equal(res$nbands, 3L)
  expect_equal(c(res$nx, res$ny), c(40L, 40L))
  expect_equal(length(res$data), 40L * 40L * 3L * 2L)  # 2 bytes/sample
  expect_equal(res$geotransform,
               c(te[1], (te[3] - te[1]) / 40, 0, te[4], 0, -(te[4] - te[2]) / 40))

  ref <- ck_read(f, t_srs = "EPSG:32631", te = te, ts = ts, r = "near")
  for (b in 1:3) {
    expect_identical(buf_plane(res, b), ref_plane(ref, b, res$nodata))
  }
})

test_that("reprojection and a band subset match ck_read", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  te <- c(5e5 + 200, 4002560 - 600, 5e5 + 600, 4002560 - 200)
  teB <- gdalraster::transform_bounds(te, "EPSG:32631", "EPSG:3857")
  ts <- c(50L, 50L)

  res <- ck_warp_to_buffer(f, t_srs = "EPSG:3857", te = teB, ts = ts,
                           bands = 1:2, r = "near")
  expect_equal(res$nbands, 2L)
  expect_equal(length(res$data), 50L * 50L * 2L * 2L)

  ref <- ck_read(f, t_srs = "EPSG:3857", te = teB, ts = ts, bands = 1:2, r = "near")
  for (b in 1:2) {
    expect_identical(buf_plane(res, b), ref_plane(ref, b, res$nodata))
  }
})

test_that("uncovered pixels come back as the fill sentinel", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)                                   # source nodata -9999
  # An extent whose right half lies beyond the source footprint.
  te <- c(5e5 + 1720, 4002560 - 400, 5e5 + 2120, 4002560)
  res <- ck_warp_to_buffer(f, t_srs = "EPSG:32631", te = te, ts = c(40L, 40L),
                           bands = 1L, fill = -9999)
  expect_equal(res$nodata, -9999)
  plane <- buf_plane(res, 1L)
  expect_true(any(plane == -9999L))                    # some uncovered pixels
  expect_true(any(plane != -9999L))                    # but not all
})

test_that("fill defaults to the source nodata", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  te <- c(5e5 + 1720, 4002560 - 400, 5e5 + 2120, 4002560)
  res <- ck_warp_to_buffer(f, t_srs = "EPSG:32631", te = te, ts = c(32L, 32L),
                           bands = 1L)
  expect_equal(res$nodata, -9999)                      # inherited from the source
})

test_that("dtype override converts the output samples", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  te <- c(5e5 + 200, 4002560 - 600, 5e5 + 600, 4002560 - 200)
  ts <- c(40L, 40L)

  res <- ck_warp_to_buffer(f, t_srs = "EPSG:32631", te = te, ts = ts,
                           bands = 1L, dtype = "Float32")
  expect_equal(res$dtype, "Float32")
  expect_equal(length(res$data), 40L * 40L * 4L)       # 4 bytes/sample

  ref <- ck_read(f, t_srs = "EPSG:32631", te = te, ts = ts, bands = 1L, r = "near")
  got <- matrix(readBin(res$data, "double", size = 4L, n = 1600L),
                nrow = 40L, ncol = 40L, byrow = TRUE)
  refm <- ref; refm[is.na(refm)] <- res$nodata
  expect_equal(got, matrix(refm, 40L, 40L), tolerance = 1e-4)
})

test_that("te and ts are required", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  expect_error(ck_warp_to_buffer(f, t_srs = "EPSG:32631", ts = c(16L, 16L)))
  expect_error(ck_warp_to_buffer(f, t_srs = "EPSG:32631",
                                 te = c(5e5, 4e6, 5e5 + 100, 4e6 + 100)))
})
