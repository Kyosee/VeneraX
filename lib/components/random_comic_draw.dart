import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/translations.dart';

/// The draw stage only presents the hand; the dialog owns all draw decisions.
class RandomComicDrawStage extends StatelessWidget {
  const RandomComicDrawStage({
    super.key,
    required this.comics,
    required this.drawCount,
    required this.deal,
    required this.flips,
    required this.selectedIndex,
    required this.onCardTap,
    this.onDraw,
  });

  final List<FavoriteItem> comics;
  final int drawCount;
  final Animation<double> deal;
  final List<Animation<double>> flips;
  final int? selectedIndex;
  final ValueChanged<int> onCardTap;
  final VoidCallback? onDraw;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final gold = dark ? const Color(0xFFEAC98B) : const Color(0xFF8B632E);
    return LayoutBuilder(
      builder: (context, constraints) {
        final single = drawCount == 1;
        final cardWidth = single
            ? 176.0
            : ((constraints.maxWidth - 36) / 3).clamp(44.0, 152.0);
        final cardHeight = cardWidth * 1.46;
        final height = math.max(238.0, cardHeight + 82);
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: ColoredBox(
            color: dark ? const Color(0xFF111D31) : const Color(0xFFF0F4FA),
            child: SizedBox(
              height: height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _DrawStagePainter(gold: gold, dark: dark),
                      ),
                    ),
                  ),
                  if (comics.isEmpty)
                    _buildDeck(context, cardWidth, cardHeight)
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var index = 0; index < comics.length; index++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: _DrawCard(
                              key: ValueKey('draw-card-$index'),
                              comic: comics[index],
                              index: index,
                              width: cardWidth,
                              height: cardHeight,
                              deal: deal,
                              flip: flips[index],
                              selected: selectedIndex == index,
                              showSelection: comics.length > 1,
                              onTap: () => onCardTap(index),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDeck(BuildContext context, double width, double height) {
    return Semantics(
      button: true,
      enabled: onDraw != null,
      label: 'Tap to draw'.tl,
      onTap: onDraw,
      child: SizedBox(
        width: width + 86,
        height: height + 34,
        child: Stack(
          alignment: Alignment.center,
          children: [
            for (final direction in [-1, 1])
              ExcludeSemantics(
                child: Transform.translate(
                  offset: Offset(direction * 25, 6),
                  child: Transform.rotate(
                    angle: direction * 0.13,
                    child: Opacity(
                      opacity: 0.6,
                      child: SizedBox(
                        width: width - 8,
                        height: height - 8,
                        child: const _DrawCardBack(),
                      ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: width,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const _DrawCardBack(),
                  Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      excludeFromSemantics: true,
                      borderRadius: BorderRadius.circular(14),
                      onTap: onDraw,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawCard extends StatelessWidget {
  const _DrawCard({
    super.key,
    required this.comic,
    required this.index,
    required this.width,
    required this.height,
    required this.deal,
    required this.flip,
    required this.selected,
    required this.showSelection,
    required this.onTap,
  });

  final FavoriteItem comic;
  final int index;
  final double width;
  final double height;
  final Animation<double> deal;
  final Animation<double> flip;
  final bool selected;
  final bool showSelection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([deal, flip]),
      child: _DrawCardFront(comic: comic, selected: selected),
      builder: (context, cover) {
        final entry = Curves.easeOutCubic.transform(
          ((deal.value - index * 0.1) / 0.8).clamp(0.0, 1.0),
        );
        final turning = Curves.easeInOutCubic.transform(flip.value);
        final front = turning >= 0.5;
        final settled = flip.value == 1;
        final lift = settled && selected && showSelection ? -8.0 : 0.0;
        return Semantics(
          container: true,
          button: true,
          selected: settled && selected,
          onTap: onTap,
          label: front
              ? comic.title
              : 'Reveal card @number'.tlParams({'number': index + 1}),
          child: Transform.translate(
            offset: Offset(0, 34 * (1 - entry) + lift),
            child: Opacity(
              opacity: 0.25 + entry * 0.75,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: -24,
                      right: -24,
                      top: -24,
                      bottom: -24,
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _DrawBurstPainter(progress: flip.value),
                        ),
                      ),
                    ),
                    Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0018)
                        ..rotateZ((index - 1) * 0.08 * (1 - entry))
                        ..rotateY(turning * math.pi),
                      child: front
                          ? Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()..rotateY(math.pi),
                              child: cover,
                            )
                          : const _DrawCardBack(),
                    ),
                    if (settled && selected && showSelection)
                      const Positioned(
                        top: -9,
                        right: -6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFFEAC98B),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.check_rounded,
                              color: Color(0xFF17243A),
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        excludeFromSemantics: true,
                        borderRadius: BorderRadius.circular(14),
                        onTap: onTap,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DrawCardBack extends StatelessWidget {
  const _DrawCardBack();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF314966), Color(0xFF142239), Color(0xFF243650)],
        ),
        border: Border.all(color: const Color(0xFFDCB878), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x35111D31),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: CustomPaint(
        painter: const _CardSealPainter(),
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) => Icon(
              Icons.auto_stories_outlined,
              color: const Color(0xFFEAC98B),
              size: constraints.maxWidth * 0.28,
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawCardFront extends StatelessWidget {
  const _DrawCardFront({required this.comic, required this.selected});

  final FavoriteItem comic;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final provider = findImageProvider(comic);
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.auto_stories_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? const Color(0xFFEAC98B) : const Color(0xFF8197B5),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF111D31).withValues(alpha: 0.3),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (provider != null)
              Image(
                image: provider,
                fit: BoxFit.cover,
                frameBuilder: (_, child, frame, _) =>
                    frame == null ? placeholder : child,
                errorBuilder: (_, _, _) => placeholder,
              )
            else
              placeholder,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xEB101827)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 30, 8, 12),
                  child: Text(
                    comic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawStagePainter extends CustomPainter {
  const _DrawStagePainter({required this.gold, required this.dark});

  final Color gold;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.46);
    final radius = size.height * 0.55;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            (dark ? const Color(0xFF45658A) : Colors.white).withValues(
              alpha: 0.6,
            ),
            gold.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = gold.withValues(alpha: 0.16);
    for (final scale in [0.76, 0.88, 1.18]) {
      canvas.drawCircle(center, radius * scale, line);
    }
    for (var i = 0; i < 16; i++) {
      final angle = math.pi * 2 * i / 16;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * radius * 0.85,
        center + direction * radius * 0.91,
        line,
      );
    }
    final stars = Paint()..color = gold.withValues(alpha: 0.45);
    for (var i = 0; i < 26; i++) {
      final x = ((i * 73 + 19) % 101) / 101 * size.width;
      final y = ((i * 37 + 11) % 97) / 97 * size.height;
      canvas.drawCircle(Offset(x, y), i % 4 == 0 ? 1.5 : 0.7, stars);
    }
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height - 28),
        width: math.min(size.width * 0.74, 310),
        height: 20,
      ),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _DrawStagePainter oldDelegate) =>
      gold != oldDelegate.gold || dark != oldDelegate.dark;
}

class _CardSealPainter extends CustomPainter {
  const _CardSealPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final line = Paint()
      ..color = const Color(0xFFEAC98B).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(7),
        const Radius.circular(8),
      ),
      line,
    );
    final radius = size.width * 0.33;
    canvas.drawCircle(center, radius, line);
    canvas.drawCircle(center, radius + 5, line);
    for (var i = 0; i < 4; i++) {
      final angle = math.pi / 4 + math.pi / 2 * i;
      final point = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final corner = Offset(
        i == 0 || i == 3 ? size.width - 13 : 13,
        i < 2 ? size.height - 18 : 18,
      );
      canvas.drawLine(point, corner, line);
    }
    final filled = Paint()..color = const Color(0xFFEAC98B);
    for (final direction in [-1, 1]) {
      final point = center + Offset(0, direction * size.height * 0.34);
      final diamond = Path()
        ..moveTo(point.dx, point.dy - 6)
        ..lineTo(point.dx + 3, point.dy)
        ..lineTo(point.dx, point.dy + 6)
        ..lineTo(point.dx - 3, point.dy)
        ..close();
      canvas.drawPath(diamond, filled);
    }
  }

  @override
  bool shouldRepaint(covariant _CardSealPainter oldDelegate) => false;
}

class _DrawBurstPainter extends CustomPainter {
  const _DrawBurstPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final burst = ((progress - 0.38) / 0.62).clamp(0.0, 1.0);
    if (burst == 0 || burst == 1) return;
    final energy = Curves.easeOutCubic.transform(burst);
    final fade = 1 - burst;
    final center = size.center(Offset.zero);
    final radius = size.width * 0.25 + energy * size.width * 0.38;
    final gold = const Color(0xFFEAC98B);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            gold.withValues(alpha: fade * 0.55),
            gold.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final line = Paint()
      ..color = gold.withValues(alpha: fade * 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius, line);
    for (var i = 0; i < 16; i++) {
      final angle = math.pi * 2 * i / 16 + 0.15;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final inner = radius * (0.75 + (i % 3) * 0.06);
      canvas.drawLine(
        center + direction * inner,
        center + direction * (inner + fade * 18),
        line,
      );
      final point = center + direction * (radius + (i % 4) * 8);
      canvas.drawCircle(
        point,
        1.2 + (i % 3) * 0.6,
        Paint()..color = gold.withValues(alpha: fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DrawBurstPainter oldDelegate) =>
      progress != oldDelegate.progress;
}
