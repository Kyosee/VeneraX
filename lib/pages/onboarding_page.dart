import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/onboarding_restore.dart';
import 'package:venera/pages/onboarding_style.dart';
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
  int _step = 0;
  bool _busy = false;
  bool? _notifications;
  String? _restored;
  bool _connected = false;
  String? _error;
  String? _progress;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await OnboardingStore.instance.accept(agreementReadingLanguage());
      if (!mounted) return;
      setState(() => _step = 1);
      await widget.ensureServices();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      builder: (context) => OnboardingTheme(
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
      builder: (_) =>
          OnboardingTheme(builder: (_) => const OnboardingWebdavDialog()),
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
  Widget build(BuildContext context) => OnboardingTheme(
    builder: (context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) widget.onDeclined();
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 840;
              final colors = Theme.of(context).colorScheme;
              return Row(
                children: [
                  if (wide) _sidebar(context),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          padding: EdgeInsets.fromLTRB(
                            wide ? 30 : 22,
                            6,
                            wide ? 30 : 22,
                            6,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (_step > 0)
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(() => _step--),
                                  icon: const Icon(
                                    Icons.chevron_left,
                                    size: 17,
                                  ),
                                  label: Text('Back'.tl),
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    foregroundColor: colors.onSurfaceVariant,
                                    textStyle: const TextStyle(fontSize: 11),
                                  ),
                                )
                              else if (wide)
                                Text(
                                  'First-time setup'.tl,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                )
                              else
                                const Flexible(child: OnboardingBrand()),
                              AgreementLanguagePicker(
                                enabled: !_busy,
                                onChanged: () {
                                  if (mounted) setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                        if (!wide)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                            child: Row(
                              children: List.generate(
                                4,
                                (i) => Expanded(
                                  child: Container(
                                    height: 3,
                                    margin: EdgeInsets.only(
                                      right: i == 3 ? 0 : 5,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(2),
                                      color: i == _step
                                          ? colors.primary
                                          : i < _step
                                          ? colors.primary.withValues(
                                              alpha: .45,
                                            )
                                          : colors.outlineVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (_step == 0)
                          Expanded(
                            child: AgreementPanel(
                              key: ValueKey(appdata.settings['language']),
                              showLanguagePicker: false,
                              onAccepted: _accept,
                              onDeclined: widget.onDeclined,
                            ),
                          )
                        else ...[
                          Expanded(
                            child: SingleChildScrollView(
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 550,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      wide ? 30 : 27,
                                      8,
                                      wide ? 30 : 27,
                                      18,
                                    ),
                                    child: _stepContent(context, wide),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 550),
                              child: Container(
                                padding: EdgeInsets.fromLTRB(
                                  wide ? 30 : 25,
                                  12,
                                  wide ? 30 : 25,
                                  10,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: colors.outlineVariant,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (_busy)
                                      const LinearProgressIndicator(
                                        minHeight: 2,
                                      ),
                                    if (_progress != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: Text(
                                          _progress!.tl,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    if (_error != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: Text(
                                          _error!.tl,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: colors.error,
                                          ),
                                        ),
                                      ),
                                    FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : _step == 3
                                          ? _finish
                                          : () => setState(() => _step++),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              (_step == 3
                                                      ? (_restored != null
                                                            ? 'Finish setup'
                                                            : 'Skip and start reading')
                                                      : 'Continue')
                                                  .tl,
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                          const SizedBox(width: 9),
                                          const Icon(
                                            Icons.arrow_forward,
                                            size: 17,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_step == 2 && !App.isDesktop)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => setState(() => _step = 3),
                                        style: TextButton.styleFrom(
                                          foregroundColor:
                                              colors.onSurfaceVariant,
                                          textStyle: const TextStyle(
                                            fontSize: 11,
                                          ),
                                          minimumSize: const Size(0, 34),
                                        ),
                                        child: Text('Skip for now'.tl),
                                      )
                                    else
                                      Padding(
                                        padding: const EdgeInsets.only(top: 9),
                                        child: Text(
                                          'You can change these choices later in Settings.'
                                              .tl,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 11,
                                            height: 1.5,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _sidebar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 210,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(right: BorderSide(color: colors.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const OnboardingBrand(large: true),
                  Padding(
                    padding: const EdgeInsets.only(top: 13, bottom: 35),
                    child: Text(
                      'Your local reading companion'.tl,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (var i = 0; i < _setupSteps.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: i == _step ? colors.primaryContainer : null,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _step ? colors.primary : null,
                              border: Border.all(
                                color: i == _step
                                    ? colors.primary
                                    : colors.outlineVariant,
                              ),
                            ),
                            child: i < _step
                                ? Icon(
                                    Icons.check,
                                    size: 13,
                                    color: colors.onSurfaceVariant,
                                  )
                                : Text(
                                    (i + 1).toString(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: i == _step
                                          ? colors.onPrimary
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              (i == 2 && App.isDesktop
                                      ? 'Access information'
                                      : _setupSteps[i])
                                  .tl,
                              style: TextStyle(
                                fontSize: 12,
                                color: i == _step
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                                fontWeight: i == _step
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 20, 10, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Transform.rotate(
                          angle: -.157,
                          child: const Icon(
                            Icons.menu_book_outlined,
                            size: 50,
                            color: Color(0xff93a9d2),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'You can change these choices later in Settings.'.tl,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.9,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    'VeneraX',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurfaceVariant.withValues(alpha: .6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(
    BuildContext context,
    String title,
    String subtitle, {
    Widget? icon,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          if (icon != null) ...[
            SizedBox(
              width: 46,
              height: 40,
              child: FittedBox(
                child: SizedBox(width: 148, height: 121, child: icon),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title.tl,
              style: const TextStyle(
                fontSize: 22,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        subtitle.tl,
        style: TextStyle(
          fontSize: 13,
          height: 1.65,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 14),
    ],
  );

  Widget _note(BuildContext context, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        Icons.info_outline,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text.tl,
          style: TextStyle(
            fontSize: 11,
            height: 1.8,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  Widget _stepContent(BuildContext context, bool wide) {
    final colors = Theme.of(context).colorScheme;
    if (_step == 1) {
      final choices = [
        ('system', 'Follow system'.tl, ''),
        ('zh-CN', '简体中文', '简'),
        ('zh-TW', '繁體中文', '繁'),
        ('en-US', 'English', 'A'),
      ];
      Widget option(int index) {
        final choice = choices[index];
        final selected = appdata.settings['language'] == choice.$1;
        return Semantics(
          checked: selected,
          inMutuallyExclusiveGroup: true,
          child: Material(
            color: selected
                ? colors.primaryContainer
                : colors.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: selected ? colors.primary : colors.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _busy
                  ? null
                  : () async {
                      appdata.settings['language'] = choice.$1;
                      await appdata.saveData(false);
                      App.forceRebuild();
                      if (mounted) setState(() {});
                    },
              child: Container(
                constraints: BoxConstraints(minHeight: wide ? 76 : 66),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 33,
                      height: 33,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.surfaceContainerLowest
                            : colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: choice.$3.isEmpty
                          ? Icon(
                              Icons.smartphone_outlined,
                              size: 18,
                              color: colors.primary,
                            )
                          : Text(
                              choice.$3,
                              style: TextStyle(
                                fontSize: 15,
                                color: colors.primary,
                              ),
                            ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        choice.$2,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 17,
                      height: 17,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceContainerLowest,
                        border: Border.all(
                          color: selected
                              ? colors.primary
                              : colors.outlineVariant,
                          width: selected ? 5 : 1,
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

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(
            context,
            'Choose your app language',
            'You can change the app language later in Settings.',
            icon: const OnboardingLanguageArt(),
          ),
          if (wide)
            for (var row = 0; row < 2; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: option(row * 2)),
                    const SizedBox(width: 12),
                    Expanded(child: option(row * 2 + 1)),
                  ],
                ),
              )
          else
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: option(i),
              ),
          const SizedBox(height: 16),
          _note(
            context,
            'This changes VeneraX only. Your device language stays the same.',
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
            App.isDesktop ? 'Features and access' : 'Permission settings',
            App.isDesktop
                ? 'No permissions need to be granted here. These notes explain how the desktop app uses your network and files.'
                : 'Skip for now and grant access when needed.',
          ),
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(top: 8, bottom: 18),
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 28, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Only when you need it'.tl,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        (App.isDesktop
                                ? 'No permissions need to be granted here. These notes explain how the desktop app uses your network and files.'
                                : 'Optional permissions can wait. You can still continue.')
                            .tl,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.7,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _permission(
            context,
            Icons.language,
            'Network access',
            App.isDesktop
                ? 'Online reading, updates, and optional WebDAV sync use your network connection. Desktop systems usually do not ask for separate network permission; system or firewall settings may still restrict access.'
                : App.isIOS
                ? 'Network access is managed by iOS. Allow access in system settings when needed.'
                : 'Online reading, updates, and optional sync use your network connection. No separate network permission prompt is needed.',
          ),
          _permission(
            context,
            Icons.notifications_none,
            'Notifications',
            App.isDesktop
                ? 'This desktop version does not request system notification permission during setup. Download and background task progress is available in the app.'
                : 'Show progress and results for downloads and background tasks.',
            trailing: App.isAndroid || App.isOhos
                ? TextButton(
                    onPressed: _busy || _notifications == true ? null : _notify,
                    style: TextButton.styleFrom(
                      backgroundColor: colors.primaryContainer,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 34),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(fontSize: 11),
                    ),
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
                    style: const TextStyle(fontSize: 11),
                  ),
          ),
          _permission(
            context,
            Icons.folder_outlined,
            'File access',
            App.isDesktop
                ? 'Choose files or folders in the system picker when importing, exporting, or adding local content. Access to protected folders may still require system confirmation.'
                : 'Choose a file when importing a backup. Setup does not request access to all files.',
          ),
        ],
      );
    }
    final cards = [
      _restoreCard(
        context,
        wide,
        Icons.folder_open,
        'Import local backup',
        '.venera',
        _restoreLocal,
      ),
      _restoreCard(
        context,
        wide,
        Icons.cloud_download_outlined,
        'Restore from WebDAV',
        'Connect to your own server',
        _restoreWebdav,
        cloud: true,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(
          context,
          'Import or restore data',
          'Import an existing backup or skip to start with an empty library.',
          icon: const OnboardingRestoreArt(),
        ),
        if (_restored != null) ...[
          Icon(Icons.check_circle_outline, size: 64, color: colors.primary),
          const SizedBox(height: 20),
          Text(
            'Data restored. Your library is ready.'.tl,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
        ] else ...[
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 11),
                Expanded(child: cards[1]),
              ],
            )
          else ...[
            cards[0],
            const SizedBox(height: 11),
            cards[1],
          ],
          if (_connected)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'Connection saved. You can restore later in Settings.'.tl,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
        const SizedBox(height: 24),
        _note(
          context,
          'Import app data or configure WebDAV later in Settings › Sync & backup.',
        ),
        const SizedBox(height: 12),
        Text(
          'Restores favorites, history, sources, and settings. Downloaded comic images are not included in an app data backup.'
              .tl,
          style: TextStyle(
            fontSize: 11,
            height: 1.8,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _permission(
    BuildContext context,
    IconData icon,
    String title,
    String description, {
    Widget? trailing,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(icon, size: 21, color: colors.primary),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.tl,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  description.tl,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.85,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: trailing,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _restoreCard(
    BuildContext context,
    bool wide,
    IconData symbol,
    String title,
    String subtitle,
    VoidCallback onTap, {
    bool cloud = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final icon = Container(
      width: 43,
      height: 43,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cloud
            ? (colors.brightness == Brightness.dark
                  ? const Color(0xff213c37)
                  : const Color(0xffedf5f3))
            : colors.primaryContainer,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(
        symbol,
        size: 24,
        color: cloud ? const Color(0xff4e8b79) : colors.primary,
      ),
    );
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.tl,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          subtitle.tl,
          style: TextStyle(
            fontSize: 11,
            height: 1.7,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Material(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 19 : 16,
            vertical: 19,
          ),
          child: wide
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [icon, const SizedBox(height: 13), label],
                )
              : Row(
                  children: [
                    icon,
                    const SizedBox(width: 13),
                    Expanded(child: label),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
