// Run with Node >= 22.13: node --test test/ohos/pdf_bridge_test.cjs
// Mocks verify ETS lifecycle control flow, not native PDFKit loading or rendering.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

function harness(options = {}) {
  const lifecycle = [];
  const gate = deferred();
  const state = {
    documentsCreated: 0,
    documentReleases: 0,
    pageReleases: 0,
    packerReleases: 0,
    pixelReleases: 0,
    activePages: 0,
    prematureDocumentReleases: 0,
    disposed: false,
  };

  async function boundary(name) {
    lifecycle.push(name);
    if (options.hold === name) await gate.promise;
    if (options.fail === name) throw new Error('Mock failure: ' + name);
  }

  class PdfDocument {
    constructor() { state.documentsCreated++; }
    loadDocument() { return 0; }
    getPageCount() { return 1; }
    getPage() {
      state.activePages++;
      lifecycle.push('page:open');
      return {
        getWidth: () => 200,
        getHeight: () => 100,
        getAreaPixelMap: () => ({
          async release() {
            state.pixelReleases++;
            await boundary('pixels:release');
          },
        }),
        release() {
          state.pageReleases++;
          state.activePages--;
          lifecycle.push('page:release');
          if (options.fail === 'page:release') {
            throw new Error('Mock failure: page:release');
          }
        },
      };
    }
    releaseDocument() {
      state.documentReleases++;
      lifecycle.push('document:release');
      if (state.activePages > 0) state.prematureDocumentReleases++;
    }
  }

  const context = vm.createContext({
    pdfService: options.missingModule ? undefined : {
      PdfDocument,
      PdfMatrix: class {},
      ParseResult: { PARSE_SUCCESS: 0 },
    },
    canIUse(capability) {
      assert.equal(capability, 'SystemCapability.OfficeService.PDFService.Core');
      return options.capability ?? true;
    },
    image: {
      createImagePacker: () => ({
        async packToData() {
          await boundary('pack:data');
          return new Uint8Array([1, 2, 3]).buffer;
        },
        async release() {
          state.packerReleases++;
          await boundary('packer:release');
        },
      }),
    },
    console,
  });
  const filename = path.resolve(
    __dirname, '../../ohos/entry/src/main/ets/bridge/PdfService.ets',
  );
  const source = readFileSync(filename, 'utf8')
    .replace(/^import\s[\s\S]*?;\r?$/gm, '')
    .replace(/\bexport\s+(?:default\s+)?(?=class)/g, '');
  const javascript = stripTypeScriptTypes(source, { mode: 'strip', sourceUrl: filename });
  vm.runInContext(javascript + '\nglobalThis.PdfService = PdfService;', context, { filename });
  const service = new context.PdfService();

  function invoke(method, args = {}) {
    const responses = [];
    service.onMethodCall({ method, argument: (key) => args[key] }, {
      success(value) {
        lifecycle.push('reply:' + method + ':success');
        responses.push({ kind: 'success', value, afterDispose: state.disposed });
      },
      error(code, message) {
        lifecycle.push('reply:' + method + ':error');
        responses.push({ kind: 'error', code, message, afterDispose: state.disposed });
      },
      notImplemented() { responses.push({ kind: 'notImplemented' }); },
    });
    return responses;
  }

  function open() {
    const responses = invoke('open', { path: '/mock/book.pdf' });
    assert.equal(responses.length, 1);
    assert.equal(responses[0].kind, 'success');
    return responses[0].value.get('id');
  }

  function dispose() {
    state.disposed = true;
    service.dispose();
  }

  return { dispose, gate, invoke, lifecycle, open, service, state };
}

for (const capability of [false, true]) {
  test('missing PDF module reports unsupported with capability=' + capability, async () => {
    const h = harness({ missingModule: true, capability });
    const responses = h.invoke('open', { path: '/mock/book.pdf' });
    await flush();
    assert.equal(responses.length, 1);
    assert.equal(responses[0].kind, 'error');
    assert.equal(responses[0].code, 'PDF_UNAVAILABLE');
    assert.equal(h.state.documentsCreated, 0);
  });
}

