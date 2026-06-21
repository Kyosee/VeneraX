import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/read_later_page.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

import 'local_comics_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool editMode = false;

  late List<HomeSectionConfig> layout;

  @override
  void initState() {
    layout = normalizeHomeLayout();
    appdata.settings.addListener(_onSettingsChanged);
    super.initState();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    // Re-read the layout when settings change (e.g. edited from the Appearance
    // settings page, or a new layout arrived via WebDAV sync download). Skip
    // while editing so an incoming sync doesn't yank the list out from under
    // the user mid-drag.
    if (editMode) return;
    var next = normalizeHomeLayout();
    if (!_sameLayout(next, layout) && mounted) {
      setState(() => layout = next);
    }
  }

  static bool _sameLayout(
    List<HomeSectionConfig> a,
    List<HomeSectionConfig> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].visible != b[i].visible) return false;
    }
    return true;
  }

  /// Maps a section id to its real widget. Each gets a [ValueKey] so reordering
  /// preserves the per-section [State] (these widgets hold data and listeners).
  Widget _sectionWidget(String id) {
    return switch (id) {
      'history' => const _History(key: ValueKey('history')),
      'readLater' => const _ReadLater(key: ValueKey('readLater')),
      'local' => const _Local(key: ValueKey('local')),
      'followUpdates' => const FollowUpdatesWidget(key: ValueKey('followUpdates')),
      'comicSource' => const _ComicSourceWidget(key: ValueKey('comicSource')),
      'imageFavorites' => const ImageFavorites(key: ValueKey('imageFavorites')),
      _ => const SliverToBoxAdapter(child: SizedBox.shrink()),
    };
  }

  void _enterEditMode() {
    setState(() {
      layout = normalizeHomeLayout();
      editMode = true;
    });
  }

  void _exitEditMode() {
    saveHomeLayout(layout);
    setState(() => editMode = false);
  }

  void _resetLayout() {
    setState(() => layout = defaultHomeLayout());
  }

  void _toggleVisible(String id) {
    setState(() {
      layout = layout
          .map((e) => e.id == id ? e.copyWith(visible: !e.visible) : e)
          .toList();
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      var item = layout.removeAt(oldIndex);
      layout.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    var slivers = <Widget>[
      SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
      const _SearchBar(),
    ];
    if (editMode) {
      slivers.add(_HomeEditBanner(onDone: _exitEditMode, onReset: _resetLayout));
      slivers.add(
        SliverReorderableList(
          itemCount: layout.length,
          onReorder: _onReorder,
          itemBuilder: (context, index) {
            var config = layout[index];
            var meta = homeSectionMetaById(config.id)!;
            return _HomeEditTile(
              key: ValueKey('edit-${config.id}'),
              meta: meta,
              visible: config.visible,
              index: index,
              onToggle: () => _toggleVisible(config.id),
            );
          },
        ),
      );
    } else {
      var visible = layout.where((e) => e.visible).toList();
      if (visible.isEmpty) {
        slivers.add(_AllHiddenHint(onEdit: _enterEditMode));
      } else {
        for (var config in visible) {
          slivers.add(_sectionWidget(config.id));
        }
      }
    }
    slivers.add(SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)));

    Widget widget = GestureDetector(
      onLongPress: editMode ? null : _enterEditMode,
      child: SmoothCustomScrollView(slivers: slivers),
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }
}

class _HomeEditBanner extends StatelessWidget {
  const _HomeEditBanner({required this.onDone, required this.onReset});

  final VoidCallback onDone;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer.toOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text('Edit Home'.tl, style: ts.s16)),
            TextButton(
              onPressed: onReset,
              child: Text('Reset to Default'.tl),
            ),
            FilledButton(onPressed: onDone, child: Text('Done'.tl)),
          ],
        ),
      ),
    );
  }
}

class _HomeEditTile extends StatelessWidget {
  const _HomeEditTile({
    super.key,
    required this.meta,
    required this.visible,
    required this.index,
    required this.onToggle,
  });

