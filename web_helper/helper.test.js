import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { createHash, randomBytes } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { deflateRawSync, gzipSync } from "node:zlib";

import { createServer } from "./server.js";

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function encodeSqliteVarint(value) {
  let n = BigInt(value);
  if (n < 0n) {
    throw new RangeError("SQLite varint cannot encode negative values");
  }
  const bytes = [];
  do {
    bytes.unshift(Number(n & 0x7fn));
    n >>= 7n;
  } while (n > 0n);
  for (let i = 0; i < bytes.length - 1; i++) {
    bytes[i] |= 0x80;
  }
  return Buffer.from(bytes);
}

function encodeSignedInt(value, size) {
  const buf = Buffer.alloc(size);
  if (size === 1) buf.writeInt8(value);
  else if (size === 2) buf.writeInt16BE(value);
  else if (size === 3) {
    let n = value < 0 ? 0x1000000 + value : value;
    buf[0] = (n >> 16) & 0xff;
    buf[1] = (n >> 8) & 0xff;
    buf[2] = n & 0xff;
  } else if (size === 4) buf.writeInt32BE(value);
  else if (size === 6) {
    let n = BigInt(value);
    if (n < 0n) n = (1n << 48n) + n;
    const hi = Number((n >> 16n) & 0xffffffffn);
    const lo = Number(n & 0xffffn);
    buf.writeUInt32BE(hi, 0);
    buf.writeUInt16BE(lo, 4);
  } else if (size === 8) {
    buf.writeBigInt64BE(BigInt(value));
  } else {
    throw new RangeError(`Unsupported integer size: ${size}`);
  }
  return buf;
}

function sqliteTextField(value) {
  const data = Buffer.from(value, "utf8");
  return { serialType: 13 + data.length * 2, data };
}

function sqliteIntField(value) {
  if (value === 0) return { serialType: 8, data: Buffer.alloc(0) };
  if (value === 1) return { serialType: 9, data: Buffer.alloc(0) };
  if (value >= -128 && value <= 127) {
    return { serialType: 1, data: encodeSignedInt(value, 1) };
  }
  if (value >= -32768 && value <= 32767) {
    return { serialType: 2, data: encodeSignedInt(value, 2) };
  }
  if (value >= -8388608 && value <= 8388607) {
    return { serialType: 3, data: encodeSignedInt(value, 3) };
  }
  if (value >= -2147483648 && value <= 2147483647) {
    return { serialType: 4, data: encodeSignedInt(value, 4) };
  }
  return { serialType: 6, data: encodeSignedInt(value, 8) };
}

function encodeSqliteRecord(fields) {
  const serialBuffers = fields.map((field) => encodeSqliteVarint(field.serialType));
  let headerSize = 0;
  while (true) {
    const headerSizeBuf = encodeSqliteVarint(headerSize);
    const nextSize =
      headerSizeBuf.length + serialBuffers.reduce((sum, buf) => sum + buf.length, 0);
    if (nextSize === headerSize) {
      return Buffer.concat([
        headerSizeBuf,
        ...serialBuffers,
        ...fields.map((field) => field.data),
      ]);
    }
    headerSize = nextSize;
  }
}

function encodeTableCell(rowId, fields) {
  const payload = encodeSqliteRecord(fields);
  return Buffer.concat([
    encodeSqliteVarint(payload.length),
    encodeSqliteVarint(rowId),
    payload,
  ]);
}

function buildLeafPage({
  pageSize,
  cells,
  pageType = 0x0d,
  rightMostChild = 0,
  isPage1 = false,
}) {
  const page = Buffer.alloc(pageSize);
  const headerOffset = isPage1 ? 100 : 0;
  page[headerOffset] = pageType;
  page.writeUInt16BE(0, headerOffset + 1);
  page.writeUInt16BE(cells.length, headerOffset + 3);
  let contentOffset = pageSize;
  const pointers = [];
  for (const cell of cells) {
    contentOffset -= cell.length;
    cell.copy(page, contentOffset);
    pointers.push(contentOffset);
  }
  page.writeUInt16BE(contentOffset, headerOffset + 5);
  page[headerOffset + 7] = 0;
  if (pageType === 0x05) {
    page.writeUInt32BE(rightMostChild, headerOffset + 8);
    for (let i = 0; i < pointers.length; i++) {
      page.writeUInt16BE(pointers[i], headerOffset + 12 + i * 2);
    }
  } else {
    for (let i = 0; i < pointers.length; i++) {
      page.writeUInt16BE(pointers[i], headerOffset + 8 + i * 2);
    }
  }
  return page;
}

function buildZipArchive(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;

  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, "utf8");
    const uncompressed = entry.data;
    const compression = entry.compression ?? 8;
    const compressed = compression === 0 ? uncompressed : deflateRawSync(uncompressed);

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(compression, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0, 12);
    localHeader.writeUInt32LE(0, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(uncompressed.length, 22);
    localHeader.writeUInt16LE(nameBytes.length, 26);
    localHeader.writeUInt16LE(0, 28);

    localParts.push(localHeader, nameBytes, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 8);
    centralHeader.writeUInt16LE(compression, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0, 14);
    centralHeader.writeUInt32LE(0, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(uncompressed.length, 24);
    centralHeader.writeUInt16LE(nameBytes.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(0, 38);
    centralHeader.writeUInt32LE(localOffset, 42);

    centralParts.push(centralHeader, nameBytes);
    localOffset += localHeader.length + nameBytes.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralDirectory.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...localParts, centralDirectory, eocd]);
}

function buildMinimalHistoryDb(title) {
  const pageSize = 512;
  const db = Buffer.alloc(pageSize * 2);

  db.write("SQLite format 3\0", 0, "ascii");
  db.writeUInt16BE(pageSize, 16);
  db[18] = 1;
  db[19] = 1;
  db[20] = 0;
  db[21] = 64;
  db[22] = 32;
  db[23] = 32;
  db.writeUInt32BE(2, 28);
  db.writeUInt32BE(4, 44);
  db.writeUInt32BE(1, 56);

  const schemaSql = "CREATE TABLE history (id, title)";
  const schemaCell = encodeTableCell(1, [
    sqliteTextField("table"),
    sqliteTextField("history"),
    sqliteTextField("history"),
    sqliteIntField(2),
    sqliteTextField(schemaSql),
  ]);
  buildLeafPage({
    pageSize,
    cells: [schemaCell],
    isPage1: true,
  }).copy(db, 100, 100);

  const dataCell = encodeTableCell(1, [sqliteIntField(1), sqliteTextField(title)]);
  buildLeafPage({
    pageSize,
    cells: [dataCell],
  }).copy(db, pageSize);

  return db;
}

function websocketPath(urlText) {
  const url = new URL(urlText);
  return `${url.pathname}${url.search}`;
}

