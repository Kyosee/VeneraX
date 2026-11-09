// Run with Node >= 22.13: node --test test/ohos/launcher_icon_service_test.cjs
// Exercise the real ETS bridge; launcher rendering still needs device validation.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const aliases = ['IconOrig', 'IconFlat', 'IconMono', 'IconIllust'];
const flush = () => new Promise((resolve) => setImmediate(resolve));
const success = (value) => [{ kind: 'success', value }];
const declaredIcons = (enabled = '') => aliases.map((iconName, i) => ({
  iconName, iconId: 100 + i, enabled: iconName === enabled,
}));

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function harness(config = {}) {
  const state = { queries: 0, changes: [] };
  const sdk = {
    getAlternateIcons() {
      state.queries++;
      if (config.queryThrow) throw new Error('SDK query failed');
      if (config.queryReject) return Promise.reject(new Error('SDK query failed'));
      return config.queryWait?.promise ?? Promise.resolve(config.icons ?? declaredIcons());
    },
    setAlternateIcon(alias) {
      state.changes.push(alias);
      if (config.setThrow) throw new Error('SDK set failed');
      if (config.setReject) return Promise.reject(new Error('SDK set failed'));
      return config.setWait?.promise ?? Promise.resolve();
    },
  };
  if (config.missingQuery) delete sdk.getAlternateIcons;
  if (config.missingSet) delete sdk.setAlternateIcon;
  const context = vm.createContext({
    bundleManager: config.missingModule ? undefined : sdk,
    $r: (name) => name,
  });
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge/LauncherIconService.ets');
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.LauncherIconService = LauncherIconService;', context, { filename });
  const service = new context.LauncherIconService();

  function call(method, args = {}) {
    const replies = [];
    const handled = service.handleMethodCall({ method, args, argument: (key) => args?.[key] }, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message, details) { replies.push({ kind: 'error', code, message, details }); },
      notImplemented() { replies.push({ kind: 'notImplemented' }); },
    });
    return { handled, replies };
  }
  return { call, config, service, state, startupIcon: () => context.LauncherIconService.getStartupIcon() };
}

test('startup uses the actual enabled launcher icon without changing it', async () => {
  for (const [alias, resource] of [
    ['', 'icon_default'], ['IconOrig', 'icon_orig'], ['IconFlat', 'icon_flat'],
    ['IconMono', 'icon_mono'], ['IconIllust', 'icon_illust'],
  ]) {
    const h = harness({ icons: declaredIcons(alias) });
    assert.equal(await h.startupIcon(), 'app.media.' + resource);
    assert.equal(h.state.queries, 1);
    assert.deepEqual(h.state.changes, []);
  }
});

test('startup uses the default on older systems without the alternate icon API', async () => {
  const h = harness({ missingQuery: true });
  assert.equal(await h.startupIcon(), 'app.media.icon_default');
  assert.equal(h.state.queries, 0);
});

test('startup does not substitute the default after a query failure or unknown enabled icon', async () => {
  for (const config of [
    { queryThrow: true }, { queryReject: true }, { missingModule: true },
    { icons: [{ iconName: 'Other', iconId: 100, enabled: true }] },
  ]) {
    const h = harness(config);
    assert.equal(await h.startupIcon(), undefined);
    assert.deepEqual(h.state.changes, []);
  }
});

test('startup waits for the system result and queries afresh on the next launch', async () => {
  const wait = deferred();
  const h = harness({ queryWait: wait });
  let result = 'pending';
  const pending = h.startupIcon().then((icon) => { result = icon; });
  await flush();
  assert.equal(result, 'pending');
  wait.resolve(declaredIcons('IconFlat'));
  await pending;
  assert.equal(result, 'app.media.icon_flat');
  delete h.config.queryWait;
  h.config.icons = declaredIcons('IconMono');
  assert.equal(await h.startupIcon(), 'app.media.icon_mono');
  assert.equal(h.state.queries, 2);
  assert.deepEqual(h.state.changes, []);
});

test('shared channel leaves unknown methods to the other services', () => {
  const h = harness();
  assert.deepEqual(h.call('getProxy'), { handled: false, replies: [] });
  h.service.dispose();
  assert.deepEqual(h.call('getProxy'), { handled: false, replies: [] });
  assert.equal(h.state.queries, 0);
});

test('both official APIs and all four declarations enable capability without changing the icon', async () => {
  const h = harness();
  const result = h.call('supportsAlternateIcons');
  await flush();
  assert.equal(result.handled, true);
  assert.deepEqual(result.replies, success(true));
  assert.deepEqual(h.state.changes, []);
});

test('old APIs, missing modules and incomplete declarations are unsupported', async () => {
  for (const config of [
    { missingQuery: true }, { missingSet: true }, { missingModule: true },
    { icons: [] }, { icons: declaredIcons().slice(1) },
    { icons: [{ iconName: 'Other', iconId: 100, enabled: true }] },
  ]) {
    const h = harness(config);
    const support = h.call('supportsAlternateIcons');
    const change = h.call('setLauncherIcon', { alias: 'IconOrig' });
    await flush();
    assert.deepEqual(support.replies, success(false));
    assert.deepEqual(change.replies, success(false));
    assert.deepEqual(h.state.changes, []);
  }
});

