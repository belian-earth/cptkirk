//! GeoTIFF metadata extraction: geotransform, CRS hint, nodata, band names.
//!
//! Unlike a5px, cptkirk does no projection math in Rust. CRS resolution is
//! deferred to GDAL/PROJ on the R side, so [`resolve_src_crs`] returns a plain
//! string GDAL can ingest (an `EPSG:<code>`, a WKT citation, or a proj4 string
//! reconstructed from explicit GeoKeys for GDAL-written user-defined CRSes).

use async_tiff::geo::GeoKeyDirectory;
use async_tiff::ImageFileDirectory;

use crate::error::{KirkError, Result};

/// EPSG sentinel for "user-defined CRS" per the GeoTIFF spec.
const EPSG_USER_DEFINED: u16 = 32767;

/// GDAL-style affine geotransform `[gt0..gt5]` such that for pixel `(col,row)`:
///   x = gt0 + col*gt1 + row*gt2
///   y = gt3 + col*gt4 + row*gt5
/// with `(col,row)` the pixel CORNER (pixel centre at `col+0.5, row+0.5`).
#[derive(Clone, Copy, Debug)]
pub(crate) struct GeoTransform(pub [f64; 6]);

/// `RasterPixelIsPoint` per GeoTIFF GTRasterTypeGeoKey (1025); the alternative
/// `RasterPixelIsArea` is 1 and is GDAL's default when the key is absent.
const RASTER_PIXEL_IS_POINT: u16 = 2;

/// Extract the affine geotransform in GDAL's corner-based `PixelIsArea`
/// convention. When the file declares `RasterPixelIsPoint`, the tiepoint
/// refers to the pixel CENTRE, so the origin is shifted back by half a pixel
/// in both raster axes to match what GDAL reports for the same file.
pub(crate) fn extract_geotransform(
    ifd: &ImageFileDirectory,
    raster_type: Option<u16>,
) -> Result<GeoTransform> {
    let mut gt = if let Some(m) = ifd.model_transformation() {
        if m.len() < 16 {
            return Err(KirkError::Invalid(
                "ModelTransformation tag has fewer than 16 elements".into(),
            ));
        }
        // 4x4 row-major -> GDAL geotransform.
        [m[3], m[0], m[1], m[7], m[4], m[5]]
    } else {
        let scale = ifd
            .model_pixel_scale()
            .ok_or(KirkError::MissingGeoKey("ModelPixelScale"))?;
        let tie = ifd
            .model_tiepoint()
            .ok_or(KirkError::MissingGeoKey("ModelTiepoint"))?;
        if scale.len() < 3 || tie.len() < 6 {
            return Err(KirkError::Invalid(
                "ModelPixelScale or ModelTiepoint malformed".into(),
            ));
        }
        let (sx, sy) = (scale[0], scale[1]);
        let (i, j, _k, x, y, _z) = (tie[0], tie[1], tie[2], tie[3], tie[4], tie[5]);
        [x - i * sx, sx, 0.0, y + j * sy, 0.0, -sy]
    };

    if raster_type == Some(RASTER_PIXEL_IS_POINT) {
        // Move origin from pixel centre to pixel corner.
        gt[0] -= 0.5 * gt[1] + 0.5 * gt[2];
        gt[3] -= 0.5 * gt[4] + 0.5 * gt[5];
    }
    Ok(GeoTransform(gt))
}

/// Resolve the source CRS into a string GDAL can import: an `EPSG:<code>`, a
/// WKT citation, or a proj4 string reconstructed from explicit GeoKeys.
pub(crate) fn resolve_src_crs(geo: &GeoKeyDirectory) -> Option<String> {
    if let Some(epsg) = geo.epsg_code() {
        if epsg != EPSG_USER_DEFINED && epsg != 0 {
            return Some(format!("EPSG:{epsg}"));
        }
    }
    if let Some(wkt) = first_wkt_citation(geo) {
        return Some(wkt.to_string());
    }
    build_proj_string_from_geokeys(geo)
}

fn first_wkt_citation(geo: &GeoKeyDirectory) -> Option<&str> {
    [
        geo.proj_citation.as_deref(),
        geo.geog_citation.as_deref(),
        geo.citation.as_deref(),
    ]
    .into_iter()
    .flatten()
    .map(str::trim)
    .find(|s| looks_like_wkt(s))
}

