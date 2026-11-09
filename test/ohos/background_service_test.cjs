// Run with Node >= 22.13: node --test test/ohos/background_service_test.cjs
// Exercise the real ETS coordinator against controllable official SDK mocks.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const flush = () => new Promise((resolve) => setImmediate(resolve));
const copy = (value) => JSON.parse(JSON.stringify(value));
const DOWNLOAD = 'venera/download_keepalive';
const BACKGROUND = 'venera/background_keepalive';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function harness(options = {}) {
  const config = { granted: true, ...options };
  const channels = new Map();
  const active = new Map();
  const starts = [];
  const publishes = [];
  const intents = [];
  const cancelRequests = [];
  const removedNotifications = [];
  const cancelledCallbacks = [];
  const transientRequests = [];
  const transientCancelled = [];
  const state = { stops: 0, permissionRequests: 0, reads: 0, off: 0 };
  const ability = { abilityInfo: { bundleName: 'com.github.venera.test' } };
  let cancellation;

  class MethodChannel {
    constructor(_messenger, name) {
      this.events = [];
      channels.set(name, this);
    }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { this.events.push({ method, args: copy(args) }); }
  }

  const native = {
    requestSuspendDelay(reason, callback) {
      assert.equal(reason, 'VeneraX');
      if (config.transientError) throw new Error('No quota');
      const requestId = 100 + transientRequests.length;
      transientRequests.push({ requestId, callback });
      return { requestId, actualDelayTime: 180000 };
    },
    cancelSuspendDelay(id) { transientCancelled.push(id); },
    on(type, callback) {
      assert.equal(type, 'continuousTaskCancel');
      if (config.subscribeError) throw new Error('Unavailable');
      cancellation = callback;
      cancelledCallbacks.push(callback);
    },
    off(type, callback) {
      assert.equal(type, 'continuousTaskCancel');
      assert.equal(callback, cancellation);
      state.off++;
      cancellation = undefined;
    },
    startBackgroundRunning(context, modes, agent) {
      assert.equal(context, ability);
      assert.deepEqual(copy(modes), ['dataTransfer']);
      assert.ok(agent);
      const task = {
        notificationId: 1000 + starts.length,
        continuousTaskId: 10 + starts.length,
        slotType: 4,
        contentType: 5,
      };
      const request = { task, wait: deferred() };
      starts.push(request);
      active.set(task.continuousTaskId, task);
      if (config.startError) {
        active.delete(task.continuousTaskId);
        return Promise.reject(new Error('Start unavailable'));
      }
      return config.deferStart ? request.wait.promise : Promise.resolve(task);
    },
    async stopBackgroundRunning(context) {
      assert.equal(context, ability);
      state.stops++;
      if (config.stopFailures > 0) {
        config.stopFailures--;
        throw new Error('Stop unavailable');
      }
      if (config.stopWait) await config.stopWait.promise;
      const tasks = [...active.values()];
      active.clear();
      if (config.emitOnStop) tasks.forEach((task) => cancellation?.({ id: task.continuousTaskId, reason: 2 }));
    },
  };
  const notifications = {
    SlotType: { OTHER_TYPES: 65535, LIVE_VIEW: 4 },
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0, NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5 },
    async isNotificationEnabled() {
      state.reads++;
      if (config.readError) throw new Error('Read unavailable');
      return config.granted;
    },
    async requestEnableNotification(context) {
      assert.equal(context, ability);
      state.permissionRequests++;
      if (config.permissionWait) await config.permissionWait.promise;
      if (config.permissionError) throw new Error('Permission refused');
    },
    async publish(request) {
      const snapshot = copy(request);
      publishes.push(snapshot);
      if (config.publishWait) await config.publishWait.promise;
      if (config.publishFailures > 0) {
        config.publishFailures--;
        throw new Error('Publish unavailable');
      }
      if (request.label === config.publishFailureLabel && config.publishFailureLabel !== undefined) {
        throw new Error('Selected notification publish unavailable');
      }
      if (request.content.notificationContentType === 5) {
        assert.ok([...active.values()].some((task) => task.notificationId === request.id));
        assert.equal(request.notificationSlotType, 4);
        assert.equal(request.content.systemLiveView.typeCode, 8);
        assert.equal(request.template.name, 'downloadTemplate');
        assert.ok(request.template.data.title.length);
        assert.ok(request.template.data.fileName.length);
        assert.ok(request.template.data.progressValue >= 0 && request.template.data.progressValue <= 100);
      }
    },
    async cancel(id, label) {
      cancelRequests.push({ id, label });
      if (label === config.cancelFailureLabel && config.cancelFailureLabel !== undefined) {
        throw new Error('Selected notification cancellation unavailable');
      }
      removedNotifications.push({ id, label });
    },
  };
  const context = vm.createContext({
    MethodChannel,
    backgroundTaskManager: native,
    notificationManager: notifications,
    wantAgent: {
      OperationType: { START_ABILITY: 1 },
      WantAgentFlags: { UPDATE_PRESENT_FLAG: 3 },
      async getWantAgent(info) {
        intents.push(copy(info));
        if (config.intentWait) await config.intentWait.promise;
        return { info };
      },
    },
    console,
  });
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge/BackgroundService.ets');
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.BackgroundService = BackgroundService;', context, { filename });
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const service = new context.BackgroundService(ability, engine);
  const handlers = new Map([...channels].map(([name, channel]) => [name, channel.handler]));

  function call(name, method, args = {}) {
    const replies = [];
    handlers.get(name).onMethodCall({ method, args, argument: (key) => args?.[key] }, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message, details) { replies.push({ kind: 'error', code, message, details }); },
      notImplemented() { replies.push({ kind: 'notImplemented' }); },
    });
    return replies;
  }
  function cancel(id) {
    active.delete(id);
    cancellation?.({ id, reason: 1 });
  }
  return {
    active, call, cancel, cancelRequests, cancelledCallbacks, channels, config, intents,
    publishes, removedNotifications, service, starts, state, transientRequests, transientCancelled,
  };
}

