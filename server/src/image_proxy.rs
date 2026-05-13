use std::{path::PathBuf, time::Duration};

use base64::{engine::general_purpose::STANDARD, Engine};
use percent_encoding::percent_decode_str;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::{fs, process::Command, time::timeout};

use crate::{
    config::AppConfig,
    error::{ApiError, ApiResult},
};

const MAX_IMAGE_BYTES: usize = 15 * 1024 * 1024;

pub struct ImagePayload {
    pub bytes: Vec<u8>,
    pub content_type: String,
    pub cache_status: &'static str,
}

#[derive(Deserialize)]
struct FetchEnvelope {
    ok: bool,
    content_type: Option<String>,
    error: Option<String>,
}

pub async fn load_image(config: &AppConfig, raw_url: &str) -> ApiResult<ImagePayload> {
    let url = raw_url.trim();
    if url.is_empty() {
        return Err(ApiError::BadRequest(
            "image url cannot be empty".to_string(),
        ));
    }

    if let Some(payload) = read_cache(config, url).await? {
        return Ok(payload);
    }

    if url.starts_with("data:") {
        let (bytes, content_type) = decode_data_url(url)?;
        if bytes.len() > MAX_IMAGE_BYTES {
            return Err(ApiError::ImageProxy("image is too large".to_string()));
        }
        write_cache(config, url, &bytes, &content_type).await?;
        return Ok(ImagePayload {
            bytes,
            content_type,
            cache_status: "miss",
        });
    }

    fetch_remote_image(config, url).await
}

async fn fetch_remote_image(config: &AppConfig, raw_url: &str) -> ApiResult<ImagePayload> {
    if !raw_url.starts_with("http://") && !raw_url.starts_with("https://") {
        return Err(ApiError::BadRequest(
            "image url must use http or https".to_string(),
        ));
    }

    let (image_path, type_path) = cache_paths(config, raw_url);
    if let Some(parent) = image_path.parent() {
        fs::create_dir_all(parent).await?;
    }

    let mut command = Command::new(&config.node_bin);
    command
        .arg(config.runtime_dir.join("image-fetcher.mjs"))
        .arg(raw_url)
        .arg(&image_path)
        .arg(&type_path);

    let output = match timeout(Duration::from_secs(30), command.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(err)) => return Err(ApiError::ImageProxy(err.to_string())),
        Err(_) => return Ok(placeholder_image_payload("image fetch timed out")),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        return Ok(placeholder_image_payload(&runtime_error(&stdout, &stderr)));
    }

    let envelope: FetchEnvelope = serde_json::from_str(stdout.trim())
        .map_err(|err| ApiError::ImageProxy(format!("invalid image fetch response: {err}")))?;
    if !envelope.ok {
        return Ok(placeholder_image_payload(
            &envelope
                .error
                .unwrap_or_else(|| "image fetch failed".to_string()),
        ));
    }

    let bytes = fs::read(&image_path).await?;
    if bytes.len() > MAX_IMAGE_BYTES {
        return Ok(placeholder_image_payload("image is too large"));
    }
    let sniffed_content_type = sniff_content_type(&bytes);
    if sniffed_content_type.is_none() {
        return Ok(placeholder_image_payload(
            "upstream did not return an image",
        ));
    }
    let content_type = envelope
        .content_type
        .filter(|value| is_image_content_type(value))
        .or_else(|| sniffed_content_type.map(str::to_string))
        .unwrap_or_else(|| "image/svg+xml".to_string());

    Ok(ImagePayload {
        bytes,
        content_type,
        cache_status: "miss",
    })
}

fn decode_data_url(raw_url: &str) -> ApiResult<(Vec<u8>, String)> {
    let body = raw_url
        .strip_prefix("data:")
        .ok_or_else(|| ApiError::BadRequest("invalid data image url".to_string()))?;
    let (metadata, data) = body
        .split_once(',')
        .ok_or_else(|| ApiError::BadRequest("invalid data image url".to_string()))?;
    let mut parts = metadata.split(';');
    let content_type = normalize_content_type(parts.next().unwrap_or("image/png"));
    if !is_image_content_type(&content_type) {
        return Err(ApiError::BadRequest(
            "data url must contain an image".to_string(),
        ));
    }
    let is_base64 = parts.any(|part| part.eq_ignore_ascii_case("base64"));
    let bytes = if is_base64 {
        STANDARD
            .decode(data.as_bytes())
            .map_err(|_| ApiError::BadRequest("invalid base64 image data".to_string()))?
    } else {
        percent_decode_str(data).collect()
    };

    Ok((bytes, content_type))
}

