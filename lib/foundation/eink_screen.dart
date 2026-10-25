import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';

/// Solid frames painted over the page during a full e-ink refresh. E-ink only
/// redraws pixels that change, so a page turn leaves a faint trace of the old
/// page; covering the whole screen with a solid color forces every pixel to
/// switch and clears it.
enum EinkRefreshColor {
  white('white', [Color(0xFFFFFFFF)]),
  black('black', [Color(0xFF000000)]),
  blackThenWhite('blackThenWhite', [Color(0xFF000000), Color(0xFFFFFFFF)]);

  const EinkRefreshColor(this.key, this.frames);

  final String key;

  /// Shown in order, each for the configured duration.
  final List<Color> frames;

  static EinkRefreshColor fromKey(Object? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => white);
}

/// Counts settled page turns and paints the refresh frames every N turns.
/// The reader listens to [overlay] and covers the page while it holds a color.
class EinkRefresher {
  final overlay = ValueNotifier<Color?>(null);

  Timer? _timer;

  int _turns = 0;

  bool get _enabled => appdata.settings['einkFullRefresh'] == true;

  int get _interval =>
      ((appdata.settings['einkRefreshInterval'] as num?)?.toInt() ?? 1).clamp(
        1,
        10,
      );

  Duration get _frameDuration => Duration(
    milliseconds:
        ((appdata.settings['einkRefreshDuration'] as num?)?.toInt() ?? 150)
            .clamp(50, 1000),
  );

  /// Whether the next settled turn will be covered by a refresh.
  bool get flashesNextTurn => _enabled && _turns + 1 >= _interval;

  /// Call once the reader has come to rest on a different page.
  void onPageSettled() {
    if (!_enabled) return;
    _turns++;
    if (_turns < _interval) return;
    _turns = 0;
    _play(EinkRefreshColor.fromKey(appdata.settings['einkRefreshColor']).frames);
  }

  void _play(List<Color> frames) {
    _timer?.cancel();
    if (frames.isEmpty) {
      overlay.value = null;
      return;
    }
    overlay.value = frames.first;
    _timer = Timer(_frameDuration, () => _play(frames.sublist(1)));
  }

  void dispose() {
    _timer?.cancel();
    overlay.dispose();
  }
}

/// Direction the page content travels during a turn, as the reader sees it.
/// Declared clockwise from up; [rippleCodes] and [opposite] rely on the order.
enum RippleSweep {
  upward,
  rightward,
  downward,
  leftward;

  RippleSweep get opposite => values[(index + 2) % 4];
}

enum RippleSpeed {
  slower('slower', 128),
  standard('standard', 64),
  faster('faster', 0);

  const RippleSpeed(this.key, this.flag);

  final String key;

  /// Speed bits the display controller reads alongside the direction.
  final int flag;

  static RippleSpeed fromKey(Object? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => standard);
}

/// The controller names directions by the panel's own edges, which only line
/// up with the reader's view in the natural orientation. Index i of the result
/// is the command for display rotation i (quarter turns), picked natively.
@visibleForTesting
List<int> rippleCodes(RippleSweep sweep, RippleSpeed speed) {
  // Panel edge codes, clockwise from the top edge.
  const edgeCodes = [4, 2, 3, 1];
  return [
    for (var rotation = 0; rotation < 4; rotation++)
      edgeCodes[(sweep.index + rotation) % 4] | speed.flag,
  ];
}

/// Native page-turn ripple on supported e-readers (Android only).
class EinkPanel {
  EinkPanel._();

  static const _channel = MethodChannel('venera/eink');

  static bool? _supported;

  static Future<bool>? _probe;

  /// Last probe result; false until [probeRipple] completes.
  static bool get rippleSupported => _supported == true;

  static bool get rippleProbed => _supported != null;

  static Future<bool> probeRipple() {
    return _probe ??= () async {
      var supported = false;
      if (App.isAndroid) {
        try {
          supported = await _channel.invokeMethod<bool>('rippleSupported') ==
              true;
        } catch (e) {
          Log.error("E-ink", "Ripple probe failed: $e");
        }
      }
      return _supported = supported;
    }();
  }

  /// Arms the ripple for the next screen update. Completes once the command is
  /// in place, so the caller can draw the new page right after.
  static Future<void> queueRipple(RippleSweep sweep) async {
    if (!rippleSupported) return;
    final speed = RippleSpeed.fromKey(appdata.settings['einkRippleSpeed']);
    try {
      await _channel
          .invokeMethod('queueRipple', rippleCodes(sweep, speed))
          .timeout(const Duration(milliseconds: 300));
    } catch (e) {
      Log.error("E-ink", "Ripple command failed: $e");
    }
  }
}
