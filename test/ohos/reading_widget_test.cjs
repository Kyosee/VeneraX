// Exercise the real ETS implementation at the filesystem and Form Kit boundaries.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');
const flush = () => new Promise(resolve => setImmediate(resolve));
const copy = value => JSON.parse(JSON.stringify(value));

function harness() {
  const contents = new Map();
  contents.set('/private/appdata.json', JSON.stringify({ settings: { authorizationRequired: false } }));
  const handles = new Map();
  const updates = [];
  let nextFd = 1;
  let updateHandler = async () => {};
  const fs = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 0 },
    openSync(filename, flags) {
      if (flags === 0 && !contents.has(filename)) throw new Error('Missing file');
      if (flags !== 0) contents.set(filename, '');
      const file = { fd: nextFd++, filename };
      handles.set(file.fd, file);
      return file;
    },
    writeSync(fd, text) { contents.set(handles.get(fd).filename, text); },
    closeSync(file) { assert.ok(handles.delete(file.fd), 'Descriptor closes once'); },
    renameSync(from, to) { contents.set(to, contents.get(from)); contents.delete(from); },
    readTextSync(filename) {
      if (!contents.has(filename)) throw new Error('Missing file');
      return contents.get(filename);
    },
    statSync(fd) { return { size: contents.get(handles.get(fd).filename).length }; },
  };
  class FormExtensionAbility { context = { filesDir: '/private' }; }
  const context = vm.createContext({
    fs, FormExtensionAbility,
    formInfo: { FormParam: { IDENTITY_KEY: 'id', DIMENSION_KEY: 'size', NAME_KEY: 'name' } },
    formBindingData: { createFormBindingData: data => ({ data: copy(data) }) },
    formProvider: {
      async updateForm(id, binding) {
        updates.push({ id, data: copy(binding.data) });
        return updateHandler(id, binding);
      },
    },
  });
  const names = ['ReadingWidgetData', 'ReadingWidgetStore', 'ReadingWidgetService', 'ReadingFormAbility'];
  for (const name of names) {
    const filename = path.resolve(__dirname, `../../ohos/entry/src/main/ets/widget/${name}.ets`);
    const source = readFileSync(filename, 'utf8')
      .replace(/^import\s[\s\S]*?;\r?$/gm, '')
      .replace(/\bexport\s+(?:default\s+)?(?=class|function)/g, '');
    vm.runInContext(stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename }), context, { filename });
  }
  vm.runInContext('Object.assign(globalThis, { ReadingWidgetStore, ReadingWidgetService, ReadingFormAbility, parseReadingWidgetData });', context);
  function call(service, method, args) {
    const replies = [];
    service.onMethodCall({ method, args }, {
      success(value) { replies.push({ success: value }); },
      error(code) { replies.push({ error: code }); },
      notImplemented() { replies.push({ unimplemented: true }); },
    });
    return replies;
  }
  return { context, contents, handles, updates, call, setUpdateHandler: handler => updateHandler = handler };
}

function snapshot(count = 6, kind = 'history') {
  return JSON.stringify({ kind, locked: false, title: 'Recent reading', emptyText: 'Open VeneraX',
    items: Array.from({ length: count }, (_, i) => ({
      id: `book/${i}?one=1&two=2`, type: 41, title: `Book ${i}`, progress: 'Chapter 2 · Page 7',
      coverPath: `/private/reading_widget_covers/cover-${i}.png`, uri: 'https://untrusted.invalid',
    })),
  });
}

test('bounds images for API 17 and reconstructs destinations from comic identity', () => {
  const h = harness();
  const parsed = h.context.parseReadingWidgetData(snapshot());
  assert.equal(parsed.items.length, 4);
  const uri = new URL(parsed.items[0].uri);
  assert.equal(uri.protocol, 'venerax:');
  assert.equal(uri.hostname, 'reading-widget');
  assert.equal(uri.searchParams.get('id'), 'book/0?one=1&two=2');
  assert.equal(uri.searchParams.get('type'), '41');
  assert.throws(() => h.context.parseReadingWidgetData('{"items":null}'));
});

