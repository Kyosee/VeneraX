import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// Remote comic library backed by a WebDAV directory tree.
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
/// the library as a native source lets all of that work unchanged.
class WebdavLibrary {
  WebdavLibrary._();

  static final WebdavLibrary instance = WebdavLibrary._();

  /// The stable source key the library registers itself under. Chosen to be
  /// unlikely to collide with any user JS source key.
  static const sourceKey = 'webdav_library';

  static const _configKey = 'webdavComicLibrary';

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

  /// Raw `[url, user, pass, rootPath]` config the user set specifically for the
  /// library, or an empty list when they never did.
  static List get _ownConfig {
    final v = appdata.settings[_configKey];
    return v is List ? v : const [];
  }

  static bool _hasOwnConfig(List c) =>
      c.length >= 3 && c[0] is String && (c[0] as String).trim().isNotEmpty;

  /// The data-sync WebDAV config (`[url, user, pass]`), used as a fallback so a
  /// user who already configured sync can browse a library on the same server
  /// without re-entering credentials.
  static List get _syncConfig {
    final v = appdata.settings['webdav'];
    return v is List ? v : const [];
  }

  /// Effective config: the library's own if set, otherwise the sync config.
  /// This is what makes the library "auto-load" for sync users (the library
  /// still has no root of its own in that case, so it browses the server root).
  static List get _rawConfig {
    final own = _ownConfig;
    if (_hasOwnConfig(own)) return own;
    return _syncConfig;
  }

  static bool get isConfigured {
    final c = _rawConfig;
    return c.length >= 3 &&
        c[0] is String &&
        (c[0] as String).trim().isNotEmpty;
  }

  /// Whether the library is only usable via the inherited data-sync config
  /// (the user never set a library-specific config). Lets the UI show a hint
  /// and prefill the form from the sync credentials.
  static bool get isUsingSyncFallback =>
      !_hasOwnConfig(_ownConfig) && isConfigured;

  static String get _url => (_rawConfig.elementAtOrNull(0) as String?) ?? '';
  static String get _user => (_rawConfig.elementAtOrNull(1) as String?) ?? '';
  static String get _pass => (_rawConfig.elementAtOrNull(2) as String?) ?? '';

  /// Effective credentials for prefilling the settings form (own config if set,
  /// otherwise the inherited sync config). The root is only ever the library's
  /// own — the sync config carries none.
  static ({String url, String user, String pass, String root}) get effective =>
      (
        url: _url,
        user: _user,
        pass: _pass,
        root: (_ownConfig.elementAtOrNull(3) as String?)?.trim() ?? '',
      );

  /// Root directory inside the server to treat as the library. Defaults to the
  /// server root the config URL already points at.
  static String get rootPath {
    final r = (_rawConfig.elementAtOrNull(3) as String?)?.trim() ?? '';
    if (r.isEmpty) return '/';
    return _ensureDir(r.startsWith('/') ? r : '/$r');
  }

  static void saveConfig({
    required String url,
    required String user,
    required String pass,
    required String root,
  }) {
    if (url.trim().isEmpty) {
      appdata.settings[_configKey] = [];
    } else {
      appdata.settings[_configKey] = [
        url.trim(),
        user.trim(),
        pass,
        root.trim(),
      ];
    }
    appdata.saveData();
  }

  /// Directory listings and probes must be bounded: rhttp only enforces a
  /// connect timeout by default, so a connected-but-stalled socket (which
  /// happens on flaky networks / when the phone changes network state) would
  /// otherwise hang forever and freeze the browse page. Archive downloads pass
  /// a longer window since a large file legitimately takes time.
  static const _listTimeout = Duration(seconds: 30);
  static const _downloadTimeout = Duration(minutes: 10);

  webdav.Client _newClient([Duration timeout = _listTimeout]) {
    return webdav.newClient(
      _url,
      user: _user,
      password: _pass,
      // WebDAV libraries usually live on a LAN NAS; the direct-connection
      // default (matching the app-wide toggle) reaches those more reliably.
      adapter: RHttpAdapter(enableProxy: _useProxy, timeout: timeout),
    );
  }

  static bool get _useProxy => appdata.settings['webdavUseProxy'] != false;

  /// Headers for the direct image/cover GETs that bypass the webdav client and
  /// go through [AppDio]: a User-Agent (matching the app's other requests, since
  /// the shared loader only injects one when headers are null) plus Basic auth
  /// when credentials exist. Digest is not attempted on this path.
  Map<String, String> _authHeaders() {
    final headers = <String, String>{'user-agent': webUA};
    if (_user.isNotEmpty || _pass.isNotEmpty) {
      final token = base64Encode(utf8.encode('$_user:$_pass'));
      headers['authorization'] = 'Basic $token';
    }
    return headers;
  }

  static String _ensureDir(String p) => p.endsWith('/') ? p : '$p/';

  /// Joins the config base URL with a server-absolute [relPath], collapsing the
  /// slash between them so the result matches what the webdav client requests.
  String _absoluteUrl(String relPath) {
    var base = _url;
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final rel = relPath.startsWith('/') ? relPath : '/$relPath';
    return '$base$rel';
  }

  /// Encodes a server-absolute directory path into an opaque comic id that
  /// round-trips through the reader/history without a lookup table.
  static String encodeId(String path) =>
      base64Url.encode(utf8.encode(_ensureDir(path)));

  static String decodeId(String id) {
    try {
      return utf8.decode(base64Url.decode(id));
    } catch (_) {
      // Tolerate ids that were never encoded (e.g. a raw path).
      return _ensureDir(id);
    }
  }

