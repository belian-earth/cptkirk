//! Band-aware tile fetching for planar (INTERLEAVE=BAND) TIFFs.
//!
//! Ported from a5px. `async_tiff::ImageFileDirectory::fetch_tile` always
//! fetches every band's byte range for a tile -- fine for chunky layouts but
//! wasteful for planar layouts when only a band subset is wanted (e.g. 8 of 64
//! embedding bands). This module fetches only the selected bands' compressed
//! byte ranges and decodes them into a `TypedArray`.
//!
//! Limitation: the predictor must be `Predictor::None` (raw byte concatenation
//! only). Files with predictor=Horizontal/FloatingPoint fall back to the full
//! tile path. Native machine endianness is assumed for multi-byte samples.

use async_tiff::decoder::DecoderRegistry;
use async_tiff::reader::AsyncFileReader;
use async_tiff::tags::Predictor;
use async_tiff::{ImageFileDirectory, TypedArray};
use bytes::Bytes;

use crate::error::{KirkError, Result};

/// Is the band-aware fetch path usable for this IFD?
pub(crate) fn supports_band_fetch(ifd: &ImageFileDirectory) -> bool {
    matches!(ifd.predictor(), None | Some(Predictor::None))
        && ifd.tile_offsets().is_some()
        && ifd.tile_byte_counts().is_some()
}

/// Fetch (only) the compressed byte ranges for the requested bands of a planar
/// tile. Returns one `Bytes` per selected band, in `selected_bands` order.
pub(crate) async fn fetch_planar_subset_bytes(
    reader: &dyn AsyncFileReader,
    ifd: &ImageFileDirectory,
    tx: usize,
    ty: usize,
    selected_bands: &[usize],
) -> Result<Vec<Bytes>> {
    if !matches!(ifd.predictor(), None | Some(Predictor::None)) {
        return Err(KirkError::Unsupported(
            "band-aware fetch requires Predictor::None".into(),
        ));
    }
    let n_bands_total = ifd.samples_per_pixel() as usize;
    let tile_offsets = ifd
        .tile_offsets()
        .ok_or_else(|| KirkError::Unsupported("missing TileOffsets".into()))?;
    let tile_byte_counts = ifd
        .tile_byte_counts()
        .ok_or_else(|| KirkError::Unsupported("missing TileByteCounts".into()))?;
    let (tiles_per_row, tiles_per_col) = ifd
        .tile_count()
        .ok_or_else(|| KirkError::Unsupported("not a tiled TIFF".into()))?;
    let tiles_per_band = tiles_per_row * tiles_per_col;

    let mut ranges: Vec<std::ops::Range<u64>> = Vec::with_capacity(selected_bands.len());
    for &b in selected_bands {
        if b >= n_bands_total {
            return Err(KirkError::Invalid(format!(
                "selected band {b} >= total {n_bands_total}"
            )));
        }
        let band_idx = (b * tiles_per_band) + (ty * tiles_per_row) + tx;
        let offset = tile_offsets[band_idx];
        let byte_count = tile_byte_counts[band_idx];
        ranges.push(offset..(offset + byte_count));
    }
    let buffers = reader.get_byte_ranges(ranges).await?;
    Ok(buffers)
}

/// Decode the per-band compressed bytes into a `TypedArray` with planar shape
/// `[n_selected, tile_h, tile_w]` (selected bands in order).
pub(crate) fn decode_planar_subset_bytes(
    band_buffers: Vec<Bytes>,
    ifd: &ImageFileDirectory,
    decoder_registry: &DecoderRegistry,
) -> Result<TypedArray> {
    let tile_w = ifd
        .tile_width()
        .ok_or_else(|| KirkError::Unsupported("not a tiled TIFF".into()))? as usize;
    let tile_h = ifd
        .tile_height()
        .ok_or_else(|| KirkError::Unsupported("not a tiled TIFF".into()))? as usize;
    let compression = ifd.compression();
    let decoder = decoder_registry
        .as_ref()
        .get(&compression)
        .ok_or_else(|| KirkError::Unsupported(format!("no decoder for {compression:?}")))?;
    let bits_per_sample = ifd.bits_per_sample().first().copied().unwrap_or(0);
    let bytes_per_sample = (bits_per_sample as usize).div_ceil(8);
    let band_bytes_uncompressed = tile_w * tile_h * bytes_per_sample;
    let total = band_bytes_uncompressed * band_buffers.len();
    let mut out: Vec<u8> = Vec::with_capacity(total);

    let photometric = ifd.photometric_interpretation();
    let jpeg_tables = ifd.jpeg_tables();
    let lerc_params = ifd.lerc_parameters();

    for buf in band_buffers {
        let decoded = decoder.decode_tile(
            buf,
            photometric,
            jpeg_tables,
            1,
            bits_per_sample,
            lerc_params,
        )?;
        if decoded.len() != band_bytes_uncompressed {
            return Err(KirkError::Unsupported(format!(
                "decoded band size {} != expected {}",
                decoded.len(),
                band_bytes_uncompressed
            )));
        }
        out.extend_from_slice(&decoded);
    }

    let dtype = derive_data_type(ifd);
    let typed = TypedArray::try_new(out, dtype)?;
    Ok(typed)
}

/// Mirror of `async_tiff::DataType::from_tags`, which is crate-private.
fn derive_data_type(ifd: &ImageFileDirectory) -> Option<async_tiff::DataType> {
    use async_tiff::tags::SampleFormat;
    use async_tiff::DataType;
    let sf = ifd.sample_format();
    let bps = ifd.bits_per_sample();
    let first_sf = sf.first()?;
    let first_bps = bps.first()?;
    if !sf.iter().all(|f| f == first_sf) {
        return None;
    }
    if !bps.iter().all(|b| b == first_bps) {
        return None;
    }
    match (first_sf, first_bps) {
        (SampleFormat::Uint, 1) => Some(DataType::Bool),
        (SampleFormat::Uint, 8) => Some(DataType::UInt8),
        (SampleFormat::Uint, 16) => Some(DataType::UInt16),
        (SampleFormat::Uint, 32) => Some(DataType::UInt32),
        (SampleFormat::Uint, 64) => Some(DataType::UInt64),
        (SampleFormat::Int, 8) => Some(DataType::Int8),
        (SampleFormat::Int, 16) => Some(DataType::Int16),
        (SampleFormat::Int, 32) => Some(DataType::Int32),
        (SampleFormat::Int, 64) => Some(DataType::Int64),
        (SampleFormat::Float, 32) => Some(DataType::Float32),
        (SampleFormat::Float, 64) => Some(DataType::Float64),
        _ => None,
    }
}
