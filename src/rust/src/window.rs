//! Remote tile streaming + window assembly.
//!
//! `open_tiff` performs the metadata round-trips (header + all IFDs).
//! `fetch_decoded` fetches every tile overlapping a requested pixel window of a
//! chosen IFD (overview level), decoding concurrently (band-subset byte ranges
//! for planar layouts). The decoded tiles are then blitted into either:
//!   * a band-sequential `f64` buffer (`blit_f64`) for returning pixel values
//!     to R, or
//!   * a band-sequential NATIVE-dtype byte buffer (`blit_native`) for staging a
//!     `/vsimem` raster that GDAL warps directly. The native path keeps memory
//!     at the source dtype's footprint (e.g. 1 byte/px for Int8, not 8).

use std::sync::Arc;

use async_tiff::decoder::DecoderRegistry;
use async_tiff::metadata::cache::ReadaheadMetadataCache;
use async_tiff::metadata::TiffMetadataReader;
use async_tiff::reader::AsyncFileReader;
use async_tiff::tags::PlanarConfiguration;
use async_tiff::{TypedArray, TIFF};
use futures::stream::{self, StreamExt, TryStreamExt};

use crate::error::{KirkError, Result};
use crate::source::open_reader;

pub(crate) struct OpenTiff {
    pub reader: Arc<dyn AsyncFileReader>,
    pub tiff: TIFF,
}

pub(crate) async fn open_tiff(src: &str, opts: &[(String, String)]) -> Result<OpenTiff> {
    open_tiff_from_reader(open_reader(src, opts)?).await
}

/// Read the header + all IFDs over an already-built reader. Splitting this from
/// reader construction lets a multi-source open build readers once (sharing a
/// connection pool via `OpenCache`) and then read metadata concurrently.
pub(crate) async fn open_tiff_from_reader(reader: Arc<dyn AsyncFileReader>) -> Result<OpenTiff> {
    let cache = ReadaheadMetadataCache::new(reader.clone());
    let mut meta = TiffMetadataReader::try_open(&cache).await?;
    let ifds = meta.read_all_ifds(&cache).await?;
    let endianness = meta.endianness();
    let tiff = TIFF::new(ifds, endianness);
    Ok(OpenTiff { reader, tiff })
}

#[inline]
fn read_pixel(data: &TypedArray, idx: usize) -> f64 {
    match data {
        TypedArray::UInt8(v) => v[idx] as f64,
        TypedArray::UInt16(v) => v[idx] as f64,
        TypedArray::UInt32(v) => v[idx] as f64,
        TypedArray::UInt64(v) => v[idx] as f64,
        TypedArray::Int8(v) => v[idx] as f64,
        TypedArray::Int16(v) => v[idx] as f64,
        TypedArray::Int32(v) => v[idx] as f64,
        TypedArray::Int64(v) => v[idx] as f64,
        TypedArray::Float32(v) => v[idx] as f64,
        TypedArray::Float64(v) => v[idx],
        TypedArray::Bool(v) => {
            if v[idx] {
                1.0
            } else {
                0.0
            }
        }
    }
}

/// Native-endian byte view of a decoded tile's buffer. The element types are
/// all plain `Copy` numeric/bool, so reinterpreting the backing storage as
/// bytes is sound; the bytes are in native order, matching the VRT ByteOrder.
#[inline]
fn typed_bytes(data: &TypedArray) -> &[u8] {
    #[inline]
    fn as_bytes<T>(v: &[T]) -> &[u8] {
        unsafe { std::slice::from_raw_parts(v.as_ptr() as *const u8, std::mem::size_of_val(v)) }
    }
    match data {
        TypedArray::UInt8(v) => v.as_slice(),
        TypedArray::Int8(v) => as_bytes(v),
        TypedArray::Bool(v) => as_bytes(v),
        TypedArray::UInt16(v) => as_bytes(v),
        TypedArray::Int16(v) => as_bytes(v),
        TypedArray::UInt32(v) => as_bytes(v),
        TypedArray::Int32(v) => as_bytes(v),
        TypedArray::UInt64(v) => as_bytes(v),
        TypedArray::Int64(v) => as_bytes(v),
        TypedArray::Float32(v) => as_bytes(v),
        TypedArray::Float64(v) => as_bytes(v),
    }
}

