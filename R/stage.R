# Stage a native-dtype window (from cog_fetch_window_raw) as an in-memory GDAL
# source: write the raw bytes to /vsimem and describe them with a raw VRT so
# GDAL warps reading native bytes in chunks. Keeps peak memory at the source
# dtype footprint (e.g. 1 byte/px for Int8) rather than the f64 of a MEM band.
#
# `w` is the list returned by cog_fetch_window_raw(); `gt` the window's
# geotransform; `wkt` the source CRS as WKT; `nodata` optional.
# Returns list(vrt = "/vsimem/<id>.vrt", files = c(bin, vrt)) for cleanup.
.stage_vsimem_vrt <- function(w, gt, wkt, nodata = NULL) {
  id <- basename(tempfile("cptkirk_"))
  bin <- sprintf("/vsimem/%s.bin", id)
  vrt <- sprintf("/vsimem/%s.vrt", id)
  # Reference the raw file relative to the VRT (both siblings in /vsimem) so it
  # passes GDAL's default VRTRawRasterBand source restriction.
  bin_rel <- sprintf("%s.bin", id)

  vf <- methods::new(gdalraster::VSIFile, bin, "w+")
  vf$write(w$bytes)
  vf$close()

  band_bytes <- as.numeric(w$xsize) * as.numeric(w$ysize) * w$bytes_per_sample
  line_off <- w$xsize * w$bytes_per_sample
  nd <- if (!is.null(nodata)) {
    sprintf("    <NoDataValue>%s</NoDataValue>\n", format(nodata, scientific = FALSE))
  } else {
    ""
  }
  bands_xml <- vapply(seq_len(w$n_bands), function(b) {
    sprintf(paste0(
      '  <VRTRasterBand dataType="%s" band="%d" subClass="VRTRawRasterBand">\n',
      '    <SourceFilename relativeToVRT="1">%s</SourceFilename>\n',
      "    <ImageOffset>%.0f</ImageOffset>\n",
      "    <PixelOffset>%d</PixelOffset>\n",
      "    <LineOffset>%d</LineOffset>\n",
      "    <ByteOrder>%s</ByteOrder>\n%s",
      "  </VRTRasterBand>\n"
    ),
    w$dtype, b, bin_rel, (b - 1) * band_bytes, w$bytes_per_sample,
    line_off, w$byte_order, nd)
  }, character(1))

  xml <- sprintf(paste0(
    '<VRTDataset rasterXSize="%d" rasterYSize="%d">\n',
    "  <SRS>%s</SRS>\n",
    "  <GeoTransform>%s</GeoTransform>\n%s",
    "</VRTDataset>\n"
  ),
  w$xsize, w$ysize, .xml_escape(wkt),
  paste(formatC(gt, format = "f", digits = 12), collapse = ", "),
  paste(bands_xml, collapse = ""))

  vf2 <- methods::new(gdalraster::VSIFile, vrt, "w+")
  vf2$write(charToRaw(xml))
  vf2$close()

  list(vrt = vrt, files = c(bin, vrt))
}

# GDAL data-type name -> bytes per sample.
.dtype_bytes <- function(dt) {
  switch(dt,
    Byte = 1L, Int8 = 1L,
    UInt16 = 2L, Int16 = 2L,
    UInt32 = 4L, Int32 = 4L, Float32 = 4L,
    UInt64 = 8L, Int64 = 8L, Float64 = 8L,
    CInt16 = 4L, CInt32 = 8L, CFloat32 = 8L, CFloat64 = 16L,
    8L
  )
}

.xml_escape <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE)
  s <- gsub("<", "&lt;", s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}