  final HomeSectionMeta meta;
  final bool visible;
  final int index;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Opacity(
        opacity: visible ? 1 : 0.45,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(meta.icon, size: 22),
            const SizedBox(width: 16),
            Expanded(child: Text(meta.titleKey.tl, style: ts.s16)),
            IconButton(
              tooltip: visible ? 'Hide'.tl : 'Show'.tl,
              icon: Icon(
                visible ? Icons.visibility : Icons.visibility_off_outlined,
              ),
              onPressed: onToggle,
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllHiddenHint extends StatelessWidget {
  const _AllHiddenHint({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
        child: Center(
          child: TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.dashboard_customize_outlined),
            label: Text('All sections hidden'.tl),
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    final double height = App.isMobile ? 52 : 46;
    return SliverToBoxAdapter(
      child: Container(
        height: height,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Material(
                color: context.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(32),
                child: InkWell(
                  borderRadius: BorderRadius.circular(32),
                  onTap: () {
                    context.to(() => const SearchPage());
                  },
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      const Icon(Icons.search),
                      const SizedBox(width: 8),
                      Text('Search'.tl, style: ts.s16),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
            _SyncButton(height: height),
          ],
        ),
      ),
    );
  }
}

class _SyncButton extends StatefulWidget {
  const _SyncButton({required this.height});

  final double height;

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    DataSync().addListener(update);
    WidgetsBinding.instance.addObserver(this);
    lastCheck = DateTime.now();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    super.dispose();
    DataSync().removeListener(update);
    WidgetsBinding.instance.removeObserver(this);
  }

  late DateTime lastCheck;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (DateTime.now().difference(lastCheck) > const Duration(minutes: 10)) {
        lastCheck = DateTime.now();
        DataSync().downloadData();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DataSync().isEnabled) {
      return const SizedBox.shrink();
    }

    var syncing = DataSync().isUploading || DataSync().isDownloading;
    var hasError = DataSync().lastError != null;

    Widget icon;
    if (syncing) {
      icon = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (hasError) {
      icon = Icon(Icons.sync_problem, color: context.colorScheme.error);
    } else {
      icon = const Icon(Icons.sync);
    }

    var tooltip = syncing
        ? 'Syncing Data'.tl
        : (hasError ? 'Error'.tl : 'Sync Data'.tl);

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: context.colorScheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: syncing
              ? null
              : () {
                  if (hasError) {
                    showDialogMessage(
                      App.rootContext,
                      "Error".tl,
                      DataSync().lastError!,
                    );
                  } else {
                    DataSync().syncData();
                  }
                },
          child: Tooltip(
            message: tooltip,
            child: SizedBox(
              width: widget.height,
              height: widget.height,
              child: Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }
}

class _History extends StatefulWidget {
  const _History({super.key});

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  late List<History> history;
  late int count;

  void onHistoryChange() {
    if (!HistoryManager().isInitialized) return;
    if (mounted) {
      setState(() {
        history = HistoryManager().getRecent();
        count = HistoryManager().count();
      });
    }
  }

  @override
  void initState() {
    history = HistoryManager().getRecent();
    count = HistoryManager().count();
    HistoryManager().addListener(onHistoryChange);
    DataSync().addListener(onHistoryChange);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onHistoryChange);
    DataSync().removeListener(onHistoryChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const HistoryPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Text('History'.tl, style: ts.s18),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(count.toString(), style: ts.s12),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (history.isNotEmpty)
                SizedBox(
                  height: 136,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final heroID = history[index].id.hashCode;
                      return SimpleComicTile(
                        comic: history[index],
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: history[index].id,
                              sourceKey: history[index].type.sourceKey,
                              cover: history[index].cover,
                              title: history[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ).paddingHorizontal(8).paddingBottom(16),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadLater extends StatefulWidget {
  const _ReadLater({super.key});

  @override
  State<_ReadLater> createState() => _ReadLaterState();
}

class _ReadLaterState extends State<_ReadLater> {
  late List<ReadLaterItem> items;
  late int count;

  void onReadLaterChange() {
    if (!ReadLaterManager().isInitialized) return;
    if (mounted) {
      setState(() {
        items = ReadLaterManager().getRecent();
        count = ReadLaterManager().count;
      });
    }
  }

  @override
  void initState() {
    items = ReadLaterManager().getRecent();
    count = ReadLaterManager().count;
    ReadLaterManager().addListener(onReadLaterChange);
    DataSync().addListener(onReadLaterChange);
    super.initState();
  }

  @override
  void dispose() {
    ReadLaterManager().removeListener(onReadLaterChange);
    DataSync().removeListener(onReadLaterChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return _readLaterBody(context);
  }

  Widget _readLaterBody(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _readLaterInk(context),
      ),
    );
  }

  Widget _readLaterInk(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        context.to(() => const ReadLaterPage());
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                Text('Read Later'.tl, style: ts.s18),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(count.toString(), style: ts.s12),
                ),
                const Spacer(),
                const Icon(Icons.arrow_right),
              ],
            ),
          ).paddingHorizontal(16),
          SizedBox(
            height: 136,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final heroID = items[index].id.hashCode;
                return SimpleComicTile(
                  comic: items[index],
                  heroID: heroID,
                ).paddingHorizontal(8).paddingVertical(2);
              },
            ),
          ).paddingHorizontal(8).paddingBottom(16),
        ],
      ),
    );
  }
}

