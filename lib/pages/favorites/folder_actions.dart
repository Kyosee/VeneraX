part of 'favorites_page.dart';

/// Dialogs that change the local folder layout. Each returns what changed, so
/// the page can update its selection and remembered state.

/// Picks where a folder goes: the top level or an existing folder.
class _FolderLocationPicker extends StatelessWidget {
  const _FolderLocationPicker({required this.value, required this.onChanged});

  final String? value;

  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    var tree = LocalFavoritesManager().folderTree;
    String label(String? folder) =>
        folder == null ? "Top level".tl : tree.pathLabel(folder);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        var box = context.findRenderObject() as RenderBox;
        var offset = box.localToGlobal(Offset.zero);
        var options = <String?>[null, ...tree.ordered];
        var picked = await showMenu<int>(
          context: context,
          useRootNavigator: true,
          position: RelativeRect.fromLTRB(
            offset.dx,
            offset.dy + box.size.height,
            offset.dx + box.size.width,
            0,
          ),
          constraints: BoxConstraints(
            minWidth: box.size.width,
            maxWidth: box.size.width,
          ),
          items: [
            for (var i = 0; i < options.length; i++)
              PopupMenuItem(
                value: i,
                child: Text(
                  label(options[i]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        );
        if (picked != null) onChanged(options[picked]);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Text("Location".tl),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(color: context.colorScheme.primary),
              ),
            ),
            Icon(Icons.arrow_drop_down, color: context.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

/// Moves [folder] into a folder picked from a list; returns whether it moved.
Future<bool> _showMoveFolderDialog(String folder) async {
  var manager = LocalFavoritesManager();
  var moved = false;
  await showPopUpWidget(
    App.rootContext,
    Builder(
      builder: (context) {
        var tree = manager.folderTree;
        var targets = <String?>[
          null,
          ...tree.ordered.where((f) => tree.canMove(folder, f)),
        ];
        return PopUpWidgetScaffold(
          title: "Move Folder".tl,
          body: ListView.builder(
            itemCount: targets.length,
            itemBuilder: (context, index) {
              var target = targets[index];
              var depth = target == null ? 0 : tree.depthOf(target) + 1;
              var isCurrent = tree.parentOf(folder) == target;
              return ListTile(
                contentPadding: EdgeInsetsDirectional.only(
                  start: 16.0 + 16 * (depth > 6 ? 6 : depth),
                  end: 16,
                ),
                leading: Icon(
                  target == null ? Icons.vertical_align_top : Icons.folder,
                ),
                title: Text(
                  target ?? "Top level".tl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: isCurrent ? const Icon(Icons.check) : null,
                onTap: () {
                  if (!isCurrent) {
                    manager.moveFolder(folder, target);
                    moved = true;
                  }
                  // The pop up hosts its own navigator; popping through this
                  // context would only empty it and leave the barrier up.
                  App.rootContext.pop();
                },
              );
            },
          ),
        );
      },
    ),
  );
  return moved;
}

/// Confirms and deletes [folder]; returns every folder deleted.
Future<List<String>?> _showDeleteFolderDialog(String folder) async {
  var manager = LocalFavoritesManager();
  var subfolders = manager.folderTree.descendantsOf(folder).length;
  var withSubfolders = false;
  List<String>? deleted;
  await showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Delete".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Delete folder '@f' ?".tlParams({"f": folder})),
                if (subfolders > 0) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () {
                      setState(() => withSubfolders = !withSubfolders);
                    },
                    child: Row(
                      children: [
                        Checkbox(
                          value: withSubfolders,
                          onChanged: (v) {
                            setState(() => withSubfolders = v ?? false);
                          },
                        ),
                        Expanded(
                          child: Text(
                            "Also delete its @c subfolders".tlParams({
                              "c": subfolders,
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    withSubfolders
                        ? "The comics saved in them are deleted too.".tl
                        : "Subfolders move up one level.".tl,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ).paddingHorizontal(16).paddingVertical(8),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colorScheme.error,
                ),
                onPressed: () {
                  deleted = manager.deleteFolder(
                    folder,
                    withSubfolders: withSubfolders,
                  );
                  context.pop();
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        },
      );
    },
  );
  return deleted;
}

/// Renames [folder]; returns the new name.
Future<String?> _showRenameFolderDialog(String folder) async {
  String? renamed;
  await showInputDialog(
    context: App.rootContext,
    title: "Rename".tl,
    hintText: "New Name".tl,
    initialValue: folder,
    onConfirm: (value) {
      // Pre-filled with the current name: confirming it unchanged is a
      // no-op, not a "folder exists" error.
      if (value == folder) return null;
      var err = validateFolderName(value, renaming: folder);
      if (err != null) return err;
      try {
        LocalFavoritesManager().rename(folder, value);
      } catch (e) {
        Log.error("Rename Folder", e.toString());
        return e.toString();
      }
      renamed = value;
      return null;
    },
  );
  return renamed;
}

/// Context menu entries for a local folder. [then] runs after the chosen
/// action finishes, for views outside the page's own rebuilds.
List<MenuEntry> _folderMenuEntries(
  BuildContext context,
  _FavoritesPageState favPage,
  String folder, {
  VoidCallback? then,
}) {
  var manager = LocalFavoritesManager();
  var nesting = manager.supportsFolderNesting;
  void run(Future<void> Function() action) {
    action().then((_) => then?.call());
  }

  return [
    if (nesting)
      MenuEntry(
        icon: Icons.create_new_folder_outlined,
        text: "New Subfolder".tl,
        onClick: () => run(() => favPage.createFolder(folder)),
      ),
    MenuEntry(
      icon: Icons.edit_outlined,
      text: "Rename".tl,
      onClick: () => run(() => favPage.renameFolder(folder)),
    ),
    if (nesting)
      MenuEntry(
        icon: Icons.drive_file_move_outline,
        text: "Move Folder".tl,
        onClick: () => run(() => favPage.moveFolder(folder)),
      ),
    if (manager.folderTree.childrenOf(folder).length > 1)
      MenuEntry(
        icon: Icons.reorder,
        text: "Sort Subfolders".tl,
        onClick: () => run(() => sortFolders(folder)),
      ),
    MenuEntry(
      icon: Icons.delete_outline,
      text: "Delete Folder".tl,
      color: context.colorScheme.error,
      onClick: () => run(() => favPage.deleteFolder(folder)),
    ),
  ];
}

/// Shows [_folderMenuEntries] at [position], or next to [context]'s widget.
void _showFolderMenu(
  BuildContext context,
  _FavoritesPageState favPage,
  String folder, {
  Offset? position,
  VoidCallback? then,
}) {
  if (position == null) {
    var box = context.findRenderObject() as RenderBox;
    position = box.localToGlobal(Offset(24, box.size.height / 2));
  }
  showMenuX(
    App.rootContext,
    position,
    _folderMenuEntries(context, favPage, folder, then: then),
  );
}
