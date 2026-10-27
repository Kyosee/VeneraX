part of 'components.dart';

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selections,
    this.enableHero = true,
    this.enableContextMenu = true,
    this.swipeActionBuilder,
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  final bool enableHero;

  /// Suppresses single-item menus while the host performs batch selection.
  final bool enableContextMenu;

  /// When set, each tile becomes swipeable on mobile. The builder returns the
  /// panes (start = right swipe, end = left swipe) for a given comic, or null
  /// to leave that comic non-swipeable. See [SwipeActionTile].
  final SwipePanes Function(Comic)? swipeActionBuilder;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (!comics.isEqualTo(widget.comics)) {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
      generateHeroID();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    for (var comic in widget.comics) {
      if (isBlocked(comic) == null) {
        comics.add(comic);
      }
    }
    generateHeroID();
    HistoryManager().addListener(update);
    LocalFavoritesManager().addListener(update);
    ReadLaterManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(update);
    LocalFavoritesManager().removeListener(update);
    ReadLaterManager().removeListener(update);
    super.dispose();
  }

  void update() {
    setState(() {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      enableHero: widget.enableHero,
      enableContextMenu: widget.enableContextMenu,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onTapWithIndex: widget.onTapWithIndex,
      onLongPressed: widget.onLongPressed,
      onLongPressedWithIndex: widget.onLongPressedWithIndex,
      swipeActionBuilder: widget.swipeActionBuilder,
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    this.enableHero = true,
    this.enableContextMenu = true,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selection,
    this.swipeActionBuilder,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  final bool enableHero;

  final bool enableContextMenu;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  final SwipePanes Function(Comic)? swipeActionBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          enableContextMenu: enableContextMenu,
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          onTap: onTapWithIndex != null
              ? () => onTapWithIndex!(comics[index], heroIDs[index], index)
              : onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressedWithIndex != null
              ? () => onLongPressedWithIndex!(
                  comics[index],
                  heroIDs[index],
                  index,
                )
              : onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          heroID: enableHero ? heroIDs[index] : null,
        );
        Widget tile = comic;
        if (selection != null) {
          tile = AnimatedContainer(
            key: ValueKey(comics[index].id),
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.toOpacity(0.72)
                  : null,
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(4),
            child: comic,
          );
        }
        if (swipeActionBuilder != null && App.isMobile) {
          final current = comics[index];
          final panes = swipeActionBuilder!(current);
          if (panes.start != null || panes.end != null) {
            tile = SwipeActionTile(
              key: ValueKey('swipe-${current.sourceKey}-${current.id}'),
              startPane: panes.start,
              endPane: panes.end,
              child: tile,
            );
          }
        }
        return tile;
      }, childCount: comics.length),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}
