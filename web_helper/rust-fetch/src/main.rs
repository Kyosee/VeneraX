//! venera-fetch: tiny HTTP sidecar that performs upstream HTTP requests on
//! behalf of the Node.js `web_helper`. Lives at 127.0.0.1:9876 inside the
//! container. Node calls POST /proxy with a JSON envelope; we pass the call
//! through reqwest+rustls and stream the upstream response back.
//!
//! Why: browser fetch() and Node's native fetch() cannot reproduce the app's
//! request path and headers. Several comic sources (CopyManga in particular)
//! ban cookies that arrive with a suspicious fingerprint. The sidecar defaults
//! to HTTP/1.1, which is closer to the current Dart HttpClient-based app path,
//! and reports diagnostics back to Node for verification.

use std::collections::HashMap;
use std::time::Duration;

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use bytes::Bytes;
use serde::Deserialize;
use tracing_subscriber::EnvFilter;

const DEFAULT_PROXY_BODY_LIMIT_BYTES: usize = 256 * 1024 * 1024;

#[derive(Clone)]
struct AppState {
    client: reqwest::Client,
    http_mode: String,
}

#[derive(Deserialize)]
struct ProxyRequest {
    url: String,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: Option<HashMap<String, String>>,
    /// base64-encoded bytes; null/missing means no body
    #[serde(default)]
    body_b64: Option<String>,
    /// follow redirects (default true). When false the upstream's 3xx is
    /// returned untouched so Node can inspect Location.
    #[serde(default = "default_true")]
    follow_redirects: bool,
}

fn default_true() -> bool {
    true
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let http_mode = std::env::var("VENERA_FETCH_HTTP_VERSION")
        .unwrap_or_else(|_| "http1".to_string())
        .to_lowercase();
    let http_mode = if http_mode == "auto" { "auto" } else { "http1" }.to_string();

    let client = build_client(reqwest::redirect::Policy::limited(5), &http_mode)?;

    let state = AppState { client, http_mode };
    let proxy_body_limit = proxy_body_limit_bytes();

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/proxy", post(proxy_handler))
        .with_state(state)
        .layer(DefaultBodyLimit::max(proxy_body_limit));

    let port: u16 = std::env::var("VENERA_FETCH_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(9876);
    let bind = std::env::var("VENERA_FETCH_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    let addr = format!("{}:{}", bind, port);

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(
        proxy_body_limit_bytes = proxy_body_limit,
        "venera-fetch listening on {}",
        addr
    );
    axum::serve(listener, app).await?;
    Ok(())
}

fn proxy_body_limit_bytes() -> usize {
    std::env::var("VENERA_FETCH_PROXY_BODY_LIMIT_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .and_then(|mb| mb.checked_mul(1024 * 1024))
        .filter(|bytes| *bytes > 0)
        .unwrap_or(DEFAULT_PROXY_BODY_LIMIT_BYTES)
}

async fn proxy_handler(
    State(state): State<AppState>,
    Json(req): Json<ProxyRequest>,
) -> Result<axum::response::Response, axum::response::Response> {
    let method = req
        .method
        .as_deref()
        .unwrap_or("GET")
        .to_uppercase()
        .parse::<Method>()
        .map_err(|e| error_response(StatusCode::BAD_REQUEST, &format!("Invalid method: {}", e)))?;

    let url = reqwest::Url::parse(&req.url).map_err(|e| {
        error_response(StatusCode::BAD_REQUEST, &format!("Invalid URL: {}", e))
    })?;

    let scheme = url.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(error_response(
            StatusCode::BAD_REQUEST,
            "Only http(s) URLs are allowed",
        ));
    }

    // Build the per-request client if redirect policy diverges from default.
    // The cheap fast-path is the shared client; only opt out if needed.
    let response = if req.follow_redirects {
        send_with_client(&state.client, method, url, req.headers, req.body_b64).await
    } else {
        let one_shot = build_client(reqwest::redirect::Policy::none(), &state.http_mode)
            .map_err(|e| error_response(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()))?;
        send_with_client(&one_shot, method, url, req.headers, req.body_b64).await
    };

    let upstream = response
        .map_err(|e| error_response(StatusCode::BAD_GATEWAY, &format!("Upstream error: {}", e)))?;

    let status = upstream.status();
    let upstream_version = format!("{:?}", upstream.version());

    // Collect headers, hoist set-cookie out into a single base64-JSON header
    // so Node sees the full multi-cookie list intact.
    let mut response_headers = HeaderMap::new();
    let mut set_cookies: Vec<String> = Vec::new();

    for (name, value) in upstream.headers() {
        let name_str = name.as_str();
        // Drop framing headers — reqwest has already decompressed and the
        // axum response will emit its own length / framing.
        if matches!(
            name_str,
            "content-encoding" | "content-length" | "transfer-encoding"
        ) {
            continue;
        }
        if name_str.eq_ignore_ascii_case("set-cookie") {
            if let Ok(s) = value.to_str() {
                set_cookies.push(s.to_string());
            }
            continue;
        }
        if let Ok(v) = HeaderValue::from_bytes(value.as_bytes()) {
            response_headers.insert(name.clone(), v);
        }
    }

    if !set_cookies.is_empty() {
        if let Ok(json) = serde_json::to_string(&set_cookies) {
            let encoded = base64::engine::general_purpose::STANDARD.encode(json.as_bytes());
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_static("x-upstream-set-cookie").try_into(),
                HeaderValue::from_str(&encoded),
            ) {
                let _: HeaderName = name;
                response_headers.insert(
                    HeaderName::from_static("x-upstream-set-cookie"),
                    value,
                );
            }
        }
    }

    response_headers.insert(
        HeaderName::from_static("x-venera-sidecar"),
        HeaderValue::from_static(if state.http_mode == "auto" {
            "reqwest-rustls-auto"
        } else {
            "reqwest-rustls-http1"
        }),
    );
    if let Ok(value) = HeaderValue::from_str(&upstream_version) {
        response_headers.insert(HeaderName::from_static("x-venera-upstream-version"), value);
    }

    // Stream the body straight through to the caller — avoids buffering large
    // images in memory.
    let body_stream = upstream.bytes_stream();
    let body = Body::from_stream(body_stream);

    let mut builder = axum::response::Response::builder().status(status);
    for (k, v) in response_headers.iter() {
        builder = builder.header(k.clone(), v.clone());
    }
    Ok(builder
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()))
}

