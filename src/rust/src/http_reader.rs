//! Raw-HTTP range reader for pre-signed URLs.
//!
//! `object_store` routes a plain `https://` URL to its `HttpStore`, whose `Path`
//! model has no query component. The credential carried in a pre-signed URL's
//! query string is therefore dropped and the request goes out unsigned:
//!   * Huawei OBS / S3 V2: `AccessKeyId` + `Expires` + `Signature`
//!   * AWS S3 V4 (and MinIO, ...): `X-Amz-Signature`
//!   * GCS V4 signed URL: `X-Goog-Signature`
//!
//! This reader keeps the full URL verbatim (query included) and issues only
//! ranged GETs. It never sends a HEAD: method-specific pre-signed URLs (OBS
//! signs for GET only) reject HEAD with 403, which is also why iearthdata wraps
//! them in GDAL's `/vsicurl?use_head=no&url=...`. The signature thus travels
//! with every byte-range request. The URL (and its embedded token) is never
//! logged.
//!
//! ## Multi-range coalescing
//!
//! A planar multi-band tile is read as one byte-range per band plane, so
//! `get_byte_ranges` is called with many scattered ranges. The default trait
//! implementation fetches them sequentially -- one round-trip each -- which is
//! ruinous on a high-latency HTTP/1.1 store (OBS has no HTTP/2 multiplexing).
//! Instead we issue a single `Range: bytes=a-b,c-d,...` request and parse the
//! `multipart/byteranges` response: N round-trips collapse to one, over a single
//! connection. If the server does not honour multi-range (returns `200` for the
//! whole object, or a single `206` range) we fall back to bounded-concurrent
//! single-range requests. The `200` case is detected from the status line before
//! the body is read, so a non-cooperating server never triggers a whole-file
//! download.

use std::collections::HashMap;
use std::ops::Range;

use async_tiff::error::{AsyncTiffError, AsyncTiffResult};
use async_tiff::reader::AsyncFileReader;
use async_trait::async_trait;
use bytes::Bytes;
use futures::{stream, StreamExt, TryStreamExt};

/// Cap on concurrent single-range requests in the fallback path, so a server
/// that ignores multi-range cannot trigger an unbounded connection storm over
/// HTTP/1.1 (one TCP+TLS handshake per connection).
const FALLBACK_MAX_INFLIGHT: usize = 8;

/// An [`AsyncFileReader`] that GETs byte ranges from one fixed pre-signed URL.
#[derive(Debug, Clone)]
pub(crate) struct SignedHttpReader {
    client: reqwest::Client,
    url: reqwest::Url,
}

/// Build the reqwest client used for pre-signed range reads. Timeouts ensure a
/// stalled server/connection fails instead of hanging forever -- the R consumer
/// drains via a blocking recv that does not poll R interrupts, so an unbounded
/// hang there is uninterruptible.
pub(crate) fn build_http_client() -> reqwest::Result<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(30))
        .timeout(std::time::Duration::from_secs(300))
        .build()
}

impl SignedHttpReader {
    pub(crate) fn new(url: reqwest::Url) -> AsyncTiffResult<Self> {
        let client = build_http_client().map_err(|e| AsyncTiffError::External(Box::new(e)))?;
        Ok(Self { client, url })
    }

    /// Construct from a shared client so many readers reuse one connection pool.
    pub(crate) fn with_client(client: reqwest::Client, url: reqwest::Url) -> Self {
        Self { client, url }
    }

    /// Send a `Range:` GET and return the response (after a 2xx status check).
    async fn range_request(&self, header: String) -> AsyncTiffResult<reqwest::Response> {
        self.client
            .get(self.url.clone())
            .header(reqwest::header::RANGE, header)
            .send()
            .await
            .map_err(|e| AsyncTiffError::External(Box::new(e)))?
            .error_for_status()
            .map_err(|e| AsyncTiffError::External(Box::new(e)))
    }

