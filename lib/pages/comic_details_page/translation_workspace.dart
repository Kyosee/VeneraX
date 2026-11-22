part of 'comic_page.dart';

enum _TranslationFilter { all, pending, translating, stored, attention }

enum _ChapterTranslationState {
  pending,
  stored,
  complete,
  failed,
  paused,
  running,
  queued,
}

class _TranslationChapterRow {
  const _TranslationChapterRow(
    this.state,
    this.saved,
    this.total,
    this.failed,
    this.progress,
    this.task,
  );
  final _ChapterTranslationState state;
  final int saved;
  final int total;
  final int failed;
  final double? progress;
  final PreTranslationTask? task;
  bool get active =>
      state == _ChapterTranslationState.running ||
      state == _ChapterTranslationState.paused ||
      state == _ChapterTranslationState.queued;
}

class _SelectPreTranslateChapterState extends State<_SelectPreTranslateChapter>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _selected = <int>{};
  late final TabController _filterTabs;
  final _tabStorage = PageStorageBucket();
  late _TranslationFilter _filter;
  late Set<int> _hidden;
  var _group = 0;
  var _manage = false;
  Map<String, int> _saved = {};
  Map<String, int> _totals = {};
  var _fetchingPageCounts = false;
  final _taskFor = <String, PreTranslationTask>{};
  final _chapterFor = <String, PreTranslationChapter>{};
  late BuildContext _contentContext;
  PreTranslationTaskManager get _manager => PreTranslationTaskManager.instance;
  bool get _picking => _manage;
  List<_TranslationFilter> get _availableFilters => [
    _TranslationFilter.all,
    _TranslationFilter.pending,
    _TranslationFilter.translating,
    _TranslationFilter.stored,
    _TranslationFilter.attention,
  ];
  List<(String, List<int>)> get _groups =>
      widget.groups ??
      [
        (
          'All chapters'.tl,
          List.generate(widget.entries.length, (index) => index),
        ),
      ];

  @override
  void initState() {
    super.initState();
    _manage = !widget.translatedView;
    _filter = widget.translatedView
        ? _TranslationFilter.stored
        : _TranslationFilter.pending;
    _filterTabs = TabController(
      length: _availableFilters.length,
      initialIndex: _availableFilters.indexOf(_filter),
      vsync: this,
    )..addListener(_onFilterTabChanged);
    _hidden = ChapterDuplicatePrefs.isHidden(widget.cid, widget.sourceKey)
        ? findDuplicateTitleIndices(
            count: widget.entries.length,
            titleOf: (index) => widget.entries[index].$2,
            scopes: widget.groups?.map((group) => group.$2).toList(),
          )
        : {};
    _loadStore();
    _loadTasks();
    _restoreKnownPageCounts();
    if (_groups.isNotEmpty && widget.translatedView) {
      final first = _groups.indexWhere(
        (group) => group.$2.any((i) => _matches(i)),
      );
      if (first >= 0) _group = first;
    }
    _manager.addListener(_onTaskUpdate);
    TranslationStore().addListener(_onStoreUpdate);
  }

  @override
  void dispose() {
    _manager.removeListener(_onTaskUpdate);
    TranslationStore().removeListener(_onStoreUpdate);
    _filterTabs.removeListener(_onFilterTabChanged);
    _filterTabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _loadStore() {
    _totals = TranslationStore().chapterPageCounts(
      widget.sourceKey,
      widget.cid,
    );
    final config = widget.config;
    _saved = {
      for (final chapter in TranslationStore().chaptersFor(
        widget.sourceKey,
        widget.cid,
        sourceLang: config.sourceLang,
        targetLang: config.targetLang,
        dialogueOnly: config.dialogueOnly,
      ))
        chapter.identity.chapterId: chapter.pageCount,
    };
  }

  void _restoreKnownPageCounts() {
    final store = TranslationStore();
    var changed = false;
    void remember(String eid, int total, int time) {
      if (total <= 0 || _totals.containsKey(eid)) return;
      changed =
          store.recordChapterPageCount(
            widget.sourceKey,
            widget.cid,
            eid,
            total,
            updatedAt: time,
          ) ||
          changed;
    }

    // Old translation tasks may have processed only a partial local download.
    // Only download tasks retain a complete source page list.
    for (final download in LocalManager().downloadingTasks) {
      if (download is! ImagesDownloadTask ||
          download.id != widget.cid ||
          download.source.key != widget.sourceKey) {
        continue;
      }
      for (final entry in download.chapterPageCounts.entries) {
        // A restored list predates a newer page-count record from sync.
        remember(entry.key, entry.value, 0);
      }
    }
    if (changed) {
      _totals = store.chapterPageCounts(widget.sourceKey, widget.cid);
      if (store.hasTranslationsForComic(widget.sourceKey, widget.cid)) {
        DataSync().onTranslationsChanged();
      }
    }
  }

  Future<void> _fetchPageCounts(List<int> indices) async {
    if (_fetchingPageCounts || indices.isEmpty) return;
    setState(() => _fetchingPageCounts = true);
    var failures = 0;
    for (final index in indices) {
      if (!mounted) break;
      final eid = widget.entries[index].$1;
      try {
        if (widget.comicType == ComicType.local) {
          final pages = await LocalManager().getImages(
            widget.cid,
            widget.comicType,
            eid == '0' ? 0 : eid,
          );
          if (pages.isEmpty) throw StateError('No pages');
        } else {
          final isCollection = ComicCollectionStore.isCollectionSourceKey(
            widget.sourceKey,
          );
          final source = ComicSource.find(widget.sourceKey);
          if (!isCollection && source?.loadComicPages == null) {
            throw StateError('Missing source');
          }
          final ep = eid == '0' ? null : eid;
          final result =
              await (isCollection
                      ? loadCollectionPages(widget.cid, ep, preferNetwork: true)
                      : source!.loadComicPages!(widget.cid, ep))
                  .timeout(const Duration(seconds: 30));
          if (result.error || result.data.isEmpty) throw StateError('No pages');
          final store = TranslationStore();
          if (store.recordChapterPageCount(
                widget.sourceKey,
                widget.cid,
                eid,
                result.data.length,
              ) &&
              store.hasTranslationsForComic(widget.sourceKey, widget.cid)) {
            DataSync().onTranslationsChanged();
          }
        }
        if (!mounted) break;
        setState(_loadStore);
        if (!_totals.containsKey(eid)) failures++;
      } catch (e, s) {
        failures++;
        Log.warning('Chapter page count', '$e\n$s');
      }
    }
    if (!mounted) return;
    setState(() => _fetchingPageCounts = false);
    if (failures > 0) {
      context.showMessage(
        message: 'Could not fetch page counts for @count chapters'.tlParams({
          'count': failures,
        }),
      );
    }
  }

  void _loadTasks() {
    _taskFor.clear();
    _chapterFor.clear();
    for (final task in [..._manager.currentTasks, ..._manager.historyTasks]) {
      if (!task.matchesScope(widget.cid, widget.sourceKey, widget.config)) {
        continue;
      }
      for (final chapter in task.chapters) {
        if (chapter.canceled || _chapterFor.containsKey(chapter.eid)) continue;
        _chapterFor[chapter.eid] = chapter;
        _taskFor[chapter.eid] = task;
      }
    }
  }

  void _onStoreUpdate() {
    if (!mounted) return;
    setState(() {
      _loadStore();
      _pruneSelection();
    });
  }

  void _onTaskUpdate() {
    if (!mounted) return;
    setState(() {
      _loadTasks();
      _pruneSelection();
    });
  }

  _TranslationChapterRow _row(int index) {
    final eid = widget.entries[index].$1;
    final stored = _saved[eid] ?? 0;
    final task = _taskFor[eid];
    final chapter = _chapterFor[eid];
    final total = _totals[eid] ?? 0;
    if (task == null || chapter == null) {
      return _TranslationChapterRow(
        stored > 0
            ? _ChapterTranslationState.stored
            : _ChapterTranslationState.pending,
        stored,
        total,
        0,
        null,
        null,
      );
    }
    final active = _manager.currentTasks.contains(task);
    final knownTotal = total;
    final activity = active ? _manager.activityOf(task.id) : null;
    final live = _manager.livePagesOf(widget.cid, widget.sourceKey, chapter);
    final failures = math.max(0, live.processed - live.done);
    final complete = knownTotal > 0 && live.processed >= knownTotal;
    final taskComplete = chapter.total > 0 && live.processed >= chapter.total;
    final processing =
        active &&
        (!taskComplete || (failures > 0 && activity?.chapterEid == eid));
    final state = processing
        ? chapter.paused || task.status == PreTranslationTaskStatus.paused
              ? _ChapterTranslationState.paused
              : activity?.chapterEid == eid
              ? _ChapterTranslationState.running
              : _ChapterTranslationState.queued
        : complete
        ? failures > 0
              ? _ChapterTranslationState.failed
              : _ChapterTranslationState.complete
        : failures > 0
        ? _ChapterTranslationState.failed
        : stored > 0
        ? _ChapterTranslationState.stored
        : _ChapterTranslationState.pending;
    final uncommitted = activity?.chapterEid == eid
        ? activity!.uncommittedPages
        : 0.0;
    return _TranslationChapterRow(
      state,
      math.max(stored, live.done),
      knownTotal,
      failures,
      knownTotal > 0
          ? (math.max(stored, chapter.done + chapter.failed + uncommitted) /
                    knownTotal)
                .clamp(0.0, 1.0)
          : null,
      task,
    );
  }

  bool _matches(int index) {
    if (_hidden.contains(index)) return false;
    final query = _search.text.replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (query.isNotEmpty &&
        !widget.entries[index].$2
            .replaceAll(RegExp(r'\s'), '')
            .toLowerCase()
            .contains(query)) {
      return false;
    }
    final row = _row(index);
    return switch (_filter) {
      _TranslationFilter.all => true,
      _TranslationFilter.pending =>
        row.state == _ChapterTranslationState.pending,
      _TranslationFilter.translating => row.active,
      _TranslationFilter.stored => row.saved > 0,
      _TranslationFilter.attention =>
        row.failed > 0 || row.state == _ChapterTranslationState.paused,
    };
  }

  List<int> get _visible {
    if (_groups.isEmpty) return [];
    final rows = _groups[_group.clamp(0, _groups.length - 1)].$2
        .where(_matches)
        .toList();
    rows.sort((a, b) {
      final active = (_row(b).active ? 1 : 0) - (_row(a).active ? 1 : 0);
      return active == 0 ? a.compareTo(b) : active;
    });
    return rows;
  }

  bool _pickable(int index) {
    if (_filter == _TranslationFilter.translating) return _row(index).active;
    return !_isChapterActive(index);
  }

  bool _isChapterActive(int index) => _manager.isChapterActive(
    widget.cid,
    widget.sourceKey,
    widget.entries[index].$1,
    config: widget.config,
  );

  void _pruneSelection() =>
      _selected.removeWhere((i) => !_matches(i) || !_pickable(i));
  void _update(VoidCallback action) => setState(action);
  void _onFilterTabChanged() {
    final filter = _availableFilters[_filterTabs.index];
    if (_filterTabs.indexIsChanging || _filter == filter) return;
    setState(() {
      _filter = filter;
      _selected.clear();
    });
  }

  void _select(int index) => setState(() {
    if (!_selected.remove(index)) _selected.add(index);
  });
  void _selectVisible() => setState(() {
    final eligible = _visible.where(_pickable).toList();
    if (eligible.isNotEmpty && eligible.every(_selected.contains)) {
      _selected.removeAll(eligible);
    } else {
      _selected.addAll(eligible);
    }
  });

  void _pauseSelected() {
    for (final index in _selected.toList()) {
      final row = _row(index);
      if (row.active && row.state != _ChapterTranslationState.paused) {
        _manager.pauseChapter(row.task!.id, widget.entries[index].$1);
      }
    }
  }

  void _resumeSelected() {
    for (final index in _selected.toList()) {
      final row = _row(index);
      if (row.state == _ChapterTranslationState.paused) {
        _manager.resumeChapter(row.task!.id, widget.entries[index].$1);
      }
    }
  }

  void _cancelSelected() {
    final chapters = [
      for (final index in _selected)
        if (_row(index).active)
          (_row(index).task!.id, widget.entries[index].$1),
    ];
    if (chapters.isEmpty) return;
    showConfirmDialog(
      context: _contentContext,
      title: 'Cancel selected chapter translations?'.tl,
      content: 'Stop translation of @count chapters? Saved pages are kept.'
          .tlParams({'count': chapters.length}),
      onConfirm: () {
        for (final (taskId, eid) in chapters) {
          _manager.cancelChapter(taskId, eid);
        }
        if (mounted) setState(_selected.clear);
      },
    );
  }

  String _status(_TranslationChapterRow row) {
    final counts = {
      'done': row.saved,
      'total': row.total,
      'failed': row.failed,
    };
    return switch (row.state) {
      _ChapterTranslationState.pending =>
        '${'Pending translation'.tl}${row.total > 0 ? ' · ${'@count pages'.tlParams({'count': row.total})}' : ''}',
      _ChapterTranslationState.stored =>
        row.total > 0
            ? '@done/@total pages saved'.tlParams(counts)
            : '@count pages saved · Total unknown'.tlParams({
                'count': row.saved,
              }),
      _ChapterTranslationState.complete =>
        'Complete · @done/@total pages'.tlParams(counts),
      _ChapterTranslationState.failed =>
        (row.total > 0
                ? '@done/@total translated · @failed failed'
                : '@done pages saved · Total unknown · @failed failed')
            .tlParams(counts),
      _ChapterTranslationState.queued =>
        '${'Queued'.tl}${row.total > 0 ? ' · ${'@count pages'.tlParams({'count': row.total})}' : ''}',
      _ =>
        '${(row.state == _ChapterTranslationState.paused ? 'Paused' : 'Translating').tl} · '
            '${row.total > 0 ? '@done/@total pages'.tlParams(counts) : '@count pages saved · Total unknown'.tlParams({'count': row.saved})}'
            '${row.progress == null ? '' : ' · ${(row.progress! * 100).round()}%'}',
    };
  }

  bool _ready() {
    if (ImageTranslationService.isReadyForLang(widget.config.sourceLang)) {
      return true;
    }
    context.showMessage(message: 'Configure AI translation first'.tl);
    return false;
  }

  void _start(List<int> indices, {bool replace = false}) {
    if (indices.isEmpty || !_ready()) return;
    final picked = List<int>.of(indices)..sort();
    showConfirmDialog(
      context: _contentContext,
      title:
          (replace
                  ? 'Re-translate selected chapters?'
                  : 'Start pre-translation?')
              .tl,
      content: replace
          ? 'This clears the translations of the @count selected chapters, then translates them again.'
                .tlParams({'count': picked.length})
          : 'About to translate @count chapters. If your configured LLM endpoint is paid, this may cost money.'
                .tlParams({'count': picked.length}),
      onConfirm: () async {
        // Recheck after confirmation: another action may have started a chapter.
        if (picked.any(_isChapterActive)) {
          context.showMessage(
            message: 'A pre-translation task is already running'.tl,
          );
          return;
        }
        if (replace) {
          for (final index in picked) {
            await ImageTranslationService.instance.retranslate(
              widget.cid,
              widget.sourceKey,
              eid: widget.entries[index].$1,
              config: widget.config,
            );
          }
          _manager.resetChapterStatus(widget.cid, widget.sourceKey, {
            for (final i in picked) widget.entries[i].$1,
          }, config: widget.config);
        }
        if (!mounted) return;
        final task = widget.finishSelect(picked, replace: replace);
        if (task?.status == PreTranslationTaskStatus.paused) {
          for (final index in picked) {
            _manager.resumeChapter(task!.id, widget.entries[index].$1);
          }
        }
        setState(_selected.clear);
      },
    );
  }

  void _retryChapter(int index) {
    if (!_ready()) return;
    final row = _row(index);
    final chapter = _chapterFor[widget.entries[index].$1];
    if (chapter == null || row.failed == 0) return;
    showConfirmDialog(
      context: _contentContext,
      title: 'Retry failed pages'.tl,
      content:
          'Retry @count failed pages? Completed pages are kept. A paid service may charge for this request.'
              .tlParams({'count': row.failed}),
      onConfirm: () {
        final current = row.task;
        if (current != null && _manager.currentTasks.contains(current)) {
          _manager.retryChapter(current.id, chapter.eid);
          return;
        }
        _manager.start(
          cid: widget.cid,
          sourceKey: widget.sourceKey,
          comicType: widget.comicType,
          config: current?.config ?? widget.config,
          title: widget.title,
          cover: widget.cover,
          chapters: [
            PreTranslationChapter.fromJson(chapter.toJson())..paused = false,
          ],
        );
      },
    );
  }

  void _deleteChapter(int index) => _deleteChapters([index]);

  void _deleteChapters(List<int> indices) {
    final picked = indices.where((index) => _row(index).saved > 0).toList();
    if (picked.isEmpty) return;
    if (picked.any(_isChapterActive)) {
      context.showMessage(
        message: 'Stop this chapter before replacing its translation'.tl,
      );
      return;
    }
    showConfirmDialog(
      context: _contentContext,
      title:
          (picked.length == 1
                  ? "Delete this chapter's translation?"
                  : 'Delete selected chapter translations?')
              .tl,
      content: picked.length == 1
          ? 'This removes the stored translation and rendered pages of "@title". The original images are unaffected.'
                .tlParams({'title': widget.entries[picked.single].$2})
          : 'This removes stored translations and rendered pages of @count chapters. The original images are unaffected.'
                .tlParams({'count': picked.length}),
      onConfirm: () async {
        if (picked.any(_isChapterActive)) return;
        for (final index in picked) {
          await ImageTranslationService.instance.retranslate(
            widget.cid,
            widget.sourceKey,
            eid: widget.entries[index].$1,
            config: widget.config,
          );
          _manager.resetChapterStatus(widget.cid, widget.sourceKey, {
            widget.entries[index].$1,
          }, config: widget.config);
        }
        if (mounted) {
          setState(() {
            _loadStore();
            _selected.removeAll(picked);
          });
        }
      },
    );
  }

  void _deleteComicTranslation() {
    showConfirmDialog(
      context: _contentContext,
      title: 'Delete these translations for this comic?'.tl,
      content:
          'This deletes this comic’s translated text and rendered pages for the selected languages and text scope, and resets its glossary.'
              .tl,
      onConfirm: () async {
        for (final task in _manager.currentTasks.toList()) {
          if (task.matchesScope(widget.cid, widget.sourceKey, widget.config)) {
            _manager.cancel(task.id);
          }
        }
        await ImageTranslationService.instance.retranslate(
          widget.cid,
          widget.sourceKey,
          config: widget.config,
        );
        _manager.resetComicStatus(
          widget.cid,
          widget.sourceKey,
          config: widget.config,
        );
        if (mounted) {
          setState(() {
            _loadStore();
            _selected.clear();
          });
          context.showMessage(message: 'Translation results cleared'.tl);
        }
      },
    );
  }

  void _readChapter(int index) {
    final entries = widget.entries;
    final chapters = widget.groups == null
        ? ComicChapters({for (final entry in entries) entry.$1: entry.$2})
        : ComicChapters.grouped({
            for (final group in widget.groups!)
              group.$1: {
                for (final i in group.$2) entries[i].$1: entries[i].$2,
              },
          });
    final details =
        ComicDetailsCache().find(widget.sourceKey, widget.cid) ??
        ComicDetails.fromJson({
          'title': widget.title,
          'cover': widget.cover,
          'comicId': widget.cid,
          'sourceKey': widget.sourceKey,
          'tags': <String, List<String>>{},
        });
    final history =
        HistoryManager().find(widget.cid, widget.comicType) ??
        History.fromModel(model: details, ep: 0, page: 0);
    final group = widget.groups?.indexWhere((g) => g.$2.contains(index));
    final chapter = group == null || group < 0
        ? index + 1
        : widget.groups![group].$2.indexOf(index) + 1;
    context.to(
      () => Reader(
        type: widget.comicType,
        cid: widget.cid,
        name: widget.title,
        chapters: chapters,
        history: history,
        initialChapter: chapter,
        initialPage: 1,
        initialChapterGroup: group == null || group < 0 ? null : group + 1,
        author: details.findAuthor() ?? '',
        tags: details.plainTags,
      ),
    );
  }

  String _edition(int index) =>
      widget.groups?.where((g) => g.$2.contains(index)).firstOrNull?.$1 ?? '';
  void _showChapterDetails(int index) {
    showDialog<void>(
      context: _contentContext,
      builder: (context) => ContentDialog(
        title: widget.entries[index].$2,
        content: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('${_edition(index)}\n${_status(_row(index))}'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close'.tl),
          ),
        ],
      ),
    );
  }

  void _chapterMenu(int index, Offset offset) {
    final row = _row(index);
    final task = row.task;
    showMenuX(
      _contentContext,
      offset,
      [
        if (row.saved > 0)
          MenuEntry(
            icon: Icons.menu_book_outlined,
            text: 'Read chapter'.tl,
            subtitle: '@count pages saved'.tlParams({'count': row.saved}),
            role: MenuEntryRole.primary,
            onClick: () => _readChapter(index),
          ),
        if (row.active)
          MenuEntry(
            icon: row.state == _ChapterTranslationState.paused
                ? Icons.play_arrow
                : Icons.pause,
            text:
                (row.state == _ChapterTranslationState.paused
                        ? 'Resume chapter'
                        : 'Pause chapter')
                    .tl,
            role: MenuEntryRole.quick,
            onClick: () => row.state == _ChapterTranslationState.paused
                ? _manager.resumeChapter(task!.id, widget.entries[index].$1)
                : _manager.pauseChapter(task!.id, widget.entries[index].$1),
          )
        else if (row.failed > 0)
          MenuEntry(
            icon: Icons.refresh_rounded,
            text: 'Retry failed pages'.tl,
            role: MenuEntryRole.quick,
            onClick: () => _retryChapter(index),
          )
        else
          MenuEntry(
            icon: Icons.info_outline,
            text: 'Chapter progress'.tl,
            role: MenuEntryRole.quick,
            onClick: () => _showChapterDetails(index),
          ),
        MenuEntry(
          icon: Icons.schedule,
          text:
              (row.state == _ChapterTranslationState.pending
                      ? 'Pre-translate'
                      : 'View tasks')
                  .tl,
          role: MenuEntryRole.quick,
          onClick: () => row.state == _ChapterTranslationState.pending
              ? _start([index])
              : _openTasks(task?.id),
        ),
        MenuEntry(
          icon: Icons.info_outline,
          text: 'Chapter details'.tl,
          role: MenuEntryRole.quick,
          onClick: () => _showChapterDetails(index),
        ),
        if (!_fetchingPageCounts)
          MenuEntry(
            icon: Icons.format_list_numbered,
            text:
                (row.total > 0 ? 'Refresh page count' : 'Fetch page count').tl,
            group: MenuGroup.organize,
            onClick: () => _fetchPageCounts([index]),
          ),
        if (!_isChapterActive(index))
          MenuEntry(
            icon: Icons.refresh_rounded,
            text: 'Re-translate chapter'.tl,
            group: MenuGroup.organize,
            onClick: () => _start([index], replace: true),
          ),
        MenuEntry(
          icon: Icons.library_books_outlined,
          text: 'Chapters of this edition'.tl,
          group: MenuGroup.organize,
          onClick: () {
            final group = _groups.indexWhere((g) => g.$2.contains(index));
            _filterTabs.index = 0;
            _update(() {
              if (group >= 0) _group = group;
              _search.clear();
              _selected.clear();
            });
          },
        ),
        if (_isChapterActive(index) && task != null)
          MenuEntry(
            icon: Icons.close,
            text: 'Cancel translation'.tl,
            destructive: true,
            onClick: () =>
                _manager.cancelChapter(task.id, widget.entries[index].$1),
          ),
        if (row.saved > 0 && !_isChapterActive(index))
          MenuEntry(
            icon: Icons.delete_outline,
            text: 'Delete chapter translation'.tl,
            destructive: true,
            onClick: () => _deleteChapter(index),
          ),
      ],
      title: widget.entries[index].$2,
      subtitle: [
        widget.title,
        _edition(index),
      ].where((s) => s.isNotEmpty).join(' · '),
      leading: _bookMark(menu: true),
    );
  }

  void _openTasks([String? taskId]) =>
      context.to(() => TasksPage(initialExpandedTaskId: taskId));

  void _openComicDetails() => context.to(
    () => ComicPage(
      id: widget.cid,
      sourceKey: widget.sourceKey,
      title: widget.title,
      cover: widget.cover,
    ),
  );

  void _pageMenu(Offset offset) => showMenuX(_contentContext, offset, [
    if (!_fetchingPageCounts)
      MenuEntry(
        icon: Icons.format_list_numbered,
        text: 'Fill missing page counts'.tl,
        onClick: () => _fetchPageCounts(
          _visible.where((index) => _row(index).total <= 0).toList(),
        ),
      ),
    MenuEntry(
      icon: Icons.info_outline,
      text: 'Open comic details'.tl,
      onClick: _openComicDetails,
    ),
    MenuEntry(
      icon: Icons.menu_book_outlined,
      text: 'Glossary'.tl,
      onClick: () => context.to(
        () => GlossaryEditorPage(
          cid: widget.cid,
          sourceKey: widget.sourceKey,
          title: widget.title,
        ),
      ),
    ),
    MenuEntry(
      icon: Icons.delete_outline,
      text: 'Delete all translations'.tl,
      destructive: true,
      onClick: _deleteComicTranslation,
    ),
  ], title: widget.title);

  @override
  Widget build(BuildContext context) => _buildWorkspace();
}