/// Native-endian byte pattern for the nodata/fill value at the source dtype.
fn fill_pattern(dtype: &str, fill: f64, bps: usize) -> Vec<u8> {
    match dtype {
        "Byte" => vec![fill as u8],
        "Int8" => vec![fill as i8 as u8],
        "UInt16" => (fill as u16).to_ne_bytes().to_vec(),
        "Int16" => (fill as i16).to_ne_bytes().to_vec(),
        "UInt32" => (fill as u32).to_ne_bytes().to_vec(),
        "Int32" => (fill as i32).to_ne_bytes().to_vec(),
        "UInt64" => (fill as u64).to_ne_bytes().to_vec(),
        "Int64" => (fill as i64).to_ne_bytes().to_vec(),
        "Float32" => (fill as f32).to_ne_bytes().to_vec(),
        "Float64" => fill.to_ne_bytes().to_vec(),
        _ => vec![0u8; bps],
    }
}

/// Decoded tiles plus the layout needed to blit them into a window.
pub(crate) struct Decoded {
    /// (tile_x, tile_y, decoded data, is_band_subset_buffer)
    tiles: Vec<(usize, usize, TypedArray, bool)>,
    planar: PlanarConfiguration,
    total_bands: usize,
    tile_w: usize,
    tile_h: usize,
    bands: Vec<usize>,
    xoff: usize,
    yoff: usize,
    pub xsize: usize,
    pub ysize: usize,
    pub dtype_name: &'static str,
    pub bps: usize,
}

impl Decoded {
    pub fn n_bands(&self) -> usize {
        self.bands.len()
    }
}

/// Fetch and decode every tile overlapping the window of IFD `level`.
/// `bands0` is 0-based; empty selects all bands. The window must lie fully
/// within the level's pixel extent (the R caller clips it).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn fetch_decoded(
    open: &OpenTiff,
    level: usize,
    xoff: usize,
    yoff: usize,
    xsize: usize,
    ysize: usize,
    bands0: &[usize],
    io_concurrency: usize,
) -> Result<Decoded> {
    let ifd = open
        .tiff
        .ifds()
        .get(level)
        .ok_or_else(|| KirkError::Invalid(format!("overview level {level} out of range")))?
        .clone();

    let width = ifd.image_width() as usize;
    let height = ifd.image_height() as usize;
    let total_bands = ifd.samples_per_pixel() as usize;
    let planar = ifd.planar_configuration();
    let tile_w = ifd
        .tile_width()
        .ok_or_else(|| KirkError::Unsupported("strip-based TIFF (tiled required)".into()))?
        as usize;
    let tile_h = ifd
        .tile_height()
        .ok_or_else(|| KirkError::Unsupported("strip-based TIFF (tiled required)".into()))?
        as usize;
    let dtype_name = crate::meta::gdal_dtype_name(&ifd);
    let bps = (ifd.bits_per_sample().first().copied().unwrap_or(8) as usize)
        .div_ceil(8)
        .max(1);

    if xsize == 0 || ysize == 0 {
        return Err(KirkError::Invalid("empty window".into()));
    }
    let xend = xoff + xsize;
    let yend = yoff + ysize;
    if xend > width || yend > height {
        return Err(KirkError::Invalid(format!(
            "window [{xoff},{yoff} {xsize}x{ysize}] exceeds level extent {width}x{height}"
        )));
    }

    let bands: Vec<usize> = if bands0.is_empty() {
        (0..total_bands).collect()
    } else {
        for &b in bands0 {
            if b >= total_bands {
                return Err(KirkError::Invalid(format!(
                    "band {b} >= band count {total_bands}"
                )));
            }
        }
        bands0.to_vec()
    };
    let n_sel = bands.len();

    if !matches!(
        planar,
        PlanarConfiguration::Chunky | PlanarConfiguration::Planar
    ) {
        return Err(KirkError::Unsupported(format!(
            "unhandled planar configuration: {planar:?}"
        )));
    }

    // Band-subset byte-range fetch is worthwhile only for planar layouts when
    // fewer than all bands are requested and there is no predictor to undo.
    let use_band_fetch = matches!(planar, PlanarConfiguration::Planar)
        && n_sel < total_bands
        && crate::band_fetch::supports_band_fetch(&ifd);

    let tx0 = xoff / tile_w;
    let tx1 = (xend - 1) / tile_w;
    let ty0 = yoff / tile_h;
    let ty1 = (yend - 1) / tile_h;
    let mut coords: Vec<(usize, usize)> = Vec::new();
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            coords.push((tx, ty));
        }
    }

    let registry = Arc::new(DecoderRegistry::default());
    let ifd = Arc::new(ifd);
    let sel = Arc::new(bands.clone());

    let tiles: Vec<(usize, usize, TypedArray, bool)> = stream::iter(coords)
        .map(|(tx, ty)| {
            let ifd = Arc::clone(&ifd);
            let registry = Arc::clone(&registry);
            let sel = Arc::clone(&sel);
            let reader = open.reader.clone();
            async move {
                if use_band_fetch {
                    let buffers = crate::band_fetch::fetch_planar_subset_bytes(
                        &reader as &dyn AsyncFileReader,
                        &ifd,
                        tx,
                        ty,
                        &sel,
                    )
                    .await?;
                    let data = tokio::task::spawn_blocking(move || {
                        crate::band_fetch::decode_planar_subset_bytes(buffers, &ifd, &registry)
                    })
                    .await
                    .map_err(|e| KirkError::WorkerJoin(e.to_string()))??;
                    Ok::<_, KirkError>((tx, ty, data, true))
                } else {
                    let tile = ifd.fetch_tile(tx, ty, &reader as &dyn AsyncFileReader).await?;
                    let arr = tokio::task::spawn_blocking(move || tile.decode(&registry))
                        .await
                        .map_err(|e| KirkError::WorkerJoin(e.to_string()))??;
                    let (data, _shape, _) = arr.into_inner();
                    Ok::<_, KirkError>((tx, ty, data, false))
                }
            }
        })
        .buffer_unordered(io_concurrency.max(1))
        .try_collect()
        .await?;

    Ok(Decoded {
        tiles,
        planar,
        total_bands,
        tile_w,
        tile_h,
        bands,
        xoff,
        yoff,
        xsize,
        ysize,
        dtype_name,
        bps,
    })
}

