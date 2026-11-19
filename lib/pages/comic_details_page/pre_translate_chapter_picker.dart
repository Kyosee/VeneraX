part of 'comic_page.dart';

void openTranslatedChaptersPage(
  BuildContext context,
  StoredTranslationComic comic,
) {
  Future<void> open({ComicDetails? details}) async {
    var stored = TranslationStore().chaptersFor(
      comic.sourceKey,
      comic.comicId,
      sourceLang: comic.sourceLang,
      targetLang: comic.targetLang,
    );

    var title = comic.title.isEmpty ? comic.comicId : comic.title;
    var cover = comic.cover;
    var chapterTitles = <String, String>{};
    if (details != null) {
      title = details.title.isEmpty ? title : details.title;
      cover = details.cover.isEmpty ? cover : details.cover;
      chapterTitles = details.chapters?.allChapters ?? {};
      TranslationStore().updateComicMetadata(
        comic.sourceKey,
        comic.comicId,
        comicTitle: details.title,
        comicCover: details.cover,
        chapterTitles: chapterTitles,
      );
      stored = TranslationStore().chaptersFor(
        comic.sourceKey,
        comic.comicId,
        sourceLang: comic.sourceLang,
        targetLang: comic.targetLang,
      );
    }

    // The details cache is the chapter-list source of truth. The durable
    // translation index only tells us which of those chapters have pages.
    // Keep indexed chapters that disappeared from a stale source response so
    // an old translation is never hidden from the user.
    final storedById = <String, StoredTranslationChapter>{
      for (var chapter in stored) chapter.identity.chapterId: chapter,
    };
    final sourceChapters =
        details?.chapters?.allChapters ?? const <String, String>{};
    final entries = <(String, String)>[];
    final seenIds = <String>{};
    for (var entry in sourceChapters.entries) {
      seenIds.add(entry.key);
      final storedTitle = storedById[entry.key]?.identity.chapterTitle ?? '';
      entries.add((
        entry.key,
        entry.value.isNotEmpty
            ? entry.value
            : (storedTitle.isNotEmpty ? storedTitle : entry.key),
      ));
    }
    for (var chapter in stored) {
      if (seenIds.add(chapter.identity.chapterId)) {
        entries.add((
          chapter.identity.chapterId,
          chapter.identity.chapterTitle.isEmpty
              ? chapter.identity.chapterId
              : chapter.identity.chapterTitle,
        ));
      }
    }
    if (entries.isEmpty) {
      context.showMessage(message: 'No items'.tl);
      return;
    }

    // A legacy page row may predate the chapter index. Hydrating it here makes
    // the status tabs accurate without requiring a new translation run.
    final translatedIds = <String>{...storedById.keys};
    for (var entry in entries) {
      if (translatedIds.contains(entry.$1)) continue;
      final pages = ImageTranslationService.storedPageCount(
        comic.comicId,
        comic.sourceKey,
        entry.$1,
        comicTitle: title,
        comicCover: cover,
        chapterTitle: entry.$2,
      );
      if (pages > 0) translatedIds.add(entry.$1);
    }
    stored = TranslationStore().chaptersFor(
      comic.sourceKey,
      comic.comicId,
      sourceLang: comic.sourceLang,
      targetLang: comic.targetLang,
    );
    translatedIds.addAll(stored.map((chapter) => chapter.identity.chapterId));

    List<(String, List<int>)>? groups;
    if (details?.chapters?.isGrouped == true) {
      var grouped = <(String, List<int>)>[];
      final groupedIndices = <int>{};
      for (var groupName in details!.chapters!.groups) {
        var ids = details.chapters!.getGroup(groupName).keys.toSet();
        var indices = [
          for (var index = 0; index < entries.length; index++)
            if (ids.contains(entries[index].$1)) index,
        ];
        if (indices.isNotEmpty) {
          grouped.add((groupName, indices));
          groupedIndices.addAll(indices);
        }
      }
      final ungrouped = [
        for (var index = 0; index < entries.length; index++)
          if (!groupedIndices.contains(index)) index,
      ];
      if (ungrouped.isNotEmpty) {
        grouped.add(('Other'.tl, ungrouped));
      }
      groups = grouped.isEmpty ? null : grouped;
    }

    void startJob(List<int> selected) {
      var task = PreTranslationTaskManager.instance.start(
        cid: comic.comicId,
        sourceKey: comic.sourceKey,
        comicType: ComicType.fromKey(comic.sourceKey),
        title: title,
        cover: cover,
        chapters: [
          for (var index in selected)
            PreTranslationChapter(
              eid: entries[index].$1,
              title: entries[index].$2,
            ),
        ],
      );
      App.rootContext.showMessage(
        message: task == null
            ? (ImageTranslationService.isReadyForComic(
                    comic.comicId,
                    comic.sourceKey,
                  )
                  ? 'A pre-translation task is already running'.tl
                  : 'Configure AI translation first'.tl)
            : 'Pre-translation started'.tl,
      );
    }

    context.to(
      () => _SelectPreTranslateChapter(
        cid: comic.comicId,
        sourceKey: comic.sourceKey,
        comicType: ComicType.fromKey(comic.sourceKey),
        title: title,
        cover: cover,
        entries: entries,
        author: details?.findAuthor(),
        groups: groups,
        translatedChapterIds: translatedIds,
        translatedView: true,
        finishSelect: startJob,
      ),
    );
  }

  Future<void> hydrateAndOpen() async {
    var cached = ComicDetailsCache().find(comic.sourceKey, comic.comicId);
    if (cached != null) {
      await open(details: cached);
      return;
    }
    var source = ComicSource.find(comic.sourceKey);
    if (source?.loadComicInfo != null) {
      try {
        var details = (await source!.loadComicInfo!(comic.comicId)).data;
        ComicDetailsCache().update(comic.sourceKey, comic.comicId, details);
        await open(details: details);
        return;
      } catch (e, s) {
        Log.error('Translated Comics', 'Failed to load comic metadata: $e', s);
      }
    }
    await open();
  }

  unawaited(hydrateAndOpen());
}

/// Shared chapter workspace for queued translation and the translation library.
class _SelectPreTranslateChapter extends StatefulWidget {
  const _SelectPreTranslateChapter({
    required this.cid,
    required this.sourceKey,
    required this.comicType,
    required this.title,
    required this.cover,
    required this.entries,
    this.author,
    this.translatedChapterIds = const {},
    this.groups,
    this.translatedView = false,
    required this.finishSelect,
  });

  final String cid;
  final String sourceKey;
  final ComicType comicType;
  final String title;
  final String cover;
  final String? author;

  /// Ordered list of chapter entries (eid, display title).
  final List<(String, String)> entries;

  /// Chapter ids that already have at least one durable translated page.
  /// Used by the translated-comics view to split the picker into status tabs.
  final Set<String> translatedChapterIds;

  /// When the source groups chapters (e.g. comick's English/Latin editions),
  /// each entry is (group name, flat indices into [entries]) so the picker can
  /// show a tab per group. Null when the comic has no groups.
  final List<(String, List<int>)>? groups;

  final bool translatedView;

  final void Function(List<int>) finishSelect;

  @override
  State<_SelectPreTranslateChapter> createState() =>
      _SelectPreTranslateChapterState();
}