function readWebSocketTextFrame(socket) {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("Timed out waiting for websocket frame"));
    }, 2000);
    function cleanup() {
      clearTimeout(timeout);
      socket.off("data", onData);
      socket.off("error", onError);
    }
    function onError(error) {
      cleanup();
      reject(error);
    }
    function onData(chunk) {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 2) return;
      const first = buffer[0];
      const second = buffer[1];
      let offset = 2;
      let length = second & 0x7f;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const masked = (second & 0x80) !== 0;
      const maskLength = masked ? 4 : 0;
      if (buffer.length < offset + maskLength + length) return;
      const mask = masked ? buffer.subarray(offset, offset + 4) : null;
      offset += maskLength;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (mask) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      }
      cleanup();
      assert.equal(first & 0x0f, 1);
      resolve(payload.toString());
    }
    socket.on("data", onData);
    socket.on("error", onError);
  });
}

function connectWebSocket(urlText) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlText);
    const key = randomBytes(16).toString("base64");
    const expectedAccept = createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    const socket = createConnection(Number(url.port), url.hostname);
    let response = Buffer.alloc(0);
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Timed out waiting for websocket handshake"));
    }, 2000);
    socket.on("connect", () => {
      socket.write(
        [
          `GET ${websocketPath(url)} HTTP/1.1`,
          `Host: ${url.host}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Key: ${key}`,
          "Sec-WebSocket-Version: 13",
          "",
          "",
        ].join("\r\n"),
      );
    });
    socket.on("data", (chunk) => {
      response = Buffer.concat([response, chunk]);
      const headerEnd = response.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      clearTimeout(timeout);
      const headers = response.subarray(0, headerEnd).toString();
      if (!headers.startsWith("HTTP/1.1 101")) {
        socket.destroy();
        reject(new Error(`Unexpected websocket response: ${headers}`));
        return;
      }
      const acceptHeader = headers
        .split("\r\n")
        .find((line) => line.toLowerCase().startsWith("sec-websocket-accept:"));
      assert.equal(acceptHeader, `Sec-WebSocket-Accept: ${expectedAccept}`);
      socket.removeAllListeners("data");
      const rest = response.subarray(headerEnd + 4);
      if (rest.length > 0) socket.unshift(rest);
      resolve(socket);
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

function closeClientWebSocket(socket) {
  return new Promise((resolve) => {
    if (socket.destroyed) {
      resolve();
      return;
    }
    socket.once("close", resolve);
    socket.end(Buffer.from([0x88, 0x00]));
    setTimeout(() => {
      if (!socket.destroyed) socket.destroy();
      resolve();
    }, 500).unref();
  });
}

test("extract-db route decodes sqlite rows from zipped database entries", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  const longTitle = "A".repeat(80);
  const zipBytes = buildZipArchive([
    {
      name: "history.db",
      data: buildMinimalHistoryDb(longTitle),
    },
  ]);

  try {
    const response = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: zipBytes.toString("base64") }),
    });

    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.ok, true);
    assert.equal(payload.databases["history.db"].ok, true);
    assert.deepEqual(payload.databases["history.db"].tables, [
      {
        name: "history",
        sql: "CREATE TABLE history (id, title)",
        columns: ["id", "title"],
        rows: [[1, longTitle]],
      },
    ]);
    assert.deepEqual(payload.databases["history.db"].indexes, []);
  } finally {
    await close(helper);
  }
});

