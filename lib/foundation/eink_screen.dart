import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';

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
