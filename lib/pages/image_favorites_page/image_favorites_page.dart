import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/image_favorites_page/type.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

part "image_favorites_item.dart";

part "image_favorites_photo_view.dart";

part "single_comic_image_favorites_page.dart";

/// 图片收藏页的三种视图模式：
/// - [list]：按漫画分组的列表（每行一部漫画，横向滑动展示其收藏图）
/// - [imageGrid]：所有漫画的收藏图平铺成一个网格
/// - [comicGrid]：每部漫画一个封面格子，点进去看该漫画专属的图片网格
enum ImageFavoritesViewMode {
  list,
  imageGrid,
  comicGrid;

  ImageFavoritesViewMode get next {
    return ImageFavoritesViewMode.values[(index + 1) % values.length];
  }
}

class ImageFavoritesPage extends StatefulWidget {
  const ImageFavoritesPage({super.key, this.initialKeyword});

  final String? initialKeyword;

  @override
  State<ImageFavoritesPage> createState() => _ImageFavoritesPageState();
}

class _ImageFavoritesPageState extends State<ImageFavoritesPage> {
  late ImageFavoriteSortType sortType;
  late TimeRange timeFilterSelect;
  late int numFilterSelect;

  // 所有的图片收藏
  List<ImageFavoritesComic> comics = [];

  late var controller = TextEditingController(
    text: widget.initialKeyword ?? "",
  );

  String get keyword => controller.text;

  // 进入关键词搜索模式
  bool searchMode = false;

  bool multiSelectMode = false;

  // 视图模式（列表 / 图片网格 / 漫画网格）
  ImageFavoritesViewMode viewMode = ImageFavoritesViewMode.list;

  // 多选的时候选中的图片
  Map<ImageFavorite, bool> selectedImageFavorites = {};

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  void updateImageFavorites() async {
    comics = searchMode
        ? ImageFavoriteManager().search(keyword)
        : ImageFavoriteManager().getAll();
    sortImageFavorites();
    update();
  }

  void sortImageFavorites() {
    comics = searchMode
        ? ImageFavoriteManager().search(keyword)
        : ImageFavoriteManager().getAll();
    // 筛选到最终列表
    comics = comics.where((ele) {
      bool isFilter = true;
      if (timeFilterSelect != TimeRange.all) {
        isFilter = timeFilterSelect.contains(ele.time);
      }
      if (numFilterSelect != numFilterList[0]) {
        isFilter = ele.images.length > numFilterSelect;
      }
      return isFilter;
    }).toList();
    // 给列表排序
    switch (sortType) {
      case ImageFavoriteSortType.title:
        comics.sort((a, b) => a.title.compareTo(b.title));
      case ImageFavoriteSortType.timeAsc:
        comics.sort((a, b) => a.time.compareTo(b.time));
      case ImageFavoriteSortType.timeDesc:
        comics.sort((a, b) => b.time.compareTo(a.time));
      case ImageFavoriteSortType.maxFavorites:
        comics.sort((a, b) => b.images.length.compareTo(a.images.length));
      case ImageFavoriteSortType.favoritesCompareComicPages:
        comics.sort((a, b) {
          double tempA = a.images.length / a.maxPageFromEp;
          double tempB = b.images.length / b.maxPageFromEp;
          return tempB.compareTo(tempA);
        });
    }
  }

  @override
  void initState() {
    if (widget.initialKeyword != null) {
      searchMode = true;
    }
    sortType =
        ImageFavoriteSortType.values.firstWhereOrNull(
          (e) => e.value == appdata.implicitData["image_favorites_sort"],
        ) ??
        ImageFavoriteSortType.title;
    timeFilterSelect = TimeRange.fromString(
      appdata.implicitData["image_favorites_time_filter"],
    );
    numFilterSelect =
        appdata.implicitData["image_favorites_number_filter"] ??
        numFilterList[0];
    viewMode = _readViewMode();
    updateImageFavorites();
    ImageFavoriteManager().addListener(updateImageFavorites);
    super.initState();
  }

  /// 读取持久化的视图模式。优先读新 key；老用户只有旧布尔 key 时做迁移：
  /// 旧 `true`（网格）→ [imageGrid]，`false`/缺省 → [list]。
  ImageFavoritesViewMode _readViewMode() {
    var name = appdata.implicitData["image_favorites_view_mode"];
    if (name is String) {
      var mode = ImageFavoritesViewMode.values
          .firstWhereOrNull((e) => e.name == name);
      if (mode != null) return mode;
    }
    var legacyGrid = appdata.implicitData["image_favorites_grid_mode"];
    return legacyGrid == true
        ? ImageFavoritesViewMode.imageGrid
        : ImageFavoritesViewMode.list;
  }

  void _saveViewMode() {
    appdata.implicitData["image_favorites_view_mode"] = viewMode.name;
    appdata.writeImplicitData();
  }

  IconData _viewModeIcon(ImageFavoritesViewMode mode) {
    return switch (mode) {
      ImageFavoritesViewMode.list => Icons.view_list,
      ImageFavoritesViewMode.imageGrid => Icons.grid_view,
      ImageFavoritesViewMode.comicGrid => Icons.collections_outlined,
    };
  }