test("query mode forwards WebDAV methods and request body", async () => {
  const upstream = createHttpServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);

    assert.equal(req.method, "PROPFIND");
    assert.equal(req.headers.authorization, "Basic token");
    assert.equal(req.headers.depth, "1");
    assert.equal(Buffer.concat(chunks).toString(), "<propfind />");

    res.writeHead(207, { "Content-Type": "application/xml" });
    res.end("<multistatus />");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(
      `${helperUrl}/proxy?url=${encodeURIComponent(`${upstreamUrl}/dav/`)}`,
      {
        method: "PROPFIND",
        headers: {
          Authorization: "Basic token",
          Depth: "1",
          "Content-Type": "application/xml",
        },
        body: "<propfind />",
      },
    );

    assert.equal(response.status, 207);
    assert.equal(await response.text(), "<multistatus />");
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("proxy.php query route is handled by the helper instead of static files", async () => {
  const upstream = createHttpServer((req, res) => {
    assert.equal(req.method, "GET");
    res.writeHead(200, { "Content-Type": "image/png" });
    res.end(Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(
      `${helperUrl}/proxy.php?url=${encodeURIComponent(`${upstreamUrl}/image`)}`,
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.deepEqual(
      Array.from(new Uint8Array(await response.arrayBuffer())),
      [0x89, 0x50, 0x4e, 0x47],
    );
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("CORS preflight echoes requested source proxy headers", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/proxy?url=https%3A%2F%2Fexample.com`, {
      method: "OPTIONS",
      headers: {
        "Access-Control-Request-Headers":
          "x-venera-forward-headers, x-venera-user-agent, x-copy-platform",
      },
    });

    assert.equal(response.status, 204);
    assert.equal(
      response.headers.get("access-control-allow-headers"),
      "x-venera-forward-headers, x-venera-user-agent, x-copy-platform",
    );
  } finally {
    await close(helper);
  }
});

test("query proxy rewrites content-length after upstream decompression", async () => {
  const body = JSON.stringify({
    message: "ok",
    payload: "repeat:".repeat(200),
  });
  const compressed = gzipSync(body);
  const upstream = createHttpServer((req, res) => {
    assert.equal(req.method, "GET");
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Content-Encoding": "gzip",
      "Content-Length": String(compressed.length),
    });
    res.end(compressed);
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(
      `${helperUrl}/proxy?url=${encodeURIComponent(`${upstreamUrl}/json`)}`,
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-encoding"), null);
    assert.equal(
      response.headers.get("content-length"),
      String(Buffer.byteLength(body)),
    );
    assert.deepEqual(await response.json(), JSON.parse(body));
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("static font files are served with browser-compatible content types", async () => {
  const staticDir = await mkdtemp(join(tmpdir(), "venera-static-"));
  const fontPath = join(staticDir, "MaterialIcons-Regular.otf");
  await writeFile(fontPath, Buffer.from([0, 1, 2, 3]));
  const helper = createServer({ staticDir });
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/MaterialIcons-Regular.otf`);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "font/otf");
    await response.arrayBuffer();
  } finally {
    await close(helper);
    await rm(staticDir, { recursive: true, force: true });
  }
});

test("static fallback serves Flutter Web index for app routes", async () => {
  const staticDir = await mkdtemp(join(tmpdir(), "venera-static-"));
  await writeFile(join(staticDir, "index.html"), "<!doctype html><title>Venera</title>");
  const helper = createServer({ staticDir });
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/reader/comic/demo`);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "text/html; charset=utf-8");
    assert.equal(await response.text(), "<!doctype html><title>Venera</title>");
  } finally {
    await close(helper);
    await rm(staticDir, { recursive: true, force: true });
  }
});

test("json mode forwards base64 body and returns binary response", async () => {
  const upstream = createHttpServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);

    assert.equal(req.method, "PUT");
    assert.equal(req.headers.authorization, "Basic token");
    assert.equal(req.headers["content-type"], "application/octet-stream");
    assert.deepEqual(Buffer.concat(chunks), Buffer.from([1, 2, 3, 4]));

    res.writeHead(201, {
      "Content-Type": "application/octet-stream",
      "Set-Cookie": "sid=abc; Path=/",
    });
    res.end(Buffer.from([0, 255, 1]));
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: `${upstreamUrl}/latest.venera`,
        method: "PUT",
        bytes: true,
        headers: {
          Authorization: "Basic token",
          "Content-Type": "application/octet-stream",
        },
        data: {
          type: "base64",
          value: Buffer.from([1, 2, 3, 4]).toString("base64"),
        },
      }),
    });

    assert.equal(response.status, 200);
    const json = await response.json();
    assert.equal(json.status, 201);
    assert.equal(json.headers["content-type"], "application/octet-stream");
    assert.equal(json.headers["set-cookie"], "sid=abc; Path=/");
    assert.equal(json.body, null);
    assert.equal(json.bodyBase64, Buffer.from([0, 255, 1]).toString("base64"));
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("sync WebDAV upload stores only the requested backup file", async () => {
  const uploaded = new Map();
  const seenRequests = [];
  const backupBytes = buildZipArchive([
    { name: "appdata.json", data: Buffer.from("{}"), compression: 0 },
  ]);

  const upstream = createHttpServer(async (req, res) => {
    seenRequests.push(`${req.method} ${req.url}`);

    if (req.method === "HEAD" && req.url === "/latest.venera") {
      res.writeHead(500);
      res.end("unexpected latest read");
      return;
    }

    if (req.method === "PUT") {
      assert.equal(req.url, "/1700000000000.venera");
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      uploaded.set(req.url, Buffer.concat(chunks));
      res.writeHead(201);
      res.end();
      return;
    }

    if (req.method === "PROPFIND") {
      res.writeHead(207, { "Content-Type": "application/xml" });
      res.end(`<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/1700000000000.venera</d:href></d:response>
  <d:response><d:href>/latest.venera</d:href></d:response>
</d:multistatus>`);
      return;
    }

    res.writeHead(404);
    res.end();
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/sync/webdav/upload`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        user: "user",
        pass: "pass",
        fileName: "1700000000000.venera",
        dataBase64: backupBytes.toString("base64"),
      }),
    });

    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.ok, true);
    assert.deepEqual(uploaded.get("/1700000000000.venera"), backupBytes);
    assert.equal(uploaded.has("/latest.venera"), false);
    assert.deepEqual(payload.files, ["1700000000000.venera"]);
    assert.equal(seenRequests.includes("HEAD /latest.venera"), false);
    assert.equal(seenRequests.includes("PUT /latest.venera"), false);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("sync WebDAV upload ignores latest conflicts", async () => {
  const backupBytes = buildZipArchive([
    { name: "appdata.json", data: Buffer.from("{}"), compression: 0 },
  ]);
  let latestHeadSeen = false;
  let latestPutSeen = false;
  let timestampUploadSeen = false;
  let timestampUploadDeleted = false;

  const upstream = createHttpServer(async (req, res) => {
    if (req.method === "HEAD" && req.url === "/latest.venera") {
      latestHeadSeen = true;
      res.writeHead(200, { ETag: '"latest-old"' });
      res.end();
      return;
    }

    if (req.method === "PUT" && req.url === "/1700000000001.venera") {
      for await (const _ of req) {
        // drain body
      }
      timestampUploadSeen = true;
      res.writeHead(201);
      res.end();
      return;
    }

    if (req.method === "PUT" && req.url === "/latest.venera") {
      latestPutSeen = true;
      assert.equal(req.headers["if-match"], '"latest-old"');
      for await (const _ of req) {
        // drain body
      }
      res.writeHead(412);
      res.end("precondition failed");
      return;
    }

    if (req.method === "DELETE" && req.url === "/1700000000001.venera") {
      timestampUploadDeleted = true;
      res.writeHead(204);
      res.end();
      return;
    }

    res.writeHead(404);
    res.end();
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/sync/webdav/upload`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        user: "user",
        pass: "pass",
        fileName: "1700000000001.venera",
        dataBase64: backupBytes.toString("base64"),
      }),
    });

    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.ok, true);
    assert.equal(timestampUploadSeen, true);
    assert.equal(timestampUploadDeleted, false);
    assert.equal(latestHeadSeen, false);
    assert.equal(latestPutSeen, false);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("proxy stores set-cookie and reuses cookies for the same host", async () => {
  let seenCookie = "";
  const upstream = createHttpServer((req, res) => {
    if (req.url === "/login") {
      res.writeHead(200, { "Set-Cookie": "sid=stored; Path=/" });
      res.end("ok");
      return;
    }

    seenCookie = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("cookie-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login` }),
    });
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/profile` }),
    });

    assert.equal(seenCookie, "sid=stored");
    const debugResponse = await fetch(`${helperUrl}/debug/proxy-requests`);
    const debugPayload = await debugResponse.json();
    assert.equal(debugPayload.requests[0].host, new URL(upstreamUrl).host);
    assert.equal(debugPayload.requests[0].cookieSource, "helper");
    assert.deepEqual(debugPayload.requests[0].cookieNames, ["sid"]);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("query proxy ignores helper-origin cookie and reuses target cookie jar", async () => {
  let seenCookie = "";
  const upstream = createHttpServer((req, res) => {
    if (req.url === "/login") {
      res.writeHead(200, { "Set-Cookie": "sid=stored; Path=/" });
      res.end("ok");
      return;
    }

    seenCookie = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("cookie-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login` }),
    });
    const response = await fetch(
      `${helperUrl}/proxy?url=${encodeURIComponent(`${upstreamUrl}/profile`)}`,
      { headers: { Cookie: "ipcountry=browser-helper-origin" } },
    );

    assert.equal(response.status, 200);
    assert.equal(seenCookie, "sid=stored");
    const debugPayload = await (
      await fetch(`${helperUrl}/debug/proxy-requests`)
    ).json();
    assert.equal(debugPayload.requests[0].cookieSource, "helper");
    assert.deepEqual(debugPayload.requests[0].cookieNames, ["sid"]);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("json proxy appends helper cookie jar to explicit cookie header", async () => {
  let seenCookie = "";
  const upstream = createHttpServer((req, res) => {
    if (req.url === "/login") {
      res.writeHead(200, { "Set-Cookie": "sid=stored; Path=/" });
      res.end("ok");
      return;
    }
    seenCookie = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("cookie-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login` }),
    });
    const response = await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: `${upstreamUrl}/api/check`,
        headers: {
          Cookie: "token=manual",
        },
      }),
    });

    assert.equal(response.status, 200);
    assert.equal(seenCookie, "token=manual; sid=stored");
    const debugPayload = await (
      await fetch(`${helperUrl}/debug/proxy-requests`)
    ).json();
    assert.equal(debugPayload.requests[0].cookieSource, "request+helper");
    assert.deepEqual(debugPayload.requests[0].cookieNames, ["token", "sid"]);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("api image reuses proxy headers, referer, explicit cookie and helper cookies", async () => {
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lxv6GQAAAABJRU5ErkJggg==",
    "base64",
  );
  const seen = {};
  const upstream = createHttpServer((req, res) => {
    if (req.url === "/login") {
      res.writeHead(200, { "Set-Cookie": "sid=image; Path=/" });
      res.end("ok");
      return;
    }
    seen.cookie = req.headers.cookie || "";
    seen.referer = req.headers.referer || "";
    seen.configHeader = req.headers["x-image-config"] || "";
    seen.accept = req.headers.accept || "";
    res.writeHead(200, {
      "Content-Type": "image/png",
      "Content-Length": String(png.length),
    });
    res.end(png);
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login` }),
    });
    const response = await fetch(`${helperUrl}/api/image`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: `${upstreamUrl}/cover.png`,
        imageConfig: {
          referer: `${upstreamUrl}/chapter/1`,
          cookie: "manual=1",
          headers: { "X-Image-Config": "yes" },
        },
      }),
    });

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
    assert.equal(seen.cookie, "manual=1; sid=image");
    assert.equal(seen.referer, `${upstreamUrl}/chapter/1`);
    assert.equal(seen.configHeader, "yes");
    assert.match(seen.accept, /image\/webp/);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("query proxy replaces browser mobile user-agent with default desktop user-agent", async () => {
  let seenUserAgent = "";
  const upstream = createHttpServer((req, res) => {
    seenUserAgent = req.headers["user-agent"] || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ua-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(
      `${helperUrl}/proxy?url=${encodeURIComponent(upstreamUrl)}`,
      {
        headers: {
          "User-Agent":
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1",
        },
      },
    );

    assert.equal(response.status, 200);
    assert.match(seenUserAgent, /Windows NT 10\.0; Win64; x64/);
    assert.doesNotMatch(seenUserAgent, /iPhone|Mobile\/15E148/);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("json proxy preserves explicit source user-agent", async () => {
  let seenUserAgent = "";
  const upstream = createHttpServer((req, res) => {
    seenUserAgent = req.headers["user-agent"] || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ua-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        headers: { "User-Agent": "CopyMangaSource/1.0" },
      }),
    });

    assert.equal(response.status, 200);
    assert.equal(seenUserAgent, "CopyMangaSource/1.0");
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("query proxy metadata forwards source headers and strips browser headers", async () => {
  const { __testHooks } = await import("./server.js");

  const headers = __testHooks.prepareQueryProxyHeaders({
    host: "helper.local",
    connection: "keep-alive",
    "user-agent": "Browser UA",
    cookie: "helper_session=ignored",
    "sec-fetch-site": "same-origin",
    "x-venera-user-agent": "CopyMangaSource/1.0",
    "x-venera-cookie": "token=abc",
    "x-venera-referer": "https://www.2026copy.com/comic/demo",
    "x-venera-origin": "https://www.2026copy.com",
    "x-venera-forward-headers": JSON.stringify([
      "Authorization",
      "X-Copy-Platform",
      "Content-Type",
    ]),
    authorization: "Bearer token",
    "x-copy-platform": "3",
    "content-type": "application/json",
    accept: "*/*",
  });

  assert.deepEqual(headers, {
    Authorization: "Bearer token",
    "X-Copy-Platform": "3",
    "Content-Type": "application/json",
    "User-Agent": "CopyMangaSource/1.0",
    Cookie: "token=abc",
    Referer: "https://www.2026copy.com/comic/demo",
    Origin: "https://www.2026copy.com",
  });
});

test("query proxy fallback keeps custom source headers without metadata", async () => {
  const { __testHooks } = await import("./server.js");

  const headers = __testHooks.prepareQueryProxyHeaders({
    host: "helper.local",
    "user-agent": "Browser UA",
    "sec-fetch-mode": "cors",
    authorization: "Bearer token",
    "x-copy-platform": "3",
  });

  assert.equal(headers.Authorization, "Bearer token");
  assert.equal(headers["x-copy-platform"], "3");
  assert.equal(headers["User-Agent"], undefined);
  assert.equal(headers.host, undefined);
  assert.equal(headers["sec-fetch-mode"], undefined);
});

test("proxy respects set-cookie domain and path when replaying cookies", async () => {
  const seenCookies = {};
  const upstream = createHttpServer((req, res) => {
    if (req.url === "/login") {
      res.writeHead(200, {
        "Set-Cookie": [
          "sid=reader; Path=/reader",
          "root=yes; Path=/",
        ],
      });
      res.end("ok");
      return;
    }

    seenCookies[req.url] = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("cookie-check");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login` }),
    });
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/reader/chapter` }),
    });
    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/api/check` }),
    });

    assert.equal(seenCookies["/reader/chapter"], "sid=reader; root=yes");
    assert.equal(seenCookies["/api/check"], "root=yes");
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("cookie import keeps host-only scope and supports explicit domain scope", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const importResponse = await fetch(`${helperUrl}/cookies`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://2026copy.com/",
        cookies: [{ name: "sid", value: "stored" }],
      }),
    });
    assert.equal(importResponse.status, 200);

    const wwwResponse = await fetch(
      `${helperUrl}/cookies?url=${encodeURIComponent("https://www.2026copy.com/comic/test")}`,
    );
    assert.equal(wwwResponse.status, 200);
    assert.deepEqual((await wwwResponse.json()).cookies, []);

    const bareResponse = await fetch(
      `${helperUrl}/cookies?url=${encodeURIComponent("https://2026copy.com/comic/test")}`,
    );
    assert.equal(bareResponse.status, 200);
    assert.deepEqual((await bareResponse.json()).cookies, [
      { name: "sid", value: "stored" },
    ]);

    const domainImportResponse = await fetch(`${helperUrl}/cookies`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://2026copy.com/",
        cookies: [{ name: "sid", value: "shared", domain: ".2026copy.com" }],
      }),
    });
    assert.equal(domainImportResponse.status, 200);

    const domainWwwResponse = await fetch(
      `${helperUrl}/cookies?url=${encodeURIComponent("https://www.2026copy.com/comic/test")}`,
    );
    assert.equal(domainWwwResponse.status, 200);
    assert.deepEqual((await domainWwwResponse.json()).cookies, [
      { name: "sid", value: "shared" },
    ]);
  } finally {
    await close(helper);
  }
});

