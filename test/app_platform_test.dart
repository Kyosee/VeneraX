import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in TargetPlatform.values) {
    test('classifies ${platform.name} without overlapping device types', () {
      debugDefaultTargetPlatformOverride = platform;

      final mobile = {'android', 'iOS', 'ohos'}.contains(platform.name);
      final desktop = {'windows', 'linux', 'macOS'}.contains(platform.name);
      expect(App.isMobile, !kIsWeb && mobile);
      expect(App.isDesktop, !kIsWeb && desktop);
      expect(App.isAndroid, !kIsWeb && platform == TargetPlatform.android);
      expect(App.isIOS, !kIsWeb && platform == TargetPlatform.iOS);
      expect(App.isOhos, !kIsWeb && platform.name == 'ohos');
    });
  }

  final ohos = TargetPlatform.values.where(
    (platform) => platform.name == 'ohos',
  );
  test(
    'OHOS uses mobile behavior without Android or Apple platform services',
    () {
      debugDefaultTargetPlatformOverride = ohos.single;

      expect(App.isMobile, isTrue);
      expect(App.isOhos, isTrue);
      expect(App.isDesktop, isFalse);
      expect(App.isAndroid, isFalse);
      expect(App.isIOS, isFalse);
      expect(App.isMacOS, isFalse);
      expect(App.isLinux, isFalse);
      expect(App.isWindows, isFalse);
    },
    skip: ohos.isEmpty ? 'Requires the Flutter OH SDK.' : false,
  );
}
