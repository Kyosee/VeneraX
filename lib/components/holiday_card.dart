import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class HolidayCard extends StatelessWidget {
  const HolidayCard({
    super.key,
    required this.christmas,
    required this.year,
    required this.greeting,
    required this.backLabel,
    required this.dismissLabel,
    required this.onBack,
    required this.onDismiss,
  });

  final bool christmas;
  final int year;
  final String greeting;
  final String backLabel;
  final String dismissLabel;
  final VoidCallback onBack;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final chinese = locale.languageCode == 'zh';
    final traditional =
        locale.scriptCode == 'Hant' ||
        const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
    final paper = christmas ? const Color(0xffedf3e9) : const Color(0xff14233c);
    final ink = christmas ? const Color(0xff264d40) : const Color(0xfff1d69b);
    final stroke = christmas
        ? const Color(0xffc2b489)
        : const Color(0xff9c8454);
    final action = christmas
        ? const Color(0xff244d3f)
        : const Color(0xfff0ce86);
    final buttonInk = christmas
        ? const Color(0xfffff5db)
        : const Color(0xff16263f);
    final note = christmas ? const Color(0xff456452) : const Color(0xffdfcfae);
    final buttonText = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.4,
    );

    return Dialog(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      constraints: const BoxConstraints(maxWidth: 430),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: stroke),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CardArt(christmas: christmas, year: year),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 23),
                  child: Semantics(
                    header: true,
                    child: Text(
                      greeting,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontFamily: chinese
                            ? (traditional
                                  ? 'HolidayGreetingTC'
                                  : 'HolidayGreetingSC')
                            : 'Georgia',
                        fontFamilyFallback: const ['Times New Roman', 'serif'],
                        fontWeight: chinese ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 30,
                        height: 1.4,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: onBack,
                        style: FilledButton.styleFrom(
                          backgroundColor: action,
                          foregroundColor: buttonInk,
                          textStyle: buttonText,
                          minimumSize: const Size(0, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(backLabel, textAlign: TextAlign.center),
                      ),
                      const SizedBox(height: 5),
                      TextButton(
                        onPressed: onDismiss,
                        style: TextButton.styleFrom(
                          foregroundColor: note,
                          textStyle: buttonText,
                          minimumSize: const Size(0, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(dismissLabel, textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              autofocus: true,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: onBack,
              style: IconButton.styleFrom(
                foregroundColor: const Color(0xfffff6df),
                backgroundColor: const Color(0x66112a30),
                minimumSize: const Size.square(44),
                side: const BorderSide(color: Color(0x44ffffff)),
              ),
              icon: const Icon(Icons.close, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardArt extends StatefulWidget {
  const _CardArt({required this.christmas, required this.year});

  final bool christmas;
  final int year;

  @override
  State<_CardArt> createState() => _CardArtState();
}

class _CardArtState extends State<_CardArt>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // The controller value is elapsed seconds so changing frames never changes speed.
  late final _seconds = AnimationController(
    vsync: this,
    upperBound: Duration.secondsPerDay.toDouble(),
    duration: const Duration(days: 1),
  );
  bool _canAnimate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    _canAnimate = !reduced && (ModalRoute.isCurrentOf(context) ?? true);
    _syncMotion(WidgetsBinding.instance.lifecycleState);
    if (reduced) _seconds.value = 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _syncMotion(state);

  void _syncMotion(AppLifecycleState? state) {
    final active =
        _canAnimate && (state == null || state == AppLifecycleState.resumed);
    if (active && !_seconds.isAnimating) {
      _seconds.repeat();
    } else if (!active && _seconds.isAnimating) {
      _seconds.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.christmas ? null : widget.year.toString(),
      child: AspectRatio(
        aspectRatio: 480 / 400,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              widget.christmas
                  ? 'assets/holidays/card_christmas.webp'
                  : 'assets/holidays/card_newyear.webp',
              fit: BoxFit.fill,
              excludeFromSemantics: true,
            ),
            if (!widget.christmas)
              CustomPaint(painter: _YearPainter(widget.year)),
            RepaintBoundary(
              child: CustomPaint(
                painter: _MotionPainter(widget.christmas, _seconds),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _YearPainter extends CustomPainter {
  const _YearPainter(this.year);
  final int year;

  // Single-line numerals match the engraved lettering on the ticket.
  static final _digits = <Path>[
    Path()
      ..moveTo(25, 2)
      ..cubicTo(9, 2, 3, 15, 3, 35)
      ..cubicTo(3, 56, 8, 69, 25, 69)
      ..cubicTo(42, 69, 48, 55, 48, 35)
      ..cubicTo(48, 15, 42, 2, 25, 2)
      ..close(),
    Path()
      ..moveTo(9, 17)
      ..lineTo(27, 3)
      ..lineTo(27, 69)
      ..moveTo(9, 69)
      ..lineTo(45, 69),
    Path()
      ..moveTo(3, 19)
      ..cubicTo(4, 0, 31, -4, 42, 7)
      ..cubicTo(57, 22, 45, 38, 27, 51)
      ..lineTo(5, 69)
      ..lineTo(49, 69),
    Path()
      ..moveTo(4, 10)
      ..cubicTo(19, -3, 47, -1, 46, 16)
      ..cubicTo(46, 28, 35, 34, 20, 34)
      ..cubicTo(40, 32, 49, 40, 47, 53)
      ..cubicTo(44, 73, 17, 74, 3, 62),
    Path()
      ..moveTo(38, 69)
      ..lineTo(38, 3)
      ..lineTo(3, 48)
      ..lineTo(49, 48),
    Path()
      ..moveTo(48, 3)
      ..lineTo(8, 3)
      ..lineTo(6, 35)
      ..cubicTo(27, 24, 48, 30, 48, 50)
      ..cubicTo(47, 71, 18, 76, 3, 62),
    Path()
      ..moveTo(42, 4)
      ..cubicTo(16, -3, 3, 21, 4, 48)
      ..cubicTo(4, 74, 47, 78, 48, 49)
      ..cubicTo(48, 27, 17, 24, 5, 44),
    Path()
      ..moveTo(2, 3)
      ..lineTo(48, 3)
      ..lineTo(16, 69)
      ..moveTo(18, 45)
      ..lineTo(36, 45),
    Path()
      ..moveTo(25, 34)
      ..cubicTo(-3, 30, 0, 2, 25, 2)
      ..cubicTo(51, 2, 53, 30, 25, 34)
      ..cubicTo(-5, 38, -2, 69, 25, 69)
      ..cubicTo(52, 69, 56, 38, 25, 34)
      ..close(),
    Path()
      ..moveTo(7, 66)
      ..cubicTo(35, 77, 48, 49, 47, 23)
      ..cubicTo(46, -4, 4, -5, 3, 22)
      ..cubicTo(2, 45, 34, 48, 47, 27),
  ];
  static final _foil = ui.Gradient.linear(
    Offset.zero,
    const Offset(0, 70),
    const [
      Color(0xfff9e8ae),
      Color(0xffefd398),
      Color(0xffcda064),
      Color(0xfff6d99b),
    ],
    const [0, .35, .7, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 480, size.height / 400);
    canvas.translate(99, 150);
    canvas.scale(1.18, 1.31);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.square;
    for (final char in year.toString().codeUnits) {
      final path = _digits[char - 48];
      canvas.save();
      canvas.translate(1.6, 2.4);
      canvas.drawPath(
        path,
        pen
          ..color = const Color(0xff071729)
          ..strokeWidth = 8,
      );
      canvas.restore();
      canvas.drawPath(
        path,
        pen
          ..color = const Color(0xffc19559)
          ..strokeWidth = 7.2,
      );
      canvas.drawPath(
        path,
        pen
          ..shader = _foil
          ..strokeWidth = 5.3,
      );
      canvas.drawPath(
        path,
        pen
          ..shader = null
          ..color = const Color(0xff8d703e)
          ..strokeWidth = .8,
      );
      canvas.translate(61.5, 0);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_YearPainter oldDelegate) => year != oldDelegate.year;
}

class _MotionPainter extends CustomPainter {
  _MotionPainter(this.christmas, this.clock) : super(repaint: clock);

  final bool christmas;
  final Animation<double> clock;
  static final _snow = _snowflakes();
  static final _rays = [
    _burstRays(36, 79, 9),
    _burstRays(34, 78, 18),
    _burstRays(24, 39, 27),
  ];
  static const _bursts = [
    (Offset(82, 106), Color(0xfff0ce86), .2),
    (Offset(396, 94), Color(0xfff2b8a5), .57),
    (Offset(279, 73), Color(0xffa2d4cd), .83),
  ];
  static const _lights = [
    Offset(-8, 82),
    Offset(17, 106),
    Offset(-31, 139),
    Offset(13, 145),
    Offset(42, 162),
    Offset(-23, 175),
    Offset(-50, 194),
    Offset(11, 198),
    Offset(60, 187),
  ];

  // This seed sequence also laid out the original illustration.
  static double Function() _random(int seed) => () {
    seed = (1664525 * seed + 1013904223) & 0xffffffff;
    return seed / 4294967296;
  };

  static List<({double x, double y, double speed, double radius, double alpha})>
  _snowflakes() {
    final rand = _random(2512);
    return List.generate(
      56,
      (_) => (
        x: rand() * 480,
        y: rand() * 350,
        speed: 11 + rand() * 13,
        radius: .65 + rand() * 1.5,
        alpha: .3 + rand() * .6,
      ),
    );
  }

  static List<({Offset direction, double fall, double alpha, double tipRadius})>
  _burstRays(int count, double radius, int seed) {
    final rand = _random(seed);
    return List.generate(count, (i) {
      final angle = (i + .1 + rand() * .3) * 2 * math.pi / count;
      final length = radius * (.65 + .42 * rand());
      return (
        direction: Offset(math.cos(angle), math.sin(angle)) * length,
        fall: length * (.16 + rand() * .16),
        alpha: .48 + rand() * .43,
        tipRadius: .55 + rand() * .9,
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 480, size.height / 400);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 480, 400));
    if (christmas) {
      _paintSnow(canvas, clock.value);
    } else {
      _paintFireworks(canvas, clock.value);
    }
    canvas.restore();
  }

  void _paintSnow(Canvas c, double seconds) {
    final pen = Paint();
    for (var i = 0; i < _snow.length; i++) {
      final snow = _snow[i];
      final y = (snow.y + seconds * snow.speed) % 365;
      final x = snow.x + math.sin(seconds * .45 + i) * 12;
      pen.color = const Color(
        0xfffbfff5,
      ).withValues(alpha: snow.alpha * math.min(1, (380 - y) / 50));
      c.drawCircle(Offset(x, y), snow.radius, pen);
    }
    c.translate(240, 37);
    c.scale(1.3);
    for (var i = 0; i < _lights.length; i++) {
      final center = _lights[i];
      final glow = .52 + .22 * math.sin(seconds * 1.3 + i * .7);
      pen.shader = ui.Gradient.radial(
        center,
        8,
        [
          const Color(0xffffe7a4).withValues(alpha: glow),
          const Color(0xfff9c65e).withValues(alpha: glow * .52),
          const Color(0x00f9c65e),
        ],
        const [0, .3, 1],
      );
      pen.color = Colors.white;
      c.drawCircle(center, 8, pen);
      pen.shader = null;
      pen.color = const Color(0xfffff4c3).withValues(alpha: glow);
      c.drawCircle(center, 1.3, pen);
    }
    _spark(
      c,
      const Offset(0, 31),
      8,
      pen
        ..color = const Color(
          0xfffff2b8,
        ).withValues(alpha: .65 + .2 * math.sin(seconds)),
    );
  }

  static final _sparkle = Path()
    ..moveTo(0, -1)
    ..quadraticBezierTo(.09, -.12, .7, 0)
    ..quadraticBezierTo(.1, .11, 0, 1)
    ..quadraticBezierTo(-.1, .12, -.7, 0)
    ..quadraticBezierTo(-.11, -.1, 0, -1)
    ..close();

  void _spark(Canvas c, Offset at, double radius, Paint pen) {
    c.save();
    c.translate(at.dx, at.dy);
    c.scale(radius);
    c.drawPath(_sparkle, pen);
    c.restore();
  }

  void _paintFireworks(Canvas c, double seconds) {
    final fill = Paint();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .75
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < _bursts.length; i++) {
      final (center, color, offset) = _bursts[i];
      final phase = ((seconds / 7.5 + offset) % 1) / .78;
      if (phase >= 1) continue;
      final progress = 1 - (1 - phase) * (1 - phase);
      final opacity = math.sin(math.pi * phase) * .85;
      fill.color = color.withValues(alpha: opacity);
      for (var j = 0; j < _rays[i].length; j++) {
        final ray = _rays[i][j];
        Offset point(double t) =>
            center + ray.direction * t + Offset(0, ray.fall * t * t);
        final a = point(math.max(.04, progress - .22)),
            b = point(math.max(.07, progress - .1)),
            end = point(progress);
        final trail = Path()
          ..moveTo(a.dx, a.dy)
          ..quadraticBezierTo(b.dx, b.dy - .9, end.dx, end.dy);
        stroke.color = color.withValues(alpha: opacity * ray.alpha);
        c.drawPath(trail, stroke);
        c.drawCircle(end, ray.tipRadius, fill);
        if (j % 3 == 0) _spark(c, point(progress + .035), 1.43, fill);
      }
    }
    for (var i = 0; i < 18; i++) {
      final x = 119 + math.sin(i * 2.3) * 84 + math.sin(seconds * .7 + i) * 3;
      fill.color = const Color(0xffefd293).withValues(
        alpha: (.15 + .15 * math.sin(seconds * .9 + i)) * (.8 - i / 40),
      );
      c.drawRect(Rect.fromLTWH(x, 339 + i * 2.5, 5 + i * .7, .8), fill);
    }
  }

  @override
  bool shouldRepaint(_MotionPainter oldDelegate) =>
      christmas != oldDelegate.christmas || clock != oldDelegate.clock;
}
