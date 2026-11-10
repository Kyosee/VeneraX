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
      DataSync().setSyncMode(WebdavSyncMode.manual, settle: false);
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
          DataSync().setSyncMode(WebdavSyncMode.realtime, settle: false);
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
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Restore from WebDAV'.tl,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      tooltip: 'Close'.tl,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'First restore downloads your remote data. It does not upload an empty library.'
                      .tl,
                  style: const TextStyle(height: 1.6),
                ),
                const SizedBox(height: 18),
                if (_backups == null) ...[
                  TextField(
                    controller: _url,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'WebDAV URL'.tl,
                      hintText: 'https://dav.example.com/backups/',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _user,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Username'.tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Password'.tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Text('Connect and check backups'.tl),
                  ),
                ] else ...[
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
  }
}
