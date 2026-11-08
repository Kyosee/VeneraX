// Run with Node >= 22.13: node --test test/ohos/device_reader_test.cjs
// Mocks verify ETS conversion and lifecycle; physical volume keys need device tests.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const UP = 16;
const DOWN = 17;

function harness(options = {}) {
  const config = { ...options };
  const methods = new Map();
  const events = new Map();
  const subscriptions = [];
  const removals = [];
  const active = new Map();
  const warnings = [];
  const state = { memoryReads: 0 };

  class MethodChannel {
    constructor(_messenger, name) { methods.set(name, this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  class EventChannel {
    constructor(_messenger, name) { events.set(name, this); }
    setStreamHandler(handler) { this.handler = handler; }
  }

  const context = vm.createContext({
    MethodChannel,
    EventChannel,
    KeyCode: { KEYCODE_VOLUME_UP: UP, KEYCODE_VOLUME_DOWN: DOWN },
    hidebug: {
      getSystemMemInfo() {
        state.memoryReads++;
        if (config.memoryError) throw new Error('Memory unavailable');
        return Object.hasOwn(config, 'memoryInfo')
          ? config.memoryInfo
          : { availableMem: 1024n };
      },
    },
    inputConsumer: {
      on(type, options, callback) {
        assert.equal(type, 'keyPressed');
        assert.ok(options.key === UP || options.key === DOWN);
        assert.equal(options.action, 1);
        assert.equal(options.isRepeat, false);
        subscriptions.push({ key: options.key, callback });
        if (config.failOnKey === options.key) {
          throw Object.assign(new Error('Subscription refused'), { code: 801 });
        }
        active.set(callback, options.key);
      },
      off(type, callback) {
        assert.equal(type, 'keyPressed');
        assert.equal(typeof callback, 'function');
        removals.push(callback);
        if (config.emitDuringOff) callback({});
        if (active.get(callback) === config.failOffKey) {
          throw Object.assign(new Error('Unsubscribe failed'), { code: 801 });
        }
        active.delete(callback);
      },
    },
    console: { warn(message) { warnings.push(message); } },
  });
  const filename = path.resolve(
    __dirname, '../../ohos/entry/src/main/ets/bridge/DeviceServices.ets',
  );
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.DeviceServices = DeviceServices;', context, { filename });
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const device = new context.DeviceServices(engine, {});
  const memory = methods.get('flutter_memory_info')?.handler;
  const volume = events.get('venera/volume')?.handler;
  assert.ok(memory, 'Memory method channel was not registered.');
  assert.ok(volume, 'Volume event channel was not registered.');

  function memoryCall(method = 'getFreePhysicalMemorySize') {
    const replies = [];
    memory.onMethodCall({ method }, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message) { replies.push({ kind: 'error', code, message }); },
      notImplemented() { replies.push({ kind: 'notImplemented' }); },
    });
    return replies;
  }

  function listen() {
    const replies = [];
    volume.onListen(null, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message, details) { replies.push({ kind: 'error', code, message, details }); },
    });
    return replies;
  }

  return {
    active, config, device, events, listen, memoryCall, methods, removals,
    state, subscriptions, volume, warnings,
  };
}

const largestSafeKb = BigInt(Number.MAX_SAFE_INTEGER) / 1024n;
for (const [label, availableMem, expected] of [
  ['ordinary memory', 1536000n, 1572864000],
  ['zero memory', 0n, 0],
  ['largest safely representable KB value', largestSafeKb, Number(largestSafeKb * 1024n)],
  ['negative memory', -1n, null],
  ['one KB beyond the safe byte range', largestSafeKb + 1n, null],
  ['extremely large memory', 1n << 1100n, null],
]) {
  test('memory conversion handles ' + label, () => {
    const h = harness({ memoryInfo: { availableMem } });
    assert.deepEqual(h.memoryCall(), [{ kind: 'success', value: expected }]);
    assert.equal(h.state.memoryReads, 1);
  });
}

