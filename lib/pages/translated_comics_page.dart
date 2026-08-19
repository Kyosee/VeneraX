import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

class _TranslationComicEntry {
  const _TranslationComicEntry({
    required this.sourceKey,
    required this.comicId,
    required this.title,
    required this.cover,
    this.translated,
  });

  final String sourceKey;
  final String comicId;
  final String title;
  final String cover;
  final StoredTranslationComic? translated;
}

final _metadataHydrationInFlight = <String>{};

/// Resolves missing titles, covers and chapter names for rows imported from a
/// database version that only stored page keys. The result is persisted so the
/// home card, the library page and the chapter picker all share the same data.
Future<void> hydrateTranslatedComicMetadata() async {
  for (var item in ImageTranslationService.translatedComics) {
    var storedChapters = TranslationStore().chaptersFor(
      item.sourceKey,
      item.comicId,
      sourceLang: item.sourceLang,
      targetLang: item.targetLang,
    );
    var needsChapterNames = storedChapters.any(
      (chapter) => chapter.identity.chapterTitle.isEmpty,
    );
    if (item.title.isNotEmpty && item.cover.isNotEmpty && !needsChapterNames) {
      continue;
    }
    var key = '${item.sourceKey}\u0000${item.comicId}';
    if (!_metadataHydrationInFlight.add(key)) continue;
    try {
      LocalComic? local;
      if (LocalManager().isInitialized) {
        local = LocalManager().find(
          item.sourceKey,
          ComicType.fromKey(item.sourceKey),
        );
      }
      if (local != null) {
        TranslationStore().updateComicMetadata(
          item.sourceKey,
          item.comicId,
          comicTitle: local.title,
          comicCover: local.cover,
          chapterTitles: local.chapters?.allChapters ?? {},
        );
        continue;
      }
      var cached = ComicDetailsCache().find(item.sourceKey, item.comicId);
      if (cached != null) {
        TranslationStore().updateComicMetadata(
          item.sourceKey,
          item.comicId,
          comicTitle: cached.title,
          comicCover: cached.cover,
          chapterTitles: cached.chapters?.allChapters ?? {},
        );
        continue;
      }
      var source = ComicSource.find(item.sourceKey);
      if (source?.loadComicInfo == null) {
        _metadataHydrationInFlight.remove(key);
        continue;
      }
      var details = (await source!.loadComicInfo!(item.comicId)).data;
      ComicDetailsCache().update(item.sourceKey, item.comicId, details);
      TranslationStore().updateComicMetadata(
        item.sourceKey,
        item.comicId,
        comicTitle: details.title,
        comicCover: details.cover,
        chapterTitles: details.chapters?.allChapters ?? {},
      );
    } catch (e, s) {
      _metadataHydrationInFlight.remove(key);
      debugPrint('Failed to hydrate translated comic metadata: $e\n$s');
    }
  }
}

class TranslatedComicsPage extends StatefulWidget {
  const TranslatedComicsPage({super.key});

  @override
  State<TranslatedComicsPage> createState() => _TranslatedComicsPageState();
}

