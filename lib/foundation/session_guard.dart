import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/boot_time.dart';
import 'package:venera/foundation/log.dart';

/// How the previous run ended, as far as this one can tell.
enum PreviousExit {
  /// No readable record: a first run, or a file cut short by power loss.
  unknown,

  /// The app closed itself.
  clean,

  /// It was not on screen. The system reclaiming it and the user swiping it
  /// away or ending its task look identical from here, and none is a crash.
  background,

  /// The device has booted since, so losing power or shutting down explains it.
  deviceRestarted,

  /// Another version left the record; a report about it would be out of date.
  appUpdated,

  /// It ended while in use and nothing else explains it.
  suspectedCrash,
}

typedef SessionStep = ({int at, String name});

/// What one run leaves on disk for the next one to judge.
class SessionRecord {
  SessionRecord({
    required this.id,
    required this.version,
    this.bootAt,
    this.presence = unknown,
    this.everFront = false,
    this.settled = false,
    this.clean = false,
    this.recovery = false,
    this.safeMode = false,
    int? lastAt,
    List<String>? active,
    List<SessionStep>? steps,
    this.earlyFailures = 0,
    this.fragile = false,
    this.pendingReport,
  }) : lastAt = lastAt ?? id,
       active = active ?? [],
       steps = steps ?? [];

  static const front = 'front';
  static const away = 'away';
  static const unknown = 'unknown';

  /// When the run started, in milliseconds since the epoch.
  final int id;

  final String version;

  /// See [bootTimeMillis].
  final int? bootAt;

  /// [front] while the user is looking at the app, [away] once they are not,
  /// [unknown] before the platform has reported either.
  String presence;

  bool everFront;

  /// The run outlived [SessionGuard.settleAfter].
  bool settled;

  /// The app was closing itself when this was written.
  bool clean;

  /// The recovery page was up: nothing that could crash was running.
  bool recovery;

  bool safeMode;

  /// When the record was last written. Not a heartbeat: the run may have
  /// lasted much longer.
  int lastAt;

  /// What was in progress.
  final List<String> active;

  final List<SessionStep> steps;

  /// Runs in a row, before this one, that ended abnormally before settling.
  int earlyFailures;

  /// Recovery has been offered and no ordinary run has settled since.
  bool fragile;

  /// The archived abnormal exit the user has not been told about yet.
  String? pendingReport;

  Map<String, dynamic> toJson() => {
    'id': id,
    'version': version,
    'bootAt': bootAt,
    'presence': presence,
    'everFront': everFront,
    'settled': settled,
    'clean': clean,
    'recovery': recovery,
    'safeMode': safeMode,
    'lastAt': lastAt,
    'active': active,
    'steps': [
      for (final step in steps) [step.at, step.name],
    ],
    'earlyFailures': earlyFailures,
    'fragile': fragile,
    'pendingReport': pendingReport,
  };

  factory SessionRecord.fromJson(Map<String, dynamic> json) => SessionRecord(
    id: json['id'] as int,
    version: json['version'] as String,
    bootAt: json['bootAt'] as int?,
    presence: json['presence'] as String? ?? unknown,
    everFront: json['everFront'] == true,
    settled: json['settled'] == true,
    clean: json['clean'] == true,
    recovery: json['recovery'] == true,
    safeMode: json['safeMode'] == true,
    lastAt: json['lastAt'] as int?,
    active: [...(json['active'] as List? ?? const []).whereType<String>()],
    steps: [
      for (final step in json['steps'] as List? ?? const [])
        if (step is List &&
            step.length == 2 &&
            step[0] is int &&
            step[1] is String)
          (at: step[0] as int, name: step[1] as String),
    ],
    earlyFailures: json['earlyFailures'] as int? ?? 0,
    fragile: json['fragile'] == true,
    pendingReport: json['pendingReport'] as String?,
  );

