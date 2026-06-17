# Scoped GDAL performance configuration for a single warp call.
#
# GDAL config options and the block cache are process-global. We set them for
# the duration of one call and restore the previous values on exit (via
# withr::defer bound to the caller's frame), so a fast warp doesn't leak state
# into the user's session.

# Apply GDAL config options + cache size for the caller's frame, restoring on
# exit. `opts` is a named list/character vector of GDAL config options;
# `cache_bytes` (optional) sets GDAL_CACHEMAX via the explicit byte API.
.local_gdal_speed <- function(opts = list(), cache_bytes = NULL,
                              .envir = parent.frame()) {
  opts <- opts[!vapply(opts, is.null, logical(1))]
  if (length(opts)) {
    keys <- names(opts)
    old <- stats::setNames(lapply(keys, gdalraster::get_config_option), keys)
    for (k in keys) gdalraster::set_config_option(k, as.character(opts[[k]]))
    withr::defer(
      for (k in keys) gdalraster::set_config_option(k, old[[k]]),
      envir = .envir
    )
  }
  if (!is.null(cache_bytes)) {
    old_cache <- gdalraster::get_cache_max("bytes")
    gdalraster::set_cache_max(cache_bytes)
    withr::defer(gdalraster::set_cache_max(old_cache), envir = .envir)
  }
  invisible()
}

# Total system RAM in bytes (Linux /proc/meminfo; falls back to 8 GB).
.sys_ram_bytes <- function() {
  ram <- tryCatch(
    if (file.exists("/proc/meminfo")) {
      line <- grep("^MemTotal", readLines("/proc/meminfo", n = 1L), value = TRUE)
      as.numeric(gsub("\\D", "", line)) * 1024
    } else {
      NA_real_
    },
    error = function(e) NA_real_
  )
  if (length(ram) != 1L || is.na(ram) || ram <= 0) 8e9 else ram
}

# Default warp memory (-wm) in MB: ~25% RAM, clamped to [256, 2048].
.default_warp_mem <- function() {
  max(256, min(2048, floor(.sys_ram_bytes() * 0.25 / 1e6)))
}

# Default GDAL block cache in bytes: ~25% RAM, clamped to [256 MB, 2 GB].
.default_cache_bytes <- function() {
  max(256e6, min(2e9, .sys_ram_bytes() * 0.25))
}

# Default ceiling (bytes) on the staged in-memory window: ~1/3 of system RAM.
# The window is native dtype; transient peak is ~2x this during the staging
# copy. Floored at 1 GB so the guard still fires on tiny machines.
.default_max_bytes <- function() {
  max(1e9, .sys_ram_bytes() / 3)
}
