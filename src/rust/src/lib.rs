use extendr_api::prelude::*;

mod band_fetch;
mod error;
mod meta;
mod runtime;
mod source;
mod window;

use error::KirkError;

fn to_r(e: KirkError) -> Error {
    Error::Other(e.to_string())
}

fn default_io_concurrency() -> usize {
    num_cpus::get().clamp(8, 16)
}

/// A handle to a remote GeoTIFF / COG.
///
/// Opens the source once (header + all IFDs over a remote-capable reader) and
/// is reused for `cog_meta()` and any number of `cog_fetch_window()` calls via
/// an R external pointer, so a warp pays the metadata round-trips once rather
/// than per call.
struct CogSource {
    open: window::OpenTiff,
}

/// Open a source (local path, http(s)://, s3://, gs://, az://). Returns an
/// external pointer reused by `cog_meta()` / `cog_fetch_window()`.
/// @noRd
#[extendr]
fn cog_open(src: &str) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let open = rt.block_on(window::open_tiff(src)).map_err(to_r)?;
    Ok(ExternalPtr::new(CogSource { open }).into())
}

/// Structural + georeferencing metadata for an open source.
/// @noRd
#[extendr]
fn cog_meta(h: ExternalPtr<CogSource>) -> extendr_api::Result<Robj> {
    build_meta(&h.open).map_err(to_r)
}

/// Fetch a pixel window of an overview level from an open source. `level` is
/// 1-based (1 = full resolution); `bands` is 1-based (empty = all). Returns a
/// list with `data` (band-sequential double vector), `xsize`, `ysize`,
/// `n_bands`.
/// @noRd
#[extendr]
#[allow(clippy::too_many_arguments)]
fn cog_fetch_window(
    h: ExternalPtr<CogSource>,
    level: i32,
    xoff: i32,
    yoff: i32,
    xsize: i32,
    ysize: i32,
    bands: Vec<i32>,
    fill: f64,
    io_concurrency: Nullable<i32>,
) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let io = match io_concurrency {
        Nullable::NotNull(v) if v > 0 => v as usize,
        _ => default_io_concurrency(),
    };
    let bands0: Vec<usize> = bands.iter().map(|&b| (b - 1).max(0) as usize).collect();
    rt.block_on(window::fetch_window(
        &h.open,
        (level - 1).max(0) as usize,
        xoff.max(0) as usize,
        yoff.max(0) as usize,
        xsize.max(0) as usize,
        ysize.max(0) as usize,
        &bands0,
        fill,
        io,
    ))
    .map(|w| {
        list!(
            data = w.data,
            xsize = w.xsize as i32,
            ysize = w.ysize as i32,
            n_bands = w.n_bands as i32
        )
        .into()
    })
    .map_err(to_r)
}

/// Fetch a pixel window as a NATIVE-dtype byte buffer (band-sequential,
/// native endianness) for staging a `/vsimem` raster. `level`/`bands` as in
/// `cog_fetch_window`. Returns a list with `bytes` (raw vector), `xsize`,
/// `ysize`, `n_bands`, `dtype` (GDAL type name), `bytes_per_sample`, and
/// `byte_order` ("LSB"/"MSB").
/// @noRd
#[extendr]
#[allow(clippy::too_many_arguments)]
fn cog_fetch_window_raw(
    h: ExternalPtr<CogSource>,
    level: i32,
    xoff: i32,
    yoff: i32,
    xsize: i32,
    ysize: i32,
    bands: Vec<i32>,
    fill: f64,
    io_concurrency: Nullable<i32>,
) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let io = match io_concurrency {
        Nullable::NotNull(v) if v > 0 => v as usize,
        _ => default_io_concurrency(),
    };
    let bands0: Vec<usize> = bands.iter().map(|&b| (b - 1).max(0) as usize).collect();
    rt.block_on(window::fetch_window_native(
        &h.open,
        (level - 1).max(0) as usize,
        xoff.max(0) as usize,
        yoff.max(0) as usize,
        xsize.max(0) as usize,
        ysize.max(0) as usize,
        &bands0,
        fill,
        io,
    ))
    .map(|w| {
        list!(
            bytes = Raw::from_bytes(&w.bytes),
            xsize = w.xsize as i32,
            ysize = w.ysize as i32,
            n_bands = w.n_bands as i32,
            dtype = w.dtype_name,
            bytes_per_sample = w.bps as i32,
            byte_order = window::native_byte_order()
        )
        .into()
    })
    .map_err(to_r)
}

/// Concurrently open several sources and return their metadata.
///
/// Opens all `srcs` in a single runtime pass (overlapping the metadata
/// round-trips) and returns a list with one `read_cog_meta`-style entry per
/// source, in order. Used to plan a multi-tile mosaic without paying the opens
/// sequentially.
/// @noRd
#[extendr]
fn cog_meta_many(srcs: Vec<String>) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let opens = rt
        .block_on(async {
            futures::future::try_join_all(srcs.iter().map(|s| window::open_tiff(s))).await
        })
        .map_err(to_r)?;
    let metas: Vec<Robj> = opens
        .iter()
        .map(build_meta)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(to_r)?;
    Ok(List::from_values(metas).into())
}