test('old snapshots and optional reading metadata remain compatible', () => {
  const h = harness();
  const legacy = h.context.parseReadingWidgetData(snapshot(1));
  assert.equal(legacy.items[0].pageProgress, -1);
  assert.equal(legacy.items[0].sourceName, '');
  const data = JSON.parse(snapshot(1));
  Object.assign(data.items[0], { sourceName: 'My source', badge: 'New', pageProgress: 120 });
  const parsed = h.context.parseReadingWidgetData(JSON.stringify(data));
  assert.equal(parsed.items[0].sourceName, 'My source');
  assert.equal(parsed.items[0].badge, 'New');
  assert.equal(parsed.items[0].pageProgress, 100);
  data.items[0].pageProgress = '35';
  assert.equal(h.context.parseReadingWidgetData(JSON.stringify(data)).items[0].pageProgress, -1);
});

test('published forms and snapshots survive a new store instance', async () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.register('12', 4);
  store.save(snapshot());
  const restarted = new h.context.ReadingWidgetStore('/private');
  assert.equal(restarted.hasWidgets(), true);
  await restarted.updateAll();
  assert.equal(h.updates[0].id, '12');
  assert.equal(h.updates[0].data.items.length, 4);
  restarted.remove('12');
  assert.equal(store.hasWidgets(), false);
});

test('image descriptors stay open through transfer and close on rejection', async () => {
  const h = harness();
  h.contents.set('/private/reading_widget_covers/cover-0.png', 'image');
  const store = new h.context.ReadingWidgetStore('/private');
  store.register('14', 2);
  store.save(snapshot(1));
  h.setUpdateHandler(async (_id, binding) => {
    assert.equal(h.handles.size, 1);
    assert.equal(binding.data.items[0].image, 'memory://cover-0.png');
    assert.ok(h.handles.has(binding.data.formImages['cover-0.png']));
    throw new Error('Host temporarily unavailable');
  });
  await assert.rejects(store.update('14'));
  assert.equal(h.handles.size, 0);
});

test('foreign paths never open a descriptor and missing images remain placeholders', async () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.register('15', 4);
  const input = JSON.parse(snapshot(3));
  input.items[0].coverPath = '/private/reading_widget_covers/../appdata.json';
  input.items[1].coverPath = '/outside/cover.png';
  h.contents.set('/outside/cover.png', 'private data');
  store.save(JSON.stringify(input));
  await store.update('15');
  assert.deepEqual(copy(h.updates[0].data.formImages), {});
  assert.ok(h.updates[0].data.items.every(item => item.image === ''));
  assert.equal(h.handles.size, 0);
});

test('a replaced cover receives a new memory name so ArkUI reloads the image', async () => {
  const h = harness();
  h.contents.set('/private/reading_widget_covers/cover-0.png', 'old image');
  h.contents.set('/private/reading_widget_covers/replacement.png', 'new image');
  const store = new h.context.ReadingWidgetStore('/private');
  store.save(snapshot(1));
  await store.update('16');
  const next = JSON.parse(snapshot(1));
  next.items[0].coverPath = '/private/reading_widget_covers/replacement.png';
  store.save(JSON.stringify(next));
  await store.update('16');
  assert.notEqual(h.updates[0].data.items[0].image, h.updates[1].data.items[0].image);
  assert.equal(h.updates[1].data.items[0].image, 'memory://replacement.png');
  assert.equal(h.handles.size, 0);
});

test('initial form image descriptors are released when the extension stops', () => {
  const h = harness();
  h.contents.set('/private/reading_widget_covers/cover-0.png', 'image');
  new h.context.ReadingWidgetStore('/private').save(snapshot(1));
  const ability = new h.context.ReadingFormAbility();
  const binding = ability.onAddForm({ parameters: { id: '18', size: 3 } });
  assert.equal(binding.data.dimension, 3);
  assert.equal(h.handles.size, 1);
  ability.onStop();
  assert.equal(h.handles.size, 0);
});

test('a queued privacy change is delivered after an older in-flight update', async () => {
  const h = harness();
  new h.context.ReadingWidgetStore('/private').register('19', 4);
  const service = new h.context.ReadingWidgetService('/private');
  let release;
  h.setUpdateHandler(() => new Promise(resolve => { release = resolve; }));
  const first = h.call(service, 'update', snapshot(1));
  await flush();
  assert.equal(h.updates[0].data.items.length, 1);
  const masked = h.call(service, 'update', JSON.stringify({ kind: 'history', locked: true, title: 'Recent reading', emptyText: 'Open VeneraX', items: [] }));
  h.setUpdateHandler(async () => {});
  release();
  await flush();
  await flush();
  assert.deepEqual(h.updates.at(-1).data.items, []);
  assert.equal(first.length, 1);
  assert.equal(masked.length, 1);
  assert.equal(h.handles.size, 0);
});

