import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/source_library.dart';

void main() {
  group('stableLibraryId', () {
    test('is deterministic for the same URL', () {
      final a = stableLibraryId('https://example.com/index.json');
      final b = stableLibraryId('https://example.com/index.json');
      expect(a, b);
    });

    test('normalizes case and trailing slashes so the same logical library '
        'converges to one id across devices', () {
      final canonical = stableLibraryId('https://example.com/repo');
      expect(stableLibraryId('https://Example.com/repo/'), canonical);
      expect(stableLibraryId('  https://EXAMPLE.com/repo  '), canonical);
      expect(stableLibraryId('https://example.com/repo///'), canonical);
    });

    test('differs for different URLs', () {
      expect(
        stableLibraryId('https://a.com/index.json'),
        isNot(stableLibraryId('https://b.com/index.json')),
      );
    });

    test('produces a short stable-length token', () {
      expect(stableLibraryId('https://example.com/index.json').length, 12);
      expect(stableLibraryId('').length, 12);
    });
  });

  group('defaultLibraryName', () {
    test('uses host when path is just an index file', () {
      expect(
        defaultLibraryName('https://example.com/index.json'),
        'example.com',
      );
      expect(defaultLibraryName('https://example.com'), 'example.com');
      expect(defaultLibraryName('https://example.com/'), 'example.com');
    });

    test('appends a distinguishing path segment so co-hosted repos differ', () {
      expect(
        defaultLibraryName('https://example.com/repoA/index.json'),
        'example.com/repoA',
      );
      expect(
        defaultLibraryName('https://example.com/repoB/index.json'),
        'example.com/repoB',
      );
    });

    test('falls back to the raw string when not a URL', () {
      expect(defaultLibraryName('not a url'), 'not a url');
    });
  });

  group('ComicSourceLibrary serialization', () {
    test('round-trips through JSON', () {
      final lib = ComicSourceLibrary(
        id: 'abc123',
        name: 'My Library',
        url: 'https://example.com/index.json',
        enabled: false,
        priority: 3,
        lastChecked: 1700000000000,
      );
      final restored = ComicSourceLibrary.fromJson(lib.toJson());
      expect(restored.id, lib.id);
      expect(restored.name, lib.name);
      expect(restored.url, lib.url);
      expect(restored.enabled, lib.enabled);
      expect(restored.priority, lib.priority);
      expect(restored.lastChecked, lib.lastChecked);
    });

    test('derives a stable id from url when id is missing in legacy json', () {
      final restored = ComicSourceLibrary.fromJson({
        'name': 'Legacy',
        'url': 'https://example.com/index.json',
      });
      expect(restored.id, stableLibraryId('https://example.com/index.json'));
      expect(restored.enabled, isTrue); // defaults to enabled
    });
  });

  group('SourceProvenance serialization', () {
    test('round-trips through JSON', () {
      final prov = SourceProvenance(
        libraryIds: ['lib1', 'lib2'],
        originId: 'lib1',
        updateLibraryId: 'lib2',
      );
      final restored = SourceProvenance.fromJson(prov.toJson());
      expect(restored.libraryIds, ['lib1', 'lib2']);
      expect(restored.originId, 'lib1');
      expect(restored.updateLibraryId, 'lib2');
    });

    test('defaults to empty offering list', () {
      final prov = SourceProvenance.fromJson({});
      expect(prov.libraryIds, isEmpty);
      expect(prov.originId, isNull);
    });
  });
}
