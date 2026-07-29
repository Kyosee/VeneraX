import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// Path/name helpers shared by every WebDAV comic library. Pure functions with
/// no configuration of their own, so they hold no notion of "the" library —
/// several are configured at once (#171) and each is driven by a
/// [WebdavLibraryClient] bound to its own address.
abstract class WebdavLibrary {
  /// Image file extensions recognised as comic pages, lower-case, no dot.
  static const _imageExts = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'avif',
    'jxl',
  };

  /// Archive extensions surfaced as importable entries rather than browsable
  /// online comics (the app already imports these locally).
  static const archiveExts = {'cbz', 'zip', '7z', 'cb7', 'cbr', 'rar'};

  static String ensureDir(String p) => p.endsWith('/') ? p : '$p/';

  /// Encodes a server-absolute directory path into an opaque comic id that
  /// round-trips through the reader/history without a lookup table.
  static String encodeId(String path) =>
      base64Url.encode(utf8.encode(ensureDir(path)));

  static String decodeId(String id) {
    try {
      return utf8.decode(base64Url.decode(id));
    } catch (_) {
      // Tolerate ids that were never encoded (e.g. a raw path).
      return ensureDir(id);
    }
  }

  static bool isImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(name.substring(dot + 1).toLowerCase());
  }

  static bool isArchive(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return archiveExts.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Human-readable title for a directory path (its last path segment).
  static String titleOf(String dir) {
    var p = dir;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final slash = p.lastIndexOf('/');
    final name = slash < 0 ? p : p.substring(slash + 1);
    // A folder name is percent-decoded for display, but a literal '%' in the
    // title (e.g. "50% OFF") is not valid percent-encoding and makes
    // decodeComponent throw, which used to crash detail loading. Fall back to
    // the raw name whenever it can't be decoded.
    String decoded;
    try {
      decoded = Uri.decodeComponent(name);
    } catch (_) {
      return name;
    }
    return decoded.isEmpty ? name : decoded;
  }

  /// Natural-order comparison so `2.jpg` sorts before `10.jpg`.
  static int naturalCompare(String a, String b) {
    final ra = RegExp(r'(\d+|\D+)').allMatches(a).map((m) => m[0]!).toList();
    final rb = RegExp(r'(\d+|\D+)').allMatches(b).map((m) => m[0]!).toList();
    for (var i = 0; i < ra.length && i < rb.length; i++) {
      final sa = ra[i], sb = rb[i];
      final na = int.tryParse(sa), nb = int.tryParse(sb);
      int c;
      if (na != null && nb != null) {
        c = na.compareTo(nb);
      } else {
        c = sa.toLowerCase().compareTo(sb.toLowerCase());
      }
      if (c != 0) return c;
    }
    return ra.length.compareTo(rb.length);
  }

  /// Directory listings and probes must be bounded: rhttp only enforces a
  /// connect timeout by default, so a connected-but-stalled socket (which
  /// happens on flaky networks / when the phone changes network state) would
  /// otherwise hang forever and freeze the browse page. Archive downloads use a
  /// longer window since a large file legitimately takes time.
  static const listTimeout = Duration(seconds: 30);
  static const transferTimeout = Duration(minutes: 10);

  static bool get useProxy => appdata.settings['webdavUseProxy'] != false;

  /// Probes an address by listing the folder it would browse. Standalone so the
  /// settings form can test credentials that aren't saved yet.
  static Future<Res<bool>> testConnection({
    required String url,
    required String user,
    required String pass,
    required String root,
  }) async {
    if (url.trim().isEmpty) {
      return const Res.error('URL is empty');
    }
    try {
      final client = webdav.newClient(
        url.trim(),
        user: user.trim(),
        password: pass,
        adapter: RHttpAdapter(enableProxy: useProxy, timeout: listTimeout),
      );
      var target = root.trim();
      if (target.isEmpty) {
        target = '/';
      } else {
        if (!target.startsWith('/')) target = '/$target';
        target = ensureDir(target);
      }
      await client.readDir(target);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }
}

/// Reads one configured WebDAV comic library.
///
/// The recommended remote layout is a single root folder holding one folder per
/// comic. A comic folder may contain chapter subfolders (each a folder of
/// numbered images) or, for a single-chapter comic, the images directly. An
/// optional `cover.*` in the comic folder is used as the cover; otherwise the
/// first image of the first chapter stands in.
///
/// Design note: this deliberately reuses the existing [ComicSource]
/// abstraction rather than inventing a third comic "kind". Every read-side path
/// in the app (reader page loading, cover/image fetch with auth headers, detail
/// page, history, favourites) already dispatches on `sourceKey`, so exposing
/// each library as a native source lets all of that work unchanged — and gives
/// two servers holding a same-named folder separate reading state.
class WebdavLibraryClient {
  WebdavLibraryClient(this.config);

  final WebdavLibraryConfig config;

  /// Client for the library registered under [sourceKey], or null when that
  /// library has since been deleted.
  static WebdavLibraryClient? forSourceKey(String? sourceKey) {
    final config = WebdavLibraryStore.findBySourceKey(sourceKey);
    return config == null ? null : WebdavLibraryClient(config);
  }

  /// Client for the library with [id], or null when it no longer exists.
  static WebdavLibraryClient? forId(String id) {
    final config = WebdavLibraryStore.find(id);
    return config == null ? null : WebdavLibraryClient(config);
  }

  String get sourceKey => config.sourceKey;

  /// Root directory inside the server this library browses.
  String get rootPath => config.rootPath;

  webdav.Client _newClient([Duration timeout = WebdavLibrary.listTimeout]) {
    return webdav.newClient(
      config.url,
      user: config.user,
      password: config.pass,
      // WebDAV libraries usually live on a LAN NAS; the direct-connection
      // default (matching the app-wide toggle) reaches those more reliably.
      adapter: RHttpAdapter(
        enableProxy: WebdavLibrary.useProxy,
        timeout: timeout,
      ),
    );
  }

  /// Headers for the direct image/cover GETs that bypass the webdav client and
  /// go through [AppDio]: a User-Agent (matching the app's other requests, since
  /// the shared loader only injects one when headers are null) plus Basic auth
  /// when credentials exist. Digest is not attempted on this path.
  Map<String, String> _authHeaders() {
    final headers = <String, String>{'user-agent': webUA};
    if (config.user.isNotEmpty || config.pass.isNotEmpty) {
      final token = base64Encode(utf8.encode('${config.user}:${config.pass}'));
      headers['authorization'] = 'Basic $token';
    }
    return headers;
  }

  /// Joins the config base URL with a server-absolute [relPath], collapsing the
  /// slash between them so the result matches what the webdav client requests.
  String _absoluteUrl(String relPath) {
    var base = config.url;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final rel = relPath.startsWith('/') ? relPath : '/$relPath';
    return '$base$rel';
  }

  /// Lists the browsable entries of [dir] (the library root when null).
  Future<Res<List<WebdavEntry>>> listEntries([String? dir]) async {
    final target = WebdavLibrary.ensureDir(dir ?? rootPath);
    try {
      final client = _newClient();
      final files = await client.readDir(target);
      final entries = <WebdavEntry>[];
      for (final f in files) {
        final name = f.name ?? '';
        if (name.isEmpty || name.startsWith('.')) continue;
        final path = f.path ?? '$target$name';
        if (f.isDir == true) {
          entries.add(
            WebdavEntry.comic(
              name: name,
              path: WebdavLibrary.ensureDir(path),
            ),
          );
        } else if (WebdavLibrary.isArchive(name)) {
          entries.add(WebdavEntry.archive(name: name, path: path, size: f.size));
        }
        // Loose images at the browse root are ignored: a comic is a folder.
      }
      entries.sort((a, b) => WebdavLibrary.naturalCompare(a.name, b.name));
      return Res(entries);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
    }
  }

  /// Loads a comic's detail: chapters (subfolders) or a single implicit chapter
  /// (images directly in the folder), plus a cover.
  Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final dir = WebdavLibrary.decodeId(id);
    try {
      final client = _newClient();
      final files = await client.readDir(dir);
      final subDirs = <webdav.File>[];
      final images = <String>[];
      String? coverName;
      for (final f in files) {
        final name = f.name ?? '';
        if (name.isEmpty || name.startsWith('.')) continue;
        if (f.isDir == true) {
          subDirs.add(f);
        } else if (WebdavLibrary.isImage(name)) {
          images.add(name);
          if (coverName == null && name.toLowerCase().startsWith('cover.')) {
            coverName = name;
          }
        }
      }

      final title = WebdavLibrary.titleOf(dir);
      // `chapters` is either a flat {chapterPath: title} map or a grouped
      // {groupName: {chapterPath: title}} map (for 卷/话/番外 tabs). Passed as-is
      // to ComicDetails.fromJson, which builds ComicChapters.grouped from a
      // nested map.
      dynamic chapters;
      String coverUrl = '';

      if (subDirs.isNotEmpty) {
        subDirs.sort(
          (a, b) => WebdavLibrary.naturalCompare(a.name ?? '', b.name ?? ''),
        );
        // Distinguish a grouped comic (comic/group/chapter/images) from a plain
        // chaptered one (comic/chapter/images) by probing the first subfolder:
        // if it holds only further subfolders (no images), this level is groups.
        final groups = await _readGroupChapters(client, dir, subDirs);
        String? firstChapterDir;
        if (groups != null) {
          chapters = groups;
          // Cover fallback digs into the first chapter of the first non-empty
          // group, since a group folder itself holds no images.
          for (final g in groups.values) {
            if (g.isNotEmpty) {
              firstChapterDir = g.keys.first;
              break;
            }
          }
        } else {
          chapters = {
            for (final d in subDirs)
              WebdavLibrary.ensureDir(d.path ?? '$dir${d.name}'): d.name ?? '',
          };
          firstChapterDir = WebdavLibrary.ensureDir(
            subDirs.first.path ?? '$dir${subDirs.first.name}/',
          );
        }
        coverUrl = coverName != null
            ? _absoluteUrl('$dir$coverName')
            : (firstChapterDir != null
                  ? await _firstImageOfPath(client, firstChapterDir)
                  : '');
      } else {
        // Single implicit chapter: images live directly in the comic folder.
        images.sort(WebdavLibrary.naturalCompare);
        // The implicit chapter id is the comic dir itself.
        chapters = {dir: title};
        final firstImage = images.firstWhereOrNull(
          (n) => !n.toLowerCase().startsWith('cover.'),
        );
        coverUrl = coverName != null
            ? _absoluteUrl('$dir$coverName')
            : (firstImage != null ? _absoluteUrl('$dir$firstImage') : '');
      }

      final details = ComicDetails.fromJson({
        'title': title,
        'cover': coverUrl,
        'comicId': id,
        'sourceKey': sourceKey,
        'tags': <String, List<String>>{},
        'chapters': chapters,
        'description': '',
      });
      return Res(details);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
    }
  }

  /// Detects and reads a grouped-chapter layout (comic/group/chapter/images).
  ///
  /// A grouped comic (卷/话/番外 tabs) is migrated as an extra folder layer, so
  /// the comic folder's subfolders are *groups*, each holding chapter folders.
  /// A plain chaptered comic instead has chapter folders directly. They are
  /// told apart by probing: a group folder contains only further subfolders
  /// (no images), a chapter folder contains images.
  ///
  /// Returns a `{groupName: {chapterPath: chapterTitle}}` map when at least one
  /// subfolder is a group, or null for the plain case (caller keeps the flat
  /// layout). Mixed layouts are tolerated: any subfolder that directly holds
  /// images is treated as a chapter and collected under a "默认" group, so
  /// stray chapters aren't lost. [subDirs] must already be natural-sorted.
  Future<Map<String, Map<String, String>>?> _readGroupChapters(
    webdav.Client client,
    String comicDir,
    List<webdav.File> subDirs,
  ) async {
    // Probe only the FIRST subfolder to decide the layout: a chapter folder
    // holds images, a group folder holds only further subfolders. A plain
    // chaptered comic (the common case, possibly hundreds of chapters) is thus
    // ruled out with a single extra request instead of one per chapter — the
    // full per-subfolder scan below runs only once we know it's grouped.
    final classified = await _classifySubDir(client, comicDir, subDirs.first);
    if (!classified.isGroup) {
      // First subfolder is a chapter → plain layout; caller keeps the flat map.
      return null;
    }

    // Grouped: read each top-level subfolder and classify it. A subfolder that
    // directly holds images is a stray chapter (mixed layout) collected under a
    // "默认" tab so nothing is lost; the count equals the tab count, small.
    final grouped = <String, Map<String, String>>{};
    final defaultGroup = <String, String>{};
    for (var i = 0; i < subDirs.length; i++) {
      final d = subDirs[i];
      final path = WebdavLibrary.ensureDir(d.path ?? '$comicDir${d.name}/');
      // Reuse the probe for the first subfolder rather than reading it twice.
      final c = i == 0 ? classified : await _classifySubDir(client, comicDir, d);
      if (c.isGroup) {
        final childDirs = c.childDirs
          ..sort(
            (a, b) => WebdavLibrary.naturalCompare(a.name ?? '', b.name ?? ''),
          );
        grouped[d.name ?? ''] = {
          for (final ch in childDirs)
            WebdavLibrary.ensureDir(ch.path ?? '$path${ch.name}/'):
                ch.name ?? '',
        };
      } else {
        // A chapter folder sitting directly under the comic (stray chapter in a
        // mixed layout, or an unreadable/empty subfolder).
        defaultGroup[path] = d.name ?? '';
      }
    }
    if (defaultGroup.isNotEmpty) {
      // Fold stray direct chapters into a default tab so nothing is lost.
      var name = '默认';
      while (grouped.containsKey(name)) {
        name = '$name ';
      }
      grouped[name] = defaultGroup;
    }
    return grouped;
  }

  /// Reads [d] and decides whether it is a group folder (only subfolders, no
  /// images) or a chapter folder. On a read error it is reported as a
  /// non-group (chapter) so the caller keeps it rather than dropping it.
  Future<({bool isGroup, List<webdav.File> childDirs})> _classifySubDir(
    webdav.Client client,
    String comicDir,
    webdav.File d,
  ) async {
    final path = WebdavLibrary.ensureDir(d.path ?? '$comicDir${d.name}/');
    List<webdav.File> children;
    try {
      children = await client.readDir(path);
    } catch (_) {
      return (isGroup: false, childDirs: const <webdav.File>[]);
    }
    final childDirs = <webdav.File>[];
    var hasImage = false;
    for (final c in children) {
      final cn = c.name ?? '';
      if (cn.isEmpty || cn.startsWith('.')) continue;
      if (c.isDir == true) {
        childDirs.add(c);
      } else if (WebdavLibrary.isImage(cn)) {
        hasImage = true;
      }
    }
    return (isGroup: !hasImage && childDirs.isNotEmpty, childDirs: childDirs);
  }

  Future<String> _firstImageOfPath(webdav.Client client, String dir) async {
    try {
      final d = WebdavLibrary.ensureDir(dir);
      final files = await client.readDir(d);
      final images =
          files
              .where((f) => f.isDir != true && WebdavLibrary.isImage(f.name ?? ''))
              .map((f) => f.name!)
              .toList()
            ..sort(WebdavLibrary.naturalCompare);
      if (images.isEmpty) return '';
      return _absoluteUrl('$d${images.first}');
    } catch (_) {
      return '';
    }
  }

  /// Loads the ordered image URLs of one chapter. [ep] is the chapter folder's
  /// server-absolute path (as stored in [ComicChapters]); when there are no
  /// subfolders it equals the comic folder.
  Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    final dir = WebdavLibrary.ensureDir(ep ?? WebdavLibrary.decodeId(id));
    try {
      final client = _newClient();
      final files = await client.readDir(dir);
      final images =
          files
              .where((f) => f.isDir != true && WebdavLibrary.isImage(f.name ?? ''))
              .map((f) => f.name!)
              .where((n) => !n.toLowerCase().startsWith('cover.'))
              .toList()
            ..sort(WebdavLibrary.naturalCompare);
      final urls = images.map((n) => _absoluteUrl('$dir$n')).toList();
      if (urls.isEmpty) {
        return const Res.error('No images found in this chapter');
      }
      return Res(urls);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
    }
  }

  /// Loading config for a comic-page image: the direct URL plus Basic-auth
  /// header. Fed to [ImageDownloader] via the source's [getImageLoadingConfig].
  Map<String, dynamic> imageLoadingConfig() {
    return {'headers': _authHeaders()};
  }

  /// Probes this library's configured address.
  Future<Res<bool>> testConnection() => WebdavLibrary.testConnection(
    url: config.url,
    user: config.user,
    pass: config.pass,
    root: config.root,
  );

  /// Downloads an archive file to a local temp path for import.
  Future<Res<String>> downloadArchive(
    String path,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final client = _newClient(WebdavLibrary.transferTimeout);
      await client.read2File(path, savePath, onProgress: onProgress);
      return Res(savePath);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
    }
  }

  // --- Migration (write) support ---------------------------------------------
  // Browsing a library is read-only, but migrating local comics *into* one needs
  // a few write primitives. Kept here so migration reuses this WebDAV client
  // (auth/proxy/timeout) instead of standing up a separate one elsewhere.

  /// The server-absolute root (trailing slash) that migration writes into.
  String get migrationRoot => rootPath;

  /// Creates [remoteDir] and any missing parents. Idempotent.
  Future<void> ensureRemoteDir(String remoteDir) async {
    final client = _newClient();
    await client.mkdirAll(WebdavLibrary.ensureDir(remoteDir));
  }

  /// Streams a local file to [remotePath]. Uses the long transfer-window
  /// timeout since an image/cover upload is a real transfer, not a probe.
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    void Function(int count, int total)? onProgress,
  }) async {
    final client = _newClient(WebdavLibrary.transferTimeout);
    await client.writeFromFile(localPath, remotePath, onProgress: onProgress);
  }

  /// Number of named entries in [remoteDir], or -1 when it does not exist or
  /// cannot be read. Lets migration skip a comic whose folder is already
  /// populated on the server (resume safety when local task state was lost).
  Future<int> remoteEntryCount(String remoteDir) async {
    try {
      final client = _newClient();
      final files = await client.readDir(WebdavLibrary.ensureDir(remoteDir));
      return files.where((f) => (f.name ?? '').isNotEmpty).length;
    } catch (_) {
      return -1;
    }
  }
}

/// A single browsable item: either a comic folder or an importable archive.
class WebdavEntry {
  final String name;
  final String path;
  final bool isArchiveFile;
  final int? size;

  const WebdavEntry._({
    required this.name,
    required this.path,
    required this.isArchiveFile,
    this.size,
  });

  factory WebdavEntry.comic({required String name, required String path}) =>
      WebdavEntry._(name: name, path: path, isArchiveFile: false);

  factory WebdavEntry.archive({
    required String name,
    required String path,
    int? size,
  }) => WebdavEntry._(name: name, path: path, isArchiveFile: true, size: size);

  /// The opaque comic id used to open this folder as an online comic.
  String get comicId => WebdavLibrary.encodeId(path);
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
