import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
    { name: "comic_source/demo.js", data: Buffer.from("function demo() {}") },
    { name: "comic_source/demo.data", data: Buffer.from('{"ok":true}') },
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
    assert.equal(syncPayload.written.writtenComicSources, 2);
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

    const comicSourcesPayload = await (
      await fetch(`${helperUrl}/api/server-db/comic-sources`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ profile: "reader" }),
      })
    ).json();
    assert.equal(comicSourcesPayload.ok, true);
    assert.deepEqual(
      comicSourcesPayload.items.map((item) => item.name).sort(),
      ["demo.data", "demo.js"],
    );

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
    await post("/api/server-db/history/upsert", {
      history: { id: "comic-3", title: "removed", time: 4000, type: 2 },
    });
    const { DatabaseSync } = await import("node:sqlite");
    const favoriteDb = new DatabaseSync(
      join(serverDataDir, "profiles", "reader", "db", "local_favorite.db"),
    );
    try {
      favoriteDb.exec(`
        create table "Default" (
          id text,
          name text,
          type int,
          primary key (id, type)
        );
      `);
      favoriteDb
        .prepare('insert into "Default" (id, name, type) values (?, ?, ?);')
        .run("comic-2", "kept", 2);
    } finally {
      favoriteDb.close();
    }
    const clearUnfavoritedResponse = await post(
      "/api/server-db/history/clear-unfavorited",
      {},
    );
    assert.equal(clearUnfavoritedResponse.status, 200);
    assert.equal((await clearUnfavoritedResponse.json()).deleted, 1);
    listPayload = await (
      await post("/api/server-db/history/list", { limit: 20 })
    ).json();
    assert.equal(listPayload.total, 1);
    assert.equal(listPayload.items[0].id, "comic-2");

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