test("cookie jar can persist helper cookies across server restarts", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "venera-cookies-"));
  const cookieJarPath = join(dataDir, "cookies.json");
  let seenCookie = "";
  const upstream = createHttpServer((req, res) => {
    seenCookie = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
  });
  const upstreamUrl = await listen(upstream);

  try {
    const firstHelper = createServer({ cookieJarPath });
    const firstHelperUrl = await listen(firstHelper);
    await fetch(`${firstHelperUrl}/cookies`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        cookies: [{ name: "token", value: "persisted" }],
      }),
    });
    await close(firstHelper);

    const secondHelper = createServer({ cookieJarPath });
    const secondHelperUrl = await listen(secondHelper);
    try {
      const proxyResponse = await fetch(`${secondHelperUrl}/proxy`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: `${upstreamUrl}/profile` }),
      });
      assert.equal((await proxyResponse.json()).status, 200);
      assert.equal(seenCookie, "token=persisted");
    } finally {
      await close(secondHelper);
    }
  } finally {
    await close(upstream);
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("cookie import and export endpoints share helper cookie jar", async () => {
  const upstream = createHttpServer((req, res) => {
    assert.equal(req.headers.cookie, "token=manual");
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const importResponse = await fetch(`${helperUrl}/cookies`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        cookies: [{ name: "token", value: "manual" }],
      }),
    });
    assert.equal(importResponse.status, 200);

    const exportResponse = await fetch(
      `${helperUrl}/cookies?url=${encodeURIComponent(upstreamUrl)}`,
    );
    assert.deepEqual(await exportResponse.json(), {
      cookies: [{ name: "token", value: "manual" }],
    });

    const proxyResponse = await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/profile` }),
    });
    assert.equal((await proxyResponse.json()).status, 200);
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("cookie bulk import/export preserves app-synced domain cookies", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);

  try {
    const importResponse = await fetch(`${helperUrl}/cookies/import`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        cookies: [
          {
            name: "token",
            value: "synced",
            domain: ".2026copy.com",
            path: "/",
            expiresMs: Date.now() + 3600000,
            secure: false,
            httpOnly: true,
          },
        ],
      }),
    });
    assert.equal(importResponse.status, 200);

    const exported = await fetch(`${helperUrl}/cookies/export`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    const payload = await exported.json();
    assert.equal(payload.ok, true);
    assert.equal(payload.cookies[0].domain, ".2026copy.com");
    assert.equal(payload.cookies[0].name, "token");
    assert.equal(payload.cookies[0].value, "synced");

    const scoped = await fetch(
      `${helperUrl}/cookies?url=${encodeURIComponent("https://www.2026copy.com/profile")}`,
    );
    assert.deepEqual((await scoped.json()).cookies, [
      { name: "token", value: "synced" },
    ]);
  } finally {
    await close(helper);
  }
});

test("login import endpoint stores shortcut payload by code", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  const code = "copy-manga-import-abcdefghijklmnopqrstuvwxyz";
  try {
    const pending = await fetch(`${helperUrl}/login-import/${code}`);
    assert.equal(pending.status, 200);
    assert.deepEqual(await pending.json(), { ok: true, status: "pending" });

    const submit = await fetch(`${helperUrl}/login-import/${code}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://www.mangacopy.com/comic/demo",
        cookie: "webp=1; token=abcdefghijklmnopqrstuvwxyz",
        localStorage: { access_token: "Bearer zyxwvutsrqponmlkjihgfedcba" },
      }),
    });
    assert.equal(submit.status, 200);
    assert.equal((await submit.json()).status, "completed");

    const completed = await fetch(`${helperUrl}/login-import/${code}`);
    assert.equal(completed.status, 200);
    const completedPayload = await completed.json();
    assert.equal(completedPayload.status, "completed");
    assert.equal(
      completedPayload.payload.url,
      "https://www.mangacopy.com/comic/demo",
    );
    assert.equal(
      completedPayload.payload.localStorage.access_token,
      "Bearer zyxwvutsrqponmlkjihgfedcba",
    );

    const cleared = await fetch(`${helperUrl}/login-import/${code}`, {
      method: "DELETE",
    });
    assert.equal(cleared.status, 200);
    assert.deepEqual(await cleared.json(), { ok: true, status: "pending" });
  } finally {
    await close(helper);
  }
});