for (const alias of aliases) {
  test('switches the declared preset ' + alias, async () => {
    const h = harness();
    const result = h.call('setLauncherIcon', { alias });
    await flush();
    assert.deepEqual(h.state.changes, [alias]);
    assert.deepEqual(result.replies, success(true));
  });
}

test('null and empty aliases restore the default through the official empty name', async () => {
  for (const alias of [null, '']) {
    const h = harness({ icons: declaredIcons('IconOrig') });
    const result = h.call('setLauncherIcon', { alias });
    await flush();
    assert.deepEqual(h.state.changes, ['']);
    assert.deepEqual(result.replies, success(true));
  }
});

test('restoring the existing default or current preset is idempotent', async () => {
  for (const alias of ['', ...aliases]) {
    const h = harness({ icons: declaredIcons(alias) });
    const result = h.call('setLauncherIcon', { alias });
    await flush();
    assert.deepEqual(h.state.changes, []);
    assert.deepEqual(result.replies, success(true));
  }
});

test('invalid aliases fail before querying or changing any icon', async () => {
  for (const alias of [undefined, 42, false, {}, [], 'IconDefault', 'Other', 'iconorig', 'IconOrig\0']) {
    const h = harness();
    const result = h.call('setLauncherIcon', { alias });
    await flush();
    assert.equal(result.handled, true);
    assert.equal(result.replies.length, 1);
    assert.equal(result.replies[0].code, 'INVALID_ARGUMENT');
    assert.equal(result.replies[0].details, null);
    assert.equal(h.state.queries, 0);
    assert.deepEqual(h.state.changes, []);
  }
});

test('query failures return unsupported and never report a successful change', async () => {
  for (const config of [{ queryThrow: true }, { queryReject: true }]) {
    const h = harness(config);
    const support = h.call('supportsAlternateIcons');
    const change = h.call('setLauncherIcon', { alias: 'IconOrig' });
    await flush();
    assert.deepEqual(support.replies, success(false));
    assert.deepEqual(change.replies, success(false));
    assert.deepEqual(h.state.changes, []);
  }
});

test('native switch failures return false and release the next request', async () => {
  for (const config of [{ setThrow: true }, { setReject: true }]) {
    const h = harness(config);
    const failed = h.call('setLauncherIcon', { alias: 'IconOrig' });
    await flush();
    assert.deepEqual(failed.replies, success(false));
    h.config.setThrow = false;
    h.config.setReject = false;
    const retry = h.call('setLauncherIcon', { alias: 'IconFlat' });
    await flush();
    assert.deepEqual(retry.replies, success(true));
    assert.deepEqual(h.state.changes, ['IconOrig', 'IconFlat']);
  }
});

test('overlapping changes are rejected while a native switch is pending', async () => {
  const wait = deferred();
  const h = harness({ setWait: wait });
  const first = h.call('setLauncherIcon', { alias: 'IconOrig' });
  await flush();
  const second = h.call('setLauncherIcon', { alias: 'IconFlat' });
  assert.equal(second.replies[0].code, 'LAUNCHER_ICON_BUSY');
  assert.deepEqual(h.state.changes, ['IconOrig']);
  wait.resolve();
  await flush();
  assert.deepEqual(first.replies, success(true));
});

for (const completion of ['resolve', 'reject']) {
  test('dispose finishes pending queries once and ignores their late ' + completion, async () => {
    const wait = deferred();
    const h = harness({ queryWait: wait });
    const support = h.call('supportsAlternateIcons');
    const change = h.call('setLauncherIcon', { alias: 'IconOrig' });
    h.service.dispose();
    h.service.dispose();
    for (const result of [support, change]) {
      assert.equal(result.replies.length, 1);
      assert.equal(result.replies[0].code, 'LAUNCHER_ICON_CLOSED');
    }
    wait[completion](completion === 'resolve' ? declaredIcons() : new Error('Late query failure'));
    await flush();
    assert.equal(support.replies.length, 1);
    assert.equal(change.replies.length, 1);
    assert.deepEqual(h.state.changes, []);
    assert.equal(h.call('supportsAlternateIcons').replies[0].code, 'LAUNCHER_ICON_CLOSED');
    assert.equal(h.call('setLauncherIcon', { alias: null }).replies[0].code, 'LAUNCHER_ICON_CLOSED');
  });

  test('dispose ignores a native switch late ' + completion, async () => {
    const wait = deferred();
    const h = harness({ setWait: wait });
    const result = h.call('setLauncherIcon', { alias: 'IconOrig' });
    await flush();
    assert.deepEqual(h.state.changes, ['IconOrig']);
    h.service.dispose();
    assert.equal(result.replies.length, 1);
    assert.equal(result.replies[0].code, 'LAUNCHER_ICON_CLOSED');
    wait[completion](completion === 'resolve' ? undefined : new Error('Late switch failure'));
    await flush();
    assert.equal(result.replies.length, 1);
  });
}
