import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/metrickit.dart';
import 'package:venera/foundation/native_diagnostics.dart';
import 'package:venera/foundation/session_guard.dart';

/// Hides what identifies a site, an account or this device in text that is
/// about to be posted in public.
///
/// Best effort: free text, such as a title quoted inside an error message,
/// cannot be recognised. That is why the result is shown before it leaves.
class Redactor {
  /// [names] are replaced by a numbered alias and [secrets] removed, wherever
  /// they stand as a word of their own.
  Redactor({
    Iterable<String> names = const [],
    Iterable<String> secrets = const [],
  }) : _names = _wordPattern(names),
       _secrets = _wordPattern(secrets);

  static const hidden = '<hidden>';

  final RegExp? _names;

  final RegExp? _secrets;

  final _aliases = <String, String>{};

  final _sites = <String, String>{};

  /// Shorter terms are too likely to be part of ordinary text.
  static RegExp? _wordPattern(Iterable<String> terms) {
    final words =
        terms
            .map((term) => term.trim())
            .where((term) => term.length >= 3)
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (words.isEmpty) return null;
    return RegExp(
      '(?<![A-Za-z0-9_])(?:${words.map(RegExp.escape).join('|')})'
      '(?![A-Za-z0-9_])',
      caseSensitive: false,
    );
  }

  /// One alias per host for the whole report, so "the same site again" still
  /// reads as such.
  String _site(String host) =>
      _sites.putIfAbsent(host.toLowerCase(), () => 'site-${_sites.length + 1}');

  // Header values contain spaces and separators, so they go to the line's end.
  static final _credentialLine = RegExp(
    r'\b((?:proxy-)?authorization|(?:set-)?cookie2?)\b(\s*[:=]\s*)[^\n]*',
    caseSensitive: false,
  );

  static final _bearer = RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}');

  static final _secretPair = RegExp(
    r'''\b(token|access_token|refresh_token|id_token|api[_-]?key|x-api-key|password|passwd|pwd|secret|client_secret|signature|session_?id|sid)\b(["']?\s*[:=]\s*["']?)([^\s"'&;,}\]]+)''',
    caseSensitive: false,
  );

  static final _url = RegExp(
    r'''\b([a-z][a-z0-9+.-]{1,15})://[^\s"'<>]+''',
    caseSensitive: false,
  );

  static const _networkSchemes = {
    'http', 'https', 'ws', 'wss', 'ftp', 'ftps', 'dav', 'davs', 'webdav', 'smb', //
  };

  // Anchored to the start of a run of name characters: without that, every
  // position in a long token is tried and the scan turns quadratic.
  static final _email = RegExp(
    r'(?<![\w.+-])[\w.+-]{1,64}@[\w-]+(?:\.[\w-]+)+',
  );

  // The last label must end the name, or `java.net.SocketException` and the
  // like would read as hosts. The list leaves out endings that double as
  // everyday member names (`padding.top`, `item.id`).
  static final _host = RegExp(
    r'(?<![\w@/.\\-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+'
    r'(?:com|net|org|xyz|club|vip|icu|moe|tv|io|cn|jp|kr|tw|hk|ru|de|fr|uk|eu|nl|gg|pw|cx|lol)'
    r'(?![\w-]|\.\w)',
    caseSensitive: false,
  );

  // Four dotted numbers are as often a build number (`5.0.0.102`) as an
  // address, so one counts only with a port or where a message calls it one.
  static final _ipv4 = RegExp(
    r'((?:address|host|ip)\s*[:=]\s*)?'
    r'(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(:\d{1,5})?(?![\w.])',
    caseSensitive: false,
  );

  // How dart:io reports the file an operation failed on. Folder names are
  // often titles.
  static final _quotedPath = RegExp(r"(path\s*=\s*')([^']*)'");

  static final _homeDirectory = RegExp(
    r'''((?:[A-Za-z]:[\\/]Users[\\/])|(?:/Users/)|(?:/home/))([^\\/\s"']+)''',
  );

  static final _extension = RegExp(r'\.[A-Za-z0-9]{1,5}$');

  String redact(String text) {
    final secrets = _secrets;
    if (secrets != null) text = text.replaceAll(secrets, hidden);
    final names = _names;
    if (names != null) {
      text = text.replaceAllMapped(
        names,
        (m) => _aliases.putIfAbsent(
          m[0]!.toLowerCase(),
          () => 'script-${_aliases.length + 1}',
        ),
      );
    }
    return text
        .replaceAllMapped(_credentialLine, (m) => '${m[1]}${m[2]}$hidden')
        .replaceAllMapped(_bearer, (m) => '${m[1]} $hidden')
        .replaceAllMapped(_url, _replaceUrl)
        .replaceAllMapped(_secretPair, (m) => '${m[1]}${m[2]}$hidden')
        .replaceAll(_email, '<email>')
        .replaceAllMapped(_quotedPath, (m) {
          final extension = _extension.firstMatch(m[2]!)?[0] ?? '';
          return "${m[1]}<path>$extension'";
        })
        .replaceAllMapped(_homeDirectory, (m) => '${m[1]}<user>')
        .replaceAllMapped(_host, (m) => _site(m[0]!))
        .replaceAllMapped(_ipv4, (m) {
          if (m[1] == null && m[3] == null) return m[0]!;
          return '${m[1] ?? ''}${_site(m[2]!)}';
        });
  }

  String _replaceUrl(Match match) {
    final scheme = match[1]!.toLowerCase();
    final raw = match[0]!;
    if (scheme == 'content') return 'content://<uri>';
    if (!_networkSchemes.contains(scheme)) return raw;
    // Punctuation that follows a URL in prose is not part of it.
    var end = raw.length;
    while (end > 0 && '.,;:!?)]}'.contains(raw[end - 1])) {
      end--;
    }
    final rest = raw.substring(scheme.length + 3, end);
    final pathStart = rest.indexOf(RegExp(r'[/?#]'));
    var authority = pathStart == -1 ? rest : rest.substring(0, pathStart);
    final path = pathStart == -1
        ? ''
        : rest.substring(pathStart).split(RegExp(r'[?#]')).first;
    authority = authority.substring(authority.lastIndexOf('@') + 1);
    final port = authority.lastIndexOf(':');
    if (port != -1 && !authority.endsWith(']')) {
      authority = authority.substring(0, port);
    }
    // The path and query can name the site or carry a token; the extension is
    // kept because the kind of file is often what matters.
    final shown = path.length <= 1
        ? ''
        : '/…${_extension.firstMatch(path)?[0] ?? ''}';
    return '$scheme://${_site(authority)}$shown${raw.substring(end)}';
  }
}