  static bool _isImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(name.substring(dot + 1).toLowerCase());
  }

  static bool isArchive(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return archiveExts.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Natural-order comparison so `2.jpg` sorts before `10.jpg`.
  static int _naturalCompare(String a, String b) {
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

  /// A single browsable entry in the library listing.
  Future<Res<List<WebdavEntry>>> listEntries([String? dir]) async {
    if (!isConfigured) {
      return const Res.error('WebDAV comic library is not configured');
    }
    final target = _ensureDir(dir ?? rootPath);
    try {
      final client = _newClient();
      final files = await client.readDir(target);
      final entries = <WebdavEntry>[];
      for (final f in files) {
        final name = f.name ?? '';
        if (name.isEmpty || name.startsWith('.')) continue;
        final path = f.path ?? '$target$name';
        if (f.isDir == true) {
          entries.add(WebdavEntry.comic(name: name, path: _ensureDir(path)));
        } else if (isArchive(name)) {
          entries.add(WebdavEntry.archive(
            name: name,
            path: path,
            size: f.size,
          ));
        }
        // Loose images at the browse root are ignored: a comic is a folder.
      }
      entries.sort((a, b) => _naturalCompare(a.name, b.name));
      return Res(entries);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
    }
  }

  /// Loads a comic's detail: chapters (subfolders) or a single implicit chapter
  /// (images directly in the folder), plus a cover.
  Future<Res<ComicDetails>> loadComicInfo(String id) async {
    if (!isConfigured) {
      return const Res.error('WebDAV comic library is not configured');
    }
    final dir = decodeId(id);
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
        } else if (_isImage(name)) {
          images.add(name);
          if (coverName == null &&
              name.toLowerCase().startsWith('cover.')) {
            coverName = name;
          }
        }
      }

      final title = _dirTitle(dir);
      Map<String, String>? chapters;
      String coverUrl = '';

      if (subDirs.isNotEmpty) {
        subDirs.sort(
          (a, b) => _naturalCompare(a.name ?? '', b.name ?? ''),
        );
        chapters = {
          for (final d in subDirs)
            _ensureDir(d.path ?? '$dir${d.name}'): d.name ?? '',
        };
        coverUrl = coverName != null
            ? _absoluteUrl('$dir$coverName')
            : await _firstImageOf(client, subDirs.first);
      } else {
        // Single implicit chapter: images live directly in the comic folder.
        images.sort(_naturalCompare);
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

  Future<String> _firstImageOf(webdav.Client client, webdav.File dir) async {
    try {
      final files = await client.readDir(_ensureDir(dir.path ?? ''));
      final images = files
          .where((f) => f.isDir != true && _isImage(f.name ?? ''))
          .map((f) => f.name!)
          .toList()
        ..sort(_naturalCompare);
      if (images.isEmpty) return '';
      return _absoluteUrl('${_ensureDir(dir.path ?? '')}${images.first}');
    } catch (_) {
      return '';
    }
  }

  /// Loads the ordered image URLs of one chapter. [ep] is the chapter folder's
  /// server-absolute path (as stored in [ComicChapters]); when there are no
  /// subfolders it equals the comic folder.
  Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    if (!isConfigured) {
      return const Res.error('WebDAV comic library is not configured');
    }
    final dir = _ensureDir(ep ?? decodeId(id));
    try {
      final client = _newClient();
      final files = await client.readDir(dir);
      final images = files
          .where((f) => f.isDir != true && _isImage(f.name ?? ''))
          .map((f) => f.name!)
          .where((n) => !n.toLowerCase().startsWith('cover.'))
          .toList()
        ..sort(_naturalCompare);
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

  /// Human-readable title for a directory path (its last path segment).
  static String titleOf(String dir) => _dirTitle(dir);

  static String _dirTitle(String dir) {
    var p = dir;
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final slash = p.lastIndexOf('/');
    final name = slash < 0 ? p : p.substring(slash + 1);
    return Uri.decodeComponent(name).isEmpty
        ? name
        : Uri.decodeComponent(name);
  }

  /// Probes the current (or supplied) config by listing its root.
  Future<Res<bool>> testConnection({
    String? url,
    String? user,
    String? pass,
    String? root,
  }) async {
    final u = url ?? _url;
    if (u.trim().isEmpty) {
      return const Res.error('URL is empty');
    }
    try {
      final client = webdav.newClient(
        u.trim(),
        user: (user ?? _user).trim(),
        password: pass ?? _pass,
        adapter: RHttpAdapter(enableProxy: _useProxy, timeout: _listTimeout),
      );
      final target = () {
        final r = (root ?? '').trim();
        if (r.isEmpty) return rootPath;
        return _ensureDir(r.startsWith('/') ? r : '/$r');
      }();
      await client.readDir(target);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// Downloads an archive file to a local temp path for import.
  Future<Res<String>> downloadArchive(
    String path,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!isConfigured) {
      return const Res.error('WebDAV comic library is not configured');
    }
    try {
      final client = _newClient(_downloadTimeout);
      await client.read2File(path, savePath, onProgress: onProgress);
      return Res(savePath);
    } catch (e, s) {
      Log.error('WebdavLibrary', e, s);
      return Res.error(e.toString());
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
  }) =>
      WebdavEntry._(name: name, path: path, isArchiveFile: true, size: size);

  /// The opaque comic id used to open this folder as an online comic.
  String get comicId => WebdavLibrary.encodeId(path);
}

extension _ElementAtOrNull on List {
  Object? elementAtOrNull(int index) =>
      (index >= 0 && index < length) ? this[index] : null;
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
