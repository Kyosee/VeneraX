// Run with Node >= 22.13: node --test test/ohos/incoming_service_test.cjs
// These mocks check ingress and lifecycle; SDK delivery still needs a HAP test.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const TEXT = 'venera/text_share';
const LINKS = 'com.llfbandit.app_links/events';
const NOTIFICATIONS = 'venera/notification_route';
const METHODS = 'com.llfbandit.app_links/messages';
const PLAIN_TEXT = 'general.plain-text';
const HYPERLINK = 'general.hyperlink';
const plain = (content) => ({ utd: PLAIN_TEXT, content });
const hyperlink = (content) => ({ utd: HYPERLINK, content });
const shareWant = (records) => ({ action: 'ohos.want.action.sendData', records });
const linkWant = (uri) => ({ action: 'ohos.want.action.viewData', uri });
const notification = (route) => ({ parameters: { 'venera.notification.route': route } });

function harness(options = {}) {
  const methods = new Map();
  const events = new Map();
  const sdkCalls = [];
  const logs = [];
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
    url: { URL },
    util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } },
    uniformTypeDescriptor: { UniformDataType: { PLAIN_TEXT, HYPERLINK } },
    systemShare: {
      async getSharedData(want) {
        sdkCalls.push(want);
        return options.getSharedData
          ? options.getSharedData(want)
          : { getRecords: () => want.records };
      },
    },
    console: Object.fromEntries(['debug', 'info', 'log', 'warn', 'error'].map(
      (level) => [level, (...args) => logs.push({ level, args })],
    )),
  });
  for (const file of ['ShareService.ets', 'IncomingService.ets']) {
    const filename = path.resolve(__dirname, '../../ohos/entry/src/main/ets/bridge', file);
    const source = readFileSync(filename, 'utf8')
      .replace(/^import\s[\s\S]*?;\r?$/gm, '')
      .replace(/\bexport\s+(?:default\s+)?(?=class|function|async\s+function)/g, '');
    const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
    vm.runInContext(javascript, context, { filename });
  }
  vm.runInContext('globalThis.IncomingService = IncomingService;', context);
  const engine = { getDartExecutor: () => ({ getBinaryMessenger: () => ({}) }) };
  const service = new context.IncomingService(engine);
  const methodHandler = methods.get(METHODS)?.handler;
  const handlers = new Map([...events].map(([name, channel]) => [name, channel.handler]));
  assert.ok(methodHandler, 'App links methods must be registered.');
  for (const name of [TEXT, LINKS, NOTIFICATIONS]) assert.ok(handlers.get(name), name);

  function call(method) {
    const replies = [];
    methodHandler.onMethodCall({ method }, {
      success(value) { replies.push({ kind: 'success', value }); },
      error(code, message) { replies.push({ kind: 'error', code, message }); },
      notImplemented() { replies.push({ kind: 'notImplemented' }); },
    });
    return replies;
  }
  function listen(name, onValue) {
    const values = [];
    handlers.get(name).onListen(null, {
      success(value) {
        values.push(value);
        if (onValue) onValue(value);
      },
    });
    return values;
  }
  return { call, events, handlers, listen, logs, methods, sdkCalls, service };
}

function deferred() {
  let resolve;
  const promise = new Promise((complete) => { resolve = complete; });
  return { promise, resolve };
}

for (const serialized of [false, true]) {
test(`reading card ${serialized ? 'Form Kit JSON' : 'direct'} parameters deliver cold and hot routes`, async () => {
  const h = harness();
  const params = uri => serialized ? { params: JSON.stringify({ 'venera.readingWidget.uri': uri }) }
    : { 'venera.readingWidget.uri': uri };
  const first = 'venerax://reading-widget/read?id=book%2Fone%26two&type=0';
  await h.service.handleWant({ parameters: params(first) }, true);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: first }]);
  const values = h.listen(LINKS);
  assert.deepEqual(values, [first]);
  const next = 'venerax://reading-widget/history';
  await h.service.handleWant({ parameters: params(next) });
  assert.deepEqual(values, [first, next]);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: first }]);
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: next }]);
});
}

test('malformed Form Kit JSON and foreign destinations are ignored', async () => {
  const h = harness();
  for (const params of ['{invalid', 'null', '{}', JSON.stringify({ 'venera.readingWidget.uri': 'file:///private' }),
    JSON.stringify({ 'venera.readingWidget.uri': 'venerax://reading-widget/history', extra: 'x'.repeat(16384) })]) {
    await h.service.handleWant({ parameters: { params } }, true);
  }
  assert.deepEqual(h.listen(LINKS), []);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: null }]);
});

