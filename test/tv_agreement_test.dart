import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/tv_agreement.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);
  testWidgets('D-pad reads and accepts on a short landscape screen', (
    tester,
  ) async {
    appdata.settings['language'] = 'en-US';
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var accepted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          },
          child: TvAgreement(
            accept: () async {
              accepted = true;
            },
            decline: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final doc = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView).first,
    );
    expect(doc.controller!.position.viewportDimension, greaterThan(220));
    expect(accepted, isFalse);
    Future<void> key(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    await key(LogicalKeyboardKey.arrowDown);
    expect(doc.controller!.offset, greaterThan(0));
    await key(LogicalKeyboardKey.arrowRight);
    await key(LogicalKeyboardKey.select);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await key(LogicalKeyboardKey.arrowDown);
    await key(LogicalKeyboardKey.select);
    expect(accepted, isTrue);
  });
}
