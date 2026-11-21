import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  const tabs = ['Home', 'Favorites', 'Explore', 'Categories'];
  late GlobalKey<NavigatorState> navigatorKey;
  late int exitRequests;
  bool? frameworkHandlesBack;

  Future<void> pumpTabs(
    WidgetTester tester, {
    required int initialPage,
    Size size = const Size(400, 800),
    Widget Function(int)? pageBuilder,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    exitRequests = 0;
    frameworkHandlesBack = null;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exitRequests++;
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        frameworkHandlesBack = call.arguments as bool;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final previousKey = App.mainNavigatorKey;
    navigatorKey = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = navigatorKey;
    addTearDown(() => App.mainNavigatorKey = previousKey);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NaviPane(
          initialPage: initialPage,
          navigatorKey: navigatorKey,
          observer: NaviObserver(),
          paneItems: [
            for (final tab in tabs)
              PaneItemEntry(
                label: tab,
                icon: Icons.circle_outlined,
                activeIcon: Icons.circle,
              ),
          ],
          paneActions: const [],
          pageBuilder: pageBuilder ?? (index) => Text('Page $index'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('each main tab returns to Home before exiting by default', (
    tester,
  ) async {
    await pumpTabs(tester, initialPage: 1);
    for (var index = 1; index < tabs.length; index++) {
      if (index > 1) {
        await tester.tap(find.byTooltip(tabs[index]).hitTestable());
        await tester.pumpAndSettle();
      }
      expect(find.text('Page $index'), findsOneWidget);
      expect(frameworkHandlesBack, isTrue);
      await back(tester);
      expect(find.text('Page 0'), findsOneWidget);
      expect(exitRequests, 0);
      expect(frameworkHandlesBack, isFalse);
    }

    await back(tester);
    expect(exitRequests, 1);
  });

  testWidgets(
    'desktop back leaves a narrow non-home tab without switching to Home',
    (tester) async {
      final original = appdata.settings['returnToHomeOnBack'];
      addTearDown(() => appdata.settings['returnToHomeOnBack'] = original);
      appdata.settings['returnToHomeOnBack'] = true;
      await pumpTabs(tester, initialPage: 1);

      await back(tester);
      expect(find.text('Page 1'), findsOneWidget);
      expect(exitRequests, 1);
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('system back exits a non-home tab when the setting is off', (
    tester,
  ) async {
    final original = appdata.settings['returnToHomeOnBack'];
    addTearDown(() => appdata.settings['returnToHomeOnBack'] = original);
    await pumpTabs(tester, initialPage: 3);

    appdata.settings['returnToHomeOnBack'] = false;
    await tester.pumpAndSettle();
    expect(frameworkHandlesBack, isFalse);
    await back(tester);
    expect(exitRequests, 1);
    expect(find.text('Page 3'), findsOneWidget);
  });

  testWidgets('dialog, details and tab selection handle back before Home', (
    tester,
  ) async {
    var selecting = true;
    await pumpTabs(
      tester,
      initialPage: 2,
      pageBuilder: (index) {
        if (index != 2) return Text('Page $index');
        return StatefulBuilder(
          builder: (context, setState) => PopScope<void>(
            canPop: !selecting,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && selecting) setState(() => selecting = false);
            },
            child: Text(selecting ? 'Selecting' : 'Page 2'),
          ),
        );
      },
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('Details')),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: tester.element(find.text('Details')),
      builder: (_) => const AlertDialog(title: Text('Actions')),
    );
    await tester.pumpAndSettle();

    await back(tester);
    expect(find.text('Actions'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    expect(frameworkHandlesBack, isTrue);
    await back(tester);
    expect(find.text('Selecting'), findsOneWidget);
    expect(frameworkHandlesBack, isTrue);
    await back(tester);
    expect(find.text('Page 2'), findsOneWidget);
    expect(frameworkHandlesBack, isTrue);
    await back(tester);
    expect(find.text('Page 0'), findsOneWidget);
    expect(exitRequests, 0);
  });

  testWidgets(
    'the wide iOS edge gesture returns to Home before exiting',
    (tester) async {
      await pumpTabs(tester, initialPage: 1, size: const Size(1024, 768));
      Future<void> swipeBack() async {
        await tester.flingFrom(const Offset(4, 400), const Offset(220, 0), 900);
        await tester.pumpAndSettle();
      }

      await swipeBack();
      expect(find.text('Page 0'), findsOneWidget);
      expect(exitRequests, 0);
      await swipeBack();
      expect(exitRequests, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