test("login import shortcut page serves a real copyable HTML page", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  const code = "copy-manga-import-abcdefghijklmnopqrstuvwxyz";
  try {
    const response = await fetch(`${helperUrl}/login-import/${code}/shortcut`);
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "text/html; charset=utf-8");
    assert.match(html, /<textarea id="script"/);
    assert.match(html, new RegExp(`/login-import/${code}`));
    assert.equal(html.includes("data:text/html"), false);
  } finally {
    await close(helper);
  }
});

test("login import shortcut page uses Chinese labels when requested", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  const code = "copy-manga-import-abcdefghijklmnopqrstuvwxyz";
  try {
    const response = await fetch(`${helperUrl}/login-import/${code}/shortcut`, {
      headers: { "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8" },
    });
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.match(html, />复制脚本</);
    assert.match(html, />全选</);
    assert.match(html, /复制下面的全部文本/);
  } finally {
    await close(helper);
  }
});

test("login import endpoint rejects invalid codes", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const response = await fetch(`${helperUrl}/login-import/../bad`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cookie: "token=abcdefghijklmnopqrstuvwxyz" }),
    });
    assert.equal(response.status, 404);
  } finally {
    await close(helper);
  }
});

function createFakeBrowserFactory() {
  const calls = [];
  return {
    calls,
    async createSession(options = {}) {
      calls.push(options);
      const state = {
        url: "about:blank",
        title: "",
        cookies: [],
        localStorage: {},
        localStorageByOrigin: {},
        clicked: null,
        typed: "",
      };
      return {
        async navigate(url) {
          const origin = new URL(url).origin;
          state.url = url;
          state.title = "Logged in";
          state.cookies = [
            {
              name: "sid",
              value: "browser",
              domain: new URL(url).hostname,
              path: "/",
              expires: -1,
            },
          ];
          state.localStorage = { token: "from-storage" };
          state.localStorageByOrigin = { [origin]: state.localStorage };
        },
        async state() {
          return { ...state };
        },
        async screenshot() {
          return Buffer.from("fake-png");
        },
        async click(x, y) {
          state.clicked = { x, y };
        },
        async type(text) {
          state.typed += text;
        },
        async press(key) {
          state.typed += `<${key}>`;
        },
        async close() {},
      };
    },
  };
}

test("browser sessions default to mobile profile", async () => {
  const factory = createFakeBrowserFactory();
  const helper = createServer({ browserFactory: factory });
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: "https://example.test/login" }),
    });

    assert.equal(response.status, 200);
    assert.equal(factory.calls[0].profile, "mobile");
  } finally {
    await close(helper);
  }
});

test("browser sessions can request desktop profile", async () => {
  const factory = createFakeBrowserFactory();
  const helper = createServer({ browserFactory: factory });
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://example.test/login",
        sessionId: "desktop",
        profile: "desktop",
      }),
    });

    assert.equal(response.status, 200);
    assert.equal(factory.calls[0].profile, "desktop");
  } finally {
    await close(helper);
  }
});

