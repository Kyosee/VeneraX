part of 'settings_page.dart';

class ExploreSettings extends StatefulWidget {
  const ExploreSettings({super.key});

  @override
  State<ExploreSettings> createState() => _ExploreSettingsState();
}

class _ExploreSettingsState extends State<ExploreSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Explore".tl)),
        SelectSetting(
          title: "Display mode of comic tile".tl,
          settingKey: "comicDisplayMode",
          optionTranslation: {"detailed": "Detailed".tl, "brief": "Brief".tl},
        ).toSliver(),
        _SliderSetting(
          title: "Size of comic tile".tl,
          settingsIndex: "comicTileScale",
          interval: 0.05,
          min: 0.5,
          max: 1.5,
        ).toSliver(),
        _PopupWindowSetting(
          title: "Explore Pages".tl,
          builder: setExplorePagesWidget,
        ).toSliver(),
        _PopupWindowSetting(
          title: "Category Pages".tl,
          builder: setCategoryPagesWidget,
        ).toSliver(),
        _PopupWindowSetting(
          title: "Network Favorite Pages".tl,
          builder: setFavoritesPagesWidget,
        ).toSliver(),
        _PopupWindowSetting(
          title: "Search Sources".tl,
          builder: setSearchSourcesWidget,
        ).toSliver(),
        _SwitchSetting(
          title: "Show favorite status on comic tile".tl,
          settingKey: "showFavoriteStatusOnTile",
        ).toSliver(),
        _SwitchSetting(
          title: "Show history on comic tile".tl,
          settingKey: "showHistoryStatusOnTile",
        ).toSliver(),
        _SwitchSetting(
          title: "Show read later status on comic tile".tl,
          settingKey: "showReadLaterStatusOnTile",
        ).toSliver(),
        _SwitchSetting(
          title: "Reverse default chapter order".tl,
          settingKey: "reverseChapterOrder",
        ).toSliver(),
        _PopupWindowSetting(
          title: "Keyword blocking".tl,
          builder: () => _ManageBlockListView(
            settingKey: "blockedWords",
            title: "Keyword blocking".tl,
            hint: "Hides comics whose title, subtitle or description contains a keyword.".tl,
          ),
        ).toSliver(),
        _PopupWindowSetting(
          title: "Tag blocking".tl,
          builder: () => _ManageBlockListView(
            settingKey: "blockedTags",
            title: "Tag blocking".tl,
            hint: "Hides comics carrying a matching tag. A partial tag works, and tags are matched in the app's language.".tl,
          ),
        ).toSliver(),
        _PopupWindowSetting(
          title: "Comment keyword blocking".tl,
          builder: () => _ManageBlockListView(
            settingKey: "blockedCommentWords",
            title: "Comment keyword blocking".tl,
            hint: "Hides comments containing a keyword.".tl,
          ),
        ).toSliver(),
        SelectSetting(
          title: "Default Search Target".tl,
          settingKey: "defaultSearchTarget",
          optionTranslation: {
            '_aggregated_': "Aggregated".tl,
            ...(() {
              var map = <String, String>{};
              for (var c in ComicSource.all()) {
                map[c.key] = c.name;
              }
              return map;
            }()),
          },
        ).toSliver(),
        SelectSetting(
          title: "Auto Language Filters".tl,
          settingKey: "autoAddLanguageFilter",
          optionTranslation: {
            'none': "None".tl,
            'chinese': "Chinese",
            'english': "English",
            'japanese': "Japanese",
          },
        ).toSliver(),
        SelectSetting(
          title: "Initial Page".tl,
          settingKey: "initialPage",
          optionTranslation: {
            '0': "Home Page".tl,
            '1': "Favorites Page".tl,
            '2': "Explore Page".tl,
            '3': "Categories Page".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Display mode of comic list".tl,
          settingKey: "comicListDisplayMode",
          optionTranslation: {
            "paging": "Paging".tl,
            "Continuous": "Continuous".tl,
          },
        ).toSliver(),
      ],
    );
  }
}

/// Editor for one of the blocklist settings (comic keywords, comic tags,
/// comment keywords). [hint] explains what the list does, since "keyword" and
/// "tag" blocking match differently and the distinction is otherwise invisible.
class _ManageBlockListView extends StatefulWidget {
  const _ManageBlockListView({
    required this.settingKey,
    required this.title,
    required this.hint,
  });

  final String settingKey;

  final String title;

  final String hint;

  @override
  State<_ManageBlockListView> createState() => _ManageBlockListViewState();
}

class _ManageBlockListViewState extends State<_ManageBlockListView> {
  /// Repairs the setting if a backup from another version left something that
  /// isn't a list under this key, so the editor can't be opened into a crash.
  List get _entries {
    var value = appdata.settings[widget.settingKey];
    if (value is! List) {
      value = <String>[];
      appdata.settings[widget.settingKey] = value;
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: widget.title,
      tailing: [
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: Text("Add".tl),
          onPressed: add,
        ),
      ],
      body: ListView.builder(
        itemCount: _entries.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Text(
              widget.hint,
              style: ts.s12.withColor(context.colorScheme.outline),
            ).paddingHorizontal(16).paddingVertical(12);
          }
          var entryIndex = index - 1;
          return ListTile(
            title: Text(_entries[entryIndex].toString()),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                _entries.removeAt(entryIndex);
                appdata.saveData();
                setState(() {});
              },
            ),
          );
        },
      ),
    );
  }

  void add() {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var controller = TextEditingController();
        String? error;
        return StatefulBuilder(
          builder: (context, setState) {
            void submit() {
              var text = controller.text.trim();
              if (text.isEmpty) {
                context.pop();
                return;
              }
              if (_entries.contains(text)) {
                setState(() {
                  error = "Keyword already exists".tl;
                });
                return;
              }
              _entries.add(text);
              appdata.saveData();
              this.setState(() {});
              context.pop();
            }

            return ContentDialog(
              title: "Add keyword".tl,
              content: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  label: Text("Keyword".tl),
                  errorText: error,
                ),
                onChanged: (s) {
                  if (error != null) {
                    setState(() {
                      error = null;
                    });
                  }
                },
                onSubmitted: (_) => submit(),
              ).paddingHorizontal(12),
              actions: [
                Button.filled(onPressed: submit, child: Text("Add".tl)),
              ],
            );
          },
        );
      },
    );
  }
}

Widget setExplorePagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    for (var page in c.explorePages) {
      pages[page.title] = page.title.ts(c.key);
    }
  }
  return _MultiPagesFilter(
    title: "Explore Pages".tl,
    settingsIndex: "explore_pages",
    pages: pages,
  );
}

Widget setCategoryPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.categoryData != null) {
      pages[c.categoryData!.key] = c.categoryData!.title;
    }
  }
  return _MultiPagesFilter(
    title: "Category Pages".tl,
    settingsIndex: "categories",
    pages: pages,
  );
}

Widget setFavoritesPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.favoriteData != null) {
      pages[c.favoriteData!.key] = c.favoriteData!.title;
    }
  }
  return _MultiPagesFilter(
    title: "Network Favorite Pages".tl,
    settingsIndex: "favorites",
    pages: pages,
  );
}

Widget setSearchSourcesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.searchPageData != null) {
      pages[c.key] = c.name;
    }
  }
  return _MultiPagesFilter(
    title: "Search Sources".tl,
    settingsIndex: "searchSources",
    pages: pages,
  );
}

