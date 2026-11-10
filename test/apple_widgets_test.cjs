// Validate the actual Xcode object graphs and packaged resources without Xcode.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function openStep(source) {
  const tokens = source.match(/\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+/g)
    .filter(token => !token.startsWith('//') && !token.startsWith('/*'));
  let index = 0;
  function take(expected) {
    const token = tokens[index++];
    if (expected) assert.equal(token, expected);
    return token;
  }
  function value() {
    const token = take();
    if (token === '{') {
      const result = {};
      while (tokens[index] !== '}') {
        const key = value();
        assert.ok(!Object.hasOwn(result, key), `Duplicate Xcode key ${key}`);
        take('='); result[key] = value(); take(';');
      }
      take('}'); return result;
    }
    if (token === '(') {
      const result = [];
      while (tokens[index] !== ')') {
        result.push(value());
        if (tokens[index] === ',') take(',');
      }
      take(')'); return result;
    }
    assert.ok(token, 'Unexpected end of Xcode project');
    return token.startsWith('"') ? JSON.parse(token) : token;
  }
  const result = value();
  assert.equal(index, tokens.length);
  return result;
}

function plist(source) {
  const tokens = source.replace(/<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<!--[\s\S]*?-->/g, '')
    .match(/<[^>]+>|[^<]+/g).filter(token => token.trim());
  let index = 1;
  function value() {
    const tag = tokens[index++];
    if (tag === '<dict>') {
      const result = {};
      while (tokens[index] !== '</dict>') {
        assert.equal(tokens[index++], '<key>');
        const key = tokens[index++];
        assert.equal(tokens[index++], '</key>');
        assert.ok(!Object.hasOwn(result, key), `Duplicate plist key ${key}`);
        result[key] = value();
      }
      index++; return result;
    }
    if (tag === '<array>') {
      const result = [];
      while (tokens[index] !== '</array>') result.push(value());
      index++; return result;
    }
    if (/^<true\s*\/>$/.test(tag)) return true;
    if (/^<false\s*\/>$/.test(tag)) return false;
    assert.equal(tag, '<string>');
    const result = tokens[index] === '</string>' ? '' : tokens[index++];
    assert.equal(tokens[index++], '</string>');
    return result;
  }
  assert.match(tokens[0], /^<plist /);
  const result = value();
  assert.equal(tokens[index++], '</plist>');
  assert.equal(index, tokens.length);
  return result;
}