// Stride layout for one tile buffer. Subset buffers (always planar) hold only
// the selected bands, in order.
#[inline]
fn strides(
    subset: bool,
    planar: PlanarConfiguration,
    total_bands: usize,
    tile_w: usize,
    tile_h: usize,
) -> (usize, usize, usize) {
    if subset {
        (tile_w, 1, tile_h * tile_w)
    } else {
        match planar {
            PlanarConfiguration::Chunky => (tile_w * total_bands, total_bands, 1),
            _ => (tile_w, 1, tile_h * tile_w),
        }
    }
}

pub(crate) struct Window {
    /// Band-sequential, row-major within each band.
    pub data: Vec<f64>,
    pub xsize: usize,
    pub ysize: usize,
    pub n_bands: usize,
}

/// Blit decoded tiles into a band-sequential `f64` buffer.
pub(crate) fn blit_f64(dec: &Decoded, fill: f64) -> Window {
    let n_sel = dec.n_bands();
    let band_area = dec.xsize * dec.ysize;
    let mut out = vec![fill; band_area * n_sel];
    let xend = dec.xoff + dec.xsize;
    let yend = dec.yoff + dec.ysize;

    for (tx, ty, data, subset) in &dec.tiles {
        let (h_stride, w_stride, b_stride) =
            strides(*subset, dec.planar, dec.total_bands, dec.tile_w, dec.tile_h);
        let tile_x0 = tx * dec.tile_w;
        let tile_y0 = ty * dec.tile_h;
        let gx0 = tile_x0.max(dec.xoff);
        let gx1 = ((tx + 1) * dec.tile_w).min(xend);
        let gy0 = tile_y0.max(dec.yoff);
        let gy1 = ((ty + 1) * dec.tile_h).min(yend);
        for gy in gy0..gy1 {
            let r_local = gy - tile_y0;
            let out_row = (gy - dec.yoff) * dec.xsize;
            for gx in gx0..gx1 {
                let c_local = gx - tile_x0;
                let base = r_local * h_stride + c_local * w_stride;
                let out_idx = out_row + (gx - dec.xoff);
                for out_b in 0..n_sel {
                    let buf_b = if *subset { out_b } else { dec.bands[out_b] };
                    out[out_b * band_area + out_idx] = read_pixel(data, base + buf_b * b_stride);
                }
            }
        }
    }
    Window {
        data: out,
        xsize: dec.xsize,
        ysize: dec.ysize,
        n_bands: n_sel,
    }
}

pub(crate) struct NativeWindow {
    /// Band-sequential, row-major within each band, native dtype + endianness.
    pub bytes: Vec<u8>,
    pub xsize: usize,
    pub ysize: usize,
    pub n_bands: usize,
    pub bps: usize,
    pub dtype_name: &'static str,
}

