import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/translations.dart';

Future<bool?> showChapterOrderEditor({
  required BuildContext context,
  required ComicChapters chapters,
  required String comicId,
  required String sourceKey,
  int initialGroupIndex = 0,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) => _ChapterOrderEditor(
      chapters: chapters,
      comicId: comicId,
      sourceKey: sourceKey,
      initialGroupIndex: initialGroupIndex,
    ),
  ),
);

class _ChapterOrderEditor extends StatefulWidget {
  const _ChapterOrderEditor({
    required this.chapters,
    required this.comicId,
    required this.sourceKey,
    required this.initialGroupIndex,
  });

  final ComicChapters chapters;
  final String comicId;
  final String sourceKey;
  final int initialGroupIndex;

  @override
  State<_ChapterOrderEditor> createState() => _ChapterOrderEditorState();
}

class _ChapterOrderEditorState extends State<_ChapterOrderEditor> {
  late final _titles = widget.chapters.titles.toList();
  late final _groups = widget.chapters.groups.toList();
  late final List<int> _order = ChapterOrderPrefs.orderedIndices(
    widget.chapters,
    widget.comicId,
    widget.sourceKey,
  );
  late int _groupIndex = _groups.isEmpty
      ? 0
      : widget.initialGroupIndex.clamp(0, _groups.length - 1);
  bool _saving = false;

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
    final offset = _groupOffset;
    setState(() {
      final chapter = _order.removeAt(offset + oldIndex);
      _order.insert(offset + newIndex, chapter);
    });
  }

  // Only the visible group; other groups keep their staged order.
  void _restoreGroup() {
    final offset = _groupOffset;
    setState(() {
      for (var i = 0; i < _count; i++) {
        _order[offset + i] = offset + i;
      }
    });
  }

  Future<void> _save() async {
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
            absorbing: _saving,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    "Drag chapters or use the arrows to reorder. Changes apply to this comic only."
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
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: _restoreGroup,
                    icon: const Icon(Icons.restore),
                    label: Text("Restore source order".tl),
                  ),
                ),
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
                  onPressed: _saving ? null : _save,
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
