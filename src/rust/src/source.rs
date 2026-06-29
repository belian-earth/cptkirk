//! Source string -> object_store dispatch.
//!
//! Ported from a5px. A URL with a scheme longer than one character is handed
//! to `object_store::parse_url` (covers http(s)://, s3://, gs://, az://).
//! Anything else is treated as a local path. Single-letter "schemes" are
//! skipped so Windows drive-letter paths (`d:/foo.tif`) take the local branch.

use std::sync::Arc;

use async_tiff::reader::{AsyncFileReader, ObjectReader};
use object_store::path::Path as ObjPath;
use object_store::ObjectStore;

use crate::error::{KirkError, Result};
use crate::http_reader::SignedHttpReader;

/// Resolve a source string to the reader the windowing engine streams from.
///
/// A pre-signed HTTP(S) URL (credential in the query string) is read with
/// [`SignedHttpReader`], which preserves the query that object_store's
/// `HttpStore` would otherwise drop (see [`is_presigned_http`]). Everything else
/// -- local paths, native `s3://`/`gs://`/`az://`, plain public https, and Azure
/// SAS URLs (handled in [`parse_src`] via `azure_storage_sas_key`) -- goes
/// through object_store via an [`ObjectReader`].
pub(crate) fn open_reader(
    src: &str,
    extra_opts: &[(String, String)],
) -> Result<Arc<dyn AsyncFileReader>> {
    if let Ok(url) = url::Url::parse(src) {
        if is_presigned_http(&url) {
            let reader = SignedHttpReader::new(url)
                .map_err(|e| KirkError::Invalid(format!("signed http reader: {e}")))?;
            return Ok(Arc::new(reader));
        }
    }
    let (store, path) = parse_src(src, extra_opts)?;
    Ok(Arc::new(ObjectReader::new(store, path)))
}

