// Run after tool/prepare_ohos.dart, or set OHOS_WEBVIEW_PACKAGE to its output.
const assert = require('node:assert/strict');
const { existsSync, readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const packageRoot = process.env.OHOS_WEBVIEW_PACKAGE || path.resolve(
  __dirname, '../../.dart_tool/ohos/packages/flutter_inappwebview_ohos',
);
const filename = path.join(packageRoot,
  'ohos/src/main/ets/components/plugin/webview/in_app_webview/InAppWebViewClient.ets');

function navigate(headers, { policy = 1, mainFrame = true, fallback = false } = {}) {
  const source = readFileSync(filename, 'utf8');
  const helpers = source.slice(source.indexOf('const TAG ='), source.indexOf('interface OHOSMessageLevels'));
  const callback = source.slice(source.indexOf('class InnerShouldOverrideUrlLoadingCallback '),
    source.indexOf('class InnerSafeBrowsingHitCallback '));
  assert.ok(callback.includes('allowShouldOverrideUrlLoading'));
  const loads = [];
  const logs = [];
  let pageUrlReads = 0;
  const controller = {
    getUrl() { pageUrlReads++; return 'https://source.example/account?token=PRIVATE#SECRET'; },
    loadUrl(url, requestHeaders) { loads.push({ url, headers: requestHeaders }); },
  };
  const webview = { getController: () => controller, toWebHeaders: (value) => [...value] };
  const context = vm.createContext({
    ShouldOverrideUrlLoadingCallback: class {},
    NavigationActionPolicy: { CANCEL: 0, ALLOW: 1 },
    Log: { d: (...args) => logs.push(args), e: (...args) => logs.push(args) },
  });
  vm.runInContext(stripTypeScriptTypes(helpers + callback, { mode: 'strip' }) +
    '\nthis.Callback = InnerShouldOverrideUrlLoadingCallback;', context);
  const instance = new context.Callback(webview, 'https://destination.example/', new Map(headers), mainFrame);
  if (fallback) instance.defaultBehaviour(null);
  else instance.nonNullSuccess(policy);
  return { loads, logs, pageUrlReads };
}

const options = { skip: !existsSync(filename) && 'Prepare the official OHOS WebView package first.' };
for (const fallback of [false, true]) {
  test(`navigation preserves engine referrer policy; fallback=${fallback}`, options, () => {
    for (const headers of [[], [['Referer', '']], [['referer', 'https://source.example/']],
      [['Referer', 'https://source.example/safe'], ['X-Custom', 'value']]]) {
      const result = navigate(headers, { fallback });
      assert.equal(result.loads.length, 1);
      assert.deepEqual(result.loads[0].headers, headers);
      assert.equal(result.pageUrlReads, 0, 'Do not infer referrer policy from the current URL.');
      assert.deepEqual(result.logs, []);
    }
  });
}
test('canceled and subframe navigation never reloads the top-level page', options, () => {
  assert.deepEqual(navigate([], { policy: 0 }).loads, []);
  assert.deepEqual(navigate([], { mainFrame: false }).loads, []);
});
