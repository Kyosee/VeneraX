import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cold start keeps a manual pause and resumes interrupted jobs',
    () async {
      const key = 'pre_translation_active_tasks';
      final directory = await Directory.systemTemp.createTemp(
        'pretranslate-restore-',
      );
      final oldPath = App.dataPath;
      final oldBackground = App.isBackgroundTask;
      App.dataPath = directory.path;
      App.isBackgroundTask = true;
      addTearDown(() async {
        App.dataPath = oldPath;
        App.isBackgroundTask = oldBackground;
        await directory.delete(recursive: true);
      });
      await AppTranslation.init();
      Map<String, dynamic> snapshot(String id, {bool manual = false}) => {
        ...PreTranslationTask(
          id: id,
          cid: id,
          sourceKey: 'fixture',
          comicType: const ComicType(0),
          title: 'Fixture',
          createdAt: DateTime(2026),
          status: PreTranslationTaskStatus.paused,
          chapters: [
            PreTranslationChapter(
              eid: '1',
              title: 'A',
              total: 12,
              done: 7,
              failed: 1,
              failedPages: {3},
            ),
          ],
        ).toJson(),
        if (manual) 'keepPaused': true,
      };
      // Older snapshots stored system-paused jobs without a pause reason.
      appdata.implicitData[key] = [
        snapshot('system'),
        snapshot('manual', manual: true),
      ];
      final manager = PreTranslationTaskManager.instance;
      final resumed = manager.currentTasks.first;
      final paused = manager.currentTasks.last;
      expect(resumed.isRunning, isTrue);
      expect(paused.status, PreTranslationTaskStatus.paused);
      expect(paused.chapters.single.failedPages, {3});
      expect(paused.done + paused.failed, 8);

      manager.pause(resumed.id);
      await appdata.writeImplicitData();
      final disk = jsonDecode(
        await File('${directory.path}/implicitData.json').readAsString(),
      );
      final entries = disk[key] as List;
      expect(entries.map((entry) => entry['id']), ['system', 'manual']);
      expect(entries.every((entry) => entry['keepPaused'] == true), isTrue);
      expect(entries.first['chapters'].single['done'], 7);
    },
  );
}