for (const hold of ['pack:data', 'packer:release', 'pixels:release']) {
  for (const action of ['close', 'dispose']) {
    test(action + ' during ' + hold + ' preserves page/document lifetime', async () => {
      const h = harness({ hold });
      const id = h.open();
      const rendering = h.invoke('render', { id, index: 0 });
      await flush();
      assert.ok(h.lifecycle.includes(hold));
      const closing = action === 'close' ? h.invoke('close', { id }) : undefined;
      if (action === 'dispose') h.dispose();
      h.gate.resolve();
      await flush();

      assert.equal(
        h.state.prematureDocumentReleases, 0,
        'Document was released while its page was still live: ' + h.lifecycle.join(', '),
      );
      assert.equal(h.state.pageReleases, 1);
      assert.equal(h.state.documentReleases, 1);
      assert.equal(h.state.packerReleases, 1);
      assert.equal(h.state.pixelReleases, 1);
      assert.equal(rendering.length, 1);
      if (closing) {
        assert.equal(closing.length, 1);
        assert.equal(closing[0].kind, 'success');
      } else {
        assert.equal(rendering.some((reply) => reply.kind === 'success' && reply.afterDispose), false);
      }
    });
  }
}

test('render success waits until asynchronous cleanup finishes', async () => {
  const h = harness({ hold: 'packer:release' });
  const id = h.open();
  const responses = h.invoke('render', { id, index: 0 });
  await flush();
  const repliesBeforeCleanup = responses.length;
  h.gate.resolve();
  await flush();
  h.invoke('close', { id });
  await flush();

  assert.equal(repliesBeforeCleanup, 0, 'Success escaped before page cleanup.');
  assert.equal(responses.length, 1);
  assert.equal(responses[0].kind, 'success');
  assert.ok(h.lifecycle.indexOf('page:release') < h.lifecycle.indexOf('reply:render:success'));
});

for (const fail of ['packer:release', 'pixels:release', 'page:release']) {
  test(fail + ' failure cannot reply twice to render', async () => {
    const h = harness({ fail });
    const id = h.open();
    const responses = h.invoke('render', { id, index: 0 });
    await flush();
    h.invoke('close', { id });
    await flush();

    assert.equal(responses.length, 1, JSON.stringify(responses));
    assert.equal(h.state.packerReleases, 1);
    assert.equal(h.state.pixelReleases, 1);
    assert.equal(h.state.pageReleases, 1);
  });
}

test('disposed PDF service rejects new document opens', async () => {
  const h = harness();
  h.dispose();
  const responses = h.invoke('open', { path: '/mock/book.pdf' });
  await flush();
  assert.equal(responses.length, 1);
  assert.equal(responses[0].kind, 'error');
  assert.equal(h.state.documentsCreated, 0);
});

test('a concurrent render is rejected and active resources are released once', async () => {
  const h = harness({ hold: 'pack:data' });
  const id = h.open();
  const first = h.invoke('render', { id, index: 0 });
  await flush();
  const second = h.invoke('render', { id, index: 0 });
  await flush();
  const repliesWhilePending = first.length;
  const pagesWhilePending = h.state.activePages;
  h.gate.resolve();
  await flush();
  const closing = h.invoke('close', { id });
  await flush();
  h.dispose();
  h.dispose();

  assert.equal(repliesWhilePending, 0);
  assert.equal(pagesWhilePending, 1);
  assert.equal(second.length, 1);
  assert.equal(second[0].kind, 'error');
  assert.match(second[0].message, /already in progress/);
  assert.equal(first.length, 1);
  assert.equal(first[0].kind, 'success');
  assert.equal(closing.length, 1);
  assert.equal(closing[0].kind, 'success');
  assert.equal(h.state.documentsCreated, 1);
  assert.equal(h.state.documentReleases, 1);
  assert.equal(h.state.pageReleases, 1);
  assert.equal(h.state.pixelReleases, 1);
  assert.equal(h.state.packerReleases, 1);
  assert.equal(h.state.prematureDocumentReleases, 0);
});