/// Concurrently fetch one native-dtype window from each of several sources.
///
/// `srcs` and the per-tile `level`/`xoff`/`yoff`/`xsize`/`ysize` vectors are
/// parallel (one entry per tile). `bands` (1-based, empty = all) and `fill`
/// are shared across tiles. All sources are opened and their windows fetched
/// within a single runtime, so the tiles' network reads overlap. Returns a
/// list with one element per tile, each as in `cog_fetch_window_raw`.
/// @noRd
#[extendr]
#[allow(clippy::too_many_arguments)]
fn cog_fetch_windows_raw(
    srcs: Vec<String>,
    level: Vec<i32>,
    xoff: Vec<i32>,
    yoff: Vec<i32>,
    xsize: Vec<i32>,
    ysize: Vec<i32>,
    bands: Vec<i32>,
    fill: f64,
    io_concurrency: Nullable<i32>,
) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let io = match io_concurrency {
        Nullable::NotNull(v) if v > 0 => v as usize,
        _ => default_io_concurrency(),
    };
    let bands0: Vec<usize> = bands.iter().map(|&b| (b - 1).max(0) as usize).collect();
    let n = srcs.len();
    let reqs: Vec<window::WindowReq> = (0..n)
        .map(|i| window::WindowReq {
            level: (level[i] - 1).max(0) as usize,
            xoff: xoff[i].max(0) as usize,
            yoff: yoff[i].max(0) as usize,
            xsize: xsize[i].max(0) as usize,
            ysize: ysize[i].max(0) as usize,
        })
        .collect();

    // Open every source concurrently, then fetch all windows through one
    // global concurrency pool (sustained saturation, no per-tile tail).
    let windows = rt
        .block_on(async {
            let opens =
                futures::future::try_join_all(srcs.iter().map(|s| window::open_tiff(s))).await?;
            window::fetch_windows_pooled(&opens, &reqs, &bands0, fill, io).await
        })
        .map_err(to_r)?;

    let out: Vec<Robj> = windows
        .into_iter()
        .map(|w| {
            list!(
                bytes = Raw::from_bytes(&w.bytes),
                xsize = w.xsize as i32,
                ysize = w.ysize as i32,
                n_bands = w.n_bands as i32,
                dtype = w.dtype_name,
                bytes_per_sample = w.bps as i32,
                byte_order = window::native_byte_order()
            )
            .into()
        })
        .collect();
    Ok(List::from_values(out).into())
}

fn build_meta(open: &window::OpenTiff) -> std::result::Result<Robj, KirkError> {
    let ifd0 = open
        .tiff
        .ifds()
        .first()
        .ok_or_else(|| KirkError::Invalid("no IFDs".into()))?;

    let geo = ifd0
        .geo_key_directory()
        .ok_or(KirkError::MissingGeoKey("GeoKeyDirectory"))?;

    let gt = meta::extract_geotransform(ifd0, geo.raster_type)?;
    let n_bands = ifd0.samples_per_pixel() as usize;
    let dtype = meta::gdal_dtype_name(ifd0);
    let nodata = meta::parse_nodata(ifd0);
    let names = meta::band_descriptions(ifd0, n_bands);
    let crs = meta::resolve_src_crs(geo);

    let mut level_width: Vec<i32> = Vec::new();
    let mut level_height: Vec<i32> = Vec::new();
    let mut tile_width: Vec<i32> = Vec::new();
    let mut tile_height: Vec<i32> = Vec::new();
    for ifd in open.tiff.ifds() {
        level_width.push(ifd.image_width() as i32);
        level_height.push(ifd.image_height() as i32);
        tile_width.push(ifd.tile_width().map(|v| v as i32).unwrap_or(i32::MIN));
        tile_height.push(ifd.tile_height().map(|v| v as i32).unwrap_or(i32::MIN));
    }

    let nodata_robj: Robj = match nodata {
        Some(v) => r!(v),
        None => r!(NULL),
    };
    let crs_robj: Robj = match crs {
        Some(s) => r!(s),
        None => r!(NULL),
    };

    Ok(list!(
        width = level_width[0],
        height = level_height[0],
        n_bands = n_bands as i32,
        dtype = dtype,
        nodata = nodata_robj,
        geotransform = gt.0.to_vec(),
        crs = crs_robj,
        band_names = names,
        n_levels = level_width.len() as i32,
        level_width = level_width,
        level_height = level_height,
        tile_width = tile_width,
        tile_height = tile_height
    )
    .into())
}

extendr_module! {
    mod cptkirk;
    fn cog_open;
    fn cog_meta;
    fn cog_meta_many;
    fn cog_fetch_window;
    fn cog_fetch_window_raw;
    fn cog_fetch_windows_raw;
}
