import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Antivirus scanners and indexers briefly hold files that were just written
/// or are about to move. Windows then reports access denied (5), a sharing
/// violation (32) or a lock violation (33); waiting a moment resolves these.
const transientRetryDelays = [
  Duration(milliseconds: 100),
  Duration(milliseconds: 200),
  Duration(milliseconds: 400),
  Duration(milliseconds: 800),
  Duration(seconds: 1),
  Duration(seconds: 1),
  Duration(seconds: 1),
];

Future<T> retryTransient<T>(
  Future<T> Function() operation, {
  List<Duration> delays = transientRetryDelays,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await operation();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (attempt >= delays.length ||
          !Platform.isWindows ||
          !(code == 5 || code == 32 || code == 33)) {
        rethrow;
      }
      await Future<void>.delayed(delays[attempt]);
    }
  }
}

/// Prepare on the installation volume, then switch directories. A locked old
/// file must never leave a partially deleted installation behind.
Future<void> replaceWindowsInstallation({
  required Directory installed,
  required Directory payload,
  FutureOr<void> Function()? beforeActivate,
  void Function(String)? log,
}) async {
  if (FileSystemEntity.typeSync(installed.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('App directory must not be a link');
  }
  final parent = installed.absolute.parent;
  final transaction = await parent.createTemp('.venera-update-');
  final previous = Directory(p.join(transaction.path, 'previous'));
  var moved = false;
  var activated = false;
  try {
    var next = Directory(p.join(transaction.path, 'next'));
    await _copyFiles(payload, next);
    await for (final entry in installed.list(followLinks: false)) {
      if (!p.basename(entry.path).toLowerCase().startsWith('unins')) continue;
      if (entry is! File) {
        throw const FileSystemException('Invalid uninstaller entry');
      }
      final target = p.join(next.path, p.basename(entry.path));
      await retryTransient(() => entry.copy(target));
    }
    // Renaming the new tree first waits out scanners still reading it, so the
    // interval without an app directory stays short.
    next = await retryTransient(
      () => next.rename(p.join(transaction.path, 'ready')),
    );
    // Both moves stay on one volume. Failure of the first leaves the app intact.
    await retryTransient(() => installed.rename(previous.path));
    moved = true;
    await beforeActivate?.call();
    await retryTransient(() => next.rename(installed.path));
    activated = true;
  } catch (_) {
    if (moved && !activated) {
      try {
        await retryTransient(
          () => previous.rename(installed.path),
          delays: [...transientRetryDelays, ...transientRetryDelays],
        );
        moved = false;
      } catch (error) {
        log?.call(
          'Restore failed; original app retained at ${previous.path}: $error',
        );
      }
    }
    rethrow;
  } finally {
    // Never delete the only remaining original copy after a failed restore.
    if (!moved || activated) {
      try {
        await retryTransient(() => transaction.delete(recursive: true));
      } catch (error) {
        log?.call(
          'Temporary update directory retained at ${transaction.path}: $error',
        );
      }
    }
  }
}

Future<void> _copyFiles(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final target = p.join(
      destination.path,
      p.relative(entry.path, from: source.path),
    );
    if (entry is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entry is File) {
      await File(target).parent.create(recursive: true);
      await retryTransient(() => entry.copy(target));
    } else {
      throw const FileSystemException('Update payload must not contain links');
    }
  }
}