    /// Fetch all `ranges` in a single `multipart/byteranges` request.
    ///
    /// Returns `Ok(None)` when the server did not honour the multi-range request
    /// -- a `200` (whole object), a single non-multipart `206`, or a body that
    /// cannot be mapped back onto every requested range -- signalling the caller
    /// to fall back. In the `200` case the body is never read (the status is
    /// checked first), so the full object is not downloaded.
    async fn try_multirange(&self, ranges: &[Range<u64>]) -> AsyncTiffResult<Option<Vec<Bytes>>> {
        // An empty range would underflow `r.end - 1`; fall back to per-range
        // (which handles empties) rather than emit a malformed multi-range spec.
        if ranges.iter().any(|r| r.end <= r.start) {
            return Ok(None);
        }
        let spec = ranges
            .iter()
            .map(|r| format!("{}-{}", r.start, r.end - 1))
            .collect::<Vec<_>>()
            .join(",");
        let resp = self.range_request(format!("bytes={spec}")).await?;

        if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
            return Ok(None); // 200 etc.: Range ignored -- do not read the body.
        }
        let boundary = match resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(parse_multipart_boundary)
        {
            Some(b) => b,
            None => return Ok(None), // 206 single range, not multipart.
        };
        let body = resp
            .bytes()
            .await
            .map_err(|e| AsyncTiffError::External(Box::new(e)))?;
        Ok(parse_byteranges(&body, boundary.as_bytes(), ranges))
    }

    /// Fallback: fetch each range as its own request, bounded concurrency,
    /// preserving input order.
    async fn fetch_concurrent(&self, ranges: Vec<Range<u64>>) -> AsyncTiffResult<Vec<Bytes>> {
        stream::iter(ranges.into_iter().map(|r| self.get_bytes(r)))
            .buffered(FALLBACK_MAX_INFLIGHT)
            .try_collect()
            .await
    }
}

#[async_trait]
impl AsyncFileReader for SignedHttpReader {
    async fn get_bytes(&self, range: Range<u64>) -> AsyncTiffResult<Bytes> {
        // Empty range (e.g. a sparse COG tile with byte_count 0): no request, and
        // avoid `range.end - 1` underflowing to a bogus `bytes=start-u64::MAX`.
        if range.end <= range.start {
            return Ok(Bytes::new());
        }
        // HTTP byte ranges are inclusive; async-tiff's range end is exclusive.
        let resp = self
            .range_request(format!("bytes={}-{}", range.start, range.end - 1))
            .await?;
        resp.bytes()
            .await
            .map_err(|e| AsyncTiffError::External(Box::new(e)))
    }

    async fn get_byte_ranges(&self, ranges: Vec<Range<u64>>) -> AsyncTiffResult<Vec<Bytes>> {
        match ranges.len() {
            0 => Ok(Vec::new()),
            1 => Ok(vec![self.get_bytes(ranges.into_iter().next().unwrap()).await?]),
            _ => {
                // A server may reject a long multi-range header (e.g. 400/416);
                // treat any multi-range failure as "not honoured" and fall back
                // to bounded per-range requests rather than failing the read.
                if let Ok(Some(parts)) = self.try_multirange(&ranges).await {
                    return Ok(parts);
                }
                self.fetch_concurrent(ranges).await
            }
        }
    }
}

