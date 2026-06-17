//! Shared tokio runtime.
//!
//! A single multi-thread runtime built once on first use and reused for the
//! lifetime of the package. Worker threads drive I/O futures that yield; the
//! CPU-heavy tile decode runs in `spawn_blocking` (a separate pool).

use std::sync::OnceLock;
use tokio::runtime::Runtime;

use crate::error::{KirkError, Result};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub(crate) fn shared_runtime() -> Result<&'static Runtime> {
    if let Some(rt) = RUNTIME.get() {
        return Ok(rt);
    }
    // Race on init is fine: the loser of `set` discards its Runtime via Drop.
    let rt = Runtime::new()
        .map_err(|e| KirkError::Internal(format!("tokio runtime build: {e}")))?;
    Ok(RUNTIME.get_or_init(|| rt))
}
