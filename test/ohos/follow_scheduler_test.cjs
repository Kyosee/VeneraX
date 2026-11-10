// Run with Node >= 22.13: node --test test/ohos/follow_scheduler_test.cjs
// Exercise the actual ETS scheduler with controllable native API boundaries.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const flush = () => new Promise((resolve) => setImmediate(resolve));
const copy = (value) => JSON.parse(JSON.stringify(value));
const success = (value) => [{ kind: 'success', value }];
const SCHEDULER = 'venera/follow_scheduler';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function loadEts(relative, exports, context) {
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets', relative);
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class|const)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + `\nObject.assign(globalThis, { ${exports} });`, context, { filename });
}

function call(handler, method, args = {}) {
  assert.ok(handler, 'Native channel must still be registered');
  const replies = [];
  handler.onMethodCall({ method, argument: (key) => args[key] }, {
    success(value) { replies.push({ kind: 'success', value }); },
    error(code, message, details) { replies.push({ kind: 'error', code, message, details }); },
    notImplemented() { replies.push({ kind: 'notImplemented' }); },
  });
  return replies;
}

function harness(options = {}) {
  const config = { granted: true, ...options };
  const state = {
    works: new Map(), starts: [], stops: [], leases: [], engines: [],
    events: [], timers: new Map(), intents: [], publishes: [], lockOwner: undefined,
  };
  const waiters = [];
  let timerId = 0;
  const abilityContext = { filesDir: '/private/files', cacheDir: '/private/cache' };

  const fs = {
    OpenMode: { CREATE: 1, READ_WRITE: 2 },
    openSync(filename, flags) {
      assert.equal(filename, '/private/files/.follow-scheduler.lock');
      assert.equal(flags, 3);
      if (config.openError) throw new Error('Open unavailable');
      const lease = {
        id: state.leases.length, closed: false,
        tryLock(exclusive) {
          assert.equal(exclusive, true);
          if (state.lockOwner !== undefined) throw new Error('Busy');
          state.lockOwner = lease;
          state.events.push(`locked:${lease.id}`);
        },
        async lock(exclusive) {
          assert.equal(exclusive, true);
          if (config.lockError) throw new Error('Lock unavailable');
          if (state.lockOwner !== undefined) {
            await new Promise((resolve) => waiters.push({ lease, resolve }));
          } else {
            state.lockOwner = lease;
          }
          state.events.push(`locked:${lease.id}`);
        },
      };
      state.leases.push(lease);
      return lease;
    },
    closeSync(lease) {
      assert.equal(lease.closed, false, 'A native lease may only be closed once');
      lease.closed = true;
      state.events.push(`closed:${lease.id}`);
      if (state.lockOwner === lease) {
        const waiting = waiters.shift();
        state.lockOwner = waiting?.lease;
        waiting?.resolve();
      }
    },
  };

  const workScheduler = {
    NetworkType: { NETWORK_TYPE_ANY: 0 },
    async getWorkStatus(id) {
      const work = state.works.get(id);
      if (!work) throw new Error('No registered work');
      return work;
    },
    startWork(work) {
      if (config.startError) throw new Error('Scheduling unavailable');
      state.starts.push(copy(work));
      state.works.set(work.workId, work);
    },
    stopWork(work, cancel) {
      state.stops.push({ work: copy(work), cancel });
      if (cancel) state.works.delete(work.workId);
    },
  };

  class FlutterEngine {
    constructor(context) {
      assert.equal(context, abilityContext);
      this.id = state.engines.length;
      this.channels = new Map();
      this.entrypoints = [];
      this.destroyed = false;
      state.engines.push(this);
    }
    init(context, args, autoRegister) {
      assert.equal(context, abilityContext);
      assert.equal(autoRegister, false);
      if (config.initError) throw new Error('Engine unavailable');
    }
    getDartExecutor() {
      return {
        getBinaryMessenger: () => this,
        executeDartEntrypoint: (entry, args) => this.entrypoints.push(copy({ entry, args })),
      };
    }
    getFlutterLoader() { return { findAppBundlePath: () => '/flutter_assets' }; }
    destroy() {
      assert.equal(this.destroyed, false, 'An engine may only be destroyed once');
      assert.ok(state.lockOwner, 'Dart must stop before its data lease is released');
      this.destroyed = true;
      state.events.push(`destroyed:${this.id}`);
    }
  }

  class MethodChannel {
    constructor(engine, name) {
      this.events = [];
      engine.channels.set(name, this);
    }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { this.events.push({ method, args }); }
  }

  class DartEntrypoint {
    constructor(bundlePath, library, functionName) {
      Object.assign(this, { bundlePath, library, functionName });
    }
  }

  const context = vm.createContext({
    fs, workScheduler, FlutterEngine, MethodChannel, DartEntrypoint,
    ReadingWidgetService: class {
      constructor(filesDir) { assert.equal(filesDir, abilityContext.filesDir); }
    },
    WorkSchedulerExtensionAbility: class {},
    bundleManager: { getBundleInfoForSelfSync: () => ({ name: 'com.github.venera.test', versionName: '2.3.12' }) },
    connection: { getDefaultHttpProxy: async () => ({ host: '', port: 0, exclusionList: [] }) },
    notificationManager: {
      SlotType: { OTHER_TYPES: 65535 },
      ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
      async isNotificationEnabled() {
        if (config.permissionError) throw new Error('Permission unavailable');
        if (config.permissionWait) await config.permissionWait.promise;
        return config.granted;
      },
      async publish(request) {
        state.publishes.push(copy(request));
        if (config.publishError) throw new Error('Publish unavailable');
      },
    },
    wantAgent: {
      OperationType: { START_ABILITY: 1 },
      WantAgentFlags: { UPDATE_PRESENT_FLAG: 3 },
      async getWantAgent(info) {
        state.intents.push(copy(info));
        if (config.intentWait) await config.intentWait.promise;
        if (config.intentError) throw new Error('Intent unavailable');
        return { info };
      },
    },
    setTimeout(callback, delay) {
      const id = ++timerId;
      state.timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) { state.timers.delete(id); },
    console: { info() {}, warn() {} },
  });
  loadEts('bridge/FollowSchedulerService.ets', 'FollowSchedulerService, FOLLOW_WORK_ID', context);
  loadEts('followupdates/FollowUpdatesAbility.ets', 'FollowUpdatesAbility', context);
  const service = new context.FollowSchedulerService('com.github.venera.test', abilityContext.filesDir);
  const ability = new context.FollowUpdatesAbility();
  ability.context = abilityContext;
  const work = { workId: context.FOLLOW_WORK_ID };

  function fire(delay) {
    const timer = [...state.timers.entries()].find(([, item]) => item.delay === delay);
    assert.ok(timer, `Expected an active ${delay}ms timer`);
    state.timers.delete(timer[0]);
    timer[1].callback();
  }

  return {
    ability, service, config, state, work, fire,
    start: () => ability.onWorkStart(work),
    stop: () => ability.onWorkStop(work),
    configure: (enabled) => call(service, 'configure', { enabled }),
    ui: () => call(service, 'acquireUiData'),
    channel: () => state.engines.at(-1).channels.get(SCHEDULER),
    call: (method, args) => call(state.engines.at(-1).channels.get(SCHEDULER).handler, method, args),
  };
}

