import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/sync_skip.dart';

/// Synced settings no user should keep off sync: the version lineage, the
/// retention count (devices with different counts prune each other), consent
/// state, and collections, which are comic data like favorites.
const _neverSkippable = {
  'dataVersion',
  'webdavBackupRetention',
  'requireDisclaimerConsent',
  'disclaimerConsented',
  'comicCollections',
};

SyncSkipCategory _cat(String id) =>
    syncSkipCategories.firstWhere((c) => c.id == id);

void main() {
  test('every synced default setting belongs to a skip category', () {
    final deviceLocal = Appdata.syncDisabledFields(const []);
    final categorized = {for (final c in syncSkipCategories) ...c.keys};
    final settings = appdata.toJson()['settings'] as Map<String, dynamic>;
    final unclassified = settings.keys
        .where((k) => !deviceLocal.contains(k))
        .where((k) => !categorized.contains(k))
        .where((k) => !_neverSkippable.contains(k))
        .toList();
    expect(unclassified, isEmpty);
  });

  test('categories stay disjoint and never list device-local keys', () {
    final deviceLocal = Appdata.syncDisabledFields(const []);
    final seen = <String>{};
    for (final c in syncSkipCategories) {
      for (final key in c.keys) {
        expect(deviceLocal, isNot(contains(key)), reason: key);
        expect(seen.add(key), isTrue, reason: 'duplicate $key');
      }
    }
  });

  test('a token covers keys added to the category later', () {
    final skipped = Appdata.syncDisabledFields(const ['@reading']);
    expect(skipped, contains('chapterOrderOverrides'));
    expect(skipped, contains('imageWidthPercent'));
  });

  test('pre-token selections upgrade to the whole category', () {
    const legacy = 'color, theme_mode, comicDisplayMode, comicTileScale';
    final selection = SyncSkipSelection.parse(legacy);
    expect(selection.isSelected(_cat('appearance')), isTrue);
    expect(selection.otherFields, isEmpty);
    final saved = selection.serialize();
    expect(saved, startsWith('@appearance, color'));
    expect(saved, contains('homeSections'));
  });

  test('saved value still lists every key for older installs', () {
    final saved = SyncSkipSelection.parse(
      '',
    ).withCategory(_cat('explore'), true).serialize();
    final entries = saved.split(',').map((e) => e.trim()).toSet();
    expect(entries, containsAll(_cat('explore').keys));
  });

  test('deselecting a category clears its keys and legacy signature', () {
    final selection = SyncSkipSelection.parse(
      'favorites, newFavoriteAddTo, quickFavorite, autoCloseFavoritePanel',
    ).withCategory(_cat('favorites'), false);
    expect(selection.isSelected(_cat('favorites')), isFalse);
    expect(selection.serialize(), isEmpty);
  });

  test('partial selections complete, unknown entries survive', () {
    var selection = SyncSkipSelection.parse('readerMode, @future, myKey');
    expect(selection.isPartial(_cat('reading')), isTrue);
    expect(selection.otherFields, ['myKey']);
    selection = selection.withCategory(_cat('reading'), true);
    expect(selection.isPartial(_cat('reading')), isFalse);
    expect(selection.isSelected(_cat('reading')), isTrue);
    final saved = selection.withoutOtherFields().serialize();
    expect(saved, contains('@future'));
    expect(saved, isNot(contains('myKey')));
  });

  test('select all then deselect all returns to empty', () {
    final all = SyncSkipSelection.parse('').withAll(true);
    expect(syncSkipCategories.every(all.isSelected), isTrue);
    expect(all.withAll(false).serialize(), isEmpty);
  });

  group('search history', () {
    late Directory tempDir;
    late String originalDataPath;
    late String originalFields;
    late List<String> originalHistory;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('venera-sync-skip-');
      originalDataPath = App.dataPath;
      originalFields = appdata.settings['disableSyncFields'];
      originalHistory = List.of(appdata.searchHistory);
      App.dataPath = tempDir.path;
    });

    tearDown(() async {
      await appdata.saveData(false);
      appdata.settings['disableSyncFields'] = originalFields;
      appdata.searchHistory = originalHistory;
      App.dataPath = originalDataPath;
      await tempDir.delete(recursive: true);
    });

    test('skipped history is neither uploaded nor overwritten', () async {
      appdata.settings['disableSyncFields'] = '@searchHistory';
      appdata.searchHistory = ['local'];
      await appdata.saveData(false);
      final synced = jsonDecode(
        await File('${tempDir.path}/syncdata.json').readAsString(),
      );
      expect((synced as Map).containsKey('searchHistory'), isFalse);

      appdata.syncData({
        'settings': <String, dynamic>{},
        'searchHistory': ['remote'],
      });
      expect(appdata.searchHistory, ['local']);
    });

    test('a backup without history leaves the local list alone', () {
      appdata.settings['disableSyncFields'] = '';
      appdata.searchHistory = ['local'];
      appdata.syncData({'settings': <String, dynamic>{}});
      expect(appdata.searchHistory, ['local']);
      appdata.syncData({
        'settings': <String, dynamic>{},
        'searchHistory': ['remote'],
      });
      expect(appdata.searchHistory, ['remote']);
    });
  });
}
