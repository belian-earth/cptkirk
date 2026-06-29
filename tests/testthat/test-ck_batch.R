# ck_batch: one pooled fetch over a list of groups, structure-preserving output.
# Offline via local tiled fixtures.

const_tif_b <- function(path, val, nx = 48L, ny = 48L, nbands = 1L,
                        gt = c(5e5, 10, 0, 4002560, 0, -10)) {
  ds <- gdalraster::create("GTiff", path, nx, ny, nbands, "Int16",
    options = c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"),
    return_obj = TRUE)
  on.exit(ds$close(), add = TRUE)
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32631"))
  for (b in seq_len(nbands)) {
    ds$write(band = b, xoff = 0L, yoff = 0L, xsize = nx, ysize = ny,
             rasterData = rep(as.integer(val), nx * ny))
  }
  path
}

# Two groups (acquisitions) of two bands each, distinct values, shared grid.
make_groups <- function(dir) {
  list(
    t1 = c(B1 = const_tif_b(file.path(dir, "t1b1.tif"), 11),
           B2 = const_tif_b(file.path(dir, "t1b2.tif"), 12)),
    t2 = c(B1 = const_tif_b(file.path(dir, "t2b1.tif"), 21),
           B2 = const_tif_b(file.path(dir, "t2b2.tif"), 22))
  )
}

test_that("ck_batch stack=FALSE returns one file per band, mirroring input", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)
  out <- ck_batch(src, dst = file.path(dir, "out.tif"), stack = FALSE)

  expect_type(out, "list")
  expect_named(out, c("t1", "t2"))
  expect_equal(lengths(out), c(t1 = 2L, t2 = 2L))
  # template names carry group + band identity
  expect_match(out$t1[1], "out_t1_B1")
  expect_match(out$t2[2], "out_t2_B2")
  # each is single-band and carries its source's value
  expect_equal(raster_dim(out$t1[1])[3], 1L)
  expect_true(all(read_band(out$t1[1]) == 11))
  expect_true(all(read_band(out$t2[2]) == 22))
})

test_that("ck_batch stack=TRUE returns one stacked file per group", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)
  out <- ck_batch(src, dst = file.path(dir, "stk.tif"), stack = TRUE)

  expect_type(out, "character")
  expect_named(out, c("t1", "t2"))
  expect_match(out[["t1"]], "stk_t1")
  expect_equal(raster_dim(out[["t1"]])[3], 2L)        # 2 bands stacked
  expect_true(all(read_band(out[["t1"]], 1) == 11))
  expect_true(all(read_band(out[["t1"]], 2) == 12))
})

test_that("ck_batch accepts an explicit nested dst (stack=FALSE)", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)
  dst <- list(c(file.path(dir, "a1.tif"), file.path(dir, "a2.tif")),
              c(file.path(dir, "b1.tif"), file.path(dir, "b2.tif")))
  out <- ck_batch(src, dst = dst, stack = FALSE)
  expect_equal(unlist(out, use.names = FALSE), unlist(dst))
  expect_true(file.exists(out[[2]][1]))
})

test_that("ck_batch errors on a malformed src", {
  expect_error(ck_batch(c("a.tif", "b.tif")), "list of character")
  expect_error(ck_batch(list(1:3)), "list of character")
})
