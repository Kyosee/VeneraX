const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function harness(reason = 3) {
  const files = new Map();
  const reads = [];
  let watcher;
  const fs = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: filename => ({ fd: filename }),
    writeSync: (fd, text) => files.set(fd, text),
    closeSync() {},
    renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); },
    readTextSync: (filename, options) => {
      reads.push(filename);
      if (!files.has(filename)) throw new Error('Missing');
      return files.get(filename).slice(0, options?.length);
    },
  };
  const hiAppEvent = {
    domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH', APP_FREEZE: 'APP_FREEZE' },
    addWatcher: value => { watcher = value; },
    removeWatcher: value => { assert.equal(value, watcher); watcher = undefined; },
  };
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge/NativeDiagnostics.ets');
  const source = readFileSync(filename, 'utf8').replace(/^import .*;\r?$/gm, '').replace('export class', 'class');
  const context = vm.createContext({ fs, hiAppEvent, console });
  vm.runInContext(stripTypeScriptTypes(source, { mode: 'strip' }) + '\nglobalThis.NativeDiagnostics = NativeDiagnostics;', context);
  const service = new context.NativeDiagnostics('/private', { lastExitReason: reason, lastExitMessage: 'Native failure' });
  return { service, files, reads, emit: event => watcher.onReceive('OS', [{ appEventInfos: [event] }]) };
}

test('normal exits are quiet while abnormal exits survive restart', () => {
  assert.equal(harness(2).service.read().length, 0);
  const h = harness();
  assert.match(h.service.read()[0], /Previous process exit \(3\)/);
  assert.ok(h.files.has('/private/native_diagnostics.json'));
  h.service.dispose();
  h.service.dispose();
});

test('native reports retain stacks, exclude unrelated paths, deduplicate and bound history', () => {
  const h = harness(2);
  const report = '/data/storage/el2/log/hiappevent/APP_CRASH.log';
  h.files.set(report, 'Native stack\n' + 'x'.repeat(70000));
  const event = { name: 'APP_CRASH', params: { time: 1, crash_type: 'NativeCrash',
    exception: { message: 'SIGSEGV' }, hilog: 'private unrelated logs',
    external_log: ['/private/appdata.json', report, '/data/storage/el2/log/hiappevent/../secret'] } };
  h.emit(event);
  h.emit(event);
  assert.equal(h.service.read().length, 1);
  assert.match(h.service.read()[0], /SIGSEGV.*\nNative stack/);
  assert.equal(h.service.read()[0].length, 65536);
  assert.ok(!h.service.read()[0].includes('private unrelated logs'));
  assert.ok(!h.reads.includes('/private/appdata.json'));
  assert.ok(!h.reads.some(value => value.includes('..')));
  for (let time = 2; time < 7; time++) h.emit({ name: 'APP_FREEZE', params: { time } });
  assert.equal(h.service.read().length, 4);
  assert.match(h.service.read().at(-1), /"time":6/);
});
