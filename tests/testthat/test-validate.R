# Always-on argument validation (independent of the sanitiser).

test_that("ck_warp validates resampling with arg_match", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  # typo -> arg_match lists the valid set
  expect_error(ck_warp(f, o, t_srs = "EPSG:3857", te = c(0, 0, 1, 1),
                       tr = c(1, 1), r = "nearist"),
               'must be one of|did you mean')
  # a method not in the list is rejected by arg_match
  expect_error(ck_warp(f, o, r = "supersample"), "must be one of")
})

test_that("ck_warp validates geometry vectors", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  expect_error(ck_warp(f, o, te = c(1, 2, 3)), "xmin")
  expect_error(ck_warp(f, o, tr = c(-1, 10), te = c(0, 0, 1, 1)), "positive")
  expect_error(ck_warp(f, o, ts = c(10, 0), te = c(0, 0, 1, 1)), "positive")
  expect_error(ck_warp(f, o, tr = "10"), "c\\(xres, yres\\)")
})

test_that("ck_warp validates bands, knobs and speed args", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  expect_error(ck_warp(f, o, bands = c(1.5, 2)), "band indices")
  expect_error(ck_warp(f, o, bands = c(0L, 1L)), "band indices")
  expect_error(ck_warp(f, o, io_concurrency = 0), "io_concurrency")
  expect_error(ck_warp(f, o, io_concurrency = -4), "io_concurrency")
  expect_error(ck_warp(f, o, margin = -1), "margin")
  expect_error(ck_warp(f, o, sanitise = "yes"), "sanitise")
  expect_error(ck_warp(f, o, warp_memory = -5), "warp_memory")
  expect_error(ck_warp(f, o, cache_max = "lots"), "cache_max")
  expect_error(ck_warp(f, o, overview = 0), "overview")
})

test_that("valid resampling and knob values pass validation", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  d <- file.path(dir, "ok.tif")
  expect_no_error(ck_warp(f, d, r = "bilinear"))           # copy of all bands, bilinear unused on copy path but valid
  expect_no_error(ck_warp(f, file.path(dir, "b.tif"), warp_memory = "auto", cache_max = 128))
})

test_that("warp_remote validates its (lighter) argument set", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  expect_error(warp_remote(f, dst = 42), "single output path")
  expect_error(warp_remote(f, o, quiet = "yes"), "quiet")
  expect_error(warp_remote(f, o, io_concurrency = 0), "io_concurrency")
  expect_error(warp_remote(f, o, sanitise = NA), "sanitise")
  expect_error(warp_remote(123, o), "path/URL")
})