test('enabling registers one persistent network job; disabling removes it', async () => {
  const h = harness();
  const enabled = h.configure(true);
  const repeated = h.configure(true);
  await flush();
  assert.deepEqual(enabled, success(null));
  assert.deepEqual(repeated, success(null));
  assert.deepEqual(h.state.starts, [{
    workId: 336, bundleName: 'com.github.venera.test', abilityName: 'FollowUpdatesAbility',
    networkType: 0, isPersisted: true, isRepeat: true, repeatCycleTime: 7200000,
  }]);
  const disabled = h.configure(false);
  const alreadyDisabled = h.configure(false);
  await flush();
  assert.deepEqual(disabled, success(null));
  assert.deepEqual(alreadyDisabled, success(null));
  assert.equal(h.state.stops.length, 1);
  assert.equal(h.state.stops[0].cancel, true);
  assert.equal(h.state.works.size, 0);
});

test('configuration errors are reported once and do not poison later calls', async () => {
  const h = harness({ startError: true });
  const failed = h.configure(true);
  await flush();
  assert.equal(failed.length, 1);
  assert.equal(failed[0].code, 'FOLLOW_SCHEDULE_UNAVAILABLE');
  h.config.startError = false;
  const invalid = h.configure('true');
  const valid = h.configure(true);
  await flush();
  assert.equal(invalid[0].kind, 'error');
  assert.deepEqual(valid, success(null));
  assert.equal(h.state.starts.length, 1);
  assert.deepEqual(call(h.service, 'unknown'), [{ kind: 'notImplemented' }]);
});