  /// Null for a missing or damaged file. Power loss can cut a write short, and
  /// that must read as "nothing known", never as an error.
  static SessionRecord? tryRead(File file) {
    try {
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync());
      return json is Map<String, dynamic>
          ? SessionRecord.fromJson(json)
          : null;
    } catch (_) {
      return null;
    }
  }
}

/// An abnormal exit set aside by [SessionGuard.archivePreviousRun].
typedef SessionReport = ({SessionRecord record, int archivedAt, File log});

/// Records enough about each run for the next one to tell whether it crashed,
/// and what it was doing.
///
/// A native crash takes the process down before anything can be logged, so the
/// evidence has to be on disk already: the record is rewritten at each change.
/// Every entry point is a no-op until [start] succeeds and none of them throws.
abstract final class SessionGuard {
  static const _fileName = 'session.json';

  /// A run that ends abnormally sooner than this counts as an early failure.
  static const settleAfter = Duration(seconds: 60);

  /// Clock corrections move the computed boot time a little; a real reboot
  /// moves it by at least the time the device was up.
  static const _bootTolerance = Duration(minutes: 2);

  static const _maxSteps = 40;

  static const _maxReports = 5;

  static const _logTailBytes = 256 * 1024;

  static File? _file;
  static SessionRecord? _current;
  static final _depth = <String, int>{};
  static Timer? _settleTimer;
  static _LifecycleObserver? _observer;
  static Future<void>? _archive;
  static bool _offerRecovery = false;

  /// The record the previous run left, when there was a readable one.
  static SessionRecord? previous;

  static PreviousExit previousExit = PreviousExit.unknown;

  /// Chosen on the recovery page: this run leaves out the work the app would
  /// otherwise start by itself.
  static bool safeMode = false;

  static SessionRecord? get current => _current;

  /// The last runs kept failing right after launch.
  static bool get offerRecovery => _offerRecovery;

  /// Judges the previous run and starts recording this one.
  static Future<void> start({
    Directory? directory,
    String? version,
    int? Function() bootTime = bootTimeMillis,
    bool observeLifecycle = true,
  }) async {
    try {
      final dir = directory ?? await getApplicationSupportDirectory();
      final appVersion = version ?? await _appVersion();
      final file = File('${dir.path}/$_fileName');
      final prev = SessionRecord.tryRead(file);
      final boot = bootTime();
      final exit = classify(prev, version: appVersion, bootAt: boot);
      final record = SessionRecord(
        id: DateTime.now().millisecondsSinceEpoch,
        version: appVersion,
        bootAt: boot,
      );
      if (prev != null) _carryOver(prev, exit, record);
      _offerRecovery = record.earlyFailures >= (record.fragile ? 1 : 2);
      if (_offerRecovery) record.fragile = true;
      previous = prev;
      previousExit = exit;
      _file = file;
      _current = record;
      if (observeLifecycle) {
        final binding = WidgetsBinding.instance;
        _applyLifecycle(binding.lifecycleState);
        binding.addObserver(_observer = _LifecycleObserver());
      }
      step('launch');
    } catch (_) {
      _file = null;
      _current = null;
    }
  }

