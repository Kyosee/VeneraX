// Run with Node >= 22.13: node --test test/ohos/directory_access_test.cjs
// Mocks verify ETS authorization flow, not a device provider's access controls.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const URI = 'file:///storage/selected';
const PATH = '/storage/selected';
const EXISTING = 'file:///storage/existing';
const flushTasks = () => new Promise((resolve) => setImmediate(resolve));

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function harness(options = {}) {
  const config = { ...options };
  const trace = [];
  const warnings = [];
  const gate = deferred();
  const grants = new Set(options.grants ?? []);
  const activated = new Set();
  const revoked = [];
  const saved = options.saved ?? [];
  const state = {
    cached: Array.isArray(saved) ? [...saved] : saved,
    durable: Array.isArray(saved) ? [...saved] : saved,
  };

  async function boundary(stage, uri) {
    trace.push({ stage, uri });
    if (config.hold === stage) await gate.promise;
    if (config.fail === stage) throw new Error('Mock failure: ' + stage);
  }

  function policy(policies) {
    assert.equal(policies.length, 1);
    assert.equal(policies[0].operationMode, 3);
    assert.equal(typeof policies[0].uri, 'string');
    return policies[0].uri;
  }

  const store = {
    async get(key) {
      assert.equal(key, 'uris');
      await boundary('get');
      return Array.isArray(state.cached) ? [...state.cached] : state.cached;
    },
    async put(key, value) {
      assert.equal(key, 'uris');
      await boundary('put');
      state.cached = [...value];
    },
    async flush() {
      await boundary('flush');
      state.durable = [...state.cached];
    },
  };
  const context = vm.createContext({
    canIUse(capability) {
      if (capability === 'SystemCapability.FileManagement.UserFileService.FolderSelection') {
        return config.folderSelection ?? true;
      }
      assert.equal(capability, 'SystemCapability.FileManagement.AppFileService.FolderAuthorization');
      return config.folderAuthorization ?? true;
    },
    preferences: {
      async getPreferences(_context, options) {
        assert.equal(options.name, 'venera_directory_access');
        await boundary('preferences');
        return store;
      },
    },
    fileShare: {
      OperationMode: { READ_MODE: 1, WRITE_MODE: 2 },
      async checkPersistentPermission(policies) {
        const uri = policy(policies);
        await boundary('check', uri);
        return config.checkResult ?? [grants.has(uri)];
      },
      async persistPermission(policies) {
        const uri = policy(policies);
        await boundary('persist', uri);
        grants.add(uri);
      },
      async activatePermission(policies) {
        const uri = policy(policies);
        await boundary('activate', uri);
        assert.ok(grants.has(uri), 'Activation attempted without a persistent grant.');
        activated.add(uri);
      },
      async revokePermission(policies) {
        const uri = policy(policies);
        await boundary('revoke', uri);
        revoked.push(uri);
        grants.delete(uri);
        activated.delete(uri);
      },
    },
    fileUri: {
      FileUri: class {
        constructor(uri) { this.path = config.path ?? uri.slice('file://'.length); }
      },
    },
    fs: {
      async lstat(value) {
        await boundary('lstat', value);
        return {
          isDirectory: () => config.isDirectory ?? true,
          isSymbolicLink: () => config.isSymbolicLink ?? false,
        };
      },
    },
    console: { warn(value) { warnings.push(value); } },
  });
  const filename = path.resolve(
    __dirname, '../../ohos/entry/src/main/ets/bridge/DirectoryAccess.ets',
  );
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.DirectoryAccess = DirectoryAccess;', context, { filename });
  const createService = () => new context.DirectoryAccess({});
  const service = createService();
  return {
    activated, config, createService, gate, grants, revoked, service, state, trace, warnings,
  };
}

function observe(promise) {
  const outcome = { settled: false };
  const done = promise.then(
    (value) => Object.assign(outcome, { settled: true, ok: true, value }),
    (error) => Object.assign(outcome, { settled: true, ok: false, error }),
  );
  return { outcome, done };
}

function expectFailure(outcome) {
  assert.equal(outcome.settled, true);
  assert.equal(outcome.ok, false, 'An unsuccessful authorization returned a path.');
  assert.equal(typeof outcome.error?.message, 'string');
}

