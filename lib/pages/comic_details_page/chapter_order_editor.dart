import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/utils/translations.dart';

Future<bool?> showChapterOrderEditor({
  required BuildContext context,
  required ComicChapters chapters,
  required String comicId,
  required String sourceKey,
  int initialGroupIndex = 0,
  Future<Map<String, DateTime>> Function(Iterable<String>)? loadModifiedTimes,
}) {
  final webdav = WebdavLibraryClient.forSourceKey(sourceKey);
  final local = LocalManager().isInitialized
      ? LocalManager().find(comicId, ComicType.fromKey(sourceKey))
      : null;
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => _ChapterOrderEditor(
        chapters: chapters,
        comicId: comicId,
        sourceKey: sourceKey,
        initialGroupIndex: initialGroupIndex,
        loadModifiedTimes:
            loadModifiedTimes ??
            webdav?.chapterModifiedTimes ??
            local?.chapterModifiedTimes,
      ),
    ),
  );
}

enum _ChapterSort { name, nameDesc, modified, modifiedDesc, reverse }

class _ChapterOrderEditor extends StatefulWidget {
  const _ChapterOrderEditor({
    required this.chapters,
    required this.comicId,
    required this.sourceKey,
    required this.initialGroupIndex,
    required this.loadModifiedTimes,
  });

  final ComicChapters chapters;
  final String comicId;
  final String sourceKey;
  final int initialGroupIndex;
  final Future<Map<String, DateTime>> Function(Iterable<String>)?
  loadModifiedTimes;

  @override
  State<_ChapterOrderEditor> createState() => _ChapterOrderEditorState();
}

class _ChapterOrderEditorState extends State<_ChapterOrderEditor> {
  late final _titles = widget.chapters.titles.toList();
  late final _groups = widget.chapters.groups.toList();
  late final _ids = widget.chapters.ids.toList();
  late final List<int> _order = ChapterOrderPrefs.orderedIndices(
    widget.chapters,
    widget.comicId,
    widget.sourceKey,
  );
  late int _groupIndex = _groups.isEmpty
      ? 0
      : widget.initialGroupIndex.clamp(0, _groups.length - 1);
  bool _saving = false;
  bool _sorting = false;

  Future<void> _sort(_ChapterSort type) async {
    if (_saving || _sorting) return;
    final offset = _groupOffset;
    final group = _order.sublist(offset, offset + _count);
    if (type == _ChapterSort.reverse) {
      setState(() => _order.setRange(offset, offset + _count, group.reversed));
      return;
    }
    final byTime =
        type == _ChapterSort.modified || type == _ChapterSort.modifiedDesc;
    Map<String, DateTime> times = {};
    if (byTime) {
      setState(() => _sorting = true);
      try {
        times = await widget.loadModifiedTimes!(group.map((i) => _ids[i]));
        if (!mounted) return;
        if (!group.any((i) => times.containsKey(_ids[i]))) {
          context.showMessage(
            message: "Chapter modification times are unavailable".tl,
          );
          return;
        }
      } catch (_) {
        if (mounted) {
          context.showMessage(
            message: "Failed to load chapter modification times".tl,
          );
        }
        return;
      } finally {
        if (mounted) setState(() => _sorting = false);
      }
    }
    final positions = {for (var i = 0; i < group.length; i++) group[i]: i};
    final descending =
        type == _ChapterSort.nameDesc || type == _ChapterSort.modifiedDesc;
    group.sort((a, b) {
      int compared;
      if (byTime) {
        final first = times[_ids[a]], second = times[_ids[b]];
        // Unknown timestamps stay last in both directions.
        if (first == null || second == null) {
          return first == second
              ? positions[a]!.compareTo(positions[b]!)
              : first == null
              ? 1
              : -1;
        }
        compared = first.compareTo(second);
      } else {
        compared = WebdavLibrary.naturalCompare(_titles[a], _titles[b]);
      }
      if (compared == 0) return positions[a]!.compareTo(positions[b]!);
      return descending ? -compared : compared;
    });
    setState(() => _order.setRange(offset, offset + group.length, group));
  }