test("mobile browser profile uses chromium-compatible mobile client data", async () => {
  const { __testHooks } = await import("./server.js");
  const contextOptions = __testHooks.browserContextOptions("mobile");

  assert.equal(contextOptions.profile, "mobile");
  assert.equal(contextOptions.options.isMobile, true);
  assert.equal(contextOptions.options.hasTouch, true);
  assert.match(contextOptions.options.userAgent, /Android/);
  assert.match(contextOptions.options.userAgent, /Chrome\//);
  assert.doesNotMatch(contextOptions.options.userAgent, /iPhone|Version\/.*Mobile\/.*Safari\/604\.1/);
});

test("mobile browser clicks dispatch touch taps", async () => {
  const { __testHooks } = await import("./server.js");
  const events = [];
  const page = {
    touchscreen: {
      async tap(x, y) {
        events.push(["tap", x, y]);
      },
    },
    mouse: {
      async click(x, y) {
        events.push(["mouse", x, y]);
      },
    },
  };

  await __testHooks.dispatchBrowserClick(page, "mobile", 12, 34);

  assert.deepEqual(events, [["tap", 12, 34]]);
});

test("desktop browser clicks keep mouse dispatch", async () => {
  const { __testHooks } = await import("./server.js");
  const events = [];
  const page = {
    touchscreen: {
      async tap(x, y) {
        events.push(["tap", x, y]);
      },
    },
    mouse: {
      async click(x, y) {
        events.push(["mouse", x, y]);
      },
    },
  };

  await __testHooks.dispatchBrowserClick(page, "desktop", 12, 34);

  assert.deepEqual(events, [["mouse", 12, 34]]);
});

test("browser session view uses direct pointer tap handling", async () => {
  const helper = createServer({ browserFactory: createFakeBrowserFactory() });
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://example.test/login",
        sessionId: "touch-view",
      }),
    });
    const response = await fetch(`${helperUrl}/browser/session/touch-view/view`);
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.match(html, /sendScreenTap/);
    assert.match(html, /pointerup/);
    assert.match(html, /WebSocket/);
  } finally {
    await close(helper);
  }
});

test("browser session view uses Chinese controls when requested", async () => {
  const helper = createServer({ browserFactory: createFakeBrowserFactory() });
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: "https://example.test/login",
        sessionId: "zh-view",
      }),
    });
    const response = await fetch(`${helperUrl}/browser/session/zh-view/view`, {
      headers: { "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.8" },
    });
    const html = await response.text();

    assert.equal(response.status, 200);
    assert.match(html, />前往</);
    assert.match(html, /placeholder="输入文字"/);
    assert.match(html, />同步</);
    assert.match(html, />正在加载.../);
  } finally {
    await close(helper);
  }
});

test("browser session websocket pushes state payloads", async () => {
  const helper = createServer({ browserFactory: createFakeBrowserFactory() });
  const helperUrl = await listen(helper);
  const target = "https://example.test/login";

  try {
    await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: target, sessionId: "events" }),
    });

    const eventsUrl = `${helperUrl.replace(/^http/, "ws")}/browser/session/events/events?url=${encodeURIComponent(target)}`;
    const socket = await connectWebSocket(eventsUrl);
    try {
      const pushed = JSON.parse(await readWebSocketTextFrame(socket));
      assert.equal(pushed.type, "state");
      assert.equal(pushed.sessionId, "events");
      assert.equal(pushed.state.url, target);
      assert.deepEqual(pushed.state.localStorage, { token: "from-storage" });
    } finally {
      await closeClientWebSocket(socket);
    }
  } finally {
    await close(helper);
  }
});

test("browser session exports cookies and localStorage", async () => {
  const helper = createServer({ browserFactory: createFakeBrowserFactory() });
  const helperUrl = await listen(helper);
  const target = "https://example.test/login";

  try {
    const createResponse = await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: target, sessionId: "source.test" }),
    });

    assert.equal(createResponse.status, 200);
    const created = await createResponse.json();
    assert.equal(created.sessionId, "source.test");
    assert.equal(created.state.url, target);
    assert.equal(created.state.title, "Logged in");
    assert.deepEqual(created.state.localStorage, { token: "from-storage" });
    assert.deepEqual(created.state.cookies, [
      {
        name: "sid",
        value: "browser",
        domain: "example.test",
        path: "/",
        expires: -1,
      },
    ]);
    assert.equal(
      created.viewUrl,
      `${helperUrl}/browser/session/source.test/view`,
    );

    const stateResponse = await fetch(
      `${helperUrl}/browser/session/source.test/state?url=${encodeURIComponent(target)}`,
    );
    assert.equal(stateResponse.status, 200);
    assert.equal((await stateResponse.json()).state.localStorage.token, "from-storage");

    const screenshotResponse = await fetch(
      `${helperUrl}/browser/session/source.test/screenshot`,
    );
    assert.equal(screenshotResponse.status, 200);
    assert.equal(await screenshotResponse.text(), "fake-png");

    await fetch(`${helperUrl}/browser/session/source.test/click`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ x: 10, y: 20 }),
    });
    await fetch(`${helperUrl}/browser/session/source.test/type`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: "abc" }),
    });
    await fetch(`${helperUrl}/browser/session/source.test/press`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: "Enter" }),
    });
    const interacted = await fetch(
      `${helperUrl}/browser/session/source.test/state`,
    );
    const interactedJson = await interacted.json();
    assert.deepEqual(interactedJson.state.clicked, { x: 10, y: 20 });
    assert.equal(interactedJson.state.typed, "abc<Enter>");
  } finally {
    await close(helper);
  }
});

test("browser state can sync cookies into proxy jar", async () => {
  let seenCookie = "";
  const upstream = createHttpServer((req, res) => {
    seenCookie = req.headers.cookie || "";
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer({ browserFactory: createFakeBrowserFactory() });
  const helperUrl = await listen(helper);

  try {
    await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/login`, sessionId: "sync" }),
    });
    const syncResponse = await fetch(
      `${helperUrl}/browser/session/sync/sync-cookies`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: upstreamUrl }),
      },
    );
    assert.equal(syncResponse.status, 200);

    await fetch(`${helperUrl}/proxy`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: `${upstreamUrl}/profile` }),
    });

    assert.equal(seenCookie, "sid=browser");
  } finally {
    await close(helper);
    await close(upstream);
  }
});

test("browser helper reports unavailable browser cleanly", async () => {
  const helper = createServer({
    browserFactory: {
      async createSession() {
        const error = new Error("Playwright unavailable");
        error.statusCode = 503;
        throw error;
      },
    },
  });
  const helperUrl = await listen(helper);

  try {
    const response = await fetch(`${helperUrl}/browser/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: "https://example.test/" }),
    });
    assert.equal(response.status, 503);
    assert.match((await response.json()).error, /Playwright unavailable/);
  } finally {
    await close(helper);
  }
});

// ---------------------------------------------------------------------------
// /sync/webdav/extract-db tests
// ---------------------------------------------------------------------------

/**
 * Build a minimal but valid SQLite 3 database buffer (pure JS, no native deps).
 * Returns a Buffer containing a 2-page, 4096-byte-per-page SQLite file with:
 *   - One table: history(id INTEGER PRIMARY KEY, title TEXT, time INTEGER)
 *   - One row:   (1, 'Test Comic', 1700000000)
 */
