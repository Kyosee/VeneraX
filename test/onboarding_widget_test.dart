import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/onboarding_page.dart';
import 'package:venera/pages/startup_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String dataPath;
  final store = OnboardingStore.instance;

  setUpAll(AppTranslation.init);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('venerax-onboarding-ui-');
    dataPath = App.dataPath;
    App.dataPath = temp.path;
    appdata.settings['language'] = 'en-US';
    appdata.settings['authorizationRequired'] = false;
    await store.load(temp.path);
  });
  tearDown(() async {
    App.dataPath = dataPath;
    AuthPage.isActive = false;
    appdata.settings['appLockType'] = 'biometric';
    appdata.settings['authorizationRequired'] = false;
    await temp.delete(recursive: true);
  });

  Future<void> panel(
    WidgetTester tester, {
    required Size size,
    required Future<void> Function() accept,
    bool update = false,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: AgreementPanel(
                isUpdate: update,
                onAccepted: accept,
                onDeclined: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    for (final size in [const Size(320, 700), const Size(1100, 760)]) {
      testWidgets(
        'agreement fits $language on $size and keeps consent visible',
        (tester) async {
          appdata.settings['language'] = language;
          await panel(
            tester,
            size: size,
            update: true,
            textScale: 1.2,
            accept: () async {},
          );
          expect(tester.takeException(), isNull);
          final button = find.byKey(const ValueKey('agreement-accept'));
          expect(tester.getRect(button).bottom, lessThanOrEqualTo(size.height));
          expect(tester.widget<FilledButton>(button).onPressed, isNull);
          expect(find.byType(DisclaimerBody), findsOneWidget);
        },
      );
    }
  }

  testWidgets('opening or ticking terms does not save acceptance', (
    tester,
  ) async {
    var calls = 0;
    await panel(
      tester,
      size: const Size(390, 800),
      accept: () async {
        calls++;
      },
    );
    expect(store.state.acceptedVersion, 0);
    await tester.tap(find.byKey(const ValueKey('agreement-consent')));
    await tester.pump();
    expect(store.state.acceptedVersion, 0);
    expect(calls, 0);
    await tester.tap(find.byKey(const ValueKey('agreement-accept')));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('failed acceptance remains visible and can be retried', (
    tester,
  ) async {
    await panel(
      tester,
      size: const Size(390, 800),
      accept: () async => throw const FileSystemException('full'),
    );
    await tester.tap(find.byKey(const ValueKey('agreement-consent')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agreement-accept')));
    await tester.pump();
    expect(
      find.text(
        'Unable to save your acceptance. Please check available storage and try again.',
      ),
      findsOneWidget,
    );
    expect(store.state.acceptedVersion, 0);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('agreement-accept')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'existing locked installation unlocks before showing the update',
    (tester) async {
      await tester.runAsync(() async {
        await File('${temp.path}/appdata.json').writeAsString('{}');
        await File('${temp.path}/onboarding.json').delete();
        await store.load(temp.path);
      });
      appdata.settings['authorizationRequired'] = true;
      appdata.settings['appLockType'] = 'pin';
      await tester.pumpWidget(const MaterialApp(home: StartupPage()));
      await tester.pump();
      expect(find.byType(AuthPage), findsOneWidget);
      expect(find.byType(AgreementPanel), findsNothing);
      expect(AuthPage.isActive, isTrue);
      tester.widget<AuthPage>(find.byType(AuthPage)).onSuccessfulAuth!();
      await tester.pump();
      expect(find.byType(AuthPage), findsNothing);
      expect(find.byType(AgreementPanel), findsOneWidget);
      expect(store.state.needsAgreement(), isTrue);
      expect(AuthPage.isActive, isFalse);
    },
  );

  testWidgets('completed empty installation gets an update notice, not setup', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await File('${temp.path}/appdata.json').writeAsString('{}');
      await File('${temp.path}/onboarding.json').delete();
      await store.load(temp.path);
    });
    await tester.pumpWidget(const MaterialApp(home: StartupPage()));
    await tester.pump();
    expect(find.byType(OnboardingPage), findsNothing);
    expect(
      tester.widget<AgreementPanel>(find.byType(AgreementPanel)).isUpdate,
      isTrue,
    );
  });

  testWidgets('fresh setup can skip optional permissions and restore', (
    tester,
  ) async {
    await tester.runAsync(() => store.accept('en-US'));
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          ensureServices: () async {},
          onFinished: () {},
          onDeclined: () {},
        ),
      ),
    );
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.tap(find.text('Skip for now'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Skip and start reading'),
          )
          .onPressed,
      isNotNull,
    );
    expect(store.state.needsAgreement(), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
      testWidgets('desktop access notes fit $platform in $language', (
        tester,
      ) async {
        appdata.settings['language'] = language;
        await tester.runAsync(() => store.accept(language));
        tester.view.physicalSize = const Size(1100, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          home: OnboardingPage(
            ensureServices: () async {},
            onFinished: () {},
            onDeclined: () {},
          ),
        ));
        await tester.tap(find.text('Continue'.tl));
        await tester.pump();
        expect(find.text('Features and access'.tl), findsOneWidget);
        expect(find.text('Access information'.tl), findsOneWidget);
        expect(find.text('Enable notifications'.tl), findsNothing);
        expect(find.text('Skip for now'.tl), findsNothing);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
