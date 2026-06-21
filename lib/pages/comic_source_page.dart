import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/comic_source_update_tasks.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    // If the user updates a single source without first running a full update
    // check, the source-list-derived download URL hasn't been cached yet, so
    // the update would fall back to the (possibly migrated/dead) URL in the
    // installed script. Resolve it lazily here. Failures are non-fatal: the
    // update still proceeds with the script's own URL.
    if (ComicSourceManager().updateUrlFor(source.key) == null) {
      var listUrl = appdata.settings['comicSourceListUrl']?.toString() ?? '';
      if (listUrl.isNotEmpty) {
        try {
          await checkComicSourceUpdate();
        } catch (e) {
          Log.error("Comic source update", e.toString());
        }
      }
    }
    if (showLoading) {
      final task = ComicSourceUpdateTaskManager.instance.start([
        source,
      ], targetVersions: ComicSourceManager().availableUpdates);
      await showUpdateTaskDialog(App.rootContext, task);
      App.forceRebuild();
      return;
    }
    await ComicSourceUpdateTaskManager.updateSourceFile(source);
  }

  static Future<void> showUpdateTaskDialog(
    BuildContext context,
    ComicSourceUpdateTask task,
  ) async {
    final manager = ComicSourceUpdateTaskManager.instance;
    final completer = Completer<void>();
    var backgrounded = false;
    var canceled = false;

    final loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: () {
        canceled = true;
        manager.cancel(task.id);
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      secondaryButtonText: "Background".tl,
      onSecondary: () {
        backgrounded = true;
        context.showMessage(message: "Task started".tl);
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      message: "Updating comic sources...".tl,
    );

    void onTaskChanged() {
      loadingController.setProgress(task.progress);
      if (!task.isRunning && !completer.isCompleted) {
        completer.complete();
      }
    }

    manager.addListener(onTaskChanged);
    onTaskChanged();

    try {
      await completer.future;
    } finally {
      manager.removeListener(onTaskChanged);
      loadingController.close();
    }

    if (canceled || backgrounded) {
      return;
    }
    if (task.failed > 0) {
      context.showMessage(
        message: "Updated @updated comic sources, @failed failed".tlParams({
          'updated': task.updated,
          'failed': task.failed,
        }),
      );
    } else {
      context.showMessage(
        message: "Updated @updated comic sources".tlParams({
          'updated': task.updated,
        }),
      );
    }
  }

  /// Checks every enabled library for source updates and merges the results.
  ///
  /// Libraries are visited in priority order (ascending). For a given source
  /// key the FIRST (lowest-priority) library that lists it wins the version and
  /// download URL; later libraries only register as additional providers. A
  /// failed or slow library is skipped without aborting the others, so one dead
  /// catalog can no longer block discovery for the rest.
  ///
  /// Returns the number of sources with a pending update, or -1 if every
  /// enabled library failed to fetch.
  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    final libraries = ComicSourceLibraryManager.enabled();
    if (libraries.isEmpty) {
      return 0;
    }

    // key -> winning version / download url, in priority order (first wins).
    var versions = <String, String>{};
    var urls = <String, String>{};
    // key -> every library id offering it (priority order preserved).
    var offeredBy = <String, List<String>>{};
    // key -> winning library id (the one that set versions[key]).
    var winnerLibrary = <String, String>{};
    // key -> a lower-priority library that offers a strictly newer version.
    var newerElsewhere = <String, ({String libraryId, String version})>{};

    var anySucceeded = false;
    for (final library in libraries) {
      if (library.url.isEmpty) {
        continue;
      }
      List? list;
      try {
        var res = await AppDio()
            .get<String>(
              library.url,
              options: Options(headers: {'cache-time': 'no'}),
            )
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          continue;
        }
        list = jsonDecode(res.data!) as List;
      } catch (e) {
        Log.error("Check comic source update", "${library.name}: $e");
        continue;
      }
      anySucceeded = true;
      ComicSourceLibraryManager.markChecked(library.id);
      for (var source in list) {
        try {
          var key = source['key']?.toString();
          var version = source['version']?.toString();
          if (key == null || version == null) {
            continue;
          }
          var downloadUrl = _resolveSourceDownloadUrl(
            url: source['url']?.toString(),
            fileName: source['fileName']?.toString(),
            listUrl: library.url,
          );
          (offeredBy[key] ??= []).add(library.id);
          if (!versions.containsKey(key)) {
            // First (highest-priority) library to list this key wins.
            versions[key] = version;
            winnerLibrary[key] = library.id;
            if (downloadUrl != null) {
              urls[key] = downloadUrl;
            }
          } else {
            // A lower-priority library: note if it offers something newer so
            // the UI can surface it rather than silently honoring priority.
            if (_isNewer(version, versions[key]!)) {
              newerElsewhere[key] = (libraryId: library.id, version: version);
            }
          }
        } catch (e) {
          Log.error("Check comic source update", e.toString());
        }
      }
    }

    if (!anySucceeded) {
      return -1;
    }

    final manager = ComicSourceManager();
    var pending = <String, String>{};
    var provenanceUpdates = <String, SourceProvenance>{};
    for (var source in ComicSource.all()) {
      final ids = offeredBy[source.key];
      if (ids != null) {
        // Refresh discovery provenance, preserving the sticky origin id.
        final prov = manager.provenanceFor(source.key) ?? SourceProvenance();
        prov.libraryIds = ids;
        prov.updateLibraryId = winnerLibrary[source.key];
        provenanceUpdates[source.key] = prov;
      }
      // Cache the resolved download URL for every known source so a manual
      // single-source update also targets the winning library's address.
      if (urls.containsKey(source.key)) {
        manager.setUpdateUrl(source.key, urls[source.key]!);
      }
      if (versions.containsKey(source.key) &&
          _isNewer(versions[source.key]!, source.version)) {
        pending[source.key] = versions[source.key]!;
      }
    }

    ComicSourceLibraryManager.setProvenanceBatch(provenanceUpdates);
    manager.setNewerElsewhere(newerElsewhere);
    // Full replace, not merge: a winner that is no longer offered (library
    // removed/disabled) must drop out of the badge set.
    manager.replaceAvailableUpdates(pending);
    return pending.length;
  }

  /// [compareSemVer] guarded against malformed version strings. A bad version
  /// in any catalog must not abort the whole merged check.
  static bool _isNewer(String candidate, String current) {
    try {
      return compareSemVer(candidate, current);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";

  void updateUI() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    super.dispose();
    ComicSourceManager().removeListener(updateUI);
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        _purgeComicSourceData(source);
        ComicSourceManager().remove(source.key);
        ComicSourceLibraryManager.clearProvenance(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  /// Remove everything a source persists locally so that reinstalling it starts
  /// from a clean state. Without this, the `<key>.data` file (which keeps the
  /// login flag, saved credentials and webview localStorage) and the source's
  /// cookies survive deletion, so a freshly reinstalled source appears already
  /// logged in with stale data.
  void _purgeComicSourceData(ComicSource source) {
    // 1. The script file itself.
    try {
      var file = File(source.filePath);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      Log.error("Delete comic source", e.toString());
    }
    // 2. Persisted data: account/login flag, _localStorage, settings, etc.
    try {
      var dataFile = File("${App.dataPath}/comic_source/${source.key}.data");
      if (dataFile.existsSync()) dataFile.deleteSync();
    } catch (e) {
      Log.error("Delete comic source", e.toString());
    }
    // 3. Cookies for the source domain, so a reinstall is not auto-logged-in.
    //    Skip when another installed source shares the same host to avoid
    //    logging that source out.
    try {
      var uri = Uri.tryParse(source.url);
      var host = uri?.host ?? '';
      if (host.isNotEmpty) {
        var sharedByOther = ComicSource.all().any(
          (e) => e.key != source.key && Uri.tryParse(e.url)?.host == host,
        );
        if (!sharedByOther) {
          SingleInstanceCookieJar.instance?.deleteUri(uri!);
        }
      }
    } catch (e) {
      Log.error("Delete comic source", e.toString());
    }
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel".tl),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: Text("Continue".tl),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        setState(() {});
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.colorScheme.outlineVariant.toOpacity(0.5),
            width: 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  color: context.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text("Add comic source".tl, style: ts.s16),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                suffixIcon: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.collections_bookmark_outlined),
                  label: Text("Source Libraries".tl),
                  onPressed: () {
                    App.rootContext.to(() => const SourceLibrariesPage());
                  },
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/Kyosee/venera/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url, [String? originLibraryId]) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller.close();
      await addSource(res.data!, fileName, originLibraryId);
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  Future<void> addSource(
    String js,
    String fileName, [
    String? originLibraryId,
  ]) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSourceManager().add(comicSource);
    if (originLibraryId != null) {
      ComicSourceLibraryManager.recordOrigin(comicSource.key, originLibraryId);
    }
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
  }
}

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

  ComicSourceLibrary get library => widget.library;

  void load() async {
    if (json != null) {
      setState(() {
        json = null;
      });
    }
    if (library.url.isEmpty) {
      setState(() {
        json = [];
      });
      return;
    }
    var dio = AppDio();
    try {
      var res = await dio.get<String>(
        library.url,
        options: Options(headers: {'cache-time': 'no'}),
      );
      if (res.statusCode != 200) {
        throw "error";
      }
      if (mounted) {
        setState(() {
          json = jsonDecode(res.data!);
        });
      }
    } catch (e) {
      context.showMessage(message: "Network error".tl);
      if (mounted) {
        setState(() {
          json = [];
        });
      }
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
              Icons.cloud_off_outlined,
              size: 48,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              "Network error".tl,
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
                        Text(
                          description,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.outline,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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

/// Resolves the download URL for a source-list entry.
///
/// Prefers an explicit absolute [url]. Otherwise derives it from [listUrl]
/// (the `index.json` location) and [fileName], mirroring how the list itself
/// is hosted: if [listUrl] has a path, the last segment is swapped for
/// [fileName]; otherwise [fileName] is appended. Returns null when no valid
/// URL can be produced.
String? _resolveSourceDownloadUrl({
  String? url,
  String? fileName,
  required String listUrl,
}) {
  if (url != null && url.isURL) {
    return url;
  }
  if (fileName == null || fileName.isEmpty) {
    return null;
  }
  String resolved;
  var bare = listUrl.replaceFirst("https://", "").replaceFirst("http://", "");
  if (bare.contains("/")) {
    resolved = listUrl.substring(0, listUrl.lastIndexOf("/") + 1) + fileName;
  } else {
    resolved = '$listUrl/$fileName';
  }
  return resolved.isURL ? resolved : null;
}

/// Downloads a source script from [url], installs it, and stamps its origin
/// library. Shared by the library catalog browser and the libraries page so the
/// install + provenance flow lives in one place. Shows its own loading dialog.
/// Returns true on success.
Future<bool> _installSourceFromUrl(String url, String originLibraryId) async {
  if (url.isEmpty) {
    return false;
  }
  var splits = url.split("/");
  splits.removeWhere((element) => element == "");
  var fileName = splits.isEmpty ? "source.js" : splits.last;
  bool cancel = false;
  var controller = showLoadingDialog(
    App.rootContext,
    onCancel: () => cancel = true,
    barrierDismissible: false,
  );
  try {
    var res = await AppDio().get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {"cache-time": "no"},
      ),
    );
    if (cancel) return false;
    controller.close();
    var comicSource = await ComicSourceParser().createAndParse(
      res.data!,
      fileName,
    );
    ComicSourceManager().add(comicSource);
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
                if (!url.isURL) {
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
    showInputDialog(
      context: context,
      title: "Edit library".tl,
      initialValue: library.name,
      onConfirm: (value) {
        ComicSourceLibraryManager.rename(library.id, value.trim());
        _reload();
        return null;
      },
    );
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
              onReorder: (oldIndex, newIndex) {
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
              // Priority rank badge.
              Container(
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
                  "${index + 1}",
                  style: ts.s12.copyWith(
                    color: disabled
                        ? context.colorScheme.outline
                        : context.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
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

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    var count = await ComicSourcePage.checkComicSourceUpdate();
    if (count == -1) {
      context.showMessage(message: "Network error".tl);
    } else if (count == 0) {
      context.showMessage(message: "No updates".tl);
    } else {
      showUpdateDialog();
    }
    setState(() {
      isLoading = false;
    });
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      final updates = ComicSourceManager().availableUpdates;
      final sources = updates.keys
          .map((key) => ComicSource.find(key))
          .whereType<ComicSource>()
          .toList();
      if (sources.isEmpty) {
        context.showMessage(message: "No updates".tl);
        return;
      }
      final task = ComicSourceUpdateTaskManager.instance.start(
        sources,
        targetVersions: updates,
      );
      await ComicSourcePage.showUpdateTaskDialog(context, task);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    var manager = ComicSourceManager();
    var newVersion = manager.availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null &&
        ComicSourcePage._isNewer(newVersion, source.version);
    var provenanceText = _provenanceText();
    var newerElsewhere = manager.newerElsewhereFor(source.key);
    String? newerHint;
    if (newerElsewhere != null) {
      final lib = ComicSourceLibraryManager.find(newerElsewhere.libraryId);
      if (lib != null) {
        newerHint = "Newer version @v in @lib".tlParams({
          "v": newerElsewhere.version,
          "lib": lib.name,
        });
      }
    }

    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.colorScheme.outlineVariant.toOpacity(0.5),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                setState(() {
                  _expanded = !_expanded;
                });
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            source.name,
                            style: ts.s18,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _versionChip(source.version),
                        if (hasUpdate) _updateChip(newVersion).paddingLeft(6),
                        const Spacer(),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          color: context.colorScheme.outline,
                        ),
                      ],
                    ),
                    if (provenanceText != null || newerHint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (provenanceText != null)
                              _infoChip(
                                icon: Icons.inventory_2_outlined,
                                text: provenanceText,
                                color: context.colorScheme.outline,
                              ),
                            if (newerHint != null)
                              _infoChip(
                                icon: Icons.upgrade,
                                text: newerHint,
                                color: context.colorScheme.tertiary,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              height: 0.6,
              color: context.colorScheme.outlineVariant.toOpacity(0.5),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _actionButton(
                    icon: Icons.edit_note,
                    tooltip: "Edit".tl,
                    onPressed: () => widget.edit(source),
                  ),
                  _actionButton(
                    icon: Icons.update,
                    tooltip: "Update".tl,
                    onPressed: () => widget.update(source),
                    highlight: hasUpdate,
                  ),
                  if (_offeringLibraries().length > 1)
                    _actionButton(
                      icon: Icons.account_tree_outlined,
                      tooltip: "Update from another library".tl,
                      onPressed: _showLibraryPicker,
                    ),
                  _actionButton(
                    icon: Icons.delete_outline,
                    tooltip: "Delete".tl,
                    onPressed: () => widget.delete(source),
                    color: context.colorScheme.error,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              Container(
                height: 0.6,
                color: context.colorScheme.outlineVariant.toOpacity(0.5),
              ),
              ...buildSourceSettings(),
              ..._buildAccount(),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }

  Widget _versionChip(String version) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(version, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _updateChip(String newVersion) {
    return Tooltip(
      message: newVersion,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.arrow_upward,
              size: 12,
              color: context.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 2),
            Text(
              "New Version".tl,
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.toOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text, style: ts.s12.copyWith(color: color)),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
    bool highlight = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          icon,
          size: 22,
          color: highlight
              ? context.colorScheme.primary
              : color ?? context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Libraries currently recorded as offering this source key (provenance).
  List<ComicSourceLibrary> _offeringLibraries() {
    final prov = ComicSourceManager().provenanceFor(source.key);
    if (prov == null) {
      return [];
    }
    return prov.libraryIds
        .map((id) => ComicSourceLibraryManager.find(id))
        .whereType<ComicSourceLibrary>()
        .toList();
  }

  /// Lets the user pick which library to (re)install this source from when more
  /// than one offers it. The chosen library's version/URL is written through to
  /// the update state so the existing update flow installs that variant. Since
  /// switching variants reinstalls the script and wipes the source's local data
  /// (login/cookies), it is gated behind an explicit confirmation.
  void _showLibraryPicker() async {
    final libraries = _offeringLibraries();
    if (libraries.isEmpty) return;
    ComicSourceLibrary? chosen;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Update from another library".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final lib in libraries)
                ListTile(
                  title: Text(lib.name),
                  subtitle: Text(Uri.tryParse(lib.url)?.host ?? lib.url),
                  onTap: () {
                    chosen = lib;
                    context.pop();
                  },
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    final library = chosen!;

    // Re-fetch the chosen library's catalog to resolve this key's version+URL.
    String? version;
    String? downloadUrl;
    try {
      var res = await AppDio()
          .get<String>(
            library.url,
            options: Options(headers: {'cache-time': 'no'}),
          )
          .timeout(const Duration(seconds: 20));
      var list = jsonDecode(res.data!) as List;
      for (var entry in list) {
        if (entry['key']?.toString() == source.key) {
          version = entry['version']?.toString();
          downloadUrl = _resolveSourceDownloadUrl(
            url: entry['url']?.toString(),
            fileName: entry['fileName']?.toString(),
            listUrl: library.url,
          );
          break;
        }
      }
    } catch (e) {
      App.rootContext.showMessage(message: "Network error".tl);
      return;
    }
    if (version == null || downloadUrl == null) {
      App.rootContext.showMessage(
        message: "This library no longer offers this source".tl,
      );
      return;
    }

    showConfirmDialog(
      context: App.rootContext,
      title: "Switch source library".tl,
      content:
          "Reinstall '@n' from @lib? This replaces the installed script and "
                  "clears its login and local data."
              .tlParams({"n": source.name, "lib": library.name}),
      onConfirm: () {
        // Write through winner state so the standard update flow targets the
        // chosen library's variant, and re-stamp the origin.
        final manager = ComicSourceManager();
        manager.setUpdateUrl(source.key, downloadUrl!);
        manager.replaceAvailableUpdates({
          ...manager.availableUpdates,
          source.key: version!,
        });
        final prov = manager.provenanceFor(source.key) ?? SourceProvenance();
        prov.originId = library.id;
        prov.updateLibraryId = library.id;
        if (!prov.libraryIds.contains(library.id)) {
          prov.libraryIds.add(library.id);
        }
        manager.updateProvenance(source.key, prov);
        widget.update(source);
      },
    );
  }

  /// Builds the origin/provenance line: "From [library]" plus "and N more"
  /// when several libraries offer this source. Returns null when no provenance
  /// is recorded (e.g. a sideloaded source).
  String? _provenanceText() {
    final prov = ComicSourceManager().provenanceFor(source.key);
    if (prov == null) {
      return null;
    }
    if (prov.originId != null) {
      final origin = ComicSourceLibraryManager.find(prov.originId!);
      if (origin == null) {
        // Origin library was removed; the source still works via its own URL.
        return "Source library removed".tl;
      }
      final others = prov.libraryIds.where((id) => id != prov.originId).length;
      if (others > 0) {
        return "From @lib and @n more".tlParams({
          "lib": origin.name,
          "n": others,
        });
      }
      return "From @lib".tlParams({"lib": origin.name});
    }
    if (prov.libraryIds.isNotEmpty) {
      final names = prov.libraryIds
          .map((id) => ComicSourceLibraryManager.find(id)?.name)
          .whereType<String>()
          .toList();
      if (names.isNotEmpty) {
        return "Provided by @libs".tlParams({"libs": names.join("、")});
      }
    }
    return null;
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: (current as String).ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }


  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookiesFromPlatformCookies(
            cookies,
            fallbackDomain: Uri.parse(url).host,
          ),
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
