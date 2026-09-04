import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'comic_source_page.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage>
    with
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin<CategoriesPage> {
  var categories = <String>[];

  late TabController controller;

  void onSettingsChanged() {
    var categories = List.from(
      appdata.settings["categories"],
    ).whereType<String>().toList();
    var allCategories = ComicSource.all()
        .map((e) => e.categoryData?.key)
        .where((element) => element != null)
        .map((e) => e!)
        .toList();
    categories = categories
        .where((element) => allCategories.contains(element))
        .toList();
    if (!categories.isEqualTo(this.categories)) {
      var oldController = controller;
      var newController = TabController(length: categories.length, vsync: this);
      setState(() {
        this.categories = categories;
        controller = newController;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    var categories = List.from(
      appdata.settings["categories"],
    ).whereType<String>().toList();
    var allCategories = ComicSource.all()
        .map((e) => e.categoryData?.key)
        .where((element) => element != null)
        .map((e) => e!)
        .toList();
    this.categories = categories
        .where((element) => allCategories.contains(element))
        .toList();
    appdata.settings.addListener(onSettingsChanged);
    controller = TabController(length: this.categories.length, vsync: this);
  }

  void addPage() {
    showPopUpWidget(App.rootContext, setCategoryPagesWidget());
  }

  TabPageSelectorItem buildSelectorItem(String category) {
    final source = ComicSource.all().firstWhere(
      (source) => source.categoryData?.key == category,
    );
    final pageLabel = source.categoryData!.title;
    return TabPageSelectorItem(
      label: source.name,
      subtitle: pageLabel == source.name ? null : pageLabel,
      searchTerms: '${source.key} $category',
    );
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    controller.dispose();
    super.dispose();
  }

  Widget buildEmpty() {
    var msg = "No Category Pages".tl;
    msg += '\n';
    VoidCallback onTap;
    if (ComicSource.isEmpty) {
      msg += "Please add some sources".tl;
      onTap = () {
        context.to(() => ComicSourcePage());
      };
    } else {
      msg += "Please check your settings".tl;
      onTap = addPage;
    }
    return NetworkError(
      message: msg,
      retry: onTap,
      withAppbar: false,
      buttonText: "Manage".tl,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (categories.isEmpty) {
      return buildEmpty();
    }

    final selectorItems = categories.map(buildSelectorItem).toList();
    return Material(
      child: Column(
        children: [
          AppTabBar(
            controller: controller,
            key: PageStorageKey(categories.toString()),
            tabs: List.generate(
              categories.length,
              (index) => Tab(
                text:
                    selectorItems[index].subtitle ?? selectorItems[index].label,
                key: Key(categories[index]),
              ),
            ),
            trailing: TabPageSelectorButton(
              controller: controller,
              items: selectorItems,
              onManage: addPage,
            ),
          ).paddingTop(context.padding.top),
          Expanded(
            child: TabBarView(
              controller: controller,
              children: categories.map((e) => _CategoryPage(e)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

typedef ClickTagCallback = void Function(String, String?);

class _CategoryPage extends StatelessWidget {
  const _CategoryPage(this.category);

  final String category;

  CategoryData get data => getCategoryDataWithKey(category);

  String findComicSourceKey() {
    for (var source in ComicSource.all()) {
      if (source.categoryData?.key == category) {
        return source.key;
      }
    }
    return "";
  }

  @override
  Widget build(BuildContext context) {
    var children = <Widget>[];
    if (data.enableRankingPage || data.buttons.isNotEmpty) {
      children.add(buildTitle(context, data.title));
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (data.enableRankingPage)
                buildTag("Ranking".tl, () {
                  context.to(() => RankingPage(categoryKey: data.key));
                }),
              for (var buttonData in data.buttons)
                buildTag(buttonData.label.tl, buttonData.onTap),
            ],
          ),
        ),
      );
    }

    for (var part in data.categories) {
      if (part.enableRandom) {
        children.add(
          StatefulBuilder(
            builder: (context, updater) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTitleWithRefresh(
                    context,
                    part.title,
                    () => updater(() {}),
                  ),
                  buildTags(part.categories),
                ],
              );
            },
          ),
        );
      } else {
        children.add(buildTitle(context, part.title));
        children.add(buildTags(part.categories));
      }
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget buildTitle(BuildContext context, String title) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            title.tl,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget buildTitleWithRefresh(
    BuildContext context,
    String title,
    void Function() onRefresh,
  ) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.tl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            onPressed: onRefresh,
            tooltip: "Refresh".tl,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ).paddingLeft(16).paddingRight(8),
    );
  }

  Widget buildTags(List<CategoryItem> categories) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List<Widget>.generate(
          categories.length,
          (index) => buildCategory(categories[index]),
        ),
      ),
    );
  }

  Widget buildCategory(CategoryItem c) {
    return buildTag(c.label, () {
      var context = App.mainNavigatorKey!.currentContext!;
      c.target.jump(context);
    });
  }

  Widget buildTag(String label, VoidCallback onClick) {
    return Builder(
      builder: (context) {
        return Material(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          color: context.colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onClick,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool get enableTranslation => App.locale.languageCode == 'zh';
}