/// Extract the boundary token from a `multipart/byteranges` Content-Type value
/// (`multipart/byteranges; boundary=XXXX`, value optionally quoted). Returns
/// `None` for any other content type, including a single-range `Content-Range`.
fn parse_multipart_boundary(content_type: &str) -> Option<String> {
    let ct = content_type.trim();
    if !ct
        .to_ascii_lowercase()
        .starts_with("multipart/byteranges")
    {
        return None;
    }
    for param in ct.split(';').skip(1) {
        let param = param.trim();
        if param.len() > 9 && param[..9].eq_ignore_ascii_case("boundary=") {
            let val = param[9..].trim().trim_matches('"');
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

/// Parse a `multipart/byteranges` body into one `Bytes` per requested range,
/// ordered to match `ranges` (each part is matched to a request by its
/// `Content-Range` start offset). Each part is length-delimited via its
/// `Content-Range`, so binary tile data that happens to contain the boundary
/// bytes is not mis-split. Returns `None` on any anomaly so the caller falls
/// back to individual requests.
fn parse_byteranges(body: &Bytes, boundary: &[u8], ranges: &[Range<u64>]) -> Option<Vec<Bytes>> {
    let mut delim = Vec::with_capacity(boundary.len() + 2);
    delim.extend_from_slice(b"--");
    delim.extend_from_slice(boundary);

    let mut by_start: HashMap<u64, Bytes> = HashMap::with_capacity(ranges.len());
    let mut pos = find(body, &delim, 0)?; // first boundary
    loop {
        pos += delim.len();
        if body.get(pos..pos + 2) == Some(b"--") {
            break; // closing "--<boundary>--"
        }
        pos = skip_crlf(body, pos);
        let hdr_end = find(body, b"\r\n\r\n", pos)?;
        let (start, end) = parse_content_range(&body[pos..hdr_end])?;
        let len = end.checked_sub(start)?.checked_add(1)? as usize;
        let data_start = hdr_end + 4;
        let data_end = data_start.checked_add(len)?;
        if data_end > body.len() {
            return None;
        }
        by_start.insert(start, body.slice(data_start..data_end));
        pos = find(body, &delim, data_end)?;
    }

    let mut out = Vec::with_capacity(ranges.len());
    for r in ranges {
        out.push(by_start.get(&r.start)?.clone());
    }
    Some(out)
}

/// First index of `needle` in `hay` at or after `from`.
fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > hay.len() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|i| from + i)
}

fn skip_crlf(body: &[u8], pos: usize) -> usize {
    if body.get(pos..pos + 2) == Some(b"\r\n") {
        pos + 2
    } else {
        pos
    }
}

/// Parse the `<start>` and `<end>` (inclusive) from a part's
/// `Content-Range: bytes <start>-<end>/<total>` header block.
fn parse_content_range(headers: &[u8]) -> Option<(u64, u64)> {
    let text = std::str::from_utf8(headers).ok()?;
    for line in text.split("\r\n") {
        let line = line.trim();
        if line.len() >= 13 && line[..13].eq_ignore_ascii_case("content-range") {
            let value = line.split_once(':')?.1.trim();
            let spec = value.strip_prefix("bytes").unwrap_or(value).trim();
            let range_part = spec.split('/').next()?.trim();
            let mut it = range_part.split('-');
            let start = it.next()?.trim().parse::<u64>().ok()?;
            let end = it.next()?.trim().parse::<u64>().ok()?;
            return Some((start, end));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boundary_parsing() {
        assert_eq!(
            parse_multipart_boundary("multipart/byteranges; boundary=abc123"),
            Some("abc123".to_string())
        );
        // Quoted value, mixed case, extra params.
        assert_eq!(
            parse_multipart_boundary("Multipart/ByteRanges; charset=x; BOUNDARY=\"a-b-c\""),
            Some("a-b-c".to_string())
        );
        // Single-range responses are not multipart.
        assert_eq!(parse_multipart_boundary("application/octet-stream"), None);
        assert_eq!(parse_multipart_boundary("multipart/byteranges"), None); // no boundary
    }

    #[test]
    fn content_range_parsing() {
        assert_eq!(
            parse_content_range(b"Content-Type: application/octet-stream\r\nContent-Range: bytes 200-299/12345"),
            Some((200, 299))
        );
        assert_eq!(parse_content_range(b"content-range:bytes 0-3/10"), Some((0, 3)));
        assert_eq!(parse_content_range(b"Content-Type: x"), None);
    }

    fn multipart_body(boundary: &str, parts: &[(u64, u64, &[u8])]) -> Bytes {
        let mut b = Vec::new();
        for (start, end, data) in parts {
            b.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
            b.extend_from_slice(b"Content-Type: application/octet-stream\r\n");
            b.extend_from_slice(format!("Content-Range: bytes {start}-{end}/100000\r\n\r\n").as_bytes());
            b.extend_from_slice(data);
            b.extend_from_slice(b"\r\n");
        }
        b.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
        Bytes::from(b)
    }

    #[test]
    fn byteranges_in_request_order() {
        let body = multipart_body("B0", &[(0, 3, b"AAAA"), (200, 203, b"BBBB")]);
        let got = parse_byteranges(&body, b"B0", &[0..4, 200..204]).unwrap();
        assert_eq!(got, vec![Bytes::from_static(b"AAAA"), Bytes::from_static(b"BBBB")]);
    }

    #[test]
    fn byteranges_reordered_to_match_request() {
        // Server returns parts in file order; output must follow request order.
        let body = multipart_body("B0", &[(0, 3, b"AAAA"), (200, 203, b"BBBB")]);
        let got = parse_byteranges(&body, b"B0", &[200..204, 0..4]).unwrap();
        assert_eq!(got, vec![Bytes::from_static(b"BBBB"), Bytes::from_static(b"AAAA")]);
    }

    #[test]
    fn byteranges_missing_part_falls_back() {
        // Body lacks the second requested range -> None (caller falls back).
        let body = multipart_body("B0", &[(0, 3, b"AAAA")]);
        assert!(parse_byteranges(&body, b"B0", &[0..4, 200..204]).is_none());
    }

    #[test]
    fn byteranges_binary_data_containing_boundary() {
        // Part payload contains the delimiter bytes; length-delimited parsing
        // must still recover it intact (not split on the embedded boundary).
        let payload = b"--B0\r\nstuff"; // 11 bytes that look like a boundary
        let body = multipart_body("B0", &[(0, (payload.len() - 1) as u64, payload)]);
        let got = parse_byteranges(&body, b"B0", &[0..payload.len() as u64]).unwrap();
        assert_eq!(got, vec![Bytes::copy_from_slice(payload)]);
    }
}