test('the UI lease blocks background startup and is reused by later UI calls', async () => {
  const h = harness();
  const first = h.ui();
  const second = h.ui();
  await flush();
  assert.deepEqual(first, success(null));
  assert.deepEqual(second, success(null));
  assert.equal(h.state.leases.length, 1);
  h.start();
  assert.equal(h.state.engines.length, 0);
  assert.equal(h.state.leases[1].closed, true);
  assert.equal(h.state.lockOwner, h.state.leases[0]);
  assert.equal(h.state.leases[0].closed, false);
  assert.equal(h.state.stops[0].cancel, false);
});

test('a failed UI lock closes its descriptor and reports failure without bypassing the lease', async () => {
  const h = harness({ lockError: true });
  const denied = h.ui();
  await flush();
  assert.equal(denied[0].code, 'FOLLOW_SCHEDULE_UNAVAILABLE');
  assert.equal(h.state.leases[0].closed, true);
  assert.equal(h.state.lockOwner, undefined);
  h.config.lockError = false;
  const retry = h.ui();
  await flush();
  assert.deepEqual(retry, success(null));
  assert.equal(h.state.lockOwner, h.state.leases[1]);
});

test('UI initialization waits until the worker has destroyed its engine and released data', async () => {
  const h = harness();
  h.configure(true);
  await flush();
  h.start();
  const waiting = h.ui();
  await flush();
  assert.deepEqual(waiting, []);
  assert.equal(h.state.stops.at(-1).cancel, false);
  h.stop();
  h.fire(5000);
  await flush();
  assert.deepEqual(waiting, success(null));
  assert.deepEqual(h.state.events.slice(-3), ['destroyed:0', 'closed:0', 'locked:1']);
  assert.equal(h.state.lockOwner, h.state.leases[1]);
  assert.equal(h.state.works.size, 1);
});

test('the extension starts one independent Dart entrypoint and ignores unrelated or overlapping jobs', () => {
  const h = harness();
  h.ability.onWorkStart({ workId: 999 });
  assert.equal(h.state.leases.length, 0);
  h.start();
  h.start();
  assert.equal(h.state.engines.length, 1);
  assert.equal(h.state.leases.length, 1);
  assert.deepEqual(h.state.engines[0].entrypoints, [{
    entry: { bundlePath: '/flutter_assets', library: '', functionName: 'followUpdatesBackgroundMain' },
    args: ['/private/files', '/private/cache', '2.3.12'],
  }]);
  assert.deepEqual(h.call('ready'), success(false));
});

test('finished acknowledges Dart before destroying the engine and releasing its lease', () => {
  const h = harness();
  h.start();
  const engine = h.state.engines[0];
  assert.deepEqual(h.call('finished'), success(null));
  assert.equal(engine.destroyed, false);
  assert.equal(h.state.leases[0].closed, false);
  h.fire(0);
  assert.equal(engine.destroyed, true);
  assert.deepEqual(h.state.events.slice(-2), ['destroyed:0', 'closed:0']);
  assert.ok([...engine.channels.values()].every((channel) => channel.handler === null));
  assert.equal(h.state.timers.size, 0);
  assert.equal(h.state.stops.at(-1).cancel, false);
});

test('OS stop requests cooperative cancellation once and retains the lease during the grace period', () => {
  const h = harness();
  h.start();
  h.ability.onWorkStop({ workId: 999 });
  assert.deepEqual(h.channel().events, []);
  h.stop();
  h.stop();
  assert.deepEqual(h.channel().events, [{ method: 'stop', args: null }]);
  assert.deepEqual(h.call('ready'), success(true));
  assert.equal(h.state.engines[0].destroyed, false);
  assert.equal(h.state.leases[0].closed, false);
  assert.equal(h.state.timers.size, 1);
  h.fire(5000);
  assert.deepEqual(h.state.events.slice(-2), ['destroyed:0', 'closed:0']);
});

