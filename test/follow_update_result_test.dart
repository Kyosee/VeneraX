import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/follow_update_result.dart';
import 'package:venera/foundation/log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'result persistence failure does not interrupt task completion',
    () async {
      final directory = Directory.systemTemp.createTempSync('follow-result-');
      final blocked = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('');
      final originalPath = App.dataPath;
      final originalBackground = App.isBackgroundTask;
      final originalResult = appdata.implicitData['follow_update_last_result'];
      addTearDown(() {
        App.dataPath = originalPath;
        App.isBackgroundTask = originalBackground;
        appdata.implicitData['follow_update_last_result'] = originalResult;
        directory.deleteSync(recursive: true);
      });
      App.dataPath = blocked.path;
      App.isBackgroundTask = true;
      final result = FollowUpdateResult(
        checkedAt: DateTime(2026, 11, 20),
        updatedKeys: {'test:comic'},
      );

      await result.save();

      expect(FollowUpdateResult.latest!.updatedKeys, {'test:comic'});
      expect(Log.logs.last.title, 'Follow update result');
    },
  );
}
