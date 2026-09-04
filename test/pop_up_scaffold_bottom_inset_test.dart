import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// Regression guard for #161: the pop up scaffold reserved room for the
/// keyboard but never for the system navigation bar, so the last row of a
/// page (e.g. the Save button of the WebDAV form) sat flush against the
/// bottom edge on phones.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  const marker = ValueKey('last-row');

  Widget wrap({required Size size, required double bottomInset}) {
    return MediaQuery(
      data: MediaQueryData(
        size: size,
        padding: EdgeInsets.only(bottom: bottomInset),
      ),
      child: const MaterialApp(
        home: PopUpWidgetScaffold(
          title: 'Webdav',
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(key: marker, height: 40, width: 120),
          ),
        ),
      ),
    );
  }

  testWidgets('full width pop up clears the system bottom inset', (
    tester,
  ) async {
    const size = Size(400, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(size: size, bottomInset: 48));
    await tester.pumpAndSettle();

    var rect = tester.getRect(find.byKey(marker));
    expect(size.height - rect.bottom, greaterThanOrEqualTo(48));
  });

  testWidgets('centered card pop up keeps only a small gap', (tester) async {
    const size = Size(900, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(size: size, bottomInset: 48));
    await tester.pumpAndSettle();

    var rect = tester.getRect(find.byKey(marker));
    var gap = size.height - rect.bottom;
    // The card is laid out by the route, not the scaffold, so the system
    // inset must not be added a second time here.
    expect(gap, greaterThan(0));
    expect(gap, lessThan(48));
  });

  testWidgets('top bar remains opaque after body scrolls', (tester) async {
    const size = Size(400, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: PopUpWidgetScaffold(
          title: 'Selector',
          body: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) =>
                ListTile(title: Text('Source $index')),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    final titleContainers = tester.widgetList<Container>(
      find.ancestor(
        of: find.text('Selector'),
        matching: find.byType(Container),
      ),
    );
    final titleContainer = titleContainers.firstWhere(
      (container) => container.decoration is BoxDecoration,
    );
    final decoration = titleContainer.decoration! as BoxDecoration;
    expect(decoration.color, isNotNull);
    expect(decoration.color!.a, 1);
  });
}