class _Local extends StatefulWidget {
  const _Local({super.key});

  @override
  State<_Local> createState() => _LocalState();
}

class _LocalState extends State<_Local> {
  late List<LocalComic> local;
  late int count;

  void onLocalComicsChange() {
    setState(() {
      local = LocalManager().getRecent();
      count = LocalManager().count;
    });
  }

  @override
  void initState() {
    local = LocalManager().getRecent();
    count = LocalManager().count;
    LocalManager().addListener(onLocalComicsChange);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(onLocalComicsChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const LocalComicsPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Local'.tl, style: ts.s18)),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(count.toString(), style: ts.s12),
                    ),
                    const Spacer(),
                    _LocalImportButton(onPressed: import),
                    if (LocalManager().hasComicsWithImages())
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _LocalExportButton(
                          onPressed: () {
                            context.to(() => const LocalComicsPage());
                          },
                        ),
                      ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (local.isNotEmpty)
                SizedBox(
                  height: 136,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: local.length,
                    itemBuilder: (context, index) {
                      final heroID = local[index].id.hashCode;
                      return SimpleComicTile(
                        comic: local[index],
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: local[index].id,
                              sourceKey: local[index].sourceKey,
                              cover: local[index].cover,
                              title: local[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ).paddingHorizontal(8).paddingBottom(16),
              if (LocalManager().downloadingTasks.isNotEmpty)
                Row(
                  children: [
                    Button.outlined(
                      child: Row(
                        children: [
                          if (LocalManager().downloadingTasks.first.isPaused)
                            const Icon(Icons.pause_circle_outline, size: 18)
                          else
                            const _AnimatedDownloadingIcon(),
                          const SizedBox(width: 8),
                          Text(
                            "@a Tasks".tlParams({
                              'a': LocalManager().downloadingTasks.length,
                            }),
                          ),
                        ],
                      ),
                      onPressed: () {
                        showPopUpWidget(context, const DownloadingPage());
                      },
                    ),
                  ],
                ).paddingHorizontal(16).paddingVertical(8),
            ],
          ),
        ),
      ),
    );
  }

  void import() {
    showDialog(
      barrierDismissible: false,
      context: App.rootContext,
      builder: (context) {
        return const ImportComicsWidget();
      },
    );
  }
}