function buildMinimalSqliteDb() {
  const PAGE_SIZE = 4096;
  const db = Buffer.alloc(PAGE_SIZE * 2);

  // File header (100 bytes at offset 0)
  db.write("SQLite format 3\0", 0, "ascii");
  db.writeUInt16BE(PAGE_SIZE, 16);
  db[18] = 1; db[19] = 1; db[20] = 0; db[21] = 64; db[22] = 32; db[23] = 32;
  db.writeUInt32BE(1, 24);   // change counter
  db.writeUInt32BE(2, 28);   // db size in pages
  db.writeUInt32BE(0, 32);   // first trunk page
  db.writeUInt32BE(0, 36);   // total free pages
  db.writeUInt32BE(1, 40);   // schema cookie
  db.writeUInt32BE(4, 44);   // schema format
  db.writeUInt32BE(1, 56);   // text encoding: UTF-8
  db.writeUInt32BE(1, 92);   // version-valid-for
  db.writeUInt32BE(3036000, 96);  // SQLite version

  function encodeVarint(n) {
    const big = BigInt(n);
    if (big < 128n) return Buffer.from([Number(big)]);
    return Buffer.from([Number((big & 0x7fn) | 0x80n), Number(big >> 7n)]);
  }

  function textSt(s) { return Buffer.byteLength(s, "utf8") * 2 + 13; }

  // ---- Page 1: sqlite_master leaf ----
  const sql = "CREATE TABLE history (id INTEGER PRIMARY KEY, title TEXT, time INTEGER)";
  const typeStr = Buffer.from("table", "utf8");
  const nameStr = Buffer.from("history", "utf8");
  const sqlStr  = Buffer.from(sql, "utf8");
  const hdrVarints = Buffer.concat([
    encodeVarint(textSt("table")),
    encodeVarint(textSt("history")),
    encodeVarint(textSt("history")),
    encodeVarint(1),              // rootpage serial type: int8
    encodeVarint(sqlStr.length * 2 + 13),
  ]);
  const hdrSize = 1 + hdrVarints.length;
  const rootPageBuf = Buffer.from([2]);
  const payload1 = Buffer.concat([Buffer.from([hdrSize]), hdrVarints,
    typeStr, nameStr, nameStr, rootPageBuf, sqlStr]);
  const cell1 = Buffer.concat([encodeVarint(payload1.length), encodeVarint(1), payload1]);
  const c1off = PAGE_SIZE - cell1.length;
  cell1.copy(db, c1off);
  db[100] = 0x0d;                          // leaf table b-tree
  db.writeUInt16BE(0, 101);                // no freeblock
  db.writeUInt16BE(1, 103);                // 1 cell
  db.writeUInt16BE(c1off, 105);            // content start
  db.writeUInt16BE(c1off, 108);            // cell pointer[0]

  // ---- Page 2: history leaf ----
  const p2 = PAGE_SIZE;
  const titleStr = Buffer.from("Test Comic", "utf8");
  const hv2 = Buffer.concat([
    encodeVarint(1),                       // id: int8
    encodeVarint(textSt("Test Comic")),
    encodeVarint(4),                       // time: int32
  ]);
  const hs2 = 1 + hv2.length;
  const idBuf = Buffer.from([1]);
  const timeBuf = Buffer.alloc(4); timeBuf.writeInt32BE(1700000000);
  const rowPay = Buffer.concat([Buffer.from([hs2]), hv2, idBuf, titleStr, timeBuf]);
  const rowCell = Buffer.concat([encodeVarint(rowPay.length), encodeVarint(1), rowPay]);
  const rc2off = PAGE_SIZE - rowCell.length;
  rowCell.copy(db, p2 + rc2off);
  db[p2]     = 0x0d;
  db.writeUInt16BE(0,      p2 + 1);
  db.writeUInt16BE(1,      p2 + 3);
  db.writeUInt16BE(rc2off, p2 + 5);
  db.writeUInt16BE(rc2off, p2 + 8);

  return db;
}

function buildSqliteDbWithOverflowCell() {
  const PAGE_SIZE = 512;
  const db = Buffer.alloc(PAGE_SIZE * 3);

  function encodeVarint(n) {
    let value = BigInt(n);
    if (value < 0n) throw new Error("negative varint");
    const bytes = [Number(value & 0x7fn)];
    value >>= 7n;
    while (value > 0n) {
      bytes.unshift(Number((value & 0x7fn) | 0x80n));
      value >>= 7n;
    }
    return Buffer.from(bytes);
  }

  function textSt(s) { return Buffer.byteLength(s, "utf8") * 2 + 13; }
  function tableLeafLocalPayloadSize(payloadSize) {
    const usableSize = PAGE_SIZE;
    const maxLocal = usableSize - 35;
    if (payloadSize <= maxLocal) return payloadSize;
    const minLocal = Math.floor(((usableSize - 12) * 32) / 255) - 23;
    let local = minLocal + ((payloadSize - minLocal) % (usableSize - 4));
    if (local > maxLocal) local = minLocal;
    return local;
  }

  db.write("SQLite format 3\0", 0, "ascii");
  db.writeUInt16BE(PAGE_SIZE, 16);
  db[18] = 1; db[19] = 1; db[20] = 0; db[21] = 64; db[22] = 32; db[23] = 32;
  db.writeUInt32BE(1, 24);
  db.writeUInt32BE(3, 28);
  db.writeUInt32BE(0, 32);
  db.writeUInt32BE(0, 36);
  db.writeUInt32BE(1, 40);
  db.writeUInt32BE(4, 44);
  db.writeUInt32BE(1, 56);
  db.writeUInt32BE(1, 92);
  db.writeUInt32BE(3036000, 96);

  const sql = `CREATE TABLE history (id INTEGER PRIMARY KEY, title TEXT, time INTEGER) /* ${"A".repeat(700)} */`;
  const typeStr = Buffer.from("table", "utf8");
  const nameStr = Buffer.from("history", "utf8");
  const sqlStr = Buffer.from(sql, "utf8");
  const hdrVarints = Buffer.concat([
    encodeVarint(textSt("table")),
    encodeVarint(textSt("history")),
    encodeVarint(textSt("history")),
    encodeVarint(1),
    encodeVarint(sqlStr.length * 2 + 13),
  ]);
  const hdrSize = encodeVarint(1 + hdrVarints.length);
  const payload = Buffer.concat([
    hdrSize,
    hdrVarints,
    typeStr,
    nameStr,
    nameStr,
    Buffer.from([2]),
    sqlStr,
  ]);
  const localSize = tableLeafLocalPayloadSize(payload.length);
  const cell = Buffer.concat([
    encodeVarint(payload.length),
    encodeVarint(1),
    payload.subarray(0, localSize),
    Buffer.from([0, 0, 0, 3]),
  ]);
  const c1off = PAGE_SIZE - cell.length;
  cell.copy(db, c1off);
  payload.subarray(localSize).copy(db, PAGE_SIZE * 2 + 4);
  db.writeUInt32BE(0, PAGE_SIZE * 2);
  db[100] = 0x0d;
  db.writeUInt16BE(0, 101);
  db.writeUInt16BE(1, 103);
  db.writeUInt16BE(c1off, 105);
  db.writeUInt16BE(c1off, 108);

  const p2 = PAGE_SIZE;
  const titleStr = Buffer.from("Overflow Comic", "utf8");
  const rowHdrVarints = Buffer.concat([
    encodeVarint(1),
    encodeVarint(textSt("Overflow Comic")),
    encodeVarint(4),
  ]);
  const rowHeader = encodeVarint(1 + rowHdrVarints.length);
  const timeBuf = Buffer.alloc(4);
  timeBuf.writeInt32BE(1700000000);
  const rowPayload = Buffer.concat([
    rowHeader,
    rowHdrVarints,
    Buffer.from([1]),
    titleStr,
    timeBuf,
  ]);
  const rowCell = Buffer.concat([encodeVarint(rowPayload.length), encodeVarint(1), rowPayload]);
  const rowOff = PAGE_SIZE - rowCell.length;
  rowCell.copy(db, p2 + rowOff);
  db[p2] = 0x0d;
  db.writeUInt16BE(0, p2 + 1);
  db.writeUInt16BE(1, p2 + 3);
  db.writeUInt16BE(rowOff, p2 + 5);
  db.writeUInt16BE(rowOff, p2 + 8);

  return db;
}