fn build_client(
    redirect_policy: reqwest::redirect::Policy,
    http_mode: &str,
) -> anyhow::Result<reqwest::Client> {
    let mut builder = reqwest::Client::builder()
        .redirect(redirect_policy)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(60))
        .pool_idle_timeout(Duration::from_secs(60))
        .use_rustls_tls()
        // No cookie management here — Node's web_helper has its own jar.
        // (cookies feature is not enabled, so jar is disabled by default.)
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36");

    if http_mode != "auto" {
        builder = builder.http1_only();
    }

    Ok(builder.build()?)
}

async fn send_with_client(
    client: &reqwest::Client,
    method: Method,
    url: reqwest::Url,
    headers: Option<HashMap<String, String>>,
    body_b64: Option<String>,
) -> reqwest::Result<reqwest::Response> {
    let mut request = client.request(method, url);

    if let Some(map) = headers {
        let mut hm = reqwest::header::HeaderMap::new();
        for (k, v) in map {
            if let (Ok(name), Ok(value)) = (
                k.parse::<reqwest::header::HeaderName>(),
                reqwest::header::HeaderValue::from_str(&v),
            ) {
                hm.insert(name, value);
            }
        }
        request = request.headers(hm);
    }

    if let Some(b64) = body_b64 {
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64.as_bytes()) {
            request = request.body(Bytes::from(bytes));
        }
    }

    request.send().await
}

fn error_response(status: StatusCode, message: &str) -> axum::response::Response {
    let body = serde_json::json!({ "error": message });
    let mut resp = (status, Json(body)).into_response();
    resp.headers_mut().insert(
        axum::http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    resp
}
