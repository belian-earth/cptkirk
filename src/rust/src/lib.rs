use extendr_api::prelude::*;

mod band_fetch;
mod error;
mod http_reader;
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

/// Pair parallel key/value vectors (the object_store options the R layer
/// translated from GDAL-style settings) into the form `parse_src` expects.
/// Length-mismatched tails are dropped by `zip`.
fn zip_opts(keys: Vec<String>, vals: Vec<String>) -> Vec<(String, String)> {
    keys.into_iter().zip(vals).collect()
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
fn cog_open(src: &str, opt_keys: Vec<String>, opt_vals: Vec<String>) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let opts = zip_opts(opt_keys, opt_vals);
    let open = rt.block_on(window::open_tiff(src, &opts)).map_err(to_r)?;
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

/// Open every source once, reusing one connection pool per host (`OpenCache`),
/// then read each header concurrently over that pool. The shared front of every
/// multi-source entry point (meta / fetch / sources-open) -- so the whole API
/// pays ~one TLS handshake per host instead of one per source.
fn open_all_cached(
    srcs: &[String],
    opts: &[(String, String)],
) -> std::result::Result<Vec<window::OpenTiff>, KirkError> {
    let rt = runtime::shared_runtime()?;
    let mut cache = source::OpenCache::new();
    let readers = srcs
        .iter()
        .map(|s| source::open_reader_cached(s, opts, &mut cache))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    rt.block_on(async {
        futures::future::try_join_all(readers.into_iter().map(|r| window::open_tiff_from_reader(r)))
            .await
    })
}

/// Concurrently open several sources (one connection pool per host) and return
/// their metadata, in order. Used to plan a multi-tile mosaic / multi-source
/// `cog_info` without paying the opens sequentially.
/// @noRd
#[extendr]
fn cog_meta_many(
    srcs: Vec<String>,
    opt_keys: Vec<String>,
    opt_vals: Vec<String>,
) -> extendr_api::Result<Robj> {
    let opts = zip_opts(opt_keys, opt_vals);
    let opens = open_all_cached(&srcs, &opts).map_err(to_r)?;
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
    opt_keys: Vec<String>,
    opt_vals: Vec<String>,
) -> extendr_api::Result<Robj> {
    let rt = runtime::shared_runtime().map_err(to_r)?;
    let opts = zip_opts(opt_keys, opt_vals);
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

    // Open every source once over a shared connection pool, then fetch all
    // windows through one global concurrency pool (sustained saturation).
    let opens = open_all_cached(&srcs, &opts).map_err(to_r)?;
    let windows = rt
        .block_on(window::fetch_windows_pooled(&opens, &reqs, &bands0, fill, io))
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

// --- Streaming fetch session ------------------------------------------------
//
// Open every source ONCE (concurrently), then stream each fetched window back to
// R as it lands -- so the warp/write overlaps the fetch and the per-source
// header is read once (not twice, as the meta-then-fetch path does). The driver
// runs the per-source fetches through one `buffer_unordered` pool on the shared
// runtime, feeding a channel; `cog_fetch_take` blocks for the next completion.

/// A set of sources opened once, reused for streamed window fetches.
struct SourceSet {
    opens: Vec<std::sync::Arc<window::OpenTiff>>,
}

/// Receiver end of an in-flight streaming fetch. `Mutex` only to satisfy the
/// external-pointer Sync bound; it is accessed solely from R's thread.
struct FetchSession {
    rx: std::sync::Mutex<
        std::sync::mpsc::Receiver<(usize, std::result::Result<window::NativeWindow, String>)>,
    >,
}

/// Open many sources concurrently. Returns `list(ptr, metas)`: a reusable
/// handle plus per-source metadata for window planning. The header is read here
/// once; the subsequent stream fetches reuse the open handles.
/// @noRd
#[extendr]
fn cog_sources_open(
    srcs: Vec<String>,
    opt_keys: Vec<String>,
    opt_vals: Vec<String>,
) -> extendr_api::Result<Robj> {
    let opts = zip_opts(opt_keys, opt_vals);
    let opens: Vec<std::sync::Arc<window::OpenTiff>> = open_all_cached(&srcs, &opts)
        .map_err(to_r)?
        .into_iter()
        .map(std::sync::Arc::new)
        .collect();
    let metas: Vec<Robj> = opens
        .iter()
        .map(|o| build_meta(o))
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(to_r)?;
    let ptr: Robj = ExternalPtr::new(SourceSet { opens }).into();
    Ok(list!(ptr = ptr, metas = List::from_values(metas)).into())
}

/// Begin streaming the requested per-source windows from an open `SourceSet`.
/// `idx` is 1-based into the set; the parallel `level/xoff/...` vectors give each
/// requested window. Returns a session handle; drain it with `cog_fetch_take`.
/// @noRd
#[extendr]
#[allow(clippy::too_many_arguments)]
fn cog_fetch_stream_begin(
    set: ExternalPtr<SourceSet>,
    idx: Vec<i32>,
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
    let jobs: Vec<(usize, std::sync::Arc<window::OpenTiff>, window::WindowReq)> = (0..idx.len())
        .map(|k| {
            let si = (idx[k] - 1).max(0) as usize;
            (
                si,
                std::sync::Arc::clone(&set.opens[si]),
                window::WindowReq {
                    level: (level[k] - 1).max(0) as usize,
                    xoff: xoff[k].max(0) as usize,
                    yoff: yoff[k].max(0) as usize,
                    xsize: xsize[k].max(0) as usize,
                    ysize: ysize[k].max(0) as usize,
                },
            )
        })
        .collect();

    let (tx, rx) = std::sync::mpsc::channel();
    rt.spawn(async move {
        use futures::stream::StreamExt;
        futures::stream::iter(jobs.into_iter().map(|(si, open, req)| {
            let tx = tx.clone();
            let bands0 = bands0.clone();
            // Inner tile concurrency is 1: parallelism comes from running `io`
            // sources at once (right for many small windows), so total in-flight
            // requests stay ~`io`.
            async move {
                let res = window::fetch_window_native(
                    &open, req.level, req.xoff, req.yoff, req.xsize, req.ysize, &bands0, fill, 1,
                )
                .await
                .map_err(|e| e.to_string());
                let _ = tx.send((si, res));
            }
        }))
        .buffer_unordered(io)
        .collect::<()>()
        .await;
    });

    Ok(ExternalPtr::new(FetchSession {
        rx: std::sync::Mutex::new(rx),
    })
    .into())
}

/// Block for the next completed window (any source, completion order). Returns a
/// `list(index, bytes, xsize, ysize, n_bands, dtype, bytes_per_sample,
/// byte_order)` (`index` 1-based into the SourceSet), `list(index, error)` on a
/// per-source failure, or `NULL` when the stream is fully drained.
/// @noRd
#[extendr]
fn cog_fetch_take(sess: ExternalPtr<FetchSession>) -> extendr_api::Result<Robj> {
    let rx = sess
        .rx
        .lock()
        .map_err(|_| Error::Other("fetch session lock poisoned".into()))?;
    match rx.recv() {
        Ok((si, Ok(w))) => Ok(list!(
            index = (si + 1) as i32,
            bytes = Raw::from_bytes(&w.bytes),
            xsize = w.xsize as i32,
            ysize = w.ysize as i32,
            n_bands = w.n_bands as i32,
            dtype = w.dtype_name,
            bytes_per_sample = w.bps as i32,
            byte_order = window::native_byte_order()
        )
        .into()),
        Ok((si, Err(e))) => Ok(list!(index = (si + 1) as i32, error = e).into()),
        Err(_) => Ok(r!(NULL)),
    }
}

extendr_module! {
    mod cptkirk;
    fn cog_open;
    fn cog_meta;
    fn cog_meta_many;
    fn cog_fetch_window;
    fn cog_fetch_window_raw;
    fn cog_fetch_windows_raw;
    fn cog_sources_open;
    fn cog_fetch_stream_begin;
    fn cog_fetch_take;
}
