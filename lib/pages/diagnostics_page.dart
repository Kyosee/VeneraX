import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/diagnostics.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/session_guard.dart';
import 'package:venera/pages/settings/settings_page.dart'
    show kUpdateRepoName, kUpdateRepoOwner;
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Tells the user, once, that the previous run ended abnormally and where its
/// report is. A toast rather than a dialog: the verdict is an inference, and a
/// wrong one must cost no more than a glance.
void showAbnormalExitNotice() {
  Future.delayed(const Duration(seconds: 2), () {
    final context = App.rootNavigatorKey.currentContext;
    if (context == null) return;
    final id = SessionGuard.takePendingReport();
    if (id == null) return;
    showToast(
      context: context,
      message: 'The last run did not end normally'.tl,
      seconds: 10,
      trailing: TextButton(
        onPressed: () =>
            App.rootContext.to(() => DiagnosticsPage(reportId: id)),
        child: Text('View'.tl),
      ),
    );
  });
}

/// The redacted report for an abnormal exit or for the current run, shown in
/// full before the user copies, saves or posts it.
///
/// Also opened from the recovery page, before the app's stores exist: it must
/// not read settings or data.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.reportId});

  /// The abnormal exit to open on. Defaults to the newest one, or to the
  /// current run when none is on record.
  final String? reportId;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late final List<SessionReport> _reports = SessionGuard.reports();

  /// Null for the current run.
  SessionReport? _selected;

  String? _text;

  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _selected =
        _reports
            .where((report) => '${report.record.id}' == widget.reportId)
            .firstOrNull ??
        _reports.firstOrNull;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final selected = _selected;
    String text;
    try {
      Log.flush();
      text = selected == null
          ? await DiagnosticsReport.forCurrentRun()
          : await DiagnosticsReport.forArchived(selected);
    } catch (e, s) {
      Log.error('Diagnostics', e, s);
      text = '${'Failed to build the report'.tl}\n$e';
    }
    if (!mounted || generation != _generation) return;
    setState(() => _text = text);
  }

  void _select(SessionReport? report) {
    if (report == _selected) return;
    setState(() {
      _selected = report;
      _text = null;
    });
    _load();
  }

  String get _fileName {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'diagnostics-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    context.showMessage(message: 'Copied'.tl);
  }

  void _save(String text) {
    saveFile(data: utf8.encode(text), filename: _fileName);
  }

  void _share(String text) {
    Share.shareFile(
      data: utf8.encode(text),
      filename: _fileName,
      mime: 'text/plain',
    );
  }

  /// Opens the bug form with what can be filled in for the user. The report
  /// itself is too long for an address, so it travels on the clipboard.
  Future<void> _report(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      context.showMessage(
        message: 'Report copied. Paste it into the logs field.'.tl,
      );
    }
    final platform = App.isOhos
        ? 'HarmonyOS'
        : App.isAndroid
        ? 'Android'
        : App.isIOS
        ? 'iOS'
        : App.isWindows
        ? 'Windows'
        : App.isMacOS
        ? 'macOS'
        : 'linux';
    final uri = Uri.https(
      'github.com',
      '/$kUpdateRepoOwner/$kUpdateRepoName/issues/new',
      {
        'template': 'bug.yaml',
        'bugType': 'Crash',
        'version': _selected?.record.version ?? App.version,
        'platform': platform,
      },
    );
    await launchUrlString(uri.toString());
  }

  static String _time(int milliseconds) {
    final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  Widget _buildRuns() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final report in _reports)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: const Icon(Icons.warning_amber_rounded, size: 18),
                label: Text(_time(report.record.lastAt)),
                selected: report == _selected,
                onSelected: (_) => _select(report),
              ),
            ),
          ChoiceChip(
            label: Text('This run'.tl),
            selected: _selected == null,
            onSelected: (_) => _select(null),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Scaffold(
      appBar: Appbar(title: Text('Diagnostic report'.tl)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Bug reports are public. Addresses, accounts and local paths '
                      'are hidden automatically, but a title inside an error '
                      'message cannot be recognized. Read the text below before '
                      'you post it.'
                  .tl,
              style: TextStyle(
                fontSize: 13,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_reports.isNotEmpty) _buildRuns(),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: text == null
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        text,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: text == null ? null : () => _copy(text),
                    child: Text('Copy'.tl),
                  ),
                  OutlinedButton(
                    onPressed: text == null ? null : () => _save(text),
                    child: Text('Save'.tl),
                  ),
                  if (App.isAndroid || App.isIOS)
                    OutlinedButton(
                      onPressed: text == null ? null : () => _share(text),
                      child: Text('Share'.tl),
                    ),
                  FilledButton(
                    onPressed: text == null ? null : () => _report(text),
                    child: Text('Report a problem'.tl),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
