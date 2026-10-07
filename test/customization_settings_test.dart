import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/script_translator.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

const _screenshots = String.fromEnvironment('CUSTOMIZATION_SCREENSHOTS');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final captureKey = GlobalKey();
  late ByteData guideBytes;

  setUpAll(() async {
    await AppTranslation.init();
    guideBytes = await rootBundle.load('doc/guide.zh.md');
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    if (_screenshots.isNotEmpty && Platform.isWindows) {
      for (final family in ['Roboto', 'monospace', 'Consolas', 'Ahem']) {
        final font = FontLoader(family);
        font.addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
        await font.load();
      }
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('venera_customization_');
    App.dataPath = temp.path;
    App.cachePath = '${temp.path}/cache';
    LocalManager().path = '${temp.path}/comics';
    appdata.settings['language'] = 'zh-CN';
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    await CacheManager().ready;
    final provider = LlmProvider(
      id: 'demo',
      name: 'My Translation API',
      url: 'https://example.invalid/translate',
      key: '',
      model: '',
      kind: LlmProviderKind.customScript,
    );
    appdata.settings['imageTranslationProviders'] = [provider.toJson()];
    appdata.settings['imageTranslationActiveProviderId'] = provider.id;
    appdata.settings[LlmProviderStore.scriptsKey] = {
      provider.id: ScriptTranslator.template,
    };
  });

  tearDown(() async {
    await CacheManager.instance?.ready;
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    appdata.settings[CacheManager.directorySetting] = '';
    appdata.settings['imageTranslationProviders'] = [];
    appdata.settings[LlmProviderStore.scriptsKey] = {};
    appdata.settings['imageTranslationActiveProviderId'] = '';
    appdata.settings['language'] = 'system';
    await temp.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    Widget page,
    Size size, {
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: App.rootNavigatorKey,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff386b62),
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (_screenshots.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_screenshots/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> openGuide(WidgetTester tester, Finder button) async {
    // Serve the real asset in the test zone; native IO uses a different clock.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    rootBundle.evict('doc/guide.zh.md');
    messenger.allMessagesHandler = (channel, handler, message) {
      if (channel == 'flutter/assets' && message != null) {
        final path = utf8.decode(
          message.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        if (path == 'doc/guide.zh.md') return Future.value(guideBytes);
      }
      if (previous != null) return previous(channel, handler, message);
      return handler != null
          ? handler(message)
          : messenger.delegate.send(channel, message);
    };
    try {
      await tester.tap(button);
      await tester.pumpAndSettle();
    } finally {
      messenger.allMessagesHandler = previous;
      rootBundle.evict('doc/guide.zh.md');
    }
  }

  testWidgets('cache setting shows pending path and links to help', (
    tester,
  ) async {
    await tester.runAsync(
      () => CacheManager.setCustomDirectory('${temp.path}/new-location'),
    );
    await pump(
      tester,
      const Scaffold(body: DataSyncSettings()),
      const Size(680, 740),
    );
    await tester.ensureVisible(find.byType(ComicCacheDirectorySetting));
    expect(find.text(CacheManager.cachePath), findsOneWidget);
    expect(find.textContaining('After restart'.tl), findsOneWidget);
    await capture(tester, 'cache-directory');
    await openGuide(tester, find.byTooltip('Usage guide'.tl));
    expect(
      tester.widget<GuidePage>(find.byType(GuidePage)).anchor,
      GuideAnchor.cacheDirectory,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('cache dialog can reset draft and cancel on a small screen', (
    tester,
  ) async {
    await pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(child: ComicCacheDirectorySetting()),
      ),
      const Size(360, 700),
    );
    await tester.tap(find.text('Set'.tl));
    await tester.pumpAndSettle();
    expect(find.text('Choose folder'.tl), findsOneWidget);
    await tester.enterText(find.byType(TextField), '/example/cache');
    await tester.tap(find.text('Use default'.tl));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await capture(tester, 'cache-dialog-mobile');
    await tester.tap(find.text('Cancel'.tl));
    await tester.pumpAndSettle();
    expect(CacheManager.customDirectory, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1280, 820), const Size(360, 760)]) {
    testWidgets('script editor has help and clear test feedback at $size', (
      tester,
    ) async {
      await pump(
        tester,
        const LlmProvidersPage(),
        size,
        dark: size.width > 900,
      );
      await tester.tap(find.text('My Translation API'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit translation script'.tl));
      await tester.tap(find.text('Edit translation script'.tl));
      await tester.pumpAndSettle();
      expect(find.text('Test run'.tl), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(
        tester,
        size.width > 900 ? 'script-editor-desktop' : 'script-editor-mobile',
      );
      final input = find.byType(TextField).last;
      await tester.enterText(
        input,
        'function translate({texts}) { return texts.map(t => "Test: " + t); }',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Test script'.tl));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(find.text('Test passed'.tl), findsOneWidget);
      expect(find.text('Test: Hello'), findsOneWidget);
      await tester.enterText(input, 'function translate() { return []; }');
      await tester.pump();
      expect(find.text('Test passed'.tl), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Test script'.tl));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(find.text('Test failed'.tl), findsOneWidget);
      await openGuide(tester, find.byTooltip('Usage guide'.tl).last);
      await capture(
        tester,
        size.width > 900 ? 'script-help-desktop' : 'script-help-mobile',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final heading = find.text('自定义翻译脚本', findRichText: true).last;
      expect(tester.getTopLeft(heading).dy, inInclusiveRange(50, 200));
      expect(
        tester.widget<GuidePage>(find.byType(GuidePage)).anchor,
        GuideAnchor.translationScript,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