/// True if `url` is a pre-signed HTTP(S) URL whose credential rides in the query
/// string, which object_store's generic `HttpStore` would silently drop.
///
/// Azure SAS blob/dfs URLs are deliberately excluded: they are read through
/// object_store's native Azure store via the `azure_storage_sas_key` injection
/// in [`parse_src`], and their signature parameter is `sig` (not matched here).
fn is_presigned_http(url: &url::Url) -> bool {
    if !matches!(url.scheme(), "http" | "https") {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    if host.ends_with(".blob.core.windows.net") || host.ends_with(".dfs.core.windows.net") {
        return false;
    }
    let Some(query) = url.query() else {
        return false;
    };
    // S3 V2 / Huawei OBS sign with AccessKeyId + Signature; S3 V4 (AWS, MinIO,
    // ...) with X-Amz-Signature; GCS V4 signed URLs with X-Goog-Signature.
    let v2 = has_query_key(query, "AccessKeyId") && has_query_key(query, "Signature");
    let v4 = has_query_key(query, "X-Amz-Signature") || has_query_key(query, "X-Goog-Signature");
    v2 || v4
}

/// Case-insensitive check for a `name=...` pair in a raw URL query string.
fn has_query_key(query: &str, name: &str) -> bool {
    query.split('&').any(|kv| {
        let key = kv.split('=').next().unwrap_or("");
        key.eq_ignore_ascii_case(name)
    })
}

pub(crate) fn parse_src(
    src: &str,
    extra_opts: &[(String, String)],
) -> Result<(Arc<dyn ObjectStore>, ObjPath)> {
    if let Ok(url) = url::Url::parse(src) {
        if url.scheme().len() > 1 {
            // Credentials come from the process environment, using the same
            // variable names object_store documents (AWS_*, GOOGLE_*, AZURE_*).
            // We forward only the recognised cloud prefixes so an unrelated var
            // (object_store also accepts bare aliases like `region`/`token`)
            // can't be mistaken for store config. With no static credentials the
            // builders fall back to their own chain (web-identity, ECS, EC2
            // instance metadata). Secrets never pass through R.
            let env_opts = std::env::vars().filter(|(k, _)| {
                let k = k.to_ascii_uppercase();
                k.starts_with("AWS_")
                    || k.starts_with("GOOGLE")
                    || k.starts_with("AZURE_")
                    || k.starts_with("OBJECT_STORE_")
            });
            // Pre-signed Azure blob URLs (e.g. Microsoft Planetary Computer
            // assets) carry their only credential in the query string. Re-home
            // that token into the store config as a SAS key (see azure_sas_opt).
            let sas_opt = azure_sas_opt(&url);
            // `extra_opts` are the GDAL-named knobs the R layer translated to
            // object_store keys (endpoints, no-sign flags, account name -- never
            // secrets). They go FIRST so a natively-named env var of the same key
            // wins on conflict: `parse_url_opts` applies options in order, last
            // write wins (object_store-0.13.2 parse.rs builder_opts!).
            //
            // The URL SAS goes LAST so the asset-specific token embedded in the
            // URL wins over any ambient AZURE_STORAGE_SAS_KEY env var: the
            // pre-signed token is scoped to this exact blob and is what the
            // caller fetched for it. A full account key in the environment
            // (AZURE_STORAGE_ACCOUNT_KEY) still takes precedence regardless of
            // ordering -- the Azure builder checks access keys before SAS keys.
            let opts = extra_opts
                .iter()
                .cloned()
                .chain(env_opts)
                .chain(sas_opt);
            let (store, path) = object_store::parse_url_opts(&url, opts)
                .map_err(|e| KirkError::Invalid(format!("parse_url: {e}")))?;
            return Ok((Arc::from(store), path));
        }
    }
    let p = std::path::Path::new(src);
    if !p.exists() {
        return Err(KirkError::Invalid(format!("file not found: {src}")));
    }
    let abs = p.canonicalize()?;
    let parent = abs
        .parent()
        .unwrap_or_else(|| std::path::Path::new("/"))
        .to_path_buf();
    let fname = abs
        .file_name()
        .ok_or_else(|| KirkError::Invalid("path has no file name".into()))?
        .to_string_lossy()
        .to_string();
    let lfs = object_store::local::LocalFileSystem::new_with_prefix(parent)?;
    let store: Arc<dyn ObjectStore> = Arc::new(lfs);
    let path = ObjPath::from(fname.as_str());
    Ok((store, path))
}

/// Detect a pre-signed Azure blob URL and return the object_store option that
/// re-homes its SAS query string into the store config.
///
/// Microsoft Planetary Computer (and any Azure shared-access-signature) asset
/// is an https URL of the form
/// `https://<account>.blob.core.windows.net/<container>/<path>?<SAS>`, where the
/// `<SAS>` query string is the *only* credential. `object_store` recognises the
/// blob host and builds a `MicrosoftAzure` store, but `parse_url_opts` derives
/// the `Path` from `url.path()` alone -- the query is dropped -- and the store
/// then runs the Azure credential chain, hitting the IMDS managed-identity
/// endpoint and timing out. Supplying the query as `azure_storage_sas_key`
/// (object_store-0.13.2 `AzureConfigKey::SasKey`) makes the store sign every
/// request with that token and skip the managed-identity chain. The blob path
/// (sans query) still becomes the `Path`, so the token is never sent twice.
///
/// Returns `None` for anything that is not a signed Azure blob/dfs URL, leaving
/// the normal pathway untouched: a plain public https COG, an Azure host with
/// no signature (anonymous public blob), or a native `s3://`/`az://` source.
///
/// Scope: Azure SAS only. AWS S3 (`X-Amz-Signature`) and GCS signed URLs are
/// NOT handled -- object_store offers no query-passthrough for those stores, so
/// a pre-signed S3/GCS URL would need a raw-HTTP reader or per-provider
/// handling.
// TODO: support pre-signed AWS S3 / GCS URLs if a caller needs them.
fn azure_sas_opt(url: &url::Url) -> Option<(String, String)> {
    if url.scheme() != "https" {
        return None;
    }
    let host = url.host_str()?;
    let is_azure_blob = host.ends_with(".blob.core.windows.net")
        || host.ends_with(".dfs.core.windows.net");
    if !is_azure_blob {
        return None;
    }
    // A SAS always carries a signature (`sig=`). Without one this is not a
    // pre-signed URL and must take the normal (anonymous/credential-chain) path.
    let query = url.query()?;
    if !query.split('&').any(|kv| kv.starts_with("sig=")) {
        return None;
    }
    Some(("azure_storage_sas_key".to_string(), query.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(u: &str) -> url::Url {
        url::Url::parse(u).unwrap()
    }

    #[test]
    fn detects_presigned_azure_blob() {
        let url = parse(
            "https://acct.blob.core.windows.net/cont/path/file.tif\
             ?st=2024-01-01T00%3A00%3A00Z&se=2024-01-02T00%3A00%3A00Z&sp=r&sig=abc%2Bdef",
        );
        let (key, val) = azure_sas_opt(&url).expect("signed Azure URL should yield a SAS opt");
        assert_eq!(key, "azure_storage_sas_key");
        // The full query string (no leading `?`) is forwarded verbatim.
        assert_eq!(val, url.query().unwrap());
        assert!(val.contains("sig=abc%2Bdef"));
    }

    #[test]
    fn detects_presigned_azure_dfs() {
        let url = parse("https://acct.dfs.core.windows.net/cont/file.tif?sp=r&sig=zzz");
        assert!(azure_sas_opt(&url).is_some());
    }

    #[test]
    fn ignores_public_https_cog() {
        // Plain public COG with no query -> normal HTTP pathway, no SAS opt.
        let url = parse("https://data.source.coop/org/dataset/file.tif");
        assert!(azure_sas_opt(&url).is_none());
    }

    #[test]
    fn ignores_azure_blob_without_signature() {
        // Azure host but no `sig=` (anonymous public blob) -> no SAS opt.
        let url = parse("https://acct.blob.core.windows.net/cont/file.tif?comp=list");
        assert!(azure_sas_opt(&url).is_none());
    }

    #[test]
    fn ignores_non_azure_and_native_schemes() {
        assert!(azure_sas_opt(&parse("s3://bucket/key.tif")).is_none());
        assert!(azure_sas_opt(&parse("az://container/key.tif?sig=zzz")).is_none());
        // A look-alike host that is not an Azure blob endpoint.
        assert!(azure_sas_opt(&parse("https://evil.com/blob.core.windows.net?sig=zzz")).is_none());
    }

    #[test]
    fn detects_presigned_obs_s3v2() {
        // Huawei OBS / S3 V2: AccessKeyId + Expires + Signature in the query.
        let url = parse(
            "https://bucket.obs.cn-south-222.ai.pcl.cn:443/path/file.tif\
             ?AccessKeyId=AK123&Expires=1782746226&Signature=abc%3D",
        );
        assert!(is_presigned_http(&url));
    }

    #[test]
    fn detects_presigned_s3v4_and_gcs() {
        assert!(is_presigned_http(&parse(
            "https://bucket.s3.amazonaws.com/key.tif?X-Amz-Signature=deadbeef&X-Amz-Expires=3600"
        )));
        assert!(is_presigned_http(&parse(
            "https://storage.googleapis.com/bucket/key.tif?X-Goog-Signature=deadbeef"
        )));
    }

    #[test]
    fn presigned_http_ignores_unsigned_and_native() {
        // Plain public COG, no query.
        assert!(!is_presigned_http(&parse(
            "https://data.source.coop/org/dataset/file.tif"
        )));
        // S3-style host but no signature in the query.
        assert!(!is_presigned_http(&parse(
            "https://bucket.s3.amazonaws.com/key.tif?versionId=42"
        )));
        // Native schemes are never routed through the raw-HTTP reader.
        assert!(!is_presigned_http(&parse("s3://bucket/key.tif")));
        assert!(!is_presigned_http(&parse("az://container/key.tif")));
        // Azure SAS stays on the native Azure (object_store) pathway.
        assert!(!is_presigned_http(&parse(
            "https://acct.blob.core.windows.net/cont/file.tif?sp=r&sig=zzz"
        )));
    }

    /// End-to-end read of a real MPC-signed COG. Ignored by default: it needs
    /// network and a *fresh* signed URL (SAS tokens expire), supplied via the
    /// `CPTKIRK_TEST_AZURE_SAS_URL` env var. Obtain one from the Planetary
    /// Computer SAS API or, in R:
    ///   `vrtility::stac_query(... collection = "hls2-s30" ...)` then
    ///   `rstac::assets_url()`.
    /// Run with:
    ///   CPTKIRK_TEST_AZURE_SAS_URL='https://...blob.core.windows.net/...?...sig=...' \
    ///     cargo test --manifest-path src/rust/Cargo.toml -- --ignored azure_sas
    #[test]
    #[ignore = "network + fresh SAS URL via CPTKIRK_TEST_AZURE_SAS_URL"]
    fn azure_sas_window_reads() {
        let src = std::env::var("CPTKIRK_TEST_AZURE_SAS_URL")
            .expect("set CPTKIRK_TEST_AZURE_SAS_URL to a fresh MPC-signed COG URL");
        let rt = crate::runtime::shared_runtime().unwrap();
        let win = rt.block_on(async {
            let open = crate::window::open_tiff(&src, &[]).await?;
            // Top overview, small window -- enough to prove auth + tile decode.
            crate::window::fetch_window(&open, 0, 0, 0, 16, 16, &[], f64::NAN, 4).await
        });
        let win = win.expect("signed COG window should read");
        assert_eq!(win.xsize, 16);
        assert_eq!(win.ysize, 16);
        assert!(win.n_bands >= 1);
    }

    /// End-to-end read of a real pre-signed Huawei OBS COG via the raw-HTTP
    /// reader. Ignored by default: needs network and a *fresh* signed URL
    /// (OBS signatures expire), supplied via `CPTKIRK_TEST_OBS_SIGNED_URL`.
    /// Obtain one in R via iearthdata:
    ///   `esd_query(bbox, years = 2024, signed = TRUE)$url` (vsicurl = FALSE).
    /// Run with:
    ///   CPTKIRK_TEST_OBS_SIGNED_URL='https://...obs...?AccessKeyId=...&Signature=...' \
    ///     cargo test --manifest-path src/rust/Cargo.toml -- --ignored obs_signed
    #[test]
    #[ignore = "network + fresh signed URL via CPTKIRK_TEST_OBS_SIGNED_URL"]
    fn obs_signed_window_reads() {
        let src = std::env::var("CPTKIRK_TEST_OBS_SIGNED_URL")
            .expect("set CPTKIRK_TEST_OBS_SIGNED_URL to a fresh signed OBS COG URL");
        let rt = crate::runtime::shared_runtime().unwrap();
        let win = rt.block_on(async {
            let open = crate::window::open_tiff(&src, &[]).await?;
            crate::window::fetch_window(&open, 0, 0, 0, 16, 16, &[], f64::NAN, 4).await
        });
        let win = win.expect("signed OBS COG window should read");
        assert_eq!(win.xsize, 16);
        assert_eq!(win.ysize, 16);
        assert!(win.n_bands >= 1);
    }
}
