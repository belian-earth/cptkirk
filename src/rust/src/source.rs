//! Source string -> object_store dispatch.
//!
//! Ported from a5px. A URL with a scheme longer than one character is handed
//! to `object_store::parse_url` (covers http(s)://, s3://, gs://, az://).
//! Anything else is treated as a local path. Single-letter "schemes" are
//! skipped so Windows drive-letter paths (`d:/foo.tif`) take the local branch.

use std::sync::Arc;

use object_store::path::Path as ObjPath;
use object_store::ObjectStore;

use crate::error::{KirkError, Result};

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
            // `extra_opts` are the GDAL-named knobs the R layer translated to
            // object_store keys (endpoints, no-sign flags, account name -- never
            // secrets). They go FIRST so a natively-named env var of the same key
            // wins on conflict: `parse_url_opts` applies options in order, last
            // write wins (object_store-0.13.2 parse.rs builder_opts!).
            let opts = extra_opts.iter().cloned().chain(env_opts);
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
