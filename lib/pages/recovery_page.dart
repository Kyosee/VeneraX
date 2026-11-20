import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/session_guard.dart';
import 'package:venera/pages/diagnostics_page.dart';
import 'package:venera/utils/translations.dart';
import 'package:window_manager/window_manager.dart';

/// Stands in for the app when the last runs kept ending right after launch,
/// and returns once the user has decided how to go on.
///
/// Whatever keeps failing has not run yet, and nothing here may start it: no
/// stores, no settings, no sync.
Future<void> runRecovery() async {
  SessionGuard.enterRecovery();
  final choice = Completer<bool>();
  try {
    await AppTranslation.init();
  } catch (_) {
    // English is better than no way out.
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      builder: (context, child) => OverlayWidget(child!),
      home: RecoveryPage(
        onChoice: (safe) {
          if (!choice.isCompleted) choice.complete(safe);
        },
      ),
    ),
  );
  if (App.isDesktop) {
    // The window stays hidden until the app proper has placed it.
    try {
      await windowManager.ensureInitialized();
      await windowManager.show();
    } catch (_) {}
  }
  SessionGuard.leaveRecovery(safe: await choice.future);
}

/// Sets the failed run's record and log aside so the report can show them.
Future<void> _prepareReport() async {
  try {
    if (!App.isInitialized) await App.init();
    await SessionGuard.archivePreviousRun();
  } catch (_) {
    // The report then covers this run only.
  }
}

class RecoveryPage extends StatefulWidget {
  const RecoveryPage({
    super.key,
    required this.onChoice,
    this.prepareReport = _prepareReport,
  });

  /// Called once, with whether to start in safe mode.
  final void Function(bool safe) onChoice;

  final Future<void> Function() prepareReport;

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  late final Future<void> _report;

  bool _starting = false;

  @override
  void initState() {
    super.initState();
    // Now rather than on demand: closing this page must not lose the record.
    _report = widget.prepareReport();
  }

  void _start(bool safe) {
    setState(() => _starting = true);
    widget.onChoice(safe);
  }

  Future<void> _export() async {
    await _report;
    if (!mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DiagnosticsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.healing_outlined,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'The app closed right after starting, more than once'.tl,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Safe mode skips automatic sync, update checks and '
                            'resuming unfinished tasks for this run. Your data '
                            'is not changed.'
                        .tl,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_starting)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    FilledButton(
                      onPressed: () => _start(true),
                      child: Text('Start in safe mode'.tl),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => _start(false),
                      child: Text('Start normally'.tl),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _export,
                      child: Text('Export diagnostic report'.tl),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
