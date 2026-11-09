// Run with Node >= 22.13: node --test test/ohos/bridge_test.cjs
// Mocks verify ETS control flow; system authentication and providers need device tests.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
// Values exercised from the public UserAuthenticationKit API.
const codes = {
  SUCCESS: 12500000,
  FAIL: 12500001,
  GENERAL_ERROR: 12500002,
  CANCELED: 12500003,
  TIMEOUT: 12500004,
  TYPE_NOT_SUPPORT: 12500005,
  TRUST_LEVEL_NOT_SUPPORT: 12500006,
  BUSY: 12500007,
  INVALID_PARAMETERS: 12500008,
  LOCKED: 12500009,
  NOT_ENROLLED: 12500010,
  CANCELED_FROM_WIDGET: 12500011,
  PIN_EXPIRED: 12500013,
};
const types = { PIN: 1, FACE: 2, FINGERPRINT: 4 };
const trust = { ATL2: 20000 };

function loadEts(relativePath, name, context) {
  const filename = path.join(root, relativePath);
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(`${javascript}\nglobalThis.loaded${name} = ${name};`, context, { filename });
  return context[`loaded${name}`];
}

function harness(options = {}) {
  const instances = [];
  const channels = [];
  const lifecycle = [];
  const warnings = [];
  const challenges = [];
  const enrolled = new Set(options.enrolled ?? [types.FACE, types.FINGERPRINT, types.PIN]);
  const config = { ...options };
  const failure = () => Object.assign(new Error('Mock SDK failure'), { code: codes.GENERAL_ERROR });
  const userAuth = {
    UserAuthResultCode: codes,
    UserAuthType: types,
    AuthTrustLevel: trust,
    getAvailableStatus(type, level) {
      assert.equal(level, trust.ATL2);
      if (config.availableError) throw config.availableError;
      if (!enrolled.has(type)) {
        throw Object.assign(new Error('Not enrolled'), { code: config.unavailableCode ?? codes.NOT_ENROLLED });
      }
    },
    getUserAuthInstance(authParam, widgetParam) {
      if (config.createError) throw failure();
      const instance = {
        authParam,
        widgetParam,
        callback: undefined,
        savedCallback: undefined,
        starts: 0,
        cancels: 0,
        offs: 0,
        on(event, callback) {
          assert.equal(event, 'result');
          this.callback = callback;
          this.savedCallback = callback;
          if (config.onError) throw failure();
        },
        off(event) {
          assert.equal(event, 'result');
          this.offs++;
          if (config.offError) throw failure();
          this.callback = undefined;
        },
        start() {
          this.starts++;
          if (config.startError) throw failure();
          if (config.startResult !== undefined) this.emit(config.startResult);
        },
        cancel() {
          this.cancels++;
          if (config.cancelResult !== undefined) this.emitLate(config.cancelResult);
          if (config.cancelError) throw failure();
        },
        emit(code) { this.callback?.onResult({ result: code }); },
        // Deliberately bypass off() to model an already queued platform callback.
        emitLate(code) { this.savedCallback?.onResult({ result: code }); },
      };
      instances.push(instance);
      return instance;
    },
  };
  class MethodChannel {
    constructor(messenger, name) {
      this.name = name;
      channels.push(this);
    }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  class FlutterAbility {
    context = { filesDir: '/mock/files', cacheDir: '/mock/cache' };
    configureFlutterEngine() { lifecycle.push('super.configure'); }
    cleanUpFlutterEngine() { lifecycle.push('super.cleanup'); }
    onBackground() { lifecycle.push('super.background'); }
  }
  class Service {
    handleMethodCall() { return false; }
    dispose() { lifecycle.push('service.dispose'); }
  }
  const context = vm.createContext({
    userAuth,
    cryptoFramework: {
      createRandom: () => ({
        generateRandomSync(size) {
          if (config.randomError) throw failure();
          const data = new Uint8Array(size).fill(challenges.length + 1);
          challenges.push(data);
          return { data };
        },
      }),
    },
    MethodChannel,
    FlutterAbility,
    GeneratedPluginRegistrant: { registerWith() { lifecycle.push('plugins.register'); } },
    DeviceServices: Service,
    FileServices: Service,
    ScanService: Service,
    IncomingService: Service,
    BackgroundService: Service,
    LauncherIconService: Service,
    PdfService: Service,
    bundleManager: {},
    console: { warn(message) { warnings.push(message); } },
  });
  const AuthService = loadEts('ohos/entry/src/main/ets/bridge/AuthService.ets', 'AuthService', context);
  const EntryAbility = loadEts('ohos/entry/src/main/ets/entryability/EntryAbility.ets', 'EntryAbility', context);
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  return { AuthService, EntryAbility, challenges, channels, config, engine, instances, lifecycle, warnings };
}

function invoke(service, method = 'authenticate', args = {}) {
  const events = [];
  service.onMethodCall({ method, argument: (key) => ({ localizedReason: 'Unlock test', ...args })[key] }, {
    success: (value) => events.push({ kind: 'success', value }),
    error: (code, message, details) => events.push({ kind: 'error', code, message, details }),
    notImplemented: () => events.push({ kind: 'notImplemented' }),
  });
  return events;
}

function expectError(events, code) {
  assert.equal(events.length, 1);
  assert.equal(events[0].kind, 'error');
  assert.equal(events[0].code, code);
}

function serviceHarness(options) {
  const h = harness(options);
  h.service = new h.AuthService(h.engine);
  return h;
}

test('registers the local_auth method channel', () => {
  const h = serviceHarness();
  assert.equal(h.channels[0].name, 'plugins.flutter.io/local_auth');
  assert.equal(h.channels[0].handler, h.service);
});

for (const [name, code] of Object.entries(codes)) {
  test(`official SDK result ${name} (${code}) only unlocks on SUCCESS`, () => {
    const h = serviceHarness();
    const result = invoke(h.service);
    const instance = h.instances[0];
    instance.emit(code);
    instance.emitLate(codes.SUCCESS);
    assert.deepEqual(result, [{ kind: 'success', value: name === 'SUCCESS' }]);
    assert.equal(instance.offs, 1);
  });
}

for (const code of [0, -1, 12599999, '12500000', true, null, undefined]) {
  test(`unknown or invalid result ${String(code)} stays locked`, () => {
    const h = serviceHarness();
    const result = invoke(h.service);
    h.instances[0].emit(code);
    assert.deepEqual(result, [{ kind: 'success', value: false }]);
  });
}

test('uses a fresh 32-byte challenge and ATL2', () => {
  const h = serviceHarness();
  invoke(h.service);
  const instance = h.instances[0];
  assert.equal(instance.authParam.challenge.byteLength, 32);
  assert.equal(instance.authParam.authTrustLevel, trust.ATL2);
  assert.equal(instance.widgetParam.title, 'Unlock test');
  assert.equal(instance.authParam.reuseUnlockResult, undefined);
  instance.emit(codes.SUCCESS);
  invoke(h.service);
  assert.equal(h.challenges.length, 2);
  assert.notEqual(h.instances[1].authParam.challenge, instance.authParam.challenge);
  assert.equal(h.instances[1].authParam.challenge, h.challenges[1]);
  assert.equal(h.instances[1].starts, 1);
  assert.equal(instance.starts, 1);
});

test('no enrolled credential reports unsupported and no biometrics', () => {
  const h = serviceHarness({ enrolled: [] });
  assert.deepEqual(invoke(h.service, 'isDeviceSupported'), [{ kind: 'success', value: false }]);
  const result = invoke(h.service, 'getAvailableBiometrics');
  assert.equal(result.length, 1);
  assert.equal(result[0].kind, 'success');
  assert.deepEqual(Array.from(result[0].value), []);
  assert.equal(h.instances.length, 0);
});

test('PIN-only device is supported without reporting a biometric', () => {
  const h = serviceHarness({ enrolled: [types.PIN] });
  assert.deepEqual(invoke(h.service, 'isDeviceSupported'), [{ kind: 'success', value: true }]);
  const result = invoke(h.service, 'getAvailableBiometrics');
  assert.deepEqual(Array.from(result[0].value), []);
  assert.equal(h.instances.length, 0);
});

test('biometric listing contains only enrolled face and fingerprint types', () => {
  const h = serviceHarness({ enrolled: [types.FINGERPRINT] });
  const result = invoke(h.service, 'getAvailableBiometrics');
  assert.deepEqual(Array.from(result[0].value), ['fingerprint']);
  assert.equal(h.instances.length, 0);
});

for (const method of ['isDeviceSupported', 'getAvailableBiometrics']) {
  test(`${method} fails closed when SDK capability query is denied`, () => {
    const h = serviceHarness({ availableError: Object.assign(new Error('Permission denied'), { code: 201 }) });
    expectError(invoke(h.service, method), 'AUTH_ERROR');
    assert.equal(h.instances.length, 0);
  });
}

for (const reason of [undefined, null, '', 42, {}, 'x'.repeat(501)]) {
  test(`invalid reason ${typeof reason}/${reason?.length ?? '-'} cannot start authentication`, () => {
    const h = serviceHarness();
    expectError(invoke(h.service, 'authenticate', { localizedReason: reason }), 'AUTH_ARGUMENT');
    assert.equal(h.instances.length, 0);
    assert.equal(h.challenges.length, 0);
  });
}

test('the SDK maximum reason length of 500 characters is accepted', () => {
  const h = serviceHarness();
  const reason = 'x'.repeat(500);
  const result = invoke(h.service, 'authenticate', { localizedReason: reason });
  assert.equal(h.instances[0].widgetParam.title, reason);
  h.instances[0].emit(codes.SUCCESS);
  assert.deepEqual(result, [{ kind: 'success', value: true }]);
});

for (const name of ['TYPE_NOT_SUPPORT', 'TRUST_LEVEL_NOT_SUPPORT', 'NOT_ENROLLED', 'PIN_EXPIRED']) {
  test(`${name} availability errors cannot start authentication`, () => {
    const h = serviceHarness({ enrolled: [], unavailableCode: codes[name] });
    expectError(invoke(h.service), 'AUTH_UNAVAILABLE');
    assert.equal(h.instances.length, 0);
  });
}

test('biometricOnly does not fall back to enrolled PIN', () => {
  const h = serviceHarness({ enrolled: [types.PIN] });
  expectError(invoke(h.service, 'authenticate', { biometricOnly: true }), 'AUTH_UNAVAILABLE');
  assert.equal(h.instances.length, 0);
  const result = invoke(h.service);
  assert.deepEqual(Array.from(h.instances[0].authParam.authType), [types.PIN]);
  h.instances[0].emit(codes.SUCCESS);
  assert.deepEqual(result, [{ kind: 'success', value: true }]);
});

for (const point of ['availableError', 'createError', 'randomError', 'onError', 'startError']) {
  test(`${point} fails closed and allows a later request`, () => {
    const h = serviceHarness({ [point]: Object.assign(new Error('Mock failure'), { code: 201 }) });
    const failed = invoke(h.service);
    expectError(failed, 'AUTH_ERROR');
    for (const instance of h.instances) instance.emitLate(codes.SUCCESS);
    expectError(failed, 'AUTH_ERROR');
    h.config[point] = false;
    const next = invoke(h.service);
    h.instances.at(-1).emit(codes.SUCCESS);
    assert.deepEqual(next, [{ kind: 'success', value: true }]);
  });
}

test('a concurrent request receives AUTH_BUSY and cannot replace the first request', () => {
  const h = serviceHarness();
  const first = invoke(h.service);
  expectError(invoke(h.service), 'AUTH_BUSY');
  assert.equal(h.instances.length, 1);
  h.instances[0].emit(codes.SUCCESS);
  assert.deepEqual(first, [{ kind: 'success', value: true }]);
});

test('synchronous completion from start resolves exactly once', () => {
  const h = serviceHarness({ startResult: codes.SUCCESS });
  const result = invoke(h.service);
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(result, [{ kind: 'success', value: true }]);
});

for (const cancelError of [false, true]) {
  test(`cancel clears pending before synchronous SUCCESS; SDK cancel throws=${cancelError}`, () => {
    const h = serviceHarness({ cancelResult: codes.SUCCESS, cancelError });
    const result = invoke(h.service);
    assert.equal(h.service.cancel(), !cancelError);
    h.instances[0].emitLate(codes.SUCCESS);
    assert.deepEqual(result, [{ kind: 'success', value: false }]);
    assert.equal(h.instances[0].cancels, 1);
    assert.equal(h.instances[0].offs, 1);
  });
}

test('a canceled request cannot finish or clear its replacement request', () => {
  const h = serviceHarness();
  const first = invoke(h.service);
  h.service.cancel();
  const second = invoke(h.service);
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(first, [{ kind: 'success', value: false }]);
  assert.equal(second.length, 0);
  expectError(invoke(h.service), 'AUTH_BUSY');
  h.instances[1].emit(codes.SUCCESS);
  assert.deepEqual(second, [{ kind: 'success', value: true }]);
});

test('stopAuthentication returns cancellation status while authenticate returns false', () => {
  const h = serviceHarness();
  assert.deepEqual(invoke(h.service, 'stopAuthentication'), [{ kind: 'success', value: false }]);
  const pending = invoke(h.service);
  assert.deepEqual(invoke(h.service, 'stopAuthentication'), [{ kind: 'success', value: true }]);
  assert.deepEqual(pending, [{ kind: 'success', value: false }]);
});

test('listener removal failure does not permit a late SUCCESS', () => {
  const h = serviceHarness({ offError: true });
  const result = invoke(h.service);
  h.service.cancel();
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(result, [{ kind: 'success', value: false }]);
  assert.equal(h.warnings.length, 1);
});

test('dispose cancels once, detaches the channel, and rejects future calls', () => {
  const h = serviceHarness();
  const result = invoke(h.service);
  h.service.dispose();
  h.service.dispose();
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(result, [{ kind: 'success', value: false }]);
  assert.equal(h.instances[0].cancels, 1);
  assert.equal(h.channels[0].handler, null);
  expectError(invoke(h.service), 'AUTH_CLOSED');
});

test('EntryAbility registers authentication and cancels before super.onBackground', () => {
  const h = harness();
  const ability = new h.EntryAbility();
  ability.configureFlutterEngine(h.engine);
  const auth = h.channels.find((channel) => channel.name === 'plugins.flutter.io/local_auth');
  assert.ok(auth?.handler instanceof h.AuthService);
  const pending = invoke(auth.handler);
  const cancel = h.instances[0].cancel.bind(h.instances[0]);
  h.instances[0].cancel = () => { h.lifecycle.push('auth.cancel'); cancel(); };
  ability.onBackground();
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(pending, [{ kind: 'success', value: false }]);
  assert.ok(h.lifecycle.indexOf('auth.cancel') < h.lifecycle.indexOf('super.background'));
});

test('EntryAbility cleanup disposes authentication before super and can register again', () => {
  const h = harness();
  const ability = new h.EntryAbility();
  ability.configureFlutterEngine(h.engine);
  const auth = h.channels.find((channel) => channel.name === 'plugins.flutter.io/local_auth');
  const originalService = auth.handler;
  const pending = invoke(originalService);
  ability.cleanUpFlutterEngine(h.engine);
  h.instances[0].emitLate(codes.SUCCESS);
  assert.deepEqual(pending, [{ kind: 'success', value: false }]);
  assert.ok(h.channels.every((channel) => channel.handler === null));
  assert.equal(h.lifecycle.at(-1), 'super.cleanup');
  expectError(invoke(originalService), 'AUTH_CLOSED');
  ability.configureFlutterEngine(h.engine);
  const replacement = h.channels.filter((channel) => channel.name === 'plugins.flutter.io/local_auth').at(-1);
  const next = invoke(replacement.handler);
  h.instances[0].emitLate(codes.SUCCESS);
  assert.equal(next.length, 0);
  h.instances[1].emit(codes.SUCCESS);
  assert.deepEqual(next, [{ kind: 'success', value: true }]);
});

test('disposing while the source opens must not subsequently truncate the export destination', async () => {
  let resolveSource;
  let openedDestination = 0;
  const closed = [];
  const context = vm.createContext({
    fs: {
      OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, TRUNC: 512 },
      open(name) {
        if (name === 'source') return new Promise((resolve) => { resolveSource = resolve; });
        assert.equal(name, 'destination');
        openedDestination++;
        return Promise.resolve({ fd: 2 });
      },
      stat: async () => ({ isFile: () => true }),
      close: async (file) => { closed.push(file.fd); },
    },
    MethodChannel: class { setMethodCallHandler() {} },
    ShareService: class { dispose() {} },
    DirectoryAccess: class { roots = []; dispose() {} },
    console,
  });
  const FileServices = loadEts('ohos/entry/src/main/ets/bridge/FileServices.ets', 'FileServices', context);
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const service = new FileServices({ filesDir: '/mock/files', cacheDir: '/mock/cache' }, engine);
  // Exercise the actual copy routine at its awaited source-open boundary.
  const result = service.copyFile('source', 'destination').catch((error) => error);
  assert.equal(typeof resolveSource, 'function');
  service.dispose();
  resolveSource({ fd: 1 });
  const error = await result;
  assert.match(error.message, /disposed/);
  assert.ok(closed.includes(1));
  assert.equal(openedDestination, 0, 'A disposed export opened its destination with CREATE | TRUNC.');
});