const startDownload = (h, progress = 12) => h.call(DOWNLOAD, 'start', { status: 'Download', progress });
const startSync = (h, tag = 'sync_1', progress = 24) => h.call(BACKGROUND, 'update', { tag, status: 'Sync', progress });
const success = (value) => [{ kind: 'success', value }];

test('both channels share one authorization request and do not reprompt after refusal', async () => {
  const wait = deferred();
  const h = harness({ granted: false, permissionWait: wait });
  const first = h.call(DOWNLOAD, 'requestNotification');
  const second = h.call(BACKGROUND, 'requestNotification');
  await flush();
  assert.equal(h.state.permissionRequests, 1);
  assert.equal(first.length, 0);
  assert.equal(second.length, 0);
  wait.resolve();
  await flush();
  assert.deepEqual(first, success(false));
  assert.deepEqual(second, success(false));
  const retry = h.call(BACKGROUND, 'requestNotification');
  const denied = startDownload(h);
  await flush();
  assert.deepEqual(retry, success(false));
  assert.deepEqual(denied, success(false));
  assert.equal(h.state.permissionRequests, 1);
  assert.equal(h.starts.length, 0);
  h.config.granted = true;
  const granted = h.call(DOWNLOAD, 'notificationGranted');
  const authorized = h.call(BACKGROUND, 'requestNotification');
  await flush();
  assert.deepEqual(granted, success(true));
  assert.deepEqual(authorized, success(true));
  assert.equal(h.state.permissionRequests, 1);
});

test('permission API rejection is shared and never retried as a new prompt', async () => {
  const h = harness({ granted: false, permissionError: true });
  const first = h.call(DOWNLOAD, 'requestNotification');
  const second = h.call(BACKGROUND, 'requestNotification');
  await flush();
  assert.deepEqual(first, success(false));
  assert.deepEqual(second, success(false));
  const retry = h.call(DOWNLOAD, 'requestNotification');
  await flush();
  assert.deepEqual(retry, success(false));
  assert.equal(h.state.permissionRequests, 1);
});

test('two transfers share one task, use the first real progress, and stop only after the last removal', async () => {
  const h = harness({ emitOnStop: true });
  const download = startDownload(h);
  const sync = startSync(h);
  await flush();
  assert.deepEqual(download, success(true));
  assert.deepEqual(sync, success(true));
  assert.equal(h.starts.length, 1);
  assert.equal(h.publishes.length, 1);
  assert.equal(h.publishes[0].template.data.progressValue, 12);
  assert.deepEqual(h.intents[0], {
    wants: [{
      bundleName: 'com.github.venera.test', abilityName: 'EntryAbility',
      parameters: { 'venera.notification.route': 'downloading' },
    }],
    actionType: 1, requestCode: 0, actionFlags: [3],
  });
  const stop = h.call(DOWNLOAD, 'stop');
  await flush();
  assert.deepEqual(stop, success(true));
  assert.equal(h.state.stops, 0);
  assert.equal(h.publishes.at(-1).template.data.progressValue, 24);
  const remove = h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  await flush();
  assert.deepEqual(remove, success(true));
  assert.equal(h.state.stops, 1);
  assert.equal(h.active.size, 0);
  assert.deepEqual(h.channels.get(DOWNLOAD).events, []);
  assert.deepEqual(h.channels.get(BACKGROUND).events, []);
});

for (const downloadFirst of [true, false]) {
  test(`the live notification route follows ${downloadFirst ? 'download to sync' : 'sync to download'}`, async () => {
    const h = harness();
    if (downloadFirst) {
      startDownload(h);
      startSync(h);
    } else {
      startSync(h);
      startDownload(h);
    }
    await flush();
    const originalId = h.publishes[0].id;
    const removed = downloadFirst
      ? h.call(DOWNLOAD, 'stop')
      : h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
    await flush();
    const current = h.publishes.at(-1);
    assert.deepEqual(removed, success(true));
    assert.equal(current.content.systemLiveView.text, downloadFirst ? 'Sync' : 'Download');
    assert.equal(current.wantAgent?.info.wants[0].parameters['venera.notification.route'],
      downloadFirst ? 'tasks' : 'downloading');
    assert.equal(current.tapDismissed, false);
    assert.equal(current.id, originalId);
    assert.equal(h.starts.length, 1);
    assert.equal(h.state.stops, 0);
  });
}

for (const action of ['stop', 'dispose', 'cancel']) {
  test(`${action} during a pending notification route change cannot republish`, async () => {
    const h = harness();
    startDownload(h);
    startSync(h);
    await flush();
    const before = h.publishes.length;
    const wait = deferred();
    h.config.intentWait = wait;
    const switching = h.call(DOWNLOAD, 'stop');
    await flush();
    assert.equal(h.publishes.length, before);
    const stopped = action === 'stop' ? h.call(BACKGROUND, 'remove', { tag: 'sync_1' }) : undefined;
    if (action === 'dispose') h.service.dispose();
    if (action === 'cancel') h.cancel(h.starts[0].task.continuousTaskId);
    wait.resolve();
    await flush();
    assert.equal(h.publishes.length, before);
    assert.equal(switching.length, 1);
    if (action === 'dispose') assert.equal(switching[0].code, 'BACKGROUND_CLOSED');
    else assert.deepEqual(switching, success(false));
    if (stopped) assert.deepEqual(stopped, success(true));
    assert.equal(h.active.size, 0);
    assert.equal(h.starts.length, 1);
  });
}

