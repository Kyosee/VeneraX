import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

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
    const n = value < 0 ? 0x1000000 + value : value;
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

function buildLeafPage({ pageSize, cells, isPage1 = false }) {
  const page = Buffer.alloc(pageSize);
  const headerOffset = isPage1 ? 100 : 0;
  page[headerOffset] = 0x0d;
  page.writeUInt16BE(0, headerOffset + 1);
  page.writeUInt16BE(cells.length, headerOffset + 3);
  let contentStart = pageSize;
  const pointers = [];
  for (const cell of cells) {
    contentStart -= cell.length;
    cell.copy(page, contentStart);
    pointers.push(contentStart);
  }
  page.writeUInt16BE(contentStart, headerOffset + 5);
  page[headerOffset + 7] = 0;
  for (let i = 0; i < pointers.length; i++) {
    page.writeUInt16BE(pointers[i], headerOffset + 8 + i * 2);
  }
  return page;
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
  buildLeafPage({ pageSize, cells: [schemaCell], isPage1: true }).copy(
    db,
    100,
    100,
  );

  const dataCell = encodeTableCell(1, [
    sqliteIntField(1),
    sqliteTextField(title),
  ]);
  buildLeafPage({ pageSize, cells: [dataCell] }).copy(db, pageSize);
  return db;
}

function buildZipArchive(entries) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;

  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, "utf8");
    const data = entry.data;
    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt32LE(0, 14);
    localHeader.writeUInt32LE(data.length, 18);
    localHeader.writeUInt32LE(data.length, 22);
    localHeader.writeUInt16LE(nameBytes.length, 26);
    localParts.push(localHeader, nameBytes, data);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt32LE(0, 16);
    centralHeader.writeUInt32LE(data.length, 20);
    centralHeader.writeUInt32LE(data.length, 24);
    centralHeader.writeUInt16LE(nameBytes.length, 28);
    centralHeader.writeUInt32LE(localOffset, 42);
    centralParts.push(centralHeader, nameBytes);
    localOffset += localHeader.length + nameBytes.length + data.length;
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