test('all card kinds accept their list and comic routes from Form Kit', async () => {
  const h = harness();
  const values = h.listen(LINKS);
  const expected = [];
  for (const kind of ['following', 'updates', 'local']) {
    for (const suffix of ['', '/read?id=book%26one&type=42']) {
      const uri = `venerax://reading-widget/${kind}${suffix}`;
      expected.push(uri);
      await h.service.handleWant({ parameters: { params: JSON.stringify({ 'venera.readingWidget.uri': uri }) } });
    }
  }
  assert.deepEqual(values, expected);
});

test('reading card parameters reject arbitrary and malformed destinations', async () => {
  const h = harness();
  const values = h.listen(LINKS);
  for (const value of [null, {}, 'file:///private', 'https://example.org',
    'venerax://reading-widget/read?id=a&type=not-number',
    'venerax://reading-widget/read?id=a&type=0&path=/private',
    'venerax://reading-widget/history#other',
    'venerax://reading-widget/read?id=' + 'a'.repeat(4096) + '&type=0']) {
    await h.service.handleWant({ parameters: { 'venera.readingWidget.uri': value } }, true);
  }
  assert.deepEqual(values, []);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: null }]);
});

test('cold links retain initial/latest values and drain once after subscription', async () => {
  const h = harness();
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: null }]);
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: null }]);
  await h.service.handleWant(linkWant('HTTPS://EXAMPLE.ORG/first'), true);
  await h.service.handleWant({ uri: 'https://example.org/second' });
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: 'https://example.org/first' }]);
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: 'https://example.org/second' }]);
  assert.deepEqual(h.listen(LINKS), ['https://example.org/first', 'https://example.org/second']);
  h.handlers.get(LINKS).onCancel(null);
  const next = h.listen(LINKS);
  assert.deepEqual(next, []);
  await h.service.handleWant(linkWant('https://example.org/hot'));
  assert.deepEqual(next, ['https://example.org/hot']);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: 'https://example.org/first' }]);
});

test('a hot link never becomes the initial link and duplicate initial calls do not overwrite it', async () => {
  const h = harness();
  await h.service.handleWant({ action: null, uri: 'https://example.org/hot' });
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: null }]);
  await h.service.handleWant(linkWant('https://example.org/initial'), true);
  await h.service.handleWant(linkWant('https://example.org/later'), true);
  assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: 'https://example.org/initial' }]);
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: 'https://example.org/later' }]);
});

for (const [label, value] of [
  ['absent', undefined], ['null', null], ['number', 123], ['object', {}], ['empty', ''],
  ['JavaScript', 'javascript:alert(1)'], ['data', 'data:text/plain,hello'],
  ['local file', 'file:///data/private'], ['custom scheme', 'venera://tasks'],
  ['relative', '/relative'], ['missing host', 'https://'],
  ['space', 'https://example.org/a b'], ['newline', 'https://example.org/\nprivate'],
  ['NUL', 'https://example.org/\u0000'], ['DEL', 'https://example.org/\u007f'],
  ['overlong', 'https://example.org/' + 'a'.repeat(4096)],
  ['overlong after normalization', 'https://example.org/' + '中'.repeat(500)],
]) {
  test('link ingress rejects ' + label + ' without updating getters', async () => {
    const h = harness();
    const values = h.listen(LINKS);
    await h.service.handleWant(linkWant(value), true);
    assert.deepEqual(values, []);
    assert.deepEqual(h.call('getInitialLink'), [{ kind: 'success', value: null }]);
    assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: null }]);
    assert.deepEqual(h.sdkCalls, []);
  });
}

test('link ingress accepts the length boundary and rejects unrelated actions', async () => {
  const h = harness();
  const values = h.listen(LINKS);
  const prefix = 'https://example.org/';
  const boundary = prefix + 'a'.repeat(4096 - prefix.length);
  await h.service.handleWant(linkWant(boundary));
  await h.service.handleWant({ action: 'unrelated', uri: 'https://example.org/ignored' });
  await h.service.handleWant(null);
  await h.service.handleWant(undefined);
  assert.deepEqual(values, [boundary]);
});