  /// 切换按钮提示「下一个」模式，与原先「点了会变成什么」的语义一致。
  String _viewModeTooltip(ImageFavoritesViewMode mode) {
    return switch (mode) {
      ImageFavoritesViewMode.list => "List View".tl,
      ImageFavoritesViewMode.imageGrid => "Grid View".tl,
      ImageFavoritesViewMode.comicGrid => "Comic Grid View".tl,
    };
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(updateImageFavorites);
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            ImageFavoriteManager().deleteImageFavorite(
              selectedImageFavorites.keys,
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

  var scrollController = ScrollController();

  // 网格模式: 所有收藏图片平铺成 (comic, image) 对
  List<(ImageFavoritesComic, ImageFavorite)> get flatImages {
    var result = <(ImageFavoritesComic, ImageFavorite)>[];
    for (var c in comics) {
      for (var i in c.images) {
        result.add((c, i));
      }
    }
    return result;
  }

  void selectAll() {
    for (var c in comics) {
      for (var i in c.images) {
        selectedImageFavorites[i] = true;
      }
    }
    update();
  }

  void deSelect() {
    setState(() {
      selectedImageFavorites.clear();
    });
  }

  void addSelected(ImageFavorite i) {
    if (selectedImageFavorites[i] == null) {
      selectedImageFavorites[i] = true;
    } else {
      selectedImageFavorites.remove(i);
    }
    if (selectedImageFavorites.isEmpty) {
      multiSelectMode = false;
    } else {
      multiSelectMode = true;
    }
    update();
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
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
      buildMultiSelectMenu(),
    ];

    var scrollWidget = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            title: Text("Image Favorites".tl),
            actions: [
              Tooltip(
                message: _viewModeTooltip(viewMode.next),
                child: IconButton(
                  icon: Icon(_viewModeIcon(viewMode)),
                  onPressed: () {
                    setState(() {
                      viewMode = viewMode.next;
                    });
                    _saveViewMode();
                  },
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      searchMode = true;
                    });
                  },
                ),
              ),
              Tooltip(
                message: "Sort".tl,
                child: IconButton(
                  isSelected:
                      timeFilterSelect != TimeRange.all ||
                      numFilterSelect != numFilterList[0],
                  icon: const Icon(Icons.filter_alt_outlined),
                  onPressed: sort,
                ),
              ),
              Tooltip(
                message: multiSelectMode
                    ? "Exit Multi-Select".tl
                    : "Multi-Select".tl,
                child: IconButton(
                  icon: const Icon(Icons.checklist),
                  onPressed: () {
                    setState(() {
                      multiSelectMode = !multiSelectMode;
                    });
                  },
                ),
              ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedImageFavorites.clear();
                  });
                },
              ),
            ),
            title: Text(selectedImageFavorites.length.toString()),
            actions: selectActions,
          )
        else if (searchMode)
          SliverAppbar(
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  setState(() {
                    searchMode = false;
                    controller.clear();
                    updateImageFavorites();
                  });
                },
              ),
            ),
            title: TextField(
              autofocus: true,
              controller: controller,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: InputBorder.none,
              ),
              onChanged: (v) {
                updateImageFavorites();
              },
            ),
          ),
        switch (viewMode) {
          ImageFavoritesViewMode.imageGrid => _buildGridSliver(),
          ImageFavoritesViewMode.comicGrid => _buildComicGridSliver(),
          ImageFavoritesViewMode.list => SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              return _ImageFavoritesItem(
                key: ValueKey(
                  "${comics[index].sourceKey}@${comics[index].id}",
                ),
                imageFavoritesComic: comics[index],
                selectedImageFavorites: selectedImageFavorites,
                addSelected: addSelected,
                multiSelectMode: multiSelectMode,
                finalImageFavoritesComicList: comics,
              );
            }, childCount: comics.length),
          ),
        },
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
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedImageFavorites.clear();
          });
        } else if (searchMode) {
          controller.clear();
          searchMode = false;
          updateImageFavorites();
        }
      },
      child: body,
    );
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return _ImageFavoritesDialog(
          initSortType: sortType,
          initTimeFilterSelect: timeFilterSelect,
          initNumFilterSelect: numFilterSelect,
          updateConfig: (sortType, timeFilter, numFilter) {
            setState(() {
              this.sortType = sortType;
              timeFilterSelect = timeFilter;
              numFilterSelect = numFilter;
            });
            sortImageFavorites();
          },
        );
      },
    );
  }

  Widget _buildGridSliver() {
    var items = flatImages;
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedHeight(
        maxCrossAxisExtent: 180,
        itemHeight: 240,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => _ImageFavoritesGridItem(
          key: ValueKey(_gridItemKey(items[index])),
          comic: items[index].$1,
          image: items[index].$2,
          selectedImageFavorites: selectedImageFavorites,
          addSelected: addSelected,
          multiSelectMode: multiSelectMode,
        ),
        childCount: items.length,
      ),
    ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8));
  }

  String _gridItemKey((ImageFavoritesComic, ImageFavorite) e) {
    var i = e.$2;
    return "${i.sourceKey}@${i.id}@${i.eid}@${i.page}";
  }

  /// 漫画网格：每部漫画一个封面格子，点击进入该漫画专属的图片网格子页。
  Widget _buildComicGridSliver() {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedHeight(
        maxCrossAxisExtent: 180,
        itemHeight: 240,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) => _ImageFavoritesComicGridItem(
          key: ValueKey(
            "${comics[index].sourceKey}@${comics[index].id}",
          ),
          comic: comics[index],
        ),
        childCount: comics.length,
      ),
    ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8));
  }
}

