import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

typedef _ClockGettimeNative = Int Function(Int clock, Pointer<_Timespec> time);
typedef _ClockGettime = int Function(int clock, Pointer<_Timespec> time);

/// When the device last booted, in milliseconds since the epoch, or null when
/// the platform does not say.
///
/// A run that ended because the device lost power looks exactly like a crash
/// from inside the app; a boot time that moved since is what tells them apart.
int? bootTimeMillis() {
  try {
    final uptime = _uptimeMillis();
    // A value outside any plausible uptime means the call did not do what it
    // is assumed to do on this platform; better no answer than a wrong one.
    if (uptime == null || uptime < 0 || uptime > _longestUptime) return null;
    return DateTime.now().millisecondsSinceEpoch - uptime;
  } catch (_) {
    return null;
  }
}

const _longestUptime = 10 * 365 * 24 * 60 * 60 * 1000;

int? _uptimeMillis() {
  if (Platform.isWindows) {
    return DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint64 Function(), int Function()>('GetTickCount64')();
  }
  // Both keep counting while the device sleeps: CLOCK_BOOTTIME on Linux
  // kernels, CLOCK_MONOTONIC on Darwin.
  final clock = Platform.isMacOS || Platform.isIOS ? 6 : 7;
  final clockGettime = DynamicLibrary.process()
      .lookupFunction<_ClockGettimeNative, _ClockGettime>('clock_gettime');
  final time = calloc<_Timespec>();
  try {
    if (clockGettime(clock, time) != 0) return null;
    return time.ref.seconds * 1000 + time.ref.nanoseconds ~/ 1000000;
  } finally {
    calloc.free(time);
  }
}
