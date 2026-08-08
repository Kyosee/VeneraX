import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Edits one collection: its name, cover, how its chapters are laid out, and
/// which comics belong to it (in what order).
///
/// Member order is the chapter order, so reordering here is the tool for "the
/// source listed part 3 before part 1".
class ComicCollectionEditPage extends StatefulWidget {
  const ComicCollectionEditPage({super.key, required this.collectionId});

  final String collectionId;

  @override
  State<ComicCollectionEditPage> createState() =>
      _ComicCollectionEditPageState();
}

class _ComicCollectionEditPageState extends State<ComicCollectionEditPage> {
  ComicCollection? collection;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      collection = ComicCollectionStore.find(widget.collectionId);
    });
  }

  /// Every edit rebuilds the source: it captures the chapter layout, so a stale
  /// one would keep serving the previous order or display mode.
  void _applyChange() {
    ComicSourceManager().refreshCollectionSources();
    _reload();
  }

  void _rename() {
    final c = collection;
    if (c == null) return;
    showInputDialog(
      context: context,
      title: "Collection name".tl,
      initialValue: c.name,
      hintText: "Leave empty to use the first comic's title".tl,
      onConfirm: (value) {
        ComicCollectionStore.update(c.id, name: value);
        _applyChange();
        return null;
      },
    );
  }

  void _setCover() {
    final c = collection;
    if (c == null) return;
    showInputDialog(
      context: context,
      title: "Cover image URL".tl,
      initialValue: c.customCover,
      hintText: "Leave empty to use the first comic's cover".tl,
      onConfirm: (value) {
        ComicCollectionStore.update(c.id, customCover: value);
        _applyChange();
        return null;
      },
    );
  }

  void _setDisplayMode(CollectionDisplayMode mode) {
    final c = collection;
    if (c == null || c.displayMode == mode) return;
    ComicCollectionStore.update(c.id, displayMode: mode);
    _applyChange();
  }

  void _renameMember(CollectionMember member) {
    final c = collection;
    if (c == null) return;
    showInputDialog(
      context: context,
      title: "Display name".tl,
      initialValue: member.displayName,
      hintText: "Leave empty to use the comic's title".tl,
      onConfirm: (value) {
        member.displayName = value;
        ComicCollectionStore.update(c.id, members: c.members);
        _applyChange();
        return null;
      },
    );
  }

  void _removeMember(CollectionMember member) {
    final c = collection;
    if (c == null) return;
    ComicCollectionStore.removeMember(c.id, member.sourceKey, member.comicId);
    _applyChange();
  }

  void _openMember(CollectionMember member) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: member.comicId,
        sourceKey: member.sourceKey,
        cover: member.cachedCover,
        title: member.label,
      ),
    );
  }

  /// Opens the collection itself, so the user can check the result of an edit
  /// without going back to the list first.
  void _preview() {
    final c = collection;
    if (c == null) return;
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: c.id,
        sourceKey: c.sourceKey,
        cover: c.displayCover,
        title: c.displayName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = collection;
    if (c == null) {
      // The collection can vanish under us: a sync download or a delete on
      // another screen replaces the whole settings map.
      return Scaffold(
        appBar: Appbar(title: Text("Collections".tl)),
        body: Center(child: Text("This collection no longer exists".tl)),
      );
    }
    return Scaffold(
      appBar: Appbar(
        title: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Tooltip(
            message: "Details".tl,
            child: IconButton(
              icon: const Icon(Icons.chrome_reader_mode_outlined),
              onPressed: _preview,
            ),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        padding: EdgeInsets.fromLTRB(0, 0, 0, context.padding.bottom + 8),
        buildDefaultDragHandles: false,
        header: _buildHeader(c),
        onReorderItem: (oldIndex, newIndex) {
          ComicCollectionStore.reorderMember(c.id, oldIndex, newIndex);
          _applyChange();
        },
        itemCount: c.members.length,
        itemBuilder: (context, index) =>
            _buildMemberTile(c, c.members[index], index),
      ),
    );
  }

  Widget _buildHeader(ComicCollection c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text("Collection name".tl),
          subtitle: Text(
            c.name.trim().isEmpty
                ? "Using the first comic's title".tl
                : c.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.edit),
          onTap: _rename,
        ),
        ListTile(
          title: Text("Cover".tl),
          subtitle: Text(
            c.customCover.trim().isEmpty
                ? "Using the first comic's cover".tl
                : c.customCover,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.edit),
          onTap: _setCover,
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text("Chapter layout".tl, style: ts.s14),
        ),
        RadioGroup<CollectionDisplayMode>(
          groupValue: c.displayMode,
          onChanged: (v) => v == null ? null : _setDisplayMode(v),
          child: Column(
            children: [
              RadioListTile<CollectionDisplayMode>(
                value: CollectionDisplayMode.flat,
                title: Text("Merged chapters".tl),
                subtitle: Text(
                  "One chapter list. Use when each comic is one instalment.".tl,
                  style: ts.s12,
                ),
              ),
              RadioListTile<CollectionDisplayMode>(
                value: CollectionDisplayMode.tabs,
                title: Text("Chapter tabs".tl),
                subtitle: Text(
                  "One tab per comic. Use when each comic has its own chapters."
                      .tl,
                  style: ts.s12,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "@n comics".tlParams({'n': c.members.length}),
                  style: ts.s14,
                ),
              ),
              if (c.members.length > 1)
                Text(
                  "Drag to reorder".tl,
                  style: ts.s12.copyWith(color: context.colorScheme.outline),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        if (c.members.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              "Long-press a comic in any list and choose 'Add to collection'.".tl,
              style: ts.s12.copyWith(color: context.colorScheme.outline),
            ),
          ),
      ],
    );
  }

  Widget _buildMemberTile(
    ComicCollection c,
    CollectionMember member,
    int index,
  ) {
    final type = ComicType.fromKey(member.sourceKey);
    // A member whose source is gone still lists, so the user can see what is
    // broken and remove or replace it rather than wonder where a chapter went.
    final available = type == ComicType.local
        ? LocalManager().find(member.comicId, ComicType.local) != null
        : ComicSource.find(member.sourceKey) != null;
    return ListTile(
      key: ValueKey(member.refKey),
      leading: SizedBox(
        width: 36,
        height: 48,
        child: _buildMemberCover(member, type),
      ),
      title: Text(
        member.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: available
            ? null
            : TextStyle(color: context.colorScheme.error),
      ),
      subtitle: Text(
        available
            ? (member.cachedSubtitle.trim().isNotEmpty
                  ? member.cachedSubtitle
                  : _sourceLabel(member, type))
            : "Unavailable".tl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ts.s12,
      ),
      onTap: available ? () => _openMember(member) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.label_outline,
                text: "Display name".tl,
                onClick: () => _renameMember(member),
              ),
              if (available)
                MenuEntry(
                  icon: Icons.chrome_reader_mode_outlined,
                  text: "Details".tl,
                  onClick: () => _openMember(member),
                ),
              MenuEntry(
                icon: Icons.remove_circle_outline,
                text: "Remove from collection".tl,
                color: context.colorScheme.error,
                onClick: () => _removeMember(member),
              ),
            ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Icon(
                Icons.drag_indicator,
                color: context.colorScheme.outline,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberCover(CollectionMember member, ComicType type) {
    final cover = member.cachedCover.trim();
    if (cover.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: context.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    ImageProvider? provider;
    if (type == ComicType.local) {
      final local = LocalManager().find(member.comicId, ComicType.local);
      provider = local == null ? null : LocalComicImageProvider(local);
    } else {
      provider = CachedImageProvider(
        cover,
        sourceKey: member.sourceKey,
        cid: member.comicId,
      );
    }
    if (provider == null) {
      return Container(
        decoration: BoxDecoration(
          color: context.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image(image: provider, fit: BoxFit.cover),
    );
  }

  String _sourceLabel(CollectionMember member, ComicType type) {
    if (type == ComicType.local) return "Local".tl;
    return ComicSource.find(member.sourceKey)?.name ?? member.sourceKey;
  }
}