test('successful authorization persists, activates, validates and flushes before publishing a root', async () => {
  const h = harness({ path: PATH + '/' });
  assert.equal(await h.service.authorize(URI), PATH);
  assert.deepEqual([...h.service.roots], [PATH]);
  assert.deepEqual(h.state.durable, [URI]);
  assert.ok(h.grants.has(URI));
  assert.ok(h.activated.has(URI));
  assert.deepEqual(h.revoked, []);
  assert.deepEqual(h.trace.map((entry) => entry.stage), [
    'preferences', 'get', 'check', 'persist', 'activate', 'lstat', 'put', 'flush',
  ]);
});

for (const hold of ['check', 'persist', 'activate', 'lstat', 'put', 'flush']) {
  test('authorization publishes no path or root while ' + hold + ' is pending', async () => {
    const h = harness({ hold });
    const pending = observe(h.service.authorize(URI));
    await flushTasks();
    const before = { settled: pending.outcome.settled, roots: [...h.service.roots] };
    assert.ok(h.trace.some((entry) => entry.stage === hold));
    h.gate.resolve();
    await pending.done;
    assert.equal(before.settled, false);
    assert.deepEqual(before.roots, []);
    assert.equal(pending.outcome.ok, true);
    assert.equal(pending.outcome.value, PATH);
    assert.deepEqual([...h.service.roots], [PATH]);
    assert.deepEqual(h.state.durable, [URI]);
  });
}

for (const existed of [false, true]) {
  for (const fail of ['check', 'persist', 'activate', 'lstat', 'put', 'flush']) {
    test('failure at ' + fail + ' preserves existing=' + existed + ' grants without adding roots', async () => {
      const h = harness({ fail, grants: existed ? [URI] : [] });
      const pending = observe(h.service.authorize(URI));
      await pending.done;
      expectFailure(pending.outcome);
      assert.deepEqual([...h.service.roots], []);
      assert.equal(h.grants.has(URI), existed);
      const persisted = !['check', 'persist'].includes(fail);
      assert.deepEqual(h.revoked, persisted && !existed ? [URI] : []);
    });
  }
}

for (const options of [
  { isDirectory: false },
  { isSymbolicLink: true },
  { path: '/' },
  { path: '/storage/../private' },
  { path: '/storage/./selected' },
  { path: '/storage\\selected' },
  { path: '/storage/\u0000selected' },
  { path: 'relative/selected' },
]) {
  test('invalid or inaccessible selected path is rejected: ' + JSON.stringify(options), async () => {
    const h = harness(options);
    const pending = observe(h.service.authorize(URI));
    await pending.done;
    expectFailure(pending.outcome);
    assert.deepEqual([...h.service.roots], []);
    assert.deepEqual(h.revoked, [URI]);
    assert.deepEqual(h.state.durable, []);
  });
}

for (const uri of ['https://example.com/selected', 'content://selected', 'file:///bad\u0000']) {
  test('invalid picker URI cannot request a persistent grant: ' + JSON.stringify(uri), async () => {
    const h = harness();
    await assert.rejects(h.service.authorize(uri));
    assert.deepEqual([...h.service.roots], []);
    assert.equal(h.trace.some((entry) => entry.stage === 'persist'), false);
    assert.equal(h.grants.size, 0);
  });
}

for (const capability of ['folderSelection', 'folderAuthorization']) {
  test('unsupported ' + capability + ' does not request or publish authorization', async () => {
    const h = harness({ [capability]: false, saved: [EXISTING], grants: [EXISTING] });
    assert.equal(h.service.supported(), false);
    assert.equal(await h.service.restore(), 1);
    await assert.rejects(h.service.authorize(URI));
    assert.deepEqual([...h.service.roots], []);
    assert.deepEqual(h.state.cached, [EXISTING]);
    assert.equal(h.trace.some((entry) => entry.stage === 'persist' || entry.stage === 'activate'), false);
  });
}

test('restart restore checks persistent permission before activation and does not rewrite saved URIs', async () => {
  const h = harness();
  await h.service.authorize(URI);
  h.service.dispose();
  h.activated.clear();
  h.trace.length = 0;
  const restarted = h.createService();
  assert.equal(await restarted.restore(), 0);
  assert.deepEqual([...restarted.roots], [PATH]);
  assert.deepEqual(h.trace.map((entry) => entry.stage), [
    'preferences', 'get', 'check', 'activate', 'lstat',
  ]);
  assert.deepEqual(h.state.durable, [URI]);
});

