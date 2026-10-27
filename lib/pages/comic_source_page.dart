import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/comic_source_update_tasks.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/source_url.dart';
import 'package:venera/pages/webdav_libraries_page.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

part 'comic_source_page/edit_file_page.dart';
part 'comic_source_page/login_page.dart';
part 'comic_source_page/source_libraries.dart';
part 'comic_source_page/source_settings.dart';

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<void> update(
    ComicSource source, [
    bool showLoading = true,
  ]) async {
    // Wire the deferred-purge hook so a library switch only wipes local data
    // after the new script has actually downloaded (see pendingDataPurge).
    ComicSourceUpdateTaskManager.onPurgeLocalData ??= (s) =>
        purgeSourceLocalData(s, deleteScript: false);
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
      // Drop any unconsumed purge intent (e.g. switch cancelled/failed) so a
      // later ordinary update of this source does not wrongly wipe its data.
      ComicSourceUpdateTaskManager.pendingDataPurge.remove(source.key);
      App.forceRebuild();
      return;
    }
    try {
      await ComicSourceUpdateTaskManager.updateSourceFile(source);
    } finally {
      ComicSourceUpdateTaskManager.pendingDataPurge.remove(source.key);
    }
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

  /// Checks enabled libraries for source updates.
  ///
  /// Update comparison is **bound to each source's origin library**: an
  /// installed source is only offered an update by the library it was installed
  /// from. Different maintainers version independently, so comparing a source
  /// against an unrelated library's catalog (even one sharing the key) is
  /// meaningless and could push the wrong script. Other libraries that also
  /// offer the key are recorded only as switch candidates — the user chooses
  /// explicitly via "Update from another library".
  ///
  /// Sources without a recorded origin (sideloaded, or installed before this
  /// feature) fall back to the first enabled library that offers the key, so
  /// single-library users keep auto-updates.
  ///
  /// A failed or slow library is skipped without aborting the others. Returns
  /// the number of sources with a pending update, or -1 if every enabled
  /// library failed to fetch.
  static Future<int> checkComicSourceUpdate() async {
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    final libraries = ComicSourceLibraryManager.enabled();
    if (libraries.isEmpty) {
      return 0;
    }

    // libraryId -> (key -> {version, url}) from that library's catalog.
    var catalogByLibrary = <String, Map<String, ({String version, String? url})>>{};
    // key -> ordered list of enabled library ids offering it (this round).
    var offeredBy = <String, List<String>>{};
    // Libraries whose catalog actually fetched+parsed this round. Distinguishes
    // "origin temporarily unreachable" from "origin no longer offers the key".
    var succeeded = <String>{};

    for (final library in libraries) {
      if (library.url.isEmpty) {
        continue;
      }
      List? list;
      try {
        var res = await fetchSourceText(library.url)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          continue;
        }
        list = jsonDecode(res.data!) as List;
      } catch (e) {
        Log.error("Check comic source update", "${library.name}: $e");
        continue;
      }
      succeeded.add(library.id);
      ComicSourceLibraryManager.markChecked(library.id);
      final entries = <String, ({String version, String? url})>{};
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
          entries[key] = (version: version, url: downloadUrl);
          final list = offeredBy[key] ??= [];
          if (!list.contains(library.id)) {
            list.add(library.id);
          }
        } catch (e) {
          Log.error("Check comic source update", e.toString());
        }
      }
      catalogByLibrary[library.id] = entries;
    }

    if (succeeded.isEmpty) {
      return -1;
    }

    final manager = ComicSourceManager();
    var pending = <String, String>{};
    var provenanceUpdates = <String, SourceProvenance>{};
    // key -> a DIFFERENT library offering a newer version than the one the
    // update library already offers; only a hint for the explicit switch flow.
    var newerElsewhere = <String, ({String libraryId, String version})>{};

    for (var source in ComicSource.all()) {
      final offered = offeredBy[source.key];
      final prov = manager.provenanceFor(source.key) ?? SourceProvenance();
      final originId = prov.originId;
      final originLib =
          originId != null ? ComicSourceLibraryManager.find(originId) : null;
      // Only an ENABLED origin governs/freezes auto-update. A disabled origin
      // is treated like a removed one — discovery no longer fetches it, so the
      // source falls through to an enabled offerer instead of being frozen.
      final originEnabled = originLib?.enabled ?? false;

      // Resolve which library governs this source's auto-update.
      String? updateLibraryId;
      if (originId != null &&
          (catalogByLibrary[originId]?.containsKey(source.key) ?? false)) {
        // Origin fetched OK and still offers the key — the normal path.
        updateLibraryId = originId;
      } else if (originEnabled && !succeeded.contains(originId)) {
        // Origin enabled but unreachable THIS round: do not silently hand the
        // source to a foreign maintainer's catalog. Skip auto-update and keep
        // the existing provenance untouched.
        updateLibraryId = null;
      } else if (offered != null && offered.isNotEmpty) {
        // No usable origin (sideloaded/legacy, origin removed or disabled, or
        // origin succeeded but dropped the key): fall back to first offerer.
        updateLibraryId = offered.first;
      }

      // Merge libraryIds: refresh ids from libraries that fetched this round,
      // and preserve ids of ENABLED libraries that merely failed to fetch (a
      // transient absence). Drop ids of removed or disabled libraries so the
      // offering count / "and N more" subtitle reflects the live enabled set.
      if (offered != null || succeeded.isNotEmpty) {
        final merged = <String>[];
        for (final id in prov.libraryIds) {
          if (succeeded.contains(id) || merged.contains(id)) continue;
          final lib = ComicSourceLibraryManager.find(id);
          if (lib != null && lib.enabled) {
            merged.add(id); // enabled but unreachable this round — keep
          }
        }
        if (offered != null) {
          for (final id in offered) {
            if (!merged.contains(id)) merged.add(id);
          }
        }
        prov.libraryIds = merged;
        prov.updateLibraryId = updateLibraryId;
        provenanceUpdates[source.key] = prov;
      }

      if (updateLibraryId != null) {
        final entry = catalogByLibrary[updateLibraryId]?[source.key];
        if (entry != null) {
          if (entry.url != null) {
            manager.setUpdateUrl(source.key, entry.url!);
          }
          if (_isNewer(entry.version, source.version)) {
            pending[source.key] = entry.version;
          }
        }
      }

      // Surface a newer version in another library, beyond what the update
      // library already offers, only as a switch hint.
      String baseVersion = source.version;
      if (updateLibraryId != null) {
        final govEntry = catalogByLibrary[updateLibraryId]?[source.key];
        if (govEntry != null) {
          baseVersion = govEntry.version;
        }
      }
      for (final id in prov.libraryIds) {
        if (id == updateLibraryId) continue;
        final entry = catalogByLibrary[id]?[source.key];
        if (entry != null && _isNewer(entry.version, baseVersion)) {
          newerElsewhere[source.key] = (libraryId: id, version: entry.version);
          break;
        }
      }
    }

    ComicSourceLibraryManager.setProvenanceBatch(provenanceUpdates);
    manager.setNewerElsewhere(newerElsewhere);
    // Full replace, not merge: a source whose origin library was removed or
    // disabled must drop out of the badge set.
    manager.replaceAvailableUpdates(pending);
    return pending.length;
  }

  /// True if [candidate] is a strictly newer version than [current].
  ///
  /// A strict superset of [compareSemVer]: it keeps that comparison (including
  /// its "hotfix" 4th-segment semantics) and only ADDS detections it misses —
  /// it never turns a detected update into a hidden one. [compareSemVer] only
  /// understands exactly three bare numeric parts, so it silently reported "not
  /// newer" for a real update declared with a leading "v", fewer than three
  /// parts, or a numeric 4th revision (e.g. "1.2.3.1" > "1.2.3"). That hid the
  /// update from the batch check even though a manual re-download installed it
  /// fine (#147). Erring toward "an update exists" is safe: applying one just
  /// re-downloads the script, so a false positive re-installs the same version
  /// harmlessly, whereas a false negative loses the update entirely.
  static bool _isNewer(String candidate, String current) {
    try {
      if (compareSemVer(candidate, current)) {
        return true;
      }
    } catch (_) {
      // Malformed for the strict parser; fall through to the tolerant compare.
    }
    return _tolerantVersionCompare(candidate, current) > 0;
  }

  /// Numeric-segment version comparison that tolerates a leading "v", differing
  /// segment counts, and non-numeric segments. Returns >0 if [a] > [b], <0 if
  /// [a] < [b], 0 if equal. Non-numeric segments are treated as 0 so a
  /// pre-release suffix ("-beta") never falsely reads as newer.
  static int _tolerantVersionCompare(String a, String b) {
    final pa = _versionSegments(a);
    final pb = _versionSegments(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) {
        return x > y ? 1 : -1;
      }
    }
    return 0;
  }

  static List<int> _versionSegments(String v) {
    v = v.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    return v
        .split(RegExp(r'[.\-+]'))
        .where((e) => e.isNotEmpty)
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
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

  /// Working copy of the sources being rearranged. Non-null only in sort mode;
  /// the arrangement is persisted when the user confirms.
  List<ComicSource>? _sorting;

  void updateUI() {
    // A background update task can remove and re-add a source while sorting is
    // open. Re-sync the working copy against what is actually installed so a
    // gone source cannot linger in the list.
    final sorting = _sorting;
    if (sorting != null) {
      final installed = _managedSources();
      final keys = installed.map((e) => e.key).toSet();
      if (!setEquals(keys, sorting.map((e) => e.key).toSet())) {
        _sorting = installed;
      } else {
        // Same set: keep the user's arrangement, refresh the instances.
        final byKey = {for (final e in installed) e.key: e};
        _sorting = sorting.map((e) => byKey[e.key]!).toList();
      }
    }
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

  /// The sources this screen manages: the native WebDAV library and comic
  /// collection sources have no script to edit/update/delete, so they never
  /// appear here — they are managed through their own screens instead.
  List<ComicSource> _managedSources() => ComicSource.all()
      .where(
        (e) =>
            !WebdavLibraryStore.isLibrarySourceKey(e.key) &&
            !ComicCollectionStore.isCollectionSourceKey(e.key),
      )
      .toList();

  void _enterSortMode() {
    final sources = _managedSources();
    if (sources.length < 2) return;
    setState(() {
      _sorting = sources;
    });
  }

  void _exitSortMode() {
    setState(() {
      _sorting = null;
    });
  }

  void _onSortReorder(int oldIndex, int newIndex) {
    final sorting = _sorting;
    if (sorting == null) return;
    setState(() {
      final moved = sorting.removeAt(oldIndex);
      sorting.insert(newIndex.clamp(0, sorting.length), moved);
    });
  }

  void _saveSortOrder() {
    final sorting = _sorting;
    if (sorting == null) return;
    ComicSourceManager().setSourceOrder(sorting.map((e) => e.key).toList());
    _exitSortMode();
    // Explore/search/category tabs are built from the source order, so they
    // have to be rebuilt for the new arrangement to show up outside this page.
    App.forceRebuild();
  }

  void _sortByName() {
    final sorting = _sorting;
    if (sorting == null) return;
    setState(() {
      sorting.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sorting = _sorting;
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(title: Text('Comic Source'.tl), style: AppbarStyle.shadow),
        if (sorting != null) ...[
          _SortModeBanner(onDone: _saveSortOrder, onSortByName: _sortByName),
          SliverReorderableList(
            itemCount: sorting.length,
            onReorderItem: _onSortReorder,
            itemBuilder: (context, index) => _SortTile(
              key: ValueKey('sort-${sorting[index].key}'),
              source: sorting[index],
              index: index,
            ),
          ),
        ] else ...[
          buildCard(context),
          const _WebdavLibrariesCard(),
          for (var source in _managedSources())
            _SliverComicSource(
              key: ValueKey(source.key),
              source: source,
              edit: edit,
              update: update,
              delete: delete,
              onLongPress: _enterSortMode,
            ),
        ],
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
    purgeSourceLocalData(source, deleteScript: true);
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
    if (!mounted) return;
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

  Future<void> handleAddSource(String url, [String? originLibraryId]) async {
    if (url.isEmpty) {
      return;
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
      if (cancel) return;
      controller.close();
      await addSource(res.data!, fileName, originLibraryId);
    } catch (e, s) {
      if (cancel) return;
      controller.close();
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  /// Parses and installs a source script. Returns false if a source with the
  /// same key is already installed — in that case the just-written script file
  /// is removed and no pages/provenance are registered, so a duplicate cannot
  /// leave a dangling `(name)(0).js` shadow on disk or falsely mark itself
  /// installed.
  Future<bool> addSource(
    String js,
    String fileName, [
    String? originLibraryId,
  ]) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    final added = ComicSourceManager().add(comicSource);
    if (!added) {
      // Duplicate key: remove the shadow file createAndParse wrote to disk.
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
    if (originLibraryId != null) {
      ComicSourceLibraryManager.recordOrigin(comicSource.key, originLibraryId);
    }
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
    return true;
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
  if (url != null && isValidSourceUrl(url)) {
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
  return isValidSourceUrl(resolved) ? resolved : null;
}

/// Removes a source's locally persisted state so a (re)install starts clean.
/// Deletes the `<key>.data` file (login flag, saved credentials, webview
/// localStorage) and the source's domain cookies (unless another installed
/// source shares the host). Set [deleteScript] true to also remove the `.js`
/// (full uninstall); leave it false when the script is being replaced in place
/// (library switch / update), so the freshly written script survives.
void purgeSourceLocalData(ComicSource source, {required bool deleteScript}) {
  if (deleteScript) {
    try {
      var file = File(source.filePath);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      Log.error("Purge comic source", e.toString());
    }
  }
  try {
    var dataFile = File("${App.dataPath}/comic_source/${source.key}.data");
    if (dataFile.existsSync()) dataFile.deleteSync();
  } catch (e) {
    Log.error("Purge comic source", e.toString());
  }
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
    Log.error("Purge comic source", e.toString());
  }
}

/// Compact card grouping the configured WebDAV comic libraries with the script
/// sources, so both kinds of source are managed from one screen (#171). The
/// libraries themselves are edited on [WebdavLibrariesPage]; this only lists and
/// links to them.
class _WebdavLibrariesCard extends StatefulWidget {
  const _WebdavLibrariesCard();

  @override
  State<_WebdavLibrariesCard> createState() => _WebdavLibrariesCardState();
}

class _WebdavLibrariesCardState extends State<_WebdavLibrariesCard> {
  @override
  void initState() {
    appdata.settings.addListener(_onChanged);
    super.initState();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _manage() {
    // No refresh needed on return: every edit writes through settings, which
    // notifies the listener above.
    App.rootContext.to(() => const WebdavLibrariesPage());
  }

  @override
  Widget build(BuildContext context) {
    final libraries = WebdavLibraryStore.effective();
    return SliverToBoxAdapter(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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
                Icon(Icons.cloud_outlined, color: context.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text("WebDAV Comic Library".tl, style: ts.s16),
                ),
                Text(
                  "@c libraries".tlParams({"c": libraries.length}),
                  style: ts.s12.copyWith(color: context.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Browse comics on a WebDAV server without downloading them first."
                  .tl,
              style: ts.s12.copyWith(color: context.colorScheme.outline),
            ),
            if (libraries.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final lib in libraries)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: lib.enabled
                            ? context.colorScheme.primaryContainer.toOpacity(
                                0.5,
                              )
                            : context.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        lib.displayName,
                        style: ts.s12.copyWith(
                          color: lib.enabled
                              ? null
                              : context.colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.settings_outlined),
                label: Text("Manage libraries".tl),
                onPressed: _manage,
              ),
            ),
          ],
        ),
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
    if (!mounted) return;
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
          return "${ComicSource.find(e.key)?.name ?? e.key}: ${e.value}";
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
      if (!mounted) return;
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

class _SortModeBanner extends StatelessWidget {
  const _SortModeBanner({required this.onDone, required this.onSortByName});

  final VoidCallback onDone;
  final VoidCallback onSortByName;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer.toOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.swap_vert, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text("Drag to reorder".tl, style: ts.s14)),
            TextButton(
              onPressed: onSortByName,
              child: Text("Sort by name".tl),
            ),
            FilledButton(onPressed: onDone, child: Text("Done".tl)),
          ],
        ),
      ),
    );
  }
}

class _SortTile extends StatelessWidget {
  const _SortTile({
    super.key,
    required this.source,
    required this.index,
  });

  final ComicSource source;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.colorScheme.outlineVariant.toOpacity(0.5),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              source.name,
              style: ts.s16,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}