/// Allocate a band-sequential output buffer prefilled with the fill value.
fn alloc_filled(xsize: usize, ysize: usize, n_sel: usize, bps: usize,
                dtype: &str, fill: f64) -> Vec<u8> {
    let mut out = vec![0u8; xsize * ysize * n_sel * bps];
    let pat = fill_pattern(dtype, fill, bps);
    if pat.iter().any(|&b| b != 0) {
        for chunk in out.chunks_mut(bps) {
            chunk.copy_from_slice(&pat);
        }
    }
    out
}

/// Blit one decoded COG tile into the band-sequential native output buffer.
/// `out` is the whole window buffer; this writes only the tile's overlap.
// out_b indexes `bands` only in the non-subset branch; it also drives the dst
// offset arithmetic, so an enumerate() rewrite would not be clearer.
#[allow(clippy::too_many_arguments, clippy::needless_range_loop)]
fn blit_cog_tile(out: &mut [u8], data: &TypedArray, subset: bool, tx: usize, ty: usize,
                 planar: PlanarConfiguration, total_bands: usize, tile_w: usize,
                 tile_h: usize, bands: &[usize], xoff: usize, yoff: usize,
                 xsize: usize, ysize: usize, bps: usize) {
    let n_sel = bands.len();
    let band_area = xsize * ysize;
    let tile_area = tile_h * tile_w;
    let xend = xoff + xsize;
    let yend = yoff + ysize;
    // Only full (non-subset) chunky buffers are byte-interleaved; planar and
    // band-subset buffers store each band's row contiguously.
    let interleaved = matches!(planar, PlanarConfiguration::Chunky) && !subset;
    let src = typed_bytes(data);
    let tile_x0 = tx * tile_w;
    let tile_y0 = ty * tile_h;
    let gx0 = tile_x0.max(xoff);
    let gx1 = ((tx + 1) * tile_w).min(xend);
    let gy0 = tile_y0.max(yoff);
    let gy1 = ((ty + 1) * tile_h).min(yend);
    let run = gx1.saturating_sub(gx0);
    if run == 0 {
        return;
    }
    for out_b in 0..n_sel {
        let buf_b = if subset { out_b } else { bands[out_b] };
        for gy in gy0..gy1 {
            let r_local = gy - tile_y0;
            let dst0 = (out_b * band_area + (gy - yoff) * xsize + (gx0 - xoff)) * bps;
            if interleaved {
                let base = (r_local * tile_w + (gx0 - tile_x0)) * total_bands + buf_b;
                for c in 0..run {
                    let s = (base + c * total_bands) * bps;
                    let d = dst0 + c * bps;
                    out[d..d + bps].copy_from_slice(&src[s..s + bps]);
                }
            } else {
                let src_elem = buf_b * tile_area + r_local * tile_w + (gx0 - tile_x0);
                let s = src_elem * bps;
                out[dst0..dst0 + run * bps].copy_from_slice(&src[s..s + run * bps]);
            }
        }
    }
}

/// Blit decoded tiles into a band-sequential NATIVE-dtype byte buffer.
pub(crate) fn blit_native(dec: &Decoded, fill: f64) -> NativeWindow {
    let n_sel = dec.n_bands();
    let bps = dec.bps;
    let mut out = alloc_filled(dec.xsize, dec.ysize, n_sel, bps, dec.dtype_name, fill);
    for (tx, ty, data, subset) in &dec.tiles {
        blit_cog_tile(&mut out, data, *subset, *tx, *ty, dec.planar, dec.total_bands,
                      dec.tile_w, dec.tile_h, &dec.bands, dec.xoff, dec.yoff,
                      dec.xsize, dec.ysize, bps);
    }
    NativeWindow {
        bytes: out,
        xsize: dec.xsize,
        ysize: dec.ysize,
        n_bands: n_sel,
        bps,
        dtype_name: dec.dtype_name,
    }
}

/// Convenience: fetch + blit to `f64`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn fetch_window(
    open: &OpenTiff,
    level: usize,
    xoff: usize,
    yoff: usize,
    xsize: usize,
    ysize: usize,
    bands0: &[usize],
    fill: f64,
    io_concurrency: usize,
) -> Result<Window> {
    let dec = fetch_decoded(open, level, xoff, yoff, xsize, ysize, bands0, io_concurrency).await?;
    Ok(blit_f64(&dec, fill))
}

