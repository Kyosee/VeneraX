import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/onboarding_restore.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

const _setupSteps = [
  'Read and agree',
  'Language',
  'Permissions',
  'Restore data',
];

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.ensureServices,
    required this.onFinished,
    required this.onDeclined,
  });
  final Future<void> Function() ensureServices;
  final VoidCallback onFinished;
  final VoidCallback onDeclined;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late int _step = OnboardingStore.instance.state.needsAgreement() ? 0 : 1;
  bool _busy = false;
  bool? _notifications;
  String? _restored;
  bool _connected = false;
  String? _error;
  String? _progress;

  Future<void> _accept() async {
    await OnboardingStore.instance.accept(agreementReadingLanguage());
    if (!mounted) return;
    setState(() => _step = 1);
    await widget.ensureServices();
  }

  Future<void> _notify() async {
    if (_busy) return;
    setState(() => _busy = true);
    final granted = await BackgroundKeepAlive.instance
        .requestNotificationPermission();
    if (mounted) {
      setState(() {
        _notifications = granted;
        _busy = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.ensureServices();
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to finish this step. Please retry or skip it for now.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _restoreLocal() => _run(() async {
    if (!coreDataStoresReady) throw StateError('App initialization failed');
    final selection = await selectFile(ext: ['venera', 'picadata']);
    if (selection == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restore this backup?'.tl),
        content: Text(
          '${selection.name}\n\n${'Restores favorites, history, sources, and settings. Downloaded comic images are not included in an app data backup.'.tl}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Restore data'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    void progress(ImportPhase phase, String? message, int? bytes) {
      if (mounted) setState(() => _progress = message ?? 'Restoring data');
    }

    await DataSync().applyBackup(() async {
      if (selection.name.toLowerCase().endsWith('.picadata')) {
        await importPicaData(File(selection.path), onProgress: progress);
      } else {
        await importAppData(
          File(selection.path),
          userRestore: true,
          restoreWebdavConfig: false,
          onProgress: progress,
        );
      }
    });
    if (mounted) setState(() => _restored = 'local');
    App.forceRebuild();
  });

  Future<void> _restoreWebdav() => _run(() async {
    if (!coreDataStoresReady) throw StateError('App initialization failed');
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const OnboardingWebdavDialog(),
    );
    if (!mounted || result == null) return;
    setState(() {
      _connected = true;
      if (result == 'webdav') _restored = 'webdav';
    });
  });

  Future<void> _finish() => _run(() async {
    await OnboardingStore.instance.completeSetup();
    widget.onFinished();
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) widget.onDeclined();
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 840;
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_step > 1)
                            IconButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() => _step--),
                              tooltip: 'Back'.tl,
                              icon: const Icon(Icons.arrow_back),
                            ),
                          const Text(
                            'VeneraX',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      if (_step != 0)
                        AgreementLanguagePicker(
                          enabled: !_busy,
                          onChanged: () {
                            if (mounted) setState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: List.generate(
                      4,
                      (i) => Expanded(
                        child: Container(
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          color: i <= _step
                              ? colors.primary
                              : colors.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_step == 0)
                    Expanded(
                      child: AgreementPanel(
                        onAccepted: _accept,
                        onDeclined: widget.onDeclined,
                      ),
                    )
                  else ...[
                    Expanded(
                      child: SingleChildScrollView(
                        child: _stepContent(context),
                      ),
                    ),
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                    ],
                    if (_progress != null)
                      Text(_progress!.tl, textAlign: TextAlign.center),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _error!.tl,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : _step == 3
                          ? _finish
                          : () => setState(() => _step++),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          (_step == 3
                                  ? (_restored != null
                                        ? 'Finish setup'
                                        : 'Skip and start reading')
                                  : 'Continue')
                              .tl,
                        ),
                      ),
                    ),
                    if (_step == 2 && !App.isDesktop)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _step = 3),
                        child: Text('Skip for now'.tl),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'You can change these choices later in Settings.'.tl,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ],
              );
              return Row(
                children: [
                  if (wide)
                    Container(
                      width: 236,
                      color: colors.surfaceContainerLow,
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Image.asset(
                            'assets/app_icon.png',
                            width: 52,
                            height: 52,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.auto_stories,
                              size: 44,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            'VeneraX',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('Your local reading companion'.tl),
                          const SizedBox(height: 36),
                          for (var i = 0; i < 4; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Row(
                                children: [
                                  Icon(
                                    i < _step
                                        ? Icons.check_circle
                                        : i == _step
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: i <= _step
                                        ? colors.primary
                                        : colors.outline,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      (i == 2 && App.isDesktop
                                              ? 'Access information'
                                              : _setupSteps[i])
                                          .tl,
                                      style: TextStyle(
                                        color: i == _step
                                            ? colors.primary
                                            : colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          Text(
                            'First-time setup'.tl,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: Padding(
                          padding: EdgeInsets.all(wide ? 30 : 18),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title.tl,
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 10),
      Text(subtitle.tl, style: const TextStyle(height: 1.7)),
      const SizedBox(height: 26),
    ],
  );

  Widget _stepContent(BuildContext context) {
    if (_step == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            'Choose your app language',
            'This changes VeneraX only. Your device language stays the same.',
          ),
          const Icon(Icons.translate, size: 64),
          const SizedBox(height: 24),
          RadioGroup<String>(
            groupValue: appdata.settings['language'],
            onChanged: (value) async {
              if (value == null) return;
              appdata.settings['language'] = value;
              await appdata.saveData(false);
              App.forceRebuild();
              if (mounted) setState(() {});
            },
            child: Column(
              children: [
                for (final choice in [
                  ('system', 'Follow system'.tl),
                  ('zh-CN', '简体中文'),
                  ('zh-TW', '繁體中文'),
                  ('en-US', 'English'),
                ])
                  Card(
                    child: RadioListTile<String>(
                      value: choice.$1,
                      title: Text(choice.$2),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (_step == 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            App.isDesktop
                ? 'Features and access'
                : 'Permissions, when you need them',
            App.isDesktop
                ? 'No permissions need to be granted here. These notes explain how the desktop app uses your network and files.'
                : 'Optional permissions can be skipped. Only grant what you want to use.',
          ),
          _permission(
            Icons.public,
            'Network access',
            App.isDesktop
                ? 'Online reading, updates, and optional WebDAV sync use your network connection. Desktop systems usually do not ask for separate network permission; system or firewall settings may still restrict access.'
                : App.isIOS
                ? 'Network access is managed by iOS. Allow access in system settings when needed.'
                : 'Online reading, updates, and optional sync use your network connection. No separate network permission prompt is needed.',
          ),
          _permission(
            Icons.notifications_none,
            'Notifications',
            App.isDesktop
                ? 'This desktop version does not request system notification permission during setup. Download and background task progress is available in the app.'
                : 'Show progress and results for downloads and background tasks.',
            trailing: App.isAndroid || App.isOhos
                ? TextButton(
                    onPressed: _busy || _notifications == true ? null : _notify,
                    child: Text(
                      (_notifications == true
                              ? 'Enabled'
                              : _notifications == false
                              ? 'Not enabled · try again'
                              : 'Enable notifications')
                          .tl,
                    ),
                  )
                : App.isDesktop
                ? null
                : Text(
                    'No notification request on this platform'.tl,
                    style: const TextStyle(fontSize: 12),
                  ),
          ),
          _permission(
            Icons.folder_outlined,
            'File access',
            App.isDesktop
                ? 'Choose files or folders in the system picker when importing, exporting, or adding local content. Access to protected folders may still require system confirmation.'
                : 'Choose a file when importing a backup. Setup does not request access to all files.',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(
          context,
          'Bring your library with you',
          'Import a local backup, connect to WebDAV, or start with an empty library.',
        ),
        if (_restored != null) ...[
          const Icon(Icons.check_circle_outline, size: 64),
          const SizedBox(height: 20),
          Text(
            'Data restored. Your library is ready.'.tl,
            textAlign: TextAlign.center,
          ),
        ] else ...[
          _restoreCard(
            Icons.folder_open,
            'Import local backup',
            '.venera / .picadata',
            _restoreLocal,
          ),
          const SizedBox(height: 12),
          _restoreCard(
            Icons.cloud_download_outlined,
            'Restore from WebDAV',
            'Connect to your own server',
            _restoreWebdav,
          ),
          if (_connected)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'Connection saved. You can restore later in Settings.'.tl,
              ),
            ),
        ],
        const SizedBox(height: 24),
        Text(
          'Restores favorites, history, sources, and settings. Downloaded comic images are not included in an app data backup.'
              .tl,
          style: const TextStyle(fontSize: 12, height: 1.7),
        ),
      ],
    );
  }

  Widget _permission(
    IconData icon,
    String title,
    String description, {
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 28),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.tl,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(description.tl, style: const TextStyle(height: 1.6)),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ],
    ),
  );

  Widget _restoreCard(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Card(
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      enabled: !_busy,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      leading: Icon(icon, size: 30),
      title: Text(title.tl),
      subtitle: Text(subtitle.tl),
      trailing: const Icon(Icons.chevron_right),
      onTap: _busy ? null : onTap,
    ),
  );
}
