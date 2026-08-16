import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/random_comic_picker.dart';
import 'package:venera/foundation/random_comic_pool.dart';
import 'package:venera/utils/translations.dart';

Future<FavoriteItem?> showRandomComicDrawDialog(BuildContext context) {
  return showDialog<FavoriteItem>(
    context: context,
    builder: (context) => const RandomComicDrawDialog(),
  );
}

class RandomComicDrawDialog extends StatefulWidget {
  const RandomComicDrawDialog({super.key});

  @override
  State<RandomComicDrawDialog> createState() => _RandomComicDrawDialogState();
}

class _RandomComicDrawDialogState extends State<RandomComicDrawDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _revealController;
  final RandomComicPicker _picker = UniformRandomComicPicker();
  final Set<RandomComicIdentity> _drawn = {};

  List<FavoriteItem> _loadedComics = const [];
  List<FavoriteItem> _candidates = const [];
  List<String> _folders = const [];
  String? _selectedFolder;
  RandomComicReadingScope _readingScope = RandomComicReadingScope.all;
  FavoriteItem? _selectedComic;
  bool _loading = true;
  bool _preparing = false;
  int _loadGeneration = 0;

  bool get _isDrawing => _preparing || _revealController.isAnimating;

  @override
  void initState() {
    super.initState();
    _revealController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 900),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            HapticFeedback.lightImpact();
            setState(() {});
          }
        });
    _loadCardPool();
  }

  @override
  void dispose() {
    _revealController.dispose();
    super.dispose();
  }

  Future<void> _loadCardPool() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _selectedComic = null;
      _drawn.clear();
      _revealController.reset();
    });
    final manager = LocalFavoritesManager();
    final folders = manager.folderNames;
    final comics = _selectedFolder == null
        ? await manager.getAllComicsAsync()
        : await manager.getFolderComicsAsync(_selectedFolder!);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _folders = folders;
      _loadedComics = comics;
      _loading = false;
      _applyReadingScope(resetDraw: false);
    });
  }

  void _applyReadingScope({bool resetDraw = true}) {
    _candidates = _loadedComics
        .where((comic) {
          final history = HistoryManager().find(comic.id, comic.type);
          return randomComicMatchesReadingScope(_readingScope, history);
        })
        .toList(growable: false);
    if (resetDraw) {
      _selectedComic = null;
      _drawn.clear();
      _revealController.reset();
    }
  }

  Future<void> _drawComic() async {
    if (_loading || _isDrawing || _candidates.isEmpty) return;
    var comic = _picker.pick(_candidates, excluded: _drawn);
    if (comic == null) {
      _drawn.clear();
      if (mounted) {
        context.showMessage(message: 'A new draw round has started'.tl);
      }
      comic = _picker.pick(_candidates);
    }
    if (comic == null) return;

    final firstDraw = _selectedComic == null;
    setState(() {
      _preparing = true;
      _selectedComic = null;
      _revealController.reset();
    });

    final provider = findImageProvider(comic);
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 180)),
      if (provider != null)
        precacheImage(
          provider,
          context,
        ).timeout(const Duration(seconds: 2)).catchError((_) {}),
    ]);
    if (!mounted) return;

    _drawn.add(randomComicIdentity(comic));
    _revealController.duration = Duration(milliseconds: firstDraw ? 900 : 550);
    setState(() {
      _selectedComic = comic;
      _preparing = false;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _revealController.value = 1;
    } else {
      _revealController.forward();
    }
  }

  void _skipAnimation() {
    if (_revealController.isAnimating) {
      _revealController.value = 1;
    }
  }

  void _onCardTap() {
    if (_selectedComic == null) {
      _drawComic();
    } else {
      _skipAnimation();
    }
  }

  String _readingScopeLabel(RandomComicReadingScope scope) => switch (scope) {
    RandomComicReadingScope.all => 'All'.tl,
    RandomComicReadingScope.notStarted => 'Not started'.tl,
    RandomComicReadingScope.inProgress => 'In progress'.tl,
    RandomComicReadingScope.completed => 'Completed'.tl,
  };

  String _readingStatus(FavoriteItem comic) {
    final history = HistoryManager().find(comic.id, comic.type);
    if (history == null) return 'Not started'.tl;
    if (randomComicMatchesReadingScope(
      RandomComicReadingScope.completed,
      history,
    )) {
      return 'Completed'.tl;
    }
    if (history.maxPage != null && history.maxPage! > 0) {
      return 'Page @page of @total'.tlParams({
        'page': history.page,
        'total': history.maxPage!,
      });
    }
    return 'In progress'.tl;
  }

  @override
  Widget build(BuildContext context) {
    final revealed =
        _selectedComic != null && !_preparing && _revealController.value == 1;
    return ContentDialog(
      title: 'Draw a comic'.tl,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildPoolControls(),
            const SizedBox(height: 14),
            _buildChanceDescription(),
            const SizedBox(height: 12),
            GestureDetector(onTap: _onCardTap, child: _buildAnimatedCard()),
            const SizedBox(height: 12),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: revealed
                  ? _buildResultDetails(_selectedComic!)
                  : _buildDrawHint(),
            ),
            const SizedBox(height: 16),
            _buildActions(revealed),
          ],
        ),
      ),
      actions: const [],
    );
  }

  Widget _buildPoolControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                initialValue: _selectedFolder,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Card pool'.tl,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                hint: Text('All favorites'.tl),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All favorites'.tl),
                  ),
                  ..._folders.map(
                    (folder) => DropdownMenuItem<String?>(
                      value: folder,
                      child: Text(folder, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: _loading || _isDrawing
                    ? null
                    : (folder) {
                        if (folder == _selectedFolder) return;
                        _selectedFolder = folder;
                        _loadCardPool();
                      },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<RandomComicReadingScope>(
                initialValue: _readingScope,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Reading progress'.tl,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                items: RandomComicReadingScope.values
                    .map(
                      (scope) => DropdownMenuItem(
                        value: scope,
                        child: Text(
                          _readingScopeLabel(scope),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _loading || _isDrawing
                    ? null
                    : (scope) {
                        if (scope == null || scope == _readingScope) return;
                        setState(() {
                          _readingScope = scope;
                          _applyReadingScope();
                        });
                      },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChanceDescription() {
    if (_loading) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.balance_outlined,
          size: 16,
          color: context.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '@count comics · Equal chance · No repeats this round'.tlParams({
              'count': _candidates.length,
            }),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.colorScheme.outline, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedCard() {
    const width = 184.0;
    const height = 258.0;
    return AnimatedBuilder(
      animation: _revealController,
      builder: (context, child) {
        final value = _revealController.value;
        final flip = Curves.easeInOutCubic.transform(
          ((value - 0.28) / 0.72).clamp(0.0, 1.0),
        );
        final angle = flip * math.pi;
        final showFront = angle > math.pi / 2 && _selectedComic != null;
        final pulse = value < 0.28
            ? 1 + math.sin(value * math.pi * 8) * 0.018
            : 1.0;
        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0014)
          ..scaleByDouble(pulse, pulse, 1, 1)
          ..rotateY(angle);
        return SizedBox(
          width: width + 44,
          height: height + 44,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RevealEffectsPainter(
                      progress: value,
                      primary: context.colorScheme.primary,
                      secondary: context.colorScheme.tertiary,
                    ),
                  ),
                ),
              ),
              Transform(
                alignment: Alignment.center,
                transform: transform,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: showFront
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()..rotateY(math.pi),
                          child: _buildCardFront(_selectedComic!),
                        )
                      : _buildCardBack(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCardBack() {
    return Semantics(
      label: (_selectedComic == null ? 'Tap to draw' : 'Comic card back').tl,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.colorScheme.primaryContainer,
              context.colorScheme.tertiaryContainer,
            ],
          ),
          border: Border.all(
            color: context.colorScheme.primary.withValues(alpha: 0.65),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: context.colorScheme.primary.withValues(alpha: 0.25),
              blurRadius: 24,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 18,
              left: 18,
              child: Icon(
                Icons.auto_awesome,
                color: context.colorScheme.onPrimaryContainer.withValues(
                  alpha: 0.5,
                ),
              ),
            ),
            Positioned(
              right: 18,
              bottom: 18,
              child: Icon(
                Icons.auto_awesome,
                color: context.colorScheme.onTertiaryContainer.withValues(
                  alpha: 0.5,
                ),
              ),
            ),
            Container(
              width: 116,
              height: 172,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(58),
                border: Border.all(
                  color: context.colorScheme.onPrimaryContainer.withValues(
                    alpha: 0.32,
                  ),
                  width: 2,
                ),
              ),
              child: Icon(
                _preparing ? Icons.hourglass_top_rounded : Icons.style_rounded,
                size: 58,
                color: context.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardFront(FavoriteItem comic) {
    final provider = findImageProvider(comic);
    return Semantics(
      label: comic.title,
      image: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: context.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: context.colorScheme.primary.withValues(alpha: 0.7),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: context.colorScheme.primary.withValues(alpha: 0.28),
              blurRadius: 26,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (provider != null)
              Image(
                image: provider,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _buildMissingCover(),
              )
            else
              _buildMissingCover(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 28, 12, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Text(
                  comic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingCover() {
    return ColoredBox(
      color: context.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.menu_book_rounded,
        size: 64,
        color: context.colorScheme.outline,
      ),
    );
  }

  Widget _buildDrawHint() {
    final text = _loading
        ? 'Loading card pool...'.tl
        : _candidates.isEmpty
        ? 'No favorite comics in this card pool'.tl
        : _preparing
        ? 'Preparing your draw...'.tl
        : _revealController.isAnimating
        ? 'Tap the card to skip'.tl
        : 'Ready to draw'.tl;
    return SizedBox(
      height: 54,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colorScheme.outline),
        ),
      ),
    );
  }

  Widget _buildResultDetails(FavoriteItem comic) {
    final author = comic.authors.isNotEmpty
        ? comic.authors.join(', ')
        : comic.author;
    return Column(
      children: [
        Text(
          comic.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text(
          [
            if (author.trim().isNotEmpty) author,
            _readingStatus(comic),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colorScheme.outline, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildActions(bool revealed) {
    if (revealed) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _isDrawing ? null : _drawComic,
            icon: const Icon(Icons.casino_outlined),
            label: Text('Draw again'.tl),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_selectedComic),
            icon: const Icon(Icons.menu_book_rounded),
            label: Text('Read this one'.tl),
          ),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: _loading || _isDrawing || _candidates.isEmpty
          ? null
          : _drawComic,
      icon: const Icon(Icons.style_rounded),
      label: Text(_isDrawing ? 'Drawing...'.tl : 'Draw'.tl),
    );
  }
}

class _RevealEffectsPainter extends CustomPainter {
  const _RevealEffectsPainter({
    required this.progress,
    required this.primary,
    required this.secondary,
  });

  final double progress;
  final Color primary;
  final Color secondary;

  static const _sparkles = <(double, double, double, double)>[
    (0.12, 0.20, 0.0, 0.9),
    (0.82, 0.18, 1.6, 0.75),
    (0.08, 0.64, 2.7, 0.65),
    (0.88, 0.72, 4.2, 0.95),
    (0.25, 0.88, 5.1, 0.7),
    (0.72, 0.91, 3.5, 0.8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final energy = Curves.easeOutCubic.transform(
      (progress / 0.78).clamp(0.0, 1.0),
    );
    final fade = progress < 0.68
        ? 1.0
        : (1.0 - ((progress - 0.68) / 0.32)).clamp(0.0, 1.0);
    if (energy <= 0 || fade <= 0) return;

    final glow = Paint()
      ..color = primary.withValues(alpha: 0.22 * fade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawCircle(center, 86 + 32 * energy, glow);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = secondary.withValues(alpha: 0.7 * fade);
    for (var i = 0; i < 2; i++) {
      canvas.drawCircle(center, 58 + i * 24 + energy * 74, ringPaint);
    }

    final rayPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2
      ..color = primary.withValues(alpha: 0.66 * fade);
    for (var i = 0; i < 18; i++) {
      final angle = math.pi * 2 * i / 18 + progress * math.pi * 1.6;
      final inner = 92 + energy * 12;
      final wave = (math.sin(progress * math.pi * 2 + i) + 1) / 2;
      final outer = inner + 8 + 25 * wave + 34 * energy;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        rayPaint,
      );
    }

    for (final sparkle in _sparkles) {
      final pulse = math.sin(progress * math.pi * 2 + sparkle.$3).abs();
      final scale = (0.35 + 0.65 * pulse) * sparkle.$4;
      final paint = Paint()
        ..color = (sparkle.$3 % 2 < 1 ? primary : secondary).withValues(
          alpha: 0.9 * fade * scale,
        );
      _drawSparkle(
        canvas,
        Offset(size.width * sparkle.$1, size.height * sparkle.$2),
        5 + 8 * energy * scale,
        paint,
      );
    }
  }

  void _drawSparkle(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius * 0.28, center.dy - radius * 0.28)
      ..lineTo(center.dx + radius, center.dy)
      ..lineTo(center.dx + radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx, center.dy + radius)
      ..lineTo(center.dx - radius * 0.28, center.dy + radius * 0.28)
      ..lineTo(center.dx - radius, center.dy)
      ..lineTo(center.dx - radius * 0.28, center.dy - radius * 0.28)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RevealEffectsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary;
}
