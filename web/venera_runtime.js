(function () {
  const nativeFetch = (globalThis.fetch || window.fetch).bind(globalThis);
  const nativeSetTimeout = globalThis.setTimeout.bind(globalThis);
  const state = {
    docs: new Map(),
    elements: new Map(),
    nodes: new Map(),
    dataStore: new Map(),
    settings: new Map(),
    cookies: new Map(),
    imageStore: new Map(),
    source: null,
    sourceClassName: null,
    nextDocId: 1,
    nextElementId: 1,
    nextNodeId: 1,
    nextImageId: 1,
  };
  const frameworkUrl =
    "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/_venera_.js";
  const cryptoJsUrl =
    "https://cdn.jsdelivr.net/npm/crypto-js@4.2.0/crypto-js.min.js";
  let cryptoJsReadyPromise = null;
  const forbiddenRequestHeaders = new Set([
    "accept-charset",
    "accept-encoding",
    "access-control-request-headers",
    "access-control-request-method",
    "connection",
    "content-length",
    "cookie",
    "date",
    "dnt",
    "expect",
    "host",
    "keep-alive",
    "origin",
    "permissions-policy",
    "proxy-",
    "referer",
    "sec-",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "user-agent",
    "via",
  ]);

  function toPlainHeaders(headers) {
    const out = {};
    headers.forEach((value, key) => {
      out[key] = value;
    });
    return out;
  }

  function utf8ToBuffer(text) {
    return new TextEncoder().encode(String(text)).buffer;
  }

  async function ensureCryptoJs() {
    if (window.CryptoJS) return;
    if (!cryptoJsReadyPromise) {
      cryptoJsReadyPromise = (async () => {
        const res = await nativeFetch(cryptoJsUrl);
        if (!res.ok) throw new Error(`加载 crypto-js 失败: ${res.status}`);
        const script = await res.text();
        const node = document.createElement("script");
        node.type = "text/javascript";
        node.text = script;
        document.head.appendChild(node);
        if (!window.CryptoJS) {
          throw new Error("crypto-js 初始化失败");
        }
      })();
    }
    await cryptoJsReadyPromise;
  }

  function arrayBufferToWordArray(buffer) {
    const bytes = new Uint8Array(buffer);
    const words = [];
    for (let i = 0; i < bytes.length; i++) {
      words[i >>> 2] = words[i >>> 2] || 0;
      words[i >>> 2] |= bytes[i] << (24 - (i % 4) * 8);
    }
    return window.CryptoJS.lib.WordArray.create(words, bytes.length);
  }

  function wordArrayToArrayBuffer(wordArray) {
    const sigBytes = wordArray.sigBytes || 0;
    const words = wordArray.words || [];
    const bytes = new Uint8Array(sigBytes);
    for (let i = 0; i < sigBytes; i++) {
      bytes[i] = (words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
    }
    return bytes.buffer;
  }

  function bufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function base64ToBuffer(base64Text) {
    const binary = atob(String(base64Text || ""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  function normalize(value, depth = 0) {
    if (depth > 8) return null;
    if (value == null) return null;
    if (Array.isArray(value)) return value.map((v) => normalize(v, depth + 1));
    if (value instanceof Map) {
      const out = {};
      for (const [k, v] of value.entries()) {
        out[String(k)] = normalize(v, depth + 1);
      }
      return out;
    }
    if (value instanceof Set) {
      return Array.from(value.values()).map((v) => normalize(v, depth + 1));
    }
    if (value instanceof Date) {
      return value.toISOString();
    }
    if (value instanceof ArrayBuffer) {
      return value;
    }
    if (typeof value === "object") {
      const out = {};
      for (const key of Object.keys(value)) {
        out[key] = normalize(value[key], depth + 1);
      }
      return out;
    }
    return value;
  }

  function parseHtml(htmlText) {
    const parser = new DOMParser();
    return parser.parseFromString(htmlText, "text/html");
  }

  function sanitizeHeaders(headers) {
    const out = {};
    const input = headers || {};
    for (const [rawKey, rawValue] of Object.entries(input)) {
      if (rawValue == null) continue;
      const key = String(rawKey);
      const lower = key.toLowerCase();
      if (forbiddenRequestHeaders.has(lower)) continue;
      if (Array.from(forbiddenRequestHeaders).some((p) => p.endsWith("-") && lower.startsWith(p))) {
        continue;
      }
      out[key] = Array.isArray(rawValue) ? rawValue.join(", ") : String(rawValue);
    }
    return out;
  }

  function getCookieBucket(urlText) {
    try {
      const url = new URL(String(urlText));
      return state.cookies.get(url.host) || new Map();
    } catch (_) {
      return new Map();
    }
  }

  function setCookiesForUrl(urlText, cookies) {
    try {
      const url = new URL(String(urlText));
      const host = url.host;
      const bucket = state.cookies.get(host) || new Map();
      for (const cookie of cookies || []) {
        if (!cookie || !cookie.name) continue;
        bucket.set(String(cookie.name), String(cookie.value ?? ""));
      }
      state.cookies.set(host, bucket);
      return true;
    } catch (_) {
      return false;
    }
  }

  function getCookiesForUrl(urlText) {
    const bucket = getCookieBucket(urlText);
    return Array.from(bucket.entries()).map(([name, value]) => ({ name, value }));
  }

  function deleteCookiesForUrl(urlText) {
    try {
      const url = new URL(String(urlText));
      state.cookies.delete(url.host);
      return true;
    } catch (_) {
      return false;
    }
  }

  function toCookieHeader(urlText) {
    const bucket = getCookieBucket(urlText);
    return Array.from(bucket.entries())
      .map(([name, value]) => `${name}=${value}`)
      .join("; ");
  }

  function parseSetCookieHeader(headerText) {
    if (!headerText) return [];
    const raw = Array.isArray(headerText)
      ? headerText.join(", ")
      : String(headerText);
    return raw
      .split(/,(?=\s*[^;,=\s]+=)/g)
      .map((entry) => {
        const firstPart = entry.split(";")[0];
        const eq = firstPart.indexOf("=");
        if (eq <= 0) return null;
        return {
          name: firstPart.slice(0, eq).trim(),
          value: firstPart.slice(eq + 1),
        };
      })
      .filter(Boolean);
  }

  function normalizeProxyUrl(value) {
    const raw = value == null ? "" : String(value).trim();
    if (!raw) return "";
    try {
      const url = new URL(raw, window.location.href);
      const segments = url.pathname.split("/").filter(Boolean);
      const last = segments[segments.length - 1] || "";
      if (last !== "proxy" && last !== "proxy.php") {
        url.pathname = `${url.pathname.replace(/\/$/, "")}/proxy`;
      }
      return url.toString();
    } catch (_) {
      return raw;
    }
  }

  function getDoc(docId) {
    return state.docs.get(Number(docId));
  }

  function getElement(docId, key) {
    return state.elements.get(`${docId}:${key}`);
  }

  function storeElement(docId, element) {
    const key = state.nextElementId++;
    state.elements.set(`${docId}:${key}`, element);
    return key;
  }

  function storeNode(docId, node) {
    const key = state.nextNodeId++;
    state.nodes.set(`${docId}:${key}`, node);
    return key;
  }

  async function convertMessage(message) {
    const type = message.type;
    const value = message.value;
    const isEncode = message.isEncode;
    if (type === "utf8") {
      if (isEncode) return new TextEncoder().encode(String(value)).buffer;
      return new TextDecoder().decode(new Uint8Array(value));
    }
    if (type === "gbk") {
      if (isEncode) {
        // Browser does not provide GBK encoder in TextEncoder.
        // Fallback to UTF-8 to keep scripts running when strict GBK encoding is not required.
        return utf8ToBuffer(String(value));
      }
      return new TextDecoder("gbk").decode(new Uint8Array(value));
    }
    if (type === "base64") {
      if (isEncode) {
        const bytes = new Uint8Array(value);
        let binary = "";
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        return btoa(binary);
      }
      const binary = atob(String(value));
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return bytes.buffer;
    }
    if (type === "md5" && isEncode) {
      await ensureCryptoJs();
      const digest = window.CryptoJS.MD5(arrayBufferToWordArray(value));
      return wordArrayToArrayBuffer(digest);
    }
    if (["sha1", "sha256", "sha512"].includes(type) && isEncode) {
      const digest = await crypto.subtle.digest(type.toUpperCase().replace("SHA", "SHA-"), value);
      return digest;
    }
    if (type === "hmac" && isEncode) {
      const hash = String(message.hash || "sha256").toUpperCase().replace("SHA", "SHA-");
      if (hash === "MD5") {
        await ensureCryptoJs();
        const signed = window.CryptoJS.HmacMD5(
          arrayBufferToWordArray(value),
          arrayBufferToWordArray(message.key),
        );
        if (message.isString) {
          return signed.toString(window.CryptoJS.enc.Hex);
        }
        return wordArrayToArrayBuffer(signed);
      }
      const key = await crypto.subtle.importKey(
        "raw",
        message.key,
        { name: "HMAC", hash: { name: hash } },
        false,
        ["sign"],
      );
      const signed = await crypto.subtle.sign("HMAC", key, value);
      if (message.isString) {
        const bytes = new Uint8Array(signed);
        return Array.from(bytes)
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("");
      }
      return signed;
    }
    if (type === "aes-cbc") {
      const key = await crypto.subtle.importKey(
        "raw",
        message.key,
        { name: "AES-CBC" },
        false,
        [isEncode ? "encrypt" : "decrypt"],
      );
      const iv = message.iv;
      if (!iv) throw new Error("aes-cbc missing iv");
      if (isEncode) {
        return await crypto.subtle.encrypt({ name: "AES-CBC", iv }, key, value);
      }
      return await crypto.subtle.decrypt({ name: "AES-CBC", iv }, key, value);
    }
    if (["aes-ecb", "aes-cfb", "aes-ofb"].includes(type)) {
      await ensureCryptoJs();
      const cryptoJs = window.CryptoJS;
      const keyWord = arrayBufferToWordArray(message.key);
      const dataWord = arrayBufferToWordArray(value);
      const modeMap = {
        "aes-ecb": cryptoJs.mode.ECB,
        "aes-cfb": cryptoJs.mode.CFB,
        "aes-ofb": cryptoJs.mode.OFB,
      };
      const options = {
        mode: modeMap[type],
        padding: cryptoJs.pad.Pkcs7,
      };
      if (type !== "aes-ecb") {
        if (!message.iv) {
          throw new Error(`${type} missing iv`);
        }
        options.iv = arrayBufferToWordArray(message.iv);
      }
      if (isEncode) {
        const encrypted = cryptoJs.AES.encrypt(dataWord, keyWord, options);
        return wordArrayToArrayBuffer(encrypted.ciphertext);
      }
      const decrypted = cryptoJs.AES.decrypt({ ciphertext: dataWord }, keyWord, options);
      return wordArrayToArrayBuffer(decrypted);
    }
    throw new Error(`convert ${type} 暂未支持`);
  }

  async function doHttpDirect(message) {
    const method = String(message.http_method || "GET").toUpperCase();
    const headers = sanitizeHeaders(message.headers || {});
    const cookieHeader = toCookieHeader(message.url);
    if (cookieHeader && !headers.Cookie && !headers.cookie) {
      headers.Cookie = cookieHeader;
    }
    const hasBody = !["GET", "HEAD"].includes(method);
    const init = {
      method,
      headers,
      body: !hasBody
        ? undefined
        : message.data == null
          ? undefined
          : typeof message.data === "string" || message.data instanceof ArrayBuffer
            ? message.data
            : JSON.stringify(message.data),
      credentials: "omit",
      mode: "cors",
    };
    const response = await nativeFetch(message.url, init);
    const body = message.bytes ? await response.arrayBuffer() : await response.text();
    return {
      status: response.status,
      headers: toPlainHeaders(response.headers),
      body,
    };
  }

  async function doHttpByProxy(message) {
    const proxyUrl = normalizeProxyUrl(
      state.settings.get("proxy_url") || state.settings.get("corsProxy"),
    );
    if (!proxyUrl) throw new Error("proxy_url not configured");
    const headers = sanitizeHeaders(message.headers || {});
    const cookieHeader = toCookieHeader(message.url);
    if (cookieHeader && !headers.Cookie && !headers.cookie) {
      headers.Cookie = cookieHeader;
    }
    const payload = {
      url: message.url,
      method: message.http_method || "GET",
      headers,
      bytes: !!message.bytes,
      data:
        message.data == null
          ? null
          : message.data instanceof ArrayBuffer
            ? { type: "base64", value: bufferToBase64(message.data) }
            : message.data,
    };
    const proxyHeaders = {
      "content-type": "application/json",
    };
    const proxyAuth = state.settings.get("proxy_auth");
    if (proxyAuth) {
      proxyHeaders.authorization = String(proxyAuth);
    }
    const proxyRes = await nativeFetch(String(proxyUrl), {
      method: "POST",
      headers: proxyHeaders,
      body: JSON.stringify(payload),
      mode: "cors",
      credentials: "omit",
    });
    if (!proxyRes.ok) {
      throw new Error(`proxy status ${proxyRes.status}`);
    }
    const json = await proxyRes.json();
    const status = Number(json.status || 0);
    const responseHeaders = json.headers || {};
    const setCookie =
      responseHeaders["set-cookie"] || responseHeaders["Set-Cookie"];
    const cookies = parseSetCookieHeader(setCookie);
    if (cookies.length > 0) {
      setCookiesForUrl(message.url, cookies);
    }
    if (message.bytes) {
      const bodyBase64 = json.bodyBase64 || "";
      return {
        status,
        headers: responseHeaders,
        body: base64ToBuffer(bodyBase64),
      };
    }
    return {
      status,
      headers: responseHeaders,
      body: json.body == null ? "" : String(json.body),
    };
  }

  function sendMessage(message) {
    const method = message.method;
    if (method === "delay") {
      return new Promise((resolve) =>
        nativeSetTimeout(resolve, Number(message.time || 0)),
      );
    }
    if (method === "uuid") {
      if (crypto && crypto.randomUUID) return crypto.randomUUID();
      return `uuid-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    }
    if (method === "random") {
      const min = Number(message.min || 0);
      const max = Number(message.max || 1);
      if (message.type === "int") {
        return Math.floor(Math.random() * (max - min + 1)) + min;
      }
      return Math.random() * (max - min) + min;
    }
    if (method === "log") {
      console.log("[source]", message.content);
      return null;
    }
    if (method === "getLocale") {
      return navigator.language || "en-US";
    }
    if (method === "getPlatform") {
      return "web";
    }
    if (method === "setClipboard") {
      if (navigator.clipboard?.writeText) {
        return navigator.clipboard.writeText(String(message.text ?? message.value ?? ""));
      }
      return Promise.resolve(null);
    }
    if (method === "getClipboard") {
      if (navigator.clipboard?.readText) {
        return navigator.clipboard.readText();
      }
      return Promise.resolve("");
    }
    if (method === "load_data") {
      const sourceKey = String(message.key || "");
      const dataKey = String(message.data_key || "");
      return state.dataStore.get(`${sourceKey}:${dataKey}`) ?? null;
    }
    if (method === "save_data") {
      const sourceKey = String(message.key || "");
      const dataKey = String(message.data_key || "");
      state.dataStore.set(`${sourceKey}:${dataKey}`, message.data);
      return null;
    }
    if (method === "delete_data") {
      const sourceKey = String(message.key || "");
      const dataKey = String(message.data_key || "");
      state.dataStore.delete(`${sourceKey}:${dataKey}`);
      return null;
    }
    if (method === "load_setting") {
      const settingKey = String(message.setting_key || message.key || "");
      return state.settings.get(settingKey) ?? null;
    }
    if (method === "isLogged") {
      const sourceKey = String(message.key || "");
      return !!state.dataStore.get(`${sourceKey}:token`);
    }
    if (method === "UI") {
      const fn = message.function;
      if (fn === "showMessage") {
        console.log("[UI]", message.message);
        return null;
      }
      if (fn === "showDialog") {
        const ok = confirm(`${message.title || "提示"}\n\n${message.content || ""}`);
        if (ok && Array.isArray(message.actions) && message.actions.length > 1) {
          const action = message.actions[1];
          if (typeof action.callback === "function") action.callback();
        }
        return null;
      }
      if (fn === "launchUrl") {
        window.open(String(message.url || ""), "_blank", "noopener,noreferrer");
        return null;
      }
      if (fn === "showInputDialog") {
        return prompt(String(message.title || "Input"), String(message.defaultValue || "")) || null;
      }
      if (fn === "showSelectDialog") {
        const options = Array.isArray(message.options) ? message.options.join("\n") : "";
        return prompt(`Select one:\n${options}`, "") || null;
      }
      return null;
    }
    if (method === "cookie") {
      const fn = String(message.function || "");
      const url = message.url || "";
      if (fn === "set") {
        setCookiesForUrl(url, message.cookies || []);
        return null;
      }
      if (fn === "get") {
        return getCookiesForUrl(url);
      }
      if (fn === "delete") {
        deleteCookiesForUrl(url);
        return null;
      }
      return [];
    }
    if (method === "convert") {
      return convertMessage(message);
    }
    if (method === "http") {
      return (async () => {
        let directError = null;
        try {
          return await doHttpDirect(message);
        } catch (err) {
          directError = err;
          try {
            return await doHttpByProxy(message);
          } catch (proxyErr) {
            const directText =
              directError && directError.message
                ? directError.message
                : String(directError || "unknown");
            const proxyText =
              proxyErr && proxyErr.message ? proxyErr.message : String(proxyErr || "unknown");
            return {
              error: `http failed (direct: ${directText}; proxy: ${proxyText})`,
            };
          }
        }
      })();
    }
    if (method === "html") {
      const fn = message.function;
      const docId = Number(message.key || message.doc || 0);
      if (fn === "parse") {
        state.docs.set(docId, parseHtml(String(message.data || "")));
        return null;
      }
      if (fn === "dispose") {
        state.docs.delete(docId);
        return null;
      }
      const doc = getDoc(Number(message.doc || message.key));
      if (!doc) return null;
      if (fn === "querySelector") {
        const el = doc.querySelector(message.query);
        return el ? storeElement(docId, el) : null;
      }
      if (fn === "querySelectorAll") {
        return Array.from(doc.querySelectorAll(message.query)).map((el) => storeElement(docId, el));
      }
      if (fn === "getElementById") {
        const el = doc.getElementById(message.id);
        return el ? storeElement(docId, el) : null;
      }
      const element = getElement(docId, Number(message.key));
      if (!element) return null;
      if (fn === "getText") return element.textContent || "";
      if (fn === "getAttributes") {
        const attrs = {};
        for (const attr of element.attributes || []) {
          attrs[attr.name] = attr.value;
        }
        return attrs;
      }
      if (fn === "dom_querySelector") {
        const el = element.querySelector(message.query);
        return el ? storeElement(docId, el) : null;
      }
      if (fn === "dom_querySelectorAll") {
        return Array.from(element.querySelectorAll(message.query)).map((el) => storeElement(docId, el));
      }
      if (fn === "getChildren") {
        return Array.from(element.children).map((el) => storeElement(docId, el));
      }
      if (fn === "getNodes") {
        return Array.from(element.childNodes).map((n) => storeNode(docId, n));
      }
      if (fn === "getInnerHTML") return element.innerHTML || "";
      if (fn === "getParent") {
        const parent = element.parentElement;
        return parent ? storeElement(docId, parent) : null;
      }
      if (fn === "getClassNames") return Array.from(element.classList.values());
      if (fn === "getId") return element.id || null;
      if (fn === "getLocalName") return element.localName || null;
      if (fn === "getPreviousSibling") {
        const prev = element.previousElementSibling;
        return prev ? storeElement(docId, prev) : null;
      }
      if (fn === "getNextSibling") {
        const next = element.nextElementSibling;
        return next ? storeElement(docId, next) : null;
      }
      const node = state.nodes.get(`${docId}:${Number(message.key)}`);
      if (!node) return null;
      if (fn === "node_text") return node.textContent || "";
      if (fn === "node_type") {
        if (node.nodeType === 1) return "element";
        if (node.nodeType === 3) return "text";
        if (node.nodeType === 8) return "comment";
        if (node.nodeType === 9) return "document";
        return "unknown";
      }
      if (fn === "node_toElement") {
        if (node.nodeType === 1) return storeElement(docId, node);
        return null;
      }
      return null;
    }
    if (method === "image") {
      return null;
    }
    if (method === "compute") {
      const fn = message.function;
      if (typeof fn === "function") {
        return Promise.resolve(fn(...(message.args || message.params || [])));
      }
      return null;
    }
    return null;
  }

  async function ensureFramework() {
    if (window.__veneraFrameworkLoaded) return;
    const response = await nativeFetch(frameworkUrl);
    if (!response.ok) throw new Error(`加载框架失败: ${response.status}`);
    const script = await response.text();
    window.appVersion = window.appVersion || "web-0.1.0";
    window.__veneraNativeFetch = nativeFetch;
    window.sendMessage = sendMessage;
    const node = document.createElement("script");
    node.type = "text/javascript";
    node.text = script;
    document.head.appendChild(node);
    window.__veneraFrameworkLoaded = true;
  }

  async function loadSource(sourceScript, className, settings) {
    await ensureFramework();
    state.settings = new Map(Object.entries(settings || {}));
    window.sendMessage = sendMessage;
    const ctor = new Function(
      `${sourceScript}\nreturn (typeof ${className} !== 'undefined') ? ${className} : null;`,
    )();
    if (!ctor) throw new Error(`source class not found: ${className}`);
    const instance = new ctor();
    if (typeof instance.init === "function") {
      await instance.init();
    }
    state.source = instance;
    state.sourceClassName = className;
    return normalize({
      name: instance.name,
      key: instance.key,
      version: instance.version,
      minAppVersion: instance.minAppVersion || "",
      hasExplore: Array.isArray(instance.explore),
      hasCategory: !!instance.category,
      hasSearch: !!instance.search,
      hasComic: !!instance.comic,
      explore: Array.isArray(instance.explore)
        ? instance.explore.map((item, index) => ({
            index,
            title: item?.title || `Explore ${index + 1}`,
            type: item?.type || "",
          }))
        : [],
      category: instance.category || null,
      categoryComics: instance.categoryComics || null,
      settings: instance.settings || null,
    });
  }

  function getSource() {
    if (!state.source) throw new Error("source not loaded");
    return state.source;
  }

  async function runSearch(keyword, page, options) {
    const source = getSource();
    if (!source.search) throw new Error("source.search 不存在");
    let result;
    if (typeof source.search.loadNext === "function") {
      result = await source.search.loadNext(keyword, options || [], null);
    } else if (typeof source.search.load === "function") {
      result = await source.search.load(keyword, options || [], page || 1);
    } else {
      throw new Error("search.load / search.loadNext 不存在");
    }
    return normalize(result);
  }

  async function runLoadInfo(comicId) {
    const source = getSource();
    if (!source.comic || typeof source.comic.loadInfo !== "function") {
      throw new Error("comic.loadInfo 不存在");
    }
    const result = await source.comic.loadInfo(comicId);
    return normalize(result);
  }

  async function runLoadEp(comicId, epId) {
    const source = getSource();
    if (!source.comic || typeof source.comic.loadEp !== "function") {
      throw new Error("comic.loadEp 不存在");
    }
    const result = await source.comic.loadEp(comicId, epId);
    return normalize(result);
  }

  async function runExplore(index, page) {
    const source = getSource();
    if (!Array.isArray(source.explore)) {
      throw new Error("source.explore 不存在");
    }
    const i = Number(index || 0);
    const target = source.explore[i];
    if (!target || typeof target.load !== "function") {
      throw new Error(`explore[${i}] 不可用`);
    }
    const result = await target.load(Number(page || 1));
    return normalize(result);
  }

  async function runCategory(category, param, options, page) {
    const source = getSource();
    if (!source.categoryComics || typeof source.categoryComics.load !== "function") {
      throw new Error("source.categoryComics.load 不存在");
    }
    const result = await source.categoryComics.load(
      category,
      param,
      options || [],
      Number(page || 1),
    );
    return normalize(result);
  }

  async function resolveImageConfig(url, comicId, epId) {
    const source = getSource();
    const raw = String(url || "");
    if (
      source.comic &&
      typeof source.comic.onImageLoad === "function"
    ) {
      const config = await source.comic.onImageLoad(raw, comicId, epId);
      if (config && typeof config === "object") {
        return normalize({
          url: config.url || raw,
          method: config.method || "GET",
          headers: config.headers || {},
          hasOnResponse: typeof config.onResponse === "function",
          hasModifyImage: typeof config.modifyImage === "string",
        });
      }
    }
    return { url: raw, method: "GET", headers: {} };
  }

  async function runResolveImageConfigs(comicId, epId, images) {
    const list = Array.isArray(images) ? images : [];
    const out = [];
    for (const item of list) {
      out.push(await resolveImageConfig(String(item || ""), comicId, epId));
    }
    return normalize(out);
  }

  function getRuntimeState() {
    return normalize({
      sourceClassName: state.sourceClassName,
      settings: Object.fromEntries(state.settings.entries()),
      cookieHosts: Array.from(state.cookies.keys()),
      dataKeys: Array.from(state.dataStore.keys()),
    });
  }

  window.veneraRuntime = {
    loadSource,
    runSearch,
    runLoadInfo,
    runLoadEp,
    runExplore,
    runCategory,
    runResolveImageConfigs,
    getRuntimeState,
    nativeFetch: (...args) => nativeFetch(...args),
  };
})();
