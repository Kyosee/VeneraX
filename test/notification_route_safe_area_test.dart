import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/handle_notification_route.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  testWidgets(
    'notification routes stay inside the safe-area navigator (#168)',
    (tester) async {
      final mainNavigatorKey = GlobalKey<NavigatorState>();
      App.mainNavigatorKey = mainNavigatorKey;
      addTearDown(() => App.mainNavigatorKey = null);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Navigator(
            key: mainNavigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('main-home')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await openNotificationRoute('tasks');
      await tester.pumpAndSettle();

      expect(find.byType(TasksPage), findsOneWidget);
      expect(mainNavigatorKey.currentState!.canPop(), isTrue);
      expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    },
  );
}
