// Run with Node >= 22.13: node --test test/ohos/scan_service_test.cjs
// Mocks exercise the real ETS bridge; Scan Kit UI still needs device validation.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const flush = () => new Promise((resolve) => setImmediate(resolve));

function harness(config = {}) {
  const channels = new Map();
  const requests = [];
  const logs = [];
  const ability = {};
  class MethodChannel {
    constructor(_messenger, name) { channels.set(name, this); }
    setMethodCallHandler(handler) { this.handler = handler; }
  }
  const context = vm.createContext({
    MethodChannel,
    canIUse(capability) {
      assert.equal(capability, 'SystemCapability.Multimedia.Scan.ScanBarcode');
      if (config.capabilityError) throw new Error('Capability unavailable');
      return config.capability ?? true;
    },
    scanCore: { ScanType: { QR_CODE: 11 } },
    scanBarcode: config.missingModule ? undefined : {
      startScanForResult(receivedContext, options) {
        assert.equal(receivedContext, ability);
        assert.deepEqual(JSON.parse(JSON.stringify(options)), {
          scanTypes: [11], enableMultiMode: false, enableAlbum: true,
        });
        if (config.syncError) throw config.syncError;
        let resolve;
        let reject;
        const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
        requests.push({ resolve, reject });
        return promise;
      },
    },
    console: {
      log(message) { logs.push(message); },
      warn(message) { logs.push(message); },
      error(message) { logs.push(message); },
    },
  });
  const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge/ScanService.ets');
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.ScanService = ScanService;', context, { filename });
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const service = new context.ScanService(ability, engine);
  const channel = channels.get('venera/scan');
  assert.equal(channel.handler, service);
  function call(method = 'scan') {
    const replies = [];
    service.onMethodCall({ method }, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message, details) { replies.push({ kind: 'error', code, message, details }); },
      notImplemented() { replies.push({ kind: 'notImplemented' }); },
    });
    return replies;
  }
  return { call, channel, config, logs, requests, service };
}

test('unknown methods do not open the scanner', () => {
  const h = harness();
  assert.deepEqual(h.call('unknown'), [{ kind: 'notImplemented' }]);
  assert.equal(h.requests.length, 0);
});

test('official single-QR and album options return the original value once', async () => {
  const h = harness();
  const replies = h.call();
  const value = 'venera://sync?v=1&d=fixture';
  h.requests[0].resolve({ originalValue: value });
  h.requests[0].resolve({ originalValue: 'late' });
  await flush();
  assert.deepEqual(replies, [{ kind: 'success', value }]);
  assert.deepEqual(h.logs, []);
});

for (const config of [
  { capability: false }, { capabilityError: true }, { missingModule: true },
  { syncError: Object.assign(new Error('private QR contents'), { code: 1000500001 }) },
]) {
  test('unavailable capability or module fails safely: ' + Object.keys(config)[0], async () => {
    const h = harness(config);
    const replies = h.call();
    await flush();
    assert.deepEqual(replies, [{
      kind: 'error', code: 'SCAN_UNAVAILABLE', message: 'Camera unavailable', details: null,
    }]);
    assert.deepEqual(h.logs, []);
  });
}

test('a second request is rejected while the first is active', async () => {
  const h = harness();
  const first = h.call();
  assert.equal(h.call()[0].code, 'SCAN_BUSY');
  assert.equal(h.requests.length, 1);
  h.requests[0].resolve({ originalValue: 'first' });
  await flush();
  assert.deepEqual(first, [{ kind: 'success', value: 'first' }]);
  const next = h.call();
  h.requests[1].resolve({ originalValue: 'next' });
  await flush();
  assert.deepEqual(next, [{ kind: 'success', value: 'next' }]);
});

test('official cancellation returns null and a subsequent scan can run', async () => {
  const h = harness();
  const canceled = h.call();
  h.requests[0].reject({ code: 1000500002, message: 'private QR contents' });
  await flush();
  assert.deepEqual(canceled, [{ kind: 'success', value: null }]);
  const next = h.call();
  h.requests[1].resolve({ originalValue: 'retry' });
  await flush();
  assert.deepEqual(next, [{ kind: 'success', value: 'retry' }]);
  assert.deepEqual(h.logs, []);
});

test('asynchronous native errors expose neither QR data nor error details', async () => {
  const h = harness();
  const replies = h.call();
  h.requests[0].reject({ code: 1000500001, message: 'private QR contents' });
  await flush();
  assert.deepEqual(replies, [{
    kind: 'error', code: 'SCAN_UNAVAILABLE', message: 'Camera unavailable', details: null,
  }]);
  assert.deepEqual(h.logs, []);
});

test('empty, missing, non-string and oversized results are rejected', async () => {
  for (const data of [undefined, null, {}, { originalValue: '' },
    { originalValue: ' \n ' }, { originalValue: 123 }, { originalValue: 'x'.repeat(16385) }]) {
    const h = harness();
    const replies = h.call();
    h.requests[0].resolve(data);
    await flush();
    assert.equal(replies.length, 1);
    assert.equal(replies[0].code, 'SCAN_INVALID_RESULT');
    assert.equal(replies[0].details, null);
    assert.deepEqual(h.logs, []);
  }
});

test('the 16 KiB character boundary is accepted', async () => {
  const h = harness();
  const replies = h.call();
  const value = 'x'.repeat(16384);
  h.requests[0].resolve({ originalValue: value });
  await flush();
  assert.deepEqual(replies, [{ kind: 'success', value }]);
});

for (const completion of ['resolve', 'reject']) {
  test('dispose replies once and ignores a late ' + completion, async () => {
    const h = harness();
    const pending = h.call();
    h.service.dispose();
    h.service.dispose();
    assert.equal(h.channel.handler, null);
    assert.equal(pending.length, 1);
    assert.equal(pending[0].code, 'SCAN_CLOSED');
    h.requests[0][completion]({ originalValue: 'late', code: 1000500002 });
    await flush();
    assert.equal(pending.length, 1);
    assert.equal(h.call()[0].code, 'SCAN_CLOSED');
    assert.equal(h.requests.length, 1);
    assert.deepEqual(h.logs, []);
  });
}
