import 'dart:convert';

import 'package:venera/network/app_dio.dart';

/// A source URL split into the address to request and the credentials that were
/// embedded in it.
///
/// Source list and script URLs may carry `user:secret@host` credentials, which
/// is the only way to reach a private host that wants HTTP Basic Auth. They must
/// not be sent as part of the address: some hosts ignore them outright, and the
/// network error log records the request path, so a failed request would copy
/// the secret into a log the user may attach to a bug report.
class SourceUrlCredentials {
  const SourceUrlCredentials(this.url, this.basicAuth);

  /// The address to request, with any credentials removed.
  final String url;

  /// Base64 of `user:secret`, or null when the URL carried none.
  final String? basicAuth;

  /// Splits [rawUrl] into its bare address and Basic Auth header value. A URL
  /// that does not parse is passed through untouched so the caller still reports
  /// the failure the request itself produces.
  static SourceUrlCredentials parse(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      if (uri.hasAuthority && uri.userInfo.isNotEmpty) {
        return SourceUrlCredentials(
          uri.replace(userInfo: '').toString(),
          base64Encode(utf8.encode(uri.userInfo)),
        );
      }
    } catch (_) {
      // Not parseable as a URI; request it as given.
    }
    return SourceUrlCredentials(rawUrl, null);
  }

  /// [headers] plus an Authorization entry when credentials are present.
  Map<String, String> headersWith(Map<String, String> headers) {
    if (basicAuth == null) {
      return headers;
    }
    return {...headers, 'Authorization': 'Basic $basicAuth'};
  }
}

/// Whether [rawUrl] is usable as a source script or source list address.
///
/// Wider than [StringExt.isURL], which rejects forms that are legitimate here:
/// embedded `user:secret@host` credentials (the only way to reach a private
/// host), a hostname with no dot such as `localhost`, and a bracketed IPv6
/// literal. Only http and https are accepted — the downloader speaks nothing
/// else, so allowing another scheme would defer a certain failure to the
/// request instead of reporting it while the address is being entered.
bool isValidSourceUrl(String rawUrl) {
  final Uri uri;
  try {
    uri = Uri.parse(rawUrl.trim());
  } catch (_) {
    return false;
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return false;
  }
  return uri.host.isNotEmpty;
}

/// Fetches a source script or source list from [rawUrl] as text, honouring any
/// `user:secret@host` credentials embedded in it.
///
/// Every source download goes through here so that a private host works the same
/// way from each entry point: installing a script, browsing a library catalog,
/// checking for updates, and updating one source.
Future<Response<String>> fetchSourceText(
  String rawUrl, {
  Map<String, String> headers = const {'cache-time': 'no'},
  ResponseType responseType = ResponseType.plain,
}) {
  final parsed = SourceUrlCredentials.parse(rawUrl);
  return AppDio().get<String>(
    parsed.url,
    options: Options(
      responseType: responseType,
      headers: parsed.headersWith(headers),
    ),
  );
}