test('the native deadline cancels an unresponsive worker, then forcefully tears it down', () => {
  const h = harness();
  h.start();
  h.fire(100000);
  assert.deepEqual(h.channel().events, [{ method: 'stop', args: null }]);
  assert.equal(h.state.engines[0].destroyed, false);
  h.fire(5000);
  assert.equal(h.state.engines[0].destroyed, true);
  assert.equal(h.state.lockOwner, undefined);
  assert.equal(h.state.timers.size, 0);
});

test('engine initialization failure still destroys the engine before releasing data', () => {
  const h = harness({ initError: true });
  h.start();
  assert.deepEqual(h.state.events.slice(-2), ['destroyed:0', 'closed:0']);
  assert.equal(h.state.lockOwner, undefined);
  assert.equal(h.state.stops.length, 1);
});

test('a delayed finished callback from the previous worker cannot destroy its successor', () => {
  const h = harness();
  h.start();
  h.call('finished');
  h.stop();
  h.fire(5000);
  h.start();
  const current = h.state.engines[1];
  h.fire(0);
  assert.equal(current.destroyed, false);
  assert.equal(h.state.lockOwner, h.state.leases[1]);
  assert.deepEqual(h.call('ready'), success(false));
});

test('a successful completion notification returns true and routes to follow updates', async () => {
  const h = harness();
  h.start();
  const replied = h.call('notify', { status: 'Follow Updates · 2 updates' });
  await flush();
  assert.deepEqual(replied, success(true));
  assert.equal(h.state.publishes.length, 1);
  assert.deepEqual(h.state.publishes[0].content.normal, { title: 'VeneraX', text: 'Follow Updates · 2 updates' });
  assert.deepEqual(h.state.intents[0].wants, [{
    bundleName: 'com.github.venera.test', abilityName: 'EntryAbility',
    parameters: { 'venera.notification.route': 'follow_updates' },
  }]);
});

for (const options of [{ granted: false }, { permissionError: true }, { intentError: true }, { publishError: true }]) {
  test(`notification refusal or failure returns false: ${Object.keys(options)[0]}`, async () => {
    const h = harness(options);
    h.start();
    const replied = h.call('notify', { status: 'Follow Updates · 2 updates' });
    await flush();
    assert.deepEqual(replied, success(false));
    assert.equal(h.state.publishes.length, options.publishError ? 1 : 0);
    assert.equal(h.state.engines[0].destroyed, false);
  });
}

test('malformed completion messages never reach the notification API', async () => {
  const h = harness();
  h.start();
  for (const status of [undefined, 42, 'x'.repeat(257)]) {
    const replied = h.call('notify', { status });
    assert.equal(replied.length, 1);
    assert.equal(replied[0].code, 'INVALID_STATUS');
  }
  await flush();
  assert.equal(h.state.publishes.length, 0);
});

for (const restart of [false, true]) {
  test(`stopping while a notification is pending cannot publish${restart ? ' after a new worker starts' : ''}`, async () => {
    const wait = deferred();
    const h = harness({ intentWait: wait });
    h.start();
    const replied = h.call('notify', { status: 'Follow Updates · 2 updates' });
    await flush();
    h.stop();
    if (restart) {
      h.fire(5000);
      h.start();
    }
    wait.resolve();
    await flush();
    // A destroyed engine cannot receive a MethodResult reply anymore.
    assert.deepEqual(replied, restart ? [] : success(false));
    assert.equal(h.state.publishes.length, 0);
    if (restart) assert.equal(h.state.engines[1].destroyed, false);
  });
}

test('an already stopping worker refuses notifications immediately', async () => {
  const h = harness();
  h.start();
  h.stop();
  const replied = h.call('notify', { status: 'Follow Updates · 2 updates' });
  await flush();
  assert.deepEqual(replied, success(false));
  assert.equal(h.state.intents.length, 0);
  assert.equal(h.state.publishes.length, 0);
});
