import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/ordered_group_committer.dart';
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

    test('partly-finished pages move the bar before the group commits', () {
      // The point of the fractional weights: one group of 4 walking fetch →
      // recognize → translate → render must show four distinct values, not sit
      // at 0 and then jump when its counters commit.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      var group = PreTranslationGroupActivity(index: 0, pageCount: 4);
      activity.groups[0] = group;

      var seen = <double>[];
      for (var completed in [
        4 * fetchedPageWeight, // all downloaded
        4 * 0.55, // all recognized
        4 * 0.8, // translation returned
        4.0, // drawn
      ]) {
        group.completedPages = completed;
        seen.add(activity.liveProgress(task));
      }

      expect(seen.first, greaterThan(0));
      expect(seen.last, closeTo(0.5, 1e-9));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
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

    test('failed pages keep the page counter moving with the bar', () {
      // A page that fails is finished work: it moves the percentage, so the
      // counter has to move with it. Reporting successes only froze the number
      // whenever a batch failed, making a running job look stuck.
      var chapter = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 10,
        done: 4,
        failed: 2,
      );
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1'
        ..bufferedDone = 1
        ..bufferedFailed = 2;

      expect(activity.liveDone(task), 5);
      expect(activity.liveFailed(task), 4);
      expect(activity.liveProcessed(task), 9);
      // Same set the bar counts.
      expect(
        activity.liveProcessed(task) / chapter.total,
        closeTo(activity.liveProgress(task), 1e-9),
      );
    });
  });

  // Groups overlap and may finish out of order, but their counts commit in
  // strict group order so done+failed stays a contiguous prefix for the resume
  // cursor. These guard the buffered-credit channel that keeps the display
  // honest while a finished group waits behind a slower predecessor.
  group('applyGroupResult', () {
    test('a group finishing out of order does not make the live figures dip', () {
      // Group 1 wins the race while group 0 is still on the LLM. Its counts
      // cannot move the cursor, so without buffered credit its pages would
      // vanish from the display the moment it left the in-flight map.
      var chapter = PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8);
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 4 * 0.8; // translated, waiting to be drawn
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..completedPages = 4; // drawn
      var before = activity.liveProgress(task);

      PreTranslationTaskManager.applyGroupResult(
        OrderedGroupCommitter(0),
        chapter,
        activity,
        1,
        GroupResult(4, 0, {}),
      );

      expect(chapter.done, 0, reason: 'cursor cannot move past group 0');
      expect(activity.bufferedDone, 4);
      expect(activity.groups.containsKey(1), isFalse);
      expect(activity.liveProgress(task), closeTo(before, 1e-9));

      // The chapter still reads as unfinished: group 0's pages are neither
      // committed nor buffered, so a premature "translated" tick is impossible.
      var live = PreTranslationTaskManager.livePagesFor(chapter, activity);
      expect(live, (done: 4, processed: 4));
      expect(live.processed, lessThan(chapter.total));
    });

    test("every group's pages leave the buffer when the prefix commits", () {
      var chapter = PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8);
      var activity = PreTranslationActivity()..chapterEid = '1';
      var committer = OrderedGroupCommitter(0);

      PreTranslationTaskManager.applyGroupResult(
        committer,
        chapter,
        activity,
        1,
        GroupResult(3, 1, {5}),
      );
      expect((chapter.done, chapter.failed), (0, 0));
      expect((activity.bufferedDone, activity.bufferedFailed), (3, 1));

      // Group 0 releases itself and the buffered group 1 in one go.
      PreTranslationTaskManager.applyGroupResult(
        committer,
        chapter,
        activity,
        0,
        GroupResult(4, 0, {}),
      );

      expect((chapter.done, chapter.failed), (7, 1));
      expect(chapter.failedPages, {5});
      expect(activity.bufferedPages, 0, reason: 'buffer must balance to zero');
      expect(
        PreTranslationTaskManager.livePagesFor(chapter, activity),
        (done: 7, processed: 8),
      );
    });

    test('buffered pages only credit the chapter they belong to', () {
      var running = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 8,
        done: 4,
      );
      var other = PreTranslationChapter(
        eid: '2',
        title: 'Ch 2',
        total: 8,
        done: 4,
      );
      var activity = PreTranslationActivity()
        ..chapterEid = '1'
        ..bufferedDone = 3
        ..bufferedFailed = 1;

      expect(
        PreTranslationTaskManager.livePagesFor(running, activity),
        (done: 7, processed: 8),
      );
      expect(
        PreTranslationTaskManager.livePagesFor(other, activity),
        (done: 4, processed: 4),
      );
      expect(
        PreTranslationTaskManager.livePagesFor(running, null),
        (done: 4, processed: 4),
      );
    });
  });
}
