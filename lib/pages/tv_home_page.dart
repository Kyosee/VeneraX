import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/pages/settings/tv_pairing_page.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/translations.dart';

enum _Shelf { home, favorites, history, settings, local, later }

class TvHomePage extends StatefulWidget {
  const TvHomePage({super.key});

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> with RouteAware {
  _Shelf shelf = _Shelf.home;
  final selectedFolders = <String>{};
  static const labels = [
    'Home',
    'Favorites',
    'History',
    'Settings',
    'Local comics',
    'Read later',
  ];
  static const icons = [
    Icons.home_outlined,
    Icons.bookmark_outline,
    Icons.history,
    Icons.settings_outlined,
    Icons.folder_outlined,
    Icons.watch_later_outlined,
  ];
  late final stores = Listenable.merge([
    HistoryManager(),
    LocalFavoritesManager(),
    ReadLaterManager(),
    App.local,
    appdata.settings,
    ComicSourceManager(),
  ]);
  bool importing = false;

  late Future<List<_TvEntry>> entries;
  final cardFocus = FocusNode(debugLabel: 'TV shelf return card');
  (ComicType, String)? returnCard;
  bool openedCard = false;
  bool restoreCard = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) App.rootRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    if (!openedCard) return;
    openedCard = false;
    setState(() => restoreCard = true);
  }

  void rememberCard(_TvEntry item) {
    setState(() {
      returnCard = (item.type, item.comic.id);
      openedCard = true;
      restoreCard = false;
    });
  }

  void focusReturnedCard() {
    if (!restoreCard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !restoreCard ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final card = cardFocus.context;
      if (card == null || !cardFocus.canRequestFocus) return;
      restoreCard = false;
      cardFocus.requestFocus();
      Scrollable.ensureVisible(
        card,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    // Shared comic tiles navigate through the main navigator on every platform.
    App.mainNavigatorKey = App.rootNavigatorKey;
    entries = loadEntries();
    stores.addListener(refresh);
  }

  @override
  void dispose() {
    App.rootRouteObserver.unsubscribe(this);
    cardFocus.dispose();
    stores.removeListener(refresh);
    if (App.mainNavigatorKey == App.rootNavigatorKey) {
      App.mainNavigatorKey = null;
    }
    super.dispose();
  }

  void refresh() => setState(() {
    entries = loadEntries();
  });

  void select(_Shelf value) {
    returnCard = null;
    openedCard = false;
    restoreCard = false;
    shelf = value;
    refresh();
  }

  Future<List<_TvEntry>> loadEntries() async {
    final current = shelf;
    final favorites = LocalFavoritesManager();
    selectedFolders.retainAll(favorites.folderNames);
    final comics = switch (current) {
      _Shelf.home => HistoryManager().getRecent(),
      _Shelf.history => await HistoryManager().getAllAsync(),
      _Shelf.favorites => await favorites.getComicsInAsync(
        selectedFolders.isEmpty
            ? favorites.folderNames
            : selectedFolders.toList(),
      ),
      _Shelf.local => App.local.getComics(LocalSortType.defaultSort),
      _Shelf.later => ReadLaterManager().getAll(),
      _Shelf.settings => <Comic>[],
    };
    final items = <_TvEntry>[];
    final localItems = <_TvEntry>[];
    for (final comic in comics) {
      final item = _TvEntry(comic);
      if (!item.visible) continue;
      items.add(item);
      if (!item.canRead && item.local != null) localItems.add(item);
    }
    final statuses = await loadLocalComicStatuses([
      for (final item in localItems) item.local!,
    ]);
    for (var i = 0; i < statuses.length; i++) {
      localItems[i].onDisk = statuses[i] == LocalComicStatus.downloaded;
    }
    return current == _Shelf.home
        ? items.where((item) => item.canRead).toList()
        : items;
  }

  void showUnavailable() =>
      context.showMessage(message: 'This comic is no longer available'.tl);

  Future<void> read(_TvEntry item) async {
    final local = item.resolveLocal();
    if (local != null) {
      final status = (await loadLocalComicStatuses([local])).single;
      if (!mounted) return;
      if (status == LocalComicStatus.downloaded) {
        rememberCard(item);
        local.read();
        return;
      }
    }
    if (item.type.comicSource?.loadComicInfo == null) {
      showUnavailable();
      refresh();
      return;
    }
    rememberCard(item);
    await context.to(
      () =>
          ReaderWithLoading(id: item.comic.id, sourceKey: item.type.sourceKey),
    );
  }

  void details(_TvEntry item) {
    final local = item.resolveLocal();
    if (local == null && item.type.comicSource?.loadComicInfo == null) {
      showUnavailable();
      return;
    }
    rememberCard(item);
    context.to(
      () => ComicPage(
        id: local?.id ?? item.comic.id,
        sourceKey: item.type.sourceKey,
        title: item.comic.title,
        cover: item.comic.cover,
      ),
    );
  }

  void editFavorite(_TvEntry item) {
    final manager = LocalFavoritesManager();
    final comic = item.comic;
    // Preserve the original folder row when editing a synced favorite.
    final target =
        comic is FavoriteItem || manager.find(comic.id, item.type).isNotEmpty
        ? comic
        : item.resolveLocal() ?? comic;
    final source = item.type.comicSource;
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(target.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 500,
          height: 400,
          child: ComicFavoriteList(
            cid: target.id,
            type: item.type,
            favoriteItem: target is FavoriteItem
                ? target
                : FavoriteItem(
                    id: target.id,
                    name: target.title,
                    coverPath: target.cover,
                    author: target.subtitle ?? '',
                    type: item.type,
                    tags: target.tags ?? [],
                  ),
            comicSource: source,
            hasNetwork: source?.favoriteData != null && source!.isLogged,
            favoriteId: target.favoriteId,
            isFavorite: null,
            localFolders: manager.folderNames,
            added: manager.find(target.id, item.type),
            closeOnFavorite: false,
            onFavorite: (_, _) {},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text('Done'.tl),
          ),
        ],
      ),
    );
  }

  void removeHistory(History record) {
    final clear =
        appdata.settings['clearReadingProgressOnSingleHistoryDelete'] == true;
    showConfirmDialog(
      context: context,
      title: 'Remove history'.tl,
      content: clear
          ? 'Delete this history entry and clear its reading progress? Reading time statistics will be kept.'
                .tl
          : 'Delete @c histories?'.tlParams({'c': 1}),
      onConfirm: () async {
        final manager = HistoryManager();
        try {
          if (clear) {
            await manager.clearReadingProgress(record.id, record.type);
          } else {
            manager.hide(record.id, record.type);
          }
        } catch (error) {
          if (mounted) context.showMessage(message: error.toString());
        }
      },
    );
  }

  Future<void> openNetworkFavorites() async {
    final sources = (appdata.settings['favorites'] as List)
        .whereType<String>()
        .toSet()
        .map(getFavoriteDataOrNull)
        .nonNulls
        .toList();
    final selected = await showDialog<FavoriteData>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text('Network Favorites'.tl),
        children: [
          for (final source in sources)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, source),
              child: Text(source.title),
            ),
          if (sources.isEmpty)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialog);
                showPopUpWidget(context, setFavoritesPagesWidget());
              },
              child: Text('Network Favorite Pages'.tl),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    // FavoritesPage restores this selection and hosts the network folder UI.
    appdata.implicitData['favoriteFolder'] = {
      'name': selected.key,
      'isNetwork': true,
    };
    await context.to(() => const Scaffold(body: FavoritesPage()));
  }

  Future<void> importComic() async {
    setState(() => importing = true);
    try {
      await const ImportComic().files();
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Widget action(String label, IconData icon, VoidCallback callback) =>
      OutlinedButton.icon(
        onPressed: callback,
        icon: Icon(icon),
        label: Text(label.tl),
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: shelf == _Shelf.home,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) select(_Shelf.home);
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'VeneraX TV',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    for (final tab in _Shelf.values.take(4))
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: TextButton(
                          autofocus: tab == _Shelf.home,
                          style: TextButton.styleFrom(
                            backgroundColor: shelf == tab
                                ? colors.secondaryContainer
                                : null,
                          ),
                          onPressed: () => select(tab),
                          child: Text(labels[tab.index].tl),
                        ),
                      ),
                  ],
                ),
                const Divider(),
                Expanded(child: content()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget content() {
    final favorites = LocalFavoritesManager();
    return CustomScrollView(
      key: PageStorageKey(shelf),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              labels[shelf.index].tl,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (shelf == _Shelf.home) ...[
                for (final tab in [_Shelf.local, _Shelf.later])
                  action(
                    labels[tab.index],
                    icons[tab.index],
                    () => select(tab),
                  ),
                action(
                  'Comic Sources',
                  Icons.extension_outlined,
                  () => context.to(() => const ComicSourcePage()),
                ),
              ],
              if (shelf == _Shelf.local)
                OutlinedButton.icon(
                  onPressed: importing ? null : importComic,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text('Import Comics'.tl),
                ),
              if (shelf == _Shelf.settings) ...[
                action(
                  'Pair with phone',
                  Icons.phonelink,
                  () => context.to(() => const TvPairingPage()),
                ),
                action(
                  'WebDAV Sync',
                  Icons.sync,
                  () => context.to(
                    () => const DataSyncSettings(section: 'WebDAV Sync'),
                  ),
                ),
                action(
                  'Cache',
                  Icons.storage_outlined,
                  () => context.to(
                    () => const DataSyncSettings(
                      storageOnly: true,
                      section: 'Cache',
                    ),
                  ),
                ),
                action(
                  'User Agreement & Disclaimer',
                  Icons.article_outlined,
                  () => showDisclaimerDialog(context),
                ),
              ],
              if (shelf == _Shelf.favorites) ...[
                FilterChip(
                  label: Text('All'.tl),
                  selected: selectedFolders.isEmpty,
                  onSelected: (_) {
                    selectedFolders.clear();
                    refresh();
                  },
                ),
                for (final name in favorites.folderNames)
                  FilterChip(
                    key: ValueKey(name),
                    label: Text(favorites.folderTree.pathLabel(name)),
                    selected: selectedFolders.contains(name),
                    onSelected: (selected) {
                      if (selected) {
                        selectedFolders.add(name);
                      } else {
                        selectedFolders.remove(name);
                      }
                      refresh();
                    },
                  ),
                action(
                  'Network Favorites',
                  Icons.cloud_outlined,
                  openNetworkFavorites,
                ),
              ],
            ],
          ),
        ),
        if (shelf == _Shelf.home)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 22),
              child: Text(
                'Continue reading'.tl,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
        if (shelf != _Shelf.settings)
          FutureBuilder<List<_TvEntry>>(
            future: entries,
            builder: (context, snapshot) {
              if (!snapshot.hasData &&
                  snapshot.connectionState != ConnectionState.done) {
                return const SliverToBoxAdapter(
                  child: LinearProgressIndicator(),
                );
              }
              if (snapshot.hasError) {
                return SliverToBoxAdapter(
                  child: action('Retry', Icons.refresh, refresh),
                );
              }
              final items = snapshot.requireData;
              if (items.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No comics'.tl)),
                );
              }
              if (shelf != _Shelf.history) return grid(items);
              final days = <DateTime, List<_TvEntry>>{};
              for (final item in items) {
                final date = DateUtils.dateOnly(
                  (item.comic as History).time.toLocal(),
                );
                (days[date] ??= []).add(item);
              }
              final today = DateUtils.dateOnly(DateTime.now());
              final yesterday = DateTime(
                today.year,
                today.month,
                today.day - 1,
              );
              return SliverMainAxisGroup(
                slivers: [
                  for (final day in days.entries) ...[
                    SliverToBoxAdapter(
                      child: Text(
                        day.key == today
                            ? 'Today'.tl
                            : day.key == yesterday
                            ? 'Yesterday'.tl
                            : MaterialLocalizations.of(
                                context,
                              ).formatFullDate(day.key),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    grid(day.value),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  Widget grid(List<_TvEntry> items) => SliverPadding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    sliver: SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 370,
        mainAxisExtent: 100,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: items.length,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<(ComicType, String)>) return null;
        final index = items.indexWhere(
          (item) => (item.type, item.comic.id) == key.value,
        );
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) {
        final item = items[index];
        final comic = item.comic;
        final isReturnCard = returnCard == (item.type, comic.id);
        if (isReturnCard) focusReturnedCard();
        final image = item.canRead
            ? findImageProvider(item.local ?? comic)
            : null;
        final progress = item.local != null || comic is! History
            ? HistoryManager().find(item.local?.id ?? comic.id, item.type)
            : comic;
        final primaryIsDetails =
            shelf == _Shelf.favorites || shelf == _Shelf.later;
        return Card(
          key: ValueKey((item.type, comic.id)),
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  focusNode: isReturnCard ? cardFocus : null,
                  focusColor: Theme.of(context).colorScheme.primaryContainer,
                  onTap: primaryIsDetails
                      ? (item.canOpenDetails ? () => details(item) : null)
                      : (item.canRead ? () => read(item) : null),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: double.infinity,
                        child: image == null
                            ? const Icon(Icons.menu_book_outlined)
                            : Image(
                                image: ResizeImage.resizeIfNeeded(
                                  160,
                                  null,
                                  image,
                                ),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.menu_book_outlined),
                              ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                comic.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                !item.canRead
                                    ? 'This comic is no longer available'.tl
                                    : progress?.description ??
                                          'Start reading'.tl,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More'.tl,
                onSelected: (value) {
                  switch (value) {
                    case 'Read':
                      read(item);
                    case 'Details':
                      details(item);
                    case 'Favorite':
                      editFavorite(item);
                    case 'Remove history':
                      removeHistory(comic as History);
                  }
                },
                itemBuilder: (_) => [
                  for (final label in [
                    if (item.canRead) 'Read',
                    if (item.canOpenDetails) 'Details',
                    'Favorite',
                    if (comic is History) 'Remove history',
                  ])
                    PopupMenuItem(value: label, child: Text(label.tl)),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _TvEntry {
  _TvEntry(this.comic);
  final Comic comic;
  late final type = comic is ReadLaterItem
      ? (comic as ReadLaterItem).type
      : readingWidgetComicType(comic);
  late final local = resolveLocal();
  bool onDisk = false;

  LocalComic? resolveLocal() {
    final copy = App.local.find(comic.id, type);
    if (type != ComicType.local) return copy;
    // Imported ids can be reused after deletion, or differ between devices.
    if (copy != null) return copy.title == comic.title ? copy : null;
    return App.local.findSyncedCopy(comic.id, comic.title);
  }

  bool get canRead => onDisk || type.comicSource?.loadComicInfo != null;
  bool get canOpenDetails =>
      local != null || type.comicSource?.loadComicInfo != null;

  bool get visible {
    if ((appdata.settings['blockedWords'] as List).isEmpty &&
        (appdata.settings['blockedTags'] as List).isEmpty) {
      return true;
    }
    if (isBlocked(comic) != null) return false;
    final target = local ?? comic;
    if (canOpenDetails) return isReadingWidgetHistoryVisible(target);
    // A removed source can still have cached tags and a removable history row.
    final info = const ComicStateRepository().displayInfoFor(comic);
    if ((appdata.settings['blockedTags'] as List).isNotEmpty &&
        info.tags.isEmpty) {
      return false;
    }
    return isBlocked(
          Comic(
            comic.title,
            '',
            comic.id,
            comic.subtitle,
            info.tags,
            info.description ?? '',
            type.sourceKey,
            null,
            null,
          ),
        ) ==
        null;
  }
}
