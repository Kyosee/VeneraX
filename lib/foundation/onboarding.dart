import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' show OpenMode, SqliteException;
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/io.dart' show FilePath, writeStringAtomic;

class OnboardingState {
  const OnboardingState({
    this.setupCompleted = false,
    this.acceptedVersion = 0,
    this.acceptedAt,
    this.acceptedLanguage,
  });

  final bool setupCompleted;
  final int acceptedVersion;
  final String? acceptedAt;
  final String? acceptedLanguage;

  bool needsAgreement([int version = kDisclaimerVersion]) =>
      acceptedVersion < version;

  Map<String, Object?> toJson() => {
    'setupCompleted': setupCompleted,
    'acceptedVersion': acceptedVersion,
    'acceptedAt': acceptedAt,
    'acceptedLanguage': acceptedLanguage,
  };

  factory OnboardingState.fromJson(Map<String, dynamic> json) {
    final version = json['acceptedVersion'];
    final at = json['acceptedAt'];
    final language = json['acceptedLanguage'];
    final validAcceptance =
        version is int &&
        version > 0 &&
        at is String &&
        DateTime.tryParse(at) != null &&
        language is String &&
        language.isNotEmpty;
    return OnboardingState(
      setupCompleted: json['setupCompleted'] == true,
      acceptedVersion: validAcceptance ? version : 0,
      acceptedAt: validAcceptance ? at : null,
      acceptedLanguage: validAcceptance ? language : null,
    );
  }
}

/// Device-local state, deliberately absent from backup and sync archives.
class OnboardingStore {
  static final instance = OnboardingStore();
  static const fileName = 'onboarding.json';

  OnboardingState state = const OnboardingState();
  bool initialized = false;
  Object? loadError;
  late String _path;

  bool get blocksAutomaticTasks =>
      initialized &&
      (loadError != null || !state.setupCompleted || state.needsAgreement());

  Future<void> load(String dataPath) async {
    initialized = true;
    loadError = null;
    _path = FilePath.join(dataPath, fileName);
    try {
      final file = File(_path);
      if (await file.exists()) {
        try {
          final json = jsonDecode(await file.readAsString());
          if (json is! Map<String, dynamic> ||
              json['setupCompleted'] is! bool) {
            throw const FormatException();
          }
          state = OnboardingState.fromJson(json);
          // Accepted, unfinished setup may already contain restored data.
          if (!state.setupCompleted &&
              state.acceptedVersion == 0 &&
              await _hasUserData(dataPath)) {
            await _save(
              OnboardingState(
                setupCompleted: true,
                acceptedVersion: state.acceptedVersion,
                acceptedAt: state.acceptedAt,
                acceptedLanguage: state.acceptedLanguage,
              ),
            );
          }
          return;
        } on FormatException {
          // A damaged record cannot stand in for acceptance.
        }
      }
      final existing = await hasExistingInstallation(dataPath);
      await Directory(dataPath).create(recursive: true);
      await _save(OnboardingState(setupCompleted: existing));
    } catch (error) {
      loadError = error;
    }
  }

  /// Empty stores created by an interrupted setup are not evidence of use.
  static Future<bool> _hasUserData(String dataPath) async {
    final appData = File(FilePath.join(dataPath, 'appdata.json'));
    if (await appData.exists()) {
      try {
        final json = jsonDecode(await appData.readAsString());
        if (json is Map &&
            json['searchHistory'] is List &&
            (json['searchHistory'] as List).isNotEmpty) {
          return true;
        }
      } on FormatException {
        // Other stores may still contain usable data.
      }
    }
    final sources = Directory(FilePath.join(dataPath, 'comic_source'));
    if (await sources.exists()) {
      await for (final entry in sources.list(followLinks: false)) {
        if (entry is File &&
            entry.path.endsWith('.js') &&
            await entry.length() > 0) {
          return true;
        }
      }
    }
    for (final store in const {
      'history.db': ['history'],
      'local.db': ['comics'],
      'read_later.db': ['read_later'],
      'data/venera.db': [
        'comics',
        'favorites',
        'history_events',
        'local_library_items',
      ],
      'local_favorite.db': <String>[],
    }.entries) {
      final file = File(FilePath.join(dataPath, store.key));
      if (!await file.exists() || await file.length() == 0) continue;
      try {
        // Startup owns these files here; close the read-only probe before any await.
        final db = openRawDatabase(file.path, mode: OpenMode.readOnly);
        try {
          for (final row in db.select(
            "SELECT name FROM sqlite_master WHERE type='table'",
          )) {
            final name = row['name'] as String;
            final quoted = '"${name.replaceAll('"', '""')}"';
            if (store.key == 'local_favorite.db') {
              final columns = db
                  .select('PRAGMA table_info($quoted)')
                  .map((row) => row['name'])
                  .toSet();
              if (!columns.containsAll(['id', 'name', 'cover_path'])) continue;
            } else if (!store.value.contains(name)) {
              continue;
            }
            if (db.select('SELECT 1 FROM $quoted LIMIT 1').isNotEmpty) {
              return true;
            }
          }
        } finally {
          db.dispose();
        }
      } on SqliteException catch (error) {
        // A damaged database cannot prove setup is complete.
        if (error.resultCode != 11 && error.resultCode != 26) rethrow;
      }
    }
    return false;
  }

  /// Run before appdata or database initialization creates empty stores.
  static Future<bool> hasExistingInstallation(String dataPath) async {
    for (final name in const [
      'appdata.json',
      'implicitData.json',
      'history.db',
      'local_favorite.db',
      'read_later.db',
      'local.db',
      'local_path',
      'downloading_tasks.json',
      'comic_source',
      'data/venera.db',
    ]) {
      if (await FileSystemEntity.type(FilePath.join(dataPath, name)) !=
          FileSystemEntityType.notFound) {
        return true;
      }
    }
    return false;
  }

  Future<void> accept(
    String language, {
    int version = kDisclaimerVersion,
  }) async {
    if (loadError != null) throw StateError('Onboarding state is unavailable');
    await _save(
      OnboardingState(
        setupCompleted: state.setupCompleted,
        acceptedVersion: version,
        acceptedAt: DateTime.now().toUtc().toIso8601String(),
        acceptedLanguage: language,
      ),
    );
  }

  Future<void> completeSetup() async {
    if (loadError != null || state.needsAgreement()) {
      throw StateError('Agreement acceptance is required');
    }
    await _save(
      OnboardingState(
        setupCompleted: true,
        acceptedVersion: state.acceptedVersion,
        acceptedAt: state.acceptedAt,
        acceptedLanguage: state.acceptedLanguage,
      ),
    );
  }

  Future<void> _save(OnboardingState next) async {
    await writeStringAtomic(_path, jsonEncode(next.toJson()));
    state = next;
  }
}
