import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/app_slider_theme.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/reader/night_mode_button.dart';
import 'package:venera/utils/translations.dart';

class _SettingsFile implements File {
  _SettingsFile(this.path, this.writes);
  @override
  final String path;
  final List<Map<String, dynamic>> writes;
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
    appdata.settings['readerNightMode'] = false;
    appdata.settings['readerNightModeFollowSystem'] = true;
    appdata.settings['readerNightModeIntensity'] = 0.45;
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    VoidCallback? onPressed,
    VoidCallback? onChanged,
  }) async {
    final colors = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: colors,
          sliderTheme: appSliderTheme(colors),
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.bottomLeft,
              child: ReaderNightModeButton(
                tooltip: 'Night mode',
                onPressed: onPressed ?? () {},
                onChanged: () {
                  setState(() {});
                  onChanged?.call();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tap toggles, long press only opens, outside tap dismisses', (
    tester,
  ) async {
    var taps = 0;
    await pumpButton(tester, onPressed: () => taps++);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.byType(Slider), findsNothing);
    await tester.longPress(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('45%'), findsOneWidget);
    expect(appdata.settings['readerNightMode'], isFalse);
    expect(appdata.settings['readerNightModeFollowSystem'], isTrue);
    await tester.tapAt(const Offset(400, 100));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.longPress(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('localized popup fits a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    appdata.settings['language'] = 'zh-CN';
    await pumpButton(tester);
    await tester.longPress(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.text('夜览强度'), findsOneWidget);
    final bounds = tester.getRect(find.byType(Slider));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(320));
    expect(bounds.bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back closes the popup before leaving the reader', (
    tester,
  ) async {
    await pumpButton(tester);
    final navigator = Navigator.of(
      tester.element(find.byType(ReaderNightModeButton)),
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: ReaderNightModeButton(
            tooltip: 'Reader',
            onPressed: () {},
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(navigator.canPop(), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final leaveEarly in [false, true]) {
    testWidgets(
      'intensity previews immediately and saves once on ${leaveEarly ? 'exit' : 'release'}',
      (tester) async {
        final writes = <Map<String, dynamic>>[];
        var previews = 0;
        await IOOverrides.runZoned(() async {
          await pumpButton(tester, onChanged: () => previews++);
          await tester.longPress(find.byType(IconButton));
          await tester.pumpAndSettle();
          final slider = find.byType(Slider);
          final gesture = await tester.startGesture(tester.getCenter(slider));
          await gesture.moveBy(const Offset(300, 0));
          await tester.pump();
          expect(appdata.settings['readerNightModeIntensity'], 0.85);
          expect(appdata.settings['readerNightMode'], isTrue);
          expect(appdata.settings['readerNightModeFollowSystem'], isFalse);
          expect(previews, greaterThan(0));
          expect(find.text('85%'), findsOneWidget);
          expect(writes, isEmpty);
          if (leaveEarly) {
            await tester.pumpWidget(const SizedBox());
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await tester.pumpAndSettle();
          expect(writes, hasLength(1));
          expect(writes.single['settings']['readerNightModeIntensity'], 0.85);
          if (!leaveEarly) {
            await tester.tapAt(const Offset(400, 100));
            await tester.pumpAndSettle();
            await tester.longPress(find.byType(IconButton));
            await tester.pumpAndSettle();
            expect(find.text('85%'), findsOneWidget);
            final gesture = await tester.startGesture(tester.getCenter(slider));
            await gesture.moveBy(const Offset(-300, 0));
            await gesture.up();
            await tester.pumpAndSettle();
            expect(appdata.settings['readerNightModeIntensity'], 0.1);
            expect(find.text('10%'), findsOneWidget);
            expect(writes, hasLength(2));
          }
          await tester.pumpWidget(const SizedBox());
          expect(writes, hasLength(leaveEarly ? 1 : 2));
          expect(tester.takeException(), isNull);
        }, createFile: (path) => _SettingsFile(path, writes));
      },
    );
  }
}
