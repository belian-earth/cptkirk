# ck_batch_to_buffer() streams grouped sources through one pool into raw BSQ
# buffers, one clipped per-tile window each, snapped to the shared te/ts lattice.
# Each descriptor's pixels must reproduce ck_read() of the same clipped grid
# (same warp engine); ck_read maps nodata to NA, the buffer carries the raw
# sentinel, so they are reconciled before comparing.

# Descriptor's extent c(xmin, ymin, xmax, ymax) from its geotransform.
desc_te <- function(d) {
  g <- d$geotransform
  c(g[1], g[4] + d$ny * g[6], g[1] + d$nx * g[2], g[4])
}

buf_plane <- function(d, b = 1L, size = 2L, signed = TRUE) {
  npx <- d$nx * d$ny
  seg <- d$data[((b - 1) * npx * size + 1):(b * npx * size)]
  matrix(readBin(seg, "integer", size = size, n = npx, signed = signed),
         nrow = d$ny, ncol = d$nx, byrow = TRUE)
}

# ck_read the same source into the descriptor's exact grid; fold NA -> sentinel.
ref_plane <- function(src, d, b = 1L, t_srs = "EPSG:32631") {
  a <- ck_read(src, t_srs = t_srs, te = desc_te(d), ts = c(d$nx, d$ny),
               bands = b, r = "near")
  m <- matrix(as.integer(a), nrow = d$ny, ncol = d$nx)
  m[is.na(m)] <- as.integer(d$nodata)
  m
}

is_desc <- function(x) is.list(x) && !is.null(x$data) && !is.null(x$geotransform)

test_that("stack=FALSE returns per-tile clipped descriptors matching ck_read", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)                 # two adjacent aligned Int16 tiles a,b
  # AOI spanning both tiles; lattice = 10 m.
  te <- c(5e5, 4002560 - 1280, 5e5 + 2560, 4002560)
  ts <- c(256L, 128L)

  res <- ck_batch_to_buffer(list(pair = srcs), stack = FALSE,
                            t_srs = "EPSG:32631", te = te, ts = ts, margin = 0L)

  expect_named(res, "pair")
  expect_length(res$pair, 2L)
  for (i in 1:2) {
    d <- res$pair[[i]]
    expect_true(is_desc(d))
    expect_equal(d$dtype, "Int16")
    expect_equal(d$nbands, 3L)
    # aligned to the 10 m lattice, origin on te
    expect_equal(unname(d$geotransform[2]), 10)
    expect_equal(unname(-d$geotransform[6]), 10)
    expect_equal((d$geotransform[1] - te[1]) %% 10, 0)
    for (b in 1:3) expect_identical(buf_plane(d, b), ref_plane(srcs[i], d, b))
  }
  # the two clipped tiles cover disjoint, adjacent lattice columns (margin 0)
  g1 <- res$pair[[1]]$geotransform[1]; g2 <- res$pair[[2]]$geotransform[1]
  expect_false(g1 == g2)
})

test_that("clipped buffers are smaller than the full AOI grid", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)
  te <- c(5e5, 4002560 - 1280, 5e5 + 2560, 4002560)
  res <- ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:32631",
                            te = te, ts = c(256L, 128L), margin = 0L)
  # each tile spans ~128 of the 256 AOI columns, not the whole grid
  expect_lt(res$g[[1]]$nx, 256L)
  expect_lt(res$g[[2]]$nx, 256L)
})

test_that("reprojection matches ck_read on the clipped grid", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)
  te <- c(5e5, 4002560 - 1280, 5e5 + 2560, 4002560)
  teB <- gdalraster::transform_bounds(te, "EPSG:32631", "EPSG:3857")
  res <- ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:3857",
                            te = teB, ts = c(256L, 128L), r = "near", margin = 4L)
  for (i in 1:2) {
    d <- res$g[[i]]
    expect_true(gdalraster::srs_is_same(d$crs, "EPSG:3857"))
    expect_identical(buf_plane(d, 1L), ref_plane(srcs[i], d, 1L, t_srs = "EPSG:3857"))
  }
})

test_that("non-overlapping source yields an NA leaf", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)                 # a at x[5e5,5e5+1280], b at [5e5+1280, ...]
  # AOI over tile a only; tile b does not overlap.
  te <- c(5e5, 4002560 - 1280, 5e5 + 1000, 4002560)
  res <- ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:32631",
                            te = te, ts = c(100L, 128L), margin = 0L)
  expect_true(is_desc(res$g[[1]]))
  expect_true(identical(res$g[[2]], NA) || is.na(res$g[[2]]))
})

test_that("stack=TRUE concatenates a group's sources BSQ into one descriptor", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)                 # two 3-band tiles; overlapping AOI on tile a
  te <- c(5e5 + 100, 4002560 - 600, 5e5 + 500, 4002560 - 200)
  res <- ck_batch_to_buffer(list(g = srcs[1]), stack = TRUE, t_srs = "EPSG:32631",
                            te = te, ts = c(40L, 40L), margin = 0L)
  d <- res$g
  expect_true(is_desc(d))
  expect_equal(d$nbands, 3L)           # one 3-band source -> 3 stacked bands
  for (b in 1:3) expect_identical(buf_plane(d, b), ref_plane(srcs[1], d, b))
})

test_that("ambient daemons produce the same descriptors as the serial path", {
  skip_on_cran()
  skip_if_not_installed("mirai")
  skip_if_not_installed("mori")
  # Daemons load cptkirk via everywhere(library(cptkirk)); the in-memory
  # devtools::load_all build is invisible to them, so require an installed pkg.
  if (!any(file.exists(file.path(.libPaths(), "cptkirk", "DESCRIPTION")))) {
    skip("daemons require an installed cptkirk")
  }
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)
  te <- c(5e5, 4002560 - 1280, 5e5 + 2560, 4002560); ts <- c(256L, 128L)

  ser <- ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:32631",
                            te = te, ts = ts, margin = 0L)
  mirai::daemons(2)
  withr::defer(mirai::daemons(0))
  par <- ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:32631",
                            te = te, ts = ts, margin = 0L)
  expect_identical(ser, par)
})

test_that("running-sum memory ceiling aborts", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)
  te <- c(5e5, 4002560 - 1280, 5e5 + 2560, 4002560)
  expect_error(
    ck_batch_to_buffer(list(g = srcs), stack = FALSE, t_srs = "EPSG:32631",
                       te = te, ts = c(256L, 128L), max_bytes = 1000),
    "max_bytes"
  )
})

test_that("a pinned target grid (te + ts/tr) is required", {
  dir <- withr::local_tempdir()
  srcs <- fx_pair(dir)
  expect_error(ck_batch_to_buffer(list(g = srcs), t_srs = "EPSG:32631"),
               "pinned target grid")
  expect_error(ck_batch_to_buffer(list(g = srcs), t_srs = "EPSG:32631",
                                   te = c(5e5, 4e6, 5e5 + 100, 4e6 + 100),
                                   ts = c(10L, 10L), tr = c(10, 10)),
               "either")
})
