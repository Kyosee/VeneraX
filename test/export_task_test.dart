import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/export_tasks.dart';

/// Unit tests for the export-task data model (issue #54). These cover the
/// persistence/resume logic — the part that must survive serialization and an
/// app restart. The actual file/isolate work in [ExportTaskManager] needs a
/// running app + storage and is verified on-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ExportFormat ext / label / fromName', () {
    expect(ExportFormat.cbz.ext, '.cbz');
    expect(ExportFormat.pdf.ext, '.pdf');
    expect(ExportFormat.epub.ext, '.epub');
    expect(ExportFormat.veneraComics.ext, '.venera_comics');
    expect(ExportFormat.pdf.label, 'PDF');
    expect(ExportFormat.veneraComics.label, 'venera_comics');
    expect(ExportFormat.fromName('epub'), ExportFormat.epub);
    // Unknown name falls back to cbz rather than throwing.
    expect(ExportFormat.fromName('nonsense'), ExportFormat.cbz);
  });

  test('ExportComicRef key is stable and JSON round-trips', () {
    final ref = ExportComicRef(id: 'abc', comicTypeValue: 7, title: 'Title');
    expect(ref.key, 'abc_7');
    final restored = ExportComicRef.fromJson(ref.toJson());
    expect(restored.id, 'abc');
    expect(restored.comicTypeValue, 7);
    expect(restored.title, 'Title');
    expect(restored.key, 'abc_7');
  });

  ExportTask makeTask({
    ExportTaskStatus status = ExportTaskStatus.running,
    Set<String>? doneKeys,
  }) {
    return ExportTask(
      id: '1',
      folderPath: '/dest',
      format: ExportFormat.cbz,
      comics: [
        ExportComicRef(id: 'a', comicTypeValue: 1, title: 'A'),
        ExportComicRef(id: 'b', comicTypeValue: 1, title: 'B'),
        ExportComicRef(id: 'c', comicTypeValue: 1, title: 'C'),
        ExportComicRef(id: 'd', comicTypeValue: 1, title: 'D'),
      ],
      createdAt: DateTime(2024),
      status: status,
      doneKeys: doneKeys,
    );
  }

  test('progress / done reflect doneKeys', () {
    final task = makeTask(doneKeys: {'a_1'});
    expect(task.total, 4);
    expect(task.done, 1);
    expect(task.progress, closeTo(0.25, 1e-9));
  });

  test('an active task is persisted as paused so it is not auto-run on restart',
      () {
    final task = makeTask(status: ExportTaskStatus.running, doneKeys: {'a_1'});
    final json = task.toJson();
    expect(json['status'], ExportTaskStatus.paused.name);

    final restored = ExportTask.fromJson(json);
    expect(restored.status, ExportTaskStatus.paused);
    expect(restored.isActive, isTrue);
    // Resume must skip already-exported comics.
    expect(restored.doneKeys, {'a_1'});
    expect(restored.total, 4);
    expect(restored.folderPath, '/dest');
    expect(restored.format, ExportFormat.cbz);
  });

  test('a terminal task keeps its status across serialization', () {
    for (final status in [
      ExportTaskStatus.completed,
      ExportTaskStatus.canceled,
      ExportTaskStatus.failed,
    ]) {
      final task = makeTask(status: status);
      expect(task.isActive, isFalse);
      final restored = ExportTask.fromJson(task.toJson());
      expect(restored.status, status);
    }
  });
}