  int get _groupOffset {
    var offset = 0;
    for (var i = 0; i < _groupIndex; i++) {
      offset += widget.chapters.getGroupByIndex(i).length;
    }
    return offset;
  }

  int get _count => _groups.isEmpty
      ? _titles.length
      : widget.chapters.getGroupByIndex(_groupIndex).length;

  void _move(int oldIndex, int newIndex) {
    if (_saving || _sorting) return;
    final offset = _groupOffset;
    setState(() {
      final chapter = _order.removeAt(offset + oldIndex);
      _order.insert(offset + newIndex, chapter);
    });
  }

  // Only the visible group; other groups keep their staged order.
  void _restoreGroup() {
    if (_saving || _sorting) return;
    final offset = _groupOffset;
    setState(() {
      for (var i = 0; i < _count; i++) {
        _order[offset + i] = offset + i;
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _sorting) return;
    setState(() => _saving = true);
    try {
      await ChapterOrderPrefs.save(
        widget.chapters,
        widget.comicId,
        widget.sourceKey,
        _order,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        context.showMessage(message: "Failed to save chapter order".tl);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: Appbar(
          title: Text(
            "Customize chapter order".tl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: AbsorbPointer(
            absorbing: _saving || _sorting,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    "Sort chapters, drag them or use the arrows. Changes apply to the current group of this comic only."
                        .tl,
                  ),
                ),
                if (_groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<int>(
                      initialValue: _groupIndex,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: "Chapter group".tl,
                      ),
                      items: [
                        for (var i = 0; i < _groups.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              _groups[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (index) {
                        if (index != null) setState(() => _groupIndex = index);
                      },
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PopupMenuButton<_ChapterSort>(
                      tooltip: "Sort".tl,
                      onSelected: _sort,
                      icon: const Icon(Icons.sort),
                      itemBuilder: (_) => [
                        for (final item in [
                          (_ChapterSort.name, "Name Asc"),
                          (_ChapterSort.nameDesc, "Name Desc"),
                          (
                            _ChapterSort.modified,
                            "Modified time (oldest first)",
                          ),
                          (
                            _ChapterSort.modifiedDesc,
                            "Modified time (newest first)",
                          ),
                          (_ChapterSort.reverse, "Reverse"),
                        ])
                          PopupMenuItem(
                            value: item.$1,
                            enabled:
                                widget.loadModifiedTimes != null ||
                                (item.$1 != _ChapterSort.modified &&
                                    item.$1 != _ChapterSort.modifiedDesc),
                            child: Text(item.$2.tl),
                          ),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: _restoreGroup,
                      icon: const Icon(Icons.restore),
                      label: Text("Restore source order".tl),
                    ),
                  ],
                ),
                if (_sorting) const LinearProgressIndicator(),
                Expanded(
                  child: ReorderableListView.builder(
                    key: ValueKey(_groupIndex),
                    buildDefaultDragHandles: false,
                    itemCount: _count,
                    onReorderItem: _move,
                    itemBuilder: (context, index) {
                      final rawIndex = _order[_groupOffset + index];
                      return ListTile(
                        key: ValueKey(rawIndex),
                        title: Text(_titles[rawIndex]),
                        leading: Text('${index + 1}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: "Move up".tl,
                              icon: const Icon(Icons.arrow_upward),
                              onPressed: index == 0
                                  ? null
                                  : () => _move(index, index - 1),
                            ),
                            IconButton(
                              tooltip: "Move down".tl,
                              icon: const Icon(Icons.arrow_downward),
                              onPressed: index == _count - 1
                                  ? null
                                  : () => _move(index, index + 1),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: Tooltip(
                                message: "Reorder".tl,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text("Cancel".tl),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _saving || _sorting ? null : _save,
                  child: _saving
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text("Save".tl),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
