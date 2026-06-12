part of 'image_favorites_page.dart';

/// 单部漫画的图片收藏网格页。
///
/// 从主页面「漫画网格」视图点击某部漫画进入，只展示这一部漫画的收藏图，
/// 多选/删除的作用域天然限定在本漫画内（解决 issue #28：在全局平铺网格里
/// 难以辨认、难以只删某部漫画的部分图）。
///
/// 数据刷新：监听全局单例 [ImageFavoriteManager]，删除后用
/// [ImageFavoriteManager.find] 重新拉取本漫画的最新数据；若图片被删空则退回。
class SingleComicImageFavoritesPage extends StatefulWidget {
  const SingleComicImageFavoritesPage({super.key, required this.comic});

  final ImageFavoritesComic comic;

  @override
  State<SingleComicImageFavoritesPage> createState() =>
      _SingleComicImageFavoritesPageState();
}

class _SingleComicImageFavoritesPageState
    extends State<SingleComicImageFavoritesPage> {
  late ImageFavoritesComic comic;

  bool multiSelectMode = false;

  final Map<ImageFavorite, bool> selectedImageFavorites = {};

  final scrollController = ScrollController();

  List<ImageFavorite> get images => comic.images.toList();

  @override
  void initState() {
    comic = widget.comic;
    ImageFavoriteManager().addListener(_onDataChanged);
    super.initState();
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(_onDataChanged);
    scrollController.dispose();
    super.dispose();
  }

  /// 全局收藏数据变化时，重新拉取本漫画。已不存在（图片删空）则退回上一页。
  void _onDataChanged() {
    if (!mounted) return;
    var latest = ImageFavoriteManager().find(comic.id, comic.sourceKey);
    if (latest == null || latest.images.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      comic = latest;
      // 清理已不存在的选中项
      selectedImageFavorites.removeWhere(
        (k, v) => !latest.images.contains(k),
      );
      if (selectedImageFavorites.isEmpty) {
        multiSelectMode = false;
      }
    });
  }

  void update() {
    if (mounted) setState(() {});
  }

  void addSelected(ImageFavorite i) {
    if (selectedImageFavorites[i] == null) {
      selectedImageFavorites[i] = true;
    } else {
      selectedImageFavorites.remove(i);
    }
    multiSelectMode = selectedImageFavorites.isNotEmpty;
    update();
  }

  void selectAll() {
    for (var i in comic.images) {
      selectedImageFavorites[i] = true;
    }
    update();
  }

  void deSelect() {
    setState(() {
      selectedImageFavorites.clear();
    });
  }

  void exitMultiSelect() {
    setState(() {
      multiSelectMode = false;
      selectedImageFavorites.clear();
    });
  }

  Widget _buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            ImageFavoriteManager().deleteImageFavorite(
              selectedImageFavorites.keys.toList(),
            );
            setState(() {
              multiSelectMode = false;
              selectedImageFavorites.clear();
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    var items = images;
    var scrollWidget = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!multiSelectMode)
          SliverAppbar(
            title: Text(comic.title),
            actions: [
              Tooltip(
                message: "Multi-Select".tl,
                child: IconButton(
                  icon: const Icon(Icons.checklist),
                  onPressed: () {
                    setState(() {
                      multiSelectMode = true;
                    });
                  },
                ),
              ),
            ],
          )
        else
          SliverAppbar(
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: exitMultiSelect,
              ),
            ),
            title: Text(selectedImageFavorites.length.toString()),
            actions: [
              IconButton(
                icon: const Icon(Icons.select_all),
                tooltip: "Select All".tl,
                onPressed: selectAll,
              ),
              IconButton(
                icon: const Icon(Icons.deselect),
                tooltip: "Deselect".tl,
                onPressed: deSelect,
              ),
              _buildMultiSelectMenu(),
            ],
          ),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedHeight(
            maxCrossAxisExtent: 180,
            itemHeight: 240,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _ImageFavoritesGridItem(
              key: ValueKey(
                "${items[index].sourceKey}@${items[index].id}@"
                "${items[index].eid}@${items[index].page}",
              ),
              comic: comic,
              image: items[index],
              selectedImageFavorites: selectedImageFavorites,
              addSelected: addSelected,
              multiSelectMode: multiSelectMode,
            ),
            childCount: items.length,
          ),
        ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    Widget body = Scrollbar(
      controller: scrollController,
      thickness: App.isDesktop ? 8 : 12,
      radius: const Radius.circular(8),
      interactive: true,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: context.width > changePoint
            ? scrollWidget.paddingHorizontal(8)
            : scrollWidget,
      ),
    );
    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          exitMultiSelect();
        }
      },
      child: body,
    );
  }
}
