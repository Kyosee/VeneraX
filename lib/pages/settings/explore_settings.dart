part of 'settings_page.dart';

class ExploreSettings extends StatefulWidget {
  const ExploreSettings({super.key, this.section});

  final String? section;

  @override
  State<ExploreSettings> createState() => _ExploreSettingsState();
}

class _ExploreSettingsState extends State<ExploreSettings> {
  Future<void> _openSection(String section) async {
    await context.to(() => ExploreSettings(section: section));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsPageView(
      title: 'Browsing & filters',
      description: 'Adjust comic cards and choose the content you see',
      section:
          widget.section ??
          _settingsSectionForTitle(4, _SettingsJumpScope.targetOf(context)),
      onOpenSection: _openSection,
      sections: [
        _SettingsSection(
          title: 'Browsing',
          common: true,
          children: [
            SelectSetting(
              title: "Display mode of comic tile".tl,
              settingKey: "comicDisplayMode",
              optionTranslation: {
                "detailed": "Detailed".tl,
                "brief": "Brief".tl,
              },
            ),
            _SliderSetting(
              title: "Size of comic tile".tl,
              settingsIndex: "comicTileScale",
              interval: 0.05,
              min: 0.5,
              max: 1.5,
            ),
            SelectSetting(
              title: "Display mode of comic list".tl,
              settingKey: "comicListDisplayMode",
              optionTranslation: {
                "paging": "Paging".tl,
                "Continuous": "Continuous".tl,
              },
            ),
            _SwitchSetting(
              title: "Reverse default chapter order".tl,
              settingKey: "reverseChapterOrder",
            ),
          ],
        ),
        _SettingsSection(
          title: 'Comic sources',
          common: true,
          children: [
            _SettingsLink(
              title: 'Comic Source',
              icon: Icons.extension_outlined,
              onTap: () => context.to(() => const ComicSourcePage()),
            ),
            _SettingsLink(
              title: 'Source Libraries',
              icon: Icons.library_books_outlined,
              onTap: () => context.to(() => const SourceLibrariesPage()),
            ),
          ],
        ),
        _SettingsSection(
          title: 'Card details',
          subtitle: 'Favorites, reading history, collections and page counts',
          icon: Icons.style_outlined,
          children: [
            _SwitchSetting(
              title: "Show favorite status on comic tile".tl,
              settingKey: "showFavoriteStatusOnTile",
            ),
            _SwitchSetting(
              title: "Show history on comic tile".tl,
              settingKey: "showHistoryStatusOnTile",
            ),
            _SwitchSetting(
              title: "Show read later status on comic tile".tl,
              settingKey: "showReadLaterStatusOnTile",
            ),
            _SwitchSetting(
              title: "Show collection status on comic tile".tl,
              settingKey: "showCollectionStatusOnTile",
            ),
            _SwitchSetting(
              title: "Show page count on comic tile".tl,
              settingKey: "showPageCountOnTile",
            ),
          ],
        ),
        _SettingsSection(
          title: 'Reading history',
          icon: Icons.history,
          children: [
            _SwitchSetting(
              title:
                  'Clear reading progress when deleting a single history entry'
                      .tl,
              settingKey: 'clearReadingProgressOnSingleHistoryDelete',
              subtitle:
                  'Also clear the saved page and read chapters when manually deleting one history entry. Batch deletion, clearing all history and automatic cleanup keep reading progress. Reading time statistics are kept.'
                      .tl,
            ),
            SelectSetting(
              title: "Auto clean reading history".tl,
              settingKey: "autoCleanHistoryDays",
              help:
                  "Automatically delete reading history older than the selected period when the app starts."
                      .tl,
              optionTranslation: {
                "0": "Never".tl,
                "7": "7 days".tl,
                "30": "30 days".tl,
                "90": "90 days".tl,
                "180": "180 days".tl,
                "365": "365 days".tl,
              },
            ),
          ],
        ),
        _SettingsSection(
          title: 'Search preferences',
          subtitle: 'Default search, language filters and comic sources',
          icon: Icons.search,
          children: [
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
            ),
            SelectSetting(
              title: "Auto Language Filters".tl,
              settingKey: "autoAddLanguageFilter",
              optionTranslation: {
                'none': "None".tl,
                'chinese': "Chinese",
                'english': "English",
                'japanese': "Japanese",
              },
            ),
            _PopupWindowSetting(
              title: "Language Filter Sources".tl,
              subtitle:
                  "Only add sources whose search supports the language: syntax. Searches on these sources get the selected language added, e.g. abc becomes abc language:chinese."
                      .tl,
              builder: setLanguageFilterSourcesWidget,
            ),
            _PopupWindowSetting(
              title: "Search Sources".tl,
              builder: setSearchSourcesWidget,
            ),
          ],
        ),
        _SettingsSection(
          title: 'Browsing pages',
          subtitle:
              'Explore, categories, network favorites and the initial page',
          icon: Icons.auto_stories_outlined,
          children: [
            _PopupWindowSetting(
              title: "Explore Pages".tl,
              builder: setExplorePagesWidget,
            ),
            _PopupWindowSetting(
              title: "Category Pages".tl,
              builder: setCategoryPagesWidget,
            ),
            _PopupWindowSetting(
              title: "Network Favorite Pages".tl,
              builder: setFavoritesPagesWidget,
            ),
            SelectSetting(
              title: "Initial Page".tl,
              settingKey: "initialPage",
              optionTranslation: {
                '0': "Home Page".tl,
                '1': "Favorites Page".tl,
                '2': "Explore Page".tl,
                '3': "Categories Page".tl,
              },
            ),
          ],
        ),
        _SettingsSection(
          title: 'Content filters',
          subtitle: 'Block comic keywords, tags and comment keywords',
          icon: Icons.filter_alt_outlined,
          children: [
            _PopupWindowSetting(
              title: "Keyword blocking".tl,
              builder: () => _ManageBlockListView(
                settingKey: "blockedWords",
                title: "Keyword blocking".tl,
                hint:
                    "Hides comics whose title, subtitle or description contains a keyword."
                        .tl,
              ),
            ),
            _PopupWindowSetting(
              title: "Tag blocking".tl,
              builder: () => _ManageBlockListView(
                settingKey: "blockedTags",
                title: "Tag blocking".tl,
                hint:
                    "Hides comics carrying a matching tag. A partial tag works, and tags are matched in the app's language."
                        .tl,
              ),
            ),
            _PopupWindowSetting(
              title: "Comment keyword blocking".tl,
              builder: () => _ManageBlockListView(
                settingKey: "blockedCommentWords",
                title: "Comment keyword blocking".tl,
                hint: "Hides comments containing a keyword.".tl,
              ),
            ),
          ],
        ),
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

Widget setLanguageFilterSourcesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.searchPageData != null) {
      pages[c.key] = c.name;
    }
  }
  return _MultiPagesFilter(
    title: "Language Filter Sources".tl,
    settingsIndex: "languageFilterSources",
    pages: pages,
  );
}
