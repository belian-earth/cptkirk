//! Error type for cptkirk's remote-read + warp staging layer.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum KirkError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("object_store error: {0}")]
    ObjectStore(#[from] object_store::Error),

    #[error("async-tiff error: {0}")]
    Tiff(#[from] async_tiff::error::AsyncTiffError),

    #[error("missing geokey: {0}")]
    MissingGeoKey(&'static str),

    #[error("unsupported configuration: {0}")]
    Unsupported(String),

    #[error("invalid input: {0}")]
    Invalid(String),

    #[error("internal error: {0}")]
    Internal(String),

    #[error("worker task failed: {0}")]
    WorkerJoin(String),

    #[error("url parse error: {0}")]
    Url(#[from] url::ParseError),
}

pub type Result<T> = std::result::Result<T, KirkError>;
