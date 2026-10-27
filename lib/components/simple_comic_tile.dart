part of 'components.dart';

class SimpleComicTile extends StatelessWidget {
  const SimpleComicTile({
    super.key,
    required this.comic,
    this.onTap,
    this.withTitle = false,
    this.heroID,
    this.showFavorite = false,
    this.width = 98,
    this.height = 136,
  });

  final Comic comic;

  final void Function()? onTap;

  final bool withTitle;

  final Object? heroID;

  final bool showFavorite;

  /// Optional dimensions for responsive surfaces such as the home feed. The
  /// established 98x136 size remains the default for all other callers.
  final double width;

  final double height;

  Widget _buildCover() {
    var image = findImageProvider(comic);
    if (image == null) return const SizedBox();
    return AnimatedImage(
      image: image,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget cover = _buildCover();
    // A collection's cover arrives asynchronously the first time its members
    // load, so this tile has to rebuild when the store fills it in.
    if (ComicCollectionStore.isCollectionSourceKey(comic.sourceKey)) {
      cover = ListenableBuilder(
        listenable: ComicCollectionStore.changes,
        builder: (context, _) => _buildCover(),
      );
    }

    if (showFavorite) {
      final comicType = ComicType.fromKey(comic.sourceKey);
      final showFav = appdata.settings['showFavoriteStatusOnTile'] &&
          LocalFavoritesManager().isExist(comic.id, comicType);
      final showReadLater = appdata.settings['showReadLaterStatusOnTile'] &&
          ReadLaterManager().isExist(comic.id, comicType);
      if (showFav || showReadLater) {
        cover = Stack(
          fit: StackFit.expand,
          children: [
            cover,
            Positioned(
              left: 0,
              top: 0,
              child: Row(
                children: [
                  if (showFav)
                    Container(
                      height: 24,
                      width: 24,
                      color: Colors.green,
                      child: const Icon(
                        Icons.bookmark_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  if (showReadLater)
                    Container(
                      height: 24,
                      width: 24,
                      color: Colors.orange,
                      child: const Icon(
                        Icons.watch_later_rounded,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      }
    }

    // Same marker as the list tiles, but top-RIGHT: the favourite and
    // read-later badges already own the top-left corner of this tile.
    if (ComicCollectionStore.isCollectionSourceKey(comic.sourceKey)) {
      cover = Stack(
        fit: StackFit.expand,
        children: [
          cover,
          Positioned(
            right: 3,
            top: 3,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.toOpacity(0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.library_books_outlined,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    } else if (appdata.settings['showCollectionStatusOnTile'] == true) {
      cover = Stack(
        fit: StackFit.expand,
        children: [
          cover,
          Positioned(
            right: 3,
            top: 3,
            child: CollectionMemberMarker(
              sourceKey: comic.sourceKey,
              comicId: comic.id,
              size: 12,
            ),
          ),
        ],
      );
    }

    Widget child = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: cover,
    );

    if (heroID != null) {
      child = Hero(tag: "cover$heroID", child: child);
    }

    child = AnimatedTapRegion(
      borderRadius: 8,
      onTap:
          onTap ??
          () {
            context.to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
                heroID: heroID,
              ),
            );
          },
      child: child,
    );

    if (withTitle) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 4),
          SizedBox(
            width: width - 6,
            child: Center(
              child: Text(
                comic.title.replaceAll('\n', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    return child;
  }
}
