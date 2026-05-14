import { createHash, randomUUID } from "node:crypto";
import { inflateRawSync } from "node:zlib";
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
      `Playwright unavailable. Run npm install in web_helper or use the Docker helper image. ${error.message}`,
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

function sortBackupFiles(files, newestFirst = true) {
  return [...files].sort((a, b) =>
    newestFirst
      ? backupTimestamp(b) - backupTimestamp(a)
      : backupTimestamp(a) - backupTimestamp(b),
  );
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

const serverDbBackupEntryNames = [...serverDbEntryNames, "appdata.json"];

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
    mkdirSync(profileRoot, { recursive: true });
    writeFileSync(join(profileRoot, "appdata.json"), appdata);
  }
  return {
    writtenDatabases,
    writtenAppdata: !!appdata,
  };
}

function historyRowsFromServerDb(profileRoot, { limit = 100, offset = 0 } = {}) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  if (!existsSync(filePath)) {
    throw createHttpError(404, "Server history DB not found");
  }
  const data = extractSqliteData(readFileSync(filePath));
  const table = data.tables.find((item) => item.name === "history");
  if (!table) {
    return { total: 0, items: [] };
  }
  const rows = table.rows.map((row) => {
    const item = {};
    for (let index = 0; index < table.columns.length; index++) {
      item[table.columns[index]] = row[index];
    }
    const readEpisode = String(item.readEpisode || "")
      .split(",")
      .filter(Boolean);
    return {
      id: String(item.id || ""),
      title: String(item.title || ""),
      subtitle: String(item.subtitle || ""),
      cover: String(item.cover || ""),
      time: Number(item.time || 0),
      type: Number(item.type || 0),
      ep: Number(item.ep || 0),
      page: Number(item.page || 0),
      readEpisode,
      max_page: item.max_page == null ? null : Number(item.max_page),
      chapter_group: item.chapter_group == null ? null : Number(item.chapter_group),
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
    ep: nullableNumber(history.ep) || 0,
    page: nullableNumber(history.page) || 0,
    readEpisode,
    maxPage: nullableNumber(history.max_page),
    chapterGroup: nullableNumber(history.chapter_group),
  };
}

async function withWritableHistoryDb(profileRoot, callback) {
  const filePath = serverDbEntryPath(profileRoot, "history.db");
  const db = await openWritableSqliteDatabase(filePath);
  try {
    ensureHistoryDbSchema(db);
    return callback(db);
  } finally {
    db.close();
  }
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

  if (parsedUrl.pathname === "/api/server-db/appdata") {
    const appdataPath = join(profileRoot, "appdata.json");
    if (!existsSync(appdataPath)) {
      throw createHttpError(404, "Server appdata not found");
    }
    let data;
    try {
      data = JSON.parse(readFileSync(appdataPath, "utf8"));
    } catch {
      throw createHttpError(422, "Server appdata is invalid JSON");
    }
    sendJson(res, 200, {
      ok: true,
      profile: profileId,
      data,
    });
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

    const entries = extractZipEntries(downloaded.buffer, (name) =>
      serverDbBackupEntryNames.includes(name),
    );
    const written = writeServerDbBackup(profileRoot, entries);
    if (written.writtenDatabases === 0 && !written.writtenAppdata) {
      throw createHttpError(422, "Backup does not contain supported app data");
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

  const config = resolveWebDavConfig(payload, webDavConfigPath);

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
  if (!existsSync(filePath) || statSync(filePath).isDirectory()) return false;
  const contentType = staticContentTypes[extname(filePath).toLowerCase()];
  if (contentType) res.setHeader("Content-Type", contentType);
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
    `[web_helper] venera-fetch sidecar at ${SIDECAR_URL} did not become healthy: ${lastError}`,
  );
  return false;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT || 8080);
  waitForSidecar()
    .catch(() => false)
    .finally(() => {
      createServer().listen(port, "0.0.0.0", () => {
        console.log(`Venera web helper listening on ${port}`);
      });
    });
}