test('one unavailable form does not stop other forms from refreshing', async () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.register('21', 2);
  store.register('22', 4);
  store.save(snapshot(1));
  h.setUpdateHandler(async id => { if (id === '21') throw new Error('Removed'); });
  await store.updateAll();
  assert.deepEqual(h.updates.map(update => update.id), ['21', '22']);
});

test('a restarted form hides a stale snapshot when the persisted app lock is enabled', () => {
  const h = harness();
  h.contents.set('/private/reading_widget_covers/cover-0.png', 'image');
  new h.context.ReadingWidgetStore('/private').save(snapshot(1));
  h.contents.set('/private/appdata.json', JSON.stringify({ settings: { authorizationRequired: true } }));
  const binding = new h.context.ReadingFormAbility().onAddForm({ parameters: { id: '25', size: 2 } });
  assert.deepEqual(copy(binding.data.items), []);
  assert.deepEqual(copy(binding.data.formImages), {});
  assert.equal(h.handles.size, 0);
});

test('missing or unreadable privacy settings never expose the persisted snapshot', () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.save(snapshot(1));
  for (const value of [undefined, '{invalid', '{}', '{"settings":{}}']) {
    if (value === undefined) h.contents.delete('/private/appdata.json');
    else h.contents.set('/private/appdata.json', value);
    const binding = store.binding('26');
    assert.deepEqual(copy(binding.data.data.items), []);
    binding.close();
  }
});

test('a delayed extension update cannot restore content after the app enables its lock', async () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.register('27', 2);
  store.save(snapshot(1));
  let release;
  h.setUpdateHandler(() => new Promise(resolve => { release = resolve; }));
  const pending = new h.context.ReadingWidgetStore('/private').update('27');
  h.contents.set('/private/appdata.json', JSON.stringify({ settings: { authorizationRequired: true } }));
  h.setUpdateHandler(async () => {});
  await store.update('27');
  release();
  await pending;
  assert.deepEqual(h.updates.at(-1).data.items, []);
  assert.equal(h.handles.size, 0);
});

test('form names select independent snapshots and resizing preserves the kind', async () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  const ability = new h.context.ReadingFormAbility();
  const kinds = ['history', 'following', 'updates', 'local'];
  for (const [index, kind] of kinds.entries()) {
    store.save(snapshot(index + 1, kind));
    const data = ability.onAddForm({ parameters: { id: String(30 + index), size: 4, name: 'reading_' + kind } }).data;
    assert.equal(data.kind, kind);
    assert.equal(data.items.length, index + 1);
    assert.equal(data.uri, 'venerax://reading-widget/' + kind);
    assert.equal(store.hasWidgets(kind), true);
    const path = kind === 'history' ? '/read' : '/' + kind + '/read';
    assert.equal(new URL(data.items[0].uri).pathname, path);
  }
  ability.onSizeChanged('33', 2, {});
  await flush();
  assert.equal(h.updates.at(-1).data.kind, 'local');
  assert.equal(h.updates.at(-1).data.items.length, 2);
  store.save(JSON.stringify({ kind: 'history', locked: true, items: [] }));
  await store.updateAll();
  assert.ok(h.updates.slice(-4).every(update => update.data.items.length === 0));
  ability.onStop();
});

test('an interrupted lock and unlock cannot resurrect another card kind', () => {
  const h = harness();
  const store = new h.context.ReadingWidgetStore('/private');
  store.save(snapshot(2, 'following'));
  store.save(JSON.stringify({ kind: 'history', locked: true, items: [] }));
  // Only one of Dart's four unlock messages reached the native process.
  new h.context.ReadingWidgetStore('/private').save(snapshot(1, 'history'));
  const ability = new h.context.ReadingFormAbility();
  const data = ability.onAddForm({ parameters: { id: '39', size: 4, name: 'reading_following' } }).data;
  assert.deepEqual(copy(data.items), []);
  assert.equal(data.kind, 'following');
  ability.onStop();
});
