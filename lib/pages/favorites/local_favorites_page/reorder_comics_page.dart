part of '../favorites_page.dart';

class _ReorderComicsPage extends StatefulWidget {
  const _ReorderComicsPage(this.name, this.onReorder);

  final String name;

  final void Function(List<FavoriteItem>) onReorder;

  @override
  State<_ReorderComicsPage> createState() => _ReorderComicsPageState();
}

class _ReorderComicsPageState extends State<_ReorderComicsPage> {
  final _key = GlobalKey();
  var reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  late var comics = LocalFavoritesManager().getFolderComics(widget.name);
  bool changed = false;

  /// Set once the grid has been remounted to rebuild its position cache.
  /// Remounting treats every tile as new, which would replay the fade-in, so
  /// the fade is dropped from that point on.
  bool positionsRebuilt = false;

  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lightenColor(Color color, double lightenValue) {
    int red = (_floatToInt8(color.r) + ((255 - color.r) * lightenValue))
        .round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();

    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    if (changed) {
      // Delay to ensure navigation is completed
      Future.delayed(const Duration(milliseconds: 200), () {
        LocalFavoritesManager().reorder(comics, widget.name);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];
    var tiles = comics.map((e) {
      var comicSource = e.type.comicSource;
      return ComicTile(
        key: Key(e.hashCode.toString()),
        enableLongPressed: false,
        comic: Comic(
          e.name,
          e.coverPath,
          e.id,
          e.author,
          e.tags,
          type == 'detailed'
              ? "${e.time} | ${comicSource?.name ?? "Unknown"}"
              : "${e.type.comicSource?.name ?? "Unknown"} | ${e.time}",
          comicSource?.key ?? (e.type == ComicType.local ? "local" : "Unknown"),
          null,
          null,
        ),
      );
    }).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Reorder".tl),
        actions: [
          Tooltip(
            message: "Information".tl,
            child: IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          ),
          Tooltip(
            message: "Reverse".tl,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() {
                  comics = comics.reversed.toList();
                  changed = true;
                  // Reversing moves every item at once. The grid caches each
                  // item's position and only refreshes entries it rebuilds, so
                  // off-screen items keep stale positions and later drags land
                  // on the wrong index. A new key rebuilds those positions.
                  reorderWidgetKey = UniqueKey();
                  positionsRebuilt = true;
                });
              },
            ),
          ),
        ],
      ),
      body: ReorderableBuilder<FavoriteItem>(
        key: reorderWidgetKey,
        scrollController: _scrollController,
        animationConfig: ReorderableAnimationConfig(
          fadeInDuration: positionsRebuilt
              ? Duration.zero
              : const Duration(milliseconds: 500),
        ),
        longPressDelay: App.isDesktop
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            comics = reorderFunc(comics);
          });
          widget.onReorder(comics);
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: lightenColor(
            Theme.of(context).splashColor.withAlpha(255),
            0.2,
          ),
        ),
        builder: (children) {
          return GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithComics(),
            children: children,
          );
        },
        children: tiles,
      ),
    );
  }
}
