import 'dart:convert';

import 'package:venera/utils/io.dart';

/// Device-local continuation state, accessed only while holding the data lease.
class BackgroundFollowQueue {
  BackgroundFollowQueue(this.path) {
    if (!File(path).existsSync()) return;
    try {
      final data = jsonDecode(File(path).readAsStringSync()) as Map;
      _order.addAll((data['order'] as List).cast<String>().toSet());
      _pending.addAll((data['pending'] as List).cast<String>());
      _inFlight.addAll((data['inFlight'] as Map).cast<String, String?>());
    } on FormatException {
      _reset();
    } on TypeError {
      _reset();
    }
  }

  final String path;
  final _order = <String>[];
  final _pending = <String>{};
  final _inFlight = <String, String?>{};

  Set<String> get pending => Set.unmodifiable(_pending);

  void _reset() {
    _order.clear();
    _pending.clear();
    _inFlight.clear();
  }

  void reconcile(Map<String, String?> updateTimes) {
    // Recover a DB write completed just before the worker was killed.
    for (final entry in _inFlight.entries) {
      if (updateTimes.containsKey(entry.key) &&
          updateTimes[entry.key] != entry.value) {
        _pending.add(entry.key);
      }
    }
    _inFlight.clear();
    _pending.removeWhere((key) => !updateTimes.containsKey(key));
    _order.removeWhere((key) => !updateTimes.containsKey(key));
    final existing = _order.toSet();
    _order.addAll(updateTimes.keys.where((key) => !existing.contains(key)));
    _save();
  }

  List<String> takeBatch(Set<String> due, Map<String, String?> updateTimes) {
    final batch = _order.where(due.contains).take(5).toList();
    final selected = batch.toSet();
    _order.removeWhere(selected.contains);
    _order.addAll(batch);
    for (final key in batch) {
      _inFlight[key] = updateTimes[key];
    }
    // Rotate before requests: failures and timeouts must not starve the tail.
    _save();
    return batch;
  }

  void complete(String key, {required bool updated}) {
    _inFlight.remove(key);
    if (updated) _pending.add(key);
    _save();
  }

  void acknowledge(Set<String> notified) {
    _pending.removeAll(notified);
    _save();
  }

  void _save() => writeStringAtomicSync(
    path,
    jsonEncode({
      'order': _order,
      'pending': _pending.toList(),
      'inFlight': _inFlight,
    }),
  );
}