/// Convenience: fetch + blit to native bytes.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn fetch_window_native(
    open: &OpenTiff,
    level: usize,
    xoff: usize,
    yoff: usize,
    xsize: usize,
    ysize: usize,
    bands0: &[usize],
    fill: f64,
    io_concurrency: usize,
) -> Result<NativeWindow> {
    let dec = fetch_decoded(open, level, xoff, yoff, xsize, ysize, bands0, io_concurrency).await?;
    Ok(blit_native(&dec, fill))
}

/// Native byte order tag for VRT raw bands ("LSB" / "MSB").
pub(crate) const fn native_byte_order() -> &'static str {
    if cfg!(target_endian = "little") {
        "LSB"
    } else {
        "MSB"
    }
}

/// A window request against one already-open source.
pub(crate) struct WindowReq {
    pub level: usize,
    pub xoff: usize,
    pub yoff: usize,
    pub xsize: usize,
    pub ysize: usize,
}

/// Per-tile fetch plan: everything needed to fetch + blit its COG tiles,
/// resolved once (no I/O beyond what `open_tiff` already did).
struct TilePlan {
    reader: Arc<dyn AsyncFileReader>,
    ifd: Arc<async_tiff::ImageFileDirectory>,
    planar: PlanarConfiguration,
    total_bands: usize,
    tile_w: usize,
    tile_h: usize,
    bands: Vec<usize>,
    xoff: usize,
    yoff: usize,
    xsize: usize,
    ysize: usize,
    dtype: &'static str,
    bps: usize,
    use_band_fetch: bool,
    coords: Vec<(usize, usize)>,
}

fn plan_tile(open: &OpenTiff, req: &WindowReq, bands0: &[usize]) -> Result<TilePlan> {
    let ifd = open
        .tiff
        .ifds()
        .get(req.level)
        .ok_or_else(|| KirkError::Invalid(format!("overview level {} out of range", req.level)))?
        .clone();
    let width = ifd.image_width() as usize;
    let height = ifd.image_height() as usize;
    let total_bands = ifd.samples_per_pixel() as usize;
    let planar = ifd.planar_configuration();
    let tile_w = ifd
        .tile_width()
        .ok_or_else(|| KirkError::Unsupported("strip-based TIFF (tiled required)".into()))?
        as usize;
    let tile_h = ifd
        .tile_height()
        .ok_or_else(|| KirkError::Unsupported("strip-based TIFF (tiled required)".into()))?
        as usize;
    let dtype = crate::meta::gdal_dtype_name(&ifd);
    let bps = (ifd.bits_per_sample().first().copied().unwrap_or(8) as usize)
        .div_ceil(8)
        .max(1);
    let (xoff, yoff, xsize, ysize) = (req.xoff, req.yoff, req.xsize, req.ysize);
    let xend = xoff + xsize;
    let yend = yoff + ysize;
    if xsize == 0 || ysize == 0 || xend > width || yend > height {
        return Err(KirkError::Invalid(format!(
            "window [{xoff},{yoff} {xsize}x{ysize}] exceeds level extent {width}x{height}"
        )));
    }
    if !matches!(
        planar,
        PlanarConfiguration::Chunky | PlanarConfiguration::Planar
    ) {
        return Err(KirkError::Unsupported(format!(
            "unhandled planar configuration: {planar:?}"
        )));
    }
    let bands: Vec<usize> = if bands0.is_empty() {
        (0..total_bands).collect()
    } else {
        // Reject out-of-range bands here (as fetch_decoded does): the chunky blit
        // slices by band index, so an out-of-range band would panic out of bounds.
        for &b in bands0 {
            if b >= total_bands {
                return Err(KirkError::Invalid(format!(
                    "band {b} >= band count {total_bands}"
                )));
            }
        }
        bands0.to_vec()
    };
    let use_band_fetch = matches!(planar, PlanarConfiguration::Planar)
        && bands.len() < total_bands
        && crate::band_fetch::supports_band_fetch(&ifd);

    let tx0 = xoff / tile_w;
    let tx1 = (xend - 1) / tile_w;
    let ty0 = yoff / tile_h;
    let ty1 = (yend - 1) / tile_h;
    let mut coords = Vec::new();
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            coords.push((tx, ty));
        }
    }
    Ok(TilePlan {
        reader: open.reader.clone(),
        ifd: Arc::new(ifd),
        planar,
        total_bands,
        tile_w,
        tile_h,
        bands,
        xoff,
        yoff,
        xsize,
        ysize,
        dtype,
        bps,
        use_band_fetch,
        coords,
    })
}

