test_that("required arguments are checked", {
  dir <- withr::local_tempdir()
  expect_error(warp_remote(dst = file.path(dir, "o.tif")))   # missing src
  expect_error(ck_warp(dst = file.path(dir, "o.tif")))       # missing src
  expect_error(cog_source())                                 # missing src
  expect_error(cog_info())                                   # missing src
})

test_that("argument types are validated", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  expect_error(cog_source(123), "single path or URL")
  expect_error(warp_remote(f, dst = 42), "single output path")
  expect_error(ck_warp(f, dst = 42), "single output path")
  expect_error(ck_warp(f, file.path(dir, "o.tif"), te = c(1, 2, 3)), "xmin")
})

test_that("non-overlapping extent and the memory guard error clearly", {
  dir <- withr::local_tempdir()
  f <- fx_north(dir)
  o <- file.path(dir, "o.tif")
  # extent nowhere near the source footprint
  expect_error(
    ck_warp(f, o, t_srs = "EPSG:4326", te = c(0, 0, 1, 1), tr = c(0.01, 0.01)),
    "overlap"
  )
  # a tiny byte budget trips the guard
  expect_error(ck_warp(f, o, max_bytes = 10), "materialise")
})
