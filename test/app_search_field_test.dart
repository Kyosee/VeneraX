import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// Guards the shared search input introduced for issue #196: every search box
/// in the app now renders through [AppSearchField], so its clear affordance and
/// its ability to sit inside a 52px app bar are load-bearing.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('clear button shows only with text and reports the empty value', (
    tester,
  ) async {
    var controller = TextEditingController();
    addTearDown(controller.dispose);
    var changes = <String>[];

    await tester.pumpWidget(
      wrap(
        AppSearchField(controller: controller, onChanged: changes.add),
      ),
    );

    expect(find.byIcon(Icons.clear), findsNothing);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);
    expect(changes, ['abc']);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changes, ['abc', '']);
    expect(find.byIcon(Icons.clear), findsNothing);
  });

  testWidgets('onTap renders a button instead of a text input', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(AppSearchField(onTap: () => taps++)));

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byIcon(Icons.search));
    expect(taps, 1);
  });

  testWidgets('toolbar height fits inside an app bar row', (tester) async {
    var controller = TextEditingController(text: 'x');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      wrap(
        SizedBox(
          height: 52,
          width: 320,
          child: Row(
            children: [
              Expanded(
                child: AppSearchField(
                  controller: controller,
                  height: AppSearchField.toolbarHeight,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(AppSearchField)).height,
      AppSearchField.toolbarHeight,
    );
  });

  testWidgets('fits as a SliverAppbar title without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var controller = TextEditingController(text: 'x');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothCustomScrollView(
            slivers: [
              SliverAppbar(
                title: AppSearchField(
                  controller: controller,
                  height: AppSearchField.toolbarHeight,
                ),
              ),
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (context, index) => SizedBox(height: 60),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(AppSearchField)).height,
      AppSearchField.toolbarHeight,
    );
  });

  testWidgets('SmoothCustomScrollView carries the shared thumb by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmoothCustomScrollView(
            slivers: [
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (context, index) => SizedBox(height: 60),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppScrollBar), findsOneWidget);
  });
}