/// Reconstruct a proj string from explicit GeoKey projection parameters.
/// Covers the common projections GDAL writes when a custom `+proj=...` string
/// is set without an EPSG code. Returns `None` for unknown/unsupported ones.
fn build_proj_string_from_geokeys(geo: &GeoKeyDirectory) -> Option<String> {
    let coord_trans = geo.proj_coord_trans?;
    let lon_0 = geo
        .proj_nat_origin_long
        .or(geo.proj_center_long)
        .or(geo.proj_false_origin_long)
        .or(geo.proj_straight_vert_pole_long);
    let lat_0 = geo
        .proj_nat_origin_lat
        .or(geo.proj_center_lat)
        .or(geo.proj_false_origin_lat);
    let x_0 = geo.proj_false_easting.or(geo.proj_false_origin_easting);
    let y_0 = geo.proj_false_northing.or(geo.proj_false_origin_northing);

    let (proj, extras): (&str, Vec<String>) = match coord_trans {
        1 => {
            let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
            ("tmerc", vec![format!("+k_0={k}")])
        }
        7 => {
            if let Some(p1) = geo.proj_std_parallel1 {
                ("merc", vec![format!("+lat_ts={p1}")])
            } else {
                let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
                ("merc", vec![format!("+k_0={k}")])
            }
        }
        8 => {
            let p1 = geo.proj_std_parallel1?;
            let p2 = geo.proj_std_parallel2?;
            ("lcc", vec![format!("+lat_1={p1}"), format!("+lat_2={p2}")])
        }
        9 => {
            let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
            ("lcc", vec![format!("+k_0={k}")])
        }
        10 => ("laea", vec![]),
        11 => {
            let p1 = geo.proj_std_parallel1?;
            let p2 = geo.proj_std_parallel2?;
            ("aea", vec![format!("+lat_1={p1}"), format!("+lat_2={p2}")])
        }
        12 => ("aeqd", vec![]),
        13 => {
            let p1 = geo.proj_std_parallel1?;
            let p2 = geo.proj_std_parallel2?;
            ("eqdc", vec![format!("+lat_1={p1}"), format!("+lat_2={p2}")])
        }
        14 => {
            let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
            ("stere", vec![format!("+k_0={k}")])
        }
        15 => {
            if let Some(p1) = geo.proj_std_parallel1 {
                ("stere", vec![format!("+lat_ts={p1}")])
            } else {
                let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
                ("stere", vec![format!("+k_0={k}")])
            }
        }
        16 => {
            let k = geo.proj_scale_at_nat_origin.unwrap_or(1.0);
            ("sterea", vec![format!("+k_0={k}")])
        }
        17 => (
            "eqc",
            geo.proj_std_parallel1
                .map(|p| format!("+lat_ts={p}"))
                .into_iter()
                .collect(),
        ),
        19 => ("gnom", vec![]),
        21 => ("ortho", vec![]),
        24 => ("sinu", vec![]),
        28 => (
            "cea",
            geo.proj_std_parallel1
                .map(|p| format!("+lat_ts={p}"))
                .into_iter()
                .collect(),
        ),
        _ => return None,
    };

    let mut parts: Vec<String> = vec![format!("+proj={proj}")];
    if let Some(v) = lon_0 {
        parts.push(format!("+lon_0={v}"));
    }
    if let Some(v) = lat_0 {
        parts.push(format!("+lat_0={v}"));
    }
    if let Some(v) = x_0 {
        parts.push(format!("+x_0={v}"));
    }
    if let Some(v) = y_0 {
        parts.push(format!("+y_0={v}"));
    }
    parts.extend(extras);
    if let Some(pm) = prime_meridian_param(geo) {
        parts.push(pm);
    }
    parts.push(ellipsoid_param(geo));
    parts.push("+no_defs".to_string());
    Some(parts.join(" "))
}

fn prime_meridian_param(geo: &GeoKeyDirectory) -> Option<String> {
    if let Some(code) = geo.geog_prime_meridian {
        let name = match code {
            8901 => return None,
            8902 => Some("lisbon"),
            8903 => Some("paris"),
            8904 => Some("bogota"),
            8905 => Some("madrid"),
            8906 => Some("rome"),
            8907 => Some("bern"),
            8908 => Some("jakarta"),
            8909 => Some("ferro"),
            8910 => Some("brussels"),
            8911 => Some("stockholm"),
            8912 => Some("athens"),
            8913 => Some("oslo"),
            _ => None,
        };
        if let Some(n) = name {
            return Some(format!("+pm={n}"));
        }
    }
    if let Some(deg) = geo.geog_prime_meridian_long {
        if deg != 0.0 {
            return Some(format!("+pm={deg}"));
        }
    }
    None
}

fn ellipsoid_param(geo: &GeoKeyDirectory) -> String {
    if let Some(ellps_epsg) = geo.geog_ellipsoid {
        if let Some(name) = ellps_name_for_epsg(ellps_epsg) {
            return format!("+ellps={name}");
        }
    }
    let a = geo.geog_semi_major_axis;
    let b = geo.geog_semi_minor_axis;
    let rf = geo.geog_inv_flattening;
    if let Some(a_) = a {
        if let Some(rf_) = rf {
            return format!("+a={a_} +rf={rf_}");
        }
        if let Some(b_) = b {
            return format!("+a={a_} +b={b_}");
        }
        return format!("+a={a_}");
    }
    "+ellps=WGS84".to_string()
}

