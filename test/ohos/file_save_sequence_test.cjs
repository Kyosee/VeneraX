// Run with Node >= 22.13: node --test test/ohos/file_save_sequence_test.cjs
// Execute the real ETS bridge with controlled picker and cleanup completion.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const flush = () => new Promise((resolve) => setImmediate(resolve));
const sourcePath = '/app/cache/export/comic.cbz';
const targetUri = 'file:///documents/comic.cbz';
const nextUri = 'file:///documents/next.cbz';
const sourceBytes = Uint8Array.from([1, 2, 3, 4]);
const saveArgs = { sourceFilePath: sourcePath, fileName: 'comic.cbz' };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function harness(config = {}) {
  const state = {
    files: new Map([[sourcePath, sourceBytes.slice()]]),
    handles: new Map(),
    pickerCalls: [],
    cleanupStarted: [],
    cleanupSettled: [],
    removed: [],
    warnings: [],
  };
  let nextFd = 0;
  let nextStage = 0;
  const fs = {
    OpenMode: { READ_ONLY: 1, WRITE_ONLY: 2, CREATE: 4, TRUNC: 8 },
    async mkdtemp() { return `/app/cache/venera_save_${++nextStage}`; },
    async open(filePath, mode) {
      if (config.writeFailure && filePath === targetUri) throw config.writeFailure;
      if (mode & fs.OpenMode.TRUNC) state.files.set(filePath, new Uint8Array());
      if (!state.files.has(filePath)) throw new Error('Missing mock file');
      const file = { fd: ++nextFd };
      state.handles.set(file.fd, { filePath, offset: 0 });
      return file;
    },
    async stat() { return { isFile: () => true }; },
    async read(fd, buffer) {
      const handle = state.handles.get(fd);
      const bytes = state.files.get(handle.filePath);
      const count = Math.min(buffer.byteLength, bytes.length - handle.offset);
      new Uint8Array(buffer).set(bytes.subarray(handle.offset, handle.offset + count));
      handle.offset += count;
      return count;
    },
    async write(fd, buffer) {
      const handle = state.handles.get(fd);
      const before = state.files.get(handle.filePath);
      const bytes = new Uint8Array(buffer);
      const after = new Uint8Array(before.length + bytes.length);
      after.set(before);
      after.set(bytes, before.length);
      state.files.set(handle.filePath, after);
      return bytes.length;
    },
    async fsync() {},
    async close(file) { state.handles.delete(file.fd); },
    async rmdir(stage) {
      state.cleanupStarted.push(stage);
      try {
        await config.cleanups?.shift();
        for (const filePath of state.files.keys()) {
          if (filePath.startsWith(stage + '/')) state.files.delete(filePath);
        }
        state.removed.push(stage);
      } finally {
        state.cleanupSettled.push(stage);
      }
    },
  };
  class MethodChannel { setMethodCallHandler() {} }
  class ShareService { dispose() {} }
  class DirectoryAccess { roots = []; dispose() {} }
  const context = vm.createContext({
    fs, MethodChannel, ShareService, DirectoryAccess, Uint8Array,
    sanitizeFileName: (name) => name,
    validateSandboxFile: async () => {},
    fileUri: { getUriFromPath: (filePath) => 'file://' + filePath },
    picker: {
      DocumentViewPicker: class {
        async save(options) {
          state.pickerCalls.push(options);
          const value = config.pickerResults?.shift() ?? [nextUri];
          if (value instanceof Error) throw value;
          return await value;
        }
      },
    },
    console: { warn: (message) => state.warnings.push(message) },
  });
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge/FileServices.ets');
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.FileServices = FileServices;', context, { filename });
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const service = new context.FileServices({ cacheDir: '/app/cache' }, engine);

  function call(args = saveArgs, onReply) {
    const events = [];
    const reply = (event) => { events.push(event); onReply?.(event); };
    service.onMethodCall({ method: 'saveFile', argument: (key) => args[key] }, {
      success: (value) => reply({ kind: 'success', value }),
      error: (code, message, details) => reply({ kind: 'error', code, message, details }),
      notImplemented: () => reply({ kind: 'notImplemented' }),
    });
    return events;
  }
  return { call, config, service, state };
}

function expectClosed(events) {
  assert.equal(events.length, 1);
  assert.equal(events[0].kind, 'error');
  assert.equal(events[0].code, 'FILE_SERVICES_CLOSED');
}

const outcomes = [
  { name: 'successful save', picker: [targetUri], expected: { kind: 'success', value: targetUri } },
  { name: 'picker cancellation', picker: [], expected: { kind: 'success', value: null } },
  { name: 'picker error', picker: Object.assign(new Error('Picker failed'), { code: 13900012 }),
    expected: { kind: 'error', code: 'FILE_SAVE_FAILED', message: 'Picker failed', details: 13900012 } },
  { name: 'destination write error', picker: [targetUri], writeFailure: new Error('Write failed'),
    expected: { kind: 'error', code: 'FILE_SAVE_FAILED', message: 'Write failed', details: null } },
];

