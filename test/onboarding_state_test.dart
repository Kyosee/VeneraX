import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/onboarding.dart';

class _UnreadableOnboardingFile implements File {
  _UnreadableOnboardingFile(this.path);

  @override
  final String path;

  @override
  Future<bool> exists() async => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    throw FileSystemException('Fixture read failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File record;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venerax_onboarding_');
    record = File('${directory.path}/${OnboardingStore.fileName}');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'a fresh installation requires agreement and the remaining setup',
    () async {
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.initialized, isTrue);
      expect(store.loadError, isNull);
      expect(store.state.setupCompleted, isFalse);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
      expect(await record.exists(), isTrue);
      await expectLater(store.completeSetup(), throwsStateError);
      expect(store.state.setupCompleted, isFalse);
    },
  );

  for (final marker in ['appdata.json', 'history.db', 'comic_source']) {
    test('existing $marker skips setup but still requires agreement', () async {
      if (marker == 'comic_source') {
        await Directory('${directory.path}/$marker').create();
      } else {
        await File('${directory.path}/$marker').create();
      }
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);

      await store.accept('zh-CN');

      expect(store.state.setupCompleted, isTrue);
      expect(store.blocksAutomaticTasks, isFalse);
      expect(
        await FileSystemEntity.type('${directory.path}/$marker'),
        marker == 'comic_source'
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file,
      );
    });
  }

  test(
    'unfinished setup stays new after initialization creates app data',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      await File('${directory.path}/appdata.json').writeAsString('{}');
      await File('${directory.path}/history.db').create();
      await Directory('${directory.path}/comic_source').create();

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);

      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.state.needsAgreement(), isTrue);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
    },
  );

  test(
    'acceptance persists its version, UTC time and language before setup',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);

      await store.accept('zh-TW');

      expect(store.state.acceptedVersion, kDisclaimerVersion);
      expect(store.state.acceptedLanguage, 'zh-TW');
      expect(DateTime.parse(store.state.acceptedAt!).isUtc, isTrue);
      expect(store.state.needsAgreement(), isFalse);
      expect(store.state.setupCompleted, isFalse);
      expect(store.blocksAutomaticTasks, isTrue);
      final saved = jsonDecode(await record.readAsString()) as Map;
      expect(saved['acceptedVersion'], kDisclaimerVersion);
      expect(saved['acceptedAt'], store.state.acceptedAt);
      expect(saved['acceptedLanguage'], 'zh-TW');
      expect(saved['setupCompleted'], isFalse);

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);
      expect(nextLaunch.state.acceptedAt, store.state.acceptedAt);
      expect(nextLaunch.state.acceptedLanguage, 'zh-TW');
      expect(nextLaunch.state.needsAgreement(), isFalse);
      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
    },
  );

  test('completed setup does not prompt again on the next launch', () async {
    final store = OnboardingStore();
    await store.load(directory.path);
    await store.accept('en-US');
    final acceptedAt = store.state.acceptedAt;

    await store.completeSetup();

    final nextLaunch = OnboardingStore();
    await nextLaunch.load(directory.path);
    expect(nextLaunch.state.setupCompleted, isTrue);
    expect(nextLaunch.state.needsAgreement(), isFalse);
    expect(nextLaunch.blocksAutomaticTasks, isFalse);
    expect(nextLaunch.state.acceptedAt, acceptedAt);
    expect(nextLaunch.state.acceptedLanguage, 'en-US');
  });

  test(
    'a higher agreement version needs acceptance without repeating setup',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);
      await store.accept('en-US');
      await store.completeSetup();
      final nextVersion = kDisclaimerVersion + 1;

      expect(store.state.needsAgreement(nextVersion), isTrue);
      expect(store.state.setupCompleted, isTrue);

      await store.accept('zh-CN', version: nextVersion);

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);
      expect(nextLaunch.state.acceptedVersion, nextVersion);
      expect(nextLaunch.state.needsAgreement(nextVersion), isFalse);
      expect(nextLaunch.state.needsAgreement(kDisclaimerVersion), isFalse);
      expect(nextLaunch.state.setupCompleted, isTrue);
      expect(nextLaunch.state.acceptedLanguage, 'zh-CN');
    },
  );

  for (final contents in ['{"acceptedVersion":', '[]', '{}']) {
    test(
      'damaged record $contents cannot authorize an existing installation',
      () async {
        final appData = File('${directory.path}/appdata.json');
        await appData.writeAsString('{"keep":"existing data"}');
        await record.writeAsString(contents);
        final store = OnboardingStore();

        await store.load(directory.path);

        expect(store.loadError, isNull);
        expect(store.state.setupCompleted, isTrue);
        expect(store.state.acceptedVersion, 0);
        expect(store.state.needsAgreement(), isTrue);
        expect(store.blocksAutomaticTasks, isTrue);
        expect(await appData.readAsString(), '{"keep":"existing data"}');
      },
    );
  }

  final invalidAcceptance = <String, Map<String, Object?>>{
    'missing version': {'acceptedVersion': null},
    'non-integer version': {'acceptedVersion': '$kDisclaimerVersion'},
    'zero version': {'acceptedVersion': 0},
    'missing time': {'acceptedAt': null},
    'invalid time': {'acceptedAt': 'not a date'},
    'missing language': {'acceptedLanguage': null},
    'empty language': {'acceptedLanguage': ''},
  };
  for (final entry in invalidAcceptance.entries) {
    test('${entry.key} cannot count as acceptance', () async {
      await record.writeAsString(
        jsonEncode({
          'setupCompleted': true,
          'acceptedVersion': kDisclaimerVersion,
          'acceptedAt': '2026-11-10T00:00:00.000Z',
          'acceptedLanguage': 'zh-CN',
          ...entry.value,
        }),
      );
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, 0);
      expect(store.state.acceptedAt, isNull);
      expect(store.state.acceptedLanguage, isNull);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
    });
  }

  test(
    'a failed acceptance save preserves memory and the saved record',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);
      final previousState = store.state;
      final previousRecord = await record.readAsString();
      await Directory('${record.path}.tmp').create();

      await expectLater(
        store.accept('zh-CN'),
        throwsA(isA<FileSystemException>()),
      );

      expect(store.state, same(previousState));
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
      expect(await record.readAsString(), previousRecord);
    },
  );

  test('a failed completion save does not skip setup on restart', () async {
    final store = OnboardingStore();
    await store.load(directory.path);
    await store.accept('zh-CN');
    final previousState = store.state;
    await Directory('${record.path}.tmp').create();

    await expectLater(
      store.completeSetup(),
      throwsA(isA<FileSystemException>()),
    );

    expect(store.state, same(previousState));
    final nextLaunch = OnboardingStore();
    await nextLaunch.load(directory.path);
    expect(nextLaunch.state.needsAgreement(), isFalse);
    expect(nextLaunch.state.setupCompleted, isFalse);
    expect(nextLaunch.blocksAutomaticTasks, isTrue);
  });

  for (final source in ['appdata.json', 'implicitData.json']) {
    test('acceptance flags in $source do not authorize this device', () async {
      await File('${directory.path}/$source').writeAsString(
        jsonEncode({
          'disclaimerConsented': true,
          'settings': {'disclaimerConsented': true},
          'setupCompleted': true,
          'acceptedVersion': kDisclaimerVersion,
          'acceptedAt': '2026-11-10T00:00:00.000Z',
          'acceptedLanguage': 'zh-CN',
        }),
      );
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, 0);
      expect(store.state.acceptedAt, isNull);
      expect(store.state.acceptedLanguage, isNull);
      expect(store.blocksAutomaticTasks, isTrue);
    });
  }

  test(
    'a read failure blocks actions until the saved record can be retried',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      await firstLaunch.accept('en-US');
      await firstLaunch.completeSetup();
      final previousRecord = await record.readAsString();
      final store = OnboardingStore();

      await IOOverrides.runZoned(
        () => store.load(directory.path),
        createFile: (path) => _UnreadableOnboardingFile(path),
      );

      expect(store.initialized, isTrue);
      expect(store.loadError, isA<FileSystemException>());
      expect(store.blocksAutomaticTasks, isTrue);
      await expectLater(store.accept('zh-CN'), throwsStateError);
      await expectLater(store.completeSetup(), throwsStateError);
      expect(await record.readAsString(), previousRecord);

      await store.load(directory.path);

      expect(store.loadError, isNull);
      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, kDisclaimerVersion);
      expect(store.state.acceptedLanguage, 'en-US');
      expect(store.blocksAutomaticTasks, isFalse);
      expect(await record.readAsString(), previousRecord);
    },
  );
}
