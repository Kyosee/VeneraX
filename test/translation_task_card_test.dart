import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/translation_progress_surface.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/translations.dart';

PreTranslationTask _task({
  PreTranslationTaskStatus status = PreTranslationTaskStatus.running,
  int total = 20,
  int done = 4,
  int failed = 1,
}) => PreTranslationTask(
  id: 'translation-card',
  cid: 'comic',
  sourceKey: 'test',
  comicType: ComicType(0),
  title: 'Tide Post Office',
  chapters: [
    PreTranslationChapter(
      eid: '35',
      title: 'Chapter 35: The unsent postcard',
      total: total,
      done: done,
      failed: failed,
    ),
  ],
  createdAt: DateTime(2026),
  status: status,
);

Widget _host(
  Widget child, {
  double width = 800,
  double textScale = 1,
  bool disableAnimations = false,
  ColorScheme? colors,
  TargetPlatform? platform,
}) => MaterialApp(
  theme: ThemeData(colorScheme: colors, platform: platform),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  ),
);

Future<List<Color>> _pixels(
  WidgetTester tester,
  GlobalKey key,
  List<Offset> points,
) async => (await tester.runAsync(() async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return points.map((point) {
      final offset = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    }).toList();
  } finally {
    image.dispose();
  }
}))!;

void _expectColor(Color actual, Color expected) {
  expect(actual.r, closeTo(expected.r, 1 / 255));
  expect(actual.g, closeTo(expected.g, 1 / 255));
  expect(actual.b, closeTo(expected.b, 1 / 255));
  expect(actual.a, closeTo(expected.a, 1 / 255));
}