test('only text and hyperlink content reaches the share stream without reading URIs', async () => {
  const h = harness();
  const records = [plain('hello'), hyperlink('HTTPS://EXAMPLE.ORG/'),
    { utd: 'general.image', content: 'private' }, plain(123), plain(''), hyperlink('file:///private')];
  for (const record of records) Object.defineProperty(record, 'uri', {
    get() { assert.fail('Incoming records must never read file URIs.'); },
  });
  await h.service.handleWant(shareWant(records));
  assert.deepEqual(h.listen(TEXT), ['hello', 'https://example.org/']);
  assert.deepEqual(h.listen(LINKS), []);
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: null }]);
  assert.deepEqual(h.logs, []);
});

for (const [label, content, accepted] of [
  ['ASCII boundary', 'a'.repeat(16384), true],
  ['ASCII overflow', 'a'.repeat(16385), false],
  ['Chinese boundary', '中'.repeat(5461) + 'a', true],
  ['Chinese overflow', '中'.repeat(5461) + 'ab', false],
  ['emoji boundary', '🦄'.repeat(4096), true],
  ['emoji overflow', '🦄'.repeat(4096) + 'a', false],
]) {
  test('plain text applies the UTF-8 byte limit: ' + label, async () => {
    const h = harness();
    const values = h.listen(TEXT);
    await h.service.handleWant(shareWant([plain(content)]));
    assert.deepEqual(values, accepted ? [content] : []);
  });
}

test('hyperlinks share the URL validation and normalization length limit', async () => {
  const h = harness();
  const values = h.listen(TEXT);
  await h.service.handleWant(shareWant([
    hyperlink('http://example.org/valid'), hyperlink('javascript:alert(1)'),
    hyperlink('https://example.org/\nprivate'), hyperlink('https://example.org/' + '中'.repeat(500)),
  ]));
  assert.deepEqual(values, ['http://example.org/valid']);
});

test('record batches larger than eight are rejected before inspecting any record', async () => {
  const h = harness();
  let reads = 0;
  const record = { utd: PLAIN_TEXT, get content() { reads++; return 'private'; } };
  await h.service.handleWant(shareWant(Array(9).fill(record)));
  assert.equal(reads, 0);
  assert.deepEqual(h.listen(TEXT), []);
});

test('invalid record collections and empty entries are ignored', async () => {
  const h = harness();
  const values = h.listen(TEXT);
  for (const records of [undefined, null, {}, 'private', []]) {
    await h.service.handleWant(shareWant(records));
  }
  await h.service.handleWant(shareWant([null, undefined, {}, plain('valid')]));
  assert.deepEqual(values, ['valid']);
});

test('cold link and text queues are bounded independently and preserve accepted order', async () => {
  const h = harness();
  for (let index = 0; index < 12; index++) {
    await h.service.handleWant(linkWant('https://example.org/' + index));
    await h.service.handleWant(shareWant([plain('text ' + index)]));
  }
  assert.deepEqual(h.listen(LINKS), Array.from({ length: 8 }, (_, i) => 'https://example.org/' + i));
  assert.deepEqual(h.listen(TEXT), Array.from({ length: 8 }, (_, i) => 'text ' + i));
  assert.deepEqual(h.call('getLatestLink'), [{ kind: 'success', value: 'https://example.org/11' }]);
});

test('cancel during draining retains unconsumed events without replaying consumed ones', async () => {
  const h = harness();
  await h.service.handleWant(shareWant([plain('first'), plain('second'), plain('third')]));
  const first = h.listen(TEXT, () => h.handlers.get(TEXT).onCancel(null));
  assert.deepEqual(first, ['first']);
  assert.deepEqual(h.listen(TEXT), ['second', 'third']);
  h.handlers.get(TEXT).onCancel(null);
  assert.deepEqual(h.listen(TEXT), []);
});

test('reentrant link delivery appends after previously queued events', async () => {
  const h = harness();
  await h.service.handleWant(linkWant('https://example.org/first'));
  await h.service.handleWant(linkWant('https://example.org/second'));
  const values = h.listen(LINKS, (value) => {
    if (value.endsWith('/first')) void h.service.handleWant(linkWant('https://example.org/third'));
  });
  assert.deepEqual(values, ['https://example.org/first', 'https://example.org/second', 'https://example.org/third']);
});

