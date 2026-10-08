import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _SettingsFile implements File {
  _SettingsFile(this.filePath, this.writes);
  final String filePath;
  final List<Map<String, dynamic>> writes;
  @override
  String get path => filePath;
  @override
  bool existsSync() => false;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (path.endsWith('appdata.json.tmp')) writes.add(jsonDecode(contents));
    return this;
  }

  @override
  Future<File> rename(String newPath) async => this;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['downloadThreads'] = 5;
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
  });

  for (final leaveEarly in [false, true]) {
    testWidgets(
      'slider previews in memory and saves once on ${leaveEarly ? 'page exit' : 'release'}',
      (tester) async {
        final writes = <Map<String, dynamic>>[];
        await IOOverrides.runZoned(() async {
          await tester.pumpWidget(
            const MaterialApp(home: Scaffold(body: NetworkSettings())),
          );
          await tester.pumpAndSettle();
          final slider = find.byType(Slider).first;
          final gesture = await tester.startGesture(tester.getCenter(slider));
          await gesture.moveBy(const Offset(40, 0));
          await tester.pump();
          await gesture.moveBy(const Offset(40, 0));
          await tester.pump();
          final value = appdata.settings['downloadThreads'];
          expect(value, isNot(5));
          expect(writes, isEmpty);
          if (leaveEarly) {
            await tester.pumpWidget(const SizedBox());
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await tester.pumpAndSettle();
          expect(writes, hasLength(1));
          expect(writes.single['settings']['downloadThreads'], value);
          await tester.pumpWidget(const SizedBox());
        }, createFile: (path) => _SettingsFile(path, writes));
      },
    );
  }

  testWidgets(
    'translation slider saves its custom preset with the final value',
    (tester) async {
      appdata.settings['imageTranslationPerformancePreset'] = 'balanced';
      final writes = <Map<String, dynamic>>[];
      await IOOverrides.runZoned(() async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: ReaderSettings(translationOnly: true)),
          ),
        );
        await tester.pumpAndSettle();
        final advanced = find.text('Advanced settings');
        await tester.scrollUntilVisible(
          advanced,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        final row = find.widgetWithText(ListTile, 'OCR parallelism (0 = auto)');
        final slider = find.descendant(of: row, matching: find.byType(Slider));
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(slider));
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
        expect(writes, isEmpty);
        expect(appdata.settings['imageTranslationPerformancePreset'], 'custom');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(writes, hasLength(1));
        expect(
          writes.single['settings']['imageTranslationPerformancePreset'],
          'custom',
        );
        await tester.pumpWidget(const SizedBox());
      }, createFile: (path) => _SettingsFile(path, writes));
    },
  );
}
