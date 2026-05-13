use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;

#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("state error: {0}")]
    State(String),
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("source runtime error: {0}")]
    SourceRuntime(String),
    #[error("image proxy error: {0}")]
    ImageProxy(String),
    #[error("webdav error: {0}")]
    WebDav(String),
    #[error("import preview error: {0}")]
    ImportPreview(String),
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self {
            ApiError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ApiError::SourceRuntime(_) | ApiError::ImageProxy(_) | ApiError::WebDav(_) => {
                StatusCode::BAD_GATEWAY
            }
            ApiError::ImportPreview(_) => StatusCode::BAD_REQUEST,
            ApiError::Database(_) | ApiError::Io(_) | ApiError::State(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };

        let body = Json(ErrorBody {
            error: self.to_string(),
        });

        (status, body).into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