test('revoked saved authorization stays recorded but cannot enter roots or activate', async () => {
  const h = harness({ saved: [URI, EXISTING], grants: [EXISTING] });
  assert.equal(await h.service.restore(), 1);
  assert.deepEqual([...h.service.roots], ['/storage/existing']);
  assert.deepEqual(h.state.cached, [URI, EXISTING]);
  assert.deepEqual(h.state.durable, [URI, EXISTING]);
  assert.equal(h.trace.some((entry) => entry.stage === 'activate' && entry.uri === URI), false);
  assert.equal(h.trace.some((entry) => entry.stage === 'put' || entry.stage === 'flush'), false);
  assert.deepEqual(h.revoked, []);
});

for (const fail of ['check', 'activate', 'lstat']) {
  test('restore failure at ' + fail + ' keeps saved URI but publishes no root', async () => {
    const h = harness({ fail, saved: [URI], grants: [URI] });
    assert.equal(await h.service.restore(), 1);
    assert.deepEqual([...h.service.roots], []);
    assert.deepEqual(h.state.cached, [URI]);
    assert.deepEqual(h.state.durable, [URI]);
    assert.deepEqual(h.revoked, []);
  });
}

test('a failed new grant leaves previously restored roots and grants unchanged', async () => {
  const h = harness({ saved: [EXISTING], grants: [EXISTING] });
  await h.service.restore();
  h.config.fail = 'activate';
  await assert.rejects(h.service.authorize(URI));
  assert.deepEqual([...h.service.roots], ['/storage/existing']);
  assert.deepEqual([...h.grants], [EXISTING]);
  assert.deepEqual(h.state.durable, [EXISTING]);
  assert.deepEqual(h.revoked, [URI]);
});

for (const hold of ['check', 'persist', 'activate', 'lstat', 'put', 'flush']) {
  test('dispose during authorization ' + hold + ' prevents late success and root repopulation', async () => {
    const h = harness({ hold });
    const pending = observe(h.service.authorize(URI));
    await flushTasks();
    assert.ok(h.trace.some((entry) => entry.stage === hold));
    h.service.dispose();
    h.gate.resolve();
    await pending.done;
    expectFailure(pending.outcome);
    assert.match(pending.outcome.error.message, /disposed/);
    assert.deepEqual([...h.service.roots], []);
    assert.equal(h.grants.has(URI), false);
    assert.deepEqual(h.revoked, hold === 'check' ? [] : [URI]);
  });
}

for (const hold of ['preferences', 'get', 'check', 'activate', 'lstat']) {
  test('dispose during restoration ' + hold + ' prevents late success and root repopulation', async () => {
    const h = harness({ hold, saved: [URI], grants: [URI] });
    const pending = observe(h.service.restore());
    await flushTasks();
    assert.ok(h.trace.some((entry) => entry.stage === hold));
    h.service.dispose();
    h.gate.resolve();
    await pending.done;
    expectFailure(pending.outcome);
    assert.match(pending.outcome.error.message, /disposed/);
    assert.deepEqual([...h.service.roots], []);
    assert.deepEqual(h.revoked, []);
    assert.deepEqual(h.state.cached, [URI]);
  });
}

test('dispose while checking a saved grant does not start a later activation', async () => {
  const h = harness({ hold: 'check', saved: [URI], grants: [URI] });
  const pending = observe(h.service.restore());
  await flushTasks();
  h.service.dispose();
  h.gate.resolve();
  await pending.done;
  expectFailure(pending.outcome);
  assert.equal(h.trace.some((entry) => entry.stage === 'activate'), false);
  assert.deepEqual([...h.service.roots], []);
});

test('a failed preferences flush cannot authorize a new root through the shared preferences cache', async () => {
  const h = harness({ fail: 'flush', grants: [URI] });
  await assert.rejects(h.service.authorize(URI));
  assert.deepEqual([...h.service.roots], []);
  assert.deepEqual(h.revoked, []);
  h.config.fail = undefined;
  const restarted = h.createService();
  await restarted.restore();
  assert.deepEqual([...restarted.roots], [], 'A failed registration leaked into a replacement service.');
  assert.deepEqual(h.state.cached, []);
});

test('dispose clears roots in place and later authorization cannot restore them', async () => {
  const h = harness();
  await h.service.authorize(URI);
  const roots = h.service.roots;
  h.service.dispose();
  h.service.dispose();
  await assert.rejects(h.service.authorize(EXISTING));
  assert.equal(h.service.roots, roots);
  assert.deepEqual([...roots], []);
  assert.deepEqual(h.revoked, []);
});
