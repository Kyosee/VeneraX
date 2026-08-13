import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';

void main() {
  group('PreTranslationChapter JSON', () {
    test('round-trips failedPages', () {
      var c = PreTranslationChapter(
        eid: '3',
        title: 'Ch 3',
        total: 10,
        done: 7,
        failed: 3,
        failedPages: {2, 5, 9},
      );
      var back = PreTranslationChapter.fromJson(c.toJson());
      expect(back.eid, '3');
      expect(back.total, 10);
      expect(back.done, 7);
      expect(back.failed, 3);
      expect(back.failedPages, {2, 5, 9});
    });

    test('defaults failedPages to empty for legacy json without the field', () {
      var back = PreTranslationChapter.fromJson({
        'eid': '0',
        'title': '',
        'total': 5,
        'done': 3,
        'failed': 2,
      });
      expect(back.failedPages, isEmpty);
      // A legacy chapter still reports failures so a retry is offered; it just
      // falls back to a whole-chapter rescan.
      expect(back.failed, 2);
    });

    test('tolerates string-encoded indices', () {
      var back = PreTranslationChapter.fromJson({
        'eid': '1',
        'title': 'x',
        'failedPages': ['4', 8, 'bad'],
      });
      expect(back.failedPages, {4, 8});
    });
  });

  group('PreTranslationTask', () {
    PreTranslationTask taskWith(List<PreTranslationChapter> chapters) {
      return PreTranslationTask(
        id: '1',
        cid: 'c',
        sourceKey: 's',
        comicType: const ComicType(0),
        title: 't',
        chapters: chapters,
        createdAt: DateTime(2026, 1, 1),
      );
    }

    test('hasFailures reflects any chapter with failures', () {
      expect(
        taskWith([PreTranslationChapter(eid: '0', title: '', failed: 0)])
            .hasFailures,
        isFalse,
      );
      expect(
        taskWith([
          PreTranslationChapter(eid: '0', title: '', done: 5, failed: 0),
          PreTranslationChapter(eid: '1', title: '', failed: 2),
        ]).hasFailures,
        isTrue,
      );
    });

    test('hasFailures ignores a canceled chapter', () {
      // Both the forward loop and the retry sweep skip a canceled chapter, so
      // its failures can never be re-run: offering a retry would do nothing.
      expect(
        taskWith([
          PreTranslationChapter(
            eid: '0',
            title: '',
            total: 10,
            done: 4,
            failed: 2,
            canceled: true,
            failedPages: {4, 5},
          ),
        ]).hasFailures,
        isFalse,
      );
      // A live chapter alongside a canceled one still offers the retry.
      expect(
        taskWith([
          PreTranslationChapter(
            eid: '0',
            title: '',
            failed: 2,
            canceled: true,
            failedPages: {0, 1},
          ),
          PreTranslationChapter(
            eid: '1',
            title: '',
            failed: 1,
            failedPages: {3},
          ),
        ]).hasFailures,
        isTrue,
      );
    });

    test('resume-cursor invariant: a successful retry preserves done+failed',
        () {
      // A retry moves a page failed->done. The forward resume cursor is
      // startIndex = done + failed, so that sum must not change or resume would
      // skip/repeat pages. This mirrors _markRetrySuccess.
      var c = PreTranslationChapter(
        eid: '0',
        title: '',
        total: 10,
        done: 7,
        failed: 3,
        failedPages: {2, 5, 9},
      );
      var before = c.done + c.failed;

      // Simulate _markRetrySuccess(index: 5).
      expect(c.failedPages.remove(5), isTrue);
      c.done++;
      c.failed--;

      expect(c.done + c.failed, before);
      expect(c.failed, 2);
      expect(c.failedPages, {2, 9});
      // failedPages length stays in step with the failed count.
      expect(c.failedPages.length, c.failed);
    });
  });
}
