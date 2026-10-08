import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  setUp(() {
    appdata.settings['language'] = 'en-US';
  });

  testWidgets('settings categories follow the requested order', (tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    const labels = [
      'App',
      'Reading settings',
      'AI Translation',
      'Local Favorites',
      'Data & Sync',
      'Explore',
      'Network',
      'Debug',
      'About',
    ];
    final positions = labels
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList();

    expect(positions, orderedEquals([...positions]..sort()));
    expect(find.text('Appearance'), findsNothing);
  });

  testWidgets('app category contains appearance settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: SettingsPage(initialPage: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme Mode'), findsOneWidget);
    expect(find.text('Theme Color'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
  });

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('custom translation scripts are searchable in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      await tester.binding.setSurfaceSize(const Size(500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'Custom translation script'.tl,
      );
      await tester.pumpAndSettle();

      final result = find.widgetWithText(
        ListTile,
        'Custom translation script'.tl,
      );
      expect(result, findsOneWidget);
      expect(
        find.descendant(
          of: result,
          matching: find.text('${'AI Translation'.tl} / ${'LLM providers'.tl}'),
        ),
        findsOneWidget,
      );
    });
  }
}
