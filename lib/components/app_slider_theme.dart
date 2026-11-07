import 'package:flutter/material.dart';

SliderThemeData appSliderTheme(ColorScheme colors) => SliderThemeData(
  trackHeight: 20,
  trackShape: const _AppSliderTrackShape(),
  thumbShape: const _AppSliderThumbShape(),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
  tickMarkShape: SliderTickMarkShape.noTickMark,
  activeTrackColor: colors.primary,
  inactiveTrackColor: colors.surfaceContainerHighest,
  disabledActiveTrackColor: colors.onSurface.withValues(alpha: 0.24),
  disabledInactiveTrackColor: colors.onSurface.withValues(alpha: 0.08),
  thumbColor: Colors.white,
  disabledThumbColor: colors.surfaceContainerHighest,
  overlayColor: colors.primary.withValues(alpha: 0.12),
);

class _AppSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _AppSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (track.isEmpty) return;
    final active = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final inactive = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;
    final canvas = context.canvas;
    final roundedTrack = RRect.fromRectAndRadius(
      track,
      Radius.circular(track.height / 2),
    );
    canvas.drawRRect(roundedTrack, Paint()..color = inactive);
    final reversed = textDirection == TextDirection.rtl;
    final activeTrack = Rect.fromLTRB(
      reversed ? thumbCenter.dx : track.left,
      track.top,
      reversed ? track.right : thumbCenter.dx,
      track.bottom,
    );
    canvas.save();
    canvas.clipRRect(roundedTrack);
    canvas.clipRect(activeTrack);
    canvas.drawRect(
      track,
      Paint()
        ..shader = LinearGradient(
          begin: reversed ? Alignment.centerRight : Alignment.centerLeft,
          end: reversed ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            Color.lerp(active, Colors.black, 0.12)!,
            Color.lerp(active, Colors.white, 0.38)!,
            Color.lerp(active, Colors.white, 0.12)!,
          ],
          stops: const [0, 0.6, 1],
        ).createShader(track),
    );
    // Stable points avoid flicker while the thumb or theme changes.
    final count = (track.width / 8).round().clamp(8, 100);
    for (var i = 0; i < count; i++) {
      final x = (i * 0.61803398875 + 0.07) % 1;
      final y = (i * 0.75487766625 + 0.23) % 1;
      final center = Offset(
        track.left + (reversed ? 1 - x : x) * track.width,
        track.top + (0.15 + y * 0.7) * track.height,
      );
      final radius = i % 7 == 0 ? 1.1 : 0.6;
      final paint = Paint()
        ..color = Colors.white.withValues(
          alpha: (i % 3 == 0 ? 0.65 : 0.3) * enableAnimation.value,
        );
      canvas.drawCircle(center, radius, paint);
      if (i % 7 == 0) {
        canvas.drawCircle(
          center,
          radius * 2.5,
          Paint()
            ..color = Colors.white.withValues(
              alpha: 0.12 * enableAnimation.value,
            ),
        );
      }
    }
    canvas.restore();
  }
}

class _AppSliderThumbShape extends RoundSliderThumbShape {
  const _AppSliderThumbShape()
    : super(enabledThumbRadius: 13, elevation: 2, pressedElevation: 3);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    super.paint(
      context,
      center,
      activationAnimation: activationAnimation,
      enableAnimation: enableAnimation,
      isDiscrete: isDiscrete,
      labelPainter: labelPainter,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      textDirection: textDirection,
      value: value,
      textScaleFactor: textScaleFactor,
      sizeWithOverflow: sizeWithOverflow,
    );
    context.canvas.drawCircle(
      center,
      enabledThumbRadius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Color.lerp(
          sliderTheme.disabledActiveTrackColor,
          sliderTheme.activeTrackColor,
          enableAnimation.value,
        )!,
    );
  }
}