test('share parsing is serial and admits at most eight active or queued requests', async () => {
  const gate = deferred();
  const h = harness({ getSharedData: (want) => want.records[0].content === '0'
    ? gate.promise : { getRecords: () => want.records } });
  const values = h.listen(TEXT);
  const pending = Array.from({ length: 12 }, (_, i) => h.service.handleWant(shareWant([plain(String(i))])));
  assert.equal(h.sdkCalls.length, 1);
  gate.resolve({ getRecords: () => [plain('0')] });
  await Promise.all(pending);
  assert.deepEqual(values, Array.from({ length: 8 }, (_, i) => String(i)));
  assert.equal(h.sdkCalls.length, 8);
  await h.service.handleWant(shareWant([plain('after')]));
  assert.deepEqual(values, [...Array.from({ length: 8 }, (_, i) => String(i)), 'after']);
});

for (const [label, fail] of [
  ['SDK rejection', async () => { throw new Error('private-content'); }],
  ['record lookup exception', () => ({ getRecords() { throw new Error('private-content'); } })],
  ['absent SDK result', () => undefined],
]) {
  test('share ' + label + ' is contained and the next request still works', async () => {
    let first = true;
    const h = harness({ getSharedData(want) {
      if (first) { first = false; return fail(); }
      return { getRecords: () => want.records };
    } });
    const values = h.listen(TEXT);
    await h.service.handleWant(shareWant([plain('private-content')]));
    await h.service.handleWant(shareWant([plain('recovered')]));
    assert.deepEqual(values, ['recovered']);
    assert.deepEqual(h.logs, []);
  });
}

test('notifications accept only known routes and retain only the latest cold route', async () => {
  const h = harness();
  for (const route of ['downloading', 'tasks', 'follow_updates']) {
    await h.service.handleWant(notification(route));
  }
  for (const route of ['../private', '/tasks', 'https://example.org', 'Tasks', '', {}, null, 1]) {
    await h.service.handleWant(notification(route));
  }
  const values = h.listen(NOTIFICATIONS);
  assert.deepEqual(values, ['follow_updates']);
  await h.service.handleWant(notification('downloading'));
  await h.service.handleWant(notification('tasks'));
  assert.deepEqual(values, ['follow_updates', 'downloading', 'tasks']);
  h.handlers.get(NOTIFICATIONS).onCancel(null);
  assert.deepEqual(h.listen(NOTIFICATIONS), []);
});

test('a valid notification route takes priority over link and share payloads', async () => {
  const h = harness();
  await h.service.handleWant({ ...shareWant([plain('ignored')]), ...notification('tasks'), uri: 'https://example.org/' });
  assert.deepEqual(h.listen(NOTIFICATIONS), ['tasks']);
  assert.deepEqual(h.listen(TEXT), []);
  assert.deepEqual(h.listen(LINKS), []);
  assert.deepEqual(h.sdkCalls, []);
});

test('dispose clears channels and buffered values and refuses stale callbacks', async () => {
  const h = harness();
  await h.service.handleWant(linkWant('https://example.org/private'), true);
  await h.service.handleWant(shareWant([plain('private')]));
  await h.service.handleWant(notification('tasks'));
  h.service.dispose();
  h.service.dispose();
  for (const channel of h.events.values()) assert.equal(channel.handler, null);
  assert.equal(h.methods.get(METHODS).handler, null);
  for (const name of [TEXT, LINKS, NOTIFICATIONS]) assert.deepEqual(h.listen(name), []);
  const callsBefore = h.sdkCalls.length;
  await h.service.handleWant(linkWant('https://example.org/late'));
  await h.service.handleWant(shareWant([plain('late')]));
  await h.service.handleWant(notification('tasks'));
  assert.equal(h.sdkCalls.length, callsBefore);
  assert.equal(h.call('getLatestLink')[0].code, 'INCOMING_CLOSED');
  assert.equal(h.call('getInitialLink')[0].code, 'INCOMING_CLOSED');
});

test('dispose resolves queued requests and a late native result cannot emit', { timeout: 2000 }, async (t) => {
  const gate = deferred();
  let recordReads = 0;
  const data = { getRecords() { recordReads++; return [plain('private-late')]; } };
  t.after(() => gate.resolve(data));
  const h = harness({ getSharedData: () => gate.promise });
  const values = h.listen(TEXT);
  const pending = Array.from({ length: 8 }, () => h.service.handleWant(shareWant([plain('queued')])));
  assert.equal(h.sdkCalls.length, 1);
  h.service.dispose();
  await Promise.all(pending);
  gate.resolve(data);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(recordReads, 0);
  assert.equal(h.sdkCalls.length, 1);
  assert.deepEqual(values, []);
  assert.deepEqual(h.logs, []);
});

test('unknown app links methods return notImplemented', () => {
  assert.deepEqual(harness().call('unknownMethod'), [{ kind: 'notImplemented' }]);
});
