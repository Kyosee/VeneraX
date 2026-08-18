import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('restores an index safely before the first tab layout', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    const tabBarKey = PageStorageKey<String>('restored-tab-bar');

    Widget buildApp({required bool showTabBar}) {
      return MaterialApp(
        home: PageStorage(
          bucket: bucket,
          child: showTabBar
              ? DefaultTabController(
                  length: 2,
                  child: const Scaffold(
                    body: AppTabBar(
                      key: tabBarKey,
                      tabs: [
                        Tab(text: 'First'),
                        Tab(text: 'Second'),
                      ],
                    ),
                  ),
                )
              : const SizedBox(),
        ),
      );
    }

    await tester.pumpWidget(buildApp(showTabBar: true));
    bucket.writeState(tester.element(find.byKey(tabBarKey)), 1);
    await tester.pumpWidget(buildApp(showTabBar: false));

    await tester.pumpWidget(buildApp(showTabBar: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final context = tester.element(find.byKey(tabBarKey));
    expect(DefaultTabController.of(context).index, 1);
  });
}
