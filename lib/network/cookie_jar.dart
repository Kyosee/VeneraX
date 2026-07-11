import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/ext.dart';

import 'dart:io' show Cookie;

export 'dart:io' show Cookie;

List<Cookie> cookiesFromPlatformCookies(
  Iterable<dynamic>? cookies, {
  String? fallbackDomain,
}) {
  if (cookies == null) {
    return const [];
  }
  return cookies.map((cookie) {
    final result = Cookie(cookie.name.toString(), cookie.value.toString());
    try {
      final domain = cookie.domain;
      result.domain = domain?.toString() ?? fallbackDomain;
    } catch (_) {
      result.domain = fallbackDomain;
    }
    try {
      final path = cookie.path;
      result.path = path?.toString();
    } catch (_) {}
    try {
      final expires = cookie.expires;
      if (expires is DateTime) {
        result.expires = expires;
      }
    } catch (_) {}
    try {
      result.secure = cookie.secure == true;
    } catch (_) {}
    try {
      result.httpOnly = cookie.httpOnly == true;
    } catch (_) {}
    return result;
  }).toList();
}

class CookieJarSql {
  late CommonDatabase _db;

  final String path;

  CookieJarSql(this.path) {
    init();
  }

  void init() {
    try {
      _db = DatabaseGateway.instance.openManaged(path);
    } on SqliteException catch (e, s) {
      // A crash mid-WAL-write can leave sidecars the next open cannot recover
      // (seen live: SQLITE_IOERR_TRUNCATE from `PRAGMA journal_mode = WAL` at
      // startup), and this open failing used to take the whole deferred init
      // down with it. Cookies only cost a re-login: move the broken files
      // aside and start fresh instead of failing every launch.
      Log.error("Cookie Jar", "Failed to open cookie.db, recreating: $e", s);
      backupAsideCorruptDatabase(path);
      _db = DatabaseGateway.instance.openManaged(path);
    }
    _ensureTable();
  }

  void _ensureTable() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
  }

  /// Replaces cookie content with the database file at [sourcePath] by
  /// closing the connection, swapping the file, and reopening — see
  /// [restoreDatabaseFiles]. Runs inside the caller's exclusive window.
  Future<void> restoreFrom(String sourcePath) async {
    DatabaseGateway.instance.closeManaged(path);
    try {
      restoreDatabaseFiles({path: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(path);
    }
    _ensureTable();
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    var current = loadForRequest(uri);
    for (var cookie in cookies) {
      var currentCookie = current.firstWhereOrNull(
        (element) =>
            element.name == cookie.name &&
            (cookie.path == null || cookie.path!.startsWith(element.path!)),
      );
      var domain = currentCookie?.domain ?? cookie.domain;
      if (domain == null || domain.isEmpty) {
        domain = uri.host;
      }
      var path = cookie.path;
      if (path == null || path.isEmpty) {
        path = "/";
      }
      _db.execute(
        '''
        INSERT OR REPLACE INTO cookies (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
        [
          cookie.name,
          cookie.value,
          domain,
          path,
          cookie.expires?.millisecondsSinceEpoch,
          cookie.secure ? 1 : 0,
          cookie.httpOnly ? 1 : 0,
        ],
      );
    }
  }

  List<Cookie> _loadWithDomain(String domain) {
    var rows = _db.select(
      '''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies
      WHERE domain = ?;
    ''',
      [domain],
    );

    return rows
        .map(
          (row) => Cookie(row["name"] as String, row["value"] as String)
            ..domain = row["domain"] as String
            ..path = row["path"] as String
            ..expires = row["expires"] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row["expires"] as int)
            ..secure = row["secure"] == 1
            ..httpOnly = row["httpOnly"] == 1,
        )
        .toList();
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  List<Cookie> loadForRequest(Uri uri) {
    // if uri.host is example.example.com, acceptedDomains will be [".example.example.com", ".example.com", "example.com"]
    var acceptedDomains = _getAcceptedDomains(uri.host);

    var cookies = <Cookie>[];
    for (var domain in acceptedDomains) {
      cookies.addAll(_loadWithDomain(domain));
    }

    // check expires
    var expires = cookies.where(
      (cookie) =>
          cookie.expires != null && cookie.expires!.isBefore(DateTime.now()),
    );
    for (var cookie in expires) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [cookie.name, cookie.domain, cookie.path],
      );
    }

    return cookies
        .where(
          (element) =>
              !expires.contains(element) && _checkPathMatch(uri, element.path),
        )
        .toList();
  }

  bool _checkPathMatch(Uri uri, String? cookiePath) {
    if (cookiePath == null) {
      return true;
    }

    if (cookiePath == uri.path) {
      return true;
    }

    if (cookiePath == "/") {
      return true;
    }

    if (cookiePath.endsWith("/")) {
      return uri.path.startsWith(cookiePath);
    }

    return uri.path.startsWith(cookiePath);
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    var cookies = <Cookie>[];
    for (var header in cookieHeader) {
      try {
        var cookie = Cookie.fromSetCookieValue(header);
        cookies.add(cookie);
      } catch (_) {
        Log.warning("Network", "Invalid cookie header: $header");
        continue;
      }
    }
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    var cookies = loadForRequest(uri);
    var map = <String, Cookie>{};
    for (var cookie in cookies) {
      if (map.containsKey(cookie.name)) {
        if (cookie.domain![0] != '.' && map[cookie.name]!.domain![0] == '.') {
          map[cookie.name] = cookie;
        } else if (cookie.domain!.length > map[cookie.name]!.domain!.length) {
          map[cookie.name] = cookie;
        }
      } else {
        map[cookie.name] = cookie;
      }
    }
    return map.entries
        .map((cookie) => "${cookie.value.name}=${cookie.value.value}")
        .join("; ");
  }

  void delete(Uri uri, String name) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [name, domain, uri.path],
      );
    }
  }

  void deleteByName(Uri uri, String name) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ?;
      ''',
        [name, domain],
      );
    }
  }

  void deleteUri(Uri uri) {
    var acceptedDomains = _getAcceptedDomains(uri.host);
    for (var domain in acceptedDomains) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE domain = ?;
      ''',
        [domain],
      );
    }
  }

  void deleteAll() {
    _db.execute('''
      DELETE FROM cookies;
    ''');
  }

  void dispose() {
    DatabaseGateway.instance.closeManaged(path);
  }
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;

  static Future<SingleInstanceCookieJar> createInstance() async {
    if (instance != null) {
      return instance!;
    }
    var dataPath = (await getApplicationSupportDirectory()).path;
    instance = SingleInstanceCookieJar("$dataPath/cookie.db");
    return instance!;
  }
}

class CookieManagerSql extends Interceptor {
  final CookieJarSql cookieJar;

  CookieManagerSql(this.cookieJar);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    var cookies = cookieJar.loadForRequestCookieHeader(options.uri);
    if (cookies.isNotEmpty) {
      if (options.headers["cookie"] != null) {
        cookies = "${options.headers["cookie"]}; $cookies";
      }
      options.headers["cookie"] = cookies;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    cookieJar.saveFromResponseCookieHeader(
      response.requestOptions.uri,
      response.headers["set-cookie"] ?? [],
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}