/**
 * Build a minimal ZIP buffer (stored, no compression) from an entries map.
 * @param {Map<string, Buffer>} entries  name -> content
 */
function buildZipStored(entries) {
  const localHeaders = [];
  const centralHeaders = [];
  let offset = 0;

  for (const [name, data] of entries) {
    const nameBytes = Buffer.from(name, "utf8");
    const crc = crc32(data);

    const local = Buffer.alloc(30 + nameBytes.length + data.length);
    local.writeUInt32LE(0x04034b50, 0);    // local file header signature
    local.writeUInt16LE(20, 4);            // version needed
    local.writeUInt16LE(0, 6);             // flags
    local.writeUInt16LE(0, 8);             // compression: stored
    local.writeUInt16LE(0, 10);            // mod time
    local.writeUInt16LE(0, 12);            // mod date
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);  // compressed size
    local.writeUInt32LE(data.length, 22);  // uncompressed size
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);            // extra length
    nameBytes.copy(local, 30);
    data.copy(local, 30 + nameBytes.length);

    const central = Buffer.alloc(46 + nameBytes.length);
    central.writeUInt32LE(0x02014b50, 0);  // central dir signature
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(0, 38);
    central.writeUInt32LE(offset, 42);
    nameBytes.copy(central, 46);

    localHeaders.push(local);
    centralHeaders.push(central);
    offset += local.length;
  }

  const centralStart = offset;
  const centralBuf = Buffer.concat(centralHeaders);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.size, 8);
  eocd.writeUInt16LE(entries.size, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(centralStart, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...localHeaders, centralBuf, eocd]);
}

/** Simple CRC-32 for the ZIP test helper. */
function crc32(buf) {
  const table = crc32._table || (crc32._table = (() => {
    const t = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let j = 0; j < 8; j++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      t[i] = c;
    }
    return t;
  })());
  let crc = 0xffffffff;
  for (const byte of buf) crc = table[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Build a minimal .venera ZIP containing a single named .db entry.
 */
function buildVeneraZipWithDb(entryName, dbBuf) {
  return buildZipStored(new Map([[entryName, dbBuf]]));
}

test("extract-db returns 405 for non-POST request", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, { method: "GET" });
    assert.equal(res.status, 405);
  } finally {
    await close(helper);
  }
});

test("extract-db returns 400 when dataBase64 is missing", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 400);
  } finally {
    await close(helper);
  }
});

test("extract-db returns 422 when payload is not a zip", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: Buffer.from("not a zip").toString("base64") }),
    });
    assert.equal(res.status, 422);
  } finally {
    await close(helper);
  }
});

test("extract-db extracts history.db table and row from venera zip", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const dbBuf = buildMinimalSqliteDb();
    const zipBuf = buildVeneraZipWithDb("history.db", dbBuf);
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: zipBuf.toString("base64") }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.ok, true);
    const histDb = data.databases["history.db"];
    assert.equal(histDb.ok, true);
    assert.ok(Array.isArray(histDb.tables));
    const historyTable = histDb.tables.find((t) => t.name === "history");
    assert.ok(historyTable, "history table should be present");
    assert.deepEqual(historyTable.columns, ["id", "title", "time"]);
    assert.equal(historyTable.rows.length, 1);
    const row = historyTable.rows[0];
    assert.equal(row[0], 1);          // id
    assert.equal(row[1], "Test Comic");
    assert.equal(row[2], 1700000000);
  } finally {
    await close(helper);
  }
});

test("extract-db reads sqlite overflow payload pages", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const dbBuf = buildSqliteDbWithOverflowCell();
    const zipBuf = buildVeneraZipWithDb("history.db", dbBuf);
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: zipBuf.toString("base64") }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    const histDb = data.databases["history.db"];
    assert.equal(histDb.ok, true);
    const historyTable = histDb.tables.find((t) => t.name === "history");
    assert.ok(historyTable, "history table should be present");
    assert.deepEqual(historyTable.columns, ["id", "title", "time"]);
    assert.equal(historyTable.rows.length, 1);
    assert.deepEqual(historyTable.rows[0], [1, "Overflow Comic", 1700000000]);
  } finally {
    await close(helper);
  }
});

test("extract-db reports ok:false for non-sqlite db entry", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const notADb = Buffer.from("this is not a database");
    // Wrap it in a valid ZIP (it'll pass zip check but fail sqlite check)
    const zipBuf = buildVeneraZipWithDb("history.db", notADb);
    // Patch the ZIP magic so assertLooksLikeVeneraBackup passes — the
    // entry content is invalid sqlite, not the zip itself.
    // (buildVeneraZipWithDb already produces valid ZIP magic 0x504b0304)
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: zipBuf.toString("base64") }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.ok, true);
    assert.equal(data.databases["history.db"].ok, false);
    assert.ok(typeof data.databases["history.db"].error === "string");
    assert.equal(
      Buffer.from(data.databases["history.db"].rawBase64, "base64").equals(notADb),
      true,
    );
  } finally {
    await close(helper);
  }
});

test("extract-db ignores zip entries not in the known db list", async () => {
  const helper = createServer();
  const helperUrl = await listen(helper);
  try {
    const dbBuf = buildMinimalSqliteDb();
    const zipBuf = buildZipStored(new Map([
      ["history.db", dbBuf],
      ["appdata.json", Buffer.from('{"settings":{}}')],
      ["unknown_extra.db", dbBuf],
    ]));
    const res = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: zipBuf.toString("base64") }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.ok("history.db" in data.databases);
    assert.ok(!("appdata.json" in data.databases));
    assert.ok(!("unknown_extra.db" in data.databases));
  } finally {
    await close(helper);
  }
});