test('a replaced task cannot publish its stale route after the agent resolves', async () => {
  const h = harness();
  startDownload(h);
  startSync(h);
  await flush();
  const before = h.publishes.length;
  const wait = deferred();
  h.config.intentWait = wait;
  h.call(DOWNLOAD, 'stop');
  await flush();
  h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  const fresh = startDownload(h, 30);
  wait.resolve();
  await flush();
  assert.deepEqual(fresh, success(true));
  const updates = h.publishes.slice(before);
  assert.equal(updates.length, 1);
  assert.equal(updates[0].content.systemLiveView.text, 'Download');
  assert.equal(updates[0].wantAgent?.info.wants[0].parameters['venera.notification.route'], 'downloading');
  assert.equal(h.starts.length, 1);
});

test('progress changes publish even when the status text is unchanged', async () => {
  const h = harness();
  startDownload(h, 1.5);
  await flush();
  startDownload(h, 2.25);
  await flush();
  assert.deepEqual(h.publishes.map((item) => item.template.data.progressValue), [1.5, 2.25]);
  assert.equal(h.starts.length, 1);
});

test('stop during start removes the late native task without publishing a progress notification', async () => {
  const h = harness({ deferStart: true });
  const start = startDownload(h);
  await flush();
  const stop = h.call(DOWNLOAD, 'stop');
  h.starts[0].wait.resolve(h.starts[0].task);
  await flush();
  assert.deepEqual(start, success(false));
  assert.deepEqual(stop, success(true));
  assert.equal(h.active.size, 0);
  assert.equal(h.state.stops, 1);
  assert.equal(h.publishes.length, 0);
});

test('dispose replies to every pending call once and cleans up a late start', async () => {
  const h = harness({ deferStart: true });
  const first = startDownload(h);
  await flush();
  const second = startSync(h);
  h.service.dispose();
  h.service.dispose();
  for (const replies of [first, second]) {
    assert.equal(replies.length, 1);
    assert.equal(replies[0].code, 'BACKGROUND_CLOSED');
  }
  assert.equal(h.state.off, 1);
  assert.equal(h.channels.get(DOWNLOAD).handler, null);
  assert.equal(h.channels.get(BACKGROUND).handler, null);
  h.starts[0].wait.resolve(h.starts[0].task);
  await flush();
  assert.equal(first.length, 1);
  assert.equal(second.length, 1);
  assert.equal(h.active.size, 0);
  assert.equal(h.state.stops, 1);
  assert.equal(h.publishes.length, 0);
  assert.equal(startDownload(h)[0].code, 'BACKGROUND_CLOSED');
});

test('dispose while authorization is pending cannot reply twice or start a task', async () => {
  const wait = deferred();
  const h = harness({ granted: false, permissionWait: wait });
  const request = h.call(DOWNLOAD, 'requestNotification');
  await flush();
  h.service.dispose();
  assert.equal(request[0].code, 'BACKGROUND_CLOSED');
  h.config.granted = true;
  wait.resolve();
  await flush();
  assert.equal(request.length, 1);
  assert.equal(h.starts.length, 0);
});

test('publishing failure releases the native task before replying false', async () => {
  const h = harness({ publishFailures: 1 });
  const replies = startDownload(h);
  await flush();
  assert.deepEqual(replies, success(false));
  assert.equal(h.active.size, 0);
  assert.equal(h.state.stops, 1);
  assert.equal(h.service.running, undefined);
});

test('a failed stop retains its handle and the next cleanup retries without creating another task', async () => {
  const h = harness({ stopFailures: 1 });
  startDownload(h);
  await flush();
  const failed = h.call(DOWNLOAD, 'stop');
  await flush();
  assert.deepEqual(failed, success(false));
  assert.ok(h.service.running);
  const retry = h.call(DOWNLOAD, 'stop');
  await flush();
  assert.deepEqual(retry, success(true));
  assert.equal(h.starts.length, 1);
  assert.equal(h.active.size, 0);
});

test('cancellation uses task IDs, not notification IDs, and blocks the affected tags until removal', async () => {
  const h = harness();
  startDownload(h);
  startSync(h);
  await flush();
  const task = h.starts[0].task;
  h.cancel(task.notificationId);
  assert.equal(h.channels.get(DOWNLOAD).events.length, 0);
  assert.equal(h.active.size, 1);
  h.cancel(task.continuousTaskId);
  assert.deepEqual(h.channels.get(DOWNLOAD).events, [{ method: 'cancelled', args: null }]);
  assert.deepEqual(h.channels.get(BACKGROUND).events, [{ method: 'cancelled', args: { tags: ['sync_1'] } }]);
  const download = startDownload(h, 13);
  const sync = startSync(h, 'sync_1', 25);
  await flush();
  assert.deepEqual(download, success(false));
  assert.deepEqual(sync, success(false));
  assert.equal(h.starts.length, 1);
  h.call(DOWNLOAD, 'stop');
  const restarted = startDownload(h, 14);
  await flush();
  assert.deepEqual(restarted, success(true));
  assert.equal(h.starts.length, 2);
  h.cancel(task.continuousTaskId);
  assert.equal(h.channels.get(DOWNLOAD).events.length, 1);
  assert.equal(h.active.size, 1);
  const stillBlocked = startSync(h, 'sync_1', 26);
  await flush();
  assert.deepEqual(stillBlocked, success(false));
  h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  const freshSync = startSync(h, 'sync_1', 27);
  await flush();
  assert.deepEqual(freshSync, success(true));
  assert.equal(h.starts.length, 2);
});

