import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/app_update_dialog.dart';
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  final releaseNotes = File(
    'release-notes/v2.3.12.zh-CN.md',
  ).readAsStringSync();

  Future<void> open(
    WidgetTester tester, {
    String language = 'zh-CN',
    Size size = const Size(390, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    String? notes,
    PrepareAppUpdate? prepare,
    Future<void> Function()? onRelease,
  }) async {
    appdata.settings['language'] = language;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AppUpdateDialog(
                  currentVersion: '2.3.11',
                  latestVersion: '2.3.12',
                  changelog: parseAppChangelog(notes ?? releaseNotes),
                  onReleasePage: onRelease ?? () async {},
                  prepareUpdate: prepare,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final primary = find.byKey(const ValueKey('update-primary'));
  final secondary = find.byKey(const ValueKey('update-secondary'));

  for (final language in ['zh-CN', 'zh-TW', 'en-US']) {
    for (final size in [const Size(320, 640), const Size(1100, 760)]) {
      testWidgets('approved layout fits $language at $size', (tester) async {
        await open(tester, language: language, size: size, textScale: 1.3);
        expect(tester.takeException(), isNull);
        final title = tester.getRect(
          find.byKey(const ValueKey('update-title')),
        );
        final icon = tester.getRect(
          find.byKey(const ValueKey('update-app-icon')),
        );
        expect(title.left, greaterThan(icon.right));
        expect(title.center.dy, closeTo(icon.center.dy, 1));
        expect(tester.getRect(primary).bottom, lessThan(size.height));
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.text('新增'), findsOneWidget);
        expect(find.text('变更'), findsOneWidget);
        expect(find.text('修复'), findsOneWidget);
        expect(find.text('移除'), findsOneWidget);
        final before = tester.getRect(primary);
        await tester.drag(
          find.byKey(const ValueKey('update-notes-scroll')),
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(primary), before);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('matches light/dark preview surfaces and has no summary', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await open(tester, brightness: brightness);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(
        dialog.backgroundColor,
        brightness == Brightness.dark ? const Color(0xff202530) : Colors.white,
      );
      expect(find.text('整理收藏，更快一步'), findsNothing);
      expect(find.text('收起更新日志'), findsNothing);
      expect(find.text('按你的节奏更新，稍后也可以。'), findsNothing);
      await tester.tap(secondary);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('missing notes keeps the release action usable', (tester) async {
    var opened = false;
    await open(tester, notes: '', onRelease: () async => opened = true);
    expect(find.text('暂时无法获取更新日志。'), findsOneWidget);
    expect(find.text('前往发布页'), findsOneWidget);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(find.byType(AppUpdateDialog), findsNothing);
  });

  testWidgets('downloads in place and requires explicit install confirmation', (
    tester,
  ) async {
    final completion = Completer<PreparedAppUpdate>();
    late ValueChanged<double?> progress;
    var installed = false;
    await open(
      tester,
      prepare: (token, onProgress) {
        progress = onProgress;
        return completion.future;
      },
    );
    await tester.tap(primary);
    await tester.pump();
    progress(.42);
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
    expect(find.text('修复'), findsOneWidget);
    completion.complete(
      PreparedAppUpdate(
        install: () async => installed = true,
        discard: () async => fail('An installing package must not be deleted'),
      ),
    );
    await tester.pump();
    expect(find.text('更新包已准备好'), findsOneWidget);
    expect(installed, isFalse);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(installed, isTrue);
  });

  testWidgets('cancelled attempt cannot overwrite a later download', (
    tester,
  ) async {
    final attempts = <Completer<PreparedAppUpdate>>[];
    final tokens = <CancelToken>[];
    final progresses = <ValueChanged<double?>>[];
    await open(
      tester,
      prepare: (token, progress) {
        tokens.add(token);
        progresses.add(progress);
        final attempt = Completer<PreparedAppUpdate>();
        attempts.add(attempt);
        return attempt.future;
      },
    );
    await tester.tap(primary);
    await tester.pump();
    await tester.tap(secondary);
    await tester.pump();
    expect(tokens.first.isCancelled, isTrue);
    await tester.tap(primary);
    await tester.pump();
    progresses.first(1);
    var discarded = 0;
    attempts.first.complete(
      PreparedAppUpdate(
        install: () async => fail('Cancelled update must not install'),
        discard: () async => discarded++,
      ),
    );
    progresses.last(.25);
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('更新包已准备好'), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tokens.last.isCancelled, isTrue);
    attempts.last.complete(
      PreparedAppUpdate(
        install: () async => fail('Closed update must not install'),
        discard: () async => discarded++,
      ),
    );
    await tester.pump();
    expect(discarded, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a ready update discards its unused package', (
    tester,
  ) async {
    var discarded = false;
    await open(
      tester,
      prepare: (token, progress) async => PreparedAppUpdate(
        install: () async => fail('Dismissed update must not install'),
        discard: () async => discarded = true,
      ),
    );
    await tester.tap(primary);
    await tester.pump();
    expect(find.text('更新包已准备好'), findsOneWidget);
    await tester.tap(secondary);
    await tester.pumpAndSettle();
    expect(discarded, isTrue);
  });

  testWidgets('verification failure stays retryable and cannot offer install', (
    tester,
  ) async {
    var attempts = 0;
    await open(
      tester,
      prepare: (token, progress) async {
        attempts++;
        throw StateError('更新包校验失败');
      },
    );
    await tester.tap(primary);
    await tester.pump();
    expect(find.text('更新包校验失败'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);
    expect(find.text('安装更新'), findsNothing);
    await tester.tap(primary);
    await tester.pump();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