test("WebDAV sync can persist and reuse helper-side configuration", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const webDavConfigPath = join(serverDataDir, "webdav-config.json");
  const seenRequests = [];

  const upstream = createHttpServer(async (req, res) => {
    seenRequests.push(`${req.method} ${req.url}`);
    assert.equal(req.headers.authorization, "Basic dXNlcjpwYXNz");

    if (req.method === "PROPFIND") {
      res.writeHead(207, { "Content-Type": "application/xml" });
      res.end(`<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/1700000000100.venera</d:href></d:response>
</d:multistatus>`);
      return;
    }

    res.writeHead(404);
    res.end();
  });

  const upstreamUrl = await listen(upstream);
  const helper = createServer({ webDavConfigPath });
  const helperUrl = await listen(helper);

  try {
    const emptyConfigResponse = await fetch(`${helperUrl}/sync/webdav/config/get`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(emptyConfigResponse.status, 200);
    assert.equal((await emptyConfigResponse.json()).configured, false);

    const saveResponse = await fetch(`${helperUrl}/sync/webdav/config/save`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: upstreamUrl,
        user: "user",
        pass: "pass",
        autoSync: true,
        disableSyncFields: "token",
      }),
    });
    assert.equal(saveResponse.status, 200);
    assert.equal((await saveResponse.json()).configured, true);

    const stored = JSON.parse(await readFile(webDavConfigPath, "utf8"));
    assert.equal(stored.url, `${upstreamUrl}/`);
    assert.equal(stored.user, "user");
    assert.equal(stored.pass, "pass");
    assert.equal(stored.disableSyncFields, "token");

    const getResponse = await fetch(`${helperUrl}/sync/webdav/config/get`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(getResponse.status, 200);
    const getPayload = await getResponse.json();
    assert.equal(getPayload.configured, true);
    assert.equal(getPayload.url, `${upstreamUrl}/`);

    const listResponse = await fetch(`${helperUrl}/sync/webdav/list`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(listResponse.status, 200);
    assert.deepEqual((await listResponse.json()).files, ["1700000000100.venera"]);
    assert.deepEqual(seenRequests, ["PROPFIND /"]);

    const clearResponse = await fetch(`${helperUrl}/sync/webdav/config/clear`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(clearResponse.status, 200);
    assert.equal((await clearResponse.json()).configured, false);

    const missingConfigResponse = await fetch(`${helperUrl}/sync/webdav/list`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(missingConfigResponse.status, 400);
  } finally {
    await close(helper);
    await close(upstream);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db sync stores WebDAV backup on helper disk", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const historyDb = buildMinimalHistoryDb("server stored history");
  const backupBytes = buildZipArchive([
    { name: "appdata.json", data: Buffer.from('{"settings":{}}') },
    { name: "history.db", data: historyDb },
  ]);
  const seenRequests = [];

  const upstream = createHttpServer(async (req, res) => {
    seenRequests.push(`${req.method} ${req.url}`);
    if (req.method === "PROPFIND") {
      res.writeHead(207, { "Content-Type": "application/xml" });
      res.end(`<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/1700000000100.venera</d:href></d:response>
</d:multistatus>`);
      return;
    }
    if (req.method === "GET" && req.url === "/1700000000100.venera") {
      res.writeHead(200, { "Content-Type": "application/octet-stream" });
      res.end(backupBytes);
      return;
    }
    res.writeHead(404);
    res.end();
  });
  const upstreamUrl = await listen(upstream);
  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);

  try {
    const syncResponse = await fetch(`${helperUrl}/api/server-db/sync/webdav`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        profile: "reader",
        url: upstreamUrl,
        user: "user",
        pass: "pass",
      }),
    });
    assert.equal(syncResponse.status, 200);
    const syncPayload = await syncResponse.json();
    assert.equal(syncPayload.ok, true);
    assert.equal(syncPayload.skipped, false);
    assert.equal(syncPayload.remoteFileName, "1700000000100.venera");
    assert.equal(syncPayload.written.writtenDatabases, 1);
    assert.equal(syncPayload.written.writtenAppdata, true);
    assert.equal(Object.hasOwn(syncPayload, "dataBase64"), false);

    const storedDb = await readFile(
      join(serverDataDir, "profiles", "reader", "db", "history.db"),
    );
    assert.deepEqual(storedDb, historyDb);

    const dumpResponse = await fetch(`${helperUrl}/api/server-db/dump`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", database: "history.db" }),
    });
    assert.equal(dumpResponse.status, 200);
    const dumpPayload = await dumpResponse.json();
    assert.equal(dumpPayload.tables[0].rows[0][1], "server stored history");

    const appdataResponse = await fetch(`${helperUrl}/api/server-db/appdata`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader" }),
    });
    assert.equal(appdataResponse.status, 200);
    assert.deepEqual((await appdataResponse.json()).data, { settings: {} });

    const statusPayload = await (
      await fetch(`${helperUrl}/api/server-db/status?profile=reader`)
    ).json();
    assert.equal(statusPayload.initialized, true);
    assert.equal(statusPayload.databases["history.db"].exists, true);
    assert.equal(statusPayload.metadata.sha256, syncPayload.sha256);

    const historyResponse = await fetch(`${helperUrl}/api/server-db/history/list`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", limit: 20 }),
    });
    assert.equal(historyResponse.status, 200);
    const historyPayload = await historyResponse.json();
    assert.equal(historyPayload.ok, true);
    assert.equal(historyPayload.total, 1);
    assert.equal(historyPayload.items[0].title, "server stored history");
    assert.deepEqual(historyPayload.items[0].readEpisode, []);

    assert.deepEqual(seenRequests, [
      "PROPFIND /",
      "GET /1700000000100.venera",
    ]);

    seenRequests.length = 0;
    const secondSyncResponse = await fetch(
      `${helperUrl}/api/server-db/sync/webdav`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          profile: "reader",
          url: upstreamUrl,
          user: "user",
          pass: "pass",
        }),
      },
    );
    assert.equal(secondSyncResponse.status, 200);
    const secondSyncPayload = await secondSyncResponse.json();
    assert.equal(secondSyncPayload.skipped, true);
    assert.equal(secondSyncPayload.reason, "server-db-up-to-date");
    assert.deepEqual(seenRequests, ["PROPFIND /"]);
  } finally {
    await close(helper);
    await close(upstream);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db history write APIs upsert, delete and clear rows", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);

  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", ...body }),
    });

  try {
    const upsertResponse = await post("/api/server-db/history/upsert", {
      history: {
        id: "comic-1",
        title: "first title",
        subtitle: "sub",
        cover: "cover.jpg",
        time: 1000,
        type: 1,
        ep: 2,
        page: 3,
        readEpisode: ["1", "2"],
        max_page: 8,
        chapter_group: 4,
      },
    });
    assert.equal(upsertResponse.status, 200);
    assert.equal((await upsertResponse.json()).ok, true);

    const replaceResponse = await post("/api/server-db/history/upsert", {
      history: {
        id: "comic-1",
        title: "second title",
        time: 2000,
        type: 1,
        ep: 5,
        page: 6,
        readEpisode: [],
      },
    });
    assert.equal(replaceResponse.status, 200);

    let listPayload = await (
      await post("/api/server-db/history/list", { limit: 20 })
    ).json();
    assert.equal(listPayload.total, 1);
    assert.equal(listPayload.items[0].title, "second title");
    assert.equal(listPayload.items[0].time, 2000);
    assert.equal(listPayload.items[0].ep, 5);

    const deleteResponse = await post("/api/server-db/history/delete", {
      id: "comic-1",
      type: 1,
    });
    assert.equal(deleteResponse.status, 200);
    listPayload = await (
      await post("/api/server-db/history/list", { limit: 20 })
    ).json();
    assert.equal(listPayload.total, 0);

    await post("/api/server-db/history/upsert", {
      history: { id: "comic-2", title: "kept", time: 3000, type: 2 },
    });
    const clearResponse = await post("/api/server-db/history/clear", {});
    assert.equal(clearResponse.status, 200);
    listPayload = await (
      await post("/api/server-db/history/list", { limit: 20 })
    ).json();
    assert.equal(listPayload.total, 0);

    const statusPayload = await (
      await fetch(`${helperUrl}/api/server-db/status?profile=reader`)
    ).json();
    assert.equal(statusPayload.metadata.dirty, true);
    assert.equal(statusPayload.metadata.dirtyReason, "history-clear");
  } finally {
    await close(helper);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});