test('cancellation arriving before start resolves cannot resurrect the same task', async () => {
  const h = harness({ deferStart: true });
  const start = startSync(h);
  await flush();
  const request = h.starts[0];
  h.cancel(request.task.continuousTaskId);
  const tick = startSync(h, 'sync_1', 25);
  request.wait.resolve(request.task);
  await flush();
  assert.deepEqual(start, success(false));
  assert.deepEqual(tick, success(false));
  assert.equal(h.starts.length, 1);
  assert.equal(h.active.size, 0);
  assert.equal(h.publishes.length, 0);
  assert.deepEqual(h.channels.get(BACKGROUND).events, [{ method: 'cancelled', args: { tags: ['sync_1'] } }]);
});

test('completion ends the old download lifecycle and permits a later download', async () => {
  const h = harness();
  startDownload(h);
  await flush();
  h.cancel(h.starts[0].task.continuousTaskId);
  h.call(DOWNLOAD, 'complete', { status: 'Finished' });
  const fresh = startDownload(h, 0);
  await flush();
  assert.deepEqual(fresh, success(true));
  assert.equal(h.starts.length, 2);
});

test('a late cancellation from an explicit stop cannot block the following task', async () => {
  const wait = deferred();
  const h = harness({ stopWait: wait, emitOnStop: true });
  startDownload(h);
  await flush();
  const old = h.starts[0].task;
  const stop = h.call(DOWNLOAD, 'stop');
  await flush();
  const next = startSync(h, 'sync_2', 3);
  wait.resolve();
  await flush();
  assert.deepEqual(stop, success(true));
  assert.deepEqual(next, success(true));
  h.cancel(old.continuousTaskId);
  assert.equal(h.active.size, 1);
  assert.deepEqual(h.channels.get(DOWNLOAD).events, []);
  assert.deepEqual(h.channels.get(BACKGROUND).events, []);
});

test('a cancelled old start does not block a tag explicitly removed and re-created meanwhile', async () => {
  const h = harness({ deferStart: true });
  startSync(h);
  await flush();
  const request = h.starts[0];
  h.cancel(request.task.continuousTaskId);
  h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  const fresh = startSync(h, 'sync_1', 4);
  h.config.deferStart = false;
  request.wait.resolve(request.task);
  await flush();
  assert.deepEqual(fresh, success(true));
  assert.equal(h.starts.length, 2);
  assert.equal(h.active.size, 1);
  assert.deepEqual(h.channels.get(BACKGROUND).events, []);
});

for (const action of ['stop', 'dispose']) {
  test(action + ' during a pending publish cleans up after that publish settles', async () => {
    const wait = deferred();
    const h = harness({ publishWait: wait });
    const started = startDownload(h);
    await flush();
    assert.equal(h.publishes.length, 1);
    const stopped = action === 'stop' ? h.call(DOWNLOAD, 'stop') : undefined;
    if (action === 'dispose') h.service.dispose();
    wait.resolve();
    await flush();
    assert.equal(started.length, 1);
    if (action === 'stop') {
      assert.deepEqual(started, success(false));
      assert.deepEqual(stopped, success(true));
    } else {
      assert.equal(started[0].code, 'BACKGROUND_CLOSED');
    }
    assert.equal(h.active.size, 0);
    assert.equal(h.state.stops, 1);
  });
}

test('completion uses an independent fixed ordinary notification and preserves ongoing sync', async () => {
  const h = harness();
  startSync(h);
  startDownload(h);
  await flush();
  assert.equal(h.intents[0].wants[0].parameters['venera.notification.route'], 'tasks');
  const completed = h.call(DOWNLOAD, 'complete', { status: 'Finished' });
  await flush();
  assert.deepEqual(completed, success(true));
  assert.equal(h.active.size, 1);
  const ordinary = h.publishes.filter((request) => request.content.notificationContentType === 0);
  assert.equal(ordinary.length, 1);
  assert.notEqual(ordinary[0].id, h.starts[0].task.notificationId);
  assert.deepEqual(ordinary[0].content.normal, { title: 'VeneraX', text: 'Finished' });
  assert.equal(ordinary[0].wantAgent.info.wants[0].bundleName, 'com.github.venera.test');
  assert.equal(ordinary[0].wantAgent.info.wants[0].abilityName, 'EntryAbility');
  assert.equal(ordinary[0].wantAgent.info.wants[0].parameters['venera.notification.route'], 'downloading');
  h.call(DOWNLOAD, 'complete', { status: 'Finished again' });
  await flush();
  assert.equal(h.publishes.at(-1).id, ordinary[0].id);
  h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  await flush();
  assert.equal(h.active.size, 0);
});

test('dispose during a completion publish removes the late notification and replies once', async () => {
  const wait = deferred();
  const h = harness({ publishWait: wait });
  const completed = h.call(DOWNLOAD, 'complete', { status: 'Finished' });
  await flush();
  assert.equal(h.publishes.length, 1);
  h.service.dispose();
  assert.equal(completed[0].code, 'BACKGROUND_CLOSED');
  wait.resolve();
  await flush();
  assert.equal(completed.length, 1);
  assert.deepEqual(h.removedNotifications, [{ id: h.publishes[0].id, label: h.publishes[0].label }]);
});

