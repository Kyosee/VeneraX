import { createDecipheriv, createHash, createHmac, randomUUID } from "node:crypto";
import { createGzip, deflateRawSync, inflateRawSync } from "node:zlib";
import { DatabaseSync } from "node:sqlite";
import vm from "node:vm";
import { parse as parseHtml } from "node-html-parser";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { URL } from "node:url";

const defaultProxyUserAgent =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";
const maxImageBytes = 15 * 1024 * 1024;
const defaultImageAccept =
  "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";

const canonicalForwardHeaders = new Map([
  ["authorization", "Authorization"],
  ["content-type", "Content-Type"],
  ["depth", "Depth"],
  ["accept", "Accept"],
  ["accept-language", "Accept-Language"],
  ["user-agent", "User-Agent"],
  ["referer", "Referer"],
  ["origin", "Origin"],
  ["cookie", "Cookie"],
  ["range", "Range"],
  ["if-match", "If-Match"],
  ["if-none-match", "If-None-Match"],
  ["destination", "Destination"],
  ["overwrite", "Overwrite"],
]);

const blockedForwardHeaders = new Set([
  "accept-charset",
  "accept-encoding",
  "access-control-request-headers",
  "access-control-request-method",
  "connection",
  "content-length",
  "date",
  "dnt",
  "expect",
  "host",
  "keep-alive",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "via",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-proto",
  "x-venera-cookie",
  "x-venera-forward-headers",
  "x-venera-origin",
  "x-venera-referer",
  "x-venera-user-agent",
]);

const blockedForwardHeaderPrefixes = ["proxy-", "sec-"];

const exposedResponseHeaders = new Set([
  "content-type",
  "content-length",
  "content-disposition",
  "set-cookie",
  "etag",
  "last-modified",
  "location",
]);

function cookieDefaultPath(urlText) {
  const pathname = new URL(urlText).pathname || "/";
  if (pathname === "/") return "/";
  const lastSlash = pathname.lastIndexOf("/");
  return lastSlash <= 0 ? "/" : pathname.slice(0, lastSlash);
}

function normalizeCookieDomain(value, fallbackHost) {
  const raw = String(value || fallbackHost || "").trim().replace(/^\./, "");
  return raw.toLowerCase();
}

function normalizeCookiePath(value, fallbackPath = "/") {
  const raw = String(value || fallbackPath || "/").trim();
  return raw.startsWith("/") ? raw : `/${raw}`;
}

function cookieKey(cookie) {
  return `${cookie.domain}\t${cookie.path}\t${cookie.name}`;
}

function parseSetCookie(setCookie, urlText) {
  const parts = String(setCookie || "").split(";").map((part) => part.trim());
  const firstPart = parts.shift() || "";
  const separator = firstPart.indexOf("=");
  if (separator <= 0) return null;
  const target = new URL(urlText);
  const cookie = {
    name: firstPart.slice(0, separator).trim(),
    value: firstPart.slice(separator + 1),
    domain: target.hostname.toLowerCase(),
    hostOnly: true,
    path: cookieDefaultPath(urlText),
    expires: null,
    maxAge: null,
    secure: false,
    httpOnly: false,
  };
  for (const part of parts) {
    const eq = part.indexOf("=");
    const attrName = (eq >= 0 ? part.slice(0, eq) : part).trim().toLowerCase();
    const attrValue = eq >= 0 ? part.slice(eq + 1).trim() : "";
    if (attrName === "domain") {
      cookie.domain = normalizeCookieDomain(attrValue, target.hostname);
      cookie.hostOnly = false;
    } else if (attrName === "path") {
      cookie.path = normalizeCookiePath(attrValue);
    } else if (attrName === "expires") {
      cookie.expires = attrValue;
    } else if (attrName === "max-age") {
      const maxAge = Number(attrValue);
      cookie.maxAge = Number.isFinite(maxAge) ? maxAge : null;
    } else if (attrName === "secure") {
      cookie.secure = true;
    } else if (attrName === "httponly") {
      cookie.httpOnly = true;
    }
  }
  return cookie.name ? cookie : null;
}

function normalizeCookieInput(input, urlText) {
  if (!input?.name) return null;
  const target = new URL(urlText);
  const hasDomain = input.domain != null && String(input.domain).trim() !== "";
  const cookie = {
    name: String(input.name),
    value: String(input.value ?? ""),
    domain: normalizeCookieDomain(input.domain, target.hostname),
    hostOnly: input.hostOnly == null ? !hasDomain : !!input.hostOnly,
    path: normalizeCookiePath(input.path, "/"),
    expires: input.expires == null ? null : String(input.expires),
    maxAge:
      input.maxAge == null && input["max-age"] == null
        ? null
        : Number(input.maxAge ?? input["max-age"]),
    secure: !!input.secure,
    httpOnly: !!input.httpOnly,
  };
  if (!Number.isFinite(cookie.maxAge)) cookie.maxAge = null;
  return cookie;
}

function isExpiredCookie(cookie) {
  if (cookie.maxAge != null && Number(cookie.maxAge) <= 0) return true;
  if (!cookie.expires) return false;
  const numericExpires = Number(cookie.expires);
  if (Number.isFinite(numericExpires)) {
    if (numericExpires <= 0) return false;
    return numericExpires * 1000 <= Date.now();
  }
  const expiresAt = Date.parse(cookie.expires);
  return Number.isFinite(expiresAt) && expiresAt <= Date.now();
}

function cookieDomainMatches(cookie, host) {
  const normalizedHost = host.toLowerCase();
  const domain = normalizeCookieDomain(cookie.domain, normalizedHost);
  if (cookie.hostOnly) return normalizedHost === domain;
  return normalizedHost === domain || normalizedHost.endsWith(`.${domain}`);
}

function cookiePathMatches(cookiePath, requestPath) {
  const normalizedCookiePath = normalizeCookiePath(cookiePath);
  const normalizedRequestPath = normalizeCookiePath(requestPath || "/");
  if (normalizedCookiePath === "/") return true;
  if (normalizedRequestPath === normalizedCookiePath) return true;
  return (
    normalizedRequestPath.startsWith(normalizedCookiePath) &&
    normalizedCookiePath.endsWith("/")
  ) || normalizedRequestPath.startsWith(`${normalizedCookiePath}/`);
}

function cookieMatchesUrl(cookie, urlText) {
  if (!cookie?.name || isExpiredCookie(cookie)) return false;
  const url = new URL(urlText);
  if (cookie.secure && url.protocol !== "https:") return false;
  return (
    cookieDomainMatches(cookie, url.hostname) &&
    cookiePathMatches(cookie.path, url.pathname || "/")
  );
}

function cookiesForUrl(cookieJar, urlText) {
  return Array.from(cookieJar.values())
    .filter((cookie) => cookieMatchesUrl(cookie, urlText))
    .sort((a, b) => String(b.path || "/").length - String(a.path || "/").length);
}

function publicCookie(cookie) {
  return {
    name: String(cookie.name),
    value: String(cookie.value ?? ""),
  };
}

function cookieExpiresMs(cookie) {
  if (cookie.maxAge != null && Number.isFinite(Number(cookie.maxAge))) {
    return Date.now() + Number(cookie.maxAge) * 1000;
  }
  if (!cookie.expires) return null;
  const numericExpires = Number(cookie.expires);
  if (Number.isFinite(numericExpires)) {
    if (numericExpires <= 0) return null;
    return numericExpires > 1000000000000
      ? Math.floor(numericExpires)
      : Math.floor(numericExpires * 1000);
  }
  const parsed = Date.parse(cookie.expires);
  return Number.isFinite(parsed) ? parsed : null;
}

function publicCookieRecord(cookie) {
  return {
    name: String(cookie.name),
    value: String(cookie.value ?? ""),
    domain: cookie.hostOnly ? cookie.domain : `.${cookie.domain}`,
    path: cookie.path || "/",
    expiresMs: cookieExpiresMs(cookie),
    secure: !!cookie.secure,
    httpOnly: !!cookie.httpOnly,
    hostOnly: !!cookie.hostOnly,
  };
}

function getCookieHeader(cookieJar, urlText) {
  return cookiesForUrl(cookieJar, urlText)
    .map((cookie) => `${cookie.name}=${cookie.value}`)
    .join("; ");
}

function cookieNamesFromHeader(value) {
  return String(value || "")
    .split(";")
    .map((part) => part.trim().split("=")[0])
    .filter(Boolean);
}

function mergeCookieHeader(requestCookieHeader, helperCookieHeader) {
  const requestCookie = String(requestCookieHeader || "").trim();
  const helperCookie = String(helperCookieHeader || "").trim();
  if (requestCookie && helperCookie) {
    return `${requestCookie}; ${helperCookie}`;
  }
  return requestCookie || helperCookie || "";
}

function redactProxyUrl(urlText) {
  try {
    const url = new URL(urlText);
    return `${url.origin}${url.pathname}${url.search ? "?..." : ""}`;
  } catch {
    return "";
  }
}

function shortHash(value) {
  const raw = String(value || "");
  if (!raw) return "";
  return createHash("sha256").update(raw).digest("hex").slice(0, 12);
}

function headerPreview(value) {
  const raw = String(value || "");
  if (!raw) return "";
  return raw.length > 120 ? `${raw.slice(0, 120)}...` : raw;
}

function proxyRequestDiagnostics(headers, response = null) {
  const userAgent = headerValue(headers, "user-agent") || "";
  return {
    userAgent: headerPreview(userAgent),
    userAgentSha256: shortHash(userAgent),
    hasReferer: !!headerValue(headers, "referer"),
    hasOrigin: !!headerValue(headers, "origin"),
    sidecar: response?.headers?.get?.("x-venera-sidecar") || "",
    upstreamHttpVersion:
      response?.headers?.get?.("x-venera-upstream-version") || "",
  };
}

function createProxyRequestRecorder(limit = 80) {
  const entries = [];
  return {
    push(entry) {
      entries.unshift({
        at: new Date().toISOString(),
        ...entry,
      });
      entries.splice(limit);
    },
    list() {
      return entries;
    },
    clear() {
      entries.splice(0);
    },
  };
}

function importCookies(cookieJar, urlText, cookies, persistCookieJar = () => {}) {
  let changed = false;
  for (const cookie of cookies || []) {
    const normalized = normalizeCookieInput(cookie, urlText);
    if (!normalized) continue;
    const key = cookieKey(normalized);
    if (isExpiredCookie(normalized)) {
      changed = cookieJar.delete(key) || changed;
    } else {
      cookieJar.set(key, normalized);
      changed = true;
    }
  }
  if (changed) persistCookieJar();
  return exportCookies(cookieJar, urlText);
}

function exportCookies(cookieJar, urlText) {
  return cookiesForUrl(cookieJar, urlText).map(publicCookie);
}

function normalizeCookieRecord(input) {
  if (!input?.name || !input?.domain) return null;
  const rawDomain = String(input.domain || "").trim();
  const expiresMs = Number(input.expiresMs);
  const cookie = {
    name: String(input.name),
    value: String(input.value ?? ""),
    domain: normalizeCookieDomain(rawDomain, ""),
    hostOnly: input.hostOnly == null ? !rawDomain.startsWith(".") : !!input.hostOnly,
    path: normalizeCookiePath(input.path, "/"),
    expires: Number.isFinite(expiresMs) && expiresMs > 0
      ? String(Math.floor(expiresMs / 1000))
      : input.expires == null
        ? null
        : String(input.expires),
    maxAge: null,
    secure: input.secure === true || input.secure === 1 || input.secure === "1",
    httpOnly:
      input.httpOnly === true || input.httpOnly === 1 || input.httpOnly === "1",
  };
  return cookie.domain ? cookie : null;
}

function importCookieRecords(cookieJar, cookies, persistCookieJar = () => {}) {
  let changed = false;
  for (const input of cookies || []) {
    const normalized = normalizeCookieRecord(input);
    if (!normalized) continue;
    const key = cookieKey(normalized);
    if (isExpiredCookie(normalized)) {
      changed = cookieJar.delete(key) || changed;
    } else {
      cookieJar.set(key, normalized);
      changed = true;
    }
  }
  if (changed) persistCookieJar();
  return Array.from(cookieJar.values())
    .filter((cookie) => !isExpiredCookie(cookie))
    .map(publicCookieRecord);
}

function exportCookieRecords(cookieJar) {
  return Array.from(cookieJar.values())
    .filter((cookie) => !isExpiredCookie(cookie))
    .map(publicCookieRecord);
}

function deleteCookiesForUrl(cookieJar, urlText, persistCookieJar = () => {}) {
  let changed = false;
  for (const [key, cookie] of cookieJar.entries()) {
    if (cookieMatchesUrl(cookie, urlText)) {
      cookieJar.delete(key);
      changed = true;
    }
  }
  if (changed) persistCookieJar();
}

function storeResponseCookies(cookieJar, urlText, response, persistCookieJar) {
  const setCookies = response.headers.getSetCookie?.() || [];
  const fallback = response.headers.get("set-cookie");
  if (fallback && setCookies.length === 0) setCookies.push(fallback);
  const cookies = setCookies
    .flatMap((value) => String(value).split(/,(?=\s*[^;,=\s]+=)/g))
    .map((value) => parseSetCookie(value, urlText))
    .filter(Boolean);
  if (cookies.length > 0) importCookies(cookieJar, urlText, cookies, persistCookieJar);
}

function loadCookieJar(cookieJarPath) {
  const cookieJar = new Map();
  if (!cookieJarPath || !existsSync(cookieJarPath)) return cookieJar;
  try {
    const raw = JSON.parse(readFileSync(cookieJarPath, "utf8"));
    for (const cookie of Array.isArray(raw?.cookies) ? raw.cookies : []) {
      const normalized = normalizeCookieInput(cookie, `https://${cookie.domain || "localhost"}/`);
      if (!normalized || isExpiredCookie(normalized)) continue;
      normalized.hostOnly = cookie.hostOnly == null ? normalized.hostOnly : !!cookie.hostOnly;
      cookieJar.set(cookieKey(normalized), normalized);
    }
  } catch (error) {
    console.warn(`Failed to load helper cookie jar: ${error.message || error}`);
  }
  return cookieJar;
}

function createCookieJarPersistor(cookieJar, cookieJarPath) {
  if (!cookieJarPath) return () => {};
  return () => {
    mkdirSync(dirname(cookieJarPath), { recursive: true });
    const cookies = Array.from(cookieJar.values()).filter(
      (cookie) => !isExpiredCookie(cookie),
    );
    writeFileSync(cookieJarPath, JSON.stringify({ cookies }, null, 2));
  };
}

function sanitizeSessionId(value) {
  const raw = String(value || "").trim();
  const normalized = raw.replace(/[^a-zA-Z0-9_.-]/g, "_").slice(0, 80);
  return normalized || `session-${randomUUID()}`;
}

function requestOrigin(req) {
  const proto = req.headers["x-forwarded-proto"] || "http";
  const host = req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1";
  return `${String(proto).split(",")[0]}://${String(host).split(",")[0]}`;
}

function makeBrowserViewUrl(req, sessionId) {
  return `${requestOrigin(req)}/browser/session/${encodeURIComponent(sessionId)}/view`;
}

function cookiesForTargetUrl(urlText, cookies) {
  return (cookies || [])
    .map((cookie) => normalizeCookieInput(cookie, urlText))
    .filter((cookie) => cookie && cookieMatchesUrl(cookie, urlText));
}

function syncBrowserCookies(cookieJar, targetUrl, state, persistCookieJar = () => {}) {
  if (!isValidTarget(targetUrl)) return [];
  const cookies = cookiesForTargetUrl(targetUrl, state.cookies || []);
  if (cookies.length === 0) return [];
  return importCookies(cookieJar, targetUrl, cookies, persistCookieJar);
}

function statePayload(req, sessionId, state, syncedCookies = []) {
  return {
    ok: true,
    sessionId,
    state,
    syncedCookies,
    viewUrl: makeBrowserViewUrl(req, sessionId),
  };
}

function isValidLoginImportCode(value) {
  return /^[a-zA-Z0-9_.-]{16,160}$/.test(String(value || ""));
}

function shortcutScriptForEndpoint(endpoint) {
  return `const veneraAlert = (message) => {
  try {
    alert(message);
  } catch (_) {}
};

const veneraFinish = (result, message) => {
  if (message) {
    veneraAlert(message);
  }
  completion(JSON.stringify(result, null, 2));
};

const collectStorage = (storage) => {
  const result = {};
  for (let i = 0; i < storage.length; i++) {
    const key = storage.key(i);
    result[key] = storage.getItem(key);
  }
  return result;
};

try {
  const payload = {
    url: location.href,
    userAgent: navigator.userAgent,
    cookie: document.cookie,
    localStorage: collectStorage(localStorage),
    sessionStorage: collectStorage(sessionStorage)
  };
  const endpoint = ${JSON.stringify(endpoint)};
  const summary = {
    url: payload.url,
    cookieLength: payload.cookie.length,
    localStorageKeys: Object.keys(payload.localStorage).length,
    sessionStorageKeys: Object.keys(payload.sessionStorage).length
  };
  fetch(endpoint, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(payload)
  })
    .then((response) => {
      const ok = response.ok;
      veneraFinish({
        ok,
        status: response.status,
        ...summary
      }, ok
        ? 'Venera login data sent. Return to Venera and tap Check.'
        : 'Venera import returned HTTP ' + response.status + '. Check helper address.');
    })
    .catch((error) => {
      veneraFinish({
        ok: false,
        error: String(error && error.message ? error.message : error),
        ...summary,
        payload
      }, 'Venera import failed. If CopyManga is HTTPS and helper is HTTP, use HTTPS for the Venera helper.');
    });
} catch (error) {
  veneraFinish({
    ok: false,
    error: String(error && error.message ? error.message : error)
  }, 'Venera script failed: ' + String(error && error.message ? error.message : error));
}
`;
}

/// Single-line `javascript:` URL the user can drag to Safari's bookmarks bar.
/// The bookmarklet collects the same payload as the iOS Shortcut script but
/// uses `alert` instead of Shortcut-specific `completion()` because it runs in
/// a regular browser context.
function bookmarkletJsForEndpoint(endpoint) {
  // Note: keep this template compact — bookmarklets in Safari have an effective
  // length limit. We avoid newlines inside the function body and use single
  // statements where possible. The whole thing is wrapped in an IIFE.
  const compact = `(function(){var ep=${JSON.stringify(endpoint)};function S(s){var r={};for(var i=0;i<s.length;i++){var k=s.key(i);r[k]=s.getItem(k);}return r;}var p={url:location.href,userAgent:navigator.userAgent,cookie:document.cookie,localStorage:S(localStorage),sessionStorage:S(sessionStorage)};fetch(ep,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p)}).then(function(r){alert(r.ok?'Venera 登录数据已发送，回到 app 点击「检查」':'导入失败：HTTP '+r.status);}).catch(function(e){alert('导入失败：'+(e&&e.message?e.message:e));});})();`;
  return `javascript:${encodeURIComponent(compact)}`;
}

function htmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function prefersChinese(req) {
  const acceptLanguage = String(req.headers["accept-language"] || "").toLowerCase();
  return acceptLanguage
    .split(",")
    .some((language) => language.trim().startsWith("zh"));
}

function helperUiText(req) {
  if (!prefersChinese(req)) {
    return {
      shortcutTitle: "Venera Shortcut JS",
      shortcutInstruction:
        'Copy all text below into the Shortcuts action named "Run JavaScript on Web Page". After that, enable the shortcut in the Safari share sheet.',
      copyScript: "Copy Script",
      selectAll: "Select All",
      selected: "Selected. Use Copy from the edit menu if needed.",
      copied: "Copied.",
      clipboardBlocked:
        "Clipboard was blocked. The script is selected; copy it manually.",
      browserTitle: "Venera Helper Browser",
      urlPlaceholder: "URL",
      go: "Go",
      textPlaceholder: "Type text",
      type: "Type",
      enter: "Enter",
      sync: "Sync",
      loading: "Loading...",
      screenAlt: "browser screenshot",
    };
  }
  return {
    shortcutTitle: "Venera 快捷指令 JS",
    shortcutInstruction:
      "复制下面的全部文本到快捷指令的“在网页上运行 JavaScript”操作中，然后在 Safari 共享表单中启用该快捷指令。",
    copyScript: "复制脚本",
    selectAll: "全选",
    selected: "已全选。如有需要，请从编辑菜单复制。",
    copied: "已复制。",
    clipboardBlocked: "剪贴板被阻止。脚本已选中，请手动复制。",
    browserTitle: "Venera Helper 浏览器",
    urlPlaceholder: "URL",
    go: "前往",
    textPlaceholder: "输入文字",
    type: "输入",
    enter: "回车",
    sync: "同步",
    loading: "正在加载...",
    screenAlt: "浏览器截图",
  };
}