class _LocalImportButton extends StatelessWidget {
  const _LocalImportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "Import".tl,
      child: Material(
        color: context.colorScheme.primary.toOpacity(0.08),
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onPressed,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: context.colorScheme.primary.toOpacity(0.28),
                width: 0.6,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              "Import".tl,
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalExportButton extends StatelessWidget {
  const _LocalExportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "Export".tl,
      child: Material(
        color: context.colorScheme.tertiary.toOpacity(0.08),
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onPressed,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: context.colorScheme.tertiary.toOpacity(0.28),
                width: 0.6,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              "Export".tl,
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.tertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ImportComicsWidget extends StatefulWidget {
  const ImportComicsWidget({super.key});

  @override
  State<ImportComicsWidget> createState() => _ImportComicsWidgetState();
}

class _ImportComicsWidgetState extends State<ImportComicsWidget> {
  int type = 0;

  bool loading = false;

  var key = GlobalKey();

  var height = 200.0;

  var folders = LocalFavoritesManager().folderNames;

  String? selectedFolder;

  bool copyToLocalFolder = true;

  bool cancelled = false;

  @override
  void dispose() {
    loading = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String info = [
      "Select comic files (cbz, zip, 7z, cb7, or .venera_comics).".tl,
      "Select a folder; single/multiple will be detected.".tl,
      "Select an EhViewer database and a download folder.".tl,
      "Scan the current local path and restore the local database.".tl,
    ][type];
    List<String> importMethods = [
      "Import files".tl,
      "Import folder".tl,
      "EhViewer downloads".tl,
      "Restore local downloads".tl,
    ];

    return ContentDialog(
      dismissible: !loading,
      title: "Import Comics".tl,
      content: loading
          ? SizedBox(
              width: 600,
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            )
          : RadioGroup<int>(
              groupValue: type,
              onChanged: (value) {
                setState(() {
                  type = value ?? type;
                  if (type >= 2) {
                    selectedFolder = null;
                  }
                });
              },
              child: Column(
                key: key,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 600),
                  ...List.generate(importMethods.length, (index) {
                    return RadioListTile<int>(
                      title: Text(importMethods[index]),
                      value: index,
                    );
                  }),
                  if (type == 0 || type == 1)
                    ListTile(
                      title: Text("Add to favorites".tl),
                      trailing: Select(
                        current: selectedFolder,
                        values: folders,
                        minWidth: 112,
                        onTap: (v) {
                          setState(() {
                            selectedFolder = folders[v];
                          });
                        },
                      ),
                    ).paddingHorizontal(8),
                  if (!App.isIOS && !App.isMacOS && (type == 0 || type == 1))
                    CheckboxListTile(
                      enabled: true,
                      title: Text("Copy to app local path".tl),
                      value: copyToLocalFolder,
                      onChanged: (v) {
                        setState(() {
                          copyToLocalFolder = !copyToLocalFolder;
                        });
                      },
                    ).paddingHorizontal(8),
                  const SizedBox(height: 8),
                  Text(info).paddingHorizontal(24),
                ],
              ),
            ),
      actions: [
        Button.text(
          child: Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: context.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text("help".tl),
            ],
          ),
          onPressed: () {
            launchUrlString(
              "https://github.com/Kyosee/venera/blob/master/doc/import_comic.md",
            );
          },
        ).fixWidth(90).paddingRight(8),
        Button.filled(
          isLoading: loading,
          onPressed: selectAndImport,
          child: Text("Select".tl),
        ),
      ],
    );
  }

  void selectAndImport() async {
    height = key.currentContext!.size!.height;

    setState(() {
      loading = true;
    });
    // Keep the process alive across backgrounding while a comic import runs
    // (Android only; no-op elsewhere). Started here, on the foreground tap, so
    // the foreground service isn't subject to background-start restrictions.
    // Empty status => the native service shows its localized default body under
    // the localized "Importing comics" title; this flow has no per-item progress.
    BackgroundKeepAlive.instance.update(BackgroundKeepAlive.tagComicImport, '');
    var importer = ImportComic(
      selectedFolder: selectedFolder,
      copyToLocal: copyToLocalFolder,
    );
    bool result;
    try {
      result = switch (type) {
        0 => await importer.files(),
        1 => await _importFolderWithConfirm(importer),
        2 => await importer.ehViewer(),
        3 => await importer.localDownloads(),
        int() => true,
      };
    } finally {
      BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagComicImport);
    }
    if (result) {
      context.pop();
    } else {
      setState(() {
        loading = false;
      });
    }
  }

  Future<bool> _importFolderWithConfirm(ImportComic importer) async {
    final r = await importer.inspectFolder();
    if (r == null) return false;
    if (r.kind == 'venera_comics') {
      return importer.multipleVeneraComicsFromDir(r.dir);
    }
    if (r.kind == 'cbz') {
      return importer.multipleCbzFromDir(r.dir);
    }
    bool asMulti = r.guessMulti;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => ContentDialog(
          title: "Import Folder".tl,
          content: RadioGroup<bool>(
            groupValue: asMulti,
            onChanged: (v) => setLocal(() => asMulti = v ?? asMulti),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("How should this folder be imported?".tl)
                    .paddingHorizontal(16),
                RadioListTile<bool>(
                  title:
                      Text("As a single comic (subfolders are chapters)".tl),
                  value: false,
                ),
                RadioListTile<bool>(
                  title:
                      Text("As multiple comics (each subfolder is one)".tl),
                  value: true,
                ),
              ],
            ),
          ),
          actions: [
            Button.text(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text("Cancel".tl),
            ),
            Button.filled(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text("Import".tl),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return false;
    return importer.directoryAt(r.dir, single: !asMulti);
  }
}