test('invalid parameters and unrelated task types never create native tasks', async () => {
  const h = harness();
  const bad = [
    [DOWNLOAD, 'start', {}],
    ...['', ' \n ', 42, 'x'.repeat(2049)].map((status) => [DOWNLOAD, 'start', { status, progress: 1 }]),
    ...[undefined, null, '1', NaN, Infinity, -1, 101].map((progress) => [DOWNLOAD, 'start', { status: 'Task', progress }]),
    ...['sync', 'sync_-1', 'sync_1.5', 'sync_01', 'sync_9007199254740992', 'download', 'import', 'export', 'sync_1\n']
      .map((tag) => [BACKGROUND, 'update', { tag, status: 'Task', progress: 1 }]),
    [BACKGROUND, 'remove', { tag: 'download' }],
    [DOWNLOAD, 'complete', { status: '' }],
  ];
  for (const [channel, method, args] of bad) {
    const replies = h.call(channel, method, args);
    assert.equal(replies.length, 1, method + ': ' + JSON.stringify(args));
    assert.equal(replies[0].code, 'BACKGROUND_ARGUMENT', method + ': ' + JSON.stringify(args));
    assert.equal(replies[0].details, null);
  }
  assert.deepEqual(h.call(DOWNLOAD, 'update'), [{ kind: 'notImplemented' }]);
  assert.deepEqual(h.call(BACKGROUND, 'start'), [{ kind: 'notImplemented' }]);
  await flush();
  assert.equal(h.starts.length, 0);
});

test('at most 32 active tags are admitted, existing updates remain allowed, and boundaries are accepted', async () => {
  const h = harness();
  const admitted = [];
  for (let index = 0; index < 32; index++) admitted.push(startSync(h, 'sync_' + index, index));
  const excess = startDownload(h);
  assert.equal(excess[0].code, 'BACKGROUND_ARGUMENT');
  const updated = h.call(BACKGROUND, 'update', { tag: 'sync_0', status: 'x'.repeat(2048), progress: 100 });
  await flush();
  admitted.forEach((replies) => assert.deepEqual(replies, success(true)));
  assert.deepEqual(updated, success(true));
  assert.equal(h.starts.length, 1);
  assert.equal(h.publishes[0].template.data.progressValue, 100);
  h.call(BACKGROUND, 'remove', { tag: 'sync_31' });
  const next = startDownload(h, 0);
  await flush();
  assert.deepEqual(next, success(true));
});

test('a missing cancellation subscription refuses to start instead of ignoring user dismissal', async () => {
  const h = harness({ subscribeError: true });
  const replies = startDownload(h);
  await flush();
  assert.deepEqual(replies, success(false));
  assert.equal(h.starts.length, 0);
  h.service.dispose();
  assert.equal(h.state.off, 0);
});

const startTranslation = (h, status = 'Translating: 1/10', progress = 10) =>
  h.call(BACKGROUND, 'update', { tag: 'pre_translate', status, progress });

test('translation has its own task notification without pretending to transfer data', async () => {
  const h = harness();
  const started = startTranslation(h);
  await flush();
  assert.deepEqual(started, success(true));
  assert.equal(h.starts.length, 0);
  assert.equal(h.transientRequests.length, 0);
  assert.equal(h.publishes.length, 1);
  const note = h.publishes[0];
  assert.equal(note.content.notificationContentType, 0);
  assert.equal(note.content.normal.text, 'Translating: 1/10');
  assert.equal(note.wantAgent.info.wants[0].parameters['venera.notification.route'], 'tasks');
  startTranslation(h);
  await flush();
  assert.equal(h.publishes.length, 1);
  startTranslation(h, 'Translating: 2/10', 20);
  await flush();
  assert.equal(h.publishes.at(-1).id, note.id);
  const removed = h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
  await flush();
  assert.deepEqual(removed, success(true));
  assert.deepEqual(h.removedNotifications, [{ id: note.id, label: note.label }]);
});

test('translation grace expires once and is not renewed by progress updates', async () => {
  const h = harness();
  startTranslation(h);
  await flush();
  h.service.setForeground(false);
  assert.equal(h.transientRequests.length, 1);
  const grace = h.transientRequests[0];
  grace.callback();
  grace.callback();
  assert.deepEqual(h.transientCancelled, [grace.requestId]);
  assert.deepEqual(h.channels.get(BACKGROUND).events, [{ method: 'translationExpired', args: null }]);
  startTranslation(h, 'Translating: 3/10', 30);
  await flush();
  assert.equal(h.transientRequests.length, 1);
  h.service.setForeground(true);
  assert.equal(h.channels.get(BACKGROUND).events.at(-1).method, 'translationForeground');
  h.service.setForeground(false);
  assert.equal(h.transientRequests.length, 2);
  grace.callback();
  assert.equal(h.channels.get(BACKGROUND).events.length, 2);
});

test('a refused translation grace pauses work without retrying the grant', async () => {
  const h = harness({ transientError: true });
  startTranslation(h);
  await flush();
  h.service.setForeground(false);
  startTranslation(h, 'Translating: 2/10', 20);
  await flush();
  assert.deepEqual(h.channels.get(BACKGROUND).events, [{ method: 'translationExpired', args: null }]);
  assert.equal(h.starts.length, 0);
});

test('background without a registered notification pauses Dart translation safely', async () => {
  const h = harness({ granted: false });
  h.service.setForeground(false);
  h.service.setForeground(false);
  assert.equal(h.transientRequests.length, 0);
  assert.equal(h.publishes.length, 0);
  assert.deepEqual(h.channels.get(BACKGROUND).events, [{ method: 'translationExpired', args: null }]);
  h.service.setForeground(true);
  assert.equal(h.channels.get(BACKGROUND).events.at(-1).method, 'translationForeground');
  h.config.granted = true;
  startTranslation(h);
  await flush();
  h.service.setForeground(false);
  assert.equal(h.transientRequests.length, 1);
});

