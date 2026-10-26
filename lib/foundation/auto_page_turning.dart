import 'dart:math' as math;

/// Values of the `autoPageTurningMode` reader setting.
const autoTurnModePage = 'page';
const autoTurnModeScroll = 'scroll';

/// `autoPageTurningInterval`, seconds per page.
const autoTurnIntervalMin = 1;
const autoTurnIntervalMax = 20;
const autoTurnIntervalDefault = 5;

/// `autoScrollSpeed`, a level where higher scrolls faster.
const autoScrollSpeedMin = 1;
const autoScrollSpeedMax = 30;
const autoScrollSpeedDefault = 15;

int autoTurnIntervalOf(Object? value) =>
    (value is num ? value.round() : autoTurnIntervalDefault).clamp(
      autoTurnIntervalMin,
      autoTurnIntervalMax,
    );

int autoScrollSpeedOf(Object? value) =>
    (value is num ? value.round() : autoScrollSpeedDefault).clamp(
      autoScrollSpeedMin,
      autoScrollSpeedMax,
    );

/// Whether auto turning scrolls the list instead of turning pages. Gallery
/// modes always turn pages: a pager has nothing to scroll between pages.
bool autoTurnScrolls(String readerModeKey, Object? turnMode) =>
    readerModeKey.startsWith('continuous') && turnMode == autoTurnModeScroll;

/// Scroll speed for [level], in image widths per second (image heights in
/// the horizontal modes). Tied to the image size rather than the screen, a
/// level reads at the same pace on a phone, a tablet and a narrow desktop
/// column. Steps are geometric, ~14% apart, from about a minute per phone
/// screen at the slowest to about a second at the fastest.
double autoScrollWidthsPerSecond(int level) {
  const slowest = 0.04, fastest = 2.0;
  final t =
      (level.clamp(autoScrollSpeedMin, autoScrollSpeedMax) -
          autoScrollSpeedMin) /
      (autoScrollSpeedMax - autoScrollSpeedMin);
  return slowest * math.pow(fastest / slowest, t);
}

/// Moves [distance] logical pixels plus the [carry] left from earlier frames,
/// in whole device pixels. Returns the logical step to apply now and the new
/// carry. A slow scroll otherwise lands on a new sub-pixel offset every frame
/// and resamples the page each time, which makes fine linework shimmer.
(double step, double carry) autoScrollStep(
  double distance,
  double carry,
  double devicePixelRatio,
) {
  final total = carry + distance;
  final step = (total * devicePixelRatio).floorToDouble() / devicePixelRatio;
  return (step, total - step);
}