test("server-db favorites read APIs list folders and items", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const profileDbDir = join(serverDataDir, "profiles", "reader", "db");
  await mkdir(profileDbDir, { recursive: true });
  const { DatabaseSync } = await import("node:sqlite");
  const favoriteDb = new DatabaseSync(join(profileDbDir, "local_favorite.db"));
  try {
    favoriteDb.exec(`
      create table folder_order (
        folder_name text primary key,
        order_value int
      );
      create table folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
      create table "Default" (
        id text,
        name text,
        author text,
        type int,
        tags text,
        cover_path text,
        time text,
        display_order int,
        translated_tags text,
        primary key (id, type)
      );
      create table "Later" (
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
    favoriteDb
      .prepare("insert into folder_order values (?, ?);")
      .run("Later", 0);
    favoriteDb
      .prepare("insert into folder_order values (?, ?);")
      .run("Default", 1);
    favoriteDb
      .prepare("insert into folder_sync values (?, ?, ?);")
      .run("Later", "source", "remote");
    favoriteDb
      .prepare(
        'insert into "Default" values (?, ?, ?, ?, ?, ?, ?, ?, ?);',
      )
      .run(
        "comic-1",
        "first",
        "author",
        1,
        "tag-a,tag-b,",
        "cover.jpg",
        "2026-05-15 12:00:00",
        2,
        "translated,",
      );
    favoriteDb
      .prepare(
        'insert into "Later" values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      )
      .run(
        "comic-2",
        "second",
        "author",
        2,
        "",
        "cover2.jpg",
        "2026-05-15 13:00:00",
        1,
        "",
        "2026-05-15 14:00:00",
        1,
        1234,
      );
  } finally {
    favoriteDb.close();
  }

  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);
  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", ...body }),
    });

  try {
    const foldersPayload = await (
      await post("/api/server-db/favorites/folders", {})
    ).json();
    assert.deepEqual(
      foldersPayload.folders.map((folder) => folder.name),
      ["Later", "Default"],
    );
    assert.equal(foldersPayload.folders[0].count, 1);
    assert.equal(foldersPayload.folders[0].sourceKey, "source");
    assert.equal(foldersPayload.folders[0].sourceFolder, "remote");

    const listPayload = await (
      await post("/api/server-db/favorites/list", {
        folder: "Default",
        limit: 10,
      })
    ).json();
    assert.equal(listPayload.total, 1);
    assert.equal(listPayload.items[0].id, "comic-1");
    assert.deepEqual(listPayload.items[0].tags, ["tag-a", "tag-b"]);
    assert.deepEqual(listPayload.items[0].translatedTags, ["translated"]);

    const findPayload = await (
      await post("/api/server-db/favorites/find", { id: "comic-2", type: 2 })
    ).json();
    assert.deepEqual(findPayload.folders, ["Later"]);

    const getPayload = await (
      await post("/api/server-db/favorites/get", {
        folder: "Later",
        id: "comic-2",
        type: 2,
      })
    ).json();
    assert.equal(getPayload.item.name, "second");
    assert.equal(getPayload.item.hasNewUpdate, true);
    assert.equal(getPayload.item.lastCheckTime, 1234);
  } finally {
    await close(helper);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db favorites write APIs create add info tags move copy delete rename reorder", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);
  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "writer", ...body }),
    });

  try {
    const createResponse = await post(
      "/api/server-db/favorites/folder/create",
      { name: "Shelf" },
    );
    assert.equal(createResponse.status, 200);
    assert.equal((await createResponse.json()).name, "Shelf");

    const linkResponse = await post("/api/server-db/favorites/folder/link", {
      folder: "Shelf",
      source: "network-source",
      networkFolder: "Remote Shelf",
    });
    assert.equal(linkResponse.status, 200);
    let foldersPayload = await (
      await post("/api/server-db/favorites/folders", {})
    ).json();
    assert.equal(foldersPayload.folders[0].sourceKey, "network-source");
    assert.equal(foldersPayload.folders[0].sourceFolder, "Remote Shelf");

    const addFirstResponse = await post("/api/server-db/favorites/add", {
      folder: "Shelf",
      order: 10,
      updateTime: "2026-05-15 12:00:00",
      item: {
        id: "comic-a",
        name: "first",
        author: "author-a",
        type: 1,
        tags: ["tag-a", "tag-b"],
        coverPath: "cover-a.jpg",
      },
    });
    assert.equal(addFirstResponse.status, 200);
    const addSecondResponse = await post("/api/server-db/favorites/add", {
      folder: "Shelf",
      order: 20,
      item: {
        id: "comic-b",
        name: "second",
        type: 2,
      },
    });
    assert.equal(addSecondResponse.status, 200);
    const addThirdResponse = await post("/api/server-db/favorites/add", {
      folder: "Shelf",
      order: 40,
      item: {
        id: "comic-c",
        name: "third",
        type: 3,
      },
    });
    assert.equal(addThirdResponse.status, 200);

    const findPayload = await (
      await post("/api/server-db/favorites/find", { id: "comic-a", type: 1 })
    ).json();
    assert.deepEqual(findPayload.folders, ["Shelf"]);

    const getPayload = await (
      await post("/api/server-db/favorites/get", {
        folder: "Shelf",
        id: "comic-a",
        type: 1,
      })
    ).json();
    assert.equal(getPayload.item.name, "first");
    assert.deepEqual(getPayload.item.tags, ["tag-a", "tag-b"]);
    assert.equal(getPayload.item.displayOrder, 10);

    const infoResponse = await post("/api/server-db/favorites/info", {
      folder: "Shelf",
      item: {
        id: "comic-a",
        type: 1,
        name: "first updated",
        author: "author-updated",
        coverPath: "cover-updated.jpg",
        tags: ["info-tag"],
        translatedTags: ["translated-info"],
      },
    });
    assert.equal(infoResponse.status, 200);
    const tagsResponse = await post("/api/server-db/favorites/tags", {
      folder: "Shelf",
      id: "comic-a",
      tags: ["tag-final"],
    });
    assert.equal(tagsResponse.status, 200);
    const updatedGetPayload = await (
      await post("/api/server-db/favorites/get", {
        folder: "Shelf",
        id: "comic-a",
        type: 1,
      })
    ).json();
    assert.equal(updatedGetPayload.item.name, "first updated");
    assert.equal(updatedGetPayload.item.author, "author-updated");
    assert.equal(updatedGetPayload.item.coverPath, "cover-updated.jpg");
    assert.deepEqual(updatedGetPayload.item.tags, ["tag-final"]);
    assert.deepEqual(updatedGetPayload.item.translatedTags, ["translated-info"]);

    let listPayload = await (
      await post("/api/server-db/favorites/list", {
        folder: "Shelf",
        limit: 10,
      })
    ).json();
    assert.equal(listPayload.total, 3);
    assert.deepEqual(
      listPayload.items.map((item) => item.id),
      ["comic-a", "comic-b", "comic-c"],
    );

    const reorderResponse = await post("/api/server-db/favorites/reorder", {
      folder: "Shelf",
      items: [
        { id: "comic-a", type: 1, order: 30 },
        { id: "comic-b", type: 2, order: 5 },
        { id: "comic-c", type: 3, order: 40 },
      ],
    });
    assert.equal(reorderResponse.status, 200);
    listPayload = await (
      await post("/api/server-db/favorites/list", {
        folder: "Shelf",
        limit: 10,
      })
    ).json();
    assert.deepEqual(
      listPayload.items.map((item) => item.id),
      ["comic-b", "comic-a", "comic-c"],
    );

    const moveResponse = await post("/api/server-db/favorites/move", {
      sourceFolder: "Shelf",
      targetFolder: "Archive",
      id: "comic-b",
      type: 2,
    });
    assert.equal(moveResponse.status, 200);

    const batchMoveResponse = await post("/api/server-db/favorites/batch-move", {
      sourceFolder: "Shelf",
      targetFolder: "Archive",
      items: [{ id: "comic-c", type: 3 }],
    });
    assert.equal(batchMoveResponse.status, 200);

    const batchCopyResponse = await post("/api/server-db/favorites/batch-copy", {
      sourceFolder: "Shelf",
      targetFolder: "Archive",
      items: [{ id: "comic-a", type: 1 }],
    });
    assert.equal(batchCopyResponse.status, 200);

    const deleteResponse = await post("/api/server-db/favorites/delete", {
      folder: "Shelf",
      id: "comic-a",
      type: 1,
    });
    assert.equal(deleteResponse.status, 200);

    const renameResponse = await post(
      "/api/server-db/favorites/folder/rename",
      { before: "Shelf", after: "Done" },
    );
    assert.equal(renameResponse.status, 200);

    foldersPayload = await (
      await post("/api/server-db/favorites/folders", {})
    ).json();
    assert.deepEqual(
      foldersPayload.folders.map((folder) => folder.name),
      ["Archive", "Done"],
    );
    assert.equal(foldersPayload.folders[0].count, 3);
    assert.equal(foldersPayload.folders[1].count, 0);
    assert.equal(foldersPayload.folders[1].sourceKey, "network-source");
    assert.equal(foldersPayload.folders[1].sourceFolder, "Remote Shelf");

    listPayload = await (
      await post("/api/server-db/favorites/list", {
        folder: "Archive",
        limit: 10,
      })
    ).json();
    assert.equal(listPayload.total, 3);
    assert.deepEqual(
      listPayload.items.map((item) => item.id),
      ["comic-b", "comic-a", "comic-c"],
    );
    assert.equal(listPayload.items[1].name, "first updated");
    assert.deepEqual(listPayload.items[1].tags, ["tag-final"]);

    const statusPayload = await (
      await fetch(`${helperUrl}/api/server-db/status?profile=writer`)
    ).json();
    assert.equal(statusPayload.metadata.dirty, true);
    assert.equal(statusPayload.metadata.dirtyReason, "favorites-folder-rename");
  } finally {
    await close(helper);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db favorites update-time check-time mark-read read and batch-delete-all", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  const profileDbDir = join(serverDataDir, "profiles", "writer", "db");
  await mkdir(profileDbDir, { recursive: true });
  const { DatabaseSync } = await import("node:sqlite");
  const favoriteDb = new DatabaseSync(join(profileDbDir, "local_favorite.db"));
  try {
    favoriteDb.exec(`
      create table folder_order (
        folder_name text primary key,
        order_value int
      );
      create table folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
      create table "Main" (
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
      create table "Other" (
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
    favoriteDb.prepare("insert into folder_order values (?, ?);").run("Main", 0);
    favoriteDb.prepare("insert into folder_order values (?, ?);").run("Other", 1);
    favoriteDb
      .prepare('insert into "Main" values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);')
      .run(
        "comic-read",
        "read target",
        "author",
        1,
        "",
        "cover.jpg",
        "2026-05-15 10:00:00",
        10,
        "",
        "2026-05-15 09:00:00",
        0,
        111,
      );
    favoriteDb
      .prepare('insert into "Main" values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);')
      .run(
        "comic-anchor",
        "anchor",
        "author",
        3,
        "",
        "cover3.jpg",
        "2026-05-15 09:30:00",
        5,
        "",
        null,
        0,
        null,
      );
    favoriteDb
      .prepare('insert into "Main" values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);')
      .run(
        "comic-sibling",
        "sibling",
        "author",
        2,
        "",
        "cover2.jpg",
        "2026-05-15 11:00:00",
        20,
        "",
        null,
        0,
        null,
      );
    favoriteDb
      .prepare('insert into "Other" values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);')
      .run(
        "comic-read",
        "read target",
        "author",
        1,
        "",
        "cover.jpg",
        "2026-05-15 10:00:00",
        30,
        "",
        "2026-05-15 09:00:00",
        1,
        222,
      );
  } finally {
    favoriteDb.close();
  }

  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);
  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "writer", ...body }),
    });
  const readRows = () => {
    const db = new DatabaseSync(join(profileDbDir, "local_favorite.db"));
    try {
      return {
        mainRead: db
          .prepare('select * from "Main" where id = ? and type = ?;')
          .get("comic-read", 1),
        mainSibling: db
          .prepare('select * from "Main" where id = ? and type = ?;')
          .get("comic-sibling", 2),
        otherRead: db
          .prepare('select * from "Other" where id = ? and type = ?;')
          .get("comic-read", 1),
      };
    } finally {
      db.close();
    }
  };

  try {
    const batchDeleteAllResponse = await post(
      "/api/server-db/favorites/batch-delete-all",
      {
        items: [
          { id: "missing", type: 99 },
          { id: "comic-read", type: 1 },
        ],
      },
    );
    assert.equal(batchDeleteAllResponse.status, 200);
    let rows = readRows();
    assert.equal(rows.mainRead, undefined);
    assert.equal(rows.otherRead, undefined);
    assert.equal(rows.mainSibling.name, "sibling");

    let response = await post("/api/server-db/favorites/update-time", {
      folder: "Main",
      id: "comic-sibling",
      type: 2,
      updateTime: "2026-05-15 12:30:00",
      lastCheckTime: 3000,
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainSibling.last_update_time, "2026-05-15 12:30:00");
    assert.equal(rows.mainSibling.has_new_update, 1);
    assert.equal(rows.mainSibling.last_check_time, 3000);

    response = await post("/api/server-db/favorites/check-time", {
      folder: "Main",
      id: "comic-sibling",
      type: 2,
      lastCheckTime: 4000,
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainSibling.last_check_time, 4000);

    response = await post("/api/server-db/favorites/mark-read", {
      folder: "Main",
      id: "comic-sibling",
      type: 2,
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainSibling.has_new_update, 0);

    response = await post("/api/server-db/favorites/update-time", {
      folder: "Main",
      id: "comic-sibling",
      type: 2,
      updateTime: "2026-05-15 13:00:00",
      lastCheckTime: 5000,
    });
    assert.equal(response.status, 200);

    response = await post("/api/server-db/favorites/read", {
      id: "comic-sibling",
      type: 2,
      moveMode: "none",
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainSibling.time.length, 19);
    assert.equal(rows.mainSibling.display_order, 20);
    assert.equal(rows.mainSibling.has_new_update, 1);

    response = await post("/api/server-db/favorites/read", {
      id: "comic-sibling",
      type: 2,
      moveMode: "start",
      followUpdatesFolder: "Main",
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainSibling.display_order, 4);
    assert.equal(rows.mainSibling.has_new_update, 0);

    response = await post("/api/server-db/favorites/read", {
      id: "comic-anchor",
      type: 3,
      moveMode: "end",
      followUpdatesFolder: "Main",
    });
    assert.equal(response.status, 200);
    rows = readRows();
    assert.equal(rows.mainRead, undefined);
    assert.equal(rows.mainSibling.display_order, 4);
    assert.equal(rows.mainSibling.has_new_update, 0);
    assert.equal(rows.mainSibling.time.length, 19);
    const dbForAnchor = new DatabaseSync(join(profileDbDir, "local_favorite.db"));
    try {
      const anchorRow = dbForAnchor
        .prepare('select * from "Main" where id = ? and type = ?;')
        .get("comic-anchor", 3);
      assert.equal(anchorRow.display_order, 6);
      assert.equal(anchorRow.has_new_update, 0);
      assert.equal(anchorRow.time.length, 19);
    } finally {
      dbForAnchor.close();
    }

    const statusPayload = await (
      await fetch(`${helperUrl}/api/server-db/status?profile=writer`)
    ).json();
    assert.equal(statusPayload.metadata.dirty, true);
    assert.equal(statusPayload.metadata.dirtyReason, "favorites-read");
  } finally {
    await close(helper);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db upload reuses helper-side comic sources", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  let uploaded = null;
  const upstream = createHttpServer(async (req, res) => {
    if (req.method === "PUT" && req.url === "/1700000000300.venera") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      uploaded = Buffer.concat(chunks);
      res.writeHead(201);
      res.end();
      return;
    }
    if (req.method === "PROPFIND") {
      res.writeHead(207, { "Content-Type": "application/xml" });
      res.end(`<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/1700000000300.venera</d:href></d:response>
</d:multistatus>`);
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const upstreamUrl = await listen(upstream);
  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);
  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", ...body }),
    });

  try {
    await post("/api/server-db/history/upsert", {
      history: { id: "comic-1", title: "uploaded history", time: 2000, type: 1 },
    });
    const sourceDir = join(serverDataDir, "profiles", "reader", "comic_source");
    await mkdir(sourceDir, { recursive: true });
    await writeFile(join(sourceDir, "stored.js"), "function stored() {}");
    await writeFile(join(sourceDir, "stored.data"), '{"stored":true}');

    const uploadResponse = await post("/api/server-db/upload/webdav", {
      url: upstreamUrl,
      user: "user",
      pass: "pass",
      fileName: "1700000000300.venera",
      appdata: { settings: {} },
    });
    assert.equal(uploadResponse.status, 200);
    const uploadPayload = await uploadResponse.json();
    assert.equal(uploadPayload.entries.includes("comic_source/stored.js"), true);
    assert.equal(uploadPayload.entries.includes("comic_source/stored.data"), true);
    assert.equal(Buffer.isBuffer(uploaded), true);
    assert.equal(uploaded.includes(Buffer.from("function stored() {}")), true);
    assert.equal(uploaded.includes(Buffer.from('{"stored":true}')), true);
  } finally {
    await close(helper);
    await close(upstream);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});

test("server-db upload builds WebDAV backup from helper-side databases", async () => {
  const serverDataDir = await mkdtemp(join(tmpdir(), "venera-server-db-"));
  let uploaded = null;
  const seenRequests = [];

  const upstream = createHttpServer(async (req, res) => {
    seenRequests.push(`${req.method} ${req.url}`);
    assert.equal(req.headers.authorization, "Basic dXNlcjpwYXNz");

    if (req.method === "PUT" && req.url === "/1700000000200.venera") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      uploaded = Buffer.concat(chunks);
      res.writeHead(201);
      res.end();
      return;
    }

    if (req.method === "PROPFIND") {
      res.writeHead(207, { "Content-Type": "application/xml" });
      res.end(`<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/1700000000200.venera</d:href></d:response>
</d:multistatus>`);
      return;
    }

    res.writeHead(404);
    res.end();
  });

  const upstreamUrl = await listen(upstream);
  const helper = createServer({ serverDataDir });
  const helperUrl = await listen(helper);

  const post = (path, body) =>
    fetch(`${helperUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile: "reader", ...body }),
    });

  try {
    const emptyUploadResponse = await post("/api/server-db/upload/webdav", {
      url: upstreamUrl,
      user: "user",
      pass: "pass",
      fileName: "1700000000200.venera",
      appdata: { settings: {} },
    });
    assert.equal(emptyUploadResponse.status, 409);

    await post("/api/server-db/history/upsert", {
      history: {
        id: "comic-1",
        title: "uploaded history",
        time: 2000,
        type: 1,
      },
    });

    const uploadResponse = await post("/api/server-db/upload/webdav", {
      url: upstreamUrl,
      user: "user",
      pass: "pass",
      fileName: "1700000000200.venera",
      appdata: { settings: { theme: "dark" } },
      comicSources: [
        {
          name: "demo.js",
          dataBase64: Buffer.from("function demo() {}").toString("base64"),
        },
        {
          name: "demo.data",
          dataBase64: Buffer.from("{\"ok\":true}").toString("base64"),
        },
      ],
    });
    assert.equal(uploadResponse.status, 200);
    const uploadPayload = await uploadResponse.json();
    assert.equal(uploadPayload.ok, true);
    assert.equal(uploadPayload.databaseCount, 1);
    assert.equal(uploadPayload.entries.includes("appdata.json"), true);
    assert.equal(uploadPayload.entries.includes("history.db"), true);
    assert.equal(uploadPayload.entries.includes("comic_source/demo.js"), true);
    assert.equal(uploadPayload.entries.includes("comic_source/demo.data"), true);
    assert.equal(uploadPayload.fileName, "1700000000200.venera");
    assert.equal(Buffer.isBuffer(uploaded), true);
    assert.equal(uploaded.includes(Buffer.from('"theme": "dark"')), true);
    assert.equal(uploaded.includes(Buffer.from("function demo() {}")), true);
    assert.equal(uploaded.includes(Buffer.from("{\"ok\":true}")), true);

    const extractResponse = await fetch(`${helperUrl}/sync/webdav/extract-db`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ dataBase64: uploaded.toString("base64") }),
    });
    assert.equal(extractResponse.status, 200);
    const extractPayload = await extractResponse.json();
    assert.equal(
      extractPayload.databases["history.db"].tables[0].rows[0][1],
      "uploaded history",
    );

    const statusPayload = await (
      await fetch(`${helperUrl}/api/server-db/status?profile=reader`)
    ).json();
    assert.equal(statusPayload.metadata.dirty, false);
    assert.equal(statusPayload.metadata.remoteFileName, "1700000000200.venera");
    assert.deepEqual(seenRequests, [
      "PUT /1700000000200.venera",
      "PROPFIND /",
    ]);
  } finally {
    await close(helper);
    await close(upstream);
    await rm(serverDataDir, { recursive: true, force: true });
  }
});
