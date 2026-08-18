import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('menu button keeps a 48px click target and opens its menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MenuButton(
              entries: [
                MenuEntry(
                  text: 'Action',
                  icon: Icons.edit_outlined,
                  onClick: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final button = find.byType(IconButton);
    expect(button, findsOneWidget);
    expect(tester.getSize(button), const Size.square(48));

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Action'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
