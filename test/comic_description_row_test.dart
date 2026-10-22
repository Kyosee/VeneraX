import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

// The detail page renders the full description below its header, so the
// header's one-line description row would only repeat it there.

Widget _host({required bool showDescription}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ComicDescription(
          title: 'Comic',
          subtitle: 'Artist',
          description: 'A long synopsis',
          enableTranslate: false,
          pagesText: '30',
          showTitle: false,
          showDescription: showDescription,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  testWidgets('a comic tile keeps its description row', (tester) async {
    await tester.pumpWidget(_host(showDescription: true));

    expect(find.text('Description'), findsOneWidget);
    expect(find.text('A long synopsis'), findsOneWidget);
  });

  testWidgets('the detail header drops the description row only', (
    tester,
  ) async {
    await tester.pumpWidget(_host(showDescription: false));

    expect(find.text('Description'), findsNothing);
    expect(find.text('A long synopsis'), findsNothing);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
  });
}
