import 'appdata.dart';

/// The last finished check, independent of the unread flags cleared by reading.
class FollowUpdateResult {
  const FollowUpdateResult({
    required this.checkedAt,
    required this.updatedKeys,
    this.failed = 0,
  });

  final DateTime checkedAt;
  // Null means an interrupted check could not recover its complete results.
  final Set<String>? updatedKeys;
  final int failed;

  static FollowUpdateResult? get latest {
    final data = appdata.implicitData['follow_update_last_result'];
    if (data is! Map || data['checkedAt'] is! int) return null;
    final keys = data['updatedKeys'];
    return FollowUpdateResult(
      checkedAt: DateTime.fromMillisecondsSinceEpoch(data['checkedAt'] as int),
      updatedKeys: keys is List ? keys.whereType<String>().toSet() : null,
      failed: (data['failed'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> save() async {
    appdata.implicitData['follow_update_last_result'] = {
      'checkedAt': checkedAt.millisecondsSinceEpoch,
      'updatedKeys': updatedKeys?.toList(),
      'failed': failed,
    };
    await appdata.writeImplicitData();
  }
}