  static Future<String> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return 'unknown';
    }
  }

  @visibleForTesting
  static PreviousExit classify(
    SessionRecord? prev, {
    required String version,
    required int? bootAt,
  }) {
    if (prev == null) return PreviousExit.unknown;
    if (prev.clean) return PreviousExit.clean;
    if (prev.version != version) return PreviousExit.appUpdated;
    final prevBoot = prev.bootAt;
    if (prevBoot != null &&
        bootAt != null &&
        (bootAt - prevBoot).abs() > _bootTolerance.inMilliseconds) {
      return PreviousExit.deviceRestarted;
    }
    if (prev.recovery) return PreviousExit.background;
    return switch (prev.presence) {
      SessionRecord.front => PreviousExit.suspectedCrash,
      // Never reached the screen and never left it either: it died launching.
      SessionRecord.unknown when !prev.settled => PreviousExit.suspectedCrash,
      _ => PreviousExit.background,
    };
  }

  static void _carryOver(
    SessionRecord prev,
    PreviousExit exit,
    SessionRecord next,
  ) {
    // A new build starts with a clean slate.
    if (exit == PreviousExit.appUpdated) return;
    next.pendingReport = exit == PreviousExit.suspectedCrash
        ? '${prev.id}'
        : prev.pendingReport;
    // Neither says anything about whether the app itself is healthy.
    if (exit == PreviousExit.deviceRestarted || prev.recovery) {
      next.earlyFailures = prev.earlyFailures;
      next.fragile = prev.fragile;
      return;
    }
    final early = exit == PreviousExit.suspectedCrash && !prev.settled;
    next.earlyFailures = early ? prev.earlyFailures + 1 : 0;
    // An uneventful first minute outside safe mode is what clears it.
    next.fragile = prev.fragile && !(prev.settled && !prev.safeMode);
  }

  @visibleForTesting
  static String presenceOf(
    AppLifecycleState? state, {
    required bool everFront,
    required bool desktop,
  }) {
    if (state == AppLifecycleState.resumed) return SessionRecord.front;
    if (!everFront) {
      // Until the first resume the state describes the launch, not the user:
      // iOS reports inactive while starting and a desktop window stays hidden
      // until it is ready to show.
      if (state == null ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.detached ||
          (desktop && state == AppLifecycleState.hidden)) {
        return SessionRecord.unknown;
      }
    }
    return SessionRecord.away;
  }

  static void _applyLifecycle(AppLifecycleState? state) {
    final record = _current;
    if (record == null) return;
    if (state == AppLifecycleState.resumed) record.everFront = true;
    record.presence = presenceOf(
      state,
      everFront: record.everFront,
      desktop: App.isDesktop,
    );
  }

  @visibleForTesting
  static void onLifecycle(AppLifecycleState state) {
    final record = _current;
    if (record == null) return;
    final before = record.presence;
    _applyLifecycle(state);
    if (record.presence != before) _commit();
  }

  /// Call once the real app is on screen.
  static void appStarted() {
    if (_current == null) return;
    _settleTimer ??= Timer(settleAfter, () {
      _current?.settled = true;
      _commit();
    });
  }

  /// Notes a moment worth knowing about if this run ends badly.
  ///
  /// Each call writes the record, so keep it to occasional events and off any
  /// per-frame, per-page or per-request path.
  static void step(String name) {
    final record = _current;
    if (record == null) return;
    record.steps.add((at: DateTime.now().millisecondsSinceEpoch, name: name));
    if (record.steps.length > _maxSteps) record.steps.removeAt(0);
    _commit();
  }

  /// Marks [activity] as in progress until a matching [end]. Overlapping
  /// instances of one activity count as one.
  static void begin(String activity) {
    final record = _current;
    if (record == null) return;
    final depth = _depth[activity] = (_depth[activity] ?? 0) + 1;
    if (depth > 1) return;
    record.active.add(activity);
    step('$activity.start');
  }

  static void end(String activity) {
    final record = _current;
    final depth = _depth[activity];
    if (record == null || depth == null) return;
    if (depth > 1) {
      _depth[activity] = depth - 1;
      return;
    }
    _depth.remove(activity);
    record.active.remove(activity);
    step('$activity.end');
  }

  static Future<T> during<T>(String activity, Future<T> Function() body) async {
    begin(activity);
    try {
      return await body();
    } finally {
      end(activity);
    }
  }

  /// Call right before the app closes itself.
  static void markCleanExit() {
    if (_current == null) return;
    _commit(clean: true);
  }

  static void enterRecovery() {
    final record = _current;
    if (record == null) return;
    record.recovery = true;
    _commit();
  }

  static void leaveRecovery({required bool safe}) {
    safeMode = safe;
    final record = _current;
    if (record == null) return;
    record.recovery = false;
    record.safeMode = safe;
    // The recovery page already offered the report.
    record.pendingReport = null;
    step(safe ? 'recovery.safe' : 'recovery.normal');
  }

  /// The archived abnormal exit to tell the user about, at most once.
  static String? takePendingReport() {
    final record = _current;
    final id = record?.pendingReport;
    if (record == null || id == null) return null;
    record.pendingReport = null;
    _commit();
    return id;
  }

  static void _commit({bool clean = false}) {
    final file = _file;
    final record = _current;
    if (file == null || record == null) return;
    // Anything recorded after an exit was announced means it did not happen.
    record.clean = clean;
    record.lastAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final json = jsonEncode(record.toJson());
      // No fsync: the page cache outlives a crashed process, and a write cut
      // short by power loss reads back as "nothing known".
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(json);
      try {
        tmp.renameSync(file.path);
      } on FileSystemException {
        file.writeAsStringSync(json);
      }
    } catch (_) {
      // Losing a record costs a report, never the app.
    }
  }

  static Directory get _reportsDirectory =>
      Directory('${App.dataPath}/diagnostics');

  /// Sets aside the previous run's record and the end of its log when it ended
  /// abnormally, before the next launch rotates that log away. Needs the app
  /// paths, so call it after [App.init].
  static Future<void> archivePreviousRun() => _archive ??= _archivePreviousRun();

  static Future<void> _archivePreviousRun() async {
    final prev = previous;
    if (prev == null || previousExit != PreviousExit.suspectedCrash) return;
    try {
      // The file being written now must not be the one copied.
      Log.ensureOpen();
      final dir = _reportsDirectory..createSync(recursive: true);
      File('${dir.path}/${prev.id}.json').writeAsStringSync(
        jsonEncode({
          ...prev.toJson(),
          'archivedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      final log = Log.previousFile;
      if (await log.exists()) {
        final source = await log.open();
        try {
          final length = await source.length();
          final start = length > _logTailBytes ? length - _logTailBytes : 0;
          await source.setPosition(start);
          await File(
            '${dir.path}/${prev.id}.log',
          ).writeAsBytes(await source.read(length - start));
        } finally {
          await source.close();
        }
      }
      final stale = _reportIds(dir).skip(_maxReports);
      for (final id in stale) {
        for (final suffix in const ['json', 'log']) {
          final file = File('${dir.path}/$id.$suffix');
          if (file.existsSync()) file.deleteSync();
        }
      }
    } catch (e, s) {
      Log.error('Diagnostics', 'Failed to archive the previous run: $e', s);
    }
  }

  /// Newest first.
  static List<int> _reportIds(Directory dir) {
    if (!dir.existsSync()) return const [];
    final ids = <int>[];
    for (final entry in dir.listSync()) {
      final name = entry.uri.pathSegments.last;
      if (entry is! File || !name.endsWith('.json')) continue;
      final id = int.tryParse(name.substring(0, name.length - 5));
      if (id != null) ids.add(id);
    }
    return ids..sort((a, b) => b.compareTo(a));
  }

  /// Archived abnormal exits, newest first.
  static List<SessionReport> reports() {
    final reports = <SessionReport>[];
    try {
      final dir = _reportsDirectory;
      for (final id in _reportIds(dir)) {
        final json = jsonDecode(File('${dir.path}/$id.json').readAsStringSync());
        if (json is! Map<String, dynamic>) continue;
        reports.add((
          record: SessionRecord.fromJson(json),
          archivedAt: json['archivedAt'] as int? ?? id,
          log: File('${dir.path}/$id.log'),
        ));
      }
    } catch (_) {
      // An unreadable archive is simply not offered.
    }
    return reports;
  }

  @visibleForTesting
  static void reset() {
    _settleTimer?.cancel();
    _settleTimer = null;
    final observer = _observer;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    _observer = null;
    _file = null;
    _current = null;
    _depth.clear();
    _archive = null;
    _offerRecovery = false;
    previous = null;
    previousExit = PreviousExit.unknown;
    safeMode = false;
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      SessionGuard.onLifecycle(state);

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    SessionGuard.markCleanExit();
    return AppExitResponse.exit;
  }
}
