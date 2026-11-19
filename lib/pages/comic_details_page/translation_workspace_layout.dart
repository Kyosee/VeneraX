part of 'comic_page.dart';

extension _TranslationWorkspaceLayout on _SelectPreTranslateChapterState {
  Color get _ink => Theme.of(context).colorScheme.onSurface;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _paper => Theme.of(context).colorScheme.surface;
  Color get _line => Theme.of(context).colorScheme.outlineVariant;
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _soft => Theme.of(context).colorScheme.surfaceContainerLow;
  Color get _tint => Theme.of(context).colorScheme.surfaceContainerHighest;
  Color get _warning => Theme.of(context).colorScheme.error;
  Color get _success => Theme.of(context).colorScheme.primary;

  TextStyle _text(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
    double height = 1.48,
  }) => TextStyle(
    fontSize: size,
    color: color ?? _ink,
    fontWeight: weight,
    height: height,
  );

  Widget _bookMark({bool menu = false}) {
    final width = menu ? 42.0 : 40.0;
    const height = 56.0;
    final placeholder = ColoredBox(
      color: _tint,
      child: Icon(Icons.menu_book_outlined, color: _muted, size: 24),
    );
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: widget.cover.isEmpty
            ? placeholder
            : Image(
                image: CachedImageProvider(
                  widget.cover,
                  sourceKey: widget.sourceKey,
                  cid: widget.cid,
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }

  Offset _anchor(BuildContext target) {
    final box = target.findRenderObject() as RenderBox?;
    return box?.localToGlobal(Offset(box.size.width, box.size.height)) ??
        Offset.zero;
  }

  Widget _buildWorkspace() {
    return Builder(
      builder: (context) {
        _contentContext = context;
        return Scaffold(
          appBar: Appbar(
            title: Text('Comic Translation'.tl),
            actions: [
              TextButton(
                key: const ValueKey('translation-manage'),
                onPressed: () => _update(() {
                  _manage = !_manage;
                  _selected.clear();
                }),
                child: Text((_manage ? 'Done' : 'Manage').tl),
              ),
              Builder(
                builder: (menuContext) => IconButton(
                  tooltip: 'more'.tl,
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => _pageMenu(_anchor(menuContext)),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                _header(),
                _searchField(),
                _filters(),
                _editionBar(),
                Expanded(child: _chapterList()),
                if (_picking) _footer(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header() => Tooltip(
    message: 'Open comic details'.tl,
    child: InkWell(
      key: const ValueKey('translation-comic-header'),
      onTap: _openComicDetails,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _bookMark(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    key: const ValueKey('translation-comic-title'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.author?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.author!.trim(),
                      key: const ValueKey('translation-comic-author'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: _muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: AppSearchField(
      key: const ValueKey('translation-search'),
      controller: _search,
      onChanged: (_) => _update(_selected.clear),
      hintText: 'Search chapter name or number'.tl,
    ),
  );

  Widget _filters() => PageStorage(
    bucket: _tabStorage,
    child: AppTabBar(
      key: const ValueKey('translation-filters'),
      controller: _filterTabs,
      tabs: [
        for (final filter in _availableFilters)
          Tab(
            key: ValueKey('translation-filter-${filter.name}'),
            text: switch (filter) {
              _TranslationFilter.all => 'All'.tl,
              _TranslationFilter.pending => 'Pending translation'.tl,
              _TranslationFilter.translating => 'Translating'.tl,
              _TranslationFilter.stored => 'Translated'.tl,
              _TranslationFilter.attention => 'Needs attention'.tl,
            },
          ),
      ],
    ),
  );

  Widget _editionBar() {
    final visible = _visible;
    final eligible = visible.where(_pickable).toList();
    final selected = eligible.isNotEmpty && eligible.every(_selected.contains);
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Container(
              height: math.max(
                48,
                MediaQuery.textScalerOf(context).scale(14) + 24,
              ),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _soft,
                border: Border.all(color: _line),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ButtonTheme(
                alignedDropdown: true,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const ValueKey('translation-edition'),
                    value: _groups.isEmpty ? null : _group,
                    isExpanded: true,
                    itemHeight: null,
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    borderRadius: BorderRadius.circular(12),
                    dropdownColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainer,
                    icon: Icon(Icons.expand_more, size: 20, color: _muted),
                    style: Theme.of(context).textTheme.bodyMedium,
                    selectedItemBuilder: (context) => [
                      for (final group in _groups)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            group.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    items: [
                      for (var i = 0; i < _groups.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(_groups[i].$1),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        _update(() {
                          _group = value;
                          _selected.clear();
                        });
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (_picking && eligible.isNotEmpty)
            Flexible(
              flex: 2,
              child: Tooltip(
                message:
                    (selected
                            ? 'Deselect visible chapters'
                            : 'Select visible chapters')
                        .tl,
                child: MediaQuery.textScalerOf(context).scale(14) > 20
                    ? IconButton(
                        key: const ValueKey('translation-select-visible'),
                        onPressed: _selectVisible,
                        icon: Icon(
                          selected ? Icons.deselect : Icons.select_all,
                        ),
                      )
                    : TextButton.icon(
                        key: const ValueKey('translation-select-visible'),
                        onPressed: _selectVisible,
                        icon: Icon(
                          selected ? Icons.deselect : Icons.select_all,
                          size: 18,
                        ),
                        label: Text((selected ? 'Deselect' : 'Select All').tl),
                      ),
              ),
            )
          else
            Text(
              '@count chapters'.tlParams({'count': visible.length}),
              style: _text(12, color: _muted),
            ),
        ],
      ),
    );
  }

  Widget _chapterList() {
    final indices = _visible;
    if (indices.isEmpty) {
      return Center(
        child: Text('No matching chapters'.tl, style: _text(14, color: _muted)),
      );
    }
    return ListView.builder(
      key: PageStorageKey('translation-$_group-${_filter.name}'),
      padding: EdgeInsets.zero,
      itemCount: indices.length,
      itemBuilder: (_, index) => _chapterTile(indices[index]),
    );
  }

  Widget _chapterTile(int index) {
    final row = _row(index);
    final selected = _selected.contains(index);
    final eligible = _pickable(index);
    final statusColor = row.failed > 0
        ? _warning
        : row.active
        ? _accent
        : row.state == _ChapterTranslationState.complete
        ? _success
        : _muted;
    return Builder(
      builder: (rowContext) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
              _chapterMenu(index, _anchor(rowContext)),
        },
        child: GestureDetector(
          onSecondaryTapDown: (details) =>
              _chapterMenu(index, details.globalPosition),
          child: TranslationProgressSurface(
            key: ValueKey('translation-progress-${widget.entries[index].$1}'),
            progress: row.progress,
            active: row.active,
            paused: row.state == _ChapterTranslationState.paused,
            // Only active rows receive a fill; ordinary rows remain opaque.
            child: Container(
              key: ValueKey('translation-chapter-${widget.entries[index].$1}'),
              constraints: const BoxConstraints(minHeight: 61),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: selected
                    ? row.active
                          ? _tint.withValues(alpha: .24)
                          : _tint
                    : row.active
                    ? null
                    : _paper,
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      checked: _picking ? selected : null,
                      enabled: !_picking || eligible,
                      child: InkWell(
                        onLongPress: !_picking && eligible
                            ? () => _update(() {
                                _manage = true;
                                _selected.add(index);
                              })
                            : null,
                        onTap: _picking
                            ? eligible
                                  ? () => _select(index)
                                  : null
                            : row.saved > 0
                            ? () => _readChapter(index)
                            : () => _showChapterDetails(index),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              if (_picking) ...[
                                SizedBox(
                                  width: 28,
                                  height: 40,
                                  child: Checkbox(
                                    value: selected,
                                    onChanged: eligible
                                        ? (_) => _select(index)
                                        : null,
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.entries[index].$2,
                                      style: _text(
                                        14,
                                        weight: FontWeight.w600,
                                        height: 1.35,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _status(row),
                                      style: _text(
                                        12,
                                        color: statusColor,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (row.state == _ChapterTranslationState.failed)
                    TextButton(
                      onPressed: () => _retryChapter(index),
                      style: TextButton.styleFrom(foregroundColor: _warning),
                      child: Text(
                        'Retry @count pages'.tlParams({'count': row.failed}),
                      ),
                    )
                  else if (row.active)
                    TextButton(
                      key: ValueKey(
                        'translation-toggle-${widget.entries[index].$1}',
                      ),
                      onPressed: () =>
                          row.state == _ChapterTranslationState.paused
                          ? _manager.resumeChapter(
                              row.task!.id,
                              widget.entries[index].$1,
                            )
                          : _manager.pauseChapter(
                              row.task!.id,
                              widget.entries[index].$1,
                            ),
                      child: Text(
                        (row.state == _ChapterTranslationState.paused
                                ? 'Resume'
                                : 'Pause')
                            .tl,
                      ),
                    )
                  else if (!_picking &&
                      row.state == _ChapterTranslationState.pending)
                    TextButton(
                      onPressed: () => _start([index]),
                      child: Text('Pre-translate'.tl),
                    ),
                  IconButton(
                    key: ValueKey(
                      'translation-menu-${widget.entries[index].$1}',
                    ),
                    tooltip: 'more'.tl,
                    onPressed: () => _chapterMenu(index, _anchor(rowContext)),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer() {
    final pending = _selected.where((index) => _row(index).saved == 0).toList();
    final stored = _selected.where((index) => _row(index).saved > 0).toList();
    final translating = _filter == _TranslationFilter.translating;
    final library = _filter == _TranslationFilter.stored;
    final paused = _selected
        .where((index) => _row(index).state == _ChapterTranslationState.paused)
        .length;
    final running = _selected.length - paused;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _paper,
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@count chapters selected'.tlParams({'count': _selected.length}),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _muted),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (translating) ...[
                  if (running > 0 || _selected.isEmpty)
                    FilledButton.tonal(
                      key: const ValueKey('translation-pause-selected'),
                      onPressed: running == 0 ? null : _pauseSelected,
                      child: Text(
                        running == 0
                            ? 'Pause'.tl
                            : 'Pause @count chapters'.tlParams({
                                'count': running,
                              }),
                      ),
                    ),
                  if (paused > 0)
                    FilledButton.tonal(
                      key: const ValueKey('translation-resume-selected'),
                      onPressed: _resumeSelected,
                      child: Text(
                        'Resume @count chapters'.tlParams({'count': paused}),
                      ),
                    ),
                  TextButton(
                    key: const ValueKey('translation-cancel-selected'),
                    onPressed: _selected.isEmpty ? null : _cancelSelected,
                    style: TextButton.styleFrom(foregroundColor: _warning),
                    child: Text(
                      _selected.isEmpty
                          ? 'Cancel translation'.tl
                          : 'Cancel @count chapters'.tlParams({
                              'count': _selected.length,
                            }),
                    ),
                  ),
                ] else ...[
                  if (pending.isNotEmpty || (stored.isEmpty && !library))
                    FilledButton(
                      key: const ValueKey('translation-start'),
                      onPressed: pending.isEmpty ? null : () => _start(pending),
                      child: Text(
                        pending.isEmpty
                            ? 'Start pre-translation'.tl
                            : 'Pre-translate @count chapters'.tlParams({
                                'count': pending.length,
                              }),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (stored.isNotEmpty || library)
                    FilledButton.tonal(
                      key: const ValueKey('translation-retranslate'),
                      onPressed: stored.isEmpty
                          ? null
                          : () => _start(stored, replace: true),
                      child: Text(
                        'Re-translate @count chapters'.tlParams({
                          'count': stored.length,
                        }),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (stored.isNotEmpty || library)
                    TextButton(
                      key: const ValueKey('translation-delete-selected'),
                      onPressed: stored.isEmpty
                          ? null
                          : () => _deleteChapters(stored),
                      style: TextButton.styleFrom(foregroundColor: _warning),
                      child: Text(
                        'Delete @count chapter translations'.tlParams({
                          'count': stored.length,
                        }),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