for (const [label, options] of [
  ['an SDK exception', { memoryError: true }],
  ['a null SDK result', { memoryInfo: null }],
  ['an absent availableMem field', { memoryInfo: {} }],
  ['a null availableMem field', { memoryInfo: { availableMem: null } }],
]) {
  test('memory unavailable from ' + label + ' returns null once', () => {
    const h = harness(options);
    assert.deepEqual(h.memoryCall(), [{ kind: 'success', value: null }]);
  });
}

test('unknown memory methods return notImplemented without reading the SDK', () => {
  const h = harness();
  assert.deepEqual(h.memoryCall('unknownMethod'), [{ kind: 'notImplemented' }]);
  assert.equal(h.state.memoryReads, 0);
});

test('volume keys use independent callbacks and emit only 1 and 2', () => {
  const h = harness();
  const replies = h.listen();
  const [up, down] = h.subscriptions;
  assert.equal(up.key, UP);
  assert.equal(down.key, DOWN);
  assert.notEqual(up.callback, down.callback);
  up.callback({});
  down.callback({});
  assert.deepEqual(replies, [
    { kind: 'success', value: 1 },
    { kind: 'success', value: 2 },
  ]);
  h.volume.onCancel(null);
  assert.deepEqual(h.removals, [up.callback, down.callback]);
  assert.equal(h.active.size, 0);
});

test('cancel and replacement listeners ignore already queued old callbacks', () => {
  const h = harness({ emitDuringOff: true });
  const first = h.listen();
  const old = [...h.subscriptions];
  h.volume.onCancel(null);
  old.forEach(({ callback }) => callback({}));
  assert.deepEqual(first, []);

  const second = h.listen();
  const replacement = h.subscriptions.slice(2);
  old.forEach(({ callback }) => callback({}));
  assert.deepEqual(second, []);
  replacement[0].callback({});
  replacement[1].callback({});
  assert.deepEqual(second, [
    { kind: 'success', value: 1 },
    { kind: 'success', value: 2 },
  ]);

  const third = h.listen();
  replacement.forEach(({ callback }) => callback({}));
  old.forEach(({ callback }) => callback({}));
  assert.deepEqual(third, []);
  h.subscriptions.at(-1).callback({});
  assert.deepEqual(third, [{ kind: 'success', value: 2 }]);
  h.volume.onCancel(null);
  assert.equal(h.active.size, 0);
});

test('second key subscription failure rolls back the first and permits retry', () => {
  const h = harness({ failOnKey: DOWN, emitDuringOff: true });
  const failed = h.listen();
  const [up, down] = h.subscriptions;
  assert.deepEqual(h.removals, [up.callback]);
  assert.equal(h.active.size, 0);
  up.callback({});
  down.callback({});
  assert.deepEqual(failed, [{
    kind: 'error', code: 'VOLUME_UNAVAILABLE', message: 'Subscription refused', details: 801,
  }]);

  h.config.failOnKey = undefined;
  const retry = h.listen();
  up.callback({});
  down.callback({});
  assert.deepEqual(retry, []);
  h.subscriptions.at(-2).callback({});
  assert.deepEqual(retry, [{ kind: 'success', value: 1 }]);
  h.volume.onCancel(null);
  assert.equal(h.active.size, 0);
});

test('failure removing the first key still cleans up the second and silences both', () => {
  const h = harness({ failOffKey: UP, emitDuringOff: true });
  const replies = h.listen();
  const [up, down] = h.subscriptions;
  h.volume.dispose();
  assert.deepEqual(h.removals, [up.callback, down.callback]);
  assert.equal(h.active.has(down.callback), false);
  assert.equal(h.warnings.length, 1);
  up.callback({});
  down.callback({});
  assert.deepEqual(replies, []);
});

test('device disposal detaches memory and volume channels and cancels keys once', () => {
  const h = harness({ emitDuringOff: true });
  const replies = h.listen();
  const callbacks = h.subscriptions.map((entry) => entry.callback);
  h.device.dispose();
  h.device.dispose();
  assert.equal(h.methods.get('flutter_memory_info').handler, null);
  assert.equal(h.events.get('venera/volume').handler, null);
  assert.deepEqual(h.removals, callbacks);
  callbacks.forEach((callback) => callback({}));
  assert.deepEqual(replies, []);
  assert.equal(h.active.size, 0);
});
