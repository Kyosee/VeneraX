import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
    Log.clear();
  });

  group('log file format', () {
    test('parse reads back what toString writes', () {
      final items = [
        LogItem(
          LogLevel.error,
          'Network',
          'boom\n#0 main (file.dart:1)',
          DateTime(2026, 11, 13, 9, 5, 7, 123),
        ),
        LogItem(LogLevel.info, '', 'untitled', DateTime(2026, 11, 13, 9, 5)),
        LogItem(
          LogLevel.warning,
          'Image Loading',
          'line one\n\nline three',
          DateTime(2026, 11, 13, 9, 5, 9, 1, 2),
        ),
      ];
      final parsed = Log.parse(items.join());
      expect(parsed, hasLength(3));
      for (var i = 0; i < items.length; i++) {
        expect(parsed[i].level, items[i].level);
        expect(parsed[i].title, items[i].title);
        expect(parsed[i].content, items[i].content);
        expect(parsed[i].time, items[i].time);
      }
    });

    test('parse drops an entry cut in half by a tail read', () {
      final text = [
        LogItem(LogLevel.info, 'First', 'cut off', DateTime(2026)),
        LogItem(LogLevel.error, 'Second', 'kept', DateTime(2026)),
      ].join();
      final parsed = Log.parse(text.substring(3));
      expect(parsed.single.content, 'kept');
    });

    test('export leads with what a bug report needs', () {
      Log.info('Test', 'hello');
      final text = Log.exportText(Log.logs);
      expect(text, startsWith('Logs\nApp version: '));
      expect(text, contains('Platform: ${Platform.operatingSystem}'));
      expect(Log.parse(text).single.content, 'hello');
      expect(
        Log.exportFileName(DateTime(2026, 1, 2, 3, 4, 5)),
        'logs-20260102-030405.txt',
      );
    });

    test('changes is bumped on every add and on clear', () {
      final before = Log.changes.value;
      Log.info('Test', 'one');
      Log.warning('Test', 'two');
      expect(Log.changes.value, before + 2);
      Log.clear();
      expect(Log.changes.value, before + 3);
    });
  });

  Future<void> pumpLogs(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('level chips count entries and narrow the list', (tester) async {
    Log.error('Network', 'connection reset');
    Log.warning('Image Loading', 'slow decode');
    Log.info('Network', 'GET /comics 200');
    await pumpLogs(tester);

    expect(find.text('All 3'), findsOneWidget);
    expect(find.text('Error 1'), findsOneWidget);
    expect(find.text('Warning 1'), findsOneWidget);
    expect(find.text('Info 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('log-level-error')));
    await tester.pumpAndSettle();
    expect(find.textContaining('connection reset'), findsWidgets);
    expect(find.textContaining('slow decode'), findsNothing);
    expect(find.textContaining('GET /comics'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search matches content and updates the counts', (
    tester,
  ) async {
    Log.error('Network', 'connection reset');
    Log.warning('Image Loading', 'slow decode');
    await pumpLogs(tester);

    await tester.enterText(find.byType(TextField), 'DECODE');
    await tester.pumpAndSettle();
    expect(find.text('All 1'), findsOneWidget);
    expect(find.text('Error 0'), findsOneWidget);
    expect(find.textContaining('slow decode'), findsWidgets);
    expect(find.textContaining('connection reset'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pumpAndSettle();
    expect(find.text('No matching logs'), findsOneWidget);
  });

  testWidgets('tapping a tag shows only that tag until removed', (
    tester,
  ) async {
    Log.error('Network', 'connection reset');
    Log.warning('Image Loading', 'slow decode');
    await pumpLogs(tester);

    await tester.tap(find.text('Image Loading'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsOneWidget);
    expect(find.textContaining('connection reset'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(InputChip),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    expect(find.textContaining('connection reset'), findsWidgets);
  });

  testWidgets('new lines appear while the list is at the top', (tester) async {
    await pumpLogs(tester);
    expect(find.text('No logs'), findsOneWidget);

    Log.error('Sync', 'upload failed');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('upload failed'), findsWidgets);
  });

  testWidgets('long entries collapse and expand', (tester) async {
    Log.error('Crash', List.generate(30, (i) => 'frame $i').join('\n'));
    await pumpLogs(tester);

    expect(find.byTooltip('Expand'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