/// The text a user attaches to a bug report: where the app runs, how the run
/// in question ended, what it was doing, and its errors. Redacted.
abstract final class DiagnosticsReport {
  /// An issue body is rejected past 65536 characters.
  static const maxLength = 60000;

  static const _maxEntryLength = 2000;

  static const _maxContextEntries = 20;

  static const _maxContextLength = 200;

  static const _maxSystemReportLength = 24000;

  static String get platform =>
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion} '
      '(${Abi.current()})';

  static String? _device;

  static bool _deviceRead = false;

  /// The device model, where it can be read without a native bridge.
  static Future<String?> device() async {
    if (!_deviceRead) {
      _device = await _readDevice();
      _deviceRead = true;
    }
    return _device;
  }

  static Future<String?> _readDevice() async {
    if (!Platform.isAndroid) return null;
    try {
      final parts = <String>[];
      for (final key in ['ro.product.manufacturer', 'ro.product.model']) {
        final result = await Process.run('getprop', [
          key,
        ]).timeout(const Duration(seconds: 2));
        final value = '${result.stdout}'.trim();
        if (value.isNotEmpty) parts.add(value);
      }
      return parts.isEmpty ? null : parts.join(' ');
    } catch (_) {
      return null;
    }
  }

  /// Names the user's installed scripts go by. They tend to name a site, and
  /// they turn up inside error messages.
  static List<String> _scriptNames() => [
    for (final source in ComicSource.all())
      if (source.filePath.endsWith('.js')) ...[source.name, source.key],
  ];

  /// The sync account: the address is caught as a URL, these are not.
  static List<String> _accountSecrets() {
    final webdav = appdata.settings['webdav'];
    return webdav is List ? webdav.skip(1).whereType<String>().toList() : [];
  }

  /// The report for an abnormal exit set aside earlier.
  ///
  /// [until] is the last record of the next abnormal exit on file, if any:
  /// system reports that arrived after it are about that one.
  static Future<String> forArchived(SessionReport report, {int? until}) async {
    var entries = const <LogItem>[];
    // A quarter of a megabyte at most, read on a tap.
    if (report.log.existsSync()) {
      entries = Log.parse(
        utf8.decode(report.log.readAsBytesSync(), allowMalformed: true),
      );
    }
    return build(
      appVersion: App.version,
      platform: platform,
      device: await device(),
      run: report.record,
      abnormal: true,
      endedBefore: report.archivedAt,
      osExit: report.osExit,
      // Android's is on file from when the run was set aside. HarmonyOS
      // delivers its report some time after the next launch, so that one is
      // asked for now. Apple's arrive on a later launch and are kept by the
      // host; each belongs to the last run that ended before it arrived.
      systemReport: report.trace.existsSync()
          ? report.trace.readAsStringSync()
          : App.isOhos
          ? systemReportFor(
              await readOhosNativeRecords(),
              from: report.record.id,
              to: report.archivedAt,
            )
          : App.isIOS || App.isMacOS
          ? readSystemDiagnostics(
              Directory('${App.dataPath}/diagnostics'),
              from: report.record.lastAt,
              to: until,
            )
          : null,
      entries: entries,
      names: _scriptNames(),
      secrets: _accountSecrets(),
    );
  }

  static final _recordTime = RegExp(r'^APP_(?:CRASH|FREEZE): \{"time":(\d+)');

  /// The system's crash and freeze reports that fall within one run.
  ///
  /// The host keeps the last few across launches, so which run a report is
  /// about has to come from the time the system stamped on it.
  static String? systemReportFor(
    Iterable<String> records, {
    required int from,
    required int to,
  }) {
    final matching = records.where((record) {
      final time = int.tryParse(_recordTime.firstMatch(record)?[1] ?? '');
      return time != null && time >= from - 1000 && time <= to + 1000;
    }).toList();
    return matching.isEmpty ? null : matching.join('\n\n');
  }

  static Future<String> forCurrentRun() async => build(
    appVersion: App.version,
    platform: platform,
    device: await device(),
    run: SessionGuard.current,
    entries: Log.logs,
    names: _scriptNames(),
    secrets: _accountSecrets(),
  );

  static String build({
    required String appVersion,
    required String platform,
    String? device,
    SessionRecord? run,
    bool abnormal = false,
    int? endedBefore,
    String? osExit,
    String? systemReport,
    Iterable<LogItem> entries = const [],
    Iterable<String> names = const [],
    Iterable<String> secrets = const [],
    DateTime? now,
  }) {
    final redactor = Redactor(names: names, secrets: secrets);
    final buffer = StringBuffer()
      ..writeln('VeneraX diagnostics')
      ..writeln('App version: ${run?.version ?? appVersion}')
      ..writeln('Platform: $platform');
    if (device != null) buffer.writeln('Device: $device');
    buffer.writeln('Exported at: ${now ?? DateTime.now()}');

    if (run != null) {
      buffer
        ..writeln()
        ..writeln(
          abnormal ? '== Run that ended abnormally ==' : '== Current run ==',
        )
        ..writeln('Started: ${DateTime.fromMillisecondsSinceEpoch(run.id)}')
        ..writeln('Last recorded: ${_offset(run.lastAt - run.id)}')
        ..writeln(
          'State: ${switch (run.presence) {
            SessionRecord.front => 'in use',
            SessionRecord.away => 'not on screen',
            _ => 'launching',
          }}',
        )
        ..writeln(
          'In progress: ${run.active.isEmpty ? 'nothing recorded' : run.active.join(', ')}',
        );
      if (run.safeMode) buffer.writeln('Safe mode: yes');
      if (osExit != null) {
        buffer.writeln('System exit reason: ${redactor.redact(osExit)}');
      }
      if (run.steps.isNotEmpty) {
        buffer.writeln('Steps:');
        for (final step in run.steps) {
          buffer.writeln('  ${_offset(step.at - run.id)} ${step.name}');
        }
      }
    }

    if (systemReport != null) {
      // The stack is at the top of a system report; what follows it are
      // registers, memory maps and log lines.
      var text = redactor.redact(systemReport);
      if (text.length > _maxSystemReportLength) {
        text = '${text.substring(0, _maxSystemReportLength)}...';
      }
      buffer
        ..writeln()
        ..writeln('== System crash report ==')
        ..writeln(text);
    }

    // A previous run's file can hold entries from before or after that run.
    final from = abnormal && run != null ? run.id - 2000 : null;
    final shown = entries.where((entry) {
      final at = entry.time.millisecondsSinceEpoch;
      if (from != null && at < from) return false;
      if (endedBefore != null && at > endedBefore) return false;
      return true;
    }).toList();
    // Scripts print whatever they like; none of it is the app's to publish.
    final own = shown.where((entry) => entry.title != 'JS Console').toList();
    final omitted = shown.length - own.length;

    final important = <String>[];
    var room = maxLength - buffer.length - 2000;
    var dropped = 0;
    for (final entry in own.reversed) {
      if (entry.level == LogLevel.info) continue;
      final text = _format(entry, redactor, _maxEntryLength);
      if (text.length > room) {
        dropped++;
        continue;
      }
      room -= text.length;
      important.add(text);
    }
    final context = own
        .where((entry) => entry.level == LogLevel.info)
        .toList()
        .reversed
        .take(_maxContextEntries)
        .map((entry) => _format(entry, redactor, _maxContextLength))
        .toList();

    buffer
      ..writeln()
      ..writeln('== Errors and warnings (${important.length}) ==');
    if (dropped > 0) buffer.writeln('($dropped older entries left out)');
    important.reversed.forEach(buffer.write);
    if (context.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('== Last other entries ==');
      context.reversed.forEach(buffer.write);
    }
    if (omitted > 0) {
      buffer
        ..writeln()
        ..writeln('($omitted entries printed by scripts left out)');
    }
    return buffer.toString();
  }

  static String _offset(int milliseconds) =>
      '+${(milliseconds / 1000).toStringAsFixed(3)}s';

  static String _format(LogItem entry, Redactor redactor, int limit) {
    var content = entry.content;
    if (entry.title == 'Network') {
      // The first lines say which request failed and how; what follows are
      // the headers and the body the server sent.
      content = content
          .split('\n')
          .takeWhile((line) => !line.startsWith('headers:'))
          .take(3)
          .join('\n');
    }
    content = redactor.redact(content);
    if (content.length > limit) content = '${content.substring(0, limit)}...';
    return '${entry.level.name} ${entry.title} ${entry.time}\n$content\n\n';
  }
}