test('translation cleanup preserves concurrent transfer notification and grant', async () => {
  const h = harness();
  startSync(h);
  startTranslation(h);
  await flush();
  h.service.setForeground(false);
  h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
  await flush();
  assert.equal(h.active.size, 1);
  assert.equal(h.state.stops, 0);
  assert.equal(h.transientCancelled.length, 1);
  h.transientRequests[0].callback();
  assert.deepEqual(h.channels.get(BACKGROUND).events, []);
  assert.equal(h.removedNotifications.length, 1);
  h.call(BACKGROUND, 'remove', { tag: 'sync_1' });
  await flush();
  assert.equal(h.active.size, 0);
});

for (const action of ['remove', 'dispose']) {
  test(`translation ${action} during publish removes the late notification`, async () => {
    const wait = deferred();
    const h = harness({ publishWait: wait });
    const started = startTranslation(h);
    await flush();
    assert.equal(h.publishes.length, 1);
    if (action === 'remove') h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
    else h.service.dispose();
    wait.resolve();
    await flush();
    assert.equal(started.length, 1);
    assert.equal(h.removedNotifications.length, 1);
    assert.equal(h.transientRequests.length, 0);
  });
}

test('translation disposal cancels its grace and ignores later expiry', async () => {
  const h = harness();
  startTranslation(h);
  await flush();
  h.service.setForeground(false);
  h.service.dispose();
  h.transientRequests[0].callback();
  await flush();
  assert.equal(h.transientCancelled.length, 1);
  assert.equal(h.removedNotifications.length, 1);
  assert.deepEqual(h.channels.get(BACKGROUND).events, []);
});

const startFollowUpdate = (h, status = 'Checking updates: 0/10', progress = 0) =>
  h.call(BACKGROUND, 'update', { tag: 'follow_update', status, progress });

test('follow updates publish once per change with their own route and no background grant', async () => {
  const h = harness();
  const started = startFollowUpdate(h);
  await flush();
  assert.deepEqual(started, success(true));
  assert.equal(h.publishes.length, 1);
  const note = h.publishes[0];
  assert.equal(note.notificationSlotType, 65535);
  assert.equal(note.content.notificationContentType, 0);
  assert.deepEqual(note.content.normal, { title: 'VeneraX', text: 'Checking updates: 0/10' });
  assert.equal(note.isAlertOnce, true);
  assert.deepEqual(note.wantAgent.info, {
    wants: [{
      bundleName: 'com.github.venera.test', abilityName: 'EntryAbility',
      parameters: { 'venera.notification.route': 'follow_updates' },
    }],
    actionType: 1, requestCode: 2, actionFlags: [3],
  });
  const duplicate = startFollowUpdate(h);
  await flush();
  assert.deepEqual(duplicate, success(true));
  assert.equal(h.publishes.length, 1);
  const advanced = startFollowUpdate(h, 'Checking updates: 1/10', 10);
  await flush();
  assert.deepEqual(advanced, success(true));
  assert.equal(h.publishes.length, 2);
  assert.equal(h.publishes[1].id, note.id);
  assert.equal(h.publishes[1].label, note.label);
  assert.equal(h.publishes[1].content.normal.text, 'Checking updates: 1/10');
  h.service.setForeground(false);
  assert.equal(h.starts.length, 0);
  assert.equal(h.transientRequests.length, 0);
});

test('follow-update cancellation leaves concurrent download and translation notifications running', async () => {
  const h = harness();
  const download = startDownload(h);
  const translation = startTranslation(h);
  const follow = startFollowUpdate(h);
  await flush();
  for (const reply of [download, translation, follow]) assert.deepEqual(reply, success(true));
  assert.equal(h.publishes.length, 3);
  assert.equal(new Set(h.publishes.map((note) => note.id)).size, 3);
  assert.equal(new Set(h.publishes.map((note) => note.wantAgent.info.requestCode)).size, 3);
  const followNote = h.publishes.find((note) =>
    note.wantAgent.info.wants[0].parameters['venera.notification.route'] === 'follow_updates');
  h.service.setForeground(false);
  assert.equal(h.transientRequests.length, 1);
  const removed = h.call(BACKGROUND, 'remove', { tag: 'follow_update' });
  await flush();
  assert.deepEqual(removed, success(true));
  assert.deepEqual(h.removedNotifications, [{ id: followNote.id, label: followNote.label }]);
  assert.equal(h.active.size, 1);
  assert.equal(h.state.stops, 0);
  assert.equal(h.transientCancelled.length, 0);
  assert.equal(h.publishes.length, 3);
  const translationProgress = startTranslation(h, 'Translating: 2/10', 20);
  const downloadProgress = startDownload(h, 30);
  await flush();
  assert.deepEqual(translationProgress, success(true));
  assert.deepEqual(downloadProgress, success(true));
  assert.equal(h.starts.length, 1);
  assert.equal(h.transientRequests.length, 1);
});

test('ending download and translation cannot remove an ongoing follow-update notification', async () => {
  const h = harness();
  startDownload(h);
  startTranslation(h);
  startFollowUpdate(h);
  await flush();
  const followNote = h.publishes.find((note) =>
    note.wantAgent.info.wants[0].parameters['venera.notification.route'] === 'follow_updates');
  h.service.setForeground(false);
  h.call(DOWNLOAD, 'stop');
  h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
  await flush();
  assert.equal(h.active.size, 0);
  assert.equal(h.state.stops, 1);
  assert.equal(h.transientCancelled.length, 1);
  assert.equal(h.removedNotifications.some((note) => note.id === followNote.id), false);
  const continued = startFollowUpdate(h, 'Checking updates: 2/10', 20);
  await flush();
  assert.deepEqual(continued, success(true));
  assert.equal(h.publishes.at(-1).id, followNote.id);
  assert.equal(h.starts.length, 1);
  assert.equal(h.transientRequests.length, 1);
});

