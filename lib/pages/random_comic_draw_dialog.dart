import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/random_comic_draw.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/random_comic_picker.dart';
import 'package:venera/foundation/random_comic_scope.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/utils/translations.dart';

const _selectionFolderKey = 'random_comic_selection_folder';
const _readingScopeKey = 'random_comic_reading_scope';
const _drawCountKey = 'random_comic_draw_count';
const _quickRevealKey = 'random_comic_quick_reveal';

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
    with TickerProviderStateMixin {
  late final AnimationController _dealController;
  late final List<AnimationController> _flips;
  final RandomComicPicker _picker = UniformRandomComicPicker();
  final Set<RandomComicIdentity> _drawn = {};

  List<FavoriteItem> _loadedComics = const [];
  List<FavoriteItem> _candidates = const [];
  List<FavoriteItem> _hand = const [];
  List<String> _folders = const [];
  String? _selectedFolder;
  RandomComicReadingScope _readingScope = RandomComicReadingScope.all;
  int _drawCount = 1;
  int? _selectedIndex;
  int _round = 1;
  int _loadGeneration = 0;
  int _handGeneration = 0;
  bool _loading = true;
  bool _loadError = false;
  bool _dealing = false;
  bool _showScope = false;
  bool _quickReveal = false;
  bool _reducedMotion = false;
  bool _savingReadLater = false;

  bool get _instant => _quickReveal || _reducedMotion;
  bool get _busy =>
      _dealing || _savingReadLater || _flips.any((flip) => flip.isAnimating);
  int get _remaining => math.max(0, _candidates.length - _drawn.length);
  int get _revealedCount =>
      _flips.take(_hand.length).where((flip) => flip.isCompleted).length;
  bool get _allRevealed => _hand.isNotEmpty && _revealedCount == _hand.length;
  FavoriteItem? get _selectedComic {
    final index = _selectedIndex;
    return index != null && index < _hand.length && _flips[index].isCompleted
        ? _hand[index]
        : null;
  }

  @override
  void initState() {
    super.initState();
    final folder = appdata.implicitData[_selectionFolderKey];
    _selectedFolder = folder is String && folder.isNotEmpty ? folder : null;
    _readingScope = randomComicReadingScopeFromName(
      appdata.implicitData[_readingScopeKey],
    );
    _drawCount = appdata.implicitData[_drawCountKey] == 3 ? 3 : 1;
    _quickReveal = appdata.implicitData[_quickRevealKey] == true;
    _dealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _flips = List.generate(3, (_) {
      return AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 640),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          if (!_instant && !_flips.any((flip) => flip.isAnimating)) {
            HapticFeedback.lightImpact();
          }
          setState(() {});
        }
      });
    });
    _loadSelectionScope();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion && !_reducedMotion && _hand.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reducedMotion) _revealAll(immediate: true);
      });
    }
    _reducedMotion = reducedMotion;
  }

  @override
  void dispose() {
    _dealController.dispose();
    for (final flip in _flips) {
      flip.dispose();
    }
    super.dispose();
  }

  void _resetHand({bool resetRound = false}) {
    _handGeneration++;
    _dealController.reset();
    for (final flip in _flips) {
      flip.reset();
    }
    _hand = const [];
    _selectedIndex = null;
    _dealing = false;
    if (resetRound) {
      _drawn.clear();
      _round = 1;
    }
  }

  Future<void> _loadSelectionScope() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = false;
      _resetHand(resetRound: true);
    });
    try {
      final manager = LocalFavoritesManager();
      _folders = manager.folderNames;
      final available = randomComicAvailableFolder(_selectedFolder, _folders);
      if (available != _selectedFolder) {
        _selectedFolder = available;
        _persistSelection();
      }
      final comics = _selectedFolder == null
          ? await manager.getAllComicsAsync()
          : await manager.getFolderComicsAsync(_selectedFolder!);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadedComics = comics;
        _loading = false;
        _applyReadingScope();
      });
    } catch (error, stack) {
      Log.error('Random comic draw', error, stack);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = true;
        _loadedComics = const [];
        _candidates = const [];
      });
    }
  }

  void _persistSelection() {
    appdata.implicitData[_selectionFolderKey] = _selectedFolder;
    appdata.implicitData[_readingScopeKey] = _readingScope.name;
    appdata.implicitData[_drawCountKey] = _drawCount;
    appdata.implicitData[_quickRevealKey] = _quickReveal;
    unawaited(
      appdata.writeImplicitData().catchError((Object error, StackTrace stack) {
        Log.error('Random comic draw preferences', error, stack);
      }),
    );
  }

  void _applyReadingScope() {
    _candidates = _loadedComics
        .where((comic) {
          return _readingScope == RandomComicReadingScope.all ||
              randomComicMatchesReadingScope(
                _readingScope,
                HistoryManager().find(comic.id, comic.type),
              );
        })
        .toList(growable: false);
    _resetHand(resetRound: true);
  }

  Future<void> _drawComics() async {
    if (_loading || _busy || _candidates.isEmpty) return;
    if (_hand.isNotEmpty && !_allRevealed) return;
    var next = _picker.pickMany(
      _candidates,
      count: _drawCount,
      excluded: _drawn,
    );
    if (next.isEmpty) {
      _drawn.clear();
      _round++;
      next = _picker.pickMany(_candidates, count: _drawCount);
    }
    if (next.isEmpty) return;
    setState(() {
      _resetHand();
      _hand = next;
      _drawn.addAll(next.map(randomComicIdentity));
      _selectedIndex = next.length == 1 ? 0 : null;
      _dealing = true;
    });
    // Covers warm up independently so a slow source never delays the draw.
    for (final comic in next) {
      final provider = findImageProvider(comic);
      if (provider == null) continue;
      unawaited(
        precacheImage(
          provider,
          context,
          onError: (_, _) {},
        ).timeout(const Duration(seconds: 2)).catchError((_) {}),
      );
    }
    if (_instant) {
      _revealAll(immediate: true);
      return;
    }
    HapticFeedback.selectionClick();
    final generation = _handGeneration;
    try {
      await _dealController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _handGeneration) return;
    setState(() => _dealing = false);
    if (_hand.length == 1) _revealCard(0);
  }

  void _revealCard(int index) {
    if (index >= _hand.length || _savingReadLater) return;
    if (_dealing) {
      _revealAll(immediate: true);
      return;
    }
    setState(() => _selectedIndex = index);
    final flip = _flips[index];
    if (_instant || flip.isAnimating) {
      flip.value = 1;
    } else if (!flip.isCompleted) {
      HapticFeedback.selectionClick();
      flip.forward();
    }
  }

  void _revealAll({bool immediate = false}) {
    if (_hand.isEmpty) return;
    _handGeneration++;
    _dealController.value = 1;
    setState(() {
      _dealing = false;
      _selectedIndex ??= 0;
    });
    for (final flip in _flips.take(_hand.length)) {
      if (immediate || _instant) {
        flip.value = 1;
      } else if (!flip.isCompleted && !flip.isAnimating) {
        flip.forward();
      }
    }
  }

  void _changeMode(int count) {
    if (_loading || _busy || count == _drawCount) return;
    setState(() {
      _drawCount = count;
      _resetHand();
    });
    _persistSelection();
  }

  void _toggleQuickReveal() {
    setState(() => _quickReveal = !_quickReveal);
    if (_quickReveal && _hand.isNotEmpty) _revealAll(immediate: true);
    _persistSelection();
  }

  void _resetFilters() {
    _selectedFolder = null;
    _readingScope = RandomComicReadingScope.all;
    _showScope = false;
    _persistSelection();
    _loadSelectionScope();
  }

  Future<void> _toggleReadLater() async {
    final comic = _selectedComic;
    if (comic == null || _savingReadLater) return;
    final manager = ReadLaterManager();
    if (!manager.isInitialized) {
      context.showMessage(message: 'Could not update read later'.tl);
      return;
    }
    final existed = manager.isExist(comic.id, comic.type);
    setState(() => _savingReadLater = true);
    try {
      if (existed) {
        await manager.remove(comic.id, comic.type);
      } else {
        // Preserve the stored type even when the comic's source was removed.
        await manager.addItem(
          ReadLaterItem(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            cover: comic.cover,
            type: comic.type,
            tags: comic.tags,
            time: DateTime.now(),
          ),
        );
      }
      if (!mounted) return;
      context.showMessage(
        message:
            (existed ? 'Removed from read later' : 'Added to read later').tl,
      );
    } catch (error, stack) {
      Log.error('Random comic read later', error, stack);
      if (mounted) {
        context.showMessage(message: 'Could not update read later'.tl);
      }
    } finally {
      if (mounted) setState(() => _savingReadLater = false);
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
    final colors = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final dialogHeight = math.min(
      800.0,
      media.size.height -
          media.padding.vertical -
          media.viewInsets.vertical -
          40,
    );
    final scrollFooter = media.textScaler.scale(14) >= 21 || dialogHeight < 560;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      backgroundColor: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SizedBox(
          width: 640,
          height: math.max(0, dialogHeight),
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                        child: _buildBody(media),
                      ),
                      if (scrollFooter) _buildFooter(),
                    ],
                  ),
                ),
              ),
              if (!scrollFooter) _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(MediaQueryData media) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildModeControls(),
        const SizedBox(height: 8),
        _buildPoolControl(),
        if (_showScope) _buildScopeControls(),
        const SizedBox(height: 12),
        RandomComicDrawStage(
          comics: _hand,
          drawCount: _drawCount,
          deal: _dealController,
          flips: _flips,
          selectedIndex: _selectedIndex,
          onCardTap: _revealCard,
          onDraw: _loading || _busy || _candidates.isEmpty ? null : _drawComics,
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: 104 * media.textScaler.scale(14) / 14,
          ),
          child: Semantics(liveRegion: true, child: _buildResult()),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Draw a comic'.tl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Let your next read surprise you.'.tl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('draw-quick-reveal'),
            tooltip: 'Quick reveal'.tl,
            isSelected: _quickReveal,
            onPressed: _toggleQuickReveal,
            icon: const Icon(Icons.bolt_outlined),
            selectedIcon: Icon(
              Icons.bolt_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
          IconButton(
            tooltip: 'Close'.tl,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildModeControls() {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ChoiceChip(
          key: const ValueKey('draw-mode-single'),
          selected: _drawCount == 1,
          avatar: const Icon(Icons.style_outlined, size: 18),
          label: Text('Single draw'.tl),
          showCheckmark: false,
          onSelected: _loading || _busy ? null : (_) => _changeMode(1),
        ),
        ChoiceChip(
          key: const ValueKey('draw-mode-three'),
          selected: _drawCount == 3,
          avatar: const Icon(Icons.view_carousel_outlined, size: 18),
          label: Text('Choose from three'.tl),
          showCheckmark: false,
          onSelected: _loading || _busy ? null : (_) => _changeMode(3),
        ),
      ],
    );
  }

  Widget _buildPoolControl() {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: const ValueKey('draw-scope-toggle'),
        borderRadius: BorderRadius.circular(12),
        onTap: _busy ? null : () => setState(() => _showScope = !_showScope),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_selectedFolder ?? 'All favorites'.tl} · ${_readingScopeLabel(_readingScope)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              if (_loading)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  '${_candidates.length}',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(width: 4),
              Icon(
                _showScope ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScopeControls() {
    final disabled = _loading || _busy;
    final folderField = DropdownButtonFormField<String?>(
      key: const ValueKey('draw-folder'),
      initialValue: randomComicAvailableFolder(_selectedFolder, _folders),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Selection scope'.tl,
        border: const OutlineInputBorder(),
      ),
      hint: Text('All favorites'.tl),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text('All favorites'.tl)),
        ..._folders.map(
          (folder) => DropdownMenuItem<String?>(
            value: folder,
            child: Text(folder, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: disabled
          ? null
          : (folder) {
              if (folder == _selectedFolder) return;
              _selectedFolder = folder;
              _persistSelection();
              _loadSelectionScope();
            },
    );
    final readingField = DropdownButtonFormField<RandomComicReadingScope>(
      key: const ValueKey('draw-reading-scope'),
      initialValue: _readingScope,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Reading progress'.tl,
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
      onChanged: disabled
          ? null
          : (scope) {
              if (scope == null || scope == _readingScope) return;
              setState(() {
                _readingScope = scope;
                _applyReadingScope();
              });
              _persistSelection();
            },
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: KeyedSubtree(
        key: ValueKey((_selectedFolder, _readingScope)),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (constraints.maxWidth >= 480)
                Row(
                  children: [
                    Expanded(child: folderField),
                    const SizedBox(width: 12),
                    Expanded(child: readingField),
                  ],
                )
              else ...[
                folderField,
                const SizedBox(height: 14),
                readingField,
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: disabled ? null : _resetFilters,
                  child: Text('Reset filters'.tl),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResult() {
    final theme = Theme.of(context);
    final comic = _selectedComic;
    if (comic != null) {
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
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            [
              if (author.trim().isNotEmpty) author,
              _readingStatus(comic),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (comic.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: comic.tags
                  .take(3)
                  .map(
                    (tag) => Container(
                      constraints: const BoxConstraints(maxWidth: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      );
    }
    final text = _loading
        ? 'Loading favorites...'.tl
        : _loadError
        ? 'Could not load favorites'.tl
        : _candidates.isEmpty
        ? 'No favorite comics in this selection'.tl
        : _dealing
        ? 'Drawing...'.tl
        : _flips.any((flip) => flip.isAnimating)
        ? 'Tap the card to skip'.tl
        : _hand.isEmpty
        ? (_drawCount == 1 ? 'Tap to draw' : 'Choose from three').tl
        : 'Tap a card to reveal it'.tl;
    return Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 5),
        Text(
          _candidates.isEmpty && !_loading && !_loadError
              ? (_selectedFolder != null ||
                            _readingScope != RandomComicReadingScope.all
                        ? 'Change filters to find more comics'
                        : 'Add favorites to build your draw pool')
                    .tl
              : (_drawCount == 3
                        ? 'Pick the one you want to read'
                        : 'Equal chance · No repeats this round')
                    .tl,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    final comic = _selectedComic;
    final inReadLater =
        comic != null && ReadLaterManager().isExist(comic.id, comic.type);
    final hasFilters =
        _selectedFolder != null || _readingScope != RandomComicReadingScope.all;
    final count = math.min(
      _drawCount,
      _remaining == 0 ? _candidates.length : _remaining,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Round @round'.tlParams({'round': _round}),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Text(
                '${_drawn.length} / ${_candidates.length}',
                style: theme.textTheme.labelMedium,
              ),
              IconButton(
                tooltip: 'Draw rules'.tl,
                onPressed: _showRules,
                icon: const Icon(Icons.info_outline_rounded, size: 18),
              ),
            ],
          ),
          LinearProgressIndicator(
            key: const ValueKey('draw-round-progress'),
            value: _candidates.isEmpty ? 0 : _drawn.length / _candidates.length,
            minHeight: 3,
            borderRadius: BorderRadius.circular(3),
            semanticsLabel: 'Round @round'.tlParams({'round': _round}),
          ),
          const SizedBox(height: 9),
          Text(
            _hand.isNotEmpty && !_allRevealed
                ? '@revealed of @count revealed'.tlParams({
                    'revealed': _revealedCount,
                    'count': _hand.length,
                  })
                : _remaining == 0 && _candidates.isNotEmpty
                ? 'Pool cleared. The next draw starts a new round.'.tl
                : '@count left'.tlParams({'count': _remaining}),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (_hand.isNotEmpty && !_allRevealed) ...[
            FilledButton.tonalIcon(
              key: const ValueKey('draw-reveal-all'),
              onPressed: () => _revealAll(immediate: _busy),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: Icon(
                _busy
                    ? Icons.fast_forward_rounded
                    : Icons.auto_awesome_outlined,
              ),
              label: Text((_busy ? 'Reveal now' : 'Reveal all').tl),
            ),
            if (comic != null) const SizedBox(height: 8),
          ],
          if (comic != null)
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_allRevealed)
                  OutlinedButton.icon(
                    key: const ValueKey('draw-button'),
                    onPressed: _busy ? null : _drawComics,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      (_remaining == 0 ? 'New round' : 'Draw again').tl,
                    ),
                  ),
                IconButton.outlined(
                  key: const ValueKey('draw-read-later'),
                  tooltip: (inReadLater ? 'In read later' : 'Read later').tl,
                  isSelected: inReadLater,
                  onPressed: _savingReadLater ? null : _toggleReadLater,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  selectedIcon: const Icon(Icons.bookmark_added_rounded),
                ),
                FilledButton.icon(
                  key: const ValueKey('draw-read'),
                  onPressed: _savingReadLater
                      ? null
                      : () => Navigator.of(context).pop(comic),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.menu_book_rounded, size: 18),
                  label: Text('Read this one'.tl),
                ),
              ],
            )
          else if (_hand.isEmpty)
            FilledButton.icon(
              key: const ValueKey('draw-button'),
              onPressed: _loadError
                  ? _loadSelectionScope
                  : _loading || _candidates.isEmpty
                  ? null
                  : _drawComics,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: Icon(
                _loadError ? Icons.refresh_rounded : Icons.style_rounded,
              ),
              label: Text(
                _loadError
                    ? 'Retry'.tl
                    : count == 0
                    ? 'Draw'.tl
                    : 'Draw @count'.tlParams({'count': count}),
              ),
            ),
          if (_candidates.isEmpty && !_loading && !_loadError && hasFilters)
            TextButton(
              onPressed: _resetFilters,
              child: Text('Reset filters'.tl),
            ),
        ],
      ),
    );
  }

  void _showRules() {
    showDialog<void>(
      context: context,
      builder: (context) => ContentDialog(
        title: 'Draw rules'.tl,
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Every comic has an equal chance. Dealt cards will not repeat until the next round. Changing filters starts a fresh round.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Choose from three deals up to three remaining comics. Reveal them, then pick one to read. No favorites or reading progress are changed.'
                    .tl,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