for (const platform of ['ios', 'macos']) {
  test(`${platform}: embedded widget target, files, resources and signing agree`, () => {
    const project = openStep(read(`${platform}/Runner.xcodeproj/project.pbxproj`));
    const objects = project.objects;
    const nativeTargets = Object.values(objects).filter(object => object.isa === 'PBXNativeTarget');
    const host = nativeTargets.find(target => target.name === 'Runner');
    const widget = nativeTargets.find(target => target.name === 'ReadingWidgets');
    assert.ok(host && widget);
    const widgetID = Object.keys(objects).find(id => objects[id] === widget);
    assert.ok(objects[project.rootObject].targets.includes(widgetID));
    assert.equal(widget.productType, 'com.apple.product-type.app-extension');
    assert.ok(host.dependencies.some(id => objects[id].target === widgetID));
    const embedded = host.buildPhases.map(id => objects[id]).find(phase => phase.name === 'Embed App Extensions');
    assert.equal(embedded.dstSubfolderSpec, '13');
    assert.ok(embedded.files.some(id => objects[id].fileRef === widget.productReference));

    function verifyReferences(value) {
      if (typeof value === 'string' && /^[A-F0-9]{24}$/.test(value)) assert.ok(objects[value], `Dangling Xcode reference ${value}`);
      else if (Array.isArray(value)) value.forEach(verifyReferences);
      else if (value && typeof value === 'object') Object.values(value).forEach(verifyReferences);
    }
    verifyReferences(project);
    const parents = new Map();
    for (const [id, object] of Object.entries(objects)) {
      for (const child of object.children ?? []) parents.set(child, id);
    }
    function filePath(id) {
      const object = objects[id];
      const parent = parents.get(id);
      return path.resolve(parent ? filePath(parent) : path.join(root, platform), object.path ?? '');
    }
    const prefix = platform === 'ios' ? '3381' : '3382';
    for (const [id, object] of Object.entries(objects)) {
      if (id.startsWith(prefix) && object.isa === 'PBXFileReference' && object.sourceTree === '<group>') {
        assert.ok(fs.existsSync(filePath(id)), `Missing referenced file ${filePath(id)}`);
      }
    }
    function sources(target) {
      return target.buildPhases.map(id => objects[id]).filter(phase => phase.isa === 'PBXSourcesBuildPhase')
        .flatMap(phase => phase.files.map(id => objects[objects[id].fileRef].path));
    }
    assert.ok(sources(host).includes('ReadingWidgetData.swift'));
    assert.ok(sources(host).includes('ReadingWidgetBridge.swift'));
    assert.ok(!sources(host).includes('ReadingWidgets.swift'), 'Widget @main must not enter the host');
    assert.deepEqual(sources(widget).sort(), ['ReadingWidgetData.swift', 'ReadingWidgets.swift']);
    const resources = widget.buildPhases.map(id => objects[id]).find(phase => phase.isa === 'PBXResourcesBuildPhase');
    const localized = resources.files.map(id => objects[objects[id].fileRef]).find(file => file.name === 'Localizable.strings');
    assert.deepEqual(localized.children.map(id => objects[id].name).sort(), ['en', 'zh-Hans', 'zh-Hant']);

    const group = 'group.io.github.kyosee.venera';
    const configs = objects[widget.buildConfigurationList].buildConfigurations.map(id => objects[id]);
    assert.deepEqual(configs.map(config => config.name).sort(), ['Debug', 'Profile', 'Release']);
    for (const config of configs) {
      const settings = config.buildSettings;
      assert.equal(settings.APPLICATION_EXTENSION_API_ONLY, 'YES');
      assert.equal(settings.PRODUCT_BUNDLE_IDENTIFIER, 'io.github.kyosee.venera.ReadingWidgets');
      assert.equal(settings[platform === 'ios' ? 'IPHONEOS_DEPLOYMENT_TARGET' : 'MACOSX_DEPLOYMENT_TARGET'], platform === 'ios' ? '15.1' : '14.0');
      assert.equal(settings.CURRENT_PROJECT_VERSION, '$(FLUTTER_BUILD_NUMBER)');
      assert.match(fs.readFileSync(filePath(config.baseConfigurationReference), 'utf8'), /Flutter.*Generated\.xcconfig/);
      const entitlements = plist(read(`${platform}/${settings.CODE_SIGN_ENTITLEMENTS}`));
      assert.deepEqual(entitlements['com.apple.security.application-groups'], [group]);
      if (platform === 'macos') assert.equal(entitlements['com.apple.security.app-sandbox'], true);
    }
    for (const configID of objects[host.buildConfigurationList].buildConfigurations) {
      const entitlements = plist(read(`${platform}/${objects[configID].buildSettings.CODE_SIGN_ENTITLEMENTS}`));
      assert.deepEqual(entitlements['com.apple.security.application-groups'], [group]);
    }
    const hostInfo = plist(read(`${platform}/Runner/Info.plist`));
    const widgetInfo = plist(read(`${platform}/ReadingWidgets/Info.plist`));
    assert.equal(widgetInfo.NSExtension.NSExtensionPointIdentifier, 'com.apple.widgetkit-extension');
    assert.equal(widgetInfo.CFBundleShortVersionString, hostInfo.CFBundleShortVersionString);
    assert.equal(widgetInfo.CFBundleVersion, hostInfo.CFBundleVersion);
    assert.equal(hostInfo.FlutterDeepLinkingEnabled, false);
    assert.ok(hostInfo.CFBundleURLTypes.some(type => type.CFBundleURLSchemes.includes('venerax')));
  });
}

test('every WidgetKit text has an English, Simplified and Traditional Chinese resource', () => {
  const swift = read('apple/Widgets/ReadingWidgets.swift');
  const keys = [...swift.matchAll(/NSLocalizedString\("([^"\n]+)"/g)].map(match => match[1]).sort();
  for (const locale of ['en', 'zh-Hans', 'zh-Hant']) {
    const entries = [...read(`apple/Widgets/Resources/${locale}.lproj/Localizable.strings`)
      .matchAll(/^"([^"\n]+)"\s*=\s*"([^"\n]+)";$/gm)];
    assert.deepEqual(entries.map(match => match[1]).sort(), keys, locale);
    assert.ok(entries.every(match => match[2].trim().length > 0));
  }
});