class _ComicSourceWidget extends StatefulWidget {
  const _ComicSourceWidget({super.key});

  @override
  State<_ComicSourceWidget> createState() => _ComicSourceWidgetState();
}

class _ComicSourceWidgetState extends State<_ComicSourceWidget> {
  late List<String> comicSources;

  void onComicSourceChange() {
    setState(() {
      comicSources = ComicSource.all().map((e) => e.name).toList();
    });
  }

  @override
  void initState() {
    comicSources = ComicSource.all().map((e) => e.name).toList();
    ComicSourceManager().addListener(onComicSourceChange);
    super.initState();
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(onComicSourceChange);
    super.dispose();
  }

  int get _availableUpdates {
    int c = 0;
    ComicSourceManager().availableUpdates.forEach((key, version) {
      var source = ComicSource.find(key);
      if (source != null) {
        if (compareSemVer(version, source.version)) {
          c++;
        }
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const ComicSourcePage());
          },
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Comic Source'.tl,
                    style: ts.s18,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                if (_availableUpdates > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context).colorScheme.primaryContainer,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.update,
                          color: context.colorScheme.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "@c updates".tlParams({'c': _availableUpdates}),
                          style: ts.s14.withColor(context.colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(comicSources.length.toString(), style: ts.s12),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_right),
              ],
            ),
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

class _AnimatedDownloadingIcon extends StatefulWidget {
  const _AnimatedDownloadingIcon();

  @override
  State<_AnimatedDownloadingIcon> createState() =>
      __AnimatedDownloadingIconState();
}

class __AnimatedDownloadingIconState extends State<_AnimatedDownloadingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      lowerBound: -1,
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Transform.translate(
            offset: Offset(0, 18 * _controller.value),
            child: Icon(
              Icons.arrow_downward,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
    );
  }
}

class ImageFavorites extends StatefulWidget {
  const ImageFavorites({super.key});

  @override
  State<ImageFavorites> createState() => _ImageFavoritesState();
}

class _ImageFavoritesState extends State<ImageFavorites> {
  ImageFavoritesComputed? imageFavoritesCompute;

  /// Ordered, visible-filtered tab ids (subset of 'tags'/'authors'/'comics').
  late List<String> tabs = _visibleTabs();

  /// Currently selected tab id. Defaults to the first visible tab.
  late String currentTab = tabs.isNotEmpty ? tabs.first : 'tags';

  static List<String> _visibleTabs() => normalizeImageFavoritesTabs()
      .where((e) => e.visible)
      .map((e) => e.id)
      .toList();

