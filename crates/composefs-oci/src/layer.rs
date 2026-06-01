//! Shared layer import logic for OCI container images.
//!
//! This module provides common functionality for importing OCI image layers
//! into a composefs repository, shared between the skopeo proxy path and
//! direct OCI layout import.

use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::task::{Context, Poll};

use anyhow::{Result, bail};
use async_compression::tokio::bufread::{GzipDecoder, ZstdDecoder};
use containers_image_proxy::oci_spec::image::MediaType;
use tokio::io::{AsyncRead, AsyncWriteExt, BufReader, ReadBuf};

use composefs::fsverity::FsVerityHashValue;
use composefs::repository::{ObjectStoreMethod, Repository};
use composefs::shared_internals::IO_BUF_CAPACITY;

use crate::skopeo::TAR_LAYER_CONTENT_TYPE;
use crate::tar::split_async;

/// Debug wrapper that counts bytes passing through a reader.
struct ByteCountingReader<R> {
    inner: R,
    count: Arc<AtomicU64>,
    label: &'static str,
}

impl<R: AsyncRead + Unpin> AsyncRead for ByteCountingReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &result {
            let n = buf.filled().len() - before;
            if n == 0 {
                let total = self.count.load(Ordering::Relaxed);
                eprintln!("[ByteCountingReader:{}] EOF after {} bytes total", self.label, total);
            } else {
                self.count.fetch_add(n as u64, Ordering::Relaxed);
            }
        }
        result
    }
}

/// Check if a media type represents a tar-based layer.
pub fn is_tar_media_type(media_type: &MediaType) -> bool {
    matches!(
        media_type,
        MediaType::ImageLayer
            | MediaType::ImageLayerGzip
            | MediaType::ImageLayerZstd
            | MediaType::ImageLayerNonDistributable
            | MediaType::ImageLayerNonDistributableGzip
            | MediaType::ImageLayerNonDistributableZstd
    )
}

/// Wrap an async reader with the appropriate decompressor for the media type.
///
/// Returns a boxed reader that decompresses the stream if needed.
/// The output is `AsyncRead` (not `AsyncBufRead`) because `split_async`
/// does its own buffering via `BytesMut`.
pub fn decompress_async<'a, R>(
    reader: R,
    media_type: &MediaType,
) -> Result<Box<dyn AsyncRead + Unpin + Send + 'a>>
where
    R: AsyncRead + Unpin + Send + 'a,
{
    let counted_input = ByteCountingReader {
        inner: reader,
        count: Arc::new(AtomicU64::new(0)),
        label: "compressed-input",
    };
    let buf = BufReader::new(counted_input);
    let reader: Box<dyn AsyncRead + Unpin + Send> = match media_type {
        MediaType::ImageLayer | MediaType::ImageLayerNonDistributable => {
            Box::new(BufReader::with_capacity(IO_BUF_CAPACITY, buf))
        }
        MediaType::ImageLayerGzip | MediaType::ImageLayerNonDistributableGzip => {
            let mut decoder = GzipDecoder::new(buf);
            decoder.multiple_members(true);
            Box::new(BufReader::with_capacity(IO_BUF_CAPACITY, decoder))
        }
        MediaType::ImageLayerZstd | MediaType::ImageLayerNonDistributableZstd => {
            let mut decoder = ZstdDecoder::new(buf);
            decoder.multiple_members(true);
            Box::new(BufReader::with_capacity(IO_BUF_CAPACITY, decoder))
        }
        _ => bail!("Unsupported layer media type for decompression: {media_type}"),
    };
    Ok(reader)
}

/// Import a tar layer from an async reader into the repository.
///
/// The reader should already be decompressed (use `decompress_async` first).
/// Returns the fs-verity object ID and import stats of the imported splitstream.
pub async fn import_tar_async<ObjectID, R>(
    repo: Arc<Repository<ObjectID>>,
    reader: R,
) -> Result<(ObjectID, crate::ImportStats)>
where
    ObjectID: FsVerityHashValue,
    R: AsyncRead + Unpin + Send,
{
    let counted = ByteCountingReader {
        inner: reader,
        count: Arc::new(AtomicU64::new(0)),
        label: "decompressed",
    };
    split_async(counted, repo, TAR_LAYER_CONTENT_TYPE).await
}

/// Store raw bytes from an async reader as a repository object.
///
/// Streams the raw bytes into a repository object without creating a splitstream.
/// Use this for non-tar blobs (OCI artifacts) where the caller will create
/// the splitstream wrapper.
///
/// Returns (object_id, size, store_method) of the stored object.
pub async fn store_blob_async<ObjectID, R>(
    repo: &Repository<ObjectID>,
    mut reader: R,
) -> Result<(ObjectID, u64, ObjectStoreMethod)>
where
    ObjectID: FsVerityHashValue,
    R: AsyncRead + Unpin,
{
    let tmpfile = repo.create_object_tmpfile()?;
    let mut writer = tokio::fs::File::from(std::fs::File::from(tmpfile));
    let size = tokio::io::copy(&mut reader, &mut writer).await?;
    writer.flush().await?;
    let tmpfile = writer.into_std().await;
    let (object_id, method) = repo.finalize_object_tmpfile(tmpfile, size)?;
    Ok((object_id, size, method))
}