test('follow-update completion replaces progress with a persistent independent result notification', async () => {
  const h = harness();
  startFollowUpdate(h);
  await flush();
  const progressNote = h.publishes[0];
  h.service.setForeground(false);
  const completed = h.call(BACKGROUND, 'complete', { tag: 'follow_update', status: 'Found 2 updates' });
  await flush();
  assert.deepEqual(completed, success(true));
  assert.equal(h.publishes.length, 2);
  const resultNote = h.publishes[1];
  assert.notEqual(resultNote.id, progressNote.id);
  assert.notEqual(resultNote.label, progressNote.label);
  assert.equal(resultNote.notificationSlotType, 65535);
  assert.equal(resultNote.content.notificationContentType, 0);
  assert.deepEqual(resultNote.content.normal, { title: 'VeneraX', text: 'Found 2 updates' });
  assert.equal(resultNote.wantAgent.info.requestCode, 2);
  assert.equal(resultNote.wantAgent.info.wants[0].parameters['venera.notification.route'], 'follow_updates');
  assert.deepEqual(h.removedNotifications, [{ id: progressNote.id, label: progressNote.label }]);
  h.call(BACKGROUND, 'remove', { tag: 'follow_update' });
  await flush();
  startFollowUpdate(h, 'Checking updates: 0/3');
  await flush();
  h.service.dispose();
  await flush();
  assert.equal(h.removedNotifications.some((note) => note.id === resultNote.id), false);
  assert.equal(h.starts.length, 0);
  assert.equal(h.transientRequests.length, 0);
  assert.equal(h.state.permissionRequests, 0);
});

test('follow-update cancellation only removes progress and never publishes a result', async () => {
  const h = harness();
  startFollowUpdate(h);
  await flush();
  const note = h.publishes[0];
  const removed = h.call(BACKGROUND, 'remove', { tag: 'follow_update' });
  const duplicate = h.call(BACKGROUND, 'remove', { tag: 'follow_update' });
  await flush();
  assert.deepEqual(removed, success(true));
  assert.deepEqual(duplicate, success(true));
  assert.equal(h.publishes.length, 1);
  assert.deepEqual(h.removedNotifications, [{ id: note.id, label: note.label }]);
  assert.equal(h.starts.length, 0);
});

test('denied follow-update notifications neither publish nor prompt in the background', async () => {
  const h = harness({ granted: false });
  h.service.setForeground(false);
  const permission = h.call(BACKGROUND, 'requestNotification');
  const update = startFollowUpdate(h);
  const complete = h.call(BACKGROUND, 'complete', { tag: 'follow_update', status: 'Found 2 updates' });
  await flush();
  for (const reply of [permission, update, complete]) assert.deepEqual(reply, success(false));
  assert.equal(h.state.permissionRequests, 0);
  assert.equal(h.publishes.length, 0);
  assert.equal(h.starts.length, 0);
  assert.equal(h.transientRequests.length, 0);
  h.service.setForeground(true);
  const foregroundPermission = h.call(BACKGROUND, 'requestNotification');
  await flush();
  assert.deepEqual(foregroundPermission, success(false));
  assert.equal(h.state.permissionRequests, 1);
  h.config.granted = true;
  startDownload(h);
  await flush();
  assert.equal(h.publishes.length, 1);
  assert.equal(h.publishes[0].wantAgent.info.wants[0].parameters['venera.notification.route'], 'downloading');
});

for (const action of ['remove', 'dispose']) {
  test(`follow-update ${action} during publish removes the late notification and replies once`, async () => {
    const wait = deferred();
    const h = harness({ publishWait: wait });
    const started = startFollowUpdate(h);
    await flush();
    assert.equal(h.publishes.length, 1);
    const note = h.publishes[0];
    const removed = action === 'remove' ? h.call(BACKGROUND, 'remove', { tag: 'follow_update' }) : undefined;
    if (action === 'dispose') h.service.dispose();
    wait.resolve();
    await flush();
    if (action === 'remove') {
      assert.deepEqual(started, success(false));
      assert.deepEqual(removed, success(true));
    } else {
      assert.equal(started.length, 1);
      assert.equal(started[0].code, 'BACKGROUND_CLOSED');
    }
    assert.deepEqual(h.removedNotifications, [{ id: note.id, label: note.label }]);
    assert.equal(h.publishes.length, 1);
    assert.equal(h.starts.length, 0);
    assert.equal(h.transientRequests.length, 0);
  });
}

test('dispose during follow-update completion removes the late result notification', async () => {
  const wait = deferred();
  const h = harness({ publishWait: wait });
  const completed = h.call(BACKGROUND, 'complete', { tag: 'follow_update', status: 'Found 2 updates' });
  await flush();
  assert.equal(h.publishes.length, 1);
  const note = h.publishes[0];
  h.service.dispose();
  wait.resolve();
  await flush();
  assert.equal(completed.length, 1);
  assert.equal(completed[0].code, 'BACKGROUND_CLOSED');
  assert.deepEqual(h.removedNotifications, [{ id: note.id, label: note.label }]);
});