for (const outcome of outcomes) {
  test(`${outcome.name} replies after cleanup and allows an immediate next save`, async () => {
    const cleanup = deferred();
    const h = harness({
      cleanups: [cleanup.promise], pickerResults: [outcome.picker, [nextUri]],
      writeFailure: outcome.writeFailure,
    });
    let second;
    let settledAtReply;
    const first = h.call(saveArgs, () => {
      settledAtReply = h.state.cleanupSettled.length;
      second = h.call();
    });
    await flush();
    assert.equal(h.state.cleanupStarted.length, 1);
    assert.deepEqual(first, []);
    assert.equal(second, undefined);
    assert.equal(h.call()[0].code, 'PICKER_IN_PROGRESS');
    assert.equal(h.state.pickerCalls.length, 1);
    cleanup.resolve();
    await flush();
    assert.deepEqual(first, [outcome.expected]);
    assert.equal(settledAtReply, 1);
    assert.deepEqual(second, [{ kind: 'success', value: nextUri }]);
    assert.equal(h.state.cleanupSettled.length, 2);
    assert.deepEqual(h.state.files.get(sourcePath), sourceBytes);
    assert.deepEqual(h.state.files.get(nextUri), sourceBytes);
    assert.equal(h.state.handles.size, 0);
    if (outcome.name === 'successful save') {
      assert.deepEqual(h.state.files.get(targetUri), sourceBytes);
    }
  });
}

for (const outcome of outcomes.slice(0, 3)) {
  test(`${outcome.name} keeps its result when cleanup fails and releases the next save`, async () => {
    const cleanup = deferred();
    const h = harness({ cleanups: [cleanup.promise], pickerResults: [outcome.picker, [nextUri]] });
    let second;
    let warningsAtReply;
    const first = h.call(saveArgs, () => {
      warningsAtReply = h.state.warnings.length;
      second = h.call();
    });
    await flush();
    assert.equal(h.state.cleanupStarted.length, 1);
    assert.deepEqual(first, []);
    cleanup.reject(new Error('Cleanup failed'));
    await flush();
    assert.deepEqual(first, [outcome.expected]);
    assert.equal(warningsAtReply, 1);
    assert.deepEqual(second, [{ kind: 'success', value: nextUri }]);
    assert.equal(h.state.cleanupSettled.length, 2);
  });
}

test('invalid arguments release the save lock before the error callback retries', async () => {
  const h = harness();
  let retry;
  const invalid = h.call({}, () => { retry = h.call(); });
  await flush();
  assert.equal(invalid.length, 1);
  assert.equal(invalid[0].code, 'FILE_SAVE_FAILED');
  assert.deepEqual(retry, [{ kind: 'success', value: nextUri }]);
  assert.equal(h.state.pickerCalls.length, 1);
  assert.equal(h.state.cleanupStarted.length, 1);
});

for (const completion of ['resolve', 'reject']) {
  test(`dispose during cleanup replies once before its late ${completion}`, async () => {
    const cleanup = deferred();
    const h = harness({ cleanups: [cleanup.promise], pickerResults: [[targetUri]] });
    const result = h.call();
    await flush();
    assert.equal(h.state.cleanupStarted.length, 1);
    assert.deepEqual(result, []);
    h.service.dispose();
    h.service.dispose();
    expectClosed(result);
    cleanup[completion](completion === 'reject' ? new Error('Late cleanup failure') : undefined);
    await flush();
    expectClosed(result);
    expectClosed(h.call());
    assert.equal(h.state.cleanupSettled.length, 1);
    assert.equal(h.state.pickerCalls.length, 1);
    assert.equal(h.state.handles.size, 0);
  });

  test(`dispose ignores picker late ${completion} and still cleans its stage`, async () => {
    const picker = deferred();
    const cleanup = deferred();
    const h = harness({ cleanups: [cleanup.promise], pickerResults: [picker.promise] });
    const result = h.call();
    await flush();
    assert.equal(h.state.pickerCalls.length, 1);
    h.service.dispose();
    expectClosed(result);
    picker[completion](completion === 'reject' ? new Error('Late picker failure') : [targetUri]);
    await flush();
    assert.equal(h.state.cleanupStarted.length, 1);
    assert.equal(h.state.files.has(targetUri), false);
    expectClosed(result);
    cleanup.resolve();
    await flush();
    expectClosed(result);
    assert.equal(h.state.removed.length, 1);
    assert.equal(h.state.handles.size, 0);
  });
}
