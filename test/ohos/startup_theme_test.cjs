// Run with Node >= 22.13: node --test test/ohos/startup_theme_test.cjs
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function harness(saved = {}, options = {}) {
  const storage = new Map();
  const pending = { ...saved };
  const resource = { name: 'app.color.start_window_background' };
  const store = {
    getSync: (key, fallback) => pending[key] ?? fallback,
    putSync: (key, value) => { pending[key] = value; },
    async flush() {
      if (options.failFlush) throw new Error('Unavailable');
      Object.assign(saved, pending);
    },
  };
  class MethodChannel { setMethodCallHandler() {} }
  class EventChannel { setStreamHandler() {} }
  const context = vm.createContext({
    preferences: {
      getPreferencesSync(_context, config) {
        assert.equal(config.name, 'venera_appearance');
        if (options.failRead) throw new Error('Unavailable');
        return store;
      },
    },
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    $r: name => { assert.equal(name, resource.name); return resource; },
    MethodChannel, EventChannel,
    console: { warn() {} },
  });
  for (const name of ['StartupTheme', 'DeviceServices']) {
    const filename = path.resolve(__dirname, `../../ohos/entry/src/main/ets/bridge/${name}.ets`);
    const source = readFileSync(filename, 'utf8')
      .replace(/^import\s[\s\S]*?;\r?$/gm, '')
      .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
    vm.runInContext(stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename }) +
      `\nglobalThis.${name} = ${name};`, context, { filename });
  }
  const device = new context.DeviceServices({
    getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }),
  }, {});
  const theme = context.StartupTheme;
  return {
    resource, storage, theme,
    restore: () => theme.restore({}),
    call(mode) {
      return new Promise(resolve => {
        assert.equal(device.handleMethodCall({ method: 'setThemeMode', args: mode }, {
          success: value => resolve({ value }),
          error: code => resolve({ error: code }),
        }), true);
      });
    },
  };
}

test('an independent app theme survives a new native process', async () => {
  const saved = {};
  for (const [mode, color] of [['dark', '#121212'], ['light', '#FFFFFF']]) {
    const running = harness(saved);
    assert.deepEqual(await running.call(mode), { value: null });
    assert.equal(running.storage.get('veneraThemeMode'), mode);
    const restarted = harness(saved);
    restarted.restore();
    assert.equal(restarted.theme.background(restarted.storage.get('veneraThemeMode')), color);
  }
});

test('resetting to system restores a live day/night resource, not a fixed color', async () => {
  const saved = { theme_mode: 'dark' };
  const running = harness(saved);
  await running.call('system');
  const restarted = harness(saved);
  restarted.restore();
  assert.equal(restarted.storage.get('veneraThemeMode'), 'system');
  assert.equal(restarted.theme.background('system'), restarted.resource);
});

test('missing, corrupt, or unreadable preferences fall back without blocking launch', () => {
  for (const saved of [{}, { theme_mode: 0 }, { theme_mode: 'invalid' }]) {
    const h = harness(saved);
    h.restore();
    assert.equal(h.storage.get('veneraThemeMode'), 'system');
  }
  const h = harness({}, { failRead: true });
  h.restore();
  assert.equal(h.storage.get('veneraThemeMode'), 'system');
});

test('malformed channel values cannot change the saved theme', async () => {
  const saved = { theme_mode: 'light' };
  const h = harness(saved);
  for (const mode of [null, 0, {}, 'invalid', '']) {
    assert.deepEqual(await h.call(mode), { error: 'INVALID_ARGUMENT' });
  }
  assert.equal(saved.theme_mode, 'light');
  assert.equal(h.storage.size, 0);
});

test('a persistence failure keeps the current splash updated and reports failure', async () => {
  const saved = { theme_mode: 'light' };
  const h = harness(saved, { failFlush: true });
  assert.deepEqual(await h.call('dark'), { error: 'THEME_UNAVAILABLE' });
  assert.equal(h.storage.get('veneraThemeMode'), 'dark');
  assert.equal(saved.theme_mode, 'light');
});
