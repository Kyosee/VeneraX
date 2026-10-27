part of '../comic_source_page.dart';

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.library, this.onAdd);

  /// The library whose catalog (`index.json`) this view browses.
  final ComicSourceLibrary library;

  /// Installs a source from [url], stamping it with the library's id as origin.
  final Future<void> Function(String url, String originLibraryId) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  List? json;
  bool loadFailed = false;

  ComicSourceLibrary get library => widget.library;

  void load() async {
    if (json != null) {
      setState(() {
        json = null;
        loadFailed = false;
      });
    }
    if (library.url.isEmpty) {
      setState(() {
        json = [];
        loadFailed = false;
      });
      return;
    }
    try {
      var res = await fetchSourceText(library.url);
      if (res.statusCode != 200) {
        throw "error";
      }
      if (mounted) {
        setState(() {
          json = jsonDecode(res.data!);
          loadFailed = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      context.showMessage(message: "Network error".tl);
      setState(() {
        json = [];
        loadFailed = true;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: library.name,
      body: buildBody(),
    );
  }

  Widget buildBody() {
    var currentKey = ComicSource.all().map((e) => e.key).toList();

    if (json == null) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
        ).fixWidth(24).fixHeight(24),
      );
    }

    if (json!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              loadFailed
                  ? Icons.cloud_off_outlined
                  : Icons.inbox_outlined,
              size: 48,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              loadFailed ? "Network error".tl : "Empty catalog".tl,
              style: ts.s14.copyWith(color: context.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: load,
              child: Text("Refresh".tl),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: json!.length,
      itemBuilder: (context, index) {
        var entry = json![index];
        var key = entry["key"]?.toString();
        var installed = key != null && currentKey.contains(key);
        var version = entry["version"]?.toString();
        var description = entry["description"]?.toString();

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: context.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: context.colorScheme.outlineVariant.toOpacity(0.5),
              width: 0.6,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              // Keep the action beside the title once a long description
              // stretches the card.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry["name"]?.toString() ?? key ?? '',
                              style: ts.s16,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (version != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    context.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(version, style: ts.s12),
                            ),
                          ],
                        ],
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        // Unclamped on purpose: a truncated description hides
                        // what a plugin actually does, so let it wrap.
                        Text(
                          description,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                installed
                    ? Tooltip(
                        message: "Installed".tl,
                        child: Icon(
                          Icons.check_circle,
                          size: 22,
                          color: context.colorScheme.primary,
                        ),
                      ).paddingRight(8)
                    : Button.filled(
                        child: Text("Add".tl),
                        onPressed: () async {
                          var fileName = entry["fileName"];
                          var url = entry["url"];
                          var resolved = _resolveSourceDownloadUrl(
                            url: url?.toString(),
                            fileName: fileName?.toString(),
                            listUrl: library.url,
                          );
                          if (resolved == null) {
                            context.showMessage(
                              message:
                                  "Cannot resolve the source download url. "
                                          "Please check the repo URL."
                                      .tl,
                            );
                            return;
                          }
                          await widget.onAdd(resolved, library.id);
                          if (!mounted) return;
                          setState(() {});
                        },
                      ).fixHeight(32),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Downloads a source script from [url], installs it, and stamps its origin
/// library. Shared by the library catalog browser and the libraries page so the
/// install + provenance flow lives in one place. Shows its own loading dialog.
/// Returns true on success.
Future<bool> _installSourceFromUrl(String url, String originLibraryId) async {
  if (url.isEmpty) {
    return false;
  }
  var fileName = ComicSourceParser.scriptFileName(url);
  bool cancel = false;
  var controller = showLoadingDialog(
    App.rootContext,
    onCancel: () => cancel = true,
    barrierDismissible: false,
  );
  try {
    var res = await fetchSourceText(url);
    if (cancel) return false;
    controller.close();
    var comicSource = await ComicSourceParser().createAndParse(
      res.data!,
      fileName,
    );
    final added = ComicSourceManager().add(comicSource);
    if (!added) {
      // Duplicate key: drop the shadow file and report instead of half-adding.
      try {
        var f = File(comicSource.filePath);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        Log.error("Add comic source", e.toString());
      }
      App.rootContext.showMessage(
        message: "A source with key '@k' is already installed".tlParams({
          "k": comicSource.key,
        }),
      );
      return false;
    }
    ComicSourceLibraryManager.recordOrigin(comicSource.key, originLibraryId);
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
    return true;
  } catch (e, s) {
    if (cancel) return false;
    controller.close();
    App.rootContext.showMessage(message: e.toString());
    Log.error("Add comic source", "$e\n$s");
    return false;
  }
}

/// Manages the ordered list of comic-source libraries. Each library is a remote
/// catalog the app can browse and update from. Order is priority: the topmost
/// library wins when several offer the same source key.
class SourceLibrariesPage extends StatefulWidget {
  const SourceLibrariesPage({super.key});

  @override
  State<SourceLibrariesPage> createState() => _SourceLibrariesPageState();
}

class _SourceLibrariesPageState extends State<SourceLibrariesPage> {
  List<ComicSourceLibrary> libraries = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      libraries = ComicSourceLibraryManager.all();
    });
  }

  void _addLibrary() {
    String name = "";
    String url = "";
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: "Add library".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: InputDecoration(
                  labelText: "Library name".tl,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => name = v,
              ).paddingBottom(12),
              TextField(
                decoration: InputDecoration(
                  labelText: "URL",
                  hintText: "index.json",
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => url = v,
              ),
              Text(
                "The URL should point to a 'index.json' file".tl,
                style: ts.s12,
              ).paddingTop(8),
            ],
          ).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                url = url.trim();
                if (!isValidSourceUrl(url)) {
                  context.showMessage(message: "Invalid URL".tl);
                  return;
                }
                ComicSourceLibraryManager.add(name.trim(), url);
                context.pop();
                _reload();
              },
              child: Text("Add".tl),
            ),
          ],
        );
      },
    );
  }

  void _editLibrary(ComicSourceLibrary library) {
    var name = library.name;
    var url = library.url;
    final nameController = TextEditingController(text: name);
    final urlController = TextEditingController(text: url);
    showDialog(
      context: App.rootContext,
      builder: (context) {        return ContentDialog(
          title: "Edit library".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: "Library name".tl,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => name = v,
              ).paddingBottom(12),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: "URL",
                  hintText: "index.json",
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => url = v,
              ),
            ],
          ).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                url = url.trim();
                if (!isValidSourceUrl(url)) {
                  context.showMessage(message: "Invalid URL".tl);
                  return;
                }
                ComicSourceLibraryManager.edit(
                  library.id,
                  name: name.trim(),
                  url: url,
                );
                context.pop();
                _reload();
              },
              child: Text("Confirm".tl),
            ),
          ],
        );
      },
    ).then((_) {
      nameController.dispose();
      urlController.dispose();
    });
  }

  void _deleteLibrary(ComicSourceLibrary library) {
    showConfirmDialog(
      context: context,
      title: "Delete library".tl,
      content: "Delete library '@n'? Installed sources are kept.".tlParams({
        "n": library.name,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        ComicSourceLibraryManager.remove(library.id);
        _reload();
      },
    );
  }

  void _browseLibrary(ComicSourceLibrary library) {
    showPopUpWidget(
      App.rootContext,
      _ComicSourceList(library, (url, originLibraryId) async {
        await _installSourceFromUrl(url, originLibraryId);
      }),
    );
  }

  Future<void> _refreshLibrary() async {
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (!mounted) return;
    _reload();
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      context.showMessage(
        message: "@c updates".tlParams({"c": count}),
      );
    }
  }

  String _lastCheckedText(ComicSourceLibrary library) {
    if (library.lastChecked == null) {
      return "Never checked".tl;
    }
    var t = DateTime.fromMillisecondsSinceEpoch(library.lastChecked!);
    var stamp =
        "${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} "
        "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
    return "Last checked: @t".tlParams({"t": stamp});
  }

  /// Number of installed sources this library provides (by recorded origin or
  /// current offering provenance).
  int _sourceCountFor(ComicSourceLibrary library) {
    var count = 0;
    for (final source in ComicSource.all()) {
      final prov = ComicSourceManager().provenanceFor(source.key);
      if (prov == null) continue;
      if (prov.originId == library.id || prov.libraryIds.contains(library.id)) {
        count++;
      }
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Source Libraries".tl),
        actions: [
          Tooltip(
            message: "Check updates".tl,
            child: IconButton(
              icon: const Icon(Icons.update),
              onPressed: _refreshLibrary,
            ),
          ),
          Tooltip(
            message: "Add library".tl,
            child: IconButton(
              icon: const Icon(Icons.add),
              onPressed: _addLibrary,
            ),
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
                ComicSourceLibraryManager.reorder(oldIndex, newIndex);
                _reload();
              },
              itemCount: libraries.length,
              itemBuilder: (context, index) {
                return _buildLibraryCard(libraries[index], index);
              },
            ),
    );
  }

  Widget _buildLibraryCard(ComicSourceLibrary library, int index) {
    var host = Uri.tryParse(library.url)?.host ?? library.url;
    var disabled = !library.enabled;
    final sourceCount = _sourceCountFor(library);
    return Container(
      key: ValueKey(library.id),
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
        onTap: () => _browseLibrary(library),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
          child: Row(
            children: [
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
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      library.name,
                      style: ts.s16.copyWith(
                        color: disabled ? context.colorScheme.outline : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host,
                      style: ts.s12.copyWith(color: context.colorScheme.outline),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 12,
                          color: context.colorScheme.outline,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _lastCheckedText(library),
                            style: ts.s12.copyWith(
                              color: context.colorScheme.outline,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Source-count badge.
              Tooltip(
                message: "@c sources".tlParams({"c": sourceCount}),
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: disabled
                        ? context.colorScheme.surfaceContainerHighest
                        : context.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    "$sourceCount",
                    textAlign: TextAlign.center,
                    style: ts.s12.copyWith(
                      height: 1.0,
                      color: disabled
                          ? context.colorScheme.outline
                          : context.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: library.enabled
                    ? "Enabled".tl
                    : "This library is disabled".tl,
                child: Switch(
                  value: library.enabled,
                  onChanged: (v) {
                    ComicSourceLibraryManager.setEnabled(library.id, v);
                    _reload();
                  },
                ),
              ),
              MenuButton(
                entries: [
                  MenuEntry(
                    icon: Icons.travel_explore,
                    text: "Browse".tl,
                    onClick: () => _browseLibrary(library),
                  ),
                  MenuEntry(
                    icon: Icons.edit,
                    text: "Edit library".tl,
                    onClick: () => _editLibrary(library),
                  ),
                  MenuEntry(
                    icon: Icons.delete_outline,
                    text: "Delete library".tl,
                    color: context.colorScheme.error,
                    onClick: () => _deleteLibrary(library),
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
            Icons.library_books_outlined,
            size: 64,
            color: context.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text("No source libraries yet".tl, style: ts.s16),
          const SizedBox(height: 8),
          Text(
            "Add a library to browse and update sources".tl,
            style: ts.s14,
            textAlign: TextAlign.center,
          ).paddingHorizontal(32),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text("Add library".tl),
            onPressed: _addLibrary,
          ),
        ],
      ),
    );
  }
}