class _TranslatedComicsPageState extends State<TranslatedComicsPage>
    with SingleTickerProviderStateMixin {
  var keyword = '';
  final searchController = TextEditingController();
  late final TabController _tabController;

  bool get _showTranslated => _tabController.index == 0;

  @override
  void initState() {
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_onTabChanged);
    TranslationStore().addListener(_reload);
    ImageTranslationService.instance.addListener(_reload);
    unawaited(_hydrateMetadata());
    super.initState();
  }

  @override
  void dispose() {
    TranslationStore().removeListener(_reload);
    ImageTranslationService.instance.removeListener(_reload);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    searchController.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() {});
  }

  void _onTabChanged() {
    if (mounted && !_tabController.indexIsChanging) setState(() {});
  }

  Future<void> _hydrateMetadata() async {
    await hydrateTranslatedComicMetadata();
  }

  String _key(String sourceKey, String comicId) => '$sourceKey\u0000$comicId';

  Map<String, ({String title, String cover})> _knownMetadata() {
    var result = <String, ({String title, String cover})>{};
    void add(String sourceKey, String comicId, String title, String cover) {
      var key = _key(sourceKey, comicId);
      var old = result[key];
      result[key] = (
        title: title.isNotEmpty ? title : old?.title ?? '',
        cover: cover.isNotEmpty ? cover : old?.cover ?? '',
      );
    }

    if (HistoryManager().isInitialized) {
      for (var history in HistoryManager().getAll()) {
        add(history.sourceKey, history.id, history.title, history.cover);
      }
    }
    if (ReadLaterManager().isInitialized) {
      for (var item in ReadLaterManager().getAll()) {
        add(item.sourceKey, item.id, item.title, item.cover);
      }
    }
    if (LocalManager().isInitialized) {
      for (var comic in LocalManager().getComics(LocalSortType.defaultSort)) {
        add(comic.sourceKey, comic.id, comic.title, comic.cover);
      }
    }
    return result;
  }

  List<_TranslationComicEntry> get _allItems {
    var stored = ImageTranslationService.translatedComics;
    var byKey = <String, _TranslationComicEntry>{};
    var metadata = _knownMetadata();
    for (var item in stored) {
      var known = metadata[_key(item.sourceKey, item.comicId)];
      byKey[_key(item.sourceKey, item.comicId)] = _TranslationComicEntry(
        sourceKey: item.sourceKey,
        comicId: item.comicId,
        title: item.title.isNotEmpty ? item.title : known?.title ?? '',
        cover: item.cover.isNotEmpty ? item.cover : known?.cover ?? '',
        translated: item,
      );
    }
    for (var rawKey in ImageTranslationService.enabledComicKeys) {
      var separator = rawKey.lastIndexOf('@');
      if (separator <= 0 || separator == rawKey.length - 1) continue;
      var comicId = rawKey.substring(0, separator);
      var sourceKey = rawKey.substring(separator + 1);
      var key = _key(sourceKey, comicId);
      if (byKey.containsKey(key)) continue;
      var known = metadata[key];
      byKey[key] = _TranslationComicEntry(
        sourceKey: sourceKey,
        comicId: comicId,
        title: known?.title ?? '',
        cover: known?.cover ?? '',
      );
    }
    var query = keyword.trim().toLowerCase();
    return byKey.values.where((item) {
      if ((item.translated != null) != _showTranslated) return false;
      if (query.isEmpty) return true;
      var source = ComicSource.find(item.sourceKey)?.name ?? item.sourceKey;
      return item.title.toLowerCase().contains(query) ||
          item.comicId.toLowerCase().contains(query) ||
          source.toLowerCase().contains(query);
    }).toList()..sort((a, b) {
      var aTime =
          a.translated?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      var bTime =
          b.translated?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
  }

  Comic _asComic(_TranslationComicEntry item) {
    var title = item.title.isEmpty ? item.comicId : item.title;
    return Comic(
      title,
      item.cover,
      item.comicId,
      ComicSource.find(item.sourceKey)?.name,
      const [],
      '',
      item.sourceKey,
      null,
      null,
    );
  }

  void _delete(StoredTranslationComic comic) {
    showConfirmDialog(
      context: context,
      title: 'Delete all translations for this comic?'.tl,
      content:
          'This removes every stored translation and rendered page of this comic. The original images are unaffected.'
              .tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        var running = PreTranslationTaskManager.instance.runningTaskFor(
          comic.comicId,
          comic.sourceKey,
        );
        if (running != null) {
          PreTranslationTaskManager.instance.cancel(running.id);
        }
        await ImageTranslationService.instance.retranslate(
          comic.comicId,
          comic.sourceKey,
        );
        PreTranslationTaskManager.instance.resetComicStatus(
          comic.comicId,
          comic.sourceKey,
        );
        if (mounted) {
          setState(() {});
          App.rootContext.showMessage(
            message: 'Translation results cleared'.tl,
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var items = _allItems;
    var comics = items.map(_asComic).toList();
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text('Translation Library'.tl)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: AppSearchField(
                controller: searchController,
                onChanged: (value) => setState(() => keyword = value),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Material(
              child: AppTabBar(
                controller: _tabController,
                tabs: [
                  Tab(text: 'Translated'.tl),
                  Tab(text: 'Not translated'.tl),
                ],
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  ImageTranslationService.translatedComics.isEmpty &&
                          ImageTranslationService.enabledComicKeys.isEmpty
                      ? 'No translation entries'.tl
                      : 'No matching items'.tl,
                  style: ts.s16,
                ),
              ),
            )
          else
            SliverGridComics(
              comics: comics,
              enableHero: false,
              badgeBuilder: (comic) {
                var item = items.firstWhere(
                  (entry) =>
                      entry.comicId == comic.id &&
                      entry.sourceKey == comic.sourceKey,
                );
                return item.translated == null
                    ? 'Not translated'.tl
                    : '@count chapters'.tlParams({
                        'count': item.translated!.chapterCount,
                      });
              },
              onTap: (comic, _) {
                var item = items.firstWhere(
                  (entry) =>
                      entry.comicId == comic.id &&
                      entry.sourceKey == comic.sourceKey,
                );
                if (item.translated != null) {
                  openTranslatedChaptersPage(context, item.translated!);
                } else {
                  context.to(
                    () => ComicPage(
                      id: item.comicId,
                      sourceKey: item.sourceKey,
                      cover: item.cover,
                      title: item.title,
                    ),
                  );
                }
              },
              menuBuilder: (comic) {
                var item = items.firstWhere(
                  (entry) =>
                      entry.comicId == comic.id &&
                      entry.sourceKey == comic.sourceKey,
                );
                return [
                  MenuEntry(
                    icon: Icons.info_outline_rounded,
                    text: 'Open comic details'.tl,
                    onClick: () => context.to(
                      () => ComicPage(
                        id: item.comicId,
                        sourceKey: item.sourceKey,
                        title: item.title,
                        cover: item.cover,
                      ),
                    ),
                  ),
                  if (item.translated != null)
                    MenuEntry(
                      icon: Icons.delete_outline_rounded,
                      text: 'Delete all translations'.tl,
                      color: context.colorScheme.error,
                      onClick: () => _delete(item.translated!),
                    ),
                ];
              },
            ),
        ],
      ),
    );
  }
}
