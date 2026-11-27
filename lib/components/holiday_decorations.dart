import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Coordinates use the local space of the toolbar's Stack.
class HolidayToolbarTrim extends StatelessWidget {
  const HolidayToolbarTrim({
    super.key,
    required this.christmas,
    required this.searchBounds,
    required this.settingsBounds,
    required this.protectedAreas,
  });

  final bool christmas;
  final Rect searchBounds;
  final Rect settingsBounds;
  final List<Rect> protectedAreas;

  @override
  Widget build(BuildContext context) {
    if (searchBounds.isEmpty) return const SizedBox.shrink();
    final layout = _ToolbarGeometry(
      searchBounds,
      settingsBounds,
      protectedAreas,
    );
    final night = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: _HolidayMotion(
          key: ValueKey(christmas),
          duration: christmas ? null : const Duration(milliseconds: 4100),
          builder: (context, clock, reduced) => Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: _ToolbarPainter(layout, christmas, night),
                ),
              ),
              if (!reduced)
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _ToolbarPainter(layout, christmas, night, clock),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class HolidayEntryIcon extends StatelessWidget {
  const HolidayEntryIcon({super.key, required this.christmas});

  final bool christmas;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: 7 * math.pi / 180,
      child: Image.asset(
        christmas
            ? 'assets/holidays/home_gift.png'
            : 'assets/holidays/home_newyear_stamp.png',
        width: 31,
        height: 33,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

class HolidaySnowbank extends StatelessWidget {
  const HolidaySnowbank({super.key});

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final night = Theme.of(context).brightness == Brightness.dark;
    final image = night
        ? 'assets/holidays/home_snow_dark.png'
        : 'assets/holidays/home_snow_light.png';
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final reach = math.min(1.55, constraints.maxWidth * .30 / 116);
              // Both asymmetric drifts share one texture with a transparent middle.
              final banks = Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final side in [
                    Alignment.centerLeft,
                    Alignment.centerRight,
                  ])
                    SizedBox(
                      width: 116 * reach,
                      height: height,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: ClipRect(
                          child: Align(
                            alignment: side,
                            widthFactor: .5,
                            child: Image.asset(
                              image,
                              width: 348,
                              height: height,
                              filterQuality: FilterQuality.medium,
                              excludeFromSemantics: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
              return _HolidayMotion(
                builder: (context, clock, reduced) => ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (reduced)
                        banks
                      else ...[
                        ValueListenableBuilder<double>(
                          valueListenable: clock,
                          child: RepaintBoundary(child: banks),
                          builder: (context, elapsed, child) =>
                              Transform.translate(
                                offset: Offset(0, _bankOffset(elapsed)),
                                child: child,
                              ),
                        ),
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: _SettlingSnow(clock, reach, night),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

double _bankOffset(double ms) => 5 * (1 - (ms / 14000).clamp(0.0, 1.0));

class _SettlingSnow extends CustomPainter {
  _SettlingSnow(this.clock, this.reach, this.night) : super(repaint: clock);

  final ValueListenable<double> clock;
  final double reach;
  final bool night;

  @override
  void paint(Canvas canvas, Size size) {
    final ms = clock.value;
    final offset = _bankOffset(ms);
    final paint = Paint();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 8, size.width, size.height));
    for (final (dx, surface, delay, direction) in [
      (30, 7, 210, 1),
      (61, 18, 1410, 1),
      (46, 12, 810, -1),
      (74, 27, 2280, -1),
    ]) {
      final phase = ((ms + delay) % 3700) / 2050;
      if (phase > 1) continue;
      final alpha = math.min(1.0, math.min(phase * 5, (1 - phase) * 8));
      final x =
          (direction == 1 ? 0.0 : size.width) +
          direction * dx * reach +
          math.sin(phase * math.pi) * 2;
      final y = surface + offset - (1 - phase) * (1 - phase) * 17;
      paint.color = (night ? const Color(0xffa5c2cf) : const Color(0xff86a9bf))
          .withValues(alpha: alpha);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(x + .25, y + .4),
          width: 2.2,
          height: 1.8,
        ),
        paint,
      );
      paint.color = (night ? const Color(0xffe1f1fb) : const Color(0xfff9fdff))
          .withValues(alpha: alpha);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: 2, height: 1.64),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SettlingSnow old) =>
      old.reach != reach || old.night != night || old.clock != clock;
}

/// Counts visible animation time only, so returning to the app never fast-forwards.
class _HolidayMotion extends StatefulWidget {
  const _HolidayMotion({super.key, this.duration, required this.builder});

  final Duration? duration;
  final Widget Function(BuildContext, ValueListenable<double>, bool) builder;

  @override
  State<_HolidayMotion> createState() => _HolidayMotionState();
}

class _HolidayMotionState extends State<_HolidayMotion>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _clock = ValueNotifier(0.0);
  late final Ticker _ticker;
  double _start = 0;
  bool _enabled = false;
  bool _visible = true;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    _visible = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final limit = widget.duration;
    if (!_enabled ||
        !_visible ||
        _reduced ||
        (limit != null && _clock.value >= limit.inMilliseconds)) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _start = _clock.value;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final ms = _start + elapsed.inMicroseconds / 1000;
    final limit = widget.duration;
    if (limit != null && ms >= limit.inMilliseconds) {
      _clock.value = limit.inMilliseconds.toDouble();
      _ticker.stop();
    } else if (ms - _clock.value >= 32) {
      _clock.value = ms;
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _clock, _reduced);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }
}

class _ToolbarGeometry {
  _ToolbarGeometry(this.search, this.settings, this.protectedAreas);

  final Rect search;
  final Rect settings;
  final List<Rect> protectedAreas;

  // The open interval between the search content and card entry holds the ornaments.
  (double, double) get clearSpan {
    var start = search.left + 6;
    var end = search.right - 6;
    for (final r in protectedAreas) {
      if (!r.overlaps(search)) continue;
      if (r.center.dx >= search.right - 50) {
        end = math.min(end, r.left - 6);
      } else {
        start = math.max(start, r.right + 8);
      }
    }
    return (math.min(start, end), end);
  }

  void clip(Canvas c) {
    final (start, end) = clearSpan;
    final top = search.top - 8;
    final band = Path();
    var labelTop = search.center.dy - 14;
    var entryTop = labelTop;
    var editTop = settings.center.dy - 14;
    for (final r in protectedAreas) {
      if (r.overlaps(search)) {
        if (r.center.dx >= search.right - 50) {
          entryTop = math.min(entryTop, r.top - 1);
        } else {
          labelTop = math.min(labelTop, r.top - 1);
        }
      }
      if (r.overlaps(settings)) editTop = math.min(editTop, r.top - 1);
    }
    void add(double left, double right, double y, double bottom) {
      if (right > left && bottom > y) {
        band.addRect(Rect.fromLTRB(left, y, right, bottom));
      }
    }

    add(search.left, start, top, labelTop);
    add(start, end, top, search.bottom);
    add(end, search.right, top, entryTop);
    add(settings.left, settings.right, settings.top - 8, editTop);
    c.clipPath(band, doAntiAlias: false);
    for (final r in protectedAreas) {
      c.clipRect(r, clipOp: ClipOp.difference, doAntiAlias: false);
    }
  }
}

class _TrimInk {
  const _TrimInk(this.night);
  final bool night;
  Color get pine => Color(night ? 0xff6f9c83 : 0xff28584d);
  Color get leaf => Color(night ? 0xff91b59a : 0xff467c66);
  Color get tips => Color(night ? 0xffb3c6a2 : 0xff88a286);
  Color get wood => Color(night ? 0xffb89471 : 0xff865537);
  Color get red => Color(night ? 0xffe46e61 : 0xffa93735);
  Color get berry => Color(night ? 0xfffd9a80 : 0xffd45444);
  Color get gold => Color(night ? 0xffefb866 : 0xffaf752e);
  Color get glow => Color(night ? 0xfff6d491 : 0xfff7cd77);
  Color get pearl => Color(night ? 0xfffff1c9 : 0xfff7e6bd);
  Color get snow => Color(night ? 0xffc2e3ee : 0xff56889d);
  Color get coral => Color(night ? 0xfff08472 : 0xffb74b44);
  Color get teal => Color(night ? 0xff76c7be : 0xff247f86);
}

class _ToolbarPainter extends CustomPainter {
  _ToolbarPainter(this.layout, this.christmas, this.night, [this.clock])
    : super(repaint: clock);

  final _ToolbarGeometry layout;
  final bool christmas;
  final bool night;
  final ValueListenable<double>? clock;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = clock?.value;
    if (!christmas && elapsed != null && elapsed >= 4100) return;
    final brush = _HolidayBrush(canvas, _TrimInk(night));
    canvas.save();
    layout.clip(canvas);
    if (elapsed == null) {
      if (christmas) {
        brush.garland(layout);
      } else {
        brush.newYear(layout);
      }
    } else if (christmas) {
      brush.snow(layout.search, elapsed);
    } else {
      brush.fireworks(layout, elapsed);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToolbarPainter old) =>
      old.christmas != christmas ||
      old.night != night ||
      old.clock != clock ||
      old.layout.search != layout.search ||
      old.layout.settings != layout.settings ||
      !listEquals(old.layout.protectedAreas, layout.protectedAreas);
}

class _HolidayBrush {
  _HolidayBrush(this.c, this.p);
  final Canvas c;
  final _TrimInk p;
  final fill = Paint();
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void dot(double x, double y, double r, Color color) =>
      c.drawCircle(Offset(x, y), r, fill..color = color);

  void line(
    double x,
    double y,
    double u,
    double v,
    Color color,
    double width,
  ) => c.drawLine(
    Offset(x, y),
    Offset(u, v),
    stroke
      ..color = color
      ..strokeWidth = width,
  );

  void curve(
    double x,
    double y,
    double cx,
    double cy,
    double u,
    double v,
    Color color,
    double width,
  ) {
    final path = Path()
      ..moveTo(x, y)
      ..quadraticBezierTo(cx, cy, u, v);
    c.drawPath(
      path,
      stroke
        ..color = color
        ..strokeWidth = width,
    );
  }

  void pine(double x, double y, double scale, [double flip = 1]) {
    c.save();
    c.translate(x, y);
    c.scale(scale * flip, scale);
    curve(-3, 3, 22, 0, 43, -4, p.wood, 1.05);
    for (final (dx, dy, angle, length) in [
      (0.0, 2.0, -.28, 22.0),
      (4.0, 2.0, .27, 23.0),
      (14.0, 1.0, -.22, 24.0),
      (19.0, 0.0, .29, 19.0),
      (25.0, -1.0, -.34, 16.0),
    ]) {
      c.save();
      c.translate(dx, dy);
      c.rotate(angle);
      curve(0, 0, length * .55, -1, length, -2, p.pine, .95);
      for (var i = 1; i <= 9; i++) {
        final stem = length * i / 11,
            needle = length * (.27 - i * .014),
            dy = -2 * i / 11;
        final color = [p.pine, p.leaf, p.tips][i % 3];
        curve(
          stem,
          dy,
          stem + needle * .65,
          dy - 2.3,
          stem + needle,
          dy - 5.3 + i * .17,
          color,
          .78,
        );
        curve(
          stem - .4,
          dy,
          stem + needle * .45,
          dy + 1.6,
          stem + needle * .92,
          dy + 4.8 - i * .18,
          color,
          .8,
        );
      }
      c.restore();
    }
    for (final (u, v) in [(8.0, 2.5), (12.0, 3.0), (9.5, 6.0)]) {
      dot(u, v, 2.15, p.red);
      dot(u - .5, v - .7, .64, p.berry);
    }
    c.restore();
  }

  void ornament(double x, double top, double y, double r, Color body) {
    line(x, top, x, y - r - 2, p.gold, .65);
    dot(x, y, r, body);
    c.drawRect(
      Rect.fromLTWH(x - 1.8, y - r - 1.8, 3.6, 2.3),
      fill..color = p.gold,
    );
    curve(
      x - r * .83,
      y,
      x,
      y + r * .53,
      x + r * .85,
      y - r * .11,
      p.pearl,
      .85,
    );
    curve(
      x - r * .43,
      y - r * .47,
      x - r * .52,
      y - r * .28,
      x - r * .56,
      y - r * .1,
      p.pearl,
      1.05,
    );
    dot(x + r * .49, y + r * .54, .6, p.glow);
  }

  void garland(_ToolbarGeometry g) {
    final pill = g.search, tune = g.settings;
    final y = pill.top + 2, start = pill.left + 24, end = pill.right - 23;
    final spans = math.max(1, ((end - start) / 184).round()),
        span = (end - start) / spans;
    curve(pill.left + 5, y + 12, pill.left + 11, y + 2, start, y, p.gold, 1.1);
    curve(end, y, end + 11, y, end + 18, y + 11, p.gold, 1.05);
    for (var i = 0; i < spans; i++) {
      final x = start + i * span;
      curve(x, y, x + span / 2, y + 12, x + span, y, p.gold, .82);
      for (final t in [.24, .51, .78]) {
        final bx = x + t * span, by = y + 24 * t * (1 - t);
        line(bx, by, bx + .3, by + 1.8, p.gold, .7);
        dot(bx + .3, by + 2.5, 1.7, p.gold);
        dot(bx, by + 2.5, 1.04, p.pearl);
      }
      if (i > 0) pine(x + 5, y - .6, .63, -1);
    }
    pine(start - 9, y + 3, 1.02);
    pine(end + 8, y + 3, .89, -1);
    final (left, right) = g.clearSpan;
    if (right - left >= 22) {
      final middle = (left + right) / 2;
      ornament(middle - 10, y + 5, y + 18, 3.9, p.gold);
      ornament(middle + 3, y + 5.8, y + 25, 5.4, p.red);
    }
    if (tune.isEmpty) return;
    final cx = tune.center.dx, ty = tune.top + 1;
    curve(tune.left + 4, ty + 15, cx - 8, ty - 3, cx + 3, ty + 1, p.gold, 1);
    curve(cx + 3, ty + 1, cx + 15, ty + 2, tune.right - 4, ty + 12, p.gold, 1);
    pine(cx - 13, ty + 5.5, .63);
    dot(cx + 14, ty + 5.5, 1.65, p.gold);
    dot(cx + 14, ty + 5.2, .8, p.pearl);
  }

  void star(double x, double y, double r, Color color) {
    line(x, y - r, x, y + r, color, .85);
    line(x - r * .65, y, x + r * .65, y, color, .75);
  }

  void burst(
    double x,
    double y,
    double radius,
    Color primary,
    Color accent,
    double phase,
    int rays,
  ) {
    for (var i = 0; i < rays; i++) {
      final angle = phase + i * 2 * math.pi / rays,
          shape = math.sin(i * 7.7 + 2);
      final span = radius * (.76 + .24 * shape * shape),
          dx = math.cos(angle) * span,
          dy = math.sin(angle) * span;
      final bend = span * (.16 + .09 * math.sin(angle)),
          start = i % 3 == 0 ? .26 : .15;
      final color = i % 4 == 1 ? accent : primary;
      curve(
        x + dx * start,
        y + dy * start,
        x + dx * .74,
        y + dy * .54 - bend,
        x + dx,
        y + dy + bend * .6,
        color,
        i % 4 == 0 ? 1.15 : .88,
      );
      if (i.isEven) dot(x + dx * 1.1, y + dy * 1.06 + bend, .86, color);
    }
    dot(x, y, 1.45, accent);
  }

  void newYear(_ToolbarGeometry g) {
    final pill = g.search, tune = g.settings;
    final top = pill.top + 5, end = pill.right - 19, first = pill.left + 25;
    curve(
      first - 14,
      top + 8,
      first - 4,
      top - 4,
      first + 31,
      top - 4,
      p.gold,
      .78,
    );
    burst(first + 19, top - .5, 8.8, p.gold, p.teal, .4, 9);
    final stars = math.max(2, ((end - first) / 139).round());
    for (var i = 0; i < stars; i++) {
      final x = first + (end - first) * (i + .53) / stars;
      star(x, top - 1 + i % 2 * 3, 2.4, p.gold);
      dot(x + 6, top + 1, .85, p.teal);
    }
    final (left, right) = g.clearSpan;
    final groups = math.max(1, ((right - left) / 238).round()),
        span = (right - left) / groups;
    if (span > 0) {
      for (var i = 0; i < groups; i++) {
        final x = left + span * (i + .37), y = top + 8;
        burst(x, y, 16.9, p.coral, p.gold, .08 + i, 14);
        curve(x - 5, y + 21, x + 1, y + 15, x, y + 9, p.gold, .82);
        final echo = left + span * (i + .84);
        burst(echo, top + 1, 10.3, p.teal, p.gold, .42, 10);
        star(echo - 7, top + 23, 2.1, p.gold);
      }
    }
    curve(end - 23, top + 2, end + 2, top - 9, end + 13, top + 8, p.gold, .79);
    if (tune.isEmpty) return;
    final cx = tune.center.dx, ty = tune.top + 5.7;
    curve(cx - 19, ty + 4, cx - 6, ty - 9, cx + 4, ty - 3, p.gold, .9);
    burst(cx + 3, ty + 1, 10.5, p.gold, p.coral, .28, 11);
    star(cx + 16, ty + 4, 2.15, p.teal);
  }

  void snow(Rect pill, double ms) {
    final count = math.max(18, (pill.width / 13).ceil()),
        strength = math.min(1.0, ms / 220);
    for (var i = 0; i < count; i++) {
      final depth = (i * 17 % 23) / 23;
      final x =
          pill.left +
          (i * 131 + 24) % pill.width +
          math.sin(ms / 710 + i) * (2 + 3 * depth);
      final y =
          pill.top -
          8 +
          (i * 29 + ms * (.017 + depth * .021)) % (pill.height + 16) -
          3;
      final color = p.snow.withValues(alpha: strength * (.44 + depth * .52));
      if (i % 5 != 0) {
        dot(x, y, (1 + depth * 1.2) * .54, color);
      } else {
        final radius = 3 + depth * 1.7, angle = i * .54 + ms / 4500;
        c.save();
        c.translate(x, y);
        c.rotate(angle);
        for (var arm = 0; arm < 6; arm++) {
          line(0, 0, 0, -radius, color, radius > 4 ? .92 : .77);
          final fork = Path()
            ..moveTo(-radius * .24, -radius * .73)
            ..lineTo(0, -radius * .49)
            ..lineTo(radius * .24, -radius * .73);
          c.drawPath(fork, stroke);
          c.rotate(math.pi / 3);
        }
        c.restore();
      }
    }
  }

  void fireworks(_ToolbarGeometry g, double ms) {
    final (left, right) = g.clearSpan;
    if (right <= left) return;
    final span = right - left;
    for (final (delay, fraction, dy, radius, primary, accent) in [
      (0, .37, 12.0, 20.0, p.coral, p.gold),
      (580, .84, 9.0, 17.0, p.teal, p.gold),
      (1430, .58, 18.0, 17.0, p.gold, p.coral),
      (2430, .21, 13.0, 20.0, p.coral, p.teal),
    ]) {
      final life = (ms - delay) / 1440;
      if (life < 0 || life >= 1) continue;
      final x = left + span * fraction, y = g.search.top + dy;
      if (life < .23) {
        final rise = 1 - life / .23,
            tx = x - 5 * rise * rise,
            ty = y + rise * 22;
        curve(tx - 2, ty + 5, tx - .4, ty + 3, tx, ty, primary, 1.1);
        dot(tx, ty, 1.3, accent);
      } else {
        final t = (life - .23) / .77,
            spread = .08 + 1.08 * (1 - (1 - t) * (1 - t));
        final opacity = math.min(1.0, (1 - t) * 2);
        burst(
          x,
          y + 3 * t * t,
          radius * spread,
          primary.withValues(alpha: opacity),
          accent.withValues(alpha: opacity),
          x / 17,
          15,
        );
      }
    }
  }
}