function sendShortcutScriptPage(req, res, code) {
  const endpoint = `${requestOrigin(req)}/login-import/${encodeURIComponent(code)}`;
  const script = shortcutScriptForEndpoint(endpoint);
  const text = helperUiText(req);
  const shortcutMessages = JSON.stringify({
    selected: text.selected,
    copied: text.copied,
    clipboardBlocked: text.clipboardBlocked,
  });
  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${htmlEscape(text.shortcutTitle)}</title>
  <style>
    body { margin: 0; padding: 16px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f7f9; color: #111827; }
    main { max-width: 760px; margin: 0 auto; }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { font-size: 14px; line-height: 1.45; color: #4b5563; }
    textarea { width: 100%; min-height: 65vh; box-sizing: border-box; padding: 12px; border: 1px solid #cbd5e1; border-radius: 8px; font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: #fff; color: #111827; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0; }
    button { appearance: none; border: 0; border-radius: 8px; padding: 10px 14px; background: #2563eb; color: #fff; font-size: 15px; }
    button.secondary { background: #475569; }
    #status { min-height: 20px; color: #166534; }
  </style>
</head>
<body>
  <main>
    <h1>${htmlEscape(text.shortcutTitle)}</h1>
    <p>${htmlEscape(text.shortcutInstruction)}</p>
    <div class="actions">
      <button id="copy">${htmlEscape(text.copyScript)}</button>
      <button id="select" class="secondary">${htmlEscape(text.selectAll)}</button>
    </div>
    <p id="status"></p>
    <textarea id="script" readonly spellcheck="false">${htmlEscape(script)}</textarea>
  </main>
  <script>
    const shortcutMessages = ${shortcutMessages};
    const textarea = document.getElementById('script');
    const status = document.getElementById('status');
    const selectAll = () => {
      textarea.focus();
      textarea.select();
      textarea.setSelectionRange(0, textarea.value.length);
    };
    document.getElementById('select').addEventListener('click', () => {
      selectAll();
      status.textContent = shortcutMessages.selected;
    });
    document.getElementById('copy').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(textarea.value);
        status.textContent = shortcutMessages.copied;
      } catch (_) {
        selectAll();
        status.textContent = shortcutMessages.clipboardBlocked;
      }
    });
    selectAll();
  </script>
</body>
</html>`;
  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(html);
}

function sendBookmarkletPage(req, res, code) {
  const endpoint = `${requestOrigin(req)}/login-import/${encodeURIComponent(code)}`;
  const bookmarkletUrl = bookmarkletJsForEndpoint(endpoint);
  const isZh = prefersChinese(req);

  const labels = isZh
    ? {
        title: "Venera 一键导入",
        intro:
          "把下面的「Venera 导入」按钮长按拖到 Safari 收藏夹，登录漫画站后点该收藏即可同步登录信息到 app。",
        button: "Venera 导入",
        steps: [
          "1. 长按下方按钮，选「添加到收藏夹」（或拖到收藏栏）",
          "2. 在 Safari 打开漫画站并登录",
          "3. 点击书签栏里的「Venera 导入」",
          "4. 看到提示后回到 app 点「检查」",
        ],
        endpointLabel: "导入端点",
        warning:
          "注意：app 与本工具必须在同一网络。如果漫画站是 HTTPS，本工具也需要 HTTPS（否则浏览器会拦截）。",
      }
    : {
        title: "Venera Login Import",
        intro:
          "Long-press the button below and add it to Safari's bookmarks. Log in to the comic site, then tap the bookmark to sync.",
        button: "Venera Import",
        steps: [
          "1. Long-press the button → Add to Bookmarks (or drag it to the bookmarks bar)",
          "2. Open the comic site in Safari and log in",
          "3. Tap the 'Venera Import' bookmark",
          "4. Return to the app and tap 'Check' once you see the success alert",
        ],
        endpointLabel: "Import endpoint",
        warning:
          "Both devices must be on the same network. If the comic site uses HTTPS, this helper must also be served over HTTPS, otherwise Safari will block the request.",
      };

  const html = `<!doctype html>
<html lang="${isZh ? "zh-CN" : "en"}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>${htmlEscape(labels.title)}</title>
  <style>
    body { margin: 0; padding: 24px 16px; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif; background: #f6f7f9; color: #111827; min-height: 100vh; }
    main { max-width: 560px; margin: 0 auto; }
    h1 { font-size: 22px; margin: 0 0 12px; }
    p { font-size: 15px; line-height: 1.55; color: #374151; }
    .bookmarklet-wrap { display: flex; justify-content: center; padding: 28px 0; }
    .bookmarklet { display: inline-block; padding: 14px 28px; background: #2563eb; color: #fff; font-size: 17px; font-weight: 600; border-radius: 10px; text-decoration: none; box-shadow: 0 2px 8px rgba(37,99,235,0.25); user-select: none; -webkit-user-select: none; }
    .bookmarklet:active { transform: scale(0.97); }
    ol { padding-left: 24px; line-height: 1.8; font-size: 15px; }
    li { margin-bottom: 4px; }
    .warning { background: #fef3c7; border-left: 4px solid #f59e0b; padding: 12px 14px; border-radius: 6px; margin-top: 24px; font-size: 14px; line-height: 1.5; color: #78350f; }
    .endpoint { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; word-break: break-all; color: #6b7280; margin-top: 16px; }
    .endpoint b { display: block; margin-bottom: 4px; color: #111827; font-family: inherit; font-size: 13px; }
  </style>
</head>
<body>
  <main>
    <h1>${htmlEscape(labels.title)}</h1>
    <p>${htmlEscape(labels.intro)}</p>
    <div class="bookmarklet-wrap">
      <a class="bookmarklet" href="${htmlEscape(bookmarkletUrl)}">${htmlEscape(labels.button)}</a>
    </div>
    <ol>
      ${labels.steps.map((s) => `<li>${htmlEscape(s)}</li>`).join("\n      ")}
    </ol>
    <div class="warning">${htmlEscape(labels.warning)}</div>
    <div class="endpoint"><b>${htmlEscape(labels.endpointLabel)}</b>${htmlEscape(endpoint)}</div>
  </main>
</body>
</html>`;
  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(html);
}

async function handleLoginImportRoute({ req, res, parsedUrl, loginImports }) {
  const segments = parsedUrl.pathname.split("/").filter(Boolean);
  if (segments[0] !== "login-import") return false;
  const subPaths = new Set(["shortcut", "bookmarklet"]);
  const valid =
    isValidLoginImportCode(segments[1]) &&
    (segments.length === 2 ||
      (segments.length === 3 && subPaths.has(segments[2])));
  if (!valid) {
    sendJson(res, 404, { error: "Not found" });
    return true;
  }

  const code = segments[1];
  if (segments[2] === "shortcut") {
    if (req.method !== "GET") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    sendShortcutScriptPage(req, res, code);
    return true;
  }
  if (segments[2] === "bookmarklet") {
    if (req.method !== "GET") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    sendBookmarkletPage(req, res, code);
    return true;
  }

  if (req.method === "GET") {
    const entry = loginImports.get(code);
    if (!entry) {
      sendJson(res, 200, { ok: true, status: "pending" });
      return true;
    }
    sendJson(res, 200, {
      ok: true,
      status: "completed",
      receivedAt: entry.receivedAt,
      payload: entry.payload,
    });
    return true;
  }

  if (req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      sendJson(res, 400, { error: "Invalid login import payload" });
      return true;
    }
    const receivedAt = new Date().toISOString();
    loginImports.set(code, { payload, receivedAt });
    sendJson(res, 200, { ok: true, status: "completed", receivedAt });
    return true;
  }

  if (req.method === "DELETE") {
    loginImports.delete(code);
    sendJson(res, 200, { ok: true, status: "pending" });
    return true;
  }

  sendJson(res, 405, { error: "Method not allowed" });
  return true;
}

const MOBILE_BROWSER_UA =
  "Mozilla/5.0 (Linux; Android 14; Pixel 7) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 " +
  "Mobile Safari/537.36";

const DESKTOP_BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 " +
  "Safari/537.36";

function normalizeBrowserProfile(value) {
  const raw = String(value || process.env.VENERA_BROWSER_PROFILE || "mobile")
    .trim()
    .toLowerCase();
  return raw === "desktop" ? "desktop" : "mobile";
}

function envPositiveNumber(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function browserContextOptions(profile) {
  const resolvedProfile = normalizeBrowserProfile(profile);
  const mobile = resolvedProfile === "mobile";
  const options = {
    headless: process.env.VENERA_BROWSER_HEADLESS !== "false",
    viewport: {
      width: envPositiveNumber("VENERA_BROWSER_WIDTH", mobile ? 390 : 1280),
      height: envPositiveNumber("VENERA_BROWSER_HEIGHT", mobile ? 844 : 900),
    },
    userAgent:
      process.env.VENERA_BROWSER_UA ||
      (mobile ? MOBILE_BROWSER_UA : DESKTOP_BROWSER_UA),
    args: [
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-blink-features=AutomationControlled",
      "--disable-features=AutomationControlled",
      "--disable-infobars",
      "--disable-background-timer-throttling",
      "--disable-popup-blocking",
      "--disable-prompt-on-repost",
      "--no-first-run",
      "--no-default-browser-check",
      "--window-position=0,0",
    ],
    ignoreDefaultArgs: ["--enable-automation"],
  };
  if (mobile) {
    options.isMobile = true;
    options.hasTouch = true;
    options.deviceScaleFactor = envPositiveNumber(
      "VENERA_BROWSER_DEVICE_SCALE_FACTOR",
      3,
    );
  }
  return { profile: resolvedProfile, options };
}

async function dispatchBrowserClick(page, profile, x, y) {
  const clickX = Number(x);
  const clickY = Number(y);
  if (!Number.isFinite(clickX) || !Number.isFinite(clickY)) {
    throw new Error("Invalid browser click coordinates");
  }
  if (normalizeBrowserProfile(profile) === "mobile" && page.touchscreen?.tap) {
    try {
      await page.touchscreen.tap(clickX, clickY);
      return;
    } catch {}
  }
  await page.mouse.click(clickX, clickY);
}

export const __testHooks = {
  browserContextOptions,
  dispatchBrowserClick,
  prepareQueryProxyHeaders,
};

const STEALTH_INIT_SCRIPT = `
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

if (!window.chrome) { window.chrome = {}; }
if (!window.chrome.runtime) {
  window.chrome.runtime = {
    connect: function() {},
    sendMessage: function() {},
    onMessage: { addListener: function() {}, removeListener: function() {} },
    id: undefined,
  };
}

Object.defineProperty(navigator, 'plugins', {
  get: () => {
    const plugins = [
      { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer',
        description: 'Portable Document Format',
        length: 1, item: () => ({ type: 'application/x-google-chrome-pdf' }),
        0: { type: 'application/x-google-chrome-pdf' } },
      { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai',
        description: '', length: 1,
        item: () => ({ type: 'application/pdf' }),
        0: { type: 'application/pdf' } },
      { name: 'Native Client', filename: 'internal-nacl-plugin',
        description: '', length: 2,
        item: (i) => [{ type: 'application/x-nacl' },
                      { type: 'application/x-pnacl' }][i],
        0: { type: 'application/x-nacl' },
        1: { type: 'application/x-pnacl' } },
    ];
    plugins.refresh = () => {};
    return plugins;
  },
});

Object.defineProperty(navigator, 'languages', {
  get: () => ['zh-CN', 'zh', 'en-US', 'en'],
});

const originalQuery = window.navigator.permissions.query;
window.navigator.permissions.query = (parameters) =>
  parameters.name === 'notifications'
    ? Promise.resolve({ state: Notification.permission })
    : originalQuery(parameters);

(function() {
  const getParameter = WebGLRenderingContext.prototype.getParameter;
  WebGLRenderingContext.prototype.getParameter = function(param) {
    if (param === 37445) return 'Google Inc. (NVIDIA)';
    if (param === 37446) return 'ANGLE (NVIDIA, NVIDIA GeForce GTX 1650 Direct3D11 vs_5_0 ps_5_0, D3D11)';
    return getParameter.call(this, param);
  };
})();
`;

async function createPlaywrightBrowserFactory() {
  let playwright;
  try {
    playwright = await import("playwright");
  } catch (error) {
    const wrapped = new Error(
      `Playwright unavailable. Run npm install in web/server or use the Docker helper image. ${error.message}`,
    );
    wrapped.statusCode = 503;
    throw wrapped;
  }

  return {
    async createSession({ userDataDir, profile }) {
      mkdirSync(userDataDir, { recursive: true });
      const contextOptions = browserContextOptions(profile);
      const context = await playwright.chromium.launchPersistentContext(
        userDataDir,
        contextOptions.options,
      );
      await context.addInitScript(STEALTH_INIT_SCRIPT);
      const page = context.pages()[0] || (await context.newPage());
      page.setDefaultTimeout(Number(process.env.VENERA_BROWSER_TIMEOUT || 45000));

      return {
        async navigate(url, waitMs = 45000) {
          await page
            .goto(url, {
              waitUntil: "domcontentloaded",
              timeout: waitMs,
            })
            .catch((error) => {
              if (!String(error?.name || error).includes("Timeout")) throw error;
            });
          await page
            .waitForLoadState("networkidle", {
              timeout: Math.min(waitMs, 5000),
            })
            .catch(() => {});
        },
        async state(targetUrl) {
          const currentUrl = page.url();
          const title = await page.title().catch(() => "");
          const storage = await context.storageState();
          const localStorageByOrigin = {};
          for (const origin of storage.origins || []) {
            localStorageByOrigin[origin.origin] = Object.fromEntries(
              (origin.localStorage || []).map((item) => [item.name, item.value]),
            );
          }
          const targetOrigin = isValidTarget(targetUrl || "")
            ? new URL(targetUrl).origin
            : "";
          const currentOrigin = isValidTarget(currentUrl)
            ? new URL(currentUrl).origin
            : "";
          let cookies = storage.cookies || [];
          try {
            const cookieTarget = isValidTarget(targetUrl || "")
              ? targetUrl
              : currentUrl;
            if (isValidTarget(cookieTarget)) {
              cookies = await context.cookies(cookieTarget);
            }
          } catch {}
          const userAgent = await page
            .evaluate(() => navigator.userAgent)
            .catch(() => "");
          return {
            url: currentUrl,
            title,
            profile: contextOptions.profile,
            deviceScaleFactor: contextOptions.options.deviceScaleFactor || 1,
            cookies,
            localStorage:
              localStorageByOrigin[targetOrigin] ||
              localStorageByOrigin[currentOrigin] ||
              {},
            localStorageByOrigin,
            userAgent,
          };
        },
        async screenshot() {
          return page.screenshot({ type: "png", fullPage: false });
        },
        async click(x, y) {
          await dispatchBrowserClick(page, contextOptions.profile, x, y);
        },
        async type(text) {
          await page.keyboard.type(String(text || ""));
        },
        async press(key) {
          await page.keyboard.press(String(key || "Enter"));
        },
        async close() {
          await context.close();
        },
      };
    },
  };
}

const staticContentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".otf": "font/otf",
  ".ttf": "font/ttf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

const gzipStaticExtensions = new Set([".css", ".js", ".json", ".svg", ".wasm"]);

function staticCacheControl(filePath) {
  return "no-cache";
}

function acceptsGzipEncoding(value) {
  return String(value || "")
    .split(",")
    .some((part) => {
      const [encoding, ...params] = part.trim().split(";").map((p) => p.trim());
      if (encoding.toLowerCase() !== "gzip") return false;
      const q = params.find((param) => param.toLowerCase().startsWith("q="));
      return !q || Number.parseFloat(q.slice(2)) > 0;
    });
}

function writeCorsHeaders(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader(
    "Access-Control-Allow-Methods",
    "GET, POST, PUT, PATCH, DELETE, PROPFIND, MKCOL, MOVE, COPY, OPTIONS",
  );
  const requestedHeaders = req?.headers?.["access-control-request-headers"];
  res.setHeader(
    "Access-Control-Allow-Headers",
    requestedHeaders
      ? String(requestedHeaders)
      : "Authorization, Content-Type, Depth, Accept, User-Agent, Referer, Cookie, X-Requested-With, Range, If-Match, If-None-Match, Destination, Overwrite, X-Venera-User-Agent, X-Venera-Cookie, X-Venera-Referer, X-Venera-Origin, X-Venera-Forward-Headers",
  );
  res.setHeader(
    "Access-Control-Expose-Headers",
    "Content-Type, Content-Length, Content-Disposition, Set-Cookie, ETag, Last-Modified, Location",
  );
  res.setHeader("Access-Control-Max-Age", "86400");
}

function readBody(req) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolveBody(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function isValidTarget(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function canonicalForwardHeaderName(rawKey) {
  const key = String(rawKey || "");
  return canonicalForwardHeaders.get(key.toLowerCase()) || key;
}

function shouldForwardHeader(rawKey) {
  const lower = String(rawKey || "").toLowerCase();
  return (
    lower &&
    !blockedForwardHeaders.has(lower) &&
    !blockedForwardHeaderPrefixes.some((prefix) => lower.startsWith(prefix))
  );
}

function headerValue(input, name) {
  const lowerName = String(name || "").toLowerCase();
  for (const [rawKey, rawValue] of Object.entries(input || {})) {
    if (String(rawKey).toLowerCase() === lowerName) return rawValue;
  }
  return undefined;
}

function headerToString(value) {
  return Array.isArray(value) ? value.join(", ") : String(value);
}

function parseForwardHeaderNames(value) {
  if (value == null || value === "") return [];
  if (Array.isArray(value)) return value.map(String).filter(Boolean);
  const raw = String(value);
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed.map(String).filter(Boolean);
  } catch {
    // Keep compatibility with comma-separated metadata from older clients.
  }
  return raw
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function filteredHeaders(input) {
  const headers = {};
  for (const [rawKey, rawValue] of Object.entries(input || {})) {
    if (rawValue == null || rawValue === "") continue;
    if (!shouldForwardHeader(rawKey)) continue;
    headers[canonicalForwardHeaderName(rawKey)] = headerToString(rawValue);
  }
  return headers;
}

function prepareQueryProxyHeaders(clientHeaders) {
  const metadataNames = parseForwardHeaderNames(
    headerValue(clientHeaders, "x-venera-forward-headers"),
  );
  const headers = {};

  if (metadataNames.length > 0) {
    for (const name of metadataNames) {
      if (!shouldForwardHeader(name)) continue;
      const value = headerValue(clientHeaders, name);
      if (value == null || value === "") continue;
      headers[canonicalForwardHeaderName(name)] = headerToString(value);
    }
  } else {
    const fallback = { ...clientHeaders };
    delete fallback.cookie;
    delete fallback.Cookie;
    delete fallback["user-agent"];
    delete fallback["User-Agent"];
    delete fallback.referer;
    delete fallback.Referer;
    delete fallback.origin;
    delete fallback.Origin;
    Object.assign(headers, filteredHeaders(fallback));
  }

  const explicitUserAgent = headerValue(clientHeaders, "x-venera-user-agent");
  if (explicitUserAgent) headers["User-Agent"] = headerToString(explicitUserAgent);

  const explicitCookie = headerValue(clientHeaders, "x-venera-cookie");
  if (explicitCookie) headers.Cookie = headerToString(explicitCookie);

  const explicitReferer = headerValue(clientHeaders, "x-venera-referer");
  if (explicitReferer) headers.Referer = headerToString(explicitReferer);

  const explicitOrigin = headerValue(clientHeaders, "x-venera-origin");
  if (explicitOrigin) headers.Origin = headerToString(explicitOrigin);

  return headers;
}

function responseHeaders(response) {
  const headers = {};
  for (const [key, value] of response.headers.entries()) {
    if (exposedResponseHeaders.has(key.toLowerCase())) {
      headers[key.toLowerCase()] = value;
    }
  }
  const setCookies = response.headers.getSetCookie?.();
  if (setCookies && setCookies.length > 0) {
    headers["set-cookie"] = setCookies.join(", ");
  }
  return headers;
}

function payloadBody(payload) {
  if (!Object.hasOwn(payload, "data") || payload.data == null) return undefined;
  const data = payload.data;
  if (typeof data === "object" && data.type === "base64") {
    return Buffer.from(String(data.value || ""), "base64");
  }
  if (typeof data === "string") {
    return Buffer.from(data);
  }
  return Buffer.from(JSON.stringify(data));
}

function imageTypeFromHeader(value) {
  const contentType = String(value || "").split(";")[0].trim().toLowerCase();
  return contentType.startsWith("image/") ? contentType : "";
}

function sniffImageType(buffer) {
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47 &&
    buffer[4] === 0x0d &&
    buffer[5] === 0x0a &&
    buffer[6] === 0x1a &&
    buffer[7] === 0x0a
  ) {
    return "image/png";
  }
  const head = buffer.subarray(0, 256).toString("utf8").toLowerCase();
  if (head.startsWith("gif87a") || head.startsWith("gif89a")) return "image/gif";
  if (head.startsWith("riff") && head.slice(8, 12) === "webp") return "image/webp";
  if (head.includes("<svg")) return "image/svg+xml";
  if (head.slice(4, 8) === "ftyp" && head.includes("avif")) return "image/avif";
  return "";
}

function parseMaybeJsonObject(value) {
  if (!value) return {};
  if (typeof value === "object") return value;
  try {
    const parsed = JSON.parse(String(value));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function imagePayloadFromQuery(searchParams) {
  return {
    url: searchParams.get("url") || "",
    headers: parseMaybeJsonObject(searchParams.get("headers")),
    imageConfig: parseMaybeJsonObject(
      searchParams.get("imageConfig") ||
        searchParams.get("image_config") ||
        searchParams.get("config"),
    ),
    referer: searchParams.get("referer") || searchParams.get("referrer") || "",
    cookie: searchParams.get("cookie") || "",
    userAgent: searchParams.get("userAgent") || searchParams.get("user_agent") || "",
  };
}

function normalizeImageProxyPayload(payload) {
  const imageConfig = parseMaybeJsonObject(
    payload?.imageConfig || payload?.image_config || payload?.config,
  );
  const merged = { ...imageConfig, ...(payload || {}) };
  const headers = {
    Accept: defaultImageAccept,
    "User-Agent": defaultProxyUserAgent,
    ...filteredHeaders(imageConfig.headers || {}),
    ...filteredHeaders(payload?.headers || {}),
  };
  const userAgent = merged.userAgent || merged.user_agent;
  const referer = merged.referer || merged.referrer;
  const cookie = merged.cookie;
  if (userAgent) headers["User-Agent"] = headerToString(userAgent);
  if (referer) headers.Referer = headerToString(referer);
  if (cookie) headers.Cookie = headerToString(cookie);
  return { url: String(merged.url || ""), headers };
}

// --- venera-fetch sidecar integration ---
//
// The Rust sidecar at $VENERA_FETCH_SIDECAR (default http://127.0.0.1:9876)
// performs upstream HTTP outside the browser sandbox. CopyManga and friends
// are sensitive to request fingerprints, so the sidecar defaults to an
// app-like HTTP/1.1 path and exposes debug headers for verification.
//
// We pass the upstream call to the sidecar and wrap its HTTP response in an
// object that quacks like the small subset of fetch Response that the rest
// of this file consumes: { status, headers.entries(), headers.get(name),
// headers.getSetCookie(), arrayBuffer() }.

const SIDECAR_URL =
  (process.env.VENERA_FETCH_SIDECAR || "http://127.0.0.1:9876").replace(/\/$/, "");

class SidecarHeaders {
  constructor(rawHeaders, setCookies) {
    this._raw = rawHeaders;
    this._setCookies = setCookies || [];
  }
  get(name) {
    if (String(name).toLowerCase() === "set-cookie") {
      return this._setCookies.length ? this._setCookies.join(", ") : null;
    }
    return this._raw.get(name);
  }
  has(name) {
    if (String(name).toLowerCase() === "set-cookie") return this._setCookies.length > 0;
    return this._raw.has(name);
  }
  getSetCookie() {
    return [...this._setCookies];
  }
  *entries() {
    for (const [k, v] of this._raw.entries()) {
      const lower = k.toLowerCase();
      if (lower === "set-cookie" || lower === "x-upstream-set-cookie") continue;
      yield [k, v];
    }
    for (const c of this._setCookies) yield ["set-cookie", c];
  }
  forEach(fn) {
    for (const [k, v] of this.entries()) fn(v, k, this);
  }
  [Symbol.iterator]() {
    return this.entries();
  }
}

class SidecarResponse {
  constructor(rawResponse, setCookies) {
    this._raw = rawResponse;
    this.status = rawResponse.status;
    this.statusText = rawResponse.statusText;
    this.ok = rawResponse.ok;
    this.headers = new SidecarHeaders(rawResponse.headers, setCookies);
  }
  arrayBuffer() {
    return this._raw.arrayBuffer();
  }
  text() {
    return this._raw.text();
  }
  json() {
    return this._raw.json();
  }
  get body() {
    return this._raw.body;
  }
}

function decodeUpstreamSetCookies(rawResponse) {
  const encoded = rawResponse.headers.get("x-upstream-set-cookie");
  if (!encoded) return [];
  try {
    const decoded = Buffer.from(encoded, "base64").toString("utf-8");
    const parsed = JSON.parse(decoded);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

async function sidecarFetch(url, init) {
  const headers = init.headers || {};
  let bodyB64 = null;
  if (init.body != null) {
    const buf = Buffer.isBuffer(init.body) ? init.body : Buffer.from(init.body);
    bodyB64 = buf.toString("base64");
  }
  const payload = {
    url,
    method: (init.method || "GET").toUpperCase(),
    headers,
    body_b64: bodyB64,
    follow_redirects: init.redirect !== "manual",
  };

  const raw = await fetch(`${SIDECAR_URL}/proxy`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (raw.status === 502) {
    let detail = "";
    try {
      const errBody = await raw.json();
      detail = errBody?.error || "";
    } catch {
      // ignore
    }
    const err = new Error(detail ? `Upstream: ${detail}` : "Upstream error");
    err.code = "SIDECAR_UPSTREAM_ERROR";
    throw err;
  }

  const setCookies = decodeUpstreamSetCookies(raw);
  return new SidecarResponse(raw, setCookies);
}

function isSidecarUnavailableError(error) {
  if (error?.code === "SIDECAR_UPSTREAM_ERROR") {
    return false;
  }
  return true;
}

async function proxyFetch({
  url,
  method,
  headers,
  body,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  if (!isValidTarget(url)) {
    const error = new Error("Invalid URL scheme");
    error.statusCode = 400;
    throw error;
  }
  const upperMethod = String(method || "GET").toUpperCase();
  const init = {
    method: upperMethod,
    headers: filteredHeaders(headers),
    redirect: "follow",
  };
  if (!init.headers["User-Agent"] && !init.headers["user-agent"]) {
    init.headers["User-Agent"] = defaultProxyUserAgent;
  }
  const requestCookieHeader = init.headers.Cookie || init.headers.cookie || "";
  const helperCookieHeader = cookieJar ? getCookieHeader(cookieJar, url) : "";
  const mergedCookieHeader = mergeCookieHeader(
    requestCookieHeader,
    helperCookieHeader,
  );
  let cookieSource = "none";
  if (requestCookieHeader && helperCookieHeader) {
    cookieSource = "request+helper";
  } else if (requestCookieHeader) {
    cookieSource = "request";
  } else if (helperCookieHeader) {
    cookieSource = "helper";
  }
  if (mergedCookieHeader) {
    init.headers.Cookie = mergedCookieHeader;
  } else {
    delete init.headers.Cookie;
  }
  delete init.headers.cookie;
  if (!["GET", "HEAD"].includes(upperMethod) && body != null) {
    init.body = body;
  }
  const startedAt = Date.now();
  const cookieHeader = init.headers.Cookie || init.headers.cookie || "";
  let transport = "sidecar";
  let sidecarError = null;
  try {
    let response;
    try {
      response = await sidecarFetch(url, init);
    } catch (error) {
      if (!isSidecarUnavailableError(error)) {
        throw error;
      }
      sidecarError = error;
      transport = "fetch";
      response = await fetch(url, init);
    }
    if (cookieJar) storeResponseCookies(cookieJar, url, response, persistCookieJar);
    recordProxyRequest?.({
      method: upperMethod,
      url: redactProxyUrl(url),
      host: new URL(url).host,
      status: response.status,
      durationMs: Date.now() - startedAt,
      cookieSource,
      cookieNames: cookieNamesFromHeader(cookieHeader),
      requestHeaderNames: Object.keys(init.headers),
      transport,
      sidecarFallbackError: sidecarError
        ? String(sidecarError.message || sidecarError)
        : "",
      ...proxyRequestDiagnostics(init.headers, response),
    });
    return response;
  } catch (error) {
    recordProxyRequest?.({
      method: upperMethod,
      url: redactProxyUrl(url),
      host: new URL(url).host,
      error: String(error && error.message ? error.message : error),
      durationMs: Date.now() - startedAt,
      cookieSource,
      cookieNames: cookieNamesFromHeader(cookieHeader),
      requestHeaderNames: Object.keys(init.headers),
      transport,
      sidecarFallbackError: sidecarError
        ? String(sidecarError.message || sidecarError)
        : "",
      ...proxyRequestDiagnostics(init.headers),
    });
    throw error;
  }
}

function sendJson(res, statusCode, value) {
  res.writeHead(statusCode, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value));
}

function websocketAcceptKey(key) {
  return createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
}

function sendWebSocketText(socket, value) {
  if (socket.destroyed) return;
  const payload = Buffer.from(String(value));
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else if (payload.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function closeWebSocket(socket) {
  if (!socket.destroyed) {
    socket.end(Buffer.from([0x88, 0x00]));
  }
}

async function handleJsonProxy(
  req,
  res,
  rawBody,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
) {
  let payload;
  try {
    payload = JSON.parse(rawBody.toString() || "{}");
  } catch {
    sendJson(res, 400, { error: "Invalid JSON proxy payload" });
    return;
  }

  const response = await proxyFetch({
    url: payload.url,
    method: payload.method || payload.http_method || "GET",
    headers: payload.headers || {},
    body: payloadBody(payload),
    cookieJar,
    persistCookieJar,
    recordProxyRequest,
  });
  const body = Buffer.from(await response.arrayBuffer());
  sendJson(res, 200, {
    status: response.status,
    headers: responseHeaders(response),
    body: payload.bytes ? null : body.toString(),
    bodyBase64: payload.bytes ? body.toString("base64") : null,
  });
}

async function handleQueryProxy(
  req,
  res,
  parsedUrl,
  rawBody,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
) {
  const target = parsedUrl.searchParams.get("url") || "";
  const requestHeaders = prepareQueryProxyHeaders(req.headers);
  const response = await proxyFetch({
    url: target,
    method: req.method,
    headers: requestHeaders,
    body: rawBody.length > 0 ? rawBody : undefined,
    cookieJar,
    persistCookieJar,
    recordProxyRequest,
  });
  const body = Buffer.from(await response.arrayBuffer());
  const headers = responseHeaders(response);
  delete headers["content-encoding"];
  headers["content-length"] = String(body.length);
  res.writeHead(response.status, headers);
  res.end(body);
}

async function handleImageProxy(
  req,
  res,
  parsedUrl,
  rawBody,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
) {
  if (req.method !== "GET" && req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return;
  }

  const payload =
    req.method === "POST"
      ? parseJsonBody(rawBody, "Invalid image proxy payload")
      : imagePayloadFromQuery(parsedUrl.searchParams);
  const { url, headers } = normalizeImageProxyPayload(payload);
  const response = await proxyFetch({
    url,
    method: "GET",
    headers,
    cookieJar,
    persistCookieJar,
    recordProxyRequest,
  });
  const body = Buffer.from(await response.arrayBuffer());
  if (response.status < 200 || response.status >= 300) {
    sendJson(res, 502, { error: `upstream returned ${response.status}` });
    return;
  }
  const contentLength = Number(response.headers.get("content-length") || 0);
  if (contentLength > maxImageBytes || body.length > maxImageBytes) {
    sendJson(res, 502, { error: "image is too large" });
    return;
  }
  const contentType =
    imageTypeFromHeader(response.headers.get("content-type")) ||
    sniffImageType(body);
  if (!contentType) {
    sendJson(res, 502, { error: "upstream did not return an image" });
    return;
  }

  res.writeHead(200, {
    "Content-Type": contentType,
    "Content-Length": String(body.length),
    "Cache-Control": "public, max-age=604800, immutable",
    "x-venera-cache": "miss",
  });
  res.end(body);
}

function createHttpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}

function parseJsonBody(rawBody, errorMessage = "Invalid JSON payload") {
  try {
    return JSON.parse(rawBody.toString() || "{}");
  } catch {
    throw createHttpError(400, errorMessage);
  }
}

function normalizeWebDavConfig(payload) {
  const urlText = String(payload?.url || "").trim();
  const user = String(payload?.user || "").trim();
  const pass = String(payload?.pass || "");
  if (!urlText || !user) {
    throw createHttpError(400, "Invalid WebDAV configuration");
  }
  let url;
  try {
    url = new URL(urlText);
  } catch {
    throw createHttpError(400, "Invalid WebDAV URL");
  }
  if (!["http:", "https:"].includes(url.protocol)) {
    throw createHttpError(400, "Unsupported WebDAV URL scheme");
  }
  const normalizedBase = url.toString().endsWith("/")
    ? url.toString()
    : `${url.toString()}/`;
  return { baseUrl: normalizedBase, user, pass };
}

function hasWebDavConfigPayload(payload) {
  return (
    payload != null &&
    (Object.hasOwn(payload, "url") ||
      Object.hasOwn(payload, "user") ||
      Object.hasOwn(payload, "pass"))
  );
}

function readStoredWebDavConfig(webDavConfigPath) {
  if (!webDavConfigPath || !existsSync(webDavConfigPath)) {
    return null;
  }
  try {
    const data = JSON.parse(readFileSync(webDavConfigPath, "utf8"));
    if (!data || typeof data !== "object") {
      return null;
    }
    return data;
  } catch {
    throw createHttpError(422, "Stored WebDAV configuration is invalid");
  }
}

function writeStoredWebDavConfig(webDavConfigPath, payload) {
  const normalized = normalizeWebDavConfig(payload);
  const data = {
    url: normalized.baseUrl,
    user: normalized.user,
    pass: normalized.pass,
    autoSync: payload.autoSync !== false,
    disableSyncFields: String(payload.disableSyncFields || ""),
  };
  mkdirSync(dirname(webDavConfigPath), { recursive: true });
  writeFileSync(webDavConfigPath, JSON.stringify(data, null, 2));
  return data;
}

function clearStoredWebDavConfig(webDavConfigPath) {
  if (webDavConfigPath) {
    rmSync(webDavConfigPath, { force: true });
  }
}

function resolveWebDavConfig(payload, webDavConfigPath) {
  if (hasWebDavConfigPayload(payload)) {
    return normalizeWebDavConfig(payload);
  }
  const stored = readStoredWebDavConfig(webDavConfigPath);
  if (stored) {
    return normalizeWebDavConfig(stored);
  }
  return normalizeWebDavConfig(payload);
}

// WebDAV sync log (in-memory, max 100 entries)
const syncLogs = [];
const MAX_SYNC_LOGS = 100;
function addSyncLog(action, fileName, success, error) {
  syncLogs.unshift({
    time: Date.now(),
    action,
    fileName: fileName || null,
    success: !!success,
    error: error || null,
  });
  if (syncLogs.length > MAX_SYNC_LOGS) syncLogs.length = MAX_SYNC_LOGS;
}

function normalizeWebDavBackupName(rawName, { required = false } = {}) {
  const value = String(rawName || "").trim();
  if (!value) {
    if (required) {
      throw createHttpError(400, "Invalid remote backup file name");
    }
    return null;
  }
  if (!/^[0-9A-Za-z_.-]+\.venera$/.test(value)) {
    throw createHttpError(400, "Invalid remote backup file name");
  }
  return value;
}

const VALID_PLATFORMS = ["web", "win", "macos", "linux", "ios", "android"];

function backupPlatform(fileName) {
  const name = String(fileName || "");
  const m = name.match(/\.([a-z]+)\.venera$/i);
  if (m && VALID_PLATFORMS.includes(m[1].toLowerCase())) return m[1].toLowerCase();
  return null;
}

function webDavAuthHeader(user, pass) {
  return `Basic ${Buffer.from(`${user}:${pass}`).toString("base64")}`;
}

function decodeXmlEntities(value) {
  return String(value || "")
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'");
}

function parseWebDavFileNames(xmlBody, baseUrl) {
  const names = new Set();
  const hrefRegex = /<(?:[a-zA-Z0-9_]+:)?href[^>]*>([\s\S]*?)<\/(?:[a-zA-Z0-9_]+:)?href>/gi;
  for (const match of xmlBody.matchAll(hrefRegex)) {
    const hrefText = decodeXmlEntities(match[1] || "").trim();
    if (!hrefText) continue;
    let parsed;
    try {
      parsed = new URL(hrefText, baseUrl);
    } catch {
      continue;
    }
    const segments = parsed.pathname.split("/").filter(Boolean);
    if (segments.length === 0) continue;
    const last = decodeURIComponent(segments[segments.length - 1]);
    if (
      last.toLowerCase().endsWith(".venera") &&
      last.toLowerCase() !== "latest.venera"
    ) {
      names.add(last);
    }
  }
  return Array.from(names);
}

function backupTimestamp(fileName) {
  return Number.parseInt(fileName.replace(/\.venera$/i, ""), 10) || 0;
}

function backupSortKey(fileName) {
  const name = String(fileName || "");
  const lowerName = name.toLowerCase();
  if (lowerName === "latest.venera") {
    return { fallback: true, day: -1, version: -1, platform: null, name };
  }
  const platform = backupPlatform(name);
  const stem = name.replace(/\.[a-z]+\.venera$/i, "").replace(/\.venera$/i, "");
  const parts = stem.split("-");
  let day = Number.parseInt(parts[0], 10);
  if (!Number.isFinite(day)) day = 0;
  if (day > 1000000000) day = Math.floor(day / 86400000);
  let version = parts.length > 1 ? Number.parseInt(parts[1], 10) : -1;
  if (!Number.isFinite(version)) version = -1;
  return { fallback: false, day, version, platform, name };
}

function sortBackupFiles(files, newestFirst = true) {
  return [...files].sort((a, b) => {
    const aKey = backupSortKey(a);
    const bKey = backupSortKey(b);
    if (aKey.fallback !== bKey.fallback) {
      return aKey.fallback ? 1 : -1;
    }
    const dayCompare = aKey.day - bKey.day;
    if (dayCompare !== 0) return newestFirst ? -dayCompare : dayCompare;
    const versionCompare = aKey.version - bKey.version;
    if (versionCompare !== 0) {
      return newestFirst ? -versionCompare : versionCompare;
    }
    const nameCompare = aKey.name.localeCompare(bKey.name);
    return newestFirst ? -nameCompare : nameCompare;
  });
}

function backupFilesToCleanup(files, maxPerPlatform = 10) {
  const groups = new Map();
  for (const f of files) {
    const platform = backupPlatform(f) || "__legacy__";
    if (!groups.has(platform)) groups.set(platform, []);
    groups.get(platform).push(f);
  }
  const toDelete = [];
  for (const [, group] of groups) {
    const sorted = sortBackupFiles(group, true);
    if (sorted.length > maxPerPlatform) {
      toDelete.push(...sorted.slice(maxPerPlatform));
    }
  }
  return toDelete;
}

function backupSha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

const serverDbEntryNames = [
  "data/venera.db",
  "history.db",
  "local_favorite.db",
  "read_later.db",
  "cookie.db",
];

const serverDbBackupEntryNames = [...serverDbEntryNames, "appdata.json", "implicitData.json"];

function assertLooksLikeVeneraBackup(buffer, fileName = "backup") {
  if (!Buffer.isBuffer(buffer) || buffer.length < 4) {
    throw createHttpError(422, `${fileName} is empty or truncated`);
  }
  const isZip =
    buffer[0] === 0x50 &&
    buffer[1] === 0x4b &&
    (buffer[2] === 0x03 || buffer[2] === 0x05 || buffer[2] === 0x07) &&
    (buffer[3] === 0x04 || buffer[3] === 0x06 || buffer[3] === 0x08);
  if (!isZip) {
    throw createHttpError(422, `${fileName} is not a .venera zip package`);
  }
}

// ---------------------------------------------------------------------------
// ZIP parser (no third-party deps; uses Node built-in zlib for DEFLATE)
// Supports compression method 0 (stored) and 8 (deflated).
// ---------------------------------------------------------------------------

/**
 * Parse a .venera ZIP buffer and return a map of {entryName -> Uint8Array}.
 * Only entries whose names match `namePredicate` are extracted.
 * @param {Buffer} zipBuf
 * @param {(name: string) => boolean} namePredicate
 * @returns {Map<string, Buffer>}
 */
function extractZipEntries(zipBuf, namePredicate) {
  // Locate End of Central Directory record (signature 0x06054b50) by scanning
  // backwards.  Must use Central Directory for sizes because zip_flutter sets
  // general-purpose flag bit 3 (data descriptor), leaving compressedSize=0 in
  // local file headers.
  let eocdOffset = -1;
  const maxSearch = Math.min(zipBuf.length, 65535 + 22);
  for (let i = zipBuf.length - 22; i >= zipBuf.length - maxSearch && i >= 0; i--) {
    if (zipBuf.readUInt32LE(i) === 0x06054b50) { eocdOffset = i; break; }
  }
  if (eocdOffset < 0) {
    throw createHttpError(422, "ZIP: End of Central Directory record not found");
  }
  const cdCount = zipBuf.readUInt16LE(eocdOffset + 10);
  const cdOffset = zipBuf.readUInt32LE(eocdOffset + 16);

  // Parse Central Directory entries to build name → metadata map.
  const cdMap = new Map();
  let cdPos = cdOffset;
  for (let i = 0; i < cdCount && cdPos + 46 <= zipBuf.length; i++) {
    if (zipBuf.readUInt32LE(cdPos) !== 0x02014b50) break;
    const compression        = zipBuf.readUInt16LE(cdPos + 10);
    const compressedSize     = zipBuf.readUInt32LE(cdPos + 20);
    const fileNameLen        = zipBuf.readUInt16LE(cdPos + 28);
    const extraLen           = zipBuf.readUInt16LE(cdPos + 30);
    const commentLen         = zipBuf.readUInt16LE(cdPos + 32);
    const localHeaderOffset  = zipBuf.readUInt32LE(cdPos + 42);
    const name = zipBuf.subarray(cdPos + 46, cdPos + 46 + fileNameLen).toString("utf8");
    cdMap.set(name, { compression, compressedSize, localHeaderOffset });
    cdPos += 46 + fileNameLen + extraLen + commentLen;
  }

  // Extract matching entries.  Use CD for sizes; use local header only to skip
  // its variable-length fields (fileNameLen + extraLen) and find the data start.
  const result = new Map();
  for (const [name, { compression, compressedSize, localHeaderOffset }] of cdMap) {
    if (!namePredicate(name)) continue;
    if (localHeaderOffset + 30 > zipBuf.length) continue;
    const lhFileNameLen = zipBuf.readUInt16LE(localHeaderOffset + 26);
    const lhExtraLen    = zipBuf.readUInt16LE(localHeaderOffset + 28);
    const dataStart = localHeaderOffset + 30 + lhFileNameLen + lhExtraLen;
    const compData = zipBuf.subarray(dataStart, dataStart + compressedSize);
    let data;
    if (compression === 0) {
      data = compData;
    } else if (compression === 8) {
      data = inflateRawSync(compData);
    } else {
      throw createHttpError(422, `Unsupported ZIP compression method ${compression} in entry ${name}`);
    }
    result.set(name, Buffer.from(data));
  }
  return result;
}

const crc32Table = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < table.length; i++) {
    let value = i;
    for (let bit = 0; bit < 8; bit++) {
      value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
    }
    table[i] = value >>> 0;
  }
  return table;
})();

function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value = crc32Table[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function buildStoredZip(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;

  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, "utf8");
    const data = Buffer.from(entry.data);
    const deflated = deflateRawSync(data, { level: 9 });
    const compressed = deflated.length < data.length ? deflated : data;
    const compressionMethod = compressed === data ? 0 : 8;
    const checksum = crc32(data);
    const flags = 0x0800;

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(flags, 6);
    localHeader.writeUInt16LE(compressionMethod, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0, 12);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(data.length, 22);
    localHeader.writeUInt16LE(nameBytes.length, 26);
    localParts.push(localHeader, nameBytes, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(flags, 8);
    centralHeader.writeUInt16LE(compressionMethod, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(data.length, 24);
    centralHeader.writeUInt16LE(nameBytes.length, 28);
    centralHeader.writeUInt32LE(localOffset, 42);
    centralParts.push(centralHeader, nameBytes);

    localOffset += localHeader.length + nameBytes.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralDirectory.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...localParts, centralDirectory, eocd]);
}

const SQLITE_HEADER = Buffer.from("SQLite format 3\0");

function looksLikeSqliteBuffer(buf) {
  return buf.length >= 16 && buf.subarray(0, 16).equals(SQLITE_HEADER);
}

// ---------------------------------------------------------------------------
// Pure-JS SQLite reader
// Reads pages, B-tree cells, and varint-encoded records from a SQLite file
// without any native addon.  Supports:
//   - SQLite 3 page sizes from 512 to 65536
//   - Table B-tree leaf pages (type 0x0d)
//   - Interior pages are traversed recursively
//   - Serial types: null, int8/16/24/32/48/64, float64, blob, text
// Limitations (acceptable for our use-case):
//   - Overflow pages not supported (all cell payloads must fit in one page)
//   - WAL journal is ignored — only the main db file is read
// ---------------------------------------------------------------------------

const SQLITE_PAGE_SIZES = new Set([512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]);

function readVarint(buf, offset) {
  let value = 0n;
  for (let i = 0; i < 9; i++) {
    if (offset + i >= buf.length) {
      throw createHttpError(422, "Truncated SQLite varint");
    }
    const byte = buf[offset + i];
    if (i === 8) {
      value = (value << 8n) | BigInt(byte);
      return { value, bytesRead: 9 };
    }
    value = (value << 7n) | BigInt(byte & 0x7f);
    if ((byte & 0x80) === 0) {
      return { value, bytesRead: i + 1 };
    }
  }
  throw createHttpError(422, "Invalid SQLite varint");
}

function decodeSerialType(serialType) {
  const t = Number(serialType);
  if (t === 0) return { kind: "null", size: 0 };
  if (t === 1) return { kind: "int", size: 1 };
  if (t === 2) return { kind: "int", size: 2 };
  if (t === 3) return { kind: "int", size: 3 };
  if (t === 4) return { kind: "int", size: 4 };
  if (t === 5) return { kind: "int", size: 6 };
  if (t === 6) return { kind: "int", size: 8 };
  if (t === 7) return { kind: "float", size: 8 };
  if (t === 8) return { kind: "zero", size: 0 };
  if (t === 9) return { kind: "one", size: 0 };
  if (t >= 12 && t % 2 === 0) return { kind: "blob", size: (t - 12) >> 1 };
  if (t >= 13 && t % 2 === 1) return { kind: "text", size: (t - 13) >> 1 };
  return { kind: "reserved", size: 0 };
}

function readInt(buf, offset, size) {
  if (size === 1) return buf.readInt8(offset);
  if (size === 2) return buf.readInt16BE(offset);
  if (size === 3) {
    const v = (buf[offset] << 16) | (buf[offset + 1] << 8) | buf[offset + 2];
    return v & 0x800000 ? v - 0x1000000 : v;
  }
  if (size === 4) return buf.readInt32BE(offset);
  if (size === 6) {
    const hi = buf.readUInt32BE(offset);
    const lo = buf.readUInt16BE(offset + 4);
    const big = (BigInt(hi) << 16n) | BigInt(lo);
    return big > BigInt(Number.MAX_SAFE_INTEGER) ? big : Number(big);
  }
  if (size === 8) {
    const big = buf.readBigInt64BE(offset);
    return big >= BigInt(Number.MIN_SAFE_INTEGER) && big <= BigInt(Number.MAX_SAFE_INTEGER)
      ? Number(big)
      : big;
  }
  return 0;
}

function parseRecord(payload, headerStart) {
  let pos = headerStart;
  const { value: headerSize, bytesRead: hs } = readVarint(payload, pos);
  pos += hs;
  const headerEnd = headerStart + Number(headerSize);
  if (headerEnd > payload.length) {
    throw createHttpError(422, "SQLite record header exceeds payload size");
  }
  const serialTypes = [];
  while (pos < headerEnd) {
    const { value: st, bytesRead: sb } = readVarint(payload, pos);
    serialTypes.push(st);
    pos += sb;
  }
  const values = [];
  let dataPos = headerEnd;
  for (const st of serialTypes) {
    const { kind, size } = decodeSerialType(st);
    if (kind === "null") {
      values.push(null);
    } else if (kind === "zero") {
      values.push(0);
    } else if (kind === "one") {
      values.push(1);
    } else if (kind === "int") {
      values.push(readInt(payload, dataPos, size));
      dataPos += size;
    } else if (kind === "float") {
      values.push(payload.readDoubleBE(dataPos));
      dataPos += size;
    } else if (kind === "blob") {
      values.push(payload.subarray(dataPos, dataPos + size));
      dataPos += size;
    } else if (kind === "text") {
      values.push(payload.subarray(dataPos, dataPos + size).toString("utf8"));
      dataPos += size;
    } else {
      values.push(null);
    }
  }
  return values;
}

function sqliteUsableSize(dbBuf, pageSize) {
  const reservedBytes = dbBuf[20] || 0;
  const usableSize = pageSize - reservedBytes;
  if (usableSize < 480) {
    throw createHttpError(422, `Invalid SQLite reserved bytes: ${reservedBytes}`);
  }
  return usableSize;
}

function tableLeafLocalPayloadSize(payloadSize, usableSize) {
  const maxLocal = usableSize - 35;
  if (payloadSize <= maxLocal) return payloadSize;
  const minLocal = Math.floor(((usableSize - 12) * 32) / 255) - 23;
  let local = minLocal + ((payloadSize - minLocal) % (usableSize - 4));
  if (local > maxLocal) local = minLocal;
  return local;
}

function readOverflowPayload(dbBuf, pageSize, usableSize, firstPageNo, size) {
  const chunks = [];
  let remaining = size;
  let pageNo = firstPageNo;
  while (remaining > 0) {
    if (!Number.isInteger(pageNo) || pageNo < 1) {
      throw createHttpError(422, "Invalid SQLite overflow page pointer");
    }
    const base = (pageNo - 1) * pageSize;
    if (base + usableSize > dbBuf.length) {
      throw createHttpError(422, "SQLite overflow page exceeds database size");
    }
    const nextPage = dbBuf.readUInt32BE(base);
    const chunkSize = Math.min(remaining, usableSize - 4);
    chunks.push(dbBuf.subarray(base + 4, base + 4 + chunkSize));
    remaining -= chunkSize;
    pageNo = nextPage;
    if (remaining > 0 && pageNo === 0) {
      throw createHttpError(422, "SQLite overflow chain ended early");
    }
  }
  return Buffer.concat(chunks, size);
}

/**
 * Read all leaf-page rows from a B-tree rooted at `rootPage` (1-based).
 * Returns array of arrays (column values per row).
 */
function readBTreeRows(dbBuf, pageSize, rootPageNo) {
  const rows = [];
  const usableSize = sqliteUsableSize(dbBuf, pageSize);

  function readPage(pageNo) {
    const base = (pageNo - 1) * pageSize;
    // Page 1 has a 100-byte file header before the B-tree header.
    const headerOffset = pageNo === 1 ? 100 : 0;
    const pageType = dbBuf[base + headerOffset];
    if (pageType !== 0x0d && pageType !== 0x05) return; // leaf or interior table b-tree

    const cellCount = dbBuf.readUInt16BE(base + headerOffset + 3);
    const cellPointerArrayStart = base + headerOffset + 8 + (pageType === 0x05 ? 4 : 0);

    if (pageType === 0x05) {
      // Interior page: visit right-most child first
      const rightMostChild = dbBuf.readUInt32BE(base + headerOffset + 8);
      // Visit all left children (from cell pointer array)
      for (let i = 0; i < cellCount; i++) {
        const cellPtr = dbBuf.readUInt16BE(cellPointerArrayStart + i * 2);
        const childPage = dbBuf.readUInt32BE(base + cellPtr);
        readPage(childPage);
      }
      readPage(rightMostChild);
      return;
    }

    // Leaf page
    for (let i = 0; i < cellCount; i++) {
      const cellPtr = dbBuf.readUInt16BE(cellPointerArrayStart + i * 2);
      let pos = base + cellPtr;
      const { value: payloadSize, bytesRead: pb } = readVarint(dbBuf, pos);
      pos += pb;
      // skip rowid varint
      const { bytesRead: rb } = readVarint(dbBuf, pos);
      pos += rb;
      const totalPayloadSize = Number(payloadSize);
      const localSize = tableLeafLocalPayloadSize(totalPayloadSize, usableSize);
      const localEnd = pos + localSize;
      if (localEnd > base + usableSize) {
        throw createHttpError(422, "SQLite local cell payload exceeds page size");
      }
      let payloadBuf = dbBuf.subarray(pos, localEnd);
      if (localSize < totalPayloadSize) {
        if (localEnd + 4 > base + usableSize) {
          throw createHttpError(422, "SQLite overflow pointer exceeds page size");
        }
        const firstOverflowPage = dbBuf.readUInt32BE(localEnd);
        const overflow = readOverflowPayload(
          dbBuf,
          pageSize,
          usableSize,
          firstOverflowPage,
          totalPayloadSize - localSize,
        );
        payloadBuf = Buffer.concat([payloadBuf, overflow], totalPayloadSize);
      }
      const record = parseRecord(payloadBuf, 0);
      rows.push(record);
    }
  }

  readPage(rootPageNo);
  return rows;
}

/**
 * Read the sqlite_master table and return metadata for all user tables.
 * Returns [{name, rootPage, sql}]
 */
function readSqliteMaster(dbBuf, pageSize) {
  const masterRows = readBTreeRows(dbBuf, pageSize, 1);
  const tables = [];
  for (const row of masterRows) {
    // sqlite_master columns: type, name, tbl_name, rootpage, sql
    if (row[0] !== "table") continue;
    const name = row[1];
    const rootPage = Number(row[3]);
    const sql = typeof row[4] === "string" ? row[4] : null;
    if (
      typeof name !== "string" ||
      name.startsWith("sqlite_") ||
      !Number.isInteger(rootPage) ||
      rootPage < 2
    ) {
      continue;
    }
    tables.push({ name, rootPage, sql });
  }
  return tables;
}

function readSqliteIndexes(dbBuf, pageSize) {
  const masterRows = readBTreeRows(dbBuf, pageSize, 1);
  const indexes = [];
  for (const row of masterRows) {
    if (row[0] !== "index") continue;
    const name = row[1];
    const sql = row[4];
    if (
      typeof name !== "string" ||
      name.startsWith("sqlite_") ||
      typeof sql !== "string" ||
      sql.trim() === ""
    ) {
      continue;
    }
    indexes.push(sql);
  }
  return indexes;
}

/**
 * Parse column names from a CREATE TABLE sql string.
 * Returns [] if parsing fails (fallback: caller will use positional names).
 */
function parseColumnNamesFromSql(sql) {
  if (!sql) return [];
  const m = sql.match(/\(([^)]+)\)/s);
  if (!m) return [];
  return m[1]
    .split(",")
    .map((part) => {
      const stripped = part.trim().replace(/^["'`\[]/, "").replace(/["'`\]].*$/, "");
      return stripped.split(/\s+/)[0] || "";
    })
    .filter(Boolean);
}

/**
 * Extract all table data from a SQLite .db buffer.
 * Returns {ok, tables: [{name, sql, columns, rows}]}
 * Values: null | number | BigInt (serialized as string) | string | Buffer (base64-encoded)
 */
function extractSqliteData(dbBuf) {
  if (!looksLikeSqliteBuffer(dbBuf)) {
    throw createHttpError(422, "Entry is not a SQLite database (magic mismatch)");
  }
  let pageSize = dbBuf.readUInt16BE(16);
  if (pageSize === 1) pageSize = 65536; // SQLite encodes 65536 as 1
  if (!SQLITE_PAGE_SIZES.has(pageSize)) {
    throw createHttpError(422, `Invalid SQLite page size: ${pageSize}`);
  }

  const masterTables = readSqliteMaster(dbBuf, pageSize);
  const indexes = readSqliteIndexes(dbBuf, pageSize);
  const tables = [];
  for (const { name, rootPage, sql } of masterTables) {
    const colNamesFromSql = parseColumnNamesFromSql(sql);
    const rawRows = readBTreeRows(dbBuf, pageSize, rootPage);
    // Serialize values: Buffer -> base64 marker objects.
    const rows = rawRows.map((row) =>
      row.map((v) => {
        if (v === null) return null;
        if (typeof v === "bigint") return { $bigint: v.toString() };
        if (Buffer.isBuffer(v)) return { $blob: v.toString("base64") };
        return v;
      }),
    );
    // Build column list: prefer SQL-parsed names, fall back to col0/col1/...
    const colCount = rows.length > 0 ? rows[0].length : colNamesFromSql.length;
    const columns =
      colNamesFromSql.length === colCount
        ? colNamesFromSql
        : Array.from({ length: colCount }, (_, i) =>
            colNamesFromSql[i] ?? `col${i}`,
          );
    tables.push({ name, sql: sql ?? null, columns, rows });
  }
  return { tables, indexes };
}

// ---------------------------------------------------------------------------
// /sync/webdav/extract-db handler
// ---------------------------------------------------------------------------

async function handleExtractDbRoute({ req, res, parsedUrl }) {
  if (parsedUrl.pathname !== "/sync/webdav/extract-db") return false;
  if (req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return true;
  }
  const payload = parseJsonBody(await readBody(req), "Invalid extract-db payload");
  const dataBase64 = String(payload.dataBase64 || "");
  if (!dataBase64) {
    throw createHttpError(400, "Missing dataBase64");
  }
  const zipBuf = Buffer.from(dataBase64, "base64");
  assertLooksLikeVeneraBackup(zipBuf, "extract-db payload");

  const entries = extractZipEntries(zipBuf, (name) => serverDbEntryNames.includes(name));

  const result = {};
  for (const [entryName, dbBuf] of entries) {
    try {
      result[entryName] = { ok: true, ...extractSqliteData(dbBuf) };
    } catch (err) {
      result[entryName] = {
        ok: false,
        error: err.message || String(err),
        rawBase64: dbBuf.toString("base64"),
      };
    }
  }
  sendJson(res, 200, { ok: true, databases: result });
  return true;
}

function normalizeServerDbProfileId(value) {
  const raw = String(value || "default").trim() || "default";
  if (!/^[0-9A-Za-z_.-]{1,80}$/.test(raw)) {
    throw createHttpError(400, "Invalid server DB profile");
  }
  return raw;
}

function serverDbProfileRoot(serverDataRoot, profileId) {
  return join(resolve(serverDataRoot), "profiles", profileId);
}

function serverDbMetadataPath(profileRoot) {
  return join(profileRoot, "metadata.json");
}

function serverDbEntryPath(profileRoot, entryName) {
  if (!serverDbEntryNames.includes(entryName)) {
    throw createHttpError(400, "Unsupported server DB entry");
  }
  return join(profileRoot, "db", entryName);
}

function readServerDbMetadata(profileRoot) {
  const filePath = serverDbMetadataPath(profileRoot);
  if (!existsSync(filePath)) return {};
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    return {};
  }
}

function writeServerDbMetadata(profileRoot, metadata) {
  mkdirSync(profileRoot, { recursive: true });
  writeFileSync(
    serverDbMetadataPath(profileRoot),
    JSON.stringify(metadata, null, 2),
  );
}

function serverDbFileInfo(profileRoot, entryName) {
  const filePath = serverDbEntryPath(profileRoot, entryName);
  if (!existsSync(filePath)) return { exists: false };
  const stat = statSync(filePath);
  const bytes = readFileSync(filePath);
  return {
    exists: true,
    size: stat.size,
    modifiedAt: stat.mtimeMs,
    sha256: backupSha256(bytes),
  };
}

function serverDbStatus(serverDataRoot, profileId) {
  const profileRoot = serverDbProfileRoot(serverDataRoot, profileId);
  const databases = {};
  for (const entryName of serverDbEntryNames) {
    databases[entryName] = serverDbFileInfo(profileRoot, entryName);
  }
  const appdataPath = join(profileRoot, "appdata.json");
  const hasAppdata = existsSync(appdataPath);
  const metadata = readServerDbMetadata(profileRoot);
  return {
    ok: true,
    profile: profileId,
    initialized:
      hasAppdata ||
      Object.values(databases).some((info) => info && info.exists === true),
    metadata,
    appdata: hasAppdata
      ? {
          exists: true,
          size: statSync(appdataPath).size,
          modifiedAt: statSync(appdataPath).mtimeMs,
        }
      : { exists: false },
    databases,
  };
}

function writeServerDbBackup(profileRoot, entries) {
  let writtenDatabases = 0;
  for (const entryName of serverDbEntryNames) {
    const bytes = entries.get(entryName);
    if (!bytes) continue;
    const filePath = serverDbEntryPath(profileRoot, entryName);
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, bytes);
    writtenDatabases += 1;
  }
  const appdata = entries.get("appdata.json");
  if (appdata) {
    writeServerDbAppdata(profileRoot, appdata);
  }
  const implicitDataEntry = entries.get("implicitData.json");
  if (implicitDataEntry) {
    mkdirSync(profileRoot, { recursive: true });
    writeFileSync(join(profileRoot, "implicitData.json"), implicitDataEntry);
  }
  const comicSources = writeServerDbComicSources(profileRoot, entries, {
    replace: true,
  });
  return {
    writtenDatabases,
    writtenAppdata: !!appdata,
    ...comicSources,
  };
}

function sqliteValueToNumber(value) {
  if (value == null) return null;
  if (typeof value === "object" && value.$bigint != null) {
    const number = Number(value.$bigint);
    return Number.isFinite(number) ? number : null;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function cookieRecordsFromServerDbCookieBuffer(dbBuf) {
  const data = extractSqliteData(dbBuf);
  const table = data.tables.find((item) => item.name === "cookies");
  if (!table) return [];
  const columns = new Map(
    table.columns.map((column, index) => [String(column).toLowerCase(), index]),
  );
  const columnValue = (row, name) => {
    const index = columns.get(name.toLowerCase());
    return index == null ? null : row[index];
  };
  return table.rows
    .map((row) => {
      const domain = String(columnValue(row, "domain") || "").trim();
      return {
        name: String(columnValue(row, "name") || ""),
        value: String(columnValue(row, "value") ?? ""),
        domain,
        path: String(columnValue(row, "path") || "/"),
        expiresMs: sqliteValueToNumber(columnValue(row, "expires")),
        secure: sqliteValueToNumber(columnValue(row, "secure")) === 1,
        httpOnly: sqliteValueToNumber(columnValue(row, "httpOnly")) === 1,
        hostOnly: !domain.startsWith("."),
      };
    })
    .filter((cookie) => cookie.name && cookie.domain);
}

function importServerDbCookieDbToJar(profileRoot, cookieJar, persistCookieJar) {
  const filePath = serverDbEntryPath(profileRoot, "cookie.db");
  if (!existsSync(filePath)) return [];
  const fileSize = statSync(filePath).size;
  if (fileSize === 0) return [];
  // Use native SQLite to read cookie.db (handles all formats correctly)
  try {
    const db = new DatabaseSync(filePath, { readOnly: true });
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all();
    if (!tables.some(t => t.name === "cookies")) { db.close(); return []; }
    const rows = db.prepare("SELECT name, value, domain, path, expires, secure, httpOnly FROM cookies").all();
    db.close();
    // Don't pass expiresMs — the Flutter app doesn't enforce expiration,
    // so treat all imported cookies as session cookies (never expire in jar)
    const records = rows.map(row => ({
      name: String(row.name || ""),
      value: String(row.value || ""),
      domain: String(row.domain || ""),
      path: String(row.path || "/"),
      secure: !!row.secure,
      httpOnly: !!row.httpOnly,
    })).filter(r => r.name && r.domain);
    return importCookieRecords(cookieJar, records, persistCookieJar);
  } catch {
    // Fallback to custom parser for older/simpler formats
    const records = cookieRecordsFromServerDbCookieBuffer(readFileSync(filePath));
    return importCookieRecords(cookieJar, records, persistCookieJar);
  }
}

function ensureCookieDbSchema(db) {
  db.exec(`
    create table if not exists cookies (
      name TEXT NOT NULL,
      value TEXT NOT NULL,
      domain TEXT NOT NULL,
      path TEXT,
      expires INTEGER,
      secure INTEGER,
      httpOnly INTEGER,
      PRIMARY KEY (name, domain, path)
    );
  `);
}

async function exportCookieJarToServerDbCookieDb(
  profileRoot,
  cookieJar,
  { createIfEmpty = false } = {},
) {
  const cookies = exportCookieRecords(cookieJar);
  const filePath = serverDbEntryPath(profileRoot, "cookie.db");
  if (cookies.length === 0 && !existsSync(filePath) && !createIfEmpty) {
    return false;
  }
  const db = await openWritableSqliteDatabase(filePath);
  try {
    ensureCookieDbSchema(db);
    db.exec("delete from cookies;");
    const statement = db.prepare(`
      insert or replace into cookies (
        name, value, domain, path, expires, secure, httpOnly
      ) values (?, ?, ?, ?, ?, ?, ?);
    `);
    for (const cookie of cookies) {
      statement.run(
        cookie.name,
        cookie.value,
        cookie.domain,
        cookie.path || "/",
        cookie.expiresMs,
        cookie.secure ? 1 : 0,
        cookie.httpOnly ? 1 : 0,
      );
    }
    return true;
  } finally {
    db.close();
  }
}

function emptyServerDbAppdata() {
  return { settings: {}, searchHistory: [] };
}

function writeServerDbAppdata(profileRoot, data) {
  mkdirSync(profileRoot, { recursive: true });
  let parsed = null;
  if (Buffer.isBuffer(data)) {
    try { parsed = JSON.parse(data.toString("utf8")); } catch { /* raw buffer */ }
  } else {
    parsed = data;
  }
  if (parsed && parsed.implicitData && typeof parsed.implicitData === "object") {
    const implicitData = parsed.implicitData;
    const withoutImplicit = { ...parsed };
    delete withoutImplicit.implicitData;
    writeFileSync(join(profileRoot, "implicitData.json"), JSON.stringify(implicitData, null, 2));
    const appdataBytes = Buffer.from(JSON.stringify(withoutImplicit, null, 2));
    writeFileSync(join(profileRoot, "appdata.json"), appdataBytes);
    return appdataBytes;
  }
  const appdataBytes = Buffer.isBuffer(data)
    ? data
    : Buffer.from(JSON.stringify(data || {}, null, 2));
  writeFileSync(join(profileRoot, "appdata.json"), appdataBytes);
  return appdataBytes;
}

function normalizeComicSourceBackupEntries(rawSources) {
  if (!Array.isArray(rawSources)) {
    return [];
  }
  const result = [];
  for (const source of rawSources) {
    if (!source || typeof source !== "object") continue;
    const name = String(source.name || "").trim();
    if (!/^[^/\\]+\.(?:js|data)$/.test(name)) {
      throw createHttpError(400, "Invalid comic source backup entry");
    }
    const dataBase64 = String(source.dataBase64 || "");
    const data = Buffer.from(dataBase64, "base64");
    result.push({ name: `comic_source/${name}`, data });
  }
  return result;
}

function isComicSourceBackupEntryName(name) {
  return /^comic_source\/[^/\\]+\.(?:js|data)$/.test(String(name || ""));
}

function serverDbComicSourceDir(profileRoot) {
  return join(profileRoot, "comic_source");
}

function writeServerDbComicSources(profileRoot, entries, { replace = false } = {}) {
  const sourceEntries = [];
  for (const [entryName, data] of entries) {
    if (!isComicSourceBackupEntryName(entryName) || !Buffer.isBuffer(data)) {
      continue;
    }
    sourceEntries.push({ name: entryName.replace("comic_source/", ""), data });
  }
  const targetDir = serverDbComicSourceDir(profileRoot);
  if (replace) {
    rmSync(targetDir, { recursive: true, force: true });
  }
  if (sourceEntries.length === 0) {
    return { writtenComicSources: 0 };
  }
  mkdirSync(targetDir, { recursive: true });
  for (const entry of sourceEntries) {
    writeFileSync(join(targetDir, entry.name), entry.data);
  }
  return { writtenComicSources: sourceEntries.length };
}

function readServerDbComicSourceEntries(profileRoot) {
  const targetDir = serverDbComicSourceDir(profileRoot);
  if (!existsSync(targetDir)) return [];
  return readdirSync(targetDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .filter((entry) => /^[^/\\]+\.(?:js|data)$/.test(entry.name))
    .map((entry) => ({
      name: `comic_source/${entry.name}`,
      data: readFileSync(join(targetDir, entry.name)),
    }));
}

function readServerDbComicSourcePayload(profileRoot) {
  return readServerDbComicSourceEntries(profileRoot).map((entry) => {
    const fileName = entry.name.replace("comic_source/", "");
    const sourceKey = fileName.replace(/\.(?:js|data)$/i, "");
    const metadata = fileName.toLowerCase().endsWith(".js")
      ? extractComicSourceMetadata(entry.data.toString("utf8"), sourceKey)
      : {};
    return {
      name: fileName,
      ...metadata,
      dataBase64: entry.data.toString("base64"),
    };
  });
}

function ensureEmptySqliteDbSchema(db) {
  db.exec(`
    create table if not exists __venera_empty_marker (id integer primary key);
    drop table __venera_empty_marker;
  `);
}

async function ensureServerDbBackupDatabase(profileRoot, entryName, initialize) {
  const filePath = serverDbEntryPath(profileRoot, entryName);
  if (existsSync(filePath) && statSync(filePath).size > 0) return;
  const db = await openWritableSqliteDatabase(filePath);
  try {
    initialize(db);
  } finally {
    db.close();
  }
}

async function ensureServerDbBackupDatabases(profileRoot) {
  await ensureServerDbBackupDatabase(
    profileRoot,
    "data/venera.db",
    ensureEmptySqliteDbSchema,
  );
  await ensureServerDbBackupDatabase(
    profileRoot,
    "history.db",
    (db) => {
      ensureHistoryDbSchema(db);
      ensureComicBasicInfoSchema(db);
    },
  );
  await ensureServerDbBackupDatabase(
    profileRoot,
    "local_favorite.db",
    ensureFavoriteDbSchema,
  );
  await ensureServerDbBackupDatabase(
    profileRoot,
    "cookie.db",
    ensureCookieDbSchema,
  );
}

async function buildServerDbBackup(profileRoot, appdataPayload, comicSourcesPayload) {
  await ensureServerDbBackupDatabases(profileRoot);

  const entries = [];
  let databaseCount = 0;
  let appdataBytes = null;

  if (appdataPayload && typeof appdataPayload === "object") {
    appdataBytes = writeServerDbAppdata(profileRoot, appdataPayload);
  } else {
    const appdataPath = join(profileRoot, "appdata.json");
    if (existsSync(appdataPath)) {
      appdataBytes = readFileSync(appdataPath);
    } else {
      appdataBytes = Buffer.from(
        JSON.stringify(emptyServerDbAppdata(), null, 2),
      );
    }
  }

  if (appdataBytes) {
    entries.push({ name: "appdata.json", data: appdataBytes });
  }

  const payloadComicSources = normalizeComicSourceBackupEntries(comicSourcesPayload);
  if (Array.isArray(comicSourcesPayload)) {
    writeServerDbComicSources(
      profileRoot,
      new Map(payloadComicSources.map((entry) => [entry.name, entry.data])),
      { replace: true },
    );
  }
  entries.push(...readServerDbComicSourceEntries(profileRoot));

  for (const entryName of serverDbEntryNames) {
    const filePath = serverDbEntryPath(profileRoot, entryName);
    if (!existsSync(filePath)) continue;
    const data = readFileSync(filePath);
    if (data.length === 0) continue;
    entries.push({ name: entryName, data });
    databaseCount += 1;
  }

  if (databaseCount === 0 && entries.length === 0) {
    throw createHttpError(409, "Server DB is not initialized");
  }
  return {
    buffer: buildStoredZip(entries),
    databaseCount,
    entryNames: entries.map((entry) => entry.name),
  };
}

function readServerDbJsonDump(profileRoot) {
  const databases = {};
  for (const entryName of serverDbEntryNames) {
    const filePath = serverDbEntryPath(profileRoot, entryName);
    if (!existsSync(filePath)) continue;
    const data = readFileSync(filePath);
    let extracted = null;
    try {
      extracted = extractSqliteData(data);
    } catch { /* keep raw dump for unsupported sqlite shapes */ }
    databases[entryName] = {
      dataBase64: data.toString("base64"),
      ...(extracted || {}),
    };
  }

  const appdataPath = join(profileRoot, "appdata.json");
  let appdata = null;
  if (existsSync(appdataPath)) {
    try {
      appdata = JSON.parse(readFileSync(appdataPath, "utf8"));
    } catch {
      appdata = {
        dataBase64: readFileSync(appdataPath).toString("base64"),
      };
    }
  }

  return {
    format: "venera-server-db-dump-v1",
    appdata,
    comicSources: readServerDbComicSourcePayload(profileRoot),
    databases,
  };
}

function writeServerDbJsonDump(profileRoot, data) {
  if (!data || typeof data !== "object") {
    throw createHttpError(400, "Invalid server DB import payload");
  }

  if (data.dataBase64 || data.backupDataBase64) {
    const backup = Buffer.from(String(data.dataBase64 || data.backupDataBase64), "base64");
    assertLooksLikeVeneraBackup(backup, "imported backup");
    const entries = extractZipEntries(
      backup,
      (name) =>
        serverDbBackupEntryNames.includes(name) ||
        isComicSourceBackupEntryName(name),
    );
    return writeServerDbBackup(profileRoot, entries);
  }

  let writtenDatabases = 0;
  const databases = data.databases && typeof data.databases === "object"
    ? data.databases
    : {};
  for (const entryName of serverDbEntryNames) {
    const entry = databases[entryName];
    const dataBase64 = typeof entry === "string" ? entry : entry?.dataBase64;
    if (!dataBase64) continue;
    const bytes = Buffer.from(String(dataBase64), "base64");
    const filePath = serverDbEntryPath(profileRoot, entryName);
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, bytes);
    writtenDatabases += 1;
  }

  let writtenAppdata = false;
  if (data.appdata != null) {
    if (
      data.appdata &&
      typeof data.appdata === "object" &&
      typeof data.appdata.dataBase64 === "string"
    ) {
      mkdirSync(profileRoot, { recursive: true });
      writeFileSync(
        join(profileRoot, "appdata.json"),
        Buffer.from(data.appdata.dataBase64, "base64"),
      );
    } else {
      writeServerDbAppdata(profileRoot, data.appdata);
    }
    writtenAppdata = true;
  }

  const comicSourceEntries = normalizeComicSourceBackupEntries(data.comicSources);
  const comicSources = Array.isArray(data.comicSources)
    ? writeServerDbComicSources(
        profileRoot,
        new Map(comicSourceEntries.map((entry) => [entry.name, entry.data])),
        { replace: true },
      )
    : { writtenComicSources: 0 };

  if (writtenDatabases === 0 && !writtenAppdata && comicSources.writtenComicSources === 0) {
    throw createHttpError(422, "Import payload does not contain supported data");
  }
  return { writtenDatabases, writtenAppdata, ...comicSources };
}

function historyRowsFromServerDb(profileRoot, { limit = 100, offset = 0 } = {}) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  if (!existsSync(filePath)) {
    return { total: 0, items: [] };
  }
  const data = extractSqliteData(readFileSync(filePath));
  const table = data.tables.find((item) => item.name === "history");
  if (!table) {
    return { total: 0, items: [] };
  }

  // Build a lookup from favorites for enrichment (id+type → metadata)
  const favLookup = new Map();
  const favPath = serverDbEntryPath(profileRoot, "local_favorite.db");
  if (existsSync(favPath)) {
    try {
      const favData = extractSqliteData(readFileSync(favPath));
      for (const favTable of favData.tables || []) {
        const name = favTable.name || "";
        if (name.startsWith("sqlite_") || name === "folder_order" || name === "folder_sync") continue;
        for (const favRow of favTable.rows) {
          const favItem = {};
          for (let i = 0; i < favTable.columns.length; i++) {
            favItem[favTable.columns[i]] = favRow[i];
          }
          const fid = String(favItem.id || "").trim();
          const ftype = Number(favItem.type);
          if (fid && Number.isInteger(ftype)) {
            const key = `${fid} ${ftype}`;
            if (!favLookup.has(key)) {
              favLookup.set(key, favItem);
            }
          }
        }
      }
    } catch (_) { /* favorites unavailable, proceed without enrichment */ }
  }

  const rows = table.rows.map((row) => {
    const item = {};
    for (let index = 0; index < table.columns.length; index++) {
      item[table.columns[index]] = row[index];
    }
    const readEpisode = String(item.readEpisode || "")
      .split(",")
      .filter(Boolean);
    const id = String(item.id || "");
    const type = Number(item.type || 0);
    const fav = favLookup.get(`${id} ${type}`);

    return {
      id,
      title: String(item.title || ""),
      subtitle: fav?.author || String(item.subtitle || ""),
      cover: String(item.cover || fav?.cover_path || ""),
      time: Number(item.time || 0),
      type,
      ep: Number(item.ep || 0),
      page: Number(item.page || 0),
      readEpisode,
      max_page: item.max_page == null ? null : Number(item.max_page),
      chapter_group: item.chapter_group == null ? null : Number(item.chapter_group),
      // Enriched fields from favorites
      author: fav?.author || "",
      tags: fav?.tags || "",
      status: fav?.status || "",
      lastUpdateTime: fav?.last_update_time == null ? null : String(fav.last_update_time),
    };
  });
  rows.sort((a, b) => b.time - a.time);
  const safeOffset = Math.max(0, Number(offset) || 0);
  const safeLimit = Math.max(1, Math.min(500, Number(limit) || 100));
  return {
    total: rows.length,
    items: rows.slice(safeOffset, safeOffset + safeLimit),
  };
}

function imageFavoriteRowsFromServerDb(
  profileRoot,
  { limit = 500, offset = 0 } = {},
) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  if (!existsSync(filePath)) {
    return { total: 0, items: [] };
  }
  const data = extractSqliteData(readFileSync(filePath));
  const table = data.tables.find((item) => item.name === "image_favorites");
  if (!table) {
    return { total: 0, items: [] };
  }
  const rows = table.rows.map((row) => {
    const item = {};
    for (let index = 0; index < table.columns.length; index++) {
      item[table.columns[index]] = row[index];
    }
    let imageFavoritesEp = [];
    let other = {};
    try {
      imageFavoritesEp = JSON.parse(String(item.image_favorites_ep || "[]"));
    } catch {}
    try {
      other = JSON.parse(String(item.other || "{}"));
    } catch {}
    return {
      id: String(item.id || ""),
      title: String(item.title || ""),
      subTitle: String(item.sub_title || ""),
      author: String(item.author || ""),
      tags: splitFavoriteTags(item.tags),
      translatedTags: splitFavoriteTags(item.translated_tags),
      time: Number(item.time || 0),
      maxPage: Number(item.max_page || 0),
      sourceKey: String(item.source_key || ""),
      imageFavoritesEp: Array.isArray(imageFavoritesEp) ? imageFavoritesEp : [],
      other: other && typeof other === "object" ? other : {},
    };
  });
  rows.sort((a, b) => b.time - a.time);
  const safeOffset = Math.max(0, Number(offset) || 0);
  const safeLimit = Math.max(1, Math.min(500, Number(limit) || 500));
  return {
    total: rows.length,
    items: rows.slice(safeOffset, safeOffset + safeLimit),
  };
}

async function openWritableSqliteDatabase(filePath) {
  let sqlite;
  try {
    sqlite = await import("node:sqlite");
  } catch {
    throw createHttpError(501, "SQLite write support requires node:sqlite");
  }
  mkdirSync(dirname(filePath), { recursive: true });
  return new sqlite.DatabaseSync(filePath);
}

function ensureHistoryDbSchema(db) {
  db.exec(`
    create table if not exists history (
      id text,
      title text,
      subtitle text,
      cover text,
      time int,
      type int,
      ep int,
      page int,
      readEpisode text,
      max_page int,
      chapter_group int,
      primary key (id, type)
    );
  `);
  const columns = db.prepare("PRAGMA table_info(history);").all();
  if (!columns.some((column) => column.name === "chapter_group")) {
    db.exec("alter table history add column chapter_group int;");
  }
}

function ensureComicBasicInfoSchema(db) {
  db.exec(`
    create table if not exists comic_basic_info (
      comic_id text primary key,
      title text not null,
      subtitle text not null default '',
      description text not null default '',
      author text,
      status text,
      update_time text,
      language text,
      cover_uri text,
      tags_json text,
      page_count integer,
      base_info_updated_at integer not null default 0
    );
  `);
}

function backfillComicBasicInfoFromHistory(db) {
  const count = db.prepare(
    "select count(*) as cnt from comic_basic_info;",
  ).all()[0]?.cnt ?? 0;
  if (count > 0) return;
  const rows = db.prepare(`
    select distinct h.id, h.title, h.subtitle, h.cover, h.type, h.max_page
    from history h
    where h.title != ''
    limit 500;
  `).all();
  for (const row of rows) {
    try {
      db.prepare(`
        insert into comic_basic_info
          (comic_id, title, subtitle, cover_uri, page_count, base_info_updated_at)
        values (?, ?, ?, ?, ?, ?)
        on conflict(comic_id) do update set
          title = excluded.title,
          subtitle = coalesce(excluded.subtitle, comic_basic_info.subtitle),
          cover_uri = coalesce(excluded.cover_uri, comic_basic_info.cover_uri),
          page_count = coalesce(excluded.page_count, comic_basic_info.page_count);
      `).run(
        String(row.id),
        String(row.title || ""),
        row.subtitle || null,
        row.cover || null,
        typeof row.max_page === "number" ? row.max_page : null,
        Date.now(),
      );
    } catch { /* skip malformed rows */ }
  }
}

function extractComicUpdateTime(comic) {
  if (!comic || typeof comic !== "object") return null;
  if (comic.updateTime && typeof comic.updateTime === "string") {
    const m = comic.updateTime.match(/(\d{4})-(\d{2})-(\d{2})/);
    if (m) {
      const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
      if (y >= 2000 && y <= 3000 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
        return comic.updateTime;
      }
    }
  }
  const tags = comic.tags;
  if (tags && typeof tags === "object") {
    const namespaces = ["更新", "最後更新", "最后更新", "update", "last update"];
    for (const ns of namespaces) {
      const vals = Array.isArray(tags) ? null : tags[ns];
      if (vals && Array.isArray(vals) && vals.length > 0) {
        const v = String(vals[0]);
        const m = v.match(/(\d{4})-(\d{2})-(\d{2})/);
        if (m) {
          const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
          if (y >= 2000 && y <= 3000 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
            return v;
          }
        }
      }
    }
  }
  return null;
}

// Legacy numeric type → source key mapping (mirrors client-side LEGACY_SOURCE_KEYS)
const LEGACY_SOURCE_KEYS = {
  1: "ehentai", 2: "jm", 3: "hitomi", 4: "wnacg", 5: "nhentai", 6: "nhentai",
  29663848: "hot_manga", 42816288: "manwaba", 150465061: "zaimanhua",
  233488852: "baozi", 236897507: "hcomic", 258019538: "hitomi",
  264196719: "nhentai", 331263271: "shonen_jump_plus", 385625716: "ehentai",
  550146035: "goda", 553570794: "picacg", 557997769: "copy_manga",
  577341847: "mh1234", 577718694: "manga_dex", 631413104: "manhuaren",
  637999886: "Komiic", 716010982: "ikmmh", 740690276: "jcomic",
  769844263: "jm", 771282371: "mxs", 778108598: "mh18",
  798816513: "ykmh", 807338462: "ccc", 823512256: "wnacg",
  964788560: "comick", 977805693: "happy", 981441865: "ManHuaGui",
};

function sourceKeyFromType(type) {
  if (type == null || type === 0) return "";
  return LEGACY_SOURCE_KEYS[type] || "";
}

async function checkFollowUpdatesFolder(
  profileRoot,
  folder,
  ignoreCheckTime,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
  taskState,
) {
  if (taskState) {
    taskState.status = "running";
    taskState.startTime = Date.now();
  }
  const items = [];
  await withWritableFavoriteDb(profileRoot, (db) => {
    const rows = db
      .prepare(`select * from ${sqliteIdentifier(folder)};`)
      .all();
    for (const row of rows) {
      const item = favoriteItemFromRow(row);
      if (item.type === 0) continue; // skip local comics
      const sourceKey = item.sourceKey || sourceKeyFromType(item.type);
      if (!sourceKey) continue;
      item.sourceKey = sourceKey;
      const lastCheck = item.lastCheckTime;
      if (!ignoreCheckTime && lastCheck != null) {
        const hoursSince = (Date.now() - lastCheck) / 3600000;
        if (hoursSince < 24) continue;
      }
      items.push(item);
    }
  });

  if (taskState) {
    taskState.total = items.length;
  }

  let checked = 0;
  const updated = [];
  for (const item of items) {
    if (taskState?.cancelled) break;
    checked++;
    if (taskState) {
      taskState.checked = checked;
      taskState.currentItem = item.name || item.title || item.id;
    }
    try {
      const result = await executeSourceMethod({
        profileRoot,
        sourceKey: item.sourceKey,
        method: "getComicInfo",
        args: [item.id],
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      const comic = result?.comic ?? result ?? {};
      const newUpdateTime = extractComicUpdateTime(comic);
      const newTitle = comic.title ?? item.name;
      const newCover = comic.cover ?? item.coverPath;
      const newAuthor = comic.subtitle ?? comic.subTitle ?? item.author;
      const newTags = Array.isArray(comic.tags)
        ? comic.tags
        : (comic.tags && typeof comic.tags === "object"
          ? Object.entries(comic.tags).flatMap(([ns, vals]) =>
              Array.isArray(vals) ? vals.map((v) => `${ns}:${v}`) : [`${ns}:${v}`])
          : (item.tags ? String(item.tags).split(",").filter(Boolean) : []));

      // Update comic_basic_info
      try {
        await withWritableHistoryDb(profileRoot, (db) => {
          saveComicBasicInfo(db, item.sourceKey, {
            id: item.id,
            title: newTitle,
            subtitle: newAuthor || null,
            cover: newCover || null,
            author: comic.author || null,
            status: comic.status || null,
            description: comic.description || null,
            tags: newTags,
            updateTime: newUpdateTime,
            maxPage: comic.maxPage ?? comic.pageCount ?? null,
          });
        });
      } catch { /* best-effort */ }

      // Update favorite item info
      await withWritableFavoriteDb(profileRoot, (db) => {
        ensureFavoriteFolderTable(db, folder);
        const quotedTable = sqliteIdentifier(folder);
        db.prepare(
          `update ${quotedTable}
           set name = ?, author = ?, cover_path = ?, tags = ?,
               last_check_time = ?
           where id = ? and type = ?;`,
        ).run(
          newTitle,
          newAuthor,
          newCover || "",
          newTags.join(","),
          Date.now(),
          item.id,
          item.type,
        );
        // Compare and set has_new_update
        const oldTime = item.lastUpdateTime || null;
        if (newUpdateTime && newUpdateTime !== oldTime) {
          db.prepare(
            `update ${quotedTable}
             set last_update_time = ?, has_new_update = 1
             where id = ? and type = ?;`,
          ).run(newUpdateTime, item.id, item.type);
          updated.push({
            id: item.id,
            type: item.type,
            title: newTitle,
            updateTime: newUpdateTime,
          });
        } else if (newUpdateTime && newUpdateTime === oldTime) {
          db.prepare(
            `update ${quotedTable}
             set has_new_update = 0
             where id = ? and type = ?;`,
          ).run(item.id, item.type);
        }
      });
    } catch {
      // Update last_check_time even on failure
      try {
        await withWritableFavoriteDb(profileRoot, (db) => {
          db.prepare(
            `update ${sqliteIdentifier(folder)}
             set last_check_time = ?
             where id = ? and type = ?;`,
          ).run(Date.now(), item.id, item.type);
        });
      } catch { /* ignore */ }
    }
  }
  if (taskState?.cancelled) {
    taskState.status = "cancelled";
    taskState.endTime = Date.now();
  }
  return { checked, updated };
}

function ensureImageFavoritesDbSchema(db) {
  db.exec(`
    create table if not exists image_favorites (
      id text,
      title text not null,
      sub_title text,
      author text,
      tags text,
      translated_tags text,
      time int,
      max_page int,
      source_key text not null,
      image_favorites_ep text not null,
      other text not null,
      primary key (id, source_key)
    );
  `);
}

function normalizeHistoryPayload(payload) {
  const history = payload?.history;
  if (!history || typeof history !== "object") {
    throw createHttpError(400, "Missing history payload");
  }
  const id = String(history.id || "").trim();
  const title = String(history.title || "");
  const type = Number(history.type);
  if (!id || !Number.isInteger(type)) {
    throw createHttpError(400, "Invalid history payload");
  }
  const readEpisode = Array.isArray(history.readEpisode)
    ? history.readEpisode.map((item) => String(item)).filter(Boolean).join(",")
    : String(history.readEpisode || "");
  const nullableNumber = (value) => {
    if (value == null || value === "") return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };
  return {
    id,
    title,
    subtitle: String(history.subtitle || ""),
    cover: String(history.cover || ""),
    time: nullableNumber(history.time) || Date.now(),
    type,
    sourceKey: String(history.sourceKey ?? history.source_key ?? ""),
    ep: nullableNumber(history.ep) || 0,
    page: nullableNumber(history.page) || 0,
    readEpisode,
    maxPage: nullableNumber(history.max_page),
    chapterGroup: nullableNumber(history.chapter_group),
  };
}

function normalizeImageFavoritePayload(item) {
  if (!item || typeof item !== "object") {
    throw createHttpError(400, "Invalid image favorite item");
  }
  const id = String(item.id || "").trim();
  const sourceKey = String(item.sourceKey ?? item.source_key ?? "").trim();
  if (!id || !sourceKey) {
    throw createHttpError(400, "Invalid image favorite item");
  }
  const listValue = (value) => {
    if (Array.isArray(value)) return value.map((entry) => String(entry)).join(",");
    return String(value || "");
  };
  const numberValue = (value, fallback = 0) => {
    const number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  };
  const imageFavoritesEp = Array.isArray(item.imageFavoritesEp)
    ? item.imageFavoritesEp
    : Array.isArray(item.image_favorites_ep)
      ? item.image_favorites_ep
      : [];
  const other =
    item.other && typeof item.other === "object" && !Array.isArray(item.other)
      ? item.other
      : {};
  return {
    id,
    title: String(item.title || ""),
    subTitle: String(item.subTitle ?? item.sub_title ?? ""),
    author: String(item.author || ""),
    tags: listValue(item.tags),
    translatedTags: listValue(item.translatedTags ?? item.translated_tags),
    time: numberValue(item.time, Date.now()),
    maxPage: numberValue(item.maxPage ?? item.max_page, 0),
    sourceKey,
    imageFavoritesEp: JSON.stringify(imageFavoritesEp),
    other: JSON.stringify(other),
  };
}

function sqliteIdentifier(name) {
  return `"${String(name).replaceAll('"', '""')}"`;
}

const nonFavoriteTableNames = new Set([
  "folder_sync",
  "folder_order",
  "comic_links",
  "sqlite_sequence",
]);

function favoriteHistoryKeysFromServerDb(profileRoot) {
  const filePath = serverDbEntryPath(profileRoot, "local_favorite.db");
  if (!existsSync(filePath)) return new Set();
  return openWritableSqliteDatabase(filePath).then((db) => {
    try {
      const keys = new Set();
      const tables = favoriteTableNames(db);
      for (const tableName of tables) {
        const quotedTable = sqliteIdentifier(tableName);
        for (const row of db.prepare(`select id, type from ${quotedTable};`).all()) {
          const id = String(row.id || "").trim();
          const type = Number(row.type);
          if (id && Number.isInteger(type)) {
            keys.add(`${id}\u0000${type}`);
          }
        }
      }
      return keys;
    } finally {
      db.close();
    }
  });
}

function tableExists(db, tableName) {
  const row = db
    .prepare("select name from sqlite_master where type = 'table' and name = ?;")
    .get(tableName);
  return row != null;
}

function favoriteTableNames(db) {
  return db
    .prepare("select name from sqlite_master where type = 'table';")
    .all()
    .map((row) => String(row.name || ""))
    .filter((name) => name && !name.startsWith("sqlite_"))
    .filter((name) => !nonFavoriteTableNames.has(name))
    .filter((name) => {
      const quotedTable = sqliteIdentifier(name);
      const columns = db.prepare(`PRAGMA table_info(${quotedTable});`).all();
      return (
        columns.some((column) => column.name === "id") &&
        columns.some((column) => column.name === "type")
      );
    });
}

function splitFavoriteTags(value) {
  return String(value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeFavoriteRow(row, folderName) {
  return {
    folder: folderName,
    id: String(row.id || ""),
    name: String(row.name || ""),
    author: String(row.author || ""),
    type: Number(row.type || 0),
    tags: splitFavoriteTags(row.tags),
    coverPath: String(row.cover_path || ""),
    time: String(row.time || ""),
    displayOrder: Number(row.display_order || 0),
    translatedTags: splitFavoriteTags(row.translated_tags),
    lastUpdateTime:
      row.last_update_time == null ? null : String(row.last_update_time),
    hasNewUpdate: Number(row.has_new_update || 0) === 1,
    lastCheckTime:
      row.last_check_time == null ? null : Number(row.last_check_time),
  };
}

async function withFavoriteDb(profileRoot, callback) {
  const filePath = serverDbEntryPath(profileRoot, "local_favorite.db");
  if (!existsSync(filePath)) {
    throw createHttpError(404, "Server favorites DB not found");
  }
  const db = await openWritableSqliteDatabase(filePath);
  try {
    return callback(db);
  } finally {
    db.close();
  }
}

const favoriteFolderColumnDefinitions = [
  ["id", "text"],
  ["name", "text"],
  ["author", "text"],
  ["type", "int"],
  ["tags", "text"],
  ["cover_path", "text"],
  ["time", "text"],
  ["display_order", "int"],
  ["translated_tags", "text"],
  ["source_key", "text"],
  ["last_update_time", "text"],
  ["has_new_update", "int"],
  ["last_check_time", "int"],
];

function normalizeFavoriteFolderName(value, fieldName = "folder") {
  const name = String(value || "").trim();
  if (
    !name ||
    name.toLowerCase().startsWith("sqlite_") ||
    nonFavoriteTableNames.has(name)
  ) {
    throw createHttpError(400, `Invalid favorites ${fieldName}`);
  }
  return name;
}

function favoriteTagsValue(value) {
  if (Array.isArray(value)) {
    const tags = value.map((item) => String(item).trim()).filter(Boolean);
    return tags.length === 0 ? "" : `${tags.join(",")},`;
  }
  return String(value || "");
}

function ensureFavoriteDbSchema(db) {
  db.exec(`
    create table if not exists folder_order (
      folder_name text primary key,
      order_value int
    );
    create table if not exists folder_sync (
      folder_name text primary key,
      source_key text,
      source_folder text
    );
  `);
}

function favoriteColumnNames(db, folderName) {
  const quotedTable = sqliteIdentifier(folderName);
  return new Set(
    db
      .prepare(`PRAGMA table_info(${quotedTable});`)
      .all()
      .map((column) => String(column.name || "")),
  );
}

function ensureFavoriteFolderTable(db, folderName) {
  const quotedTable = sqliteIdentifier(folderName);
  if (!tableExists(db, folderName)) {
    db.exec(`
      create table ${quotedTable} (
        id text,
        name text,
        author text,
        type int,
        tags text,
        cover_path text,
        time text,
        display_order int,
        translated_tags text,
        last_update_time text,
        has_new_update int,
        last_check_time int,
        primary key (id, type)
      );
    `);
    return;
  }
  const columns = favoriteColumnNames(db, folderName);
  if (!columns.has("id") || !columns.has("type")) {
    throw createHttpError(422, "Favorites folder schema is invalid");
  }
  for (const [name, type] of favoriteFolderColumnDefinitions) {
    if (!columns.has(name)) {
      db.exec(
        `alter table ${quotedTable} add column ${sqliteIdentifier(name)} ${type};`,
      );
    }
  }
}

async function withWritableFavoriteDb(profileRoot, callback) {
  const filePath = serverDbEntryPath(profileRoot, "local_favorite.db");
  const db = await openWritableSqliteDatabase(filePath);
  try {
    ensureFavoriteDbSchema(db);
    return callback(db);
  } finally {
    db.close();
  }
}

function nextFavoriteFolderName(db, name) {
  if (!tableExists(db, name)) return name;
  let index = 1;
  while (tableExists(db, `${name} (${index})`)) {
    index += 1;
  }
  return `${name} (${index})`;
}

function normalizeFavoriteWriteItem(payload) {
  const item = payload?.item;
  if (!item || typeof item !== "object") {
    throw createHttpError(400, "Missing favorite item");
  }
  const id = String(item.id || "").trim();
  const type = Number(item.type);
  if (!id || !Number.isInteger(type)) {
    throw createHttpError(400, "Invalid favorite item");
  }
  const nullableNumber = (value) => {
    if (value == null || value === "") return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };
  return {
    id,
    name: String(item.name ?? item.title ?? ""),
    author: String(item.author || ""),
    type,
    sourceKey: String(
      item.sourceKey ?? item.source_key ?? payload.sourceKey ?? "",
    ),
    tags: favoriteTagsValue(item.tags),
    coverPath: String(item.coverPath ?? item.cover_path ?? item.cover ?? ""),
    time: String(item.time ?? payload.updateTime ?? ""),
    displayOrder:
      nullableNumber(payload.order) ??
      nullableNumber(item.displayOrder) ??
      nullableNumber(item.display_order) ??
      0,
    translatedTags: favoriteTagsValue(
      item.translatedTags ?? item.translated_tags,
    ),
    lastUpdateTime:
      item.lastUpdateTime == null && item.last_update_time == null
        ? null
        : String(item.lastUpdateTime ?? item.last_update_time),
    hasNewUpdate: item.hasNewUpdate ?? item.has_new_update,
    lastCheckTime:
      nullableNumber(item.lastCheckTime) ?? nullableNumber(item.last_check_time),
  };
}

function favoriteWriteValue(item, column) {
  switch (column) {
    case "id":
      return item.id;
    case "name":
      return item.name;
    case "author":
      return item.author;
    case "type":
      return item.type;
    case "tags":
      return item.tags;
    case "cover_path":
      return item.coverPath;
    case "time":
      return item.time;
    case "display_order":
      return item.displayOrder;
    case "translated_tags":
      return item.translatedTags;
    case "source_key":
      return item.sourceKey || null;
    case "last_update_time":
      return item.lastUpdateTime;
    case "has_new_update":
      return item.hasNewUpdate ? 1 : 0;
    case "last_check_time":
      return item.lastCheckTime;
    default:
      return null;
  }
}

function writeFavoriteItem(db, folderName, item) {
  ensureFavoriteFolderTable(db, folderName);
  const columns = favoriteFolderColumnDefinitions.map(([name]) => name);
  const quotedColumns = columns.map(sqliteIdentifier).join(", ");
  const placeholders = columns.map(() => "?").join(", ");
  const quotedTable = sqliteIdentifier(folderName);
  db.prepare(
    `insert or replace into ${quotedTable} (${quotedColumns}) values (${placeholders});`,
  ).run(...columns.map((column) => favoriteWriteValue(item, column)));
}

function favoriteItemFromRow(row) {
  return {
    id: String(row.id || ""),
    name: String(row.name || ""),
    author: String(row.author || ""),
    type: Number(row.type || 0),
    tags: row.tags == null ? "" : String(row.tags),
    coverPath: String(row.cover_path || ""),
    time: String(row.time || ""),
    displayOrder: Number(row.display_order || 0),
    translatedTags:
      row.translated_tags == null ? "" : String(row.translated_tags),
    sourceKey: row.source_key == null ? "" : String(row.source_key),
    lastUpdateTime:
      row.last_update_time == null ? null : String(row.last_update_time),
    hasNewUpdate: Number(row.has_new_update || 0) === 1,
    lastCheckTime:
      row.last_check_time == null ? null : Number(row.last_check_time),
  };
}

function copyFavoriteItem(db, sourceFolder, targetFolder, id, type) {
  ensureFavoriteFolderTable(db, sourceFolder);
  ensureFavoriteFolderTable(db, targetFolder);
  const row = db
    .prepare(
      `select * from ${sqliteIdentifier(sourceFolder)} where id = ? and type = ?;`,
    )
    .get(id, type);
  if (!row) {
    throw createHttpError(404, "Favorite item not found");
  }
  writeFavoriteItem(db, targetFolder, favoriteItemFromRow(row));
}

function favoriteReadTime() {
  const date = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  return `${[
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
  ].join("-")} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function validateFavoriteIdType(payload, message) {
  const id = String(payload?.id || "").trim();
  const type = Number(payload?.type);
  if (!id || !Number.isInteger(type)) {
    throw createHttpError(400, message);
  }
  return { id, type };
}

function favoriteMinDisplayOrder(db, folder) {
  const row = db
    .prepare(`select min(display_order) as value from ${sqliteIdentifier(folder)};`)
    .get();
  return Number(row?.value || 0);
}

function favoriteMaxDisplayOrder(db, folder) {
  const row = db
    .prepare(`select max(display_order) as value from ${sqliteIdentifier(folder)};`)
    .get();
  return Number(row?.value || 0);
}

function favoriteFoldersFromDb(db) {
  const tables = favoriteTableNames(db);
  const orders = new Map();
  if (tableExists(db, "folder_order")) {
    for (const row of db.prepare("select * from folder_order;").all()) {
      orders.set(String(row.folder_name || ""), Number(row.order_value || 0));
    }
  }
  const syncLinks = new Map();
  if (tableExists(db, "folder_sync")) {
    for (const row of db.prepare("select * from folder_sync;").all()) {
      syncLinks.set(String(row.folder_name || ""), {
        sourceKey: row.source_key == null ? null : String(row.source_key),
        sourceFolder:
          row.source_folder == null ? null : String(row.source_folder),
      });
    }
  }
  return tables
    .map((name) => {
      const quotedTable = sqliteIdentifier(name);
      const countRow = db.prepare(`select count(*) as c from ${quotedTable};`).get();
      const syncLink = syncLinks.get(name) || {};
      return {
        name,
        count: Number(countRow?.c || 0),
        order: orders.get(name) || 0,
        sourceKey: syncLink.sourceKey ?? null,
        sourceFolder: syncLink.sourceFolder ?? null,
      };
    })
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
}

async function withWritableHistoryDb(profileRoot, callback) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  const db = await openWritableSqliteDatabase(filePath);
  try {
    ensureHistoryDbSchema(db);
    ensureComicBasicInfoSchema(db);
    backfillComicBasicInfoFromHistory(db);
    return callback(db);
  } finally {
    db.close();
  }
}

async function withWritableComicInfoDb(profileRoot, callback) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  const db = await openWritableSqliteDatabase(filePath);
  try {
    ensureHistoryDbSchema(db);
    ensureComicBasicInfoSchema(db);
    return callback(db);
  } finally {
    db.close();
  }
}

function saveComicBasicInfo(db, sourceKey, comic) {
  const comicId = `${sourceKey}:${comic.id}`;
  const tags = Array.isArray(comic.tags)
    ? JSON.stringify(comic.tags)
    : (typeof comic.tags === 'object' && comic.tags !== null
      ? JSON.stringify(Object.entries(comic.tags).flatMap(([ns, vals]) =>
          Array.isArray(vals) ? vals.map(v => `${ns}:${v}`) : [`${ns}:${vals}`]))
      : (comic.tags ?? null));
  const now = Date.now();
  db.prepare(`
    insert into comic_basic_info
      (comic_id, title, subtitle, description, author, status, update_time, language, cover_uri, tags_json, page_count, base_info_updated_at)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(comic_id) do update set
      title = excluded.title,
      subtitle = coalesce(excluded.subtitle, comic_basic_info.subtitle),
      description = coalesce(excluded.description, comic_basic_info.description),
      author = coalesce(excluded.author, comic_basic_info.author),
      status = coalesce(excluded.status, comic_basic_info.status),
      update_time = coalesce(excluded.update_time, comic_basic_info.update_time),
      language = coalesce(excluded.language, comic_basic_info.language),
      cover_uri = coalesce(excluded.cover_uri, comic_basic_info.cover_uri),
      tags_json = coalesce(excluded.tags_json, comic_basic_info.tags_json),
      page_count = coalesce(excluded.page_count, comic_basic_info.page_count),
      base_info_updated_at = excluded.base_info_updated_at
  `).run(
    comicId,
    comic.title ?? '',
    comic.subtitle ?? comic.subTitle ?? null,
    comic.description ?? null,
    comic.author ?? null,
    comic.status ?? null,
    comic.updateTime ?? comic.update ?? comic.lastUpdateTime ?? null,
    comic.language ?? null,
    comic.cover ?? comic.coverPath ?? null,
    tags,
    comic.maxPage ?? comic.pageCount ?? null,
    now,
  );
}

function markServerDbDirty(profileRoot, reason) {
  const metadata = readServerDbMetadata(profileRoot);
  writeServerDbMetadata(profileRoot, {
    ...metadata,
    dirty: true,
    dirtyReason: reason,
    dirtyAt: new Date().toISOString(),
  });
}

function listServerDbProfiles(serverDataRoot) {
  const profilesRoot = join(resolve(serverDataRoot), "profiles");
  if (!existsSync(profilesRoot)) return [];
  return readdirSync(profilesRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => /^[0-9A-Za-z_.-]{1,80}$/.test(name))
    .sort();
}

async function downloadLatestWebDavBackup({
  config,
  payload,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  const remoteFileName = normalizeWebDavBackupName(payload.remoteFileName);
  let selectedFile = remoteFileName;
  let remoteTimestamp = null;
  let buffer = null;
  let availableFiles = await listWebDavBackupFiles({
    config,
    cookieJar,
    persistCookieJar,
    recordProxyRequest,
  });
  availableFiles = availableFiles.filter((name) => name !== "latest.venera");

  if (selectedFile) {
    const result = await webDavRequest({
      config,
      path: selectedFile,
      method: "GET",
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    buffer = result.body;
    remoteTimestamp = backupTimestamp(selectedFile) || null;
  } else if (availableFiles.length > 0) {
    selectedFile = sortBackupFiles(availableFiles, true)[0];
    const result = await webDavRequest({
      config,
      path: selectedFile,
      method: "GET",
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    buffer = result.body;
    remoteTimestamp = backupTimestamp(selectedFile) || null;
  } else {
    const result = await webDavRequest({
      config,
      path: "latest.venera",
      method: "GET",
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    buffer = result.body;
    selectedFile = "latest.venera";
    remoteTimestamp = Date.now();
  }

  assertLooksLikeVeneraBackup(buffer, selectedFile || "downloaded backup");
  return {
    buffer,
    remoteFileName: selectedFile,
    remoteTimestamp,
    availableFiles: sortBackupFiles(availableFiles, true),
    size: buffer.length,
    sha256: backupSha256(buffer),
  };
}

// --- Comic Source Runtime ---

function validateComicSourceKey(sourceKey) {
  const key = String(sourceKey || "").trim();
  if (!key || key.includes("/") || key.includes("\\") || key.includes("..")) {
    throw createHttpError(400, "Invalid comic source key");
  }
  return key;
}

function canonicalComicSourceKey(sourceKey) {
  return String(sourceKey || "")
    .trim()
    .replace(/\.js$/i, "")
    .replace(/\s*\(\d+\)$/u, "");
}

function firstRegexGroup(text, patterns) {
  for (const pattern of patterns) {
    const match = String(text || "").match(pattern);
    if (match?.[1]) return match[1].trim();
  }
  return "";
}

function extractComicSourceMetadata(sourceCode, fallbackKey) {
  const text = String(sourceCode || "");
  const key =
    firstRegexGroup(text, [
      /\bthis\.key\s*=\s*["'`]([^"'`]+)["'`]/u,
      /\bkey\s*=\s*["'`]([^"'`]+)["'`]/u,
      /\bkey\s*:\s*["'`]([^"'`]+)["'`]/u,
      /\bget\s+key\s*\(\)\s*\{\s*return\s*["'`]([^"'`]+)["'`]/u,
    ]) || fallbackKey;
  const name =
    firstRegexGroup(text, [
      /\bthis\.name\s*=\s*["'`]([^"'`]+)["'`]/u,
      /\bname\s*=\s*["'`]([^"'`]+)["'`]/u,
      /\bname\s*:\s*["'`]([^"'`]+)["'`]/u,
      /\bget\s+name\s*\(\)\s*\{\s*return\s*["'`]([^"'`]+)["'`]/u,
      /\bdisplayName\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
      /\btitle\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
    ]) || fallbackKey;
  const version = firstRegexGroup(text, [
    /\bthis\.version\s*=\s*["'`]([^"'`]+)["'`]/u,
    /\bversion\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
    /\bget\s+version\s*\(\)\s*\{\s*return\s*["'`]([^"'`]+)["'`]/u,
  ]);
  const url = firstRegexGroup(text, [
    /\bthis\.url\s*=\s*["'`]([^"'`]+)["'`]/u,
    /\burl\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
    /\bwebsite\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
    /\bbaseUrl\s*[:=]\s*["'`]([^"'`]+)["'`]/u,
  ]);
  return {
    key,
    canonicalKey: canonicalComicSourceKey(key),
    displayName: name,
    sourceName: name,
    version,
    url,
  };
}

function comicSourceMetadataForKey(profileRoot, sourceKey) {
  try {
    const sourceDir = join(profileRoot, "comic_source");
    const sourceInfo = resolveComicSourceFiles(sourceDir, sourceKey);
    const sourceCode = readFileSync(sourceInfo.sourceFile, "utf8");
    return extractComicSourceMetadata(sourceCode, sourceInfo.selectedKey);
  } catch {
    return {
      key: canonicalComicSourceKey(sourceKey),
      canonicalKey: canonicalComicSourceKey(sourceKey),
      displayName: String(sourceKey || ""),
      sourceName: String(sourceKey || ""),
      version: "",
      url: "",
    };
  }
}

function resolveComicSourceFiles(sourceDir, sourceKey) {
  const key = validateComicSourceKey(sourceKey).replace(/\.js$/i, "");
  const candidates = [];
  const addCandidate = (value) => {
    const candidate = validateComicSourceKey(value).replace(/\.js$/i, "");
    if (candidate && !candidates.includes(candidate)) candidates.push(candidate);
  };
  addCandidate(key);
  const canonicalKey = canonicalComicSourceKey(key);
  if (canonicalKey && canonicalKey !== key) addCandidate(canonicalKey);
  try {
    const duplicateCandidates = readdirSync(sourceDir)
      .filter((name) => {
        const candidate = String(name || "");
        if (!candidate.toLowerCase().endsWith(".js")) return false;
        const candidateKey = candidate.replace(/\.js$/i, "");
        return canonicalComicSourceKey(candidateKey) === canonicalKey;
      })
      .map((name) => String(name).replace(/\.js$/i, ""))
      .sort((a, b) => {
        const rank = (value) => {
          const match = String(value).match(/\((\d+)\)$/u);
          return match ? Number(match[1]) + 1 : 0;
        };
        return rank(a) - rank(b) || a.localeCompare(b);
      });
    for (const candidate of duplicateCandidates) addCandidate(candidate);
  } catch { /* source directory may not exist */ }

  let selectedKey = "";
  let sourceFile = "";
  for (const candidate of candidates) {
    const filePath = join(sourceDir, `${candidate}.js`);
    let isUsableSourceFile = false;
    try {
      const stat = statSync(filePath);
      isUsableSourceFile = stat.isFile() && stat.size > 0;
    } catch { /* ignore invalid candidate */ }
    if (isUsableSourceFile) {
      selectedKey = candidate;
      sourceFile = filePath;
      break;
    }
  }
  if (!sourceFile) {
    throw createHttpError(404, `Comic source "${key}" not found`);
  }

  let dataFile = join(sourceDir, `${selectedKey}.data`);
  if (!existsSync(dataFile)) {
    const canonicalDataFile = join(sourceDir, `${canonicalKey || selectedKey}.data`);
    if (canonicalDataFile !== dataFile && existsSync(canonicalDataFile)) {
      dataFile = canonicalDataFile;
    }
  }
  return { requestedKey: key, selectedKey, sourceFile, dataFile };
}

function comicSourceClassNames(sourceCode) {
  return Array.from(
    String(sourceCode || "").matchAll(
      /\bclass\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource\b/g,
    ),
    (match) => match[1],
  );
}

function normalizeComicChapters(chapters) {
  if (!chapters) return [];
  if (Array.isArray(chapters)) {
    return chapters
      .map((item, index) => {
        if (typeof item === "string") {
          return { id: String(index), title: item };
        }
        if (!item || typeof item !== "object") return null;
        if (item.chapters != null) {
          return { ...item, chapters: normalizeComicChapters(item.chapters) };
        }
        return item;
      })
      .filter(Boolean);
  }
  if (typeof chapters !== "object") return [];

  const entries =
    chapters instanceof Map || chapters.constructor?.name === "Map"
      ? Array.from(chapters.entries())
      : Object.entries(chapters);

  const result = entries.map(([key, value]) => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const hasChapterShape = "id" in value || "title" in value;
      if (hasChapterShape) return { id: String(key), ...value };
      return { title: String(key), chapters: normalizeComicChapters(value) };
    }
    return { id: String(key), title: String(value ?? key) };
  });

  // When mixed flat & grouped entries exist, wrap flat entries in a default
  // group so tabs (番外, Online版, etc.) are preserved consistently.
  const hasGroup = result.some((item) => item.chapters);
  if (hasGroup) {
    const flatEntries = result.filter((item) => !item.chapters);
    const groupEntries = result.filter((item) => item.chapters);
    if (flatEntries.length) {
      const existingDefault = groupEntries.find((g) => g.title === "默认");
      if (existingDefault) {
        existingDefault.chapters = [...flatEntries, ...existingDefault.chapters];
      } else {
        groupEntries.unshift({ title: "默认", chapters: flatEntries });
      }
    }
    return groupEntries;
  }
  return result;
}

function normalizeComicPages(result) {
  if (Array.isArray(result)) return result;
  if (!result || typeof result !== "object") return [];
  if (Array.isArray(result.images)) return result.images;
  if (Array.isArray(result.pages)) return result.pages;
  if (Array.isArray(result.data)) return result.data;
  return [];
}

const legacySourceTypesByKey = new Map([
  ["local", 0],
  ["ehentai", 1],
  ["jm", 769844263],
  ["hitomi", 258019538],
  ["wnacg", 823512256],
  ["nhentai", 264196719],
  ["hot_manga", 29663848],
  ["manwaba", 42816288],
  ["zaimanhua", 150465061],
  ["baozi", 233488852],
  ["hcomic", 236897507],
  ["shonen_jump_plus", 331263271],
  ["goda", 550146035],
  ["picacg", 553570794],
  ["copy_manga", 557997769],
  ["mh1234", 577341847],
  ["manga_dex", 577718694],
  ["manhuaren", 631413104],
  ["Komiic", 637999886],
  ["ikmmh", 716010982],
  ["jcomic", 740690276],
  ["mxs", 771282371],
  ["mh18", 778108598],
  ["ykmh", 798816513],
  ["ccc", 807338462],
  ["comick", 964788560],
  ["happy", 977805693],
  ["ManHuaGui", 981441865],
]);

function sourceTypeCandidates(sourceKey) {
  const candidates = new Set();
  const raw = String(sourceKey || "").trim();
  const canonical = canonicalComicSourceKey(raw);
  for (const key of [raw, canonical]) {
    if (!key) continue;
    const numeric = Number(key);
    if (Number.isInteger(numeric)) candidates.add(numeric);
    const legacy = legacySourceTypesByKey.get(key);
    if (Number.isInteger(legacy)) candidates.add(legacy);
  }
  return [...candidates];
}

async function findFavoriteId(profileRoot, comicId, sourceKey) {
  const favDbPath = serverDbEntryPath(profileRoot, "local_favorite.db");
  if (!existsSync(favDbPath)) return null;
  const typeCandidates = sourceTypeCandidates(sourceKey);
  if (typeCandidates.length === 0) return null;
  try {
    const sqlite = await import("node:sqlite");
    const db = new sqlite.DatabaseSync(favDbPath);
    try {
      const tables = db
        .prepare("SELECT name FROM sqlite_master WHERE type='table';")
        .all()
        .map((r) => r.name)
        .filter((n) => !nonFavoriteTableNames.has(n) && !String(n || "").startsWith("sqlite_"));
      for (const table of tables) {
        try {
          const columns = favoriteColumnNames(db, table);
          if (!columns.has("id") || !columns.has("type")) continue;
          const row = db
            .prepare(`SELECT id FROM ${sqliteIdentifier(table)} WHERE id = ? AND type IN (${typeCandidates.map(() => "?").join(",")}) LIMIT 1;`)
            .get(comicId, ...typeCandidates);
          if (row) return `${table}:${comicId}`;
        } catch { /* table may not have expected columns */ }
      }
    } finally {
      db.close();
    }
  } catch { /* sqlite not available or db error */ }
  return null;
}

async function executeSourceMethod({
  profileRoot,
  sourceKey,
  method,
  args = [],
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  const sourceDir = join(profileRoot, "comic_source");
  const sourceInfo = resolveComicSourceFiles(sourceDir, sourceKey);
  sourceKey = sourceInfo.requestedKey;
  const sourceCode = readFileSync(sourceInfo.sourceFile, "utf-8");
  const sourceClassNames = comicSourceClassNames(sourceCode);

  // Build a sandboxed Network object that uses proxyFetch
  function normalizeNetworkArgs(secondArg = {}, thirdArg = undefined) {
    if (thirdArg !== undefined) {
      return { headers: secondArg || {}, body: thirdArg, options: {} };
    }
    if (
      secondArg &&
      typeof secondArg === "object" &&
      !Buffer.isBuffer(secondArg) &&
      ("headers" in secondArg || "body" in secondArg || "method" in secondArg)
    ) {
      return {
        headers: secondArg.headers || {},
        body: secondArg.body,
        options: secondArg,
      };
    }
    return { headers: secondArg || {}, body: undefined, options: {} };
  }

  function normalizeNetworkGetHeaders(options = {}) {
    return normalizeNetworkArgs(options).headers || {};
  }

  function normalizeNetworkPost(firstArg, secondArg = undefined) {
    if (secondArg !== undefined) {
      return normalizeNetworkArgs(firstArg, secondArg);
    }
    if (
      firstArg &&
      typeof firstArg === "object" &&
      !Buffer.isBuffer(firstArg) &&
      ("headers" in firstArg || "body" in firstArg || "method" in firstArg)
    ) {
      return normalizeNetworkArgs(firstArg);
    }
    return { headers: {}, body: firstArg, options: {} };
  }

  function normalizeNetworkBody(body, headers = {}) {
    if (body == null) return undefined;
    if (Buffer.isBuffer(body)) return body;
    if (body instanceof ArrayBuffer) return Buffer.from(body);
    if (ArrayBuffer.isView(body)) {
      return Buffer.from(body.buffer, body.byteOffset, body.byteLength);
    }
    if (typeof body === "object") {
      if (!headers["Content-Type"] && !headers["content-type"]) {
        headers["Content-Type"] = "application/json";
      }
      return JSON.stringify(body);
    }
    return body;
  }

  async function sendNetworkRequest(method, url, headers = {}, body = undefined, bytes = false) {
    const requestHeaders = headers || {};
    const response = await proxyFetch({
      url,
      method,
      headers: requestHeaders,
      body: normalizeNetworkBody(body, requestHeaders),
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const responseBody = Buffer.from(await response.arrayBuffer());
    return {
      status: response.status,
      headers: Object.fromEntries(response.headers.entries()),
      body: bytes ? responseBody.buffer.slice(
        responseBody.byteOffset,
        responseBody.byteOffset + responseBody.byteLength,
      ) : responseBody.toString(),
    };
  }

  function Cookie({ name, value, domain, path, expires, maxAge, secure, httpOnly } = {}) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
    this.expires = expires;
    this.maxAge = maxAge;
    this.secure = secure;
    this.httpOnly = httpOnly;
  }

  function createNetworkObj() {
    return {
      async fetchBytes(method, url, headers = {}, data = undefined, extra = undefined) {
        return sendNetworkRequest(method, url, headers, data, true, extra);
      },
      async sendRequest(method, url, headers = {}, data = undefined, extra = undefined) {
        return sendNetworkRequest(method, url, headers, data, false, extra);
      },
      async get(url, options = {}) {
        return this.sendRequest("GET", url, normalizeNetworkGetHeaders(options));
      },
      async post(url, firstArg, secondArg = undefined) {
        const { headers, body } = normalizeNetworkPost(firstArg, secondArg);
        return this.sendRequest("POST", url, headers, body);
      },
      async put(url, headers = {}, data = undefined, extra = undefined) {
        return this.sendRequest("PUT", url, headers, data, extra);
      },
      async patch(url, headers = {}, data = undefined, extra = undefined) {
        return this.sendRequest("PATCH", url, headers, data, extra);
      },
      async delete(url, headers = {}, extra = undefined) {
        return this.sendRequest("DELETE", url, headers, undefined, extra);
      },
      async request(url, options = {}) {
        return this.sendRequest(
          options.method || "GET",
          url,
          normalizeNetworkGetHeaders(options),
          options.body,
        );
      },
      setCookies(url, cookies) {
        return importCookies(cookieJar, url, cookies || [], persistCookieJar);
      },
      getCookies(url) {
        return exportCookies(cookieJar, url);
      },
      deleteCookies(url) {
        deleteCookiesForUrl(cookieJar, url, persistCookieJar);
        return true;
      },
    };
  }

  // HTML DOM implementation using node-html-parser
  function createHtmlDom(html) {
    const root = parseHtml(String(html || ""), { lowerCaseTagName: true });
    return wrapNode(root);
  }

  function wrapNode(node) {
    if (!node) return null;
    return {
      querySelector(sel) { const el = node.querySelector(sel); return el ? wrapNode(el) : null; },
      querySelectorAll(sel) { return (node.querySelectorAll(sel) || []).map(wrapNode); },
      getElementById(id) { const el = node.getElementById(id); return el ? wrapNode(el) : null; },
      get text() { return node.text || node.textContent || ""; },
      get innerHTML() { return node.innerHTML || ""; },
      get outerHTML() { return node.outerHTML || node.toString() || ""; },
      get body() { return wrapNode(node); },
      getAttribute(name) { return node.getAttribute ? node.getAttribute(name) : null; },
      get attributes() {
        const attrs = {};
        if (node.attributes) { for (const [k, v] of Object.entries(node.attributes)) attrs[k] = v; }
        return attrs;
      },
      get children() { return (node.childNodes || []).filter(n => n.nodeType === 1).map(wrapNode); },
      get nodes() { return (node.childNodes || []).map(wrapNode); },
      get previousElementSibling() { const el = node.previousElementSibling; return el ? wrapNode(el) : null; },
      get nextElementSibling() { const el = node.nextElementSibling; return el ? wrapNode(el) : null; },
      get src() { return node.getAttribute ? node.getAttribute("src") : null; },
      get href() { return node.getAttribute ? node.getAttribute("href") : null; },
      get className() { return node.getAttribute ? (node.getAttribute("class") || "") : ""; },
      get id() { return node.getAttribute ? (node.getAttribute("id") || "") : ""; },
      dispose() {},
    };
  }

  function createDomElement(html, selector) {
    // Very basic selector support for common patterns
    const el = findElement(html, selector);
    if (!el) return null;
    return makeDomNode(el);
  }

  function makeDomNode(html) {
    if (!html) return null;
    return {
      querySelector(sel) { return createDomElement(html, sel); },
      querySelectorAll(sel) { return findAllElements(html, sel); },
      getElementById(id) { return createDomElement(html, `#${id}`); },
      get text() { return html.replace(/<[^>]*>/g, "").trim(); },
      get innerHTML() {
        const m = html.match(/^<[^>]*>([\s\S]*)<\/[^>]*>$/);
        return m ? m[1] : html;
      },
      get outerHTML() { return html; },
      getAttribute(name) {
        const re = new RegExp(`${name}\\s*=\\s*["']([^"']*)["']`);
        const m = html.match(re);
        return m ? m[1] : null;
      },
      get attributes() {
        const attrs = {};
        const re = /(\w[\w-]*)=["']([^"']*?)["']/g;
        let m;
        while ((m = re.exec(html)) !== null) {
          attrs[m[1]] = m[2];
        }
        return attrs;
      },
      get children() {
        const inner = this.innerHTML;
        return findAllElements(inner, "*");
      },
      get nodes() { return this.children; },
      get previousElementSibling() { return null; },
      get nextElementSibling() { return null; },
      get src() { return this.getAttribute("src"); },
      get href() { return this.getAttribute("href"); },
      get className() { return this.getAttribute("class") || ""; },
      get id() { return this.getAttribute("id") || ""; },
      dispose() {},
    };
  }

  function findElement(html, selector) {
    const elements = findAllElements(html, selector);
    return elements.length > 0 ? elements[0] : null;
  }

  function findAllElements(html, selector) {
    if (!html || !selector) return [];
    const results = [];
    // Support tag, .class, #id, tag.class, tag[attr]
    let tagName = "";
    let className = "";
    let idName = "";
    let attrName = "";
    let attrVal = "";

    const classMatch = selector.match(/\.([a-zA-Z0-9_-]+)/);
    const idMatch = selector.match(/#([a-zA-Z0-9_-]+)/);
    const attrMatch = selector.match(/\[([a-zA-Z0-9_-]+)(?:="([^"]*)")?\]/);
    const tagMatch = selector.match(/^([a-zA-Z0-9]+)/);

    if (tagMatch) tagName = tagMatch[1];
    if (classMatch) className = classMatch[1];
    if (idMatch) idName = idMatch[1];
    if (attrMatch) { attrName = attrMatch[1]; attrVal = attrMatch[2] || ""; }

    const tagPattern = tagName || "[a-zA-Z][a-zA-Z0-9]*";
    const re = new RegExp(
      `<(${tagPattern})(\\s[^>]*)?>([\\s\\S]*?)<\\/\\1>|<(${tagPattern})(\\s[^>]*)?\\s*\\/?>`,
      "gi",
    );
    let match;
    while ((match = re.exec(html)) !== null) {
      const fullMatch = match[0];
      const attrs = match[2] || match[5] || "";
      let passes = true;
      if (className && !new RegExp(`class\\s*=\\s*["'][^"']*\\b${className}\\b`).test(attrs)) {
        passes = false;
      }
      if (idName && !new RegExp(`id\\s*=\\s*["']${idName}["']`).test(attrs)) {
        passes = false;
      }
      if (attrName) {
        if (attrVal) {
          if (!new RegExp(`${attrName}\\s*=\\s*["']${attrVal}["']`).test(attrs)) passes = false;
        } else {
          if (!new RegExp(`${attrName}\\s*=`).test(attrs)) passes = false;
        }
      }
      if (passes) results.push(fullMatch);
    }
    return results.map(makeDomNode);
  }

  // Data file support (source .data files)
  let sourceData = {};
  const dataFile = sourceInfo.dataFile;
  if (existsSync(dataFile)) {
    try {
      sourceData = JSON.parse(readFileSync(dataFile, "utf-8"));
    } catch { sourceData = {}; }
  }

  // Inject source token as cookie (replicates APP's CookieManagerSql behavior)
  if (cookieJar && sourceData.token && sourceData.settings?.base_url) {
    const apiUrl = `https://${sourceData.settings.base_url}`;
    importCookies(cookieJar, apiUrl, [
      { name: "token", value: sourceData.token, path: "/" },
    ], persistCookieJar);
  }

  const sourceDataShouldPersist = () =>
    sourceData && typeof sourceData === "object" && Object.keys(sourceData).length > 0;

  const convertObj = {
    encodeUtf8(value) {
      return Buffer.from(String(value ?? ""), "utf8");
    },
    decodeUtf8(value) {
      return Buffer.from(value || []).toString("utf8");
    },
    encodeBase64(value) {
      return Buffer.from(value || []).toString("base64");
    },
    decodeBase64(value) {
      return Buffer.from(String(value || ""), "base64");
    },
    hexEncode(value) {
      return Buffer.from(value || []).toString("hex");
    },
    md5(value) {
      return createHash("md5").update(Buffer.from(value || [])).digest("hex");
    },
    sha256(value) {
      return createHash("sha256").update(Buffer.from(value || [])).digest("hex");
    },
    hmacString(key, data, algorithm = "sha256") {
      return createHmac(String(algorithm || "sha256"), Buffer.from(key || []))
        .update(Buffer.from(data || []))
        .digest("hex");
    },
    decryptAesEcb(data, key) {
      try {
        const decipher = createDecipheriv("aes-128-ecb", Buffer.from(key || []), null);
        decipher.setAutoPadding(true);
        return Buffer.concat([decipher.update(Buffer.from(data || [])), decipher.final()]);
      } catch { return Buffer.alloc(0); }
    },
    decryptAesCbc(data, key, iv) {
      try {
        const keyBuf = Buffer.from(key || []);
        const ivBuf = Buffer.from(iv || []);
        let dataBuf;
        if (data instanceof ArrayBuffer) {
          dataBuf = Buffer.from(new Uint8Array(data));
        } else if (data && data.buffer instanceof ArrayBuffer) {
          dataBuf = Buffer.from(data);
        } else if (data && typeof data.byteLength === 'number') {
          dataBuf = Buffer.from(new Uint8Array(data));
        } else {
          dataBuf = Buffer.from(data || []);
        }
        const algo = keyBuf.length <= 16 ? "aes-128-cbc" : keyBuf.length <= 24 ? "aes-192-cbc" : "aes-256-cbc";
        const decipher = createDecipheriv(algo, keyBuf, ivBuf);
        decipher.setAutoPadding(false);
        return Buffer.concat([decipher.update(dataBuf), decipher.final()]);
      } catch { return Buffer.alloc(0); }
    },
  };

  // Build the sandbox context
  const networkObj = createNetworkObj();
  const sandbox = {
    console: {
      log: (...args) => {},
      warn: (...args) => {},
      error: (...args) => {},
      info: (...args) => {},
      debug: (...args) => {},
    },
    log: (...args) => {},
    setTimeout: (fn, ms) => setTimeout(fn, Math.min(ms || 0, 30000)),
    clearTimeout,
    JSON,
    parseInt,
    parseFloat,
    isNaN,
    isFinite,
    encodeURIComponent,
    decodeURIComponent,
    encodeURI,
    decodeURI,
    atob: (s) => Buffer.from(s, "base64").toString("binary"),
    btoa: (s) => Buffer.from(s, "binary").toString("base64"),
    Array,
    Object,
    String,
    Number,
    Boolean,
    RegExp,
    Date,
    Map,
    Set,
    Promise,
    Error,
    Math,
    Symbol,
    Uint8Array,
    Buffer,
    randomInt(min, max) {
      const low = Math.ceil(Number(min));
      const high = Math.floor(Number(max));
      if (!Number.isFinite(low) || !Number.isFinite(high) || high < low) {
        return 0;
      }
      return Math.floor(Math.random() * (high - low + 1)) + low;
    },
    randomDouble(min, max) {
      const low = Number(min);
      const high = Number(max);
      if (!Number.isFinite(low) || !Number.isFinite(high) || high < low) {
        return 0;
      }
      return Math.random() * (high - low) + low;
    },
    createUuid() {
      return randomUUID();
    },
    fetch(url, options = {}) {
      return proxyFetch({
        url: String(url),
        method: options.method || "GET",
        headers: options.headers || {},
        body: options.body,
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
    },
    URL,
    URLSearchParams: globalThis.URLSearchParams,
    Network: networkObj,
    Convert: convertObj,
    Cookie,
    HtmlDom: createHtmlDom,
    HtmlDocument: createHtmlDom,
    Comic: function(fields = {}) { Object.assign(this, fields); },
    ComicDetails: function(fields = {}) { Object.assign(this, fields); },
    Comment: function(fields = {}) { Object.assign(this, fields); },
    Image: { empty: () => ({ fillImageRangeAt: () => {} }) },
    UI: { showDialog: async () => null, showMessage: () => {} },
    APP: { locale: "zh_CN", version: "web" },
    sendMessage(payload = {}) {
      const methodName = payload?.method;
      if (methodName === "log") return undefined;
      if (methodName === "uuid") return randomUUID();
      if (methodName === "delay") {
        const ms = Math.min(Number(payload?.time || 0), 5000);
        return new Promise(resolve => setTimeout(resolve, ms));
      }
      if (methodName === "getLocale") return "zh_CN";
      if (methodName === "getPlatform") return "web";
      if (methodName === "random") {
        return payload?.type === "double"
          ? this.randomDouble(payload.min, payload.max)
          : this.randomInt(payload.min, payload.max);
      }
      if (methodName === "http") {
        return payload?.bytes
          ? networkObj.fetchBytes(
              payload.http_method || "GET",
              payload.url,
              payload.headers || {},
              payload.data,
              payload.extra,
            )
          : networkObj.sendRequest(
              payload.http_method || "GET",
              payload.url,
              payload.headers || {},
              payload.data,
              payload.extra,
            );
      }
      if (methodName === "cookie") {
        if (payload.function === "set") {
          return networkObj.setCookies(payload.url, payload.cookies || []);
        }
        if (payload.function === "get") return networkObj.getCookies(payload.url);
        if (payload.function === "delete") return networkObj.deleteCookies(payload.url);
      }
      if (methodName === "load_data") {
        const val = sourceData?.[payload.data_key] ?? null;
        if (payload.data_key === "token" || payload.data_key === "account") {
          console.log(`[DATA] load_data("${payload.data_key}") => ${JSON.stringify(val)?.slice(0,40)}`);
        }
        return val;
      }
      if (methodName === "load_setting") {
        return sourceData?.settings?.[payload.setting_key] ?? null;
      }
      if (methodName === "save_data") {
        if (sourceData && payload?.data_key) sourceData[payload.data_key] = payload.data;
        return true;
      }
      if (methodName === "delete_data") {
        if (sourceData && payload?.data_key) delete sourceData[payload.data_key];
        return true;
      }
      if (methodName === "isLogged") return sourceData?.isLogged ?? true;
      return null;
    },
    __sourceData: sourceData,
    __sourceKey: sourceKey,
    __selectedSourceKey: sourceInfo.selectedKey,
    __result: null,
    __error: null,
  };

  const context = vm.createContext(sandbox);

  // Wrapper script that defines ComicSource base class and runs the source
  const wrapperScript = `
(async () => {
  class ComicSource {
    constructor() {
      this.data = __sourceData || {};
    }
    loadData(dataKey) { return dataKey ? (this.data?.[dataKey] ?? null) : this.data; }
    loadSetting(key) {
      const saved = this.data?.settings?.[key];
      if (saved !== undefined && saved !== null) return saved;
      // Fallback to source-defined default (matches Flutter app behavior)
      const def = this.settings?.[key];
      if (def && typeof def === 'object' && 'default' in def) return def.default;
      return def ?? null;
    }
    saveData(dataKey, data) { if (dataKey) this.data[dataKey] = data; return true; }
    deleteData(dataKey) { if (dataKey) delete this.data[dataKey]; return true; }
    get isLogged() { return this.data?.isLogged ?? true; }
    translate(key) { return this.translation?.[APP.locale]?.[key] ?? key; }
    // Methods to be overridden by source scripts
    async search(keyword, page, options) { return { comics: [], hasMore: false }; }
    async explore(page) { return []; }
    async getCategories() { return []; }
    async getCategoryComics(categoryId, page) { return { comics: [], hasMore: false }; }
    async getComicInfo(id) { return {}; }
    async getPages(comicId, chapterId) { return []; }
    async getComments(comicId, page) { return []; }
    async getRelated(comicId) { return []; }
    async getThumbnails(comicId) { return []; }
    init() {}
    static sources = {};
  }

  // Provide global references
  globalThis.ComicSource = ComicSource;
  globalThis.Network = Network;
  globalThis.HtmlDom = HtmlDom;
  globalThis.HtmlDocument = HtmlDom;
  ${sourceCode}

  // Find or create the ComicSource subclass instance used by native sources.
  const candidates = [];
  const addCandidate = (val) => {
    if (val && val instanceof ComicSource && val.constructor !== ComicSource) {
      candidates.push(val);
    }
  };
  for (const key of Object.keys(globalThis)) {
    addCandidate(globalThis[key]);
  }
  const sourceVarNames = ['source', 'comicSource', 'src'];
  for (const name of sourceVarNames) {
    try {
      addCandidate(eval(name));
    } catch {}
  }
  for (const val of Object.values(ComicSource.sources || {})) {
    addCandidate(val);
  }
  const sourceClassNames = ${JSON.stringify(sourceClassNames)};
  for (const name of sourceClassNames) {
    try {
      const Constructor = eval(name);
      if (typeof Constructor === 'function') addCandidate(new Constructor());
    } catch {}
  }
  let sourceInstance = candidates.find((item) => {
    const key = String(item.key || '');
    return key === __sourceKey || key === __selectedSourceKey;
  }) || candidates[0] || null;
  if (sourceInstance && typeof sourceInstance.init === 'function') {
    await sourceInstance.init();
  }
  if (sourceInstance) {
    ComicSource.sources[sourceInstance.key || __sourceKey] = sourceInstance;
  }
  async function callSourceMethod(methodName, methodArgs) {
    const direct = sourceInstance?.[methodName];
    if (
      typeof direct === 'function' &&
      direct !== ComicSource.prototype[methodName]
    ) {
      return direct.apply(sourceInstance, methodArgs);
    }
    if (methodName === 'getComicInfo') {
      if (typeof sourceInstance?.comic?.loadInfo === 'function') {
        return sourceInstance.comic.loadInfo.call(sourceInstance.comic, methodArgs[0]);
      }
      if (typeof sourceInstance?.comic?.load === 'function') {
        return sourceInstance.comic.load.call(sourceInstance.comic, methodArgs[0]);
      }
    }
    if (methodName === 'getPages') {
      if (typeof sourceInstance?.comic?.loadEp === 'function') {
        return sourceInstance.comic.loadEp.call(sourceInstance.comic, methodArgs[0], methodArgs[1]);
      }
      if (typeof sourceInstance?.comic?.loadImages === 'function') {
        return sourceInstance.comic.loadImages.call(sourceInstance.comic, methodArgs[0], methodArgs[1]);
      }
    }
    if (methodName === 'search') {
      const keyword = methodArgs[0];
      const page = methodArgs[1];
      const options = methodArgs[2];
      if (typeof sourceInstance?.search?.load === 'function') {
        return sourceInstance.search.load.call(sourceInstance.search, keyword, options, page);
      }
      if (typeof sourceInstance?.search?.loadPage === 'function') {
        return sourceInstance.search.loadPage.call(sourceInstance.search, keyword, page, options);
      }
      if (typeof sourceInstance?.search?.loadNext === 'function') {
        return sourceInstance.search.loadNext.call(sourceInstance.search, keyword, options, page);
      }
    }
    if (methodName === 'getCategories') {
      if (sourceInstance?.category) return sourceInstance.category;
      if (typeof sourceInstance?.getCategories === 'function' && sourceInstance.getCategories !== ComicSource.prototype.getCategories) {
        return sourceInstance.getCategories();
      }
      return null;
    }
    if (methodName === 'getCategoryComics') {
      const category = methodArgs[0];
      const page = methodArgs[1];
      const param = methodArgs[2] ?? null;
      const options = methodArgs[3] ?? [];
      if (typeof sourceInstance?.categoryComics?.load === 'function') {
        return sourceInstance.categoryComics.load.call(sourceInstance.categoryComics, category, param, options, page);
      }
    }
    if (methodName === 'explore') {
      const page = methodArgs[0] ?? 1;
      const exploreIndex = methodArgs[1] ?? 0;
      const explorePages = sourceInstance?.explore;
      if (Array.isArray(explorePages) && explorePages[exploreIndex]) {
        const explorePage = explorePages[exploreIndex];
        if (typeof explorePage.load === 'function') {
          return explorePage.load.call(explorePage, page);
        }
        if (typeof explorePage.loadNext === 'function') {
          return explorePage.loadNext.call(explorePage, page === 1 ? null : String(page));
        }
      }
    }
    if (methodName === 'getComments') {
      if (typeof sourceInstance?.comic?.loadComments === 'function') {
        return sourceInstance.comic.loadComments.call(sourceInstance.comic, methodArgs[0], methodArgs[1]);
      }
    }
    if (methodName === 'getThumbnails') {
      if (typeof sourceInstance?.comic?.loadThumbnails === 'function') {
        return sourceInstance.comic.loadThumbnails.call(sourceInstance.comic, methodArgs[0]);
      }
    }
    if (methodName === 'getRelated') {
      if (typeof sourceInstance?.comic?.loadRelated === 'function') {
        return sourceInstance.comic.loadRelated.call(sourceInstance.comic, methodArgs[0]);
      }
    }
    if (methodName === 'getRanking') {
      const option = methodArgs[0];
      const page = methodArgs[1];
      const ranking = sourceInstance?.categoryComics?.ranking;
      if (ranking && typeof ranking === 'object') {
        if (typeof ranking.load === 'function') {
          return ranking.load.call(ranking, option, page);
        }
        if (typeof ranking.loadWithNext === 'function') {
          return ranking.loadWithNext.call(ranking, option, page === 1 ? null : String(page));
        }
      }
      throw new Error('Ranking not available for this source');
    }
    throw new Error('Method ' + methodName + ' not found on source');
  }
  if (!sourceInstance) {
    throw new Error("No ComicSource instance found in source script");
  }

  const method = "${method}";
  const args = ${JSON.stringify(args)};
  __result = await callSourceMethod(method, args);
})().catch(e => { __error = e.message || String(e); });
`;

  const script = new vm.Script(wrapperScript, {
    filename: `${sourceKey}.js`,
    timeout: 30000,
  });

  // Run with async support - wrap in try-catch to prevent server crash
  try {
    const promise = script.runInContext(context, { timeout: 30000 });
    await promise;
  } catch (vmError) {
    sandbox.__error = sandbox.__error || vmError.message || String(vmError);
  }

  if (sandbox.__error) {
    throw createHttpError(500, `Source error: ${sandbox.__error}`);
  }
  if (sourceDataShouldPersist()) {
    mkdirSync(dirname(dataFile), { recursive: true });
    writeFileSync(dataFile, JSON.stringify(sourceData, null, 2));
  }
  return sandbox.__result;
}

function serializeOptionList(optionList) {
  if (!Array.isArray(optionList)) return [];
  return optionList.map((item) => {
    if (!item || typeof item !== "object") return null;
    const options = Array.isArray(item.options) ? item.options : [];
    return {
      label: String(item.label || ""),
      type: String(item.type || "select"),
      options,
      default: item.default ?? null,
    };
  }).filter(Boolean);
}

function serializeExplorePagesConfig(explore) {
  if (!Array.isArray(explore)) return [];
  return explore.map((page) => {
    if (!page || typeof page !== "object") return null;
    return {
      title: String(page.title || ""),
      type: String(page.type || "multiPageComicList"),
      hasLoad: typeof page.load === "function",
      hasLoadNext: typeof page.loadNext === "function",
    };
  }).filter(Boolean);
}

function serializeCategoryConfig(category) {
  if (!category || typeof category !== "object") return null;
  const parts = Array.isArray(category.parts)
    ? category.parts.map((part) => {
        if (!part || typeof part !== "object") return null;
        return {
          name: String(part.name || ""),
          type: String(part.type || "fixed"),
          categories: Array.isArray(part.categories) ? part.categories.map(String) : [],
          categoryParams: Array.isArray(part.categoryParams) ? part.categoryParams.map(String) : null,
          itemType: String(part.itemType || "category"),
        };
      }).filter(Boolean)
    : [];
  return {
    title: String(category.title || ""),
    parts,
    enableRankingPage: Boolean(category.enableRankingPage),
  };
}

function serializeCategoryComicsConfig(categoryComics) {
  if (!categoryComics || typeof categoryComics !== "object") return null;
  const ranking = categoryComics.ranking;
  const hasRanking = ranking != null && typeof ranking === "object";
  let rankingOptions = null;
  if (hasRanking && Array.isArray(ranking.options)) {
    rankingOptions = ranking.options.map(String);
  }
  return {
    hasLoad: typeof categoryComics.load === "function",
    optionList: serializeOptionList(categoryComics.optionList),
    hasRanking,
    rankingOptions,
  };
}

async function extractSourceCapabilities({ profileRoot, sourceKey }) {
  const sourceDir = join(profileRoot, "comic_source");
  const sourceInfo = resolveComicSourceFiles(sourceDir, sourceKey);
  const sourceCode = readFileSync(sourceInfo.sourceFile, "utf-8");
  const sourceClassNames = comicSourceClassNames(sourceCode);

  let sourceData = {};
  const dataFile = sourceInfo.dataFile;
  if (existsSync(dataFile)) {
    try { sourceData = JSON.parse(readFileSync(dataFile, "utf-8")); } catch { sourceData = {}; }
  }

  const sandbox = {
    console: { log: () => {}, warn: () => {}, error: () => {}, info: () => {}, debug: () => {} },
    log: () => {},
    setTimeout: (fn) => setTimeout(fn, 0),
    clearTimeout,
    JSON, parseInt, parseFloat, isNaN, isFinite,
    encodeURIComponent, decodeURIComponent, encodeURI, decodeURI,
    atob: (s) => Buffer.from(s, "base64").toString("binary"),
    btoa: (s) => Buffer.from(s, "binary").toString("base64"),
    Array, Object, String, Number, Boolean, RegExp, Date, Map, Set,
    Promise, Error, Math, Symbol, Uint8Array, Buffer, URL,
    URLSearchParams: globalThis.URLSearchParams,
    Network: { get: async () => ({ status: 0, body: "" }), post: async () => ({ status: 0, body: "" }), sendRequest: async () => ({ status: 0, body: "" }), fetchBytes: async () => ({ status: 0, body: "" }), setCookies: () => {}, getCookies: () => [], deleteCookies: () => true },
    Convert: { encodeUtf8: (v) => Buffer.from(String(v ?? ""), "utf8"), decodeUtf8: (v) => Buffer.from(v || []).toString("utf8"), encodeBase64: (v) => Buffer.from(v || []).toString("base64"), decodeBase64: (v) => Buffer.from(String(v || ""), "base64"), hmacString: () => "" },
    Cookie: function() {},
    HtmlDom: (html) => ({ querySelector: () => null, querySelectorAll: () => [], text: "", innerHTML: html }),
    APP: { locale: "zh_CN", version: "web" },
    randomInt: (min, max) => Math.floor(Math.random() * (max - min + 1)) + min,
    randomDouble: (min, max) => Math.random() * (max - min) + min,
    createUuid: () => randomUUID(),
    fetch: async () => ({ status: 0, ok: false, headers: new Map(), arrayBuffer: async () => new ArrayBuffer(0) }),
    sendMessage: (payload) => {
      const methodName = payload?.method;
      if (methodName === "load_data") return sourceData?.[payload.data_key] ?? null;
      if (methodName === "load_setting") return sourceData?.settings?.[payload.setting_key] ?? null;
      return null;
    },
    __sourceData: sourceData,
    __sourceKey: sourceKey,
    __selectedSourceKey: sourceInfo.selectedKey,
    __result: null,
    __error: null,
  };

  const context = vm.createContext(sandbox);
  const wrapperScript = `
(async () => {
  class ComicSource {
    constructor() { this.data = __sourceData || {}; }
    loadData(dataKey) { return dataKey ? (this.data?.[dataKey] ?? null) : this.data; }
    loadSetting(key) {
      const saved = this.data?.settings?.[key];
      if (saved !== undefined && saved !== null) return saved;
      const def = this.settings?.[key];
      if (def && typeof def === 'object' && 'default' in def) return def.default;
      return def ?? null;
    }
    saveData(dataKey, data) { if (dataKey) this.data[dataKey] = data; return true; }
    deleteData(dataKey) { if (dataKey) delete this.data[dataKey]; return true; }
    get isLogged() { return this.data?.isLogged ?? true; }
    translate(key) { return this.translation?.[APP.locale]?.[key] ?? key; }
    init() {}
    static sources = {};
  }
  globalThis.ComicSource = ComicSource;
  globalThis.Network = Network;
  globalThis.HtmlDom = HtmlDom;
  globalThis.HtmlDocument = HtmlDom;
  ${sourceCode}
  const candidates = [];
  const addCandidate = (val) => { if (val && val instanceof ComicSource && val.constructor !== ComicSource) candidates.push(val); };
  for (const key of Object.keys(globalThis)) addCandidate(globalThis[key]);
  for (const name of ['source', 'comicSource', 'src']) { try { addCandidate(eval(name)); } catch {} }
  for (const val of Object.values(ComicSource.sources || {})) addCandidate(val);
  const sourceClassNames = ${JSON.stringify(sourceClassNames)};
  for (const name of sourceClassNames) { try { const C = eval(name); if (typeof C === 'function') addCandidate(new C()); } catch {} }
  let sourceInstance = candidates.find((item) => {
    const key = String(item.key || '');
    return key === __sourceKey || key === __selectedSourceKey;
  }) || candidates[0] || null;
  if (!sourceInstance) throw new Error("No ComicSource instance found");
  __result = {
    key: sourceInstance.key || __sourceKey,
    name: sourceInstance.name || '',
    version: sourceInstance.version || '',
    search: sourceInstance.search || null,
    explore: sourceInstance.explore || null,
    category: sourceInstance.category || null,
    categoryComics: sourceInstance.categoryComics || null,
    comic: sourceInstance.comic ? { hasLoadInfo: typeof sourceInstance.comic.loadInfo === 'function', hasLoadEp: typeof sourceInstance.comic.loadEp === 'function', hasLoadComments: typeof sourceInstance.comic.loadComments === 'function', hasLoadThumbnails: typeof sourceInstance.comic.loadThumbnails === 'function' } : null,
    account: sourceInstance.account ? { hasLogin: typeof sourceInstance.account.login === 'function' || typeof sourceInstance.account.loginWithWebview === 'function' || typeof sourceInstance.account.loginWithCookies === 'function' } : null,
    favorites: sourceInstance.favorites ? { multiFolder: Boolean(sourceInstance.favorites.multiFolder) } : null,
    settings: sourceInstance.settings || null,
    translation: sourceInstance.translation || null,
  };
})().catch(e => { __error = e.message || String(e); });
`;

  const script = new vm.Script(wrapperScript, { filename: `${sourceKey}-caps.js`, timeout: 10000 });
  await script.runInContext(context, { timeout: 10000 });

  if (sandbox.__error) {
    throw createHttpError(500, `Source capabilities error: ${sandbox.__error}`);
  }

  const raw = sandbox.__result;
  return {
    key: String(raw.key || sourceKey),
    name: String(raw.name || ""),
    version: String(raw.version || ""),
    search: raw.search ? {
      hasLoad: typeof raw.search.load === "function",
      hasLoadNext: typeof raw.search.loadNext === "function",
      optionList: serializeOptionList(raw.search.optionList),
      enableTagsSuggestions: Boolean(raw.search.enableTagsSuggestions),
    } : null,
    explore: serializeExplorePagesConfig(raw.explore),
    category: serializeCategoryConfig(raw.category),
    categoryComics: serializeCategoryComicsConfig(raw.categoryComics),
    comic: raw.comic || null,
    account: raw.account || null,
    favorites: raw.favorites || null,
    settings: raw.settings || null,
  };
}

// Async follow-update check tasks (survive browser close)
const followUpdateTasks = new Map();
function cleanStaleTasks() {
  const cutoff = Date.now() - 3600_000;
  for (const [id, t] of followUpdateTasks) {
    if (t.endTime && t.endTime < cutoff) followUpdateTasks.delete(id);
  }
}
setInterval(cleanStaleTasks, 600_000);

async function handleServerDbRoute({
  req,
  res,
  parsedUrl,
  serverDataRoot,
  webDavConfigPath,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  if (!parsedUrl.pathname.startsWith("/api/server-db")) return false;

  if (parsedUrl.pathname === "/api/server-db/profiles") {
    if (req.method !== "GET") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    sendJson(res, 200, {
      ok: true,
      profiles: listServerDbProfiles(serverDataRoot),
    });
    return true;
  }

  let payload = {};
  if (req.method === "POST") {
    payload = parseJsonBody(await readBody(req), "Invalid server DB payload");
  } else if (req.method !== "GET") {
    sendJson(res, 405, { error: "Method not allowed" });
    return true;
  }
  const profileId = normalizeServerDbProfileId(
    payload.profile || parsedUrl.searchParams.get("profile"),
  );
  const profileRoot = serverDbProfileRoot(serverDataRoot, profileId);

  if (parsedUrl.pathname === "/api/server-db/status") {
    sendJson(res, 200, serverDbStatus(serverDataRoot, profileId));
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/dump") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const database = String(payload.database || "").trim();
    if (!database) {
      sendJson(res, 200, {
        ok: true,
        profile: profileId,
        ...readServerDbJsonDump(profileRoot),
      });
      return true;
    }
    const filePath = serverDbEntryPath(profileRoot, database);
    if (!existsSync(filePath)) {
      throw createHttpError(404, "Server DB entry not found");
    }
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      database,
      ...extractSqliteData(readFileSync(filePath)),
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/import") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const written = writeServerDbJsonDump(profileRoot, payload.data || payload);
    markServerDbDirty(profileRoot, "server-db-import");
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      written,
      status: serverDbStatus(serverDataRoot, profileId),
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/appdata") {
    const appdataPath = join(profileRoot, "appdata.json");
    let data;
    if (existsSync(appdataPath)) {
      try {
        data = JSON.parse(readFileSync(appdataPath, "utf8"));
      } catch {
        throw createHttpError(422, "Server appdata is invalid JSON");
      }
    } else {
      data = emptyServerDbAppdata();
    }
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      data,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic-sources") {
    const allItems = readServerDbComicSourcePayload(profileRoot);
    // Deduplicate: keep first source per canonical key (matches app behavior)
    const seen = new Map();
    const items = [];
    for (const item of allItems) {
      const key = (item.key || item.name || "").replace(/\.js$/i, "");
      const canonical = key.replace(/\s*\(\d+\)$/u, "");
      if (!canonical) { items.push(item); continue; }
      if (!seen.has(canonical)) {
        seen.set(canonical, true);
        items.push({ ...item, key: canonical });
      }
    }
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      items,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/source/capabilities") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceKey = String(payload.sourceKey || "").trim();
    if (!sourceKey) {
      throw createHttpError(400, "sourceKey is required");
    }
    const capabilities = await extractSourceCapabilities({ profileRoot, sourceKey });
    sendJson(res, 200, { ok: true, profile: profileId, ...capabilities });
    return true;
  }

  // ── Comic source management endpoints ──────────────────────────────────

  if (parsedUrl.pathname === "/api/server-db/sources/add") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const url = String(payload.url || "").trim();
    if (!url || (!/^https?:\/\//i.test(url))) {
      throw createHttpError(400, "A valid HTTP/HTTPS URL is required");
    }
    let sourceCode;
    try {
      const resp = await fetch(url);
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
      }
      sourceCode = await resp.text();
    } catch (err) {
      throw createHttpError(502, `Failed to fetch source: ${err.message}`);
    }
    const fallbackKey = new URL(url).pathname.split("/").pop().replace(/\.js$/i, "") || "unknown";
    const meta = extractComicSourceMetadata(sourceCode, fallbackKey);
    const key = meta.key || fallbackKey;
    const sourceDir = serverDbComicSourceDir(profileRoot);
    mkdirSync(sourceDir, { recursive: true });
    writeFileSync(join(sourceDir, `${key}.js`), sourceCode, "utf8");
    markServerDbDirty(profileRoot, "source-add");
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      key,
      name: meta.displayName || key,
      version: meta.version || null,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/sources/delete") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceKey = validateComicSourceKey(payload.sourceKey);
    const sourceDir = serverDbComicSourceDir(profileRoot);
    try {
      const resolved = resolveComicSourceFiles(sourceDir, sourceKey);
      if (resolved.sourceFile && existsSync(resolved.sourceFile)) {
        rmSync(resolved.sourceFile, { force: true });
      }
      if (resolved.dataFile && existsSync(resolved.dataFile)) {
        rmSync(resolved.dataFile, { force: true });
      }
    } catch {
      // Fallback: try direct paths if resolveComicSourceFiles fails
    }
    const directJs = join(sourceDir, `${sourceKey}.js`);
    const directData = join(sourceDir, `${sourceKey}.data`);
    if (existsSync(directJs)) rmSync(directJs, { force: true });
    if (existsSync(directData)) rmSync(directData, { force: true });
    markServerDbDirty(profileRoot, "source-delete");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/sources/update") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceKey = validateComicSourceKey(payload.sourceKey);
    const sourceDir = serverDbComicSourceDir(profileRoot);
    const resolved = resolveComicSourceFiles(sourceDir, sourceKey);
    const currentCode = readFileSync(resolved.sourceFile, "utf8");
    const currentMeta = extractComicSourceMetadata(currentCode, resolved.selectedKey);
    if (!currentMeta.url) {
      sendJson(res, 200, { ok: false, error: "Source has no update URL" });
      return true;
    }
    let newCode;
    try {
      const resp = await fetch(currentMeta.url);
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
      }
      newCode = await resp.text();
    } catch (err) {
      throw createHttpError(502, `Failed to fetch update: ${err.message}`);
    }
    writeFileSync(resolved.sourceFile, newCode, "utf8");
    const newMeta = extractComicSourceMetadata(newCode, resolved.selectedKey);
    markServerDbDirty(profileRoot, "source-update");
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      key: newMeta.key || sourceKey,
      name: newMeta.displayName || sourceKey,
      version: newMeta.version || null,
      previousVersion: currentMeta.version || null,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/sources/check-updates") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const allItems = readServerDbComicSourcePayload(profileRoot);
    const sourcesWithUrl = allItems.filter((item) => item.url);
    const fetchPromises = sourcesWithUrl.map(async (item) => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      try {
        const resp = await fetch(item.url, { signal: controller.signal });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const remoteCode = await resp.text();
        const remoteMeta = extractComicSourceMetadata(remoteCode, item.key);
        const remoteVersion = remoteMeta.version || null;
        const currentVersion = item.version || null;
        return {
          key: item.key,
          name: item.displayName || item.sourceName || item.key,
          currentVersion,
          remoteVersion,
          updateAvailable: !!(remoteVersion && currentVersion && remoteVersion !== currentVersion),
        };
      } finally {
        clearTimeout(timeout);
      }
    });
    const settled = await Promise.allSettled(fetchPromises);
    const results = settled
      .filter((r) => r.status === "fulfilled")
      .map((r) => r.value);
    sendJson(res, 200, { ok: true, profile: profileId, results });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/history/list") {
    const data = historyRowsFromServerDb(profileRoot, {
      limit: payload.limit,
      offset: payload.offset,
    });
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      ...data,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/history/upsert") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const history = normalizeHistoryPayload(payload);
    await withWritableHistoryDb(profileRoot, (db) => {
      db.prepare(`
        insert or replace into history (
          id, title, subtitle, cover, time, type, ep, page,
          readEpisode, max_page, chapter_group
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      `).run(
        history.id,
        history.title,
        history.subtitle,
        history.cover,
        history.time,
        history.type,
        history.ep,
        history.page,
        history.readEpisode,
        history.maxPage,
        history.chapterGroup,
      );
      if (history.sourceKey) {
        ensureComicBasicInfoSchema(db);
        saveComicBasicInfo(db, history.sourceKey, {
          id: history.id,
          title: history.title,
          subtitle: history.subtitle || null,
          cover: history.cover || null,
          maxPage: history.maxPage,
        });
      }
    });
    markServerDbDirty(profileRoot, "history-upsert");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/history/delete") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const id = String(payload.id || "").trim();
    const type = Number(payload.type);
    if (!id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid history delete payload");
    }
    await withWritableHistoryDb(profileRoot, (db) => {
      db.prepare("delete from history where id = ? and type = ?;").run(id, type);
    });
    markServerDbDirty(profileRoot, "history-delete");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/history/clear") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    await withWritableHistoryDb(profileRoot, (db) => {
      db.exec("delete from history;");
    });
    markServerDbDirty(profileRoot, "history-clear");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/history/clear-unfavorited") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const favoriteKeys = await favoriteHistoryKeysFromServerDb(profileRoot);
    let deleted = 0;
    await withWritableHistoryDb(profileRoot, (db) => {
      const rows = db.prepare("select id, type from history;").all();
      const statement = db.prepare(
        "delete from history where id = ? and type = ?;",
      );
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const row of rows) {
          const id = String(row.id || "").trim();
          const type = Number(row.type);
          if (!id || !Number.isInteger(type)) continue;
          if (!favoriteKeys.has(`${id}\u0000${type}`)) {
            statement.run(id, type);
            deleted += 1;
          }
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "history-clear-unfavorited");
    sendJson(res, 200, { ok: true, profile: profileId, deleted });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/image-favorites/list") {
    const data = imageFavoriteRowsFromServerDb(profileRoot, {
      limit: payload.limit,
      offset: payload.offset,
    });
    sendJson(res, 200, { ok: true, profile: profileId, ...data });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/image-favorites/replace") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const items = Array.isArray(payload.items)
      ? payload.items.map(normalizeImageFavoritePayload)
      : [];
    await withWritableHistoryDb(profileRoot, (db) => {
      ensureImageFavoritesDbSchema(db);
      db.exec("BEGIN TRANSACTION;");
      try {
        db.exec("delete from image_favorites;");
        const statement = db.prepare(`
          insert or replace into image_favorites (
            id, title, sub_title, author, tags, translated_tags, time,
            max_page, source_key, image_favorites_ep, other
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        `);
        for (const item of items) {
          statement.run(
            item.id,
            item.title,
            item.subTitle,
            item.author,
            item.tags,
            item.translatedTags,
            item.time,
            item.maxPage,
            item.sourceKey,
            item.imageFavoritesEp,
            item.other,
          );
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "image-favorites-replace");
    sendJson(res, 200, { ok: true, profile: profileId, count: items.length });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folders") {
    const filePath = serverDbEntryPath(profileRoot, "local_favorite.db");
    if (!existsSync(filePath)) {
      sendJson(res, 200, { ok: true, profile: profileId, folders: [] });
      return true;
    }
    const folders = await withFavoriteDb(profileRoot, favoriteFoldersFromDb);
    sendJson(res, 200, { ok: true, profile: profileId, folders });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folder/create") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const renameWhenInvalidName = Boolean(payload.renameWhenInvalidName);
    let name = normalizeFavoriteFolderName(payload.name, "folder name");
    await withWritableFavoriteDb(profileRoot, (db) => {
      ensureFavoriteDbSchema(db);
      if (tableExists(db, name)) {
        if (!renameWhenInvalidName) {
          throw createHttpError(409, "Favorites folder already exists");
        }
        name = nextFavoriteFolderName(db, name);
      }
      ensureFavoriteFolderTable(db, name);
      db.prepare(
        "insert or ignore into folder_order(folder_name, order_value) values (?, ?);",
      ).run(name, 0);
    });
    markServerDbDirty(profileRoot, "favorites-folder-create");
    sendJson(res, 200, { ok: true, profile: profileId, name });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folder/delete") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const name = normalizeFavoriteFolderName(payload.name, "folder name");
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, name)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      const quotedTable = sqliteIdentifier(name);
      db.exec(`drop table ${quotedTable};`);
      db.prepare("delete from folder_order where folder_name = ?;").run(name);
      db.prepare("delete from folder_sync where folder_name = ?;").run(name);
    });
    markServerDbDirty(profileRoot, "favorites-folder-delete");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folder/rename") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const before = normalizeFavoriteFolderName(payload.before, "folder name");
    const after = normalizeFavoriteFolderName(payload.after, "folder name");
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, before)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      if (before !== after && tableExists(db, after)) {
        throw createHttpError(409, "Favorites folder already exists");
      }
      if (before !== after) {
        const beforeQuoted = sqliteIdentifier(before);
        const afterQuoted = sqliteIdentifier(after);
        db.exec(`alter table ${beforeQuoted} rename to ${afterQuoted};`);
        if (tableExists(db, "folder_order")) {
          db.prepare(
            "update folder_order set folder_name = ? where folder_name = ?;",
          ).run(after, before);
        }
        if (tableExists(db, "folder_sync")) {
          db.prepare(
            "update folder_sync set folder_name = ? where folder_name = ?;",
          ).run(after, before);
        }
      }
    });
    markServerDbDirty(profileRoot, "favorites-folder-rename");
    sendJson(res, 200, { ok: true, profile: profileId, name: after });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folder/link") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const source = String(payload.source || "").trim();
    const networkFolder = String(payload.networkFolder || "").trim();
    if (!source || !networkFolder) {
      throw createHttpError(400, "Invalid favorites folder link payload");
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      db.prepare(
        "insert or replace into folder_sync(folder_name, source_key, source_folder) values (?, ?, ?);",
      ).run(folder, source, networkFolder);
    });
    markServerDbDirty(profileRoot, "favorites-folder-link");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/folder/order") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folders = Array.isArray(payload.folders) ? payload.folders : [];
    await withWritableFavoriteDb(profileRoot, (db) => {
      ensureFavoriteDbSchema(db);
      db.exec("BEGIN TRANSACTION;");
      try {
        const statement = db.prepare(
          "insert or replace into folder_order(folder_name, order_value) values (?, ?);",
        );
        folders.forEach((folderName, index) => {
          const name = normalizeFavoriteFolderName(folderName, "folder name");
          if (!tableExists(db, name)) {
            throw createHttpError(404, "Favorites folder not found");
          }
          statement.run(name, index);
        });
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-folder-order");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/list") {
    const folder = String(payload.folder || "").trim();
    if (!folder) {
      throw createHttpError(400, "Missing favorites folder");
    }
    const filePath = serverDbEntryPath(profileRoot, "local_favorite.db");
    if (!existsSync(filePath)) {
      sendJson(res, 200, {
        ok: true,
        profile: profileId,
        folder,
        total: 0,
        items: [],
      });
      return true;
    }
    const safeOffset = Math.max(0, Number(payload.offset) || 0);
    const safeLimit = Math.max(1, Math.min(500, Number(payload.limit) || 100));
    const data = await withFavoriteDb(profileRoot, (db) => {
      const folders = favoriteTableNames(db);
      if (!folders.includes(folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      const quotedTable = sqliteIdentifier(folder);
      const total = Number(
        db.prepare(`select count(*) as c from ${quotedTable};`).get()?.c || 0,
      );
      const items = db
        .prepare(
          `select * from ${quotedTable} order by display_order limit ? offset ?;`,
        )
        .all(safeLimit, safeOffset)
        .map((row) => normalizeFavoriteRow(row, folder));
      return { total, items };
    });
    sendJson(res, 200, { ok: true, profile: profileId, folder, ...data });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/add") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const item = normalizeFavoriteWriteItem(payload);
    await withWritableFavoriteDb(profileRoot, (db) => {
      writeFavoriteItem(db, folder, item);
    });
    if (item.sourceKey) {
      await withWritableHistoryDb(profileRoot, (db) => {
        saveComicBasicInfo(db, item.sourceKey, {
          id: item.id,
          title: item.name,
          author: item.author || null,
          cover: item.coverPath || null,
          tags: item.tags ? String(item.tags).split(",") : null,
        });
      });
    }
    markServerDbDirty(profileRoot, "favorites-add");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/info") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const item = payload?.item;
    const id = String(item?.id || "").trim();
    const type = Number(item?.type);
    if (!id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid favorites info payload");
    }
    const sourceKey = String(
      item?.sourceKey ?? item?.source_key ?? payload.sourceKey ?? "",
    );
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const result = db
        .prepare(
          `update ${sqliteIdentifier(folder)}
           set name = ?, author = ?, cover_path = ?, tags = ?, translated_tags = ?
           where id = ? and type = ?;`,
        )
        .run(
          String(item.name ?? item.title ?? ""),
          String(item.author || ""),
          String(item.coverPath ?? item.cover_path ?? item.cover ?? ""),
          favoriteTagsValue(item.tags),
          favoriteTagsValue(item.translatedTags ?? item.translated_tags),
          id,
          type,
        );
      if (Number(result?.changes || 0) === 0) {
        throw createHttpError(404, "Favorite item not found");
      }
    });
    if (sourceKey) {
      await withWritableHistoryDb(profileRoot, (db) => {
        saveComicBasicInfo(db, sourceKey, {
          id,
          title: String(item?.name ?? item?.title ?? ""),
          author: item?.author || null,
          cover: item?.coverPath ?? item?.cover_path ?? item?.cover ?? null,
          tags: item?.tags ? (Array.isArray(item.tags) ? item.tags : String(item.tags).split(",")) : null,
        });
      });
    }
    markServerDbDirty(profileRoot, "favorites-info");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/delete") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const id = String(payload.id || "").trim();
    const type = Number(payload.type);
    if (!id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid favorites delete payload");
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      db.prepare(
        `delete from ${sqliteIdentifier(folder)} where id = ? and type = ?;`,
      ).run(id, type);
    });
    markServerDbDirty(profileRoot, "favorites-delete");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/batch-delete") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const items = Array.isArray(payload.items) ? payload.items : [];
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      const statement = db.prepare(
        `delete from ${sqliteIdentifier(folder)} where id = ? and type = ?;`,
      );
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const entry of items) {
          const id = String(entry?.id || "").trim();
          const type = Number(entry?.type);
          if (!id || !Number.isInteger(type)) continue;
          statement.run(id, type);
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-batch-delete");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/batch-delete-all") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const items = Array.isArray(payload.items) ? payload.items : [];
    const itemKeys = new Set();
    for (const entry of items) {
      const id = String(entry?.id || "").trim();
      const type = Number(entry?.type);
      if (!id || !Number.isInteger(type)) continue;
      itemKeys.add(`${id}\u0000${type}`);
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      const tables = favoriteTableNames(db);
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const folder of tables) {
          const rows = db
            .prepare(`select id, type from ${sqliteIdentifier(folder)};`)
            .all();
          const statement = db.prepare(
            `delete from ${sqliteIdentifier(folder)} where id = ? and type = ?;`,
          );
          for (const row of rows) {
            const id = String(row.id || "").trim();
            const type = Number(row.type);
            if (!id || !Number.isInteger(type)) continue;
            if (!itemKeys.has(`${id}\u0000${type}`)) continue;
            statement.run(id, type);
          }
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-batch-delete-all");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/follow-updates/check") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const checkFolder = normalizeFavoriteFolderName(
      payload.folder || appdataGet(profileRoot, "followUpdatesFolder"),
      "folder",
    );
    if (!checkFolder) {
      throw createHttpError(400, "No follow-updates folder configured");
    }
    const ignoreCheckTime = Boolean(payload.ignoreCheckTime);
    const results = await checkFollowUpdatesFolder(
      profileRoot,
      checkFolder,
      ignoreCheckTime,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    );
    sendJson(res, 200, { ok: true, ...results, profile: profileId });
    return true;
  }

  // Async follow-update check (survives browser close)
  if (parsedUrl.pathname === "/api/server-db/follow-updates/check-async") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const checkFolder = normalizeFavoriteFolderName(
      payload.folder || appdataGet(profileRoot, "followUpdatesFolder"),
      "folder",
    );
    if (!checkFolder) {
      throw createHttpError(400, "No follow-updates folder configured");
    }
    const taskId = randomUUID();
    const taskState = {
      taskId,
      status: "pending",
      folder: checkFolder,
      total: 0,
      checked: 0,
      updated: [],
      currentItem: "",
      error: null,
      startTime: 0,
      endTime: null,
    };
    followUpdateTasks.set(taskId, taskState);
    cleanStaleTasks();

    // Start check in background — intentionally not awaited
    checkFollowUpdatesFolder(
      profileRoot,
      checkFolder,
      true, // ignoreCheckTime
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
      taskState,
    ).then((results) => {
      taskState.status = "completed";
      taskState.checked = results.checked;
      taskState.updated = results.updated;
      taskState.endTime = Date.now();
      taskState.currentItem = results.updated.length > 0
        ? `完成，发现 ${results.updated.length} 个更新`
        : `完成，检查了 ${results.checked} 项，无更新`;
      markServerDbDirty(profileRoot, "follow-updates-check");
      tryAutoBackupToWebDav(profileRoot);
    }).catch((e) => {
      taskState.status = "failed";
      taskState.error = e.message || "Unknown error";
      taskState.endTime = Date.now();
    });

    sendJson(res, 200, { ok: true, taskId, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/follow-updates/check-status") {
    const taskId = String(payload.taskId || "");
    const taskState = followUpdateTasks.get(taskId);
    if (!taskState) {
      sendJson(res, 200, { ok: true, notFound: true, profile: profileId });
      return true;
    }
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      taskId: taskState.taskId,
      status: taskState.status,
      total: taskState.total,
      checked: taskState.checked,
      updated: taskState.updated,
      currentItem: taskState.currentItem,
      error: taskState.error,
      startTime: taskState.startTime,
      endTime: taskState.endTime,
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/follow-updates/check-cancel") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const taskId = String(payload.taskId || "");
    const taskState = followUpdateTasks.get(taskId);
    if (!taskState || taskState.status !== "running") {
      sendJson(res, 200, { ok: true, notFound: true, profile: profileId });
      return true;
    }
    taskState.cancelled = true;
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/update-time") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const { id, type } = validateFavoriteIdType(
      payload,
      "Invalid favorites update-time payload",
    );
    const updateTime = String(payload.updateTime || "");
    const lastCheckTime = Number(payload.lastCheckTime);
    if (!Number.isFinite(lastCheckTime)) {
      throw createHttpError(400, "Invalid favorites update-time payload");
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const current = db
        .prepare(
          `select last_update_time from ${sqliteIdentifier(folder)} where id = ? and type = ?;`,
        )
        .get(id, type);
      if (!current) {
        throw createHttpError(404, "Favorite item not found");
      }
      db.prepare(
        `update ${sqliteIdentifier(folder)}
         set last_update_time = ?, has_new_update = ?, last_check_time = ?
         where id = ? and type = ?;`,
      ).run(
        updateTime,
        current.last_update_time === updateTime ? 0 : 1,
        lastCheckTime,
        id,
        type,
      );
    });
    markServerDbDirty(profileRoot, "favorites-update-time");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/check-time") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const { id, type } = validateFavoriteIdType(
      payload,
      "Invalid favorites check-time payload",
    );
    const lastCheckTime = Number(payload.lastCheckTime);
    if (!Number.isFinite(lastCheckTime)) {
      throw createHttpError(400, "Invalid favorites check-time payload");
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const result = db.prepare(
        `update ${sqliteIdentifier(folder)}
         set last_check_time = ?
         where id = ? and type = ?;`,
      ).run(lastCheckTime, id, type);
      if (Number(result?.changes || 0) === 0) {
        throw createHttpError(404, "Favorite item not found");
      }
    });
    markServerDbDirty(profileRoot, "favorites-check-time");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/mark-read") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const { id, type } = validateFavoriteIdType(
      payload,
      "Invalid favorites mark-read payload",
    );
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const result = db.prepare(
        `update ${sqliteIdentifier(folder)}
         set has_new_update = 0
         where id = ? and type = ?;`,
      ).run(id, type);
      if (Number(result?.changes || 0) === 0) {
        throw createHttpError(404, "Favorite item not found");
      }
    });
    markServerDbDirty(profileRoot, "favorites-mark-read");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/read") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { id, type } = validateFavoriteIdType(
      payload,
      "Invalid favorites read payload",
    );
    const moveMode = String(payload.moveMode || "none");
    const followUpdatesFolder = String(payload.followUpdatesFolder || "").trim();
    const followUpdatesFolderName = followUpdatesFolder || null;
    const nowTime = favoriteReadTime();
    let changed = false;
    await withWritableFavoriteDb(profileRoot, (db) => {
      const tables = favoriteTableNames(db);
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const folder of tables) {
          const row = db
            .prepare(
              `select display_order from ${sqliteIdentifier(folder)} where id = ? and type = ?;`,
            )
            .get(id, type);
          if (!row) continue;
          const updates = [];
          const params = [];
          if (moveMode === "end") {
            updates.push("display_order = ?");
            params.push(favoriteMaxDisplayOrder(db, folder) + 1);
          } else if (moveMode === "start") {
            updates.push("display_order = ?");
            params.push(favoriteMinDisplayOrder(db, folder) - 1);
          }
          if (followUpdatesFolderName && followUpdatesFolderName === folder) {
            updates.push("has_new_update = 0");
          }
          updates.push("time = ?");
          params.push(nowTime);
          params.push(id, type);
          db.prepare(
            `update ${sqliteIdentifier(folder)}
             set ${updates.join(", ")}
             where id = ? and type = ?;`,
          ).run(...params);
          changed = true;
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    if (changed) {
      markServerDbDirty(profileRoot, "favorites-read");
    }
    sendJson(res, 200, { ok: true, profile: profileId, changed });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/move") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceFolder = normalizeFavoriteFolderName(
      payload.sourceFolder,
      "source folder",
    );
    const targetFolder = normalizeFavoriteFolderName(
      payload.targetFolder,
      "target folder",
    );
    const id = String(payload.id || "").trim();
    const type = Number(payload.type);
    if (!id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid favorites move payload");
    }
    await withWritableFavoriteDb(profileRoot, (db) => {
      copyFavoriteItem(db, sourceFolder, targetFolder, id, type);
      db.prepare(
        `delete from ${sqliteIdentifier(sourceFolder)} where id = ? and type = ?;`,
      ).run(id, type);
    });
    markServerDbDirty(profileRoot, "favorites-move");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/batch-move") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceFolder = normalizeFavoriteFolderName(
      payload.sourceFolder,
      "source folder",
    );
    const targetFolder = normalizeFavoriteFolderName(
      payload.targetFolder,
      "target folder",
    );
    const items = Array.isArray(payload.items) ? payload.items : [];
    await withWritableFavoriteDb(profileRoot, (db) => {
      ensureFavoriteFolderTable(db, sourceFolder);
      ensureFavoriteFolderTable(db, targetFolder);
      db.exec("BEGIN TRANSACTION;");
      try {
        const deleteStatement = db.prepare(
          `delete from ${sqliteIdentifier(sourceFolder)} where id = ? and type = ?;`,
        );
        for (const entry of items) {
          const id = String(entry?.id || "").trim();
          const type = Number(entry?.type);
          if (!id || !Number.isInteger(type)) continue;
          copyFavoriteItem(db, sourceFolder, targetFolder, id, type);
          deleteStatement.run(id, type);
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-batch-move");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/batch-copy") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const sourceFolder = normalizeFavoriteFolderName(
      payload.sourceFolder,
      "source folder",
    );
    const targetFolder = normalizeFavoriteFolderName(
      payload.targetFolder,
      "target folder",
    );
    const items = Array.isArray(payload.items) ? payload.items : [];
    await withWritableFavoriteDb(profileRoot, (db) => {
      ensureFavoriteFolderTable(db, sourceFolder);
      ensureFavoriteFolderTable(db, targetFolder);
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const entry of items) {
          const id = String(entry?.id || "").trim();
          const type = Number(entry?.type);
          if (!id || !Number.isInteger(type)) continue;
          copyFavoriteItem(db, sourceFolder, targetFolder, id, type);
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-batch-copy");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/reorder") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const items = Array.isArray(payload.items) ? payload.items : [];
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const statement = db.prepare(
        `update ${sqliteIdentifier(folder)} set display_order = ? where id = ? and type = ?;`,
      );
      db.exec("BEGIN TRANSACTION;");
      try {
        for (const entry of items) {
          const id = String(entry?.id || "").trim();
          const type = Number(entry?.type);
          const order = Number(entry?.order);
          if (!id || !Number.isInteger(type) || !Number.isFinite(order)) {
            continue;
          }
          statement.run(order, id, type);
        }
        db.exec("COMMIT;");
      } catch (err) {
        db.exec("ROLLBACK;");
        throw err;
      }
    });
    markServerDbDirty(profileRoot, "favorites-reorder");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/tags") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const folder = normalizeFavoriteFolderName(payload.folder, "folder");
    const id = String(payload.id || "").trim();
    const type = payload.type == null ? null : Number(payload.type);
    if (!id) {
      throw createHttpError(400, "Invalid favorites tags payload");
    }
    const tags = favoriteTagsValue(payload.tags);
    await withWritableFavoriteDb(profileRoot, (db) => {
      if (!tableExists(db, folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      ensureFavoriteFolderTable(db, folder);
      const hasType = Number.isInteger(type);
      const quotedTable = sqliteIdentifier(folder);
      const sql = hasType
        ? `update ${quotedTable} set tags = ? where id = ? and type = ?;`
        : `update ${quotedTable} set tags = ? where id = ?;`;
      const statement = db.prepare(sql);
      const result = hasType
        ? statement.run(tags, id, type)
        : statement.run(tags, id);
      if (Number(result?.changes || 0) === 0) {
        throw createHttpError(404, "Favorite item not found");
      }
    });
    markServerDbDirty(profileRoot, "favorites-tags");
    sendJson(res, 200, { ok: true, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/find") {
    const id = String(payload.id || "").trim();
    const type = Number(payload.type);
    if (!id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid favorites find payload");
    }
    const folders = await withFavoriteDb(profileRoot, (db) =>
      favoriteTableNames(db).filter((folder) => {
        const quotedTable = sqliteIdentifier(folder);
        return (
          db
            .prepare(`select 1 from ${quotedTable} where id = ? and type = ?;`)
            .get(id, type) != null
        );
      }),
    );
    sendJson(res, 200, { ok: true, profile: profileId, folders });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/favorites/get") {
    const folder = String(payload.folder || "").trim();
    const id = String(payload.id || "").trim();
    const type = Number(payload.type);
    if (!folder || !id || !Number.isInteger(type)) {
      throw createHttpError(400, "Invalid favorites get payload");
    }
    const item = await withFavoriteDb(profileRoot, (db) => {
      const folders = favoriteTableNames(db);
      if (!folders.includes(folder)) {
        throw createHttpError(404, "Favorites folder not found");
      }
      const quotedTable = sqliteIdentifier(folder);
      const row = db
        .prepare(`select * from ${quotedTable} where id = ? and type = ?;`)
        .get(id, type);
      return row ? normalizeFavoriteRow(row, folder) : null;
    });
    if (!item) {
      throw createHttpError(404, "Favorite item not found");
    }
    sendJson(res, 200, { ok: true, profile: profileId, item });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/upload/webdav") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const config = resolveWebDavConfig(payload, webDavConfigPath);
    const fileName = normalizeWebDavBackupName(payload.fileName, {
      required: true,
    });
    const removeFileNames = Array.isArray(payload.removeFileNames)
      ? payload.removeFileNames
          .map((name) => normalizeWebDavBackupName(name, { required: false }))
          .filter((name) => name != null && name !== "latest.venera")
      : [];
    await exportCookieJarToServerDbCookieDb(profileRoot, cookieJar, {
      createIfEmpty: true,
    });
    const backup = await buildServerDbBackup(
      profileRoot,
      payload.appdata,
      payload.comicSources,
    );

    await webDavRequest({
      config,
      path: fileName,
      method: "PUT",
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(backup.buffer.length),
      },
      body: backup.buffer,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });

    for (const removeName of removeFileNames) {
      try {
        await webDavRequest({
          config,
          path: removeName,
          method: "DELETE",
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        });
      } catch (error) {
        if (Number(error?.statusCode || 0) !== 404) {
          throw error;
        }
      }
    }

    const files = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    writeServerDbMetadata(profileRoot, {
      ...readServerDbMetadata(profileRoot),
      dirty: false,
      uploadedAt: new Date().toISOString(),
      remoteFileName: fileName,
      sha256: backupSha256(backup.buffer),
      size: backup.buffer.length,
    });
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      fileName,
      size: backup.buffer.length,
      sha256: backupSha256(backup.buffer),
      databaseCount: backup.databaseCount,
      entries: backup.entryNames,
      files: sortBackupFiles(files, true),
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/sync/webdav") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const config = resolveWebDavConfig(payload, webDavConfigPath);
    const metadata = readServerDbMetadata(profileRoot);
    const force = payload.force === true;
    const existingStatus = serverDbStatus(serverDataRoot, profileId);
    if (
      !force &&
      payload.remoteFileName &&
      metadata.remoteFileName === payload.remoteFileName &&
      existingStatus.initialized
    ) {
      sendJson(res, 200, {
        ok: true,
        skipped: true,
        reason: "server-db-up-to-date",
        profile: profileId,
        status: existingStatus,
      });
      return true;
    }
    if (!force && !payload.remoteFileName && metadata.remoteFileName) {
      let availableFiles = await listWebDavBackupFiles({
        config,
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      availableFiles = availableFiles.filter((name) => name !== "latest.venera");
      const selectedFile = sortBackupFiles(availableFiles, true)[0] || "";
      if (selectedFile && selectedFile === metadata.remoteFileName && existingStatus.initialized) {
        sendJson(res, 200, {
          ok: true,
          skipped: true,
          reason: "server-db-up-to-date",
          profile: profileId,
          remoteFileName: selectedFile,
          availableFiles: sortBackupFiles(availableFiles, true),
          status: existingStatus,
        });
        return true;
      }
    }

    const downloaded = await downloadLatestWebDavBackup({
      config,
      payload,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    if (
      !force &&
      metadata.sha256 === downloaded.sha256 &&
      serverDbStatus(serverDataRoot, profileId).initialized
    ) {
      sendJson(res, 200, {
        ok: true,
        skipped: true,
        reason: "server-db-same-backup",
        profile: profileId,
        remoteFileName: downloaded.remoteFileName,
        sha256: downloaded.sha256,
        status: serverDbStatus(serverDataRoot, profileId),
      });
      return true;
    }

    const entries = extractZipEntries(
      downloaded.buffer,
      (name) =>
        serverDbBackupEntryNames.includes(name) ||
        isComicSourceBackupEntryName(name),
    );
    const written = writeServerDbBackup(profileRoot, entries);
    if (written.writtenDatabases === 0 && !written.writtenAppdata) {
      throw createHttpError(422, "Backup does not contain supported app data");
    }
    if (entries.has("cookie.db")) {
      importServerDbCookieDbToJar(profileRoot, cookieJar, persistCookieJar);
    }
    writeServerDbMetadata(profileRoot, {
      remoteFileName: downloaded.remoteFileName,
      remoteTimestamp: downloaded.remoteTimestamp,
      availableFiles: downloaded.availableFiles,
      size: downloaded.size,
      sha256: downloaded.sha256,
      syncedAt: Date.now(),
    });
    sendJson(res, 200, {
      ok: true,
      skipped: false,
      profile: profileId,
      remoteFileName: downloaded.remoteFileName,
      remoteTimestamp: downloaded.remoteTimestamp,
      size: downloaded.size,
      sha256: downloaded.sha256,
      written,
      status: serverDbStatus(serverDataRoot, profileId),
    });
    return true;
  }

  // --- Comic Source Runtime Endpoints ---

  if (parsedUrl.pathname === "/api/server-db/appdata/save") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const data = payload.data;
    if (!data || typeof data !== "object") {
      throw createHttpError(400, "Invalid appdata payload");
    }
    writeServerDbAppdata(profileRoot, data);
    sendJson(res, 200, { ok: true });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/search") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, keyword, page = 1, options } = payload;
    if (!sourceKey || !keyword) {
      throw createHttpError(400, "sourceKey and keyword are required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "search",
      args: [keyword, page, options || null],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const comics = result?.comics ?? [];
    sendJson(res, 200, {
      ok: true,
      comics,
      hasMore: result?.hasMore ?? false,
    });
    // Mirror comic basic info to local DB
    if (Array.isArray(comics) && comics.length > 0) {
      try {
        await withWritableComicInfoDb(profileRoot, (db) => {
          for (const comic of comics) {
            if (comic && typeof comic === 'object' && comic.id) {
              saveComicBasicInfo(db, sourceKey, comic);
            }
          }
        });
      } catch { /* best-effort */ }
    }
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/categories") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey } = payload;
    if (!sourceKey) {
      throw createHttpError(400, "sourceKey is required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "getCategories",
      args: [],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    sendJson(res, 200, {
      ok: true,
      categories: result ?? [],
    });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/category/comics") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, categoryId, page = 1, param, options } = payload;
    if (!sourceKey || !categoryId) {
      throw createHttpError(400, "sourceKey and categoryId are required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "getCategoryComics",
      args: [categoryId, page, param ?? null, options ?? []],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const catComics = result?.comics ?? [];
    sendJson(res, 200, {
      ok: true,
      comics: catComics,
      hasMore: result?.hasMore ?? false,
      maxPage: result?.maxPage ?? null,
    });
    // Mirror comic basic info to local DB
    if (Array.isArray(catComics) && catComics.length > 0) {
      try {
        await withWritableComicInfoDb(profileRoot, (db) => {
          for (const comic of catComics) {
            if (comic && typeof comic === 'object' && comic.id) {
              saveComicBasicInfo(db, sourceKey, comic);
            }
          }
        });
      } catch { /* best-effort */ }
    }
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/ranking") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, option, page = 1 } = payload;
    if (!sourceKey || !option) {
      throw createHttpError(400, "sourceKey and option are required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "getRanking",
      args: [option, page],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const rankingComics = result?.comics ?? [];
    sendJson(res, 200, {
      ok: true,
      comics: rankingComics,
      hasMore: result?.hasMore ?? false,
      maxPage: result?.maxPage ?? null,
    });
    // Mirror comic basic info to local DB
    if (Array.isArray(rankingComics) && rankingComics.length > 0) {
      try {
        await withWritableComicInfoDb(profileRoot, (db) => {
          for (const comic of rankingComics) {
            if (comic && typeof comic === 'object' && comic.id) {
              saveComicBasicInfo(db, sourceKey, comic);
            }
          }
        });
      } catch { /* best-effort */ }
    }
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/search/aggregated") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { keyword, page = 1, options } = payload;
    if (!keyword) {
      throw createHttpError(400, "keyword is required");
    }
    const entries = readServerDbComicSourceEntries(profileRoot);
    const sourceKeys = entries
      .map((entry) => entry.name.replace("comic_source/", "").replace(/\.(?:js|data)$/i, ""))
      .filter((key, index, arr) => arr.indexOf(key) === index);

    const results = await Promise.allSettled(
      sourceKeys.map((sourceKey) =>
        executeSourceMethod({
          profileRoot,
          sourceKey,
          method: "search",
          args: [keyword, page, options ?? null],
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        }),
      ),
    );

    const comics = [];
    for (const result of results) {
      if (result.status === "fulfilled" && result.value?.comics) {
        comics.push(...result.value.comics);
      }
    }

    sendJson(res, 200, { ok: true, comics, profile: profileId });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic/detail") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, comicId } = payload;
    if (!sourceKey || !comicId) {
      throw createHttpError(400, "sourceKey and comicId are required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "getComicInfo",
      args: [comicId],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const comic = result?.comic ?? result ?? {};
    const rawChapters = result?.chapters ?? comic?.chapters;
    const chapters = normalizeComicChapters(rawChapters);
    const comments = result?.comments ?? [];
    // Check if this comic is in favorites
    let favoriteId = null;
    try {
      favoriteId = await findFavoriteId(profileRoot, comicId, sourceKey);
    } catch { /* ignore */ }
    if (comic && typeof comic === "object") {
      comic.favoriteId = favoriteId;
      comic.sourceKey = sourceKey;
    }
    const source = comicSourceMetadataForKey(profileRoot, sourceKey);
    sendJson(res, 200, { comic, chapters, comments, source, sourceName: source.sourceName });
    // Mirror full comic detail to local DB
    if (comic && typeof comic === 'object' && comic.id) {
      try {
        await withWritableComicInfoDb(profileRoot, (db) => {
          saveComicBasicInfo(db, sourceKey, comic);
        });
      } catch { /* best-effort */ }
    }
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic/thumbnails") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, comicId } = payload;
    if (!sourceKey || !comicId) {
      throw createHttpError(400, "sourceKey and comicId are required");
    }
    let thumbnails = [];
    try {
      const result = await executeSourceMethod({
        profileRoot,
        sourceKey,
        method: "getThumbnails",
        args: [comicId],
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      thumbnails = result ?? [];
    } catch { /* source may not support thumbnails */ }
    sendJson(res, 200, { ok: true, thumbnails });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic/related") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, comicId } = payload;
    if (!sourceKey || !comicId) {
      throw createHttpError(400, "sourceKey and comicId are required");
    }
    let comics = [];
    try {
      const result = await executeSourceMethod({
        profileRoot,
        sourceKey,
        method: "getRelated",
        args: [comicId],
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      comics = result ?? [];
    } catch { /* source may not support related */ }
    sendJson(res, 200, { ok: true, comics });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic/comments") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, comicId, page = 1 } = payload;
    if (!sourceKey || !comicId) {
      throw createHttpError(400, "sourceKey and comicId are required");
    }
    let comments = [];
    try {
      const result = await executeSourceMethod({
        profileRoot,
        sourceKey,
        method: "getComments",
        args: [comicId, page],
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      comments = result ?? [];
    } catch { /* source may not support comments */ }
    sendJson(res, 200, { ok: true, comments });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/reader/pages") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, comicId, chapterId } = payload;
    if (!sourceKey || !comicId) {
      throw createHttpError(400, "sourceKey and comicId are required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "getPages",
      args: [comicId, chapterId ?? null],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    const data = normalizeComicPages(result);
    const title = result?.title ?? "";
    const comicTitle = result?.comicTitle ?? "";
    sendJson(res, 200, { ok: true, data, title, comicTitle });
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/explore/list") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { sourceKey, page = 1, exploreIndex = 0 } = payload;
    if (!sourceKey) {
      throw createHttpError(400, "sourceKey is required");
    }
    const result = await executeSourceMethod({
      profileRoot,
      sourceKey,
      method: "explore",
      args: [page, exploreIndex],
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    // Collect all comics and save/query cached basic info
    let allComics = [];
    if (result && typeof result === "object" && !Array.isArray(result) && !result.comics && !result.items) {
      allComics = Object.values(result).flatMap(items => Array.isArray(items) ? items : []);
    } else {
      allComics = Array.isArray(result) ? result
        : (result?.comics ?? result?.items ?? []);
    }
    // Save and query cached basic info BEFORE sending response
    const cachedInfo = {};
    if (allComics.length > 0) {
      try {
        await withWritableComicInfoDb(profileRoot, (db) => {
          // Save explore data to DB (future requests benefit)
          for (const comic of allComics) {
            if (comic && typeof comic === 'object' && comic.id) {
              saveComicBasicInfo(db, sourceKey, comic);
            }
          }
          // Query cached info for all returned comics
          const stmt = db.prepare("select * from comic_basic_info where comic_id = ?");
          for (const comic of allComics) {
            if (!comic || typeof comic !== 'object' || !comic.id) continue;
            const row = stmt.get(`${sourceKey}:${comic.id}`);
            if (row) {
              cachedInfo[comic.id] = {
                subtitle: row.subtitle || undefined,
                author: row.author || undefined,
                status: row.status || undefined,
                updateTime: row.update_time || undefined,
                language: row.language || undefined,
                description: row.description || undefined,
                tags: row.tags_json ? JSON.parse(row.tags_json) : undefined,
                pageCount: row.page_count || undefined,
              };
            }
          }
        });
      } catch { /* best-effort */ }
    }
    // Merge cached info into each comic
    function mergeCached(comic) {
      if (!comic || typeof comic !== 'object') return comic;
      const info = cachedInfo[comic.id];
      if (!info) return comic;
      const merged = { ...info, ...comic };
      // Prefer existing fields over cached
      if (!merged.subtitle && info.subtitle) merged.subtitle = info.subtitle;
      return merged;
    }
    if (result && typeof result === "object" && !Array.isArray(result) && !result.comics && !result.items) {
      const sections = Object.entries(result).map(([title, items]) => ({
        title,
        comics: (Array.isArray(items) ? items : []).map(mergeCached),
      }));
      sendJson(res, 200, { ok: true, type: "multiPart", sections });
    } else {
      const comics = allComics.map(mergeCached);
      sendJson(res, 200, { ok: true, type: "list", comics });
    }
    return true;
  }

  if (parsedUrl.pathname === "/api/server-db/comic/basic-info/batch") {
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return true;
    }
    const { ids } = payload;
    if (!Array.isArray(ids) || ids.length === 0) {
      sendJson(res, 200, { ok: true, items: {} });
      return true;
    }
    const items = {};
    try {
      await withWritableComicInfoDb(profileRoot, (db) => {
        const stmt = db.prepare(
          "select * from comic_basic_info where comic_id = ?"
        );
        for (const { sourceKey, comicId } of ids) {
          if (!sourceKey || !comicId) continue;
          const key = `${sourceKey}:${comicId}`;
          const row = stmt.get(key);
          if (row) {
            items[key] = {
              title: row.title,
              subtitle: row.subtitle || undefined,
              description: row.description || undefined,
              author: row.author || undefined,
              status: row.status || undefined,
              updateTime: row.update_time || undefined,
              language: row.language || undefined,
              coverUri: row.cover_uri || undefined,
              tags: row.tags_json ? JSON.parse(row.tags_json) : undefined,
              pageCount: row.page_count || undefined,
            };
          }
        }
      });
    } catch { /* best-effort */ }
    sendJson(res, 200, { ok: true, items });
    return true;
  }

  sendJson(res, 404, { error: "Not found" });
  return true;
}

function canFallbackToLatest(error) {
  const statusCode = Number(error?.statusCode || 0);
  return (
    statusCode === 404 ||
    statusCode === 405 ||
    statusCode === 501 ||
    statusCode === 403 ||
    error?.code === "SIDECAR_UPSTREAM_ERROR"
  );
}

async function webDavRequest({
  config,
  path = "",
  method = "GET",
  headers = {},
  body,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  const targetUrl = path ? new URL(path, config.baseUrl).toString() : config.baseUrl;
  const response = await proxyFetch({
    url: targetUrl,
    method,
    headers: {
      Authorization: webDavAuthHeader(config.user, config.pass),
      ...headers,
    },
    body,
    cookieJar,
    persistCookieJar,
    recordProxyRequest,
  });
  const responseBody = Buffer.from(await response.arrayBuffer());
  if (response.status >= 400) {
    const error = createHttpError(
      response.status,
      `WebDAV ${method} ${path || "/"} failed with HTTP ${response.status}`,
    );
    error.responseBody = responseBody.toString("utf-8");
    throw error;
  }
  return {
    status: response.status,
    headers: responseHeaders(response),
    body: responseBody,
  };
}

async function listWebDavBackupFiles({
  config,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  try {
    const result = await webDavRequest({
      config,
      method: "PROPFIND",
      headers: {
        Depth: "1",
        "Content-Type": "application/xml",
      },
      body:
        '<?xml version="1.0"?>' +
        '<d:propfind xmlns:d="DAV:">' +
        "<d:prop><d:displayname/></d:prop>" +
        "</d:propfind>",
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    return parseWebDavFileNames(result.body.toString("utf-8"), config.baseUrl);
  } catch (error) {
    if (canFallbackToLatest(error)) {
      return [];
    }
    throw error;
  }
}

async function handleSyncWebDavRoute({
  req,
  res,
  parsedUrl,
  webDavConfigPath,
  cookieJar,
  persistCookieJar,
  recordProxyRequest,
}) {
  if (!parsedUrl.pathname.startsWith("/sync/webdav/")) {
    return false;
  }
  if (req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return true;
  }

  const payload = parseJsonBody(await readBody(req), "Invalid sync payload");

  if (parsedUrl.pathname === "/sync/webdav/config/get") {
    const stored = readStoredWebDavConfig(webDavConfigPath);
    sendJson(res, 200, {
      ok: true,
      configured: stored != null,
      ...(stored || {}),
    });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/config/save") {
    const stored = writeStoredWebDavConfig(webDavConfigPath, payload);
    sendJson(res, 200, { ok: true, configured: true, ...stored });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/config/clear") {
    clearStoredWebDavConfig(webDavConfigPath);
    sendJson(res, 200, { ok: true, configured: false });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/logs") {
    sendJson(res, 200, { ok: true, logs: syncLogs });
    return true;
  }

  const config = resolveWebDavConfig(payload, webDavConfigPath);

  if (parsedUrl.pathname === "/sync/webdav/test") {
    const files = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    sendJson(res, 200, { ok: true, files: sortBackupFiles(files, true) });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/list") {
    const files = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    sendJson(res, 200, { ok: true, files: sortBackupFiles(files, true) });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/download") {
    const force = payload.force === true;
    const remoteFileName = normalizeWebDavBackupName(payload.remoteFileName);
    const lastSyncTime = Number(payload.lastSyncTime || 0);

    let selectedFile = remoteFileName;
    let remoteTimestamp = null;
    let buffer = null;
    let availableFiles = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    availableFiles = availableFiles.filter((name) => name !== "latest.venera");

    if (selectedFile) {
      const result = await webDavRequest({
        config,
        path: selectedFile,
        method: "GET",
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      buffer = result.body;
      remoteTimestamp = backupTimestamp(selectedFile) || null;
    } else if (availableFiles.length > 0) {
      selectedFile = sortBackupFiles(availableFiles, true)[0];
      const timestamp = backupTimestamp(selectedFile);
      const isOldFormat = selectedFile.includes("-");
      if (
        !force &&
        !isOldFormat &&
        Number.isFinite(timestamp) &&
        timestamp > 0 &&
        timestamp <= lastSyncTime
      ) {
        sendJson(res, 200, {
          ok: true,
          skipped: true,
          reason: "up-to-date",
          remoteFileName: selectedFile,
          remoteTimestamp: timestamp,
          availableFiles: sortBackupFiles(availableFiles, true),
        });
        return true;
      }
      const result = await webDavRequest({
        config,
        path: selectedFile,
        method: "GET",
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      });
      buffer = result.body;
      remoteTimestamp = timestamp || null;
    } else {
      try {
        const result = await webDavRequest({
          config,
          path: "latest.venera",
          method: "GET",
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        });
        buffer = result.body;
        selectedFile = "latest.venera";
        remoteTimestamp = Date.now();
      } catch (error) {
        if (canFallbackToLatest(error)) {
          sendJson(res, 200, {
            ok: true,
            skipped: true,
            reason: "no-backup",
            availableFiles: [],
          });
          return true;
        }
        throw error;
      }
    }

    assertLooksLikeVeneraBackup(buffer, selectedFile || "downloaded backup");
    addSyncLog("download", selectedFile, true, null);
    sendJson(res, 200, {
      ok: true,
      skipped: false,
      remoteFileName: selectedFile,
      remoteTimestamp,
      availableFiles: sortBackupFiles(availableFiles, true),
      size: buffer.length,
      sha256: backupSha256(buffer),
      dataBase64: buffer?.toString("base64") || "",
    });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/upload") {
    const fileName = normalizeWebDavBackupName(payload.fileName, {
      required: true,
    });
    const removeFileNames = Array.isArray(payload.removeFileNames)
      ? payload.removeFileNames
          .map((name) => normalizeWebDavBackupName(name, { required: false }))
          .filter((name) => name != null && name !== "latest.venera")
      : [];

    const dataBase64 = String(payload.dataBase64 || "");
    if (!dataBase64) {
      throw createHttpError(400, "Missing upload payload");
    }
    const bytes = Buffer.from(dataBase64, "base64");
    if (bytes.length === 0) {
      throw createHttpError(400, "Upload payload is empty");
    }
    assertLooksLikeVeneraBackup(bytes, fileName);

    await webDavRequest({
      config,
      path: fileName,
      method: "PUT",
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(bytes.length),
      },
      body: bytes,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });

    for (const removeName of removeFileNames) {
      if (!removeName) continue;
      try {
        await webDavRequest({
          config,
          path: removeName,
          method: "DELETE",
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        });
      } catch (error) {
        if (Number(error?.statusCode || 0) !== 404) {
          throw error;
        }
      }
    }

    const files = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    addSyncLog("upload", fileName, true, null);
    sendJson(res, 200, {
      ok: true,
      fileName,
      size: bytes.length,
      sha256: backupSha256(bytes),
      files: sortBackupFiles(files, true),
    });
    return true;
  }

  if (parsedUrl.pathname === "/sync/webdav/cleanup") {
    const removeFileNames = Array.isArray(payload.removeFileNames)
      ? payload.removeFileNames
          .map((name) => normalizeWebDavBackupName(name, { required: false }))
          .filter((name) => name != null && name !== "latest.venera")
      : [];
    for (const removeName of removeFileNames) {
      if (!removeName) continue;
      try {
        await webDavRequest({
          config,
          path: removeName,
          method: "DELETE",
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        });
      } catch (error) {
        if (Number(error?.statusCode || 0) !== 404) {
          throw error;
        }
      }
    }
    const files = await listWebDavBackupFiles({
      config,
      cookieJar,
      persistCookieJar,
      recordProxyRequest,
    });
    sendJson(res, 200, {
      ok: true,
      files: sortBackupFiles(files, true),
    });
    return true;
  }

  sendJson(res, 404, { error: "Not found" });
  return true;
}

function tryServeStatic(req, res, parsedUrl, staticDir) {
  if (!staticDir) return false;
  const pathname = decodeURIComponent(parsedUrl.pathname);
  const safePath = normalize(pathname).replace(/^(\.\.[/\\])+/, "");
  const requested = resolve(join(staticDir, safePath));
  const root = resolve(staticDir);
  let filePath = requested.startsWith(root) ? requested : root;
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
    filePath = join(root, "index.html");
  }
  if (!existsSync(filePath)) return false;
  const stat = statSync(filePath);
  if (stat.isDirectory()) return false;
  const extension = extname(filePath).toLowerCase();
  const contentType = staticContentTypes[extension];
  if (contentType) res.setHeader("Content-Type", contentType);
  res.setHeader("Cache-Control", staticCacheControl(filePath));
  res.setHeader("Last-Modified", stat.mtime.toUTCString());
  res.setHeader("X-Content-Type-Options", "nosniff");
  const canGzip = stat.size > 1024 && gzipStaticExtensions.has(extension);
  if (canGzip) res.setHeader("Vary", "Accept-Encoding");
  if (req.headers["if-modified-since"]) {
    const since = new Date(String(req.headers["if-modified-since"]));
    if (
      !Number.isNaN(since.valueOf()) &&
      Math.floor(stat.mtimeMs / 1000) <= Math.floor(since.valueOf() / 1000)
    ) {
      res.writeHead(304);
      res.end();
      return true;
    }
  }
  const shouldGzip =
    canGzip && acceptsGzipEncoding(req.headers["accept-encoding"]);
  if (shouldGzip) {
    res.setHeader("Content-Encoding", "gzip");
    createReadStream(filePath).pipe(createGzip({ level: 6 })).pipe(res);
    return true;
  }
  res.setHeader("Content-Length", String(stat.size));
  createReadStream(filePath).pipe(res);
  return true;
}

function sendBrowserView(req, res, sessionId) {
  const safeId = JSON.stringify(sessionId);
  const text = helperUiText(req);
  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${htmlEscape(text.browserTitle)}</title>
  <style>
    body { margin: 0; font-family: system-ui, sans-serif; background: #111; color: #eee; }
    header { display: flex; gap: 8px; align-items: center; padding: 8px; background: #202020; position: sticky; top: 0; z-index: 1; }
    input { min-width: 0; padding: 8px; border-radius: 6px; border: 1px solid #555; background: #181818; color: #eee; }
    #url { flex: 1; }
    button { padding: 8px 10px; border: 0; border-radius: 6px; background: #3f7cff; color: white; cursor: pointer; }
    #status { padding: 8px; white-space: pre-wrap; color: #bdbdbd; font-size: 12px; background: #181818; }
    #screen { display: block; width: 100%; max-width: 1280px; margin: 0 auto; background: white; touch-action: manipulation; user-select: none; -webkit-user-select: none; }
  </style>
</head>
<body>
  <header>
    <input id="url" placeholder="${htmlEscape(text.urlPlaceholder)}">
    <button id="go">${htmlEscape(text.go)}</button>
    <input id="text" placeholder="${htmlEscape(text.textPlaceholder)}">
    <button id="type">${htmlEscape(text.type)}</button>
    <button id="enter">${htmlEscape(text.enter)}</button>
    <button id="sync">${htmlEscape(text.sync)}</button>
  </header>
  <div id="status">${htmlEscape(text.loading)}</div>
  <img id="screen" alt="${htmlEscape(text.screenAlt)}" draggable="false">
  <script>
    const sessionId = ${safeId};
    const screen = document.getElementById('screen');
    const statusEl = document.getElementById('status');
    const urlInput = document.getElementById('url');
    async function call(action, options = {}) {
      return fetch('/browser/session/' + encodeURIComponent(sessionId) + '/' + action, options);
    }
    async function refresh() {
      screen.src = '/browser/session/' + encodeURIComponent(sessionId) + '/screenshot?t=' + Date.now();
      const res = await call('state');
      const json = await res.json();
      applyState(json.state || {});
    }
    function applyState(state) {
      urlInput.value = state.url || '';
      deviceScaleFactor = state.deviceScaleFactor || 1;
      screen.src = '/browser/session/' + encodeURIComponent(sessionId) + '/screenshot?t=' + Date.now();
      statusEl.textContent = (state.title || '') + '\\n' + (state.url || '') +
        '\\ncookies=' + ((state.cookies || []).length) +
        ' localStorageKeys=' + Object.keys(state.localStorage || {}).length;
    }
    function connectEvents() {
      if (!window.WebSocket) {
        refresh();
        setInterval(refresh, 2000);
        return;
      }
      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const socket = new WebSocket(protocol + '//' + location.host +
        '/browser/session/' + encodeURIComponent(sessionId) + '/events');
      socket.onmessage = (event) => {
        try {
          const json = JSON.parse(event.data);
          if (json.type === 'state') applyState(json.state || {});
        } catch (_) {}
      };
      socket.onclose = () => setTimeout(connectEvents, 1500);
      socket.onerror = () => {
        try { socket.close(); } catch (_) {}
      };
    }
    let lastPointerTapAt = 0;
    let deviceScaleFactor = 1;
    async function sendScreenTap(clientX, clientY) {
      const rect = screen.getBoundingClientRect();
      const scaleX = (screen.naturalWidth || rect.width) / rect.width;
      const scaleY = (screen.naturalHeight || rect.height) / rect.height;
      await call('click', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          x: Math.round((clientX - rect.left) * scaleX / deviceScaleFactor),
          y: Math.round((clientY - rect.top) * scaleY / deviceScaleFactor),
        }),
      });
      setTimeout(refresh, 500);
    }
    screen.addEventListener('pointerup', async (event) => {
      if (event.pointerType === 'mouse' && event.button !== 0) return;
      event.preventDefault();
      lastPointerTapAt = Date.now();
      await sendScreenTap(event.clientX, event.clientY);
    });
    screen.addEventListener('click', async (event) => {
      if (Date.now() - lastPointerTapAt < 700) return;
      await sendScreenTap(event.clientX, event.clientY);
    });
    document.getElementById('go').onclick = async () => {
      await call('navigate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: urlInput.value }),
      });
      await refresh();
    };
    document.getElementById('type').onclick = async () => {
      await call('type', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: document.getElementById('text').value }),
      });
      document.getElementById('text').value = '';
      setTimeout(refresh, 500);
    };
    document.getElementById('enter').onclick = async () => {
      await call('press', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: 'Enter' }),
      });
      setTimeout(refresh, 500);
    };
    document.getElementById('sync').onclick = async () => {
      await call('sync-cookies', { method: 'POST' });
      await refresh();
    };
    connectEvents();
  </script>
</body>
</html>`;
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(html);
}

async function handleBrowserUpgrade({
  req,
  socket,
  parsedUrl,
  cookieJar,
  persistCookieJar,
  browserSessions,
}) {
  const segments = parsedUrl.pathname.split("/").filter(Boolean);
  if (
    segments[0] !== "browser" ||
    segments[1] !== "session" ||
    segments[3] !== "events"
  ) {
    socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const sessionId = sanitizeSessionId(decodeURIComponent(segments[2] || ""));
  const session = browserSessions.get(sessionId);
  if (!session) {
    socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const key = req.headers["sec-websocket-key"];
  if (!key) {
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  socket.write(
    [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${websocketAcceptKey(key)}`,
      "",
      "",
    ].join("\r\n"),
  );

  const targetUrl = parsedUrl.searchParams.get("url") || undefined;
  let previousPayload = "";
  let closed = false;
  const push = async () => {
    if (closed || socket.destroyed) return;
    try {
      const state = await session.state(targetUrl);
      const syncedCookies = targetUrl
        ? syncBrowserCookies(cookieJar, targetUrl, state, persistCookieJar)
        : [];
      const payload = JSON.stringify({
        type: "state",
        ...statePayload(req, sessionId, state, syncedCookies),
      });
      if (payload !== previousPayload) {
        previousPayload = payload;
        sendWebSocketText(socket, payload);
      }
    } catch (error) {
      sendWebSocketText(
        socket,
        JSON.stringify({
          type: "error",
          sessionId,
          error: error.message || String(error),
        }),
      );
    }
  };

  const intervalMs = Number(process.env.VENERA_BROWSER_EVENT_INTERVAL_MS || 1000);
  const interval = setInterval(push, Number.isFinite(intervalMs) ? intervalMs : 1000);
  interval.unref?.();
  socket.on("close", () => {
    closed = true;
    clearInterval(interval);
  });
  socket.on("error", () => {
    closed = true;
    clearInterval(interval);
  });
  socket.on("data", (chunk) => {
    if (chunk[0] === 0x88) {
      closed = true;
      clearInterval(interval);
      closeWebSocket(socket);
    }
  });
  setTimeout(push, 0).unref?.();
}

async function handleBrowserRoute({
  req,
  res,
  parsedUrl,
  cookieJar,
  persistCookieJar,
  browserSessions,
  getOrCreateBrowserSession,
}) {
  const segments = parsedUrl.pathname.split("/").filter(Boolean);
  if (segments[0] !== "browser" || segments[1] !== "session") {
    return false;
  }

  if (segments.length === 2 && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    if (!isValidTarget(payload.url)) {
      sendJson(res, 400, { error: "Invalid URL scheme" });
      return true;
    }
    const sessionId = sanitizeSessionId(payload.sessionId || payload.sourceKey);
    const { session } = await getOrCreateBrowserSession(
      sessionId,
      payload.profile,
    );
    await session.navigate(payload.url, Number(payload.waitMs || 45000));
    const state = await session.state(payload.url);
    const syncedCookies =
      payload.syncCookies === false
        ? []
        : syncBrowserCookies(cookieJar, payload.url, state, persistCookieJar);
    sendJson(res, 200, statePayload(req, sessionId, state, syncedCookies));
    return true;
  }

  if (segments.length < 3) {
    sendJson(res, 404, { error: "Not found" });
    return true;
  }

  const sessionId = sanitizeSessionId(decodeURIComponent(segments[2]));
  const action = segments[3] || "";
  const session = browserSessions.get(sessionId);
  if (!session) {
    sendJson(res, 404, { error: "Browser session not found" });
    return true;
  }

  if (action === "view" && req.method === "GET") {
    sendBrowserView(req, res, sessionId);
    return true;
  }

  if ((action === "state" || action === "") && req.method === "GET") {
    const targetUrl = parsedUrl.searchParams.get("url") || undefined;
    const state = await session.state(targetUrl);
    sendJson(res, 200, statePayload(req, sessionId, state));
    return true;
  }

  if (action === "sync-cookies" && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    const targetUrl =
      payload.url || parsedUrl.searchParams.get("url") || (await session.state()).url;
    const state = await session.state(targetUrl);
    const syncedCookies = syncBrowserCookies(
      cookieJar,
      targetUrl,
      state,
      persistCookieJar,
    );
    sendJson(res, 200, statePayload(req, sessionId, state, syncedCookies));
    return true;
  }

  if (action === "navigate" && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    if (!isValidTarget(payload.url)) {
      sendJson(res, 400, { error: "Invalid URL scheme" });
      return true;
    }
    await session.navigate(payload.url, Number(payload.waitMs || 45000));
    const state = await session.state(payload.url);
    sendJson(res, 200, statePayload(req, sessionId, state));
    return true;
  }

  if (action === "screenshot" && req.method === "GET") {
    const image = await session.screenshot();
    res.writeHead(200, {
      "Content-Type": "image/png",
      "Cache-Control": "no-store",
    });
    res.end(image);
    return true;
  }

  if (action === "click" && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    await session.click(payload.x, payload.y);
    sendJson(res, 200, { ok: true });
    return true;
  }

  if (action === "type" && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    await session.type(payload.text || "");
    sendJson(res, 200, { ok: true });
    return true;
  }

  if (action === "press" && req.method === "POST") {
    const payload = JSON.parse((await readBody(req)).toString() || "{}");
    await session.press(payload.key || "Enter");
    sendJson(res, 200, { ok: true });
    return true;
  }

  if ((action === "close" && req.method === "POST") || req.method === "DELETE") {
    await session.close();
    browserSessions.delete(sessionId);
    sendJson(res, 200, { ok: true });
    return true;
  }

  sendJson(res, 404, { error: "Not found" });
  return true;
}

export function createServer(options = {}) {
  // Prevent source script errors from crashing the server process
  process.on("uncaughtException", (error) => {
    console.error("[uncaughtException]", error.message || error);
  });
  process.on("unhandledRejection", (reason) => {
    console.error("[unhandledRejection]", reason?.message || reason);
  });

  const staticDir = options.staticDir || process.env.VENERA_STATIC_DIR || "";
  const browserSessions = new Map();
  const loginImports = new Map();
  let browserFactory = Object.hasOwn(options, "browserFactory")
    ? options.browserFactory
    : null;
  const browserDataRoot = resolve(
    options.browserDataDir ||
      process.env.VENERA_BROWSER_DATA_DIR ||
      join(process.cwd(), ".browser-data"),
  );
  const serverDataRoot = resolve(
    options.serverDataDir ||
      process.env.VENERA_SERVER_DATA_DIR ||
      join(process.cwd(), ".venera-helper-data"),
  );
  const webDavConfigPath = resolve(
    options.webDavConfigPath ||
      process.env.VENERA_WEBDAV_CONFIG_PATH ||
      join(serverDataRoot, "webdav-config.json"),
  );
  const cookieJarPath =
    options.cookieJarPath || process.env.VENERA_COOKIE_JAR_PATH || "";
  const cookieJar = loadCookieJar(cookieJarPath);
  const persistCookieJar = createCookieJarPersistor(cookieJar, cookieJarPath);

  // Load cookies from synced cookie.db at startup (default profile)
  try {
    const defaultProfileRoot = join(serverDataRoot, "profiles", "default");
    const imported = importServerDbCookieDbToJar(defaultProfileRoot, cookieJar, persistCookieJar);
    if (imported.length > 0) console.log(`Loaded ${imported.length} cookies from cookie.db`);
  } catch (e) { console.error("[cookie.db import]", e.message || e); }

  const proxyRequests = createProxyRequestRecorder();
  const recordProxyRequest = (entry) => proxyRequests.push(entry);

  async function getBrowserFactory() {
    if (browserFactory === false) {
      const error = new Error("Browser helper disabled");
      error.statusCode = 503;
      throw error;
    }
    if (browserFactory) return browserFactory;
    browserFactory = await createPlaywrightBrowserFactory();
    return browserFactory;
  }

  async function getOrCreateBrowserSession(sessionId, profile) {
    const id = sanitizeSessionId(sessionId);
    let session = browserSessions.get(id);
    if (!session) {
      const factory = await getBrowserFactory();
      const resolvedProfile = normalizeBrowserProfile(profile);
      session = await factory.createSession({
        id,
        profile: resolvedProfile,
        userDataDir: join(browserDataRoot, id),
      });
      browserSessions.set(id, session);
    }
    return { id, session };
  }

  const server = createHttpServer(async (req, res) => {
    writeCorsHeaders(req, res);
    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    try {
      const parsedUrl = new URL(req.url || "/", "http://127.0.0.1");
      if (parsedUrl.pathname === "/healthz") {
        sendJson(res, 200, { ok: true });
        return;
      }

      if (parsedUrl.pathname === "/debug/proxy-requests") {
        if (req.method === "DELETE") {
          proxyRequests.clear();
          sendJson(res, 200, { ok: true, requests: [] });
          return;
        }
        sendJson(res, 200, { ok: true, requests: proxyRequests.list() });
        return;
      }

      if (
        parsedUrl.pathname === "/proxy" ||
        parsedUrl.pathname === "/proxy.php"
      ) {
        const rawBody = await readBody(req);
        const isJsonMode =
          req.method === "POST" &&
          !parsedUrl.searchParams.has("url") &&
          String(req.headers["content-type"] || "").includes("application/json");
        if (isJsonMode) {
          await handleJsonProxy(
            req,
            res,
            rawBody,
            cookieJar,
            persistCookieJar,
            recordProxyRequest,
          );
        } else {
          await handleQueryProxy(
            req,
            res,
            parsedUrl,
            rawBody,
            cookieJar,
            persistCookieJar,
            recordProxyRequest,
          );
        }
        return;
      }

      if (parsedUrl.pathname === "/api/image") {
        const rawBody = req.method === "POST" ? await readBody(req) : Buffer.alloc(0);
        await handleImageProxy(
          req,
          res,
          parsedUrl,
          rawBody,
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        );
        return;
      }

      if (parsedUrl.pathname === "/api/source/check-update") {
        if (req.method !== "POST") {
          sendJson(res, 405, { error: "Method not allowed" });
          return;
        }
        const rawBody = await readBody(req);
        const payload = parseJsonBody(rawBody, "Invalid source update payload");
        const sourceKey = validateComicSourceKey(payload.sourceKey);
        sendJson(res, 200, {
          ok: true,
          sourceKey,
          updateAvailable: false,
          supported: false,
          message: "Source update check is not supported in web helper yet",
        });
        return;
      }

      if (parsedUrl.pathname === "/cookies/export") {
        if (req.method !== "GET" && req.method !== "POST") {
          sendJson(res, 405, { error: "Method not allowed" });
          return;
        }
        sendJson(res, 200, {
          ok: true,
          cookies: exportCookieRecords(cookieJar),
        });
        return;
      }

      if (parsedUrl.pathname === "/cookies/import") {
        if (req.method !== "POST") {
          sendJson(res, 405, { error: "Method not allowed" });
          return;
        }
        const rawBody = await readBody(req);
        const payload = JSON.parse(rawBody.toString() || "{}");
        sendJson(res, 200, {
          ok: true,
          cookies: importCookieRecords(
            cookieJar,
            payload.cookies || [],
            persistCookieJar,
          ),
        });
        return;
      }

      if (parsedUrl.pathname === "/cookies") {
        if (req.method === "GET") {
          const target = parsedUrl.searchParams.get("url") || "";
          if (!isValidTarget(target)) {
            sendJson(res, 400, { error: "Invalid URL scheme" });
            return;
          }
          sendJson(res, 200, { cookies: exportCookies(cookieJar, target) });
          return;
        }
        if (req.method === "POST") {
          const rawBody = await readBody(req);
          const payload = JSON.parse(rawBody.toString() || "{}");
          if (!isValidTarget(payload.url)) {
            sendJson(res, 400, { error: "Invalid URL scheme" });
            return;
          }
          sendJson(res, 200, {
            cookies: importCookies(
              cookieJar,
              payload.url,
              payload.cookies || [],
              persistCookieJar,
            ),
          });
          return;
        }
        if (req.method === "DELETE") {
          const target = parsedUrl.searchParams.get("url") || "";
          if (!isValidTarget(target)) {
            sendJson(res, 400, { error: "Invalid URL scheme" });
            return;
          }
          deleteCookiesForUrl(cookieJar, target, persistCookieJar);
          sendJson(res, 200, { ok: true });
          return;
        }
      }

      if (await handleExtractDbRoute({ req, res, parsedUrl })) {
        return;
      }

      if (
        await handleServerDbRoute({
          req,
          res,
          parsedUrl,
          serverDataRoot,
          webDavConfigPath,
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        })
      ) {
        return;
      }

      if (
        await handleSyncWebDavRoute({
          req,
          res,
          parsedUrl,
          webDavConfigPath,
          cookieJar,
          persistCookieJar,
          recordProxyRequest,
        })
      ) {
        return;
      }

      if (
        await handleLoginImportRoute({
          req,
          res,
          parsedUrl,
          loginImports,
        })
      ) {
        return;
      }

      if (
        await handleBrowserRoute({
          req,
          res,
          parsedUrl,
          cookieJar,
          persistCookieJar,
          browserSessions,
          getOrCreateBrowserSession,
        })
      ) {
        return;
      }

      if (tryServeStatic(req, res, parsedUrl, staticDir)) return;
      sendJson(res, 404, { error: "Not found" });
    } catch (error) {
      const statusCode = error.statusCode || 502;
      sendJson(res, statusCode, { error: error.message || String(error) });
    }
  });

  server.on("upgrade", async (req, socket) => {
    try {
      const parsedUrl = new URL(req.url || "/", "http://127.0.0.1");
      await handleBrowserUpgrade({
        req,
        socket,
        parsedUrl,
        cookieJar,
        persistCookieJar,
        browserSessions,
      });
    } catch (error) {
      socket.write(
        "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n" +
          (error.message || String(error)),
      );
      socket.destroy();
    }
  });

  // Periodic follow-updates check (every 10 minutes)
  const followUpdatesTimer = setInterval(() => {
    try {
      const appdataPath = join(defaultProfileRoot, "appdata.json");
      if (!existsSync(appdataPath)) return;
      const appdata = JSON.parse(readFileSync(appdataPath, "utf8"));
      const folder = appdata?.followUpdatesFolder;
      if (!folder) return;
      checkFollowUpdatesFolder(
        defaultProfileRoot,
        String(folder),
        false,
        cookieJar,
        persistCookieJar,
        recordProxyRequest,
      ).catch(() => {});
    } catch { /* timer errors should not crash the server */ }
  }, 10 * 60 * 1000);
  server.on("close", () => clearInterval(followUpdatesTimer));

  // Build a minimal venera backup ZIP from server databases
  function createBackupZip(profileRoot) {
    const chunks = [];
    const cdEntries = [];
    const encoder = new TextEncoder();
    let cdOffset = 0;

    function addZipEntry(name, data) {
      const nameBytes = encoder.encode(name);
      const local = Buffer.alloc(30 + nameBytes.length);
      local.writeUInt32LE(0x04034b50, 0); // local file header signature
      local.writeUInt16LE(20, 4);          // version needed
      local.writeUInt32LE(0, 14);          // crc32 (omitted)
      local.writeUInt32LE(data.length, 18); // compressed size
      local.writeUInt32LE(data.length, 22); // uncompressed size
      local.writeUInt16LE(nameBytes.length, 26);
      chunks.push(local);
      chunks.push(Buffer.from(nameBytes));
      chunks.push(data);

      const cd = Buffer.alloc(46 + nameBytes.length);
      cd.writeUInt32LE(0x02014b50, 0);    // central directory header
      cd.writeUInt16LE(20, 4);
      cd.writeUInt16LE(20, 6);
      cd.writeUInt32LE(0, 16);             // crc32
      cd.writeUInt32LE(data.length, 20);
      cd.writeUInt32LE(data.length, 24);
      cd.writeUInt16LE(nameBytes.length, 28);
      cd.writeUInt32LE(cdOffset, 42);
      cdEntries.push(cd);
      cdEntries.push(Buffer.from(nameBytes));
      cdOffset += 30 + nameBytes.length + data.length;
    }

    for (const entryName of serverDbBackupEntryNames) {
      const filePath = serverDbEntryPath(profileRoot, entryName);
      if (existsSync(filePath)) {
        addZipEntry(entryName, readFileSync(filePath));
      }
    }

    const sourcesDir = join(profileRoot, "sources");
    if (existsSync(sourcesDir)) {
      try {
        for (const file of readdirSync(sourcesDir)) {
          if (file.endsWith(".mjs") || file.endsWith(".js")) {
            addZipEntry(`sources/${file}`, readFileSync(join(sourcesDir, file)));
          }
        }
      } catch { /* skip */ }
    }

    const cdBuf = Buffer.concat(cdEntries);
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(cdEntries.length / 2, 8);
    eocd.writeUInt16LE(cdEntries.length / 2, 10);
    eocd.writeUInt32LE(cdBuf.length, 12);
    eocd.writeUInt32LE(cdOffset, 16);

    return Buffer.concat([...chunks, cdBuf, eocd]);
  }

  // Auto-upload backup to WebDAV (called after background check finds updates)
  async function tryAutoBackupToWebDav(profileRoot) {
    try {
      const stored = readStoredWebDavConfig(webDavConfigPath);
      if (!stored || !stored.url) return;
      const config = normalizeWebDavConfig(stored);

      let existingFiles = [];
      try {
        existingFiles = (await listWebDavBackupFiles({
          config, cookieJar, persistCookieJar, recordProxyRequest,
        })).filter(f => f !== "latest.venera");
      } catch { /* proceed with upload even if list fails */ }

      const daysSinceEpoch = Math.floor(Date.now() / 86400000);
      let dataVersion = 0;
      try {
        const appdataPath = join(profileRoot, "appdata.json");
        if (existsSync(appdataPath)) {
          const ad = JSON.parse(readFileSync(appdataPath, "utf8"));
          dataVersion = Number(ad?.settings?.dataVersion) || 0;
        }
      } catch { /* use 0 */ }
      dataVersion += 1;
      try {
        const appdataPath = join(profileRoot, "appdata.json");
        const ad = existsSync(appdataPath) ? JSON.parse(readFileSync(appdataPath, "utf8")) : { settings: {} };
        if (!ad.settings) ad.settings = {};
        ad.settings.dataVersion = dataVersion;
        writeFileSync(appdataPath, JSON.stringify(ad, null, 2));
      } catch { /* best-effort */ }
      const zipBuf = createBackupZip(profileRoot);
      const fileName = `${daysSinceEpoch}-${dataVersion}.web.venera`;

      await webDavRequest({
        config, path: fileName, method: "PUT",
        headers: {
          "Content-Type": "application/octet-stream",
          "Content-Length": String(zipBuf.length),
        },
        body: zipBuf,
        cookieJar, persistCookieJar, recordProxyRequest,
      });

      // Also upload as latest.venera for convenience
      await webDavRequest({
        config, path: "latest.venera", method: "PUT",
        headers: {
          "Content-Type": "application/octet-stream",
          "Content-Length": String(zipBuf.length),
        },
        body: zipBuf,
        cookieJar, persistCookieJar, recordProxyRequest,
      });

      // Keep only latest 10 backups per platform
      const toRemove = backupFilesToCleanup(existingFiles, 10);
      for (const name of toRemove) {
        try {
          await webDavRequest({
            config, path: name, method: "DELETE",
            cookieJar, persistCookieJar, recordProxyRequest,
          });
        } catch { /* best-effort */ }
      }

      console.log(`[auto-backup] Uploaded ${fileName} (${zipBuf.length} bytes)`);
      addSyncLog("auto-upload", fileName, true, null);
    } catch (e) {
      console.error("[auto-backup] Failed:", e.message || e);
      addSyncLog("auto-upload", null, false, e.message || String(e));
    }
  }

  return server;
}

async function waitForSidecar({ timeoutMs = 20000, intervalMs = 200 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`${SIDECAR_URL}/health`, { method: "GET" });
      if (r.ok) return true;
      lastError = `status ${r.status}`;
    } catch (e) {
      lastError = String(e && e.message ? e.message : e);
    }
    await new Promise((res) => setTimeout(res, intervalMs));
  }
  console.warn(
    `[web/server] venera-fetch sidecar at ${SIDECAR_URL} did not become healthy: ${lastError}`,
  );
  return false;
}

if (import.meta.url === `file://${process.argv[1]}` || import.meta.url === `file:///${process.argv[1]?.replace(/\\/g, '/')}`) {
  const port = Number(process.env.PORT || 8080);
  waitForSidecar()
    .catch(() => false)
    .finally(() => {
      createServer().listen(port, "0.0.0.0", () => {
        console.log(`Venera web helper listening on ${port}`);
      });
    });
}