test('invalid follow-update requests cannot publish, remove valid progress, or grant background execution', async () => {
  const h = harness();
  startFollowUpdate(h);
  await flush();
  const bad = [
    ...['follow_updates', 'follow_update\n', 'follow_update_1', '', 42, null].flatMap((tag) => [
      ['update', { tag, status: 'Task', progress: 0 }],
      ['remove', { tag }],
      ['complete', { tag, status: 'Finished' }],
    ]),
    ...['', ' \n ', 42, null, 'x'.repeat(2049)].flatMap((status) => [
      ['update', { tag: 'follow_update', status, progress: 0 }],
      ['complete', { tag: 'follow_update', status }],
    ]),
  ];
  for (const [method, args] of bad) {
    const replies = h.call(BACKGROUND, method, args);
    assert.equal(replies.length, 1, method + ': ' + JSON.stringify(args));
    assert.equal(replies[0].code, 'BACKGROUND_ARGUMENT', method + ': ' + JSON.stringify(args));
  }
  for (const tag of ['pre_translate', 'sync_1']) {
    assert.deepEqual(h.call(BACKGROUND, 'complete', { tag, status: 'Finished' }), [{ kind: 'notImplemented' }]);
  }
  const stillActive = startFollowUpdate(h);
  await flush();
  assert.deepEqual(stillActive, success(true));
  assert.equal(h.publishes.length, 1);
  assert.equal(h.removedNotifications.length, 0);
  assert.equal(h.starts.length, 0);
});

for (const failedTag of ['pre_translate', 'follow_update']) {
  test(`${failedTag} publish failure leaves other tasks successful and completion notifications deliverable`, async () => {
    const failedLabel = failedTag === 'pre_translate' ? 'venera.pre_translate' : 'venera.follow_update';
    const h = harness({ publishFailureLabel: failedLabel });
    const failed = failedTag === 'pre_translate' ? startTranslation(h) : startFollowUpdate(h);
    await flush();
    assert.deepEqual(failed, success(false));
    assert.ok(h.publishes.some((note) => note.label === failedLabel));
    const other = failedTag === 'pre_translate' ? startFollowUpdate(h) : startTranslation(h);
    const download = startDownload(h);
    await flush();
    assert.deepEqual(other, success(true));
    assert.deepEqual(download, success(true));
    assert.equal(h.starts.length, 1);
    assert.equal(h.active.size, 1);

    const completionReplies = [h.call(DOWNLOAD, 'complete', { status: 'Download finished' })];
    const expectedLabels = ['venera.download.complete'];
    if (failedTag === 'pre_translate') {
      completionReplies.push(h.call(BACKGROUND, 'complete', { tag: 'follow_update', status: 'Found 2 updates' }));
      expectedLabels.push('venera.follow_update.complete');
    }
    await flush();
    for (const reply of completionReplies) {
      assert.equal(reply.length, 1);
      assert.equal(reply[0].kind, 'success');
    }
    for (const label of expectedLabels) {
      const note = h.publishes.find((request) => request.label === label);
      assert.ok(note, label);
      assert.equal(note.content.notificationContentType, 0);
    }
    assert.equal(h.active.size, 0);
  });
}

for (const action of ['remove', 'dispose']) {
  test(`translation cancellation failure does not prevent follow-update ${action} cleanup`, async () => {
    const h = harness();
    startTranslation(h);
    startFollowUpdate(h);
    await flush();
    const translationNote = h.publishes.find((note) => note.label === 'venera.pre_translate');
    const followNote = h.publishes.find((note) => note.label === 'venera.follow_update');
    h.config.cancelFailureLabel = translationNote.label;
    if (action === 'remove') {
      h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
      h.call(BACKGROUND, 'remove', { tag: 'follow_update' });
    } else {
      h.service.dispose();
    }
    await flush();
    assert.ok(h.cancelRequests.some((note) => note.id === translationNote.id));
    assert.deepEqual(h.removedNotifications, [{ id: followNote.id, label: followNote.label }]);
    assert.equal(h.publishes.length, 2);
    if (action === 'remove') {
      h.config.cancelFailureLabel = undefined;
      const retry = h.call(BACKGROUND, 'remove', { tag: 'pre_translate' });
      await flush();
      assert.deepEqual(retry, success(true));
      assert.deepEqual(h.removedNotifications.at(-1), { id: translationNote.id, label: translationNote.label });
    } else {
      assert.equal(h.state.off, 1);
    }
  });
}

for (const failedTag of ['pre_translate', 'follow_update']) {
  test(`${failedTag} cancellation failure cannot block other completion notifications`, async () => {
    const h = harness();
    startTranslation(h);
    startFollowUpdate(h);
    startDownload(h);
    await flush();
    const failedLabel = failedTag === 'pre_translate' ? 'venera.pre_translate' : 'venera.follow_update';
    h.config.cancelFailureLabel = failedLabel;
    h.call(BACKGROUND, 'remove', { tag: failedTag });
    await flush();
    assert.ok(h.cancelRequests.some((note) => note.label === failedLabel));
    const completionReplies = [h.call(DOWNLOAD, 'complete', { status: 'Download finished' })];
    const expectedLabels = ['venera.download.complete'];
    if (failedTag === 'pre_translate') {
      completionReplies.push(h.call(BACKGROUND, 'complete', { tag: 'follow_update', status: 'Found 2 updates' }));
      expectedLabels.push('venera.follow_update.complete');
    }
    await flush();
    for (const reply of completionReplies) {
      assert.equal(reply.length, 1);
      assert.equal(reply[0].kind, 'success');
    }
    for (const label of expectedLabels) {
      const note = h.publishes.find((request) => request.label === label);
      assert.ok(note, label);
      assert.equal(note.content.notificationContentType, 0);
    }
    assert.equal(h.active.size, 0);
  });
}
