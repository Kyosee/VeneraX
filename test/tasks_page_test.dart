import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/source_migration_tasks.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory temp;
  setUpAll(() async {
    await AppTranslation.init();
    temp = Directory.systemTemp.createTempSync('tasks-page-test-');
    App.dataPath = temp.path;
  });
  tearDownAll(() => temp.deleteSync(recursive: true));
  setUp(() {
    appdata.settings['language'] = 'en-US';
    ImportTaskManager.instance.currentTasks.clear();
    ImportTaskManager.instance.historyTasks.clear();
    ExportTaskManager.instance.currentTasks.clear();
    ExportTaskManager.instance.historyTasks.clear();
    FollowUpdateTaskManager.instance.currentTasks.clear();
    FollowUpdateTaskManager.instance.historyTasks.clear();
    SourceMigrationTaskManager.instance.currentTasks.clear();
    SourceMigrationTaskManager.instance.historyTasks.clear();
  });

  testWidgets(
    'canceling a paused task moves it to history with updated counts',
    (tester) async {
      final task = ExportTask(
        id: 'paused',
        folderPath: temp.path,
        format: ExportFormat.cbz,
        comics: [],
        createdAt: DateTime(2026),
        status: ExportTaskStatus.paused,
      );
      ExportTaskManager.instance.currentTasks.add(task);
      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await tester.pumpAndSettle();
      expect(find.text('Current (1)'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Cancel'));
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(task.status, ExportTaskStatus.canceled);
      expect(find.text('Current (0)'), findsOneWidget);
      expect(find.text('History (1)'), findsOneWidget);
      await tester.tap(find.text('History (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Export Comics'), findsOneWidget);
      expect(find.byTooltip('Clear History'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long confirmation actions fit narrow screens with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SourceMigrationTaskManager.instance.currentTasks.add(SourceMigrationTask(
      id: 'waiting', folder: 'Reading', targetSourceKeys: [], targetSourceNames: [],
      createdAt: DateTime(2026), details: [], migrateHistory: false,
      replaceFavorite: false, confirmEach: true,
      status: SourceMigrationTaskStatus.waitingConfirmation,
    ));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)),
        child: child!,
      ),
      home: const TasksPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Confirm All'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('following a task link keeps its card expanded', (tester) async {
    FollowUpdateTaskManager.instance.currentTasks.add(
      FollowUpdateTask(
        id: 'follow',
        folders: ['Reading'],
        manual: true,
        createdAt: DateTime(2026),
        total: 10,
        checked: 4,
        sources: {
          'source': FollowUpdateSourceProgress(
            sourceKey: 'source',
            sourceName: 'Sample source',
            total: 10,
            checked: 4,
          ),
        },
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: TasksPage(initialExpandedTaskId: 'follow')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sample source'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('an expanded upload can finish and open history in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      final manager = DataSyncTaskManager.instance;
      final task = manager.createTask(DataSyncTaskType.upload);
      addTearDown(() async {
        manager.removeTask(task.id);
        await appdata.saveData(false);
      });
      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Details'.tl), findsOneWidget);

      await tester.runAsync(() async {
        manager.completeTask(task.id);
        await appdata.saveData(false);
      });
      expect(task.progress, 1.0);
      expect(task.status, DataSyncTaskStatus.completed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No current tasks'.tl), findsOneWidget);
      expect(find.text("${'Current'.tl} (0)"), findsOneWidget);
      await tester.tap(find.text("${'History'.tl} (1)"));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
