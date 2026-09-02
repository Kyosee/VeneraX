import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/source_library.dart';

void main() {
  group('stableLibraryId', () {
    test('is deterministic for the same URL', () {
      final a = stableLibraryId('https://example.com/index.json');
      final b = stableLibraryId('https://example.com/index.json');
      expect(a, b);
    });

    test('normalizes scheme, host, and trailing slashes so the same logical '
        'library converges to one id across devices', () {
      final canonical = stableLibraryId('https://example.com/repo');
      expect(stableLibraryId('HTTPS://Example.com/repo/'), canonical);
      expect(stableLibraryId('  https://EXAMPLE.com/repo  '), canonical);
      expect(stableLibraryId('https://example.com/repo///'), canonical);
    });

    test('preserves case-sensitive path and query components', () {
      expect(
        stableLibraryId('https://example.com/Repo/index.json'),
        isNot(stableLibraryId('https://example.com/repo/index.json')),
      );
      expect(
        stableLibraryId('https://example.com/index.json?branch=Main'),
        isNot(stableLibraryId('https://example.com/index.json?branch=main')),
      );
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

  group('allocateLibraryId', () {
    test(
      'uses a deterministic full digest when a stale id occupies the hash',
      () {
        const url = 'https://example.com/index.json';
        final base = stableLibraryId(url);
        final allocated = allocateLibraryId(url, [base]);

        expect(allocated, isNot(base));
        expect(allocated.length, 32);
        expect(allocateLibraryId(url, ['other', base]), allocated);
        expect(allocateLibraryId(url, [base, 'other']), allocated);
      },
    );

    test('compares current URLs instead of an id left behind by an edit', () {
      const oldUrl = 'https://example.com/old/index.json';
      const currentUrl = 'https://example.com/current/index.json';
      final editedLibrary = ComicSourceLibrary(
        id: stableLibraryId(oldUrl),
        name: 'Edited',
        url: currentUrl,
      );

      expect(findLibraryByUrl([editedLibrary], oldUrl), isNull);
      expect(findLibraryByUrl([editedLibrary], currentUrl), editedLibrary);
      expect(
        allocateLibraryId(oldUrl, [editedLibrary.id]),
        isNot(editedLibrary.id),
      );
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

  group('reconcileOriginDeclarations', () {
    test('mirrors the origin of every locally installed source', () {
      final result = reconcileOriginDeclarations(
        provenance: {
          'a': SourceProvenance(originId: 'lib1', libraryIds: ['lib1']).toJson(),
          'b': SourceProvenance(originId: 'lib2').toJson(),
        },
        declarations: {},
      );
      expect(result, {'a': 'lib1', 'b': 'lib2'});
    });

    test('keeps declarations for sources this device does not have', () {
      final result = reconcileOriginDeclarations(
        provenance: {'a': SourceProvenance(originId: 'lib1').toJson()},
        declarations: {'a': 'lib2', 'onlyOnOtherDevice': 'lib3'},
      );
      expect(result, {'a': 'lib1', 'onlyOnOtherDevice': 'lib3'});
    });

    test('drops a declaration once the local record has no origin left', () {
      final result = reconcileOriginDeclarations(
        provenance: {'a': SourceProvenance(libraryIds: ['lib1']).toJson()},
        declarations: {'a': 'lib1'},
      );
      expect(result, isEmpty);
    });

    test('drops uninstalled keys named in removedKeys', () {
      final result = reconcileOriginDeclarations(
        provenance: {},
        declarations: {'a': 'lib1', 'b': 'lib2'},
        removedKeys: ['a'],
      );
      expect(result, {'b': 'lib2'});
    });
  });

  group('adoptOriginDeclarations', () {
    test('stamps an origin onto a source that has none', () {
      final provenance = <String, dynamic>{
        'a': SourceProvenance(libraryIds: ['lib2']).toJson(),
      };
      final changed = adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'lib1'},
        knownLibraryIds: {'lib1', 'lib2'},
      );

      expect(changed, {'a'});
      final prov = SourceProvenance.fromJson(
        Map<String, dynamic>.from(provenance['a'] as Map),
      );
      expect(prov.originId, 'lib1');
      expect(prov.libraryIds, containsAll(['lib1', 'lib2']));
      // The winner has to be recomputed by the next check.
      expect(prov.updateLibraryId, isNull);
    });

    test('creates a record for a source with no provenance at all', () {
      final provenance = <String, dynamic>{};
      final changed = adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'lib1'},
        knownLibraryIds: {'lib1'},
      );

      expect(changed, {'a'});
      expect(
        SourceProvenance.fromJson(
          Map<String, dynamic>.from(provenance['a'] as Map),
        ).originId,
        'lib1',
      );
    });

    test('replaces a different local origin', () {
      final provenance = <String, dynamic>{
        'a': SourceProvenance(originId: 'lib2', updateLibraryId: 'lib2')
            .toJson(),
      };
      final changed = adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'lib1'},
        knownLibraryIds: {'lib1', 'lib2'},
      );

      expect(changed, {'a'});
      expect(
        SourceProvenance.fromJson(
          Map<String, dynamic>.from(provenance['a'] as Map),
        ).originId,
        'lib1',
      );
    });

    test('reports no change when the origin already matches', () {
      final provenance = <String, dynamic>{
        'a': SourceProvenance(originId: 'lib1', updateLibraryId: 'lib1')
            .toJson(),
      };
      final changed = adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'lib1'},
        knownLibraryIds: {'lib1'},
      );

      expect(changed, isEmpty);
      // An unchanged record keeps its resolved winner.
      expect(
        SourceProvenance.fromJson(
          Map<String, dynamic>.from(provenance['a'] as Map),
        ).updateLibraryId,
        'lib1',
      );
    });

    test('ignores a declaration naming a library this device lacks', () {
      final provenance = <String, dynamic>{
        'a': SourceProvenance(originId: 'lib2').toJson(),
      };
      final changed = adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'gone', 'b': 'gone'},
        knownLibraryIds: {'lib2'},
      );

      expect(changed, isEmpty);
      expect(
        SourceProvenance.fromJson(
          Map<String, dynamic>.from(provenance['a'] as Map),
        ).originId,
        'lib2',
      );
      expect(provenance.containsKey('b'), isFalse);
    });

    test('never deletes a local record the incoming data omits', () {
      final provenance = <String, dynamic>{
        'a': SourceProvenance(originId: 'lib1').toJson(),
        'localOnly': SourceProvenance(originId: 'lib2').toJson(),
      };
      adoptOriginDeclarations(
        provenance: provenance,
        declarations: {'a': 'lib1'},
        knownLibraryIds: {'lib1', 'lib2'},
      );

      expect(provenance.keys, containsAll(['a', 'localOnly']));
      expect(
        SourceProvenance.fromJson(
          Map<String, dynamic>.from(provenance['localOnly'] as Map),
        ).originId,
        'lib2',
      );
    });
  });
}
