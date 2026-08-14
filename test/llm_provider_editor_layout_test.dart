import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

/// The provider editor is a ContentDialog, whose content sits inside an
/// IntrinsicWidth. Anything in there that refuses intrinsic measurement throws
/// during layout (see the QR-dialog regression), so pumping the add-provider
/// dialog and switching service type exercises that path headlessly.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  testWidgets('add-provider dialog lays out and switches service type', (
    tester,
  ) async {
    // The page opens its dialog on App.rootContext, so the root navigator key
    // has to be the one driving this tree.
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const LlmProvidersPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Default kind shows the endpoint fields.
    expect(find.text("LLM API URL".tl), findsOneWidget);

    await tester.tap(find.text("Google Translate (no key)".tl).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Keyless kind hides them — nothing left to configure.
    expect(find.text("LLM API URL".tl), findsNothing);
    expect(find.text("LLM API Key".tl), findsNothing);

    await tester.tap(find.text("AI model".tl).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("LLM API URL".tl), findsOneWidget);
  });
}