/// Fetch several windows (one per open source) through a SINGLE global
/// concurrency pool: every (tile, COG-tile) fetch+decode is scheduled in one
/// `buffer_unordered(concurrency)`, so in-flight requests stay pinned at
/// `concurrency` until all tiles are done -- no per-tile budget, no uneven
/// tail when tiles cover different amounts of the AOI. Each decoded COG tile is
/// blitted into its source tile's output buffer as it arrives.
///
/// We deliberately do NOT coalesce a source's tile byte ranges into fewer
/// merged `get_ranges` requests (the rustycogs / "one request per file"
/// approach). Benchmarked on the 4-tile AEF -> ESD mosaic it was consistently
/// slower (~66s vs ~48s) with a pathological tail (one 235s run): the planar
/// 64-band layout scatters a window's ranges across the whole file, so
/// coalescing either over-merges (fetching gap bytes between band planes) or
/// erodes the request concurrency that saturation -- cptkirk's whole speed
/// lever -- depends on. Many small concurrent reads win here.
pub(crate) async fn fetch_windows_pooled(
    opens: &[OpenTiff],
    reqs: &[WindowReq],
    bands0: &[usize],
    fill: f64,
    concurrency: usize,
) -> Result<Vec<NativeWindow>> {
    let registry = Arc::new(DecoderRegistry::default());
    let plans: Vec<TilePlan> = opens
        .iter()
        .zip(reqs.iter())
        .map(|(o, r)| plan_tile(o, r, bands0))
        .collect::<Result<_>>()?;

    // Flat task list across all tiles: (tile_index, tx, ty).
    let tasks: Vec<(usize, usize, usize)> = plans
        .iter()
        .enumerate()
        .flat_map(|(i, p)| p.coords.iter().map(move |&(tx, ty)| (i, tx, ty)))
        .collect();

    let decoded: Vec<(usize, usize, usize, TypedArray, bool)> = stream::iter(tasks)
        .map(|(i, tx, ty)| {
            let p = &plans[i];
            let reader = p.reader.clone();
            let ifd = Arc::clone(&p.ifd);
            let registry = Arc::clone(&registry);
            let bands = p.bands.clone();
            let use_band_fetch = p.use_band_fetch;
            async move {
                if use_band_fetch {
                    let buffers = crate::band_fetch::fetch_planar_subset_bytes(
                        &reader as &dyn AsyncFileReader,
                        &ifd,
                        tx,
                        ty,
                        &bands,
                    )
                    .await?;
                    let ifd2 = Arc::clone(&ifd);
                    let data = tokio::task::spawn_blocking(move || {
                        crate::band_fetch::decode_planar_subset_bytes(buffers, &ifd2, &registry)
                    })
                    .await
                    .map_err(|e| KirkError::WorkerJoin(e.to_string()))??;
                    Ok::<_, KirkError>((i, tx, ty, data, true))
                } else {
                    let tile = ifd.fetch_tile(tx, ty, &reader as &dyn AsyncFileReader).await?;
                    let arr = tokio::task::spawn_blocking(move || tile.decode(&registry))
                        .await
                        .map_err(|e| KirkError::WorkerJoin(e.to_string()))??;
                    let (data, _shape, _) = arr.into_inner();
                    Ok::<_, KirkError>((i, tx, ty, data, false))
                }
            }
        })
        .buffer_unordered(concurrency.max(1))
        .try_collect()
        .await?;

    // Allocate output buffers, then blit each decoded COG tile into its tile.
    let mut outs: Vec<Vec<u8>> = plans
        .iter()
        .map(|p| alloc_filled(p.xsize, p.ysize, p.bands.len(), p.bps, p.dtype, fill))
        .collect();
    for (i, tx, ty, data, subset) in &decoded {
        let p = &plans[*i];
        blit_cog_tile(&mut outs[*i], data, *subset, *tx, *ty, p.planar, p.total_bands,
                      p.tile_w, p.tile_h, &p.bands, p.xoff, p.yoff, p.xsize, p.ysize, p.bps);
    }

    Ok(plans
        .into_iter()
        .zip(outs)
        .map(|(p, bytes)| NativeWindow {
            bytes,
            xsize: p.xsize,
            ysize: p.ysize,
            n_bands: p.bands.len(),
            bps: p.bps,
            dtype_name: p.dtype,
        })
        .collect())
}
