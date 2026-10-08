part of 'settings_page.dart';

/// Shows where a value comes from without creating a second settings store.
class _SettingLabel extends StatelessWidget {
  const _SettingLabel({
    required this.title,
    required this.keys,
    required this.onReset,
    this.comicId,
    this.sourceKey,
    this.useDeviceSettings = false,
  });

  final String title;
  final List<String> keys;
  final String? comicId;
  final String? sourceKey;
  final bool useDeviceSettings;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final settings = appdata.settings;
    final comicScope = comicId != null && sourceKey != null;
    final ownValue = comicScope
        ? keys.any(
            (key) => settings.hasComicReaderSetting(comicId!, sourceKey!, key),
          )
        : useDeviceSettings && keys.any(settings.hasDeviceReaderSetting);
    final fromDevice =
        (comicScope || useDeviceSettings) &&
        keys.any(settings.hasDeviceReaderSetting);
    final showSource =
        comicScope ||
        useDeviceSettings ||
        context.findAncestorWidgetOfExactType<ReaderSettings>() != null;
    final source = ownValue
        ? (comicScope ? 'Current comic' : 'This device')
        : fromDevice
        ? 'Inherited from this device'
        : (comicScope || useDeviceSettings)
        ? 'Inherited from global'
        : 'Global settings';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, softWrap: true),
              if (showSource)
                Text(
                  source.tl,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (ownValue)
          IconButton(
            icon: const Icon(Icons.settings_backup_restore, size: 18),
            tooltip: 'Use inherited value'.tl,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              for (final key in keys) {
                if (comicScope) {
                  settings.resetComicReaderSetting(comicId!, sourceKey!, key);
                } else {
                  settings.resetDeviceReaderSetting(key);
                }
              }
              onReset();
              context
                  .findAncestorStateOfType<_ReaderSettingsState>()
                  ?.refreshSettings();
              appdata.saveData();
            },
          ),
      ],
    );
  }
}
