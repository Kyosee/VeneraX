import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

PreTranslationTask taskWith(List<PreTranslationChapter> chapters) {
  return PreTranslationTask(
    id: 't',
    cid: 'c',
    sourceKey: 's',
    comicType: ComicType(0),
    title: 'Comic',
    chapters: chapters,
    createdAt: DateTime(2026),
  );
}

void main() {
  // The live activity channel exists because chapter counters commit one whole
  // group at a time — the resume cursor needs done+failed to stay a contiguous
  // committed prefix. These guard that the display layer reads the in-flight
  // groups without ever being able to move those counters.
  group('PreTranslationActivity', () {
    test('head stage is the lowest-numbered live group, not the newest', () {
      var activity = PreTranslationActivity();
      activity.groups[2] = PreTranslationGroupActivity(index: 2, pageCount: 4)
        ..stage = TranslationStage.rendering;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.translating;
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.recognizing;

      // Group 0 holds the commit cursor, so it is the honest answer to
      // "why hasn't the page count moved".
      expect(activity.headStage, TranslationStage.translating);
    });

    test('head stage is null with no live group', () {
      expect(PreTranslationActivity().headStage, isNull);
    });

    test('stage counts group concurrent work by phase', () {
      var activity = PreTranslationActivity();
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.recognizing;
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.recognizing;
      activity.groups[2] = PreTranslationGroupActivity(index: 2, pageCount: 4)
        ..stage = TranslationStage.fetching;

      expect(activity.stageCounts, {
        TranslationStage.recognizing: 2,
        TranslationStage.fetching: 1,
      });
    });

    test('live progress adds uncommitted pages to the committed value', () {
      // One chapter of 10 pages, 2 committed, a group with 3 pages resolved.
      var chapter = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 10,
        done: 2,
      );
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;

      expect(task.progress, closeTo(0.2, 1e-9));
      expect(activity.liveProgress(task), closeTo(0.5, 1e-9));
    });

    test('uncommitted pages only count toward the running chapter slice', () {
      // Two chapters: the second is running, so its in-flight pages fill half
      // of that chapter and therefore a quarter of the whole job.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 4),
        PreTranslationChapter(eid: '2', title: 'Ch 2', total: 4),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 2;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 2;

      expect(task.progress, closeTo(0.5, 1e-9));
      expect(activity.liveProgress(task), closeTo(0.75, 1e-9));
    });

    test('falls back to committed progress before a chapter starts', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 10, done: 5),
      ]);
      // chapterIndex 0 = nothing running yet.
      var activity = PreTranslationActivity();
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;

      expect(activity.liveProgress(task), task.progress);
    });

    test('falls back while the chapter page count is unresolved', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1'),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 2;

      expect(activity.liveProgress(task), 0);
    });

    test('never exceeds 1 when a group over-reports', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 3),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 9;

      expect(activity.liveProgress(task), 1.0);
    });

    test('dropping a group takes its pages back out of live progress', () {
      // An abandoned group (cancel/pause) is removed rather than committed, so
      // the bar has to fall back to the committed value instead of keeping
      // credit for work that will be redone.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 10, done: 2),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;
      expect(activity.liveProgress(task), closeTo(0.5, 1e-9));

      activity.groups.remove(0);
      expect(activity.uncommittedPages, 0);
      expect(activity.liveProgress(task), closeTo(0.2, 1e-9));
    });
  });
}
