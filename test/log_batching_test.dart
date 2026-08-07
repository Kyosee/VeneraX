import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';

/// Log lines used to hit the disk one at a time, which on a comic page meant a
/// write per network request — continuous small I/O that keeps the storage
/// controller awake and drains the battery without costing frame rate. Lines
/// are now buffered and flushed on a timer, with errors going out immediately.
///
/// These tests cover the parts observable without a real file sink: the
/// in-memory list must stay intact, and flushing must never lose entries or
/// throw when no sink was ever opened (the case in unit tests and headless).
void main() {
  setUp(() => Log.clear());

  test('flush is a no-op when no file sink was opened', () {
    Log.info('Test', 'hello');
    // Must not throw: _file is null in tests, so there is nothing to write.
    Log.flush();
    expect(Log.logs, hasLength(1));
  });

  test('clear flushes rather than dropping, and empties the view', () {
    Log.info('Test', 'first');
    Log.error('Test', 'second');
    Log.clear();
    expect(Log.logs, isEmpty);
  });

  test('buffering does not delay the in-memory list', () {
    // The logs page reads the list directly, so it must be updated
    // synchronously even though the disk write is deferred.
    Log.info('Test', 'visible right away');
    expect(Log.logs.single.content, 'visible right away');
  });

  test('errors are recorded and flushed without throwing', () {
    Log.error('Test', 'boom');
    // Errors flush immediately rather than waiting for the timer, so a crash
    // right after this point still leaves the explanation on disk.
    expect(Log.logs.single.level, LogLevel.error);
  });

  test('verbose network logging defaults to off', () {
    // The default decides whether ordinary reading pays the logging cost.
    expect(Log.verboseNetwork, isFalse);
  });

  test('syncVerboseNetwork drives the flag both ways', () {
    // Log cannot read settings directly (appdata imports it), so the stored
    // setting reaches it only through this call. If startup or the toggle ever
    // stops making it, logging silently reverts to recording every request.
    Log.syncVerboseNetwork(true);
    expect(Log.verboseNetwork, isTrue);
    Log.syncVerboseNetwork(false);
    expect(Log.verboseNetwork, isFalse);
  });
}
