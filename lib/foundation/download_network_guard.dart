import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';

/// Pauses active downloads on a metered (cellular) connection when the user has
/// turned on "WiFi only", and resumes them once an unmetered connection
/// returns. A no-op while the setting is off, and on platforms that don't
/// report connectivity.
///
/// Kept separate from [LocalManager] so the queue stays agnostic of how a
/// network-pause is decided — this class only flips a single block flag.
class DownloadNetworkGuard {
  DownloadNetworkGuard._();

  static final DownloadNetworkGuard instance = DownloadNetworkGuard._();

  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// Begin watching connectivity. Idempotent. Safe to call before any download
  /// exists — it just evaluates the current network once and then on changes.
  void start() {
    _sub ??= Connectivity().onConnectivityChanged.listen(
      _onChanged,
      onError: (_) {},
    );
    unawaited(_evaluate());
  }

  /// Re-evaluate immediately after the "WiFi only" setting is toggled so the
  /// effect is instant rather than waiting for the next connectivity change.
  void onSettingChanged() => unawaited(_evaluate());

  void _onChanged(List<ConnectivityResult> _) => unawaited(_evaluate());

  Future<void> _evaluate() async {
    // Setting off: never block on our account (clears any previous block).
    if (appdata.settings['downloadWifiOnly'] != true) {
      LocalManager().setNetworkBlocked(false);
      return;
    }
    List<ConnectivityResult> result;
    try {
      result = await Connectivity().checkConnectivity();
    } catch (e) {
      Log.error("Download", "connectivity check failed: $e");
      return; // can't tell — leave the queue as-is rather than guessing
    }
    final hasUnmetered = result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.ethernet);
    final hasMetered = result.contains(ConnectivityResult.mobile) ||
        result.contains(ConnectivityResult.satellite);
    // Only block when clearly on a metered link with no unmetered one. "No
    // network" doesn't actively block: downloads simply fail/retry, and a real
    // WiFi/ethernet event will re-evaluate.
    LocalManager().setNetworkBlocked(hasMetered && !hasUnmetered);
  }
}