class _ImageFavoritesDialog extends StatefulWidget {
  const _ImageFavoritesDialog({
    required this.initSortType,
    required this.initTimeFilterSelect,
    required this.initNumFilterSelect,
    required this.updateConfig,
  });

  final ImageFavoriteSortType initSortType;
  final TimeRange initTimeFilterSelect;
  final int initNumFilterSelect;
  final Function updateConfig;

  @override
  State<_ImageFavoritesDialog> createState() => _ImageFavoritesDialogState();
}

class _ImageFavoritesDialogState extends State<_ImageFavoritesDialog> {
  List<String> optionTypes = ['Sort', 'Filter'];
  late var sortType = widget.initSortType;
  late var numFilter = widget.initNumFilterSelect;
  late TimeRangeType timeRangeType;
  DateTime? start;
  DateTime? end;

  @override
  void initState() {
    super.initState();
    timeRangeType = switch (widget.initTimeFilterSelect) {
      TimeRange.all => TimeRangeType.all,
      TimeRange.lastWeek => TimeRangeType.lastWeek,
      TimeRange.lastMonth => TimeRangeType.lastMonth,
      TimeRange.lastHalfYear => TimeRangeType.lastHalfYear,
      TimeRange.lastYear => TimeRangeType.lastYear,
      _ => TimeRangeType.custom,
    };
    if (timeRangeType == TimeRangeType.custom) {
      end = widget.initTimeFilterSelect.end;
      start = end!.subtract(widget.initTimeFilterSelect.duration);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);
    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(
              children: [
                RadioGroup<ImageFavoriteSortType>(
                  groupValue: sortType,
                  onChanged: (v) {
                    setState(() {
                      sortType = v ?? sortType;
                    });
                  },
                  child: Column(
                    children: ImageFavoriteSortType.values
                        .map(
                          (e) => RadioListTile<ImageFavoriteSortType>(
                            title: Text(e.value.tl),
                            value: e,
                          ),
                        )
                        .toList(),
                  ),
                ),
                Column(
                  children: [
                    ListTile(
                      title: Text("Time Filter".tl),
                      trailing: Select(
                        current: timeRangeType.value.tl,
                        values: TimeRangeType.values
                            .map((e) => e.value.tl)
                            .toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            timeRangeType = TimeRangeType.values[index];
                          });
                        },
                      ),
                    ),
                    if (timeRangeType == TimeRangeType.custom)
                      Column(
                        children: [
                          ListTile(
                            title: Text("Start Time".tl),
                            trailing: TextButton(
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: start ?? DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: end ?? DateTime.now(),
                                );
                                if (date != null) {
                                  setState(() {
                                    start = date;
                                  });
                                }
                              },
                              child: Text(
                                start == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(start!),
                              ),
                            ),
                          ),
                          ListTile(
                            title: Text("End Time".tl),
                            trailing: TextButton(
                              onPressed: () async {
                                final date = await showDatePicker(
                                  context: context,
                                  initialDate: end ?? DateTime.now(),
                                  firstDate: start ?? DateTime(2000),
                                  lastDate: DateTime.now(),
                                );
                                if (date != null) {
                                  setState(() {
                                    end = date;
                                  });
                                }
                              },
                              child: Text(
                                end == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(end!),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ListTile(
                      title: Text("Image Favorites Greater Than".tl),
                      trailing: Select(
                        current: numFilter.toString(),
                        values: numFilterList.map((e) => e.toString()).toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            numFilter = numFilterList[index];
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            appdata.implicitData["image_favorites_sort"] = sortType.value;
            TimeRange timeRange;
            if (timeRangeType == TimeRangeType.custom) {
              timeRange = TimeRange(
                end: end,
                duration: end!.difference(start!),
              );
            } else {
              timeRange = switch (timeRangeType) {
                TimeRangeType.all => TimeRange.all,
                TimeRangeType.lastWeek => TimeRange.lastWeek,
                TimeRangeType.lastMonth => TimeRange.lastMonth,
                TimeRangeType.lastHalfYear => TimeRange.lastHalfYear,
                TimeRangeType.lastYear => TimeRange.lastYear,
                _ => TimeRange.all,
              };
            }
            appdata.implicitData["image_favorites_time_filter"] = timeRange
                .toString();
            appdata.implicitData["image_favorites_number_filter"] = numFilter;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              widget.updateConfig(sortType, timeRange, numFilter);
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
