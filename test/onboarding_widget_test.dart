import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/app_update_dialog.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/onboarding_page.dart';
import 'package:venera/pages/onboarding_restore.dart';
import 'package:venera/pages/onboarding_style.dart';
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

  void expectVisibleButton(WidgetTester tester, Finder button, Size size) {
    expect(button, findsOneWidget);
    final bounds = tester.getRect(button);
    expect(bounds.width, greaterThan(0));
    expect(bounds.height, greaterThan(0));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(size.width));
    expect(bounds.bottom, lessThanOrEqualTo(size.height));
    expect(button.hitTestable(), findsOneWidget);
  }

  void expectTitleLeading(WidgetTester tester, Type artType, String title) {
    final art = find.byType(artType);
    final heading = find.text(title.tl);
    expect(art, findsOneWidget);
    expect(heading, findsOneWidget);
    final box = tester.renderObject<RenderBox>(art);
    // Include the leading artwork's FittedBox scale in its screen bounds.
    final artBounds = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
    final headingBounds = tester.getRect(heading);
    expect(artBounds.width, greaterThan(0));
    expect(artBounds.height, greaterThan(0));
    expect(artBounds.right, lessThanOrEqualTo(headingBounds.left));
    expect(artBounds.top, lessThan(headingBounds.bottom));
    expect(artBounds.bottom, greaterThan(headingBounds.top));
  }

  Widget setupPage() => OnboardingPage(
    ensureServices: () async {},
    onFinished: () {},
    onDeclined: () {},
  );

  Future<void> acceptAgreement(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('agreement-consent')));
    await tester.pump();
    final dynamic accept = tester
        .widget<FilledButton>(find.byKey(const ValueKey('agreement-accept')))
        .onPressed!;
    // Await the actual button callback, including its atomic disk write.
    await tester.runAsync(() async => await accept());
    await tester.pumpAndSettle();
  }

  for (final interruptedStep in [1, 2, 3]) {
    testWidgets('restart at setup step $interruptedStep requires agreement', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(home: setupPage()));
      await acceptAgreement(tester);
      for (var step = 1; step < interruptedStep; step++) {
        await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(AgreementPanel), findsNothing);
      expect(store.state.setupCompleted, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => store.load(temp.path));
      await tester.pumpWidget(MaterialApp(home: setupPage()));
      await tester.pumpAndSettle();

      expect(find.byType(AgreementPanel), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('agreement-accept')),
            )
            .onPressed,
        isNull,
      );
      expect(store.state.setupCompleted, isFalse);
      expect(store.blocksAutomaticTasks, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final existingUser in [false, true]) {
    testWidgets(
      'update dialog cannot bypass agreement: existing=$existingUser',
      (tester) async {
        store.state = OnboardingState(setupCompleted: existingUser);
        await tester.pumpWidget(const MaterialApp(home: StartupPage()));
        await tester.pumpAndSettle();
        expect(find.byType(AgreementPanel), findsOneWidget);
        expect(find.byType(MainPage), findsNothing);

        final notice = showDialog<void>(
          context: tester.element(find.byType(AgreementPanel)),
          builder: (_) => AppUpdateDialog(
            currentVersion: '1.0.0',
            latestVersion: '1.0.1',
            changelog: const [],
            onReleasePage: () async {},
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('update-secondary')));
        await tester.pumpAndSettle();
        await notice;

        expect(find.byType(AppUpdateDialog), findsNothing);
        expect(find.byType(AgreementPanel), findsOneWidget);
        expect(find.byType(MainPage), findsNothing);
        expect(store.state.acceptedVersion, 0);
        expect(store.blocksAutomaticTasks, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entry in ['launch', 'unlock', 'retry']) {
    testWidgets('reopening setup via $entry waits for renewed consent', (
      tester,
    ) async {
      final savedWebdav = appdata.settings['webdav'];
      final savedAutoSync = appdata.implicitData['webdavAutoSync'];
      final savedSyncMode = appdata.implicitData['webdavSyncMode'];
      addTearDown(() {
        appdata.settings['webdav'] = savedWebdav;
        appdata.implicitData['webdavAutoSync'] = savedAutoSync;
        appdata.implicitData['webdavSyncMode'] = savedSyncMode;
      });
      await tester.runAsync(() async {
        await store.accept('en-US');
        await store.load(temp.path);
      });
      appdata.settings['webdav'] = <String>[];
      appdata.implicitData['webdavAutoSync'] = true;
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      if (entry == 'unlock') {
        appdata.settings['authorizationRequired'] = true;
        appdata.settings['appLockType'] = 'pin';
      } else if (entry == 'retry') {
        store.loadError = const FileSystemException('Fixture read failure');
      }

      await tester.pumpWidget(const MaterialApp(home: StartupPage()));
      await tester.pump();
      if (entry == 'unlock') {
        expect(find.byType(AuthPage), findsOneWidget);
        tester.widget<AuthPage>(find.byType(AuthPage)).onSuccessfulAuth!();
      } else if (entry == 'retry') {
        final dynamic retry = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Retry'))
            .onPressed!;
        await tester.runAsync(() async => await retry());
      }
      await tester.pumpAndSettle();

      // Service initialization must not apply setup defaults before consent.
      expect(appdata.implicitData['webdavAutoSync'], isTrue);
      expect(appdata.implicitData['webdavSyncMode'], 'realtime');
      expect(find.byType(AgreementPanel), findsOneWidget);
      expect(find.byType(MainPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    testWidgets('agreement shortcuts scroll to their sections in $language', (
      tester,
    ) async {
      appdata.settings['language'] = language;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: setupPage()));
      await tester.pumpAndSettle();
      final scroll = find.ancestor(
        of: find.byType(DisclaimerBody),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.vertical,
        ),
      );
      final controller = tester
          .widget<SingleChildScrollView>(scroll)
          .controller!;
      final accept = find.byKey(const ValueKey('agreement-accept'));
      final footer = tester.getRect(accept);
      final offsets = <int, double>{};
      for (final target in [
        (6, 'Risks & liability'),
        (4, 'Privacy & data'),
        (8, 'Acceptance & changes'),
      ]) {
        // Reveal the horizontal shortcut, never its target section.
        final shortcut = find.widgetWithText(TextButton, target.$2.tl);
        await tester.ensureVisible(shortcut);
        await tester.pumpAndSettle();
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        final heading = find.descendant(
          of: find.byType(DisclaimerBody),
          matching: find.text(kDisclaimerSections[target.$1].$1.tl),
        );
        final viewport = tester.getRect(scroll);
        final headingBounds = tester.getRect(heading);
        expect(controller.offset, greaterThan(0));
        expect(headingBounds.top, greaterThanOrEqualTo(viewport.top - 1));
        expect(
          headingBounds.bottom,
          lessThanOrEqualTo(viewport.bottom + 1),
          reason: '${target.$2}: heading=$headingBounds, viewport=$viewport',
        );
        expect(tester.getRect(accept), footer);
        offsets[target.$1] = controller.offset;
      }
      expect(offsets[6], greaterThan(offsets[4]!));
      expect(offsets[8], greaterThan(offsets[6]!));
      final backToTop = find.widgetWithText(TextButton, 'Back to top'.tl);
      await tester.ensureVisible(backToTop);
      await tester.pumpAndSettle();
      await tester.tap(backToTop);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(0, 1));
      expect(tester.getRect(accept), footer);
      expect(store.state.acceptedVersion, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('changing language resets consent on the first setup screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: setupPage()));
    await tester.tap(find.byKey(const ValueKey('agreement-consent')));
    await tester.pump();
    final accept = find.byKey(const ValueKey('agreement-accept'));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(tester.widget<FilledButton>(accept).onPressed, isNotNull);

    final dynamic changeLanguage = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .onChanged!;
    await tester.runAsync(() async {
      // Await the real callback's disk write before checking the rebuilt panel.
      await changeLanguage('zh-CN');
    });
    await tester.pumpAndSettle();
    expect(appdata.settings['language'], 'zh-CN');
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(tester.widget<FilledButton>(accept).onPressed, isNull);
    expect(store.state.acceptedVersion, 0);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    for (final device in [
      (TargetPlatform.android, const Size(320, 700)),
      (TargetPlatform.windows, const Size(1100, 760)),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'setup and existing-user notice fit $language ${device.$2} $brightness',
          (tester) async {
            appdata.settings['language'] = language;
            tester.view.physicalSize = device.$2;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            Widget themed(Widget home) => MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.2)),
                child: child!,
              ),
              home: home,
            );
            final accept = find.byKey(const ValueKey('agreement-accept'));
            await tester.pumpWidget(themed(setupPage()));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expectVisibleButton(tester, accept, device.$2);
            expect(tester.widget<FilledButton>(accept).onPressed, isNull);
            expect(
              Theme.of(tester.element(find.byType(AgreementPanel))).brightness,
              brightness,
            );

            await acceptAgreement(tester);
            expectTitleLeading(
              tester,
              OnboardingLanguageArt,
              'Choose your app language',
            );
            for (var step = 1; step <= 3; step++) {
              final next = find.widgetWithText(
                FilledButton,
                (step == 3 ? 'Skip and start reading' : 'Continue').tl,
              );
              expectVisibleButton(tester, next, device.$2);
              expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
              expect(tester.takeException(), isNull);
              if (step == 2) {
                expect(
                  find.text(
                    (device.$1 == TargetPlatform.android
                            ? 'Permission settings'
                            : 'Features and access')
                        .tl,
                  ),
                  findsOneWidget,
                );
              } else if (step == 3) {
                expectTitleLeading(
                  tester,
                  OnboardingRestoreArt,
                  'Import or restore data',
                );
              }
              if (step < 3) {
                await tester.tap(next);
                await tester.pumpAndSettle();
              }
            }

            await tester.pumpWidget(const SizedBox.shrink());
            store.state = const OnboardingState(setupCompleted: true);
            await tester.pumpWidget(themed(const StartupPage()));
            await tester.pumpAndSettle();
            expect(find.byType(OnboardingPage), findsNothing);
            expect(
              tester
                  .widget<AgreementPanel>(find.byType(AgreementPanel))
                  .isUpdate,
              isTrue,
            );
            expectVisibleButton(tester, accept, device.$2);
            expect(tester.widget<FilledButton>(accept).onPressed, isNull);
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant({device.$1}),
        );
      }
    }
  }

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    testWidgets(
      'WebDAV form remains reachable above a small-screen keyboard in $language',
      (tester) async {
        appdata.settings['language'] = language;
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.2)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => OnboardingTheme(
                      builder: (_) => const OnboardingWebdavDialog(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNWidgets(3));
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        for (var index = 0; index < 3; index++) {
          final field = find.byType(TextField).at(index);
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(
            field,
            ['https://example.invalid/backups/', 'fixture', 'fixture'][index],
          );
          await tester.pumpAndSettle();
          expectVisibleButton(tester, field, const Size(320, 400));
          expect(tester.takeException(), isNull);
        }
        final connect = find.widgetWithText(
          FilledButton,
          'Connect and check backups'.tl,
        );
        await tester.ensureVisible(connect);
        await tester.pumpAndSettle();
        expectVisibleButton(tester, connect, const Size(320, 400));
        expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
        expect(tester.takeException(), isNull);

        final close = find.byTooltip('Close'.tl);
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        expectVisibleButton(tester, close, const Size(320, 400));
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(OnboardingWebdavDialog), findsNothing);
        expect(store.state.acceptedVersion, 0);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
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
    await acceptAgreement(tester);
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
      testWidgets(
        'desktop access notes fit $platform in $language',
        (tester) async {
          appdata.settings['language'] = language;
          tester.view.physicalSize = const Size(1100, 760);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              home: OnboardingPage(
                ensureServices: () async {},
                onFinished: () {},
                onDeclined: () {},
              ),
            ),
          );
          await acceptAgreement(tester);
          await tester.tap(find.text('Continue'.tl));
          await tester.pump();
          expect(find.text('Features and access'.tl), findsOneWidget);
          expect(find.text('Access information'.tl), findsOneWidget);
          expect(find.text('Enable notifications'.tl), findsNothing);
          expect(find.text('Skip for now'.tl), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
