import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/pages/webdav_library_page.dart';
import 'package:venera/utils/translations.dart';

/// Manages the configured WebDAV comic libraries: add, edit, reorder, and jump
/// straight into browsing one.
///
/// Several addresses coexist (#171) so someone with a server at home and another
/// at work keeps both and switches with a tap instead of retyping credentials.
class WebdavLibrariesPage extends StatefulWidget {
  const WebdavLibrariesPage({super.key});

  @override
  State<WebdavLibrariesPage> createState() => _WebdavLibrariesPageState();
}

class _WebdavLibrariesPageState extends State<WebdavLibrariesPage> {
  List<WebdavLibraryConfig> libraries = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      libraries = WebdavLibraryStore.effective();
    });
  }

  /// Re-registers the native sources after any change, so a freshly added
  /// library is readable immediately and a deleted one stops being offered.
  void _applyChange() {
    ComicSourceManager().refreshWebdavLibrarySources();
    _reload();
  }

  // The editor writes straight to the store, and a dismissed pop-up carries no
  // result, so both entry points just re-read once it closes.
  void _add() async {
    await showPopUpWidget(context, const WebdavLibraryEditor());
    if (mounted) _applyChange();
  }

  void _edit(WebdavLibraryConfig config) async {
    await showPopUpWidget(context, WebdavLibraryEditor(config: config));
    if (mounted) _applyChange();
  }

  void _delete(WebdavLibraryConfig config) {
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete library '@n'? Comics on the server are kept.".tlParams({
        "n": config.displayName,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        WebdavLibraryStore.remove(config.id);
        _applyChange();
      },
    );
  }

  void _browse(WebdavLibraryConfig config) {
    context.to(() => WebdavLibraryPage(libraryId: config.id));
  }

  void _test(WebdavLibraryConfig config) async {
    final controller = showLoadingDialog(
      context,
      message: "Testing".tl,
      allowCancel: false,
    );
    final res = await WebdavLibraryClient(config).testConnection();
    controller.close();
    if (!mounted) return;
    context.showMessage(
      message: res.error
          ? "Connection failed: @error".tlParams({
              "error": res.errorMessage ?? "",
            })
          : "Connection successful".tl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("WebDAV Comic Library".tl),
        actions: [
          Tooltip(
            message: "Add WebDAV library".tl,
            child: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ],
      ),
      body: libraries.isEmpty
          ? _buildEmptyState()
          : ReorderableListView.builder(
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                12,
                context.padding.bottom + 8,
              ),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                WebdavLibraryStore.reorder(oldIndex, newIndex);
                _applyChange();
              },
              itemCount: libraries.length,
              itemBuilder: (context, index) =>
                  _buildCard(libraries[index], index),
            ),
    );
  }

  Widget _buildCard(WebdavLibraryConfig config, int index) {
    final disabled = !config.enabled;
    final host = Uri.tryParse(config.url)?.host ?? config.url;
    final subtitle = config.root.trim().isEmpty
        ? host
        : '$host  ·  ${config.rootPath}';
    return Container(
      key: ValueKey(config.id),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.colorScheme.outlineVariant.toOpacity(0.5),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _browse(config),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
          child: Row(
            children: [
              // The implicit sync-derived library has no stored position, so it
              // offers no drag handle.
              if (!config.isInherited)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.drag_indicator,
                      color: context.colorScheme.outline,
                      size: 22,
                    ),
                  ),
                )
              else
                const SizedBox(width: 8),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.displayName,
                      style: ts.s16.copyWith(
                        color: disabled ? context.colorScheme.outline : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (config.isInherited) ...[
                      const SizedBox(height: 4),
                      Text(
                        "Using your data-sync WebDAV credentials. Save to customize.".tl,
                        style: ts.s12.copyWith(
                          color: context.colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (!config.isInherited)
                Tooltip(
                  message: config.enabled ? "Enabled".tl : "Disabled".tl,
                  child: Switch(
                    value: config.enabled,
                    onChanged: (v) {
                      WebdavLibraryStore.setEnabled(config.id, v);
                      _applyChange();
                    },
                  ),
                ),
              MenuButton(
                entries: [
                  MenuEntry(
                    icon: Icons.travel_explore,
                    text: "Browse".tl,
                    onClick: () => _browse(config),
                  ),
                  MenuEntry(
                    icon: Icons.wifi_tethering,
                    text: "Test Connection".tl,
                    onClick: () => _test(config),
                  ),
                  MenuEntry(
                    icon: Icons.edit,
                    text: "Edit".tl,
                    onClick: () => _edit(config),
                  ),
                  if (!config.isInherited)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete".tl,
                      color: context.colorScheme.error,
                      onClick: () => _delete(config),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 64,
            color: context.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text("WebDAV comic library is not configured".tl, style: ts.s16),
          const SizedBox(height: 8),
          Text(
            "Browse comics on a WebDAV server without downloading them first.".tl,
            style: ts.s14,
            textAlign: TextAlign.center,
          ).paddingHorizontal(32),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text("Add WebDAV library".tl),
            onPressed: _add,
          ),
        ],
      ),
    );
  }
}

/// Add/edit form for one library. Writes straight to the store on save; the
/// caller re-registers the sources once the form closes.
class WebdavLibraryEditor extends StatefulWidget {
  const WebdavLibraryEditor({super.key, this.config});

  /// The library being edited, or null when adding a new one. An inherited
  /// (sync-derived) config is prefilled and saved as a real entry.
  final WebdavLibraryConfig? config;

  @override
  State<WebdavLibraryEditor> createState() => _WebdavLibraryEditorState();
}

class _WebdavLibraryEditorState extends State<WebdavLibraryEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _root;

  bool isTesting = false;

  bool get _isNew => widget.config == null || widget.config!.isInherited;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _name = TextEditingController(text: c?.name ?? '');
    _url = TextEditingController(text: c?.url ?? '');
    _user = TextEditingController(text: c?.user ?? '');
    _pass = TextEditingController(text: c?.pass ?? '');
    _root = TextEditingController(text: c?.root ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _root.dispose();
    super.dispose();
  }

  void _test() async {
    if (_url.text.trim().isEmpty) {
      context.showMessage(message: "Fill in the URL first".tl);
      return;
    }
    setState(() => isTesting = true);
    final res = await WebdavLibrary.testConnection(
      url: _url.text,
      user: _user.text,
      pass: _pass.text,
      root: _root.text,
    );
    if (!mounted) return;
    setState(() => isTesting = false);
    context.showMessage(
      message: res.error
          ? "Connection failed: @error".tlParams({
              "error": res.errorMessage ?? "",
            })
          : "Connection successful".tl,
    );
  }

  void _save() {
    if (_url.text.trim().isEmpty) {
      context.showMessage(message: "Fill in the URL first".tl);
      return;
    }
    if (_isNew) {
      WebdavLibraryStore.add(
        name: _name.text,
        url: _url.text,
        user: _user.text,
        pass: _pass.text,
        root: _root.text,
      );
    } else {
      WebdavLibraryStore.update(
        widget.config!.id,
        name: _name.text,
        url: _url.text,
        user: _user.text,
        pass: _pass.text,
        root: _root.text,
      );
    }
    context.showMessage(message: "Saved".tl);
    App.rootPop();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: _isNew ? "Add WebDAV library".tl : "Edit".tl,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Text(
              "Browse comics on a WebDAV server without downloading them first."
                  .tl,
              style: TextStyle(color: context.colorScheme.outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: "Display name".tl,
                hintText: "Home NAS",
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _root,
              decoration: InputDecoration(
                labelText: "Library Folder (Optional)".tl,
                hintText: "/comics",
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Button.outlined(
                isLoading: isTesting,
                onPressed: _test,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_tethering, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        "Test Connection".tl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Button.filled(
                onPressed: _save,
                child: Text("Save".tl),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }
}
