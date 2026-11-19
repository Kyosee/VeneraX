import 'package:flutter/material.dart';

/// A shared background for chapter rows and translation task cards.
class TranslationProgressSurface extends StatelessWidget {
  const TranslationProgressSurface({
    super.key,
    required this.child,
    this.progress,
    this.paused = false,
    this.active = false,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final double? progress;
  final bool paused;
  final bool active;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final value = progress?.isFinite == true ? progress!.clamp(0.0, 1.0) : null;
    final fill = colors.primary.withValues(
      alpha: paused || value == null ? (dark ? .11 : .10) : (dark ? .23 : .17),
    );

    Widget paint(double? progress, Widget child) => CustomPaint(
      painter: _ProgressSurfacePainter(progress, fill, borderRadius),
      child: child,
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: active
            ? Color.alphaBlend(
                colors.primary.withValues(alpha: .04),
                colors.surface,
              )
            : colors.surface,
        child: value == null || MediaQuery.disableAnimationsOf(context)
            ? paint(value, child)
            : TweenAnimationBuilder<double>(
                tween: Tween(begin: value, end: value),
                duration: const Duration(milliseconds: 280),
                curve: Curves.ease,
                child: child,
                builder: (context, progress, child) => paint(progress, child!),
              ),
      ),
    );
  }
}

class _ProgressSurfacePainter extends CustomPainter {
  const _ProgressSurfacePainter(this.progress, this.color, this.borderRadius);

  final double? progress;
  final Color color;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (progress != null) {
      canvas.drawRRect(
        borderRadius.toRRect(
          Rect.fromLTWH(0, 0, size.width * progress!, size.height),
        ),
        paint,
      );
      return;
    }
  }

  @override
  bool shouldRepaint(_ProgressSurfacePainter oldDelegate) =>
      progress != oldDelegate.progress ||
      color != oldDelegate.color ||
      borderRadius != oldDelegate.borderRadius;
}
