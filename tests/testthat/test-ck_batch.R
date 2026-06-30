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

test_that("ck_batch accepts a per-band list r matching src", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)                    # 2 groups x 2 bands
  m <- cog_info(src[[1]][1]); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])
  out <- ck_batch(src, dst = file.path(dir, "o.tif"), stack = TRUE,
                  te = te, tr = c(40, 40),
                  r = list(c("near", "bilinear"), c("average", "near")))
  expect_named(out, c("t1", "t2"))
  expect_equal(raster_dim(out[["t1"]])[3], 2L)
})

test_that("ck_batch rejects a mis-shaped list r", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)
  expect_error(
    ck_batch(src, r = list(c("near"), c("near", "near"))),
    "match the structure"
  )
})

test_that("ck_batch sanitise = FALSE (trusted single-grid) matches the default", {
  dir <- withr::local_tempdir()
  src <- make_groups(dir)                     # uniform grid -> trust path valid
  m <- cog_info(src[[1]][1]); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])

  def  <- ck_batch(src, dst = file.path(dir, "d.tif"), stack = FALSE, te = te,
                   sanitise = TRUE)
  fast <- ck_batch(src, dst = file.path(dir, "f.tif"), stack = FALSE, te = te,
                   sanitise = FALSE)
  expect_equal(lengths(fast), lengths(def))
  for (g in seq_along(src)) {
    for (b in seq_along(src[[g]])) {
      expect_equal(read_band(fast[[g]][b]), read_band(def[[g]][b]))
    }
  }
})

test_that("ck_batch returns NA for a source that does not overlap the AOI", {
  dir <- withr::local_tempdir()
  near <- const_tif_b(file.path(dir, "near.tif"), 5)
  far  <- const_tif_b(file.path(dir, "far.tif"), 9,
                      gt = c(9e6, 10, 0, 9e6, 0, -10))   # disjoint extent
  m <- cog_info(near); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])
  out <- ck_batch(list(a = near, b = far), dst = file.path(dir, "o.tif"),
                  stack = FALSE, t_srs = m$crs, te = te, tr = c(10, 10))
  expect_false(is.na(out$a[1]))
  expect_true(is.na(out$b[1]))
})

test_that("ck_batch stack=TRUE keeps band order when a middle band is missing", {
  dir <- withr::local_tempdir()
  b1 <- const_tif_b(file.path(dir, "b1.tif"), 11)
  b2 <- const_tif_b(file.path(dir, "b2.tif"), 22,
                    gt = c(9e6, 10, 0, 9e6, 0, -10))      # off-AOI -> dropped
  b3 <- const_tif_b(file.path(dir, "b3.tif"), 33)
  m <- cog_info(b1); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])
  out <- ck_batch(list(t1 = c(b1, b2, b3)), dst = file.path(dir, "s.tif"),
                  stack = TRUE, t_srs = m$crs, te = te, tr = c(10, 10))
  expect_equal(raster_dim(out[["t1"]])[3], 2L)            # middle band dropped
  expect_true(all(read_band(out[["t1"]], 1) == 11))       # b1 stays first
  expect_true(all(read_band(out[["t1"]], 2) == 33))       # b3 stays second
})

test_that("ck_batch sanitise = FALSE aborts on mixed grids", {
  dir <- withr::local_tempdir()
  g1 <- const_tif_b(file.path(dir, "g1.tif"), 1)
  g2 <- const_tif_b(file.path(dir, "g2.tif"), 2,
                    gt = c(6e5, 10, 0, 4002560, 0, -10))  # shifted origin
  m <- cog_info(g1); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])
  expect_error(
    ck_batch(list(a = g1, b = g2), dst = file.path(dir, "o.tif"),
             t_srs = m$crs, te = te, sanitise = FALSE),
    "share one grid"
  )
})

test_that("ck_batch rejects a dst template that collides on duplicate names", {
  dir <- withr::local_tempdir()
  p <- const_tif_b(file.path(dir, "p.tif"), 7)
  expect_error(
    ck_batch(list(a = p, a = p), dst = file.path(dir, "out.tif"), stack = TRUE),
    "duplicate output paths"
  )
})

test_that(".plan_sources gives each same-grid source its own nodata", {
  dir <- withr::local_tempdir()
  mk <- function(p, nd) {
    ds <- gdalraster::create("GTiff", p, 48L, 48L, 1L, "Int16",
      options = c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"), return_obj = TRUE)
    on.exit(ds$close())
    ds$setGeoTransform(c(5e5, 10, 0, 4002560, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32631"))
    ds$setNoDataValue(1L, nd)
    ds$write(band = 1L, xoff = 0L, yoff = 0L, xsize = 48L, ysize = 48L,
             rasterData = rep(7L, 48L * 48L))
    p
  }
  a <- mk(file.path(dir, "a.tif"), 0)
  b <- mk(file.path(dir, "b.tif"), -9999)               # same grid, diff nodata
  ma <- cog_meta(cog_open(a, character(0), character(0)))
  mb <- cog_meta(cog_open(b, character(0), character(0)))
  gt <- ma$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])
  plans <- .plan_sources(c(a, b), list(ma, mb), t_srs = NULL, te = te,
    te_srs = NULL, tr = NULL, ts = NULL, bands = NULL, overview = NULL,
    margin = 8L, max_bytes = .default_max_bytes())
  expect_equal(plans[[1]]$nodata, 0)                     # not the first's value
  expect_equal(plans[[2]]$nodata, -9999)
})

test_that("ck_batch auto-uses ambient daemons and matches the serial path", {
  skip_on_cran()
  skip_if_not_installed("mirai")
  skip_if_not_installed("mori")
  # The daemons are separate processes that load cptkirk via the package's own
  # everywhere(library(cptkirk)) call -- which needs cptkirk INSTALLED. Under
  # devtools::load_all there is no installed build to hand them, so skip there
  # (DEVTOOLS_LOAD is set to the package name during load_all). Runs in R CMD
  # check / CI, where the package under test is installed.
  if (identical(Sys.getenv("DEVTOOLS_LOAD"), "cptkirk")) {
    skip("daemons need an installed cptkirk (skipped under devtools::load_all)")
  }
  dir <- withr::local_tempdir()
  src <- make_groups(dir)
  m <- cog_info(src[[1]][1]); gt <- m$geotransform
  te <- c(gt[1], gt[4] + 32 * gt[6], gt[1] + 32 * gt[2], gt[4])

  # No daemons -> serial (auto-detect off).
  ser <- ck_batch(src, dst = file.path(dir, "ser.tif"), stack = FALSE, te = te)

  mirai::daemons(2)
  withr::defer(mirai::daemons(0))

  # Daemons running -> parallel path is auto-selected; output must match serial.
  par <- ck_batch(src, dst = file.path(dir, "par.tif"), stack = FALSE, te = te)
  expect_equal(lengths(par), lengths(ser))
  for (g in seq_along(src)) {
    for (b in seq_along(src[[g]])) {
      expect_equal(read_band(par[[g]][b]), read_band(ser[[g]][b]))
    }
  }
})

