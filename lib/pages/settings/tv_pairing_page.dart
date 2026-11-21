import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/auto_page_turning.dart';
import 'package:venera/pages/reader/reader.dart' show ReaderMode;
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/tv_pairing.dart';
import 'package:venera/utils/translations.dart';

class TvPairingPage extends StatefulWidget {
  const TvPairingPage({super.key});
  @override
  State<TvPairingPage> createState() => _TvPairingPageState();
}

class _TvPairingPageState extends State<TvPairingPage>
    with WidgetsBindingObserver {
  TvPairingSession? session;
  String? status;
  bool starting = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  void end() {
    generation++;
    session?.close();
    session = null;
    starting = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      end();
      setState(() => status = 'Pairing ended');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    end();
    super.dispose();
  }

  Future<void> start() async {
    end();
    final current = generation;
    setState(() {
      starting = true;
      status = null;
    });
    try {
      final next = await TvPairingSession.start(receive, (applied) {
        if (mounted && current == generation) {
          end();
          setState(() => status = applied ? 'Saved' : 'Pairing ended');
        }
      });
      if (!mounted || current != generation) {
        next.close();
        return;
      }
      setState(() {
        session = next;
        starting = false;
      });
    } catch (_) {
      if (mounted && current == generation) {
        setState(() {
          status = 'Connect both devices to the same Wi-Fi';
          starting = false;
        });
      }
    }
  }

  Future<bool> receive(Map<String, dynamic> data) async {
    final current = generation;
    final changes = <String, dynamic>{};
    final labels = <String>[];
    if (data['webdav'] case final Map<String, dynamic> json) {
      final config = SyncConfigPayload.fromJson(json);
      final uri = Uri.tryParse(config.url);
      if (uri == null ||
          !{'https', 'http'}.contains(uri.scheme) ||
          uri.host.isEmpty) {
        return false;
      }
      changes['webdav'] = [config.url, config.user, config.pass];
      changes['disableSyncFields'] = config.disableSyncFields;
      labels.add('${"WebDAV Sync".tl} · ${uri.host}');
    }
    final mode = ReaderMode.values
        .where((mode) => mode.key == data['readerMode'])
        .firstOrNull;
    if (mode != null) {
      changes['readerMode'] = mode.key;
      changes['adaptiveReading'] = false;
      labels.add('${"Reading mode".tl} · ${mode.label.tl}');
    }
    if (data['autoPageTurningInterval'] case final int seconds
        when seconds >= autoTurnIntervalMin && seconds <= autoTurnIntervalMax) {
      changes['autoPageTurningInterval'] = seconds;
      labels.add('${"Auto page turning interval".tl} · ${seconds}s');
    }
    if (changes.isEmpty || session?.active != true) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apply phone settings?'.tl),
        content: Text(labels.join('\n')),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Reject'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Accept'.tl),
          ),
        ],
      ),
    );
    if (accepted != true ||
        !mounted ||
        generation != current ||
        session?.active != true) {
      return false;
    }
    final previous = {
      for (final key in changes.keys) key: appdata.settings[key],
    };
    for (final entry in changes.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    try {
      await appdata.saveData(false);
    } catch (_) {
      for (final entry in previous.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      rethrow;
    }
    if (mounted) setState(() => status = 'Saved');
    return true;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Pair with phone'.tl)),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, size) => Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (session case final active?)
                QrImageView(
                  data: active.code.qr.toString(),
                  size: size.maxHeight.clamp(120, 236).toDouble(),
                  backgroundColor: Colors.white,
                ),
              const SizedBox(width: 24),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Connect both devices to the same Wi-Fi'.tl),
                      if (session != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '${"WebDAV Sync".tl} → ${"Data Sync".tl} → ${"Scan to Import".tl}\n'
                            '${"Scan with your phone within two minutes.".tl}',
                          ),
                        ),
                      if (status != null) Text(status!.tl),
                      if (starting)
                        const CircularProgressIndicator()
                      else
                        FilledButton(
                          autofocus: true,
                          onPressed: session == null
                              ? start
                              : () {
                                  end();
                                  setState(() => status = 'Pairing ended');
                                },
                          child: Text(
                            (session == null
                                    ? 'Pair with phone'
                                    : 'End pairing')
                                .tl,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> sendSettingsToTv(BuildContext context, TvPairingCode tv) async {
  final account = appdata.settings['webdav'];
  final available =
      account is List &&
      account.length == 3 &&
      account.every((v) => v is String) &&
      account.first != '';
  var sync = false;
  var reader = true;
  var mode = ReaderMode.fromKey(
    appdata.settings['readerMode'] as String? ?? '',
  );
  var seconds = autoTurnIntervalOf(appdata.settings['autoPageTurningInterval']);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: Text('Send settings to TV'.tl),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              value: reader,
              title: Text('Reading mode'.tl),
              onChanged: (v) => refresh(() => reader = v!),
            ),
            if (reader) ...[
              DropdownButton<ReaderMode>(
                value: mode,
                isExpanded: true,
                items: [
                  for (final item in ReaderMode.values)
                    DropdownMenuItem(value: item, child: Text(item.label.tl)),
                ],
                onChanged: (value) {
                  if (value != null) refresh(() => mode = value);
                },
              ),
              Text('${"Auto page turning interval".tl} · ${seconds}s'),
              Slider(
                value: seconds.toDouble(),
                min: autoTurnIntervalMin.toDouble(),
                max: autoTurnIntervalMax.toDouble(),
                divisions: autoTurnIntervalMax - autoTurnIntervalMin,
                label: '${seconds}s',
                onChanged: (value) => refresh(() => seconds = value.round()),
              ),
            ],
            CheckboxListTile(
              value: sync,
              title: Text('WebDAV Sync'.tl),
              onChanged: available ? (v) => refresh(() => sync = v!) : null,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: reader || sync ? () => Navigator.pop(ctx, true) : null,
            child: Text('Confirm'.tl),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final payload = <String, dynamic>{
    if (reader) ...{'readerMode': mode.key, 'autoPageTurningInterval': seconds},
    if (sync)
      'webdav': SyncConfigPayload(
        url: account[0],
        user: account[1],
        pass: account[2],
        autoSync: false,
        disableSyncFields: appdata.settings['disableSyncFields'] ?? '',
      ).toJson(),
  };
  context.showMessage(message: 'Waiting for confirmation'.tl);
  try {
    final ok = await tv.send(payload);
    if (context.mounted) {
      context.showMessage(message: (ok ? 'Saved' : 'Canceled').tl);
    }
  } catch (_) {
    if (context.mounted) {
      context.showMessage(
        message: 'Pairing failed. Scan a new code on the TV.'.tl,
      );
    }
  }
}
