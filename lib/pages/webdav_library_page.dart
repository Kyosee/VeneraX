import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/webdav_libraries_page.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Browses one configured WebDAV comic library. Folders open as online comics
/// (routed through [ComicPage] with that library's own source key); archive
/// files are offered for download-and-import through the existing comic
/// importer.
class WebdavLibraryPage extends StatefulWidget {
  const WebdavLibraryPage({super.key, required this.libraryId, this.dir});

  /// Which configured library to browse. Held as an id rather than a snapshot so
  /// an edit made from the settings shortcut is picked up on refresh.
  final String libraryId;

  /// Server-absolute directory to browse. Null browses the library root.
  final String? dir;

  @override
  State<WebdavLibraryPage> createState() => _WebdavLibraryPageState();
}

class _WebdavLibraryPageState extends State<WebdavLibraryPage> {
  bool loading = true;
  String? error;
  List<WebdavEntry> entries = const [];

  WebdavLibraryConfig? get _config => WebdavLibraryStore.find(widget.libraryId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() async {
    final client = WebdavLibraryClient.forId(widget.libraryId);
    if (client == null) {
      // The library was deleted (possibly from the shortcut on this very page).
      setState(() {
        loading = false;
        error = null;
        entries = const [];
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    final res = await client.listEntries(widget.dir);
    if (!mounted) return;
    setState(() {
      loading = false;
      if (res.error) {
        error = res.errorMessage;
      } else {
        entries = res.data;
      }
    });
  }

  List<Comic> get _comicEntries => entries
      .where((e) => !e.isArchiveFile)
      .map(
        (e) => Comic(
          e.name,
          // A "cover."-prefixed placeholder makes the thumbnail loader resolve
          // the real cover lazily per visible tile via loadComicInfo(cid),
          // instead of PROPFIND-ing every comic folder up front just to build
          // the grid.
          'cover.jpg',
          e.comicId,
          null,
          null,
          '',
          _config?.sourceKey ?? WebdavLibraryStore.legacySourceKey,
          null,
          null,
        ),
      )
      .toList();

  List<WebdavEntry> get _archiveEntries =>
      entries.where((e) => e.isArchiveFile).toList();

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text(
              widget.dir == null
                  ? (config?.displayName ?? "WebDAV Library".tl)
                  : WebdavLibrary.titleOf(widget.dir!),
            ),
            actions: [
              if (widget.dir == null)
                Tooltip(
                  message: "Settings".tl,
                  child: IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () async {
                      final current = _config;
                      if (current == null) return;
                      await showPopUpWidget(
                        context,
                        WebdavLibraryEditor(config: current),
                      );
                      if (mounted) _load();
                    },
                  ),
                ),
              Tooltip(
                message: "Refresh".tl,
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _load,
                ),
              ),
            ],
          ),
          ..._buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_config == null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text("WebDAV comic library is not configured".tl),
          ),
        ),
      ];
    }
    if (loading) {
      return const [
        SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
      ];
    }
    if (error != null) {
      return [
        SliverFillRemaining(
          child: NetworkError(
            message: error!,
            retry: _load,
            withAppbar: false,
          ),
        ),
      ];
    }
    if (entries.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text("Nothing here".tl)),
        ),
      ];
    }
    return [
      SliverGridComics(comics: _comicEntries, onTap: _openComic),
      if (_archiveEntries.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Text("Archives".tl, style: ts.s16),
          ),
        ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final a = _archiveEntries[i];
            return ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(a.name),
              subtitle: a.size != null ? Text(_humanSize(a.size!)) : null,
              trailing: const Icon(Icons.download_outlined),
              onTap: () => _importArchive(a),
            );
          },
          childCount: _archiveEntries.length,
        ),
      ),
      SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
    ];
  }

  void _openComic(Comic comic, int heroID) {
    final sourceKey = _config?.sourceKey;
    if (sourceKey == null) return;
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: sourceKey,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }

  void _importArchive(WebdavEntry entry) async {
    final client = WebdavLibraryClient.forId(widget.libraryId);
    if (client == null) return;
    final dir = await _tempDir();
    final savePath = FilePath.join(dir, entry.name);
    final controller = showLoadingDialog(
      context,
      message: "Downloading".tl,
      allowCancel: false,
    );
    final res = await client.downloadArchive(entry.path, savePath);
    controller.close();
    if (!mounted) {
      // Left the page mid-download: still clean up the temp file.
      File(savePath).deleteIgnoreError();
      return;
    }
    if (res.error) {
      // A failed download may leave a half-written file behind.
      File(savePath).deleteIgnoreError();
      context.showMessage(message: res.errorMessage!);
      return;
    }
    // Reuse the existing archive importer; it opens its own progress dialog and
    // registers the comic into the local library. The temp file is always
    // removed afterwards, even if extraction throws on a corrupt archive.
    try {
      final importer = ImportComic(copyToLocal: true);
      await importer.cbzFile(File(savePath));
    } finally {
      File(savePath).deleteIgnoreError();
    }
  }

  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double s = bytes.toDouble();
    int u = 0;
    while (s >= 1024 && u < units.length - 1) {
      s /= 1024;
      u++;
    }
    return '${s.toStringAsFixed(s < 10 && u > 0 ? 1 : 0)} ${units[u]}';
  }

  Future<String> _tempDir() async {
    final d = FilePath.join(App.cachePath, 'webdav_archive');
    final dir = Directory(d);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return d;
  }
}
