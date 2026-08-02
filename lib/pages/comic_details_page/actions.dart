part of 'comic_page.dart';

abstract mixin class _ComicPageActions {
  void update();

  ComicDetails get comic;

  ComicSource? get comicSource => ComicSource.find(comic.sourceKey);

  History? get history;

  /// Whether the network fetch that resolves the chapter list is still running.
  /// A comic with chapters shows [ComicDetails.chapters] == null until this
  /// completes, so pre-translate must wait rather than treat it as chapter-less.
  bool get isDetailsLoading;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    final source = comicSource;
    if (source?.likeOrUnlikeComic == null) return;
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await source!.likeOrUnlikeComic!(comic.id, isLiked);
    if (res.error) {
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var rawTags = <String>[];
    for (var e in comic.tags.entries) {
      rawTags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    final buckets = splitFavoriteTags(rawTags);
    final author = buckets.authors.isNotEmpty
        ? buckets.authors.join(', ')
        : (comic.subTitle ?? comic.uploader ?? '');
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: author,
      type: comic.comicType,
      tags: buckets.tags,
      authors: buckets.authors,
      status: buckets.status,
      updateTimeMeta: buckets.updateTime,
      extraMeta: buckets.extraMeta,
    );
  }

  void openFavPanel() {
    showSideBar(
      App.rootContext,
      _FavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (network != null) {
            isFavorite = network;
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateTime: comic.findUpdateTime(),
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String || !LocalFavoritesManager().existsFolder(folder)) {
      return;
    }
    LocalFavoritesManager().addComic(
      folder,
      _toFavoriteItem(),
      null,
      comic.findUpdateTime(),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(message: "Added".tl);
  }

  /// whether the comic is in the "Read Later" list
  bool get isInReadLater =>
      ReadLaterManager().isExist(comic.id, comic.comicType);

  void toggleReadLater() async {
    if (isInReadLater) {
      await ReadLaterManager().remove(comic.id, comic.comicType);
      update();
      App.rootContext.showMessage(message: "Removed from read later".tl);
    } else {
      await ReadLaterManager().addItem(ReadLaterItem(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subTitle,
        cover: comic.cover,
        type: comic.comicType,
        tags: comic.plainTags,
        time: DateTime.now(),
      ));
      update();
      App.rootContext.showMessage(message: "Added to read later".tl);
    }
  }

  void share() {
    var text = comic.title;
    if (comic.url != null) {
      text += '\n${comic.url}';
    }
    Share.shareText(text);
  }

  /// Queues selected chapters for background pre-translation so their pages are
  /// rendered and cached before the user opens the reader (no in-reader wait).
  void preTranslate() {
    if (!ImageTranslationService.isReady) {
      App.rootContext.showMessage(
        message: "Configure AI translation first".tl,
      );
      return;
    }
    if (!ImageTranslationService.isEnabledForComic(comic.id, comic.sourceKey)) {
      App.rootContext.showMessage(
        message: "Enable AI translation in the reader for this comic first".tl,
      );
      return;
    }
    // The chapter list arrives with the background network fetch; until it
    // finishes, comic.chapters is null even for a comic that HAS chapters.
    // Treating that as chapter-less would wrongly start a whole-comic job and
    // skip the picker, so wait for the fetch instead.
    if (isDetailsLoading && comic.chapters == null) {
      App.rootContext.showMessage(
        message: "Loading chapters, please wait".tl,
      );
      return;
    }
    // Ordered (id, title) list of chapters; a chapter-less comic is one job.
    final entries = <(String, String)>[];
    // When the source groups chapters (e.g. comick's English/Latin editions),
    // keep the grouping so the picker can show tabs. Each group maps to the
    // flat indices into [entries] it covers, preserving the same order
    // allChapters merges them in.
    List<(String, List<int>)>? groups;
    final chapters = comic.chapters;
    if (chapters == null) {
      entries.add(('0', comic.title));
    } else if (chapters.isGrouped) {
      groups = [];
      var index = 1;
      for (var groupName in chapters.groups) {
        var indices = <int>[];
        for (var entry in chapters.getGroup(groupName).entries) {
          indices.add(entries.length);
          entries.add(
            (entry.key, entry.value.isEmpty ? 'E$index' : entry.value),
          );
          index++;
        }
        groups.add((groupName, indices));
      }
    } else {
      var index = 1;
      for (var entry in chapters.allChapters.entries) {
        entries.add((entry.key, entry.value.isEmpty ? 'E$index' : entry.value));
        index++;
      }
    }

    void startJob(List<int> selected) {
      if (selected.isEmpty) return;
      var picked = [
        for (var i in selected)
          PreTranslationChapter(eid: entries[i].$1, title: entries[i].$2),
      ];
      var task = PreTranslationTaskManager.instance.start(
        cid: comic.id,
        sourceKey: comic.sourceKey,
        comicType: comic.comicType,
        title: comic.title,
        chapters: picked,
      );
      App.rootContext.showMessage(
        message: task == null
            ? "A pre-translation task is already running".tl
            : "Pre-translation started".tl,
      );
    }

    // A chapter-less comic has no picker to open, but pre-translation still
    // runs in the background and may spend paid requests, so confirm before
    // starting instead of kicking it off the moment the button is tapped.
    if (chapters == null) {
      showConfirmDialog(
        context: App.rootContext,
        title: "Start pre-translation?".tl,
        content:
            "Pages are translated in the background. If your configured AI endpoint is paid this may cost money; the offline engine is free."
                .tl,
        onConfirm: () => startJob([0]),
      );
      return;
    }
    App.rootContext.to(
      () => _SelectPreTranslateChapter(
        cid: comic.id,
        sourceKey: comic.sourceKey,
        comicType: comic.comicType,
        title: comic.title,
        entries: entries,
        groups: groups,
        finishSelect: startJob,
      ),
    );
  }

  /// Clears every translation (both stored text and rendered images) and the
  /// learned glossary for this comic, so subsequent reading / pre-translation is
  /// produced fresh. Reached by long-pressing the pre-translate button; used
  /// when translations came out wrong and need to be redone.
  void reTranslate() {
    showConfirmDialog(
      context: App.rootContext,
      title: "Re-translate this comic?".tl,
      content:
          "This clears all translations and the learned glossary for this comic, then translates again."
              .tl,
      onConfirm: () async {
        await ImageTranslationService.instance.retranslate(
          comic.id,
          comic.sourceKey,
        );
        // This comic's status is stale now; drop its ticks too.
        PreTranslationTaskManager.instance.resetComicStatus(
          comic.id,
          comic.sourceKey,
        );
        App.rootContext.showMessage(message: "Translation results cleared".tl);
        // Offer to pre-translate again right away; the user can also just
        // reopen the reader, which translates on demand.
        if (ImageTranslationService.isReady) {
          preTranslate();
        }
      },
    );
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    // Heal a stale history row (e.g. a reused local id whose old record kept
    // the previous comic's title/cover, issue #135) before the reader
    // persists it again.
    if (history != null) {
      history!.title = comic.title;
      history!.subtitle = comic.subTitle ?? '';
      history!.cover = comic.cover;
    }
    App.rootContext
        .to(
          () => Reader(
            type: comic.comicType,
            cid: comic.id,
            name: comic.title,
            chapters: comic.chapters,
            initialChapter: ep,
            initialPage: page,
            initialChapterGroup: group,
            history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
            author: comic.findAuthor() ?? '',
            tags: comic.plainTags,
          ),
        )
        .then((_) {
          onReadEnd();
        });
  }

  void continueRead() {
    var ep = history?.ep ?? 1;
    var page = history?.page ?? 1;
    var group = history?.group;
    read(ep, page, group);
  }

  void onReadEnd();

  void download() async {
    final source = comicSource;
    if (source == null) {
      App.rootContext.showMessage(message: "Comic source not found".tl);
      return;
    }
    if (LocalManager().isDownloading(comic.id, comic.comicType)) {
      App.rootContext.showMessage(message: "The comic is downloading".tl);
      return;
    }
    if (comic.chapters == null &&
        LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
      App.rootContext.showMessage(message: "The comic is downloaded".tl);
      return;
    }
    if (!await ensureDownloadStorageWritable()) return;

    if (source.archiveDownloader != null) {
      bool useNormalDownload = false;
      List<ArchiveInfo>? archives;
      int selected = -1;
      bool isLoading = false;
      bool isGettingLink = false;
      await showDialog(
        context: App.rootContext,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return ContentDialog(
                title: "Download".tl,
                content: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    setState(() {
                      selected = v ?? selected;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<int>(value: -1, title: Text("Normal".tl)),
                      ExpansionTile(
                        title: Text("Archive".tl),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        collapsedShape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        onExpansionChanged: (b) {
                          if (!isLoading && b && archives == null) {
                            isLoading = true;
                            source.archiveDownloader!
                                .getArchives(comic.id)
                                .then((value) {
                                  if (value.success) {
                                    archives = value.data;
                                  } else {
                                    App.rootContext.showMessage(
                                      message: value.errorMessage!,
                                    );
                                  }
                                  setState(() {
                                    isLoading = false;
                                  });
                                });
                          }
                        },
                        children: [
                          if (archives == null)
                            const ListLoadingIndicator().toCenter()
                          else
                            for (int i = 0; i < archives!.length; i++)
                              RadioListTile<int>(
                                value: i,
                                title: Text(archives![i].title),
                                subtitle: Text(archives![i].description),
                              ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  Button.filled(
                    isLoading: isGettingLink,
                    onPressed: () async {
                      if (selected == -1) {
                        useNormalDownload = true;
                        context.pop();
                        return;
                      }
                      setState(() {
                        isGettingLink = true;
                      });
                      var res = await source.archiveDownloader!.getDownloadUrl(
                        comic.id,
                        archives![selected].id,
                      );
                      if (res.error) {
                        App.rootContext.showMessage(message: res.errorMessage!);
                        setState(() {
                          isGettingLink = false;
                        });
                      } else if (context.mounted) {
                        if (res.data.isNotEmpty) {
                          LocalManager().addTask(
                            ArchiveDownloadTask(res.data, comic),
                          );
                          App.rootContext.showMessage(
                            message: "Download started".tl,
                          );
                        }
                        context.pop();
                      }
                    },
                    child: Text("Confirm".tl),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!useNormalDownload) {
        return;
      }
    }

    // The comic details may be a local-first placeholder whose chapter info
    // hasn't been resolved yet (background network fetch still pending or
    // failed). In that case a multi-chapter comic looks single-chapter and
    // would download `chapter/null`. Resolve authoritative details first.
    var details = comic;
    if (details.chapters == null && source.loadComicInfo != null) {
      try {
        var res = await source.loadComicInfo!(comic.id);
        if (res.success && res.data.chapters != null) {
          details = res.data;
        }
      } catch (_) {
        // Network/JS fetch failed; fall back to the current comic info so the
        // download flow doesn't break or hang.
      }
    }

    if (details.chapters == null) {
      LocalManager().addTask(
        ImagesDownloadTask(source: source, comicId: comic.id, comic: details),
      );
    } else {
      List<int>? selected;
      var downloaded = <int>[];
      var localComic = LocalManager().find(comic.id, comic.comicType);
      if (localComic != null) {
        for (int i = 0; i < details.chapters!.length; i++) {
          if (localComic.downloadedChapters.contains(
            details.chapters!.ids.elementAt(i),
          )) {
            downloaded.add(i);
          }
        }
      }
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          details.chapters!.titles.toList(),
          (v) => selected = v,
          downloaded,
        ),
      );
      if (selected == null) return;
      LocalManager().addTask(
        ImagesDownloadTask(
          source: source,
          comicId: comic.id,
          comic: details,
          chapters: selected!.map((i) {
            return details.chapters!.ids.elementAt(i);
          }).toList(),
        ),
      );
    }
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  void onTapTag(String tag, String namespace) {
    final source = comicSource;
    var target = source?.handleClickTagEvent?.call(namespace, tag);
    var context = App.mainNavigatorKey!.currentContext!;
    if (target != null) {
      target.jump(context);
      return;
    }
    context.to(
      () => SearchResultPage(
        text: tag,
        sourceKey: source?.key ?? comic.sourceKey,
      ),
    );
  }

  void showMoreActions() {
    var context = App.rootContext;
    final translationEnabled = ImageTranslationService.isEnabledForComic(
      comic.id,
      comic.sourceKey,
    );
    showMenuX(context, Offset(context.width - 16, context.padding.top), [
      // Per-comic AI translation switch. Toggling notifies the service, which
      // the detail page listens to, so the pre-translate button appears/hides
      // in sync (when the engine is also ready).
      MenuEntry(
        icon: Icons.translate_rounded,
        text: translationEnabled
            ? "Disable AI translation".tl
            : "Enable AI translation".tl,
        color: translationEnabled ? context.colorScheme.primary : null,
        onClick: () {
          ImageTranslationService.setEnabledForComic(
            comic.id,
            comic.sourceKey,
            !translationEnabled,
          );
          context.showMessage(
            message: translationEnabled
                ? "AI translation disabled".tl
                : "AI translation enabled".tl,
          );
        },
      ),
      MenuEntry(
        icon: Icons.copy,
        text: "Copy Title".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          context.showMessage(message: "Copied".tl);
        },
      ),
      MenuEntry(
        icon: Icons.copy_rounded,
        text: "Copy ID".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.id));
          context.showMessage(message: "Copied".tl);
        },
      ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.link,
          text: "Copy URL".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: comic.url!));
            context.showMessage(message: "Copied".tl);
          },
        ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.open_in_browser,
          text: "Open in Browser".tl,
          onClick: () {
            launchUrlString(comic.url!);
          },
        ),
      MenuEntry(
        icon: Icons.hub_outlined,
        text: "Related Sources".tl,
        onClick: () {
          showRelatedSourcesDialog(
            context,
            Comic(
              comic.title,
              comic.cover,
              comic.id,
              comic.subTitle,
              comic.plainTags,
              comic.description ?? '',
              comic.sourceKey,
              comic.maxPage,
              null,
            ),
          );
        },
      ),
      MenuEntry(
        icon: Icons.move_up_outlined,
        text: "Migrate Source".tl,
        onClick: () {
          showSourceMigrationDialog(context, _toFavoriteItem());
        },
      ),
      // Only offered for a comic whose images are actually on disk: migration
      // uploads the local pages, so a not-yet-downloaded online comic has
      // nothing to send. The multi-select list page has the batch entry.
      if (_localDownloadedComic() != null)
        MenuEntry(
          icon: Icons.cloud_upload_outlined,
          text: "Migrate to WebDAV source".tl,
          onClick: () {
            startWebdavMigrationFlow([_localDownloadedComic()!]);
          },
        ),
      MenuEntry(
        icon: Icons.block,
        text: "Block".tl,
        onClick: blockThisComic,
      ),
    ]);
  }

  /// Block entry for the detail page. The list long-press menu has one too, but
  /// a list item often carries no tags at all — here the full tag set is loaded,
  /// so this is the only place a tag can reliably be picked off a comic.
  void blockThisComic() {
    showBlockDialog(
      title: comic.title,
      subtitle: comic.subTitle,
      tags: comic.plainTags,
    );
  }

  /// The on-disk [LocalComic] for this page's comic when its images are fully
  /// downloaded, else null. Drives the WebDAV-migration menu entry's visibility.
  LocalComic? _localDownloadedComic() {
    var local = LocalManager().find(comic.id, comic.comicType);
    if (local == null || local.status != LocalComicStatus.downloaded) {
      return null;
    }
    return local;
  }

  /// Long-press menu on the translate button: the fast path (tap) starts a
  /// pre-translation, while this exposes the less-common "re-translate" action
  /// for when cached translations came out wrong.
  void showTranslationMenu() {
    var context = App.rootContext;
    if (!ImageTranslationService.isReady) {
      context.showMessage(message: "Configure AI translation first".tl);
      return;
    }
    if (!ImageTranslationService.isEnabledForComic(comic.id, comic.sourceKey)) {
      context.showMessage(
        message: "Enable AI translation in the reader for this comic first".tl,
      );
      return;
    }
    showMenuX(context, Offset(context.width - 16, context.padding.top), [
      MenuEntry(
        icon: Icons.translate_rounded,
        text: "Pre-translate".tl,
        onClick: preTranslate,
      ),
      MenuEntry(
        icon: Icons.menu_book_outlined,
        text: "Glossary".tl,
        onClick: openGlossary,
      ),
      MenuEntry(
        icon: Icons.refresh_rounded,
        text: "Re-translate".tl,
        onClick: reTranslate,
      ),
    ]);
  }

  /// Opens the per-comic glossary editor so the user can view or correct the
  /// learned name translations that keep proper nouns consistent across pages.
  void openGlossary() {
    App.rootContext.to(
      () => GlossaryEditorPage(
        cid: comic.id,
        sourceKey: comic.sourceKey,
        title: comic.title,
      ),
    );
  }

  void showComments() {
    final source = comicSource;
    if (source == null) return;
    showSideBar(App.rootContext, CommentsPage(data: comic, source: source));
  }

  void starRating() {
    final source = comicSource;
    if (source?.isLogged != true || source?.starRatingFunc == null) {
      return;
    }
    var rating = 0.0;
    var isLoading = false;
    showDialog(
      context: App.rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: Text("Rating".tl),
          alignment: Alignment.center,
          children: [
            SizedBox(
              height: 100,
              child: Center(
                child: SizedBox(
                  width: 210,
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      RatingWidget(
                        padding: 2,
                        onRatingUpdate: (value) => rating = value,
                        value: 1,
                        selectable: true,
                        size: 40,
                      ),
                      const Spacer(),
                      Button.filled(
                        isLoading: isLoading,
                        onPressed: () {
                          setState(() {
                            isLoading = true;
                          });
                          source!.starRatingFunc!(comic.id, rating.round())
                              .then((value) {
                                if (value.success) {
                                  App.rootContext.showMessage(
                                    message: "Success".tl,
                                  );
                                  Navigator.of(dialogContext).pop();
                                } else {
                                  App.rootContext.showMessage(
                                    message: value.errorMessage!,
                                  );
                                  setState(() {
                                    isLoading = false;
                                  });
                                }
                              });
                        },
                        child: Text("Submit".tl),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
