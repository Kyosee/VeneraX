<?php
/**
 * Venera PWA same-origin proxy.
 *
 * Modes:
 * - Query passthrough: proxy.php?url=<target>, forwards current HTTP method.
 * - JSON RPC: POST proxy.php with {url, method, headers, data, bytes}.
 *
 * JSON mode is used by the Flutter Web runtime for source requests and WebDAV.
 */

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, PROPFIND, MKCOL, MOVE, COPY, OPTIONS');
header('Access-Control-Allow-Headers: Authorization, Content-Type, Depth, Accept, User-Agent, Referer, Cookie, X-Requested-With, Range, If-Match, If-None-Match, Destination, Overwrite');
header('Access-Control-Expose-Headers: Content-Type, Content-Length, Content-Disposition, Set-Cookie, ETag, Last-Modified, Location');
header('Access-Control-Max-Age: 86400');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

function fail_json($status, $message) {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error' => $message], JSON_UNESCAPED_UNICODE);
    exit;
}

function is_valid_target($url) {
    return is_string($url) && preg_match('#^https?://#i', $url);
}

function incoming_headers_map() {
    $incoming = [];
    if (function_exists('apache_request_headers')) {
        $incoming = apache_request_headers();
    } elseif (function_exists('getallheaders')) {
        $incoming = getallheaders();
    } else {
        foreach ($_SERVER as $key => $value) {
            if (strpos($key, 'HTTP_') === 0) {
                $name = str_replace('_', '-', substr($key, 5));
                $incoming[$name] = $value;
            }
        }
        if (isset($_SERVER['CONTENT_TYPE'])) {
            $incoming['Content-Type'] = $_SERVER['CONTENT_TYPE'];
        }
    }

    $normalized = [];
    foreach ($incoming as $k => $v) {
        $normalized[strtolower($k)] = $v;
    }
    if (empty($normalized['authorization']) && !empty($_SERVER['REDIRECT_HTTP_AUTHORIZATION'])) {
        $normalized['authorization'] = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'];
    }
    if (empty($normalized['authorization']) && !empty($_SERVER['HTTP_AUTHORIZATION'])) {
        $normalized['authorization'] = $_SERVER['HTTP_AUTHORIZATION'];
    }
    return $normalized;
}

function normalize_forward_headers($headers) {
    $allowed = [
        'authorization' => 'Authorization',
        'content-type' => 'Content-Type',
        'depth' => 'Depth',
        'accept' => 'Accept',
        'user-agent' => 'User-Agent',
        'referer' => 'Referer',
        'cookie' => 'Cookie',
        'range' => 'Range',
        'if-match' => 'If-Match',
        'if-none-match' => 'If-None-Match',
        'destination' => 'Destination',
        'overwrite' => 'Overwrite',
    ];
    $result = [];
    foreach (($headers ?: []) as $key => $value) {
        if ($value === null || $value === '') {
            continue;
        }
        $lower = strtolower((string)$key);
        if (!array_key_exists($lower, $allowed)) {
            continue;
        }
        if (is_array($value)) {
            $value = implode(', ', $value);
        }
        $result[] = $allowed[$lower] . ': ' . (string)$value;
    }
    return $result;
}

function headers_from_current_request() {
    $incoming = incoming_headers_map();
    $forward = [];
    foreach (['authorization', 'content-type', 'depth', 'accept', 'user-agent', 'referer', 'cookie'] as $key) {
        if (!empty($incoming[$key])) {
            $forward[$key] = $incoming[$key];
        }
    }
    return $forward;
}

function parse_response_headers($rawHeaders) {
    $headers = [];
    foreach (explode("\r\n", $rawHeaders) as $line) {
        if (!strpos($line, ':')) {
            continue;
        }
        [$name, $value] = explode(':', $line, 2);
        $name = trim($name);
        $value = trim($value);
        if ($name === '') {
            continue;
        }
        $lower = strtolower($name);
        if (isset($headers[$lower])) {
            $headers[$lower] .= ', ' . $value;
        } else {
            $headers[$lower] = $value;
        }
    }
    return $headers;
}