async fn read_cache(config: &AppConfig, raw_url: &str) -> ApiResult<Option<ImagePayload>> {
    let (image_path, type_path) = cache_paths(config, raw_url);
    if fs::metadata(&image_path).await.is_err() {
        return Ok(None);
    }

    let bytes = fs::read(&image_path).await?;
    let content_type = fs::read_to_string(&type_path)
        .await
        .unwrap_or_else(|_| "application/octet-stream".to_string())
        .trim()
        .to_string();
    let content_type = if is_image_content_type(&content_type) {
        content_type
    } else {
        sniff_content_type(&bytes)
            .unwrap_or("application/octet-stream")
            .to_string()
    };

    Ok(Some(ImagePayload {
        bytes,
        content_type,
        cache_status: "hit",
    }))
}

async fn write_cache(
    config: &AppConfig,
    raw_url: &str,
    bytes: &[u8],
    content_type: &str,
) -> ApiResult<()> {
    let (image_path, type_path) = cache_paths(config, raw_url);
    if let Some(parent) = image_path.parent() {
        fs::create_dir_all(parent).await?;
    }
    fs::write(image_path, bytes).await?;
    fs::write(type_path, content_type).await?;
    Ok(())
}

fn cache_paths(config: &AppConfig, raw_url: &str) -> (PathBuf, PathBuf) {
    let key = cache_key(raw_url);
    let dir = config.cache_dir().join("images");
    (dir.join(&key), dir.join(format!("{key}.content-type")))
}

fn cache_key(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    format!("{digest:x}")
}

fn normalize_content_type(value: &str) -> String {
    value
        .split(';')
        .next()
        .unwrap_or("application/octet-stream")
        .trim()
        .to_ascii_lowercase()
}

fn is_image_content_type(value: &str) -> bool {
    value.starts_with("image/")
}

fn sniff_content_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" && bytes[8..].windows(4).any(|w| w == b"avif") {
        return Some("image/avif");
    }

    let sample = String::from_utf8_lossy(&bytes[..bytes.len().min(256)]).to_ascii_lowercase();
    if sample.contains("<svg") {
        return Some("image/svg+xml");
    }

    None
}

fn runtime_error(stdout: &str, stderr: &str) -> String {
    let stdout = stdout.trim();
    let stderr = stderr.trim();
    if !stderr.is_empty() {
        stderr.to_string()
    } else if !stdout.is_empty() {
        stdout.to_string()
    } else {
        "image fetch failed".to_string()
    }
}

fn placeholder_image_payload(reason: &str) -> ImagePayload {
    let escaped = escape_svg_text(reason);
    let svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="320" viewBox="0 0 240 320">
<rect width="240" height="320" rx="16" fill="#30354a"/>
<path d="M88 132h64v48H88z" fill="none" stroke="#9b96ff" stroke-width="8" stroke-linejoin="round"/>
<path d="M96 168l18-22 20 24 11-14 7 10" fill="none" stroke="#9b96ff" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
<circle cx="145" cy="144" r="6" fill="#9b96ff"/>
<text x="120" y="218" text-anchor="middle" fill="#a8adbc" font-family="Arial, sans-serif" font-size="14">cover unavailable</text>
<title>{escaped}</title>
</svg>"##
    );
    ImagePayload {
        bytes: svg.into_bytes(),
        content_type: "image/svg+xml".to_string(),
        cache_status: "fallback",
    }
}

fn escape_svg_text(value: &str) -> String {
    value
        .chars()
        .take(160)
        .flat_map(|ch| match ch {
            '&' => "&amp;".chars().collect::<Vec<_>>(),
            '<' => "&lt;".chars().collect::<Vec<_>>(),
            '>' => "&gt;".chars().collect::<Vec<_>>(),
            '"' => "&quot;".chars().collect::<Vec<_>>(),
            '\'' => "&#39;".chars().collect::<Vec<_>>(),
            _ => vec![ch],
        })
        .collect()
}