  void _reloadTabs() {
    var next = _visibleTabs();
    if (!_sameIds(next, tabs) && mounted) {
      setState(() {
        tabs = next;
        if (!tabs.contains(currentTab)) {
          currentTab = tabs.isNotEmpty ? tabs.first : 'tags';
        }
      });
    }
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void refreshImageFavorites() async {
    if (!HistoryManager().isInitialized) return;
    try {
      imageFavoritesCompute =
          await ImageFavoriteManager.computeImageFavorites();
      if (mounted) {
        setState(() {});
      }
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
    }
  }

  @override
  void initState() {
    refreshImageFavorites();
    ImageFavoriteManager().addListener(refreshImageFavorites);
    DataSync().addListener(refreshImageFavorites);
    appdata.settings.addListener(_reloadTabs);
    super.initState();
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(refreshImageFavorites);
    DataSync().removeListener(refreshImageFavorites);
    appdata.settings.removeListener(_reloadTabs);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool hasData =
        imageFavoritesCompute != null && !imageFavoritesCompute!.isEmpty;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const ImageFavoritesPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Image Favorites'.tl, style: ts.s18)),
                    if (hasData)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          imageFavoritesCompute!.count.toString(),
                          style: ts.s12,
                        ),
                      ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (hasData)
                _ImageFavoritesTabBar(
                  tabs: tabs,
                  current: currentTab,
                  onTap: _selectTab,
                ).paddingHorizontal(16),
              if (hasData) const SizedBox(height: 8),
              if (hasData)
                buildChart(switch (currentTab) {
                  'tags' => imageFavoritesCompute!.tags,
                  'authors' => imageFavoritesCompute!.authors,
                  'comics' => imageFavoritesCompute!.comics,
                  _ => [],
                }).paddingHorizontal(16).paddingBottom(16),
            ],
          ),
        ),
      ),
    );
  }

  void _selectTab(String id) async {
    if (currentTab == id) return;
    setState(() {
      currentTab = id;
    });
    await Future.delayed(const Duration(milliseconds: 20));
    if (!mounted) return;
    var scrollController = ScrollState.of(context).controller;
    scrollController.animateTo(
      scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  Widget buildChart(List<TextWithCount> data) {
    if (data.isEmpty) {
      return const SizedBox();
    }
    var maxCount = data.map((e) => e.count).reduce((a, b) => a > b ? a : b);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 164),
      child: SingleChildScrollView(
        child: Column(
          key: ValueKey(currentTab),
          children: data.map((e) {
            return _ChartLine(
              text: e.text,
              count: e.count,
              maxCount: maxCount,
              enableTranslation: currentTab != 'comics',
              onTap: (text) {
                context.to(() => ImageFavoritesPage(initialKeyword: text));
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _ImageFavoritesTabBar extends StatelessWidget {
  const _ImageFavoritesTabBar({
    required this.tabs,
    required this.current,
    required this.onTap,
  });

  final List<String> tabs;
  final String current;
  final void Function(String id) onTap;

  static String _label(String id) => switch (id) {
        'tags' => "Tags".tl,
        'authors' => "Authors".tl,
        'comics' => "Comics".tl,
        _ => id,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tabs.map((id) {
          var selected = id == current;
          return Expanded(
            child: InkWell(
              onTap: () => onTap(id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: ts.s16.copyWith(
                          color: selected
                              ? context.colorScheme.primary
                              : context.colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                        child: Text(_label(id), textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 3,
                    decoration: BoxDecoration(
                      color: selected
                          ? context.colorScheme.primary
                          : Colors.transparent,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ChartLine extends StatefulWidget {
  const _ChartLine({
    required this.text,
    required this.count,
    required this.maxCount,
    required this.enableTranslation,
    this.onTap,
  });

  final String text;

  final int count;

  final int maxCount;

  final bool enableTranslation;

  final void Function(String text)? onTap;

  @override
  State<_ChartLine> createState() => __ChartLineState();
}

class __ChartLineState extends State<_ChartLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var text = widget.text;
    var enableTranslation =
        App.locale.countryCode == 'CN' && widget.enableTranslation;
    if (enableTranslation) {
      text = text.translateTagsToCN;
    }
    if (widget.enableTranslation && text.contains(':')) {
      text = text.split(':').last;
    }
    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () {
            widget.onTap?.call(widget.text);
          },
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)
              .paddingHorizontal(4)
              .toAlign(Alignment.centerLeft)
              .fixWidth(context.width > 600 ? 120 : 80)
              .fixHeight(double.infinity),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constrains) {
              var width = constrains.maxWidth * widget.count / widget.maxCount;
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Container(
                    width: width * _controller.value,
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        colors: context.isDarkMode
                            ? [Colors.blue.shade800, Colors.blue.shade500]
                            : [Colors.blue.shade300, Colors.blue.shade600],
                      ),
                    ),
                  ).toAlign(Alignment.centerLeft);
                },
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(
          widget.count.toString(),
          style: ts.s12,
        ).fixWidth(context.width > 600 ? 60 : 30),
      ],
    ).fixHeight(28);
  }
}