fn ellps_name_for_epsg(code: u16) -> Option<&'static str> {
    Some(match code {
        7001 => "airy",
        7002 => "mod_airy",
        7003 => "aust_SA",
        7004 => "bessel",
        7008 => "clrk66",
        7012 => "clrk80",
        7019 => "GRS80",
        7022 => "intl",
        7030 => "WGS84",
        7035 => "sphere",
        7043 => "WGS72",
        _ => return None,
    })
}

fn looks_like_wkt(s: &str) -> bool {
    let s = s.trim_start();
    matches!(
        s.split(|c: char| c == '[' || c == '(' || c.is_whitespace())
            .next()
            .unwrap_or(""),
        "PROJCS"
            | "PROJCRS"
            | "GEOGCS"
            | "GEOGCRS"
            | "GEODCRS"
            | "BOUNDCRS"
            | "COMPD_CS"
            | "COMPDCRS"
            | "ENGCRS"
            | "ENGCS"
            | "VERTCS"
            | "VERTCRS"
            | "TIMECRS"
    )
}

/// Dataset-wide nodata from the `TIFFTAG_GDAL_NODATA` ASCII tag.
pub(crate) fn parse_nodata(ifd: &ImageFileDirectory) -> Option<f64> {
    let s = ifd.gdal_nodata()?;
    s.trim().to_ascii_lowercase().parse::<f64>().ok()
}

/// Parse GDAL's per-band `<Item name="DESCRIPTION" sample="N">name</Item>`
/// from the GDAL_METADATA XML. Returns band-ordered names, or default
/// `band_NN` names if none are parseable.
pub(crate) fn band_descriptions(ifd: &ImageFileDirectory, n_bands: usize) -> Vec<String> {
    let default = || (0..n_bands).map(|i| format!("band_{:02}", i + 1)).collect();
    let xml = match ifd.gdal_metadata() {
        Some(s) => s,
        None => return default(),
    };
    let mut out: Vec<String> = (0..n_bands).map(|i| format!("band_{:02}", i + 1)).collect();
    let mut found = false;
    walk_items(xml, |sample, attrs, body| {
        if attr_eq(attrs, "name", "DESCRIPTION") {
            if let Some(s) = sample {
                if s < n_bands {
                    out[s] = body.trim().to_string();
                    found = true;
                }
            }
        }
    });
    if found {
        out
    } else {
        default()
    }
}

fn walk_items<F: FnMut(Option<usize>, &str, &str)>(xml: &str, mut f: F) {
    let mut rest = xml;
    while let Some(idx) = rest.find("<Item") {
        rest = &rest[idx..];
        let close = match rest.find('>') {
            Some(c) => c,
            None => break,
        };
        let attrs = &rest[..close];
        let body_end = match rest[close..].find("</Item>") {
            Some(e) => close + e,
            None => break,
        };
        let body = &rest[close + 1..body_end];
        let sample = parse_attr(attrs, "sample").and_then(|s| s.parse::<usize>().ok());
        f(sample, attrs, body);
        rest = &rest[body_end + "</Item>".len()..];
    }
}

fn parse_attr<'a>(attrs: &'a str, name: &str) -> Option<&'a str> {
    let needle = format!("{}=\"", name);
    let i = attrs.find(&needle)?;
    let tail = &attrs[i + needle.len()..];
    let q = tail.find('"')?;
    Some(&tail[..q])
}

fn attr_eq(attrs: &str, name: &str, value: &str) -> bool {
    parse_attr(attrs, name) == Some(value)
}

/// Map an IFD's sample format + bit depth to a GDAL data-type name.
pub(crate) fn gdal_dtype_name(ifd: &ImageFileDirectory) -> &'static str {
    use async_tiff::tags::SampleFormat;
    let sf = ifd.sample_format();
    let bps = ifd.bits_per_sample();
    let first_sf = sf.first().copied();
    let first_bps = bps.first().copied().unwrap_or(0);
    match (first_sf, first_bps) {
        (Some(SampleFormat::Uint), 1) => "Byte",
        (Some(SampleFormat::Uint), 8) => "Byte",
        (Some(SampleFormat::Uint), 16) => "UInt16",
        (Some(SampleFormat::Uint), 32) => "UInt32",
        (Some(SampleFormat::Uint), 64) => "UInt64",
        (Some(SampleFormat::Int), 8) => "Int8",
        (Some(SampleFormat::Int), 16) => "Int16",
        (Some(SampleFormat::Int), 32) => "Int32",
        (Some(SampleFormat::Int), 64) => "Int64",
        (Some(SampleFormat::Float), 32) => "Float32",
        (Some(SampleFormat::Float), 64) => "Float64",
        _ => "Float64",
    }
}
