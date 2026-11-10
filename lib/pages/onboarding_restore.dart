import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

/// Connection details stay in the form until the user saves or restores.
class OnboardingWebdavDialog extends StatefulWidget {
  const OnboardingWebdavDialog({super.key});
  @override
  State<OnboardingWebdavDialog> createState() => _OnboardingWebdavDialogState();
}

class _OnboardingWebdavDialogState extends State<OnboardingWebdavDialog> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  List<RemoteBackupInfo>? _backups;
  List<String>? _testedConfig;
  bool _busy = false;
  bool _autoSync = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    final config = [_url.text.trim(), _user.text.trim(), _password.text];
    final uri = Uri.tryParse(config[0]);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        config[1].isEmpty ||
        config[2].isEmpty) {
      setState(
        () => _error = 'Enter a valid WebDAV URL, username, and password.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await DataSync().listRemoteBackups(configuration: config);
      if (!mounted) return;
      if (result.error) {
        setState(
          () => _error =
              'Unable to connect. Check the address, credentials, and network, then try again.',
        );
      } else {
        setState(() {
          _backups = result.data;
          _testedConfig = config;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to connect. Check the address, credentials, and network, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({required bool restore}) async {
    if (_busy || _testedConfig == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Establish manual mode before credentials can enable any automatic work.
      appdata.implicitData['hasCompletedInitialSync'] = false;
      appdata.implicitData['webdavSetupRestorePending'] = true;
      appdata.implicitData.remove('webdavPendingPublish');
      await DataSync().setSyncMode(WebdavSyncMode.manual, settle: false);
      appdata.settings['webdav'] = List<String>.from(_testedConfig!);
      await appdata.saveData(false);
      if (restore) {
        final result = await DataSync().downloadData(userRestore: true);
        if (result.error) {
          if (mounted) {
            setState(
              () => _error =
                  'Restore failed. Your connection is saved; retry now or restore later in Settings.',
            );
          }
          return;
        }
        if (_autoSync) {
          await DataSync().setSyncMode(WebdavSyncMode.realtime, settle: false);
        }
      }
      if (mounted) Navigator.pop(context, restore ? 'webdav' : 'connected');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to finish this step. Please retry or skip it for now.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 600;
        Widget field(
          String label,
          TextEditingController controller, {
          bool secret = false,
          bool url = false,
        }) => Padding(
          padding: const EdgeInsets.only(top: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                label.tl,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 7),
              Semantics(
                label: label.tl,
                child: TextField(
                  controller: controller,
                  enabled: !_busy,
                  keyboardType: url ? TextInputType.url : null,
                  obscureText: secret,
                  autocorrect: false,
                  enableSuggestions: !secret,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: url ? 'https://dav.example.com/backups/' : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        return PopScope(
          canPop: !_busy,
          child: Dialog(
            alignment: wide ? Alignment.center : Alignment.bottomCenter,
            insetPadding: EdgeInsets.all(wide ? 28 : 0),
            backgroundColor: colors.surface,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: wide
                  ? BorderRadius.circular(20)
                  : const BorderRadius.vertical(top: Radius.circular(25)),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 540,
                maxHeight: wide ? size.maxHeight : size.maxHeight * .89,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  wide ? 26 : 23,
                  wide ? 23 : 8,
                  wide ? 26 : 23,
                  24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!wide) ...[
                      Center(
                        child: Container(
                          width: 32,
                          height: 4,
                          margin: const EdgeInsets.only(top: 2, bottom: 15),
                          decoration: BoxDecoration(
                            color: colors.outlineVariant,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Restore from WebDAV'.tl,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context),
                          tooltip: 'Close'.tl,
                          iconSize: 18,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'First restore downloads your remote data. It does not upload an empty library.'
                          .tl,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.9,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (_backups == null) ...[
                      field('WebDAV URL', _url, url: true),
                      field('Username', _user),
                      field('Password', _password, secret: true),
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _busy ? null : _connect,
                        child: Text('Connect and check backups'.tl),
                      ),
                    ] else ...[
                      const SizedBox(height: 18),
                      const Icon(Icons.cloud_done_outlined, size: 40),
                      const SizedBox(height: 14),
                      Text(
                        (_backups!.isEmpty
                                ? 'Connected. No app data backup was found.'
                                : 'Connection successful')
                            .tl,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (_backups!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          _backups!.first.fileName,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          value: _autoSync,
                          onChanged: _busy
                              ? null
                              : (value) =>
                                    setState(() => _autoSync = value ?? false),
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Enable automatic uploads after restoring'.tl,
                            style: const TextStyle(fontSize: 13, height: 1.8),
                          ),
                        ),
                        Text(
                          'Off by default. You can change this later in Settings.'
                              .tl,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _busy ? null : () => _save(restore: true),
                          child: Text('Restore latest backup'.tl),
                        ),
                      ],
                      TextButton(
                        onPressed: _busy ? null : () => _save(restore: false),
                        child: Text('Save connection for later'.tl),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _backups = null;
                                _testedConfig = null;
                              }),
                        child: Text('Edit connection'.tl),
                      ),
                    ],
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: LinearProgressIndicator(),
                      ),
                    if (_error != null)
                      Text(
                        _error!.tl,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