function run_proxy_request($targetUrl, $method, $headers, $body) {
    if (!function_exists('curl_init')) {
        fail_json(500, 'PHP cURL extension is required for Venera proxy');
    }

    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $targetUrl);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
    curl_setopt($ch, CURLOPT_TIMEOUT, 90);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 15);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_HEADER, true);
    curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);

    if ($body !== null && !in_array($method, ['GET', 'HEAD'], true)) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $forwardHeaders = normalize_forward_headers($headers);
    if (!empty($forwardHeaders)) {
        curl_setopt($ch, CURLOPT_HTTPHEADER, $forwardHeaders);
    }

    $response = curl_exec($ch);
    if ($response === false) {
        $error = curl_error($ch);
        $errno = curl_errno($ch);
        curl_close($ch);
        fail_json(502, "Proxy cURL failed ($errno): $error");
    }

    $status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $headerSize = curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);

    return [
        'status' => $status,
        'headersRaw' => substr($response, 0, $headerSize),
        'body' => substr($response, $headerSize),
    ];
}

function request_payload_body($payload) {
    if (!array_key_exists('data', $payload) || $payload['data'] === null) {
        return null;
    }
    $data = $payload['data'];
    if (is_array($data) && ($data['type'] ?? '') === 'base64') {
        $decoded = base64_decode((string)($data['value'] ?? ''), true);
        if ($decoded === false) {
            fail_json(400, 'Invalid base64 request body');
        }
        return $decoded;
    }
    if (is_string($data)) {
        return $data;
    }
    return json_encode($data, JSON_UNESCAPED_UNICODE);
}

function handle_json_mode($rawBody) {
    $payload = json_decode($rawBody, true);
    if (!is_array($payload)) {
        fail_json(400, 'Invalid JSON proxy payload');
    }

    $targetUrl = $payload['url'] ?? '';
    if (!is_valid_target($targetUrl)) {
        fail_json(400, 'Invalid URL scheme');
    }

    $method = strtoupper((string)($payload['method'] ?? $payload['http_method'] ?? 'GET'));
    $headers = is_array($payload['headers'] ?? null) ? $payload['headers'] : [];
    $body = request_payload_body($payload);
    $res = run_proxy_request($targetUrl, $method, $headers, $body);
    $headers = parse_response_headers($res['headersRaw']);

    http_response_code(200);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode([
        'status' => $res['status'],
        'headers' => $headers,
        'body' => !empty($payload['bytes']) ? null : $res['body'],
        'bodyBase64' => !empty($payload['bytes']) ? base64_encode($res['body']) : null,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

$rawBody = file_get_contents('php://input');
$contentType = $_SERVER['CONTENT_TYPE'] ?? $_SERVER['HTTP_CONTENT_TYPE'] ?? '';
$isJsonMode = $_SERVER['REQUEST_METHOD'] === 'POST'
    && empty($_GET['url'])
    && stripos($contentType, 'application/json') !== false;

if ($isJsonMode) {
    handle_json_mode($rawBody ?: '{}');
}

$targetUrl = $_GET['url'] ?? '';
if (!is_valid_target($targetUrl)) {
    fail_json(400, 'Missing or invalid "url" parameter');
}

$method = strtoupper($_SERVER['REQUEST_METHOD']);
$body = in_array($method, ['POST', 'PUT', 'PATCH', 'PROPFIND', 'MKCOL'], true) ? $rawBody : null;
$res = run_proxy_request($targetUrl, $method, headers_from_current_request(), $body);

http_response_code($res['status']);
foreach (explode("\r\n", $res['headersRaw']) as $line) {
    if (preg_match('/^(Content-Type|Content-Disposition|Content-Length|Set-Cookie|ETag|Last-Modified|Location):\s*(.+)$/i', $line, $m)) {
        header("$m[1]: $m[2]", false);
    }
}
echo $res['body'];