void main() {
  late Directory temporary;
  setUpAll(() async {
    await AppTranslation.init();
    temporary = Directory.systemTemp.createTempSync('translation-card-test-');
    App.dataPath = temporary.path;
  });
  tearDownAll(() => temporary.deleteSync(recursive: true));
  setUp(() {
    appdata.settings['language'] = 'en-US';
    PreTranslationTaskManager.instance.currentTasks.clear();
    PreTranslationTaskManager.instance.historyTasks.clear();
  });

  for (final brightness in Brightness.values) {
    testWidgets('whole-height fill follows $brightness theme and pause', (
      tester,
    ) async {
      final dark = brightness == Brightness.dark;
      final colors =
          ColorScheme.fromSeed(
            seedColor: const Color(0xff285c92),
            brightness: brightness,
          ).copyWith(
            primary: Color(dark ? 0xffaacbff : 0xff285c92),
            surface: Color(dark ? 0xff1c2833 : 0xffffffff),
          );
      final key = GlobalKey();
      Widget surface(bool paused) => _host(
        RepaintBoundary(
          key: key,
          child: TranslationProgressSurface(
            progress: .4,
            paused: paused,
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
        width: 200,
        colors: colors,
      );
      for (final paused in [false, true]) {
        await tester.pumpWidget(surface(paused));
        await tester.pumpAndSettle();
        final pixels = await _pixels(tester, key, const [
          Offset(40, 5),
          Offset(40, 90),
          Offset(120, 50),
        ]);
        final expected = Color.alphaBlend(
          colors.primary.withValues(
            alpha: paused ? (dark ? .11 : .10) : (dark ? .23 : .17),
          ),
          colors.surface,
        );
        _expectColor(pixels[0], expected);
        _expectColor(pixels[1], expected);
        _expectColor(pixels[2], colors.surface);
      }
    });

    testWidgets('expanded task details retain progress in $brightness', (
      tester,
    ) async {
      final wasBackgroundTask = App.isBackgroundTask;
      App.isBackgroundTask = true;
      addTearDown(() => App.isBackgroundTask = wasBackgroundTask);
      final colors = ColorScheme.fromSeed(
        seedColor: const Color(0xff285c92),
        brightness: brightness,
      );
      final key = GlobalKey();
      PreTranslationTaskManager.instance.currentTasks.add(_task());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: colors),
          home: RepaintBoundary(key: key, child: const TasksPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Pre-translate: Tide Post Office'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      for (final paused in [false, true]) {
        if (paused) {
          await tester.tap(find.byTooltip('Pause'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Resume'), findsOneWidget);
        }
        expect(find.text('Pages: 5/20'), findsOneWidget);
        final details = tester.getRect(
          find
              .ancestor(
                of: find.text('Pages: 5/20'),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(
          details.bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byType(TranslationProgressSurface)).bottom,
          ),
        );
        final origin = tester.getTopLeft(find.byKey(key));
        // Sample the detail box's padding on both sides of the progress edge.
        final pixels = await _pixels(tester, key, [
          Offset(details.left + 20, details.top + 6) - origin,
          Offset(details.left + 20, details.bottom - 6) - origin,
          Offset(details.right - 20, details.top + 6) - origin,
          Offset(details.right - 20, details.bottom - 6) - origin,
        ]);
        final dark = brightness == Brightness.dark;
        final expected = Color.alphaBlend(
          colors.primary.withValues(
            alpha: paused ? (dark ? .11 : .10) : (dark ? .23 : .17),
          ),
          colors.surface,
        );
        _expectColor(pixels[0], expected);
        _expectColor(pixels[1], expected);
        _expectColor(pixels[2], colors.surface);
        _expectColor(pixels[3], colors.surface);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'progress transitions for 280ms and reduced motion is immediate',
    (tester) async {
      final key = GlobalKey();
      final colors = ColorScheme.fromSeed(seedColor: Colors.blue);
      Widget surface(double progress, {bool disableAnimations = false}) =>
          _host(
            RepaintBoundary(
              key: key,
              child: TranslationProgressSurface(
                progress: progress,
                child: const SizedBox(width: 200, height: 100),
              ),
            ),
            width: 200,
            colors: colors,
            disableAnimations: disableAnimations,
          );
      await tester.pumpWidget(surface(.25));
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(.75));
      _expectColor(
        (await _pixels(tester, key, const [Offset(80, 50)])).single,
        colors.surface,
      );
      await tester.pump(const Duration(milliseconds: 140));
      final middle = await _pixels(tester, key, const [
        Offset(80, 50),
        Offset(145, 50),
      ]);
      expect(middle[0], isNot(colors.surface));
      _expectColor(middle[1], colors.surface);
      await tester.pump(const Duration(milliseconds: 140));
      expect(
        (await _pixels(tester, key, const [Offset(145, 50)])).single,
        isNot(colors.surface),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(surface(.1, disableAnimations: true));
      _expectColor(
        (await _pixels(tester, key, const [Offset(40, 50)])).single,
        colors.surface,
      );
      await tester.pumpWidget(surface(.9, disableAnimations: true));
      expect(
        (await _pixels(tester, key, const [Offset(160, 50)])).single,
        isNot(colors.surface),
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('unknown progress leaves the task surface unpainted', (
    tester,
  ) async {
    final colors = ColorScheme.fromSeed(seedColor: Colors.blue);
    final key = GlobalKey();
    await tester.pumpWidget(
      _host(
        RepaintBoundary(
          key: key,
          child: const TranslationProgressSurface(
            child: SizedBox(width: 200, height: 100),
          ),
        ),
        width: 200,
        colors: colors,
      ),
    );
    final points = [for (var x = 0; x < 180; x += 3) Offset(x.toDouble(), 50)];
    for (final pixel in await _pixels(tester, key, points)) {
      _expectColor(pixel, colors.surface);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'task centre uses standard cards and retains details and task controls',
    (tester) async {
      final wasBackgroundTask = App.isBackgroundTask;
      App.isBackgroundTask = true;
      addTearDown(() => App.isBackgroundTask = wasBackgroundTask);
      final manager = PreTranslationTaskManager.instance;
      final task = _task();
      manager.currentTasks.add(task);
      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await tester.pump(const Duration(milliseconds: 400));
      final title = find.text('Pre-translate: Tide Post Office');
      expect(title, findsOneWidget);
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      final card = find.byType(Card);
      expect(tester.getTopLeft(card).dx, 16);
      expect(
        tester.getSize(card).width,
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 32,
      );
      final surface = find.byType(TranslationProgressSurface);
      expect(tester.widget<TranslationProgressSurface>(surface).progress, .25);
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Pages: 5/20'), findsOneWidget);
      expect(find.text('Failed: 1'), findsOneWidget);
      expect(find.text('View Detail'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      expect(task.status, PreTranslationTaskStatus.paused);
      expect(find.byTooltip('Resume'), findsOneWidget);
      expect(find.text('Pages: 5/20'), findsOneWidget);
      expect(find.byType(Dismissible), findsNothing);
      expect(tester.widget<TranslationProgressSurface>(surface).progress, .25);
      expect(tester.widget<TranslationProgressSurface>(surface).paused, isTrue);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(task.status, PreTranslationTaskStatus.canceled);
      await tester.tap(find.text('History (1)'));
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      expect(tester.widget<TranslationProgressSurface>(surface).progress, 0);
      expect(find.byType(Dismissible), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('task centre keeps unknown totals and large text usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final manager = PreTranslationTaskManager.instance;
    final task = _task(
      status: PreTranslationTaskStatus.paused,
      total: 0,
      done: 0,
      failed: 0,
    );
    manager.currentTasks.add(task);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const TasksPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pre-translate: Tide Post Office'));
    await tester.pumpAndSettle();
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Pages: 0/?'), findsOneWidget);
    final surface = tester.widget<TranslationProgressSurface>(
      find.byType(TranslationProgressSurface),
    );
    expect(surface.progress, isNull);
    final resume = find.byTooltip('Resume');
    await tester.ensureVisible(resume);
    expect(tester.getRect(resume).right, lessThanOrEqualTo(304));
    expect(tester.getSize(resume).height, greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
