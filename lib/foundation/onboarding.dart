import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/disclaimer_content.dart';
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
