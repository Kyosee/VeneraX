part of 'settings_page.dart';

/// Keeps settings routes inside the reader's sidebar.
class ReaderSettingsPanel extends StatefulWidget {
  const ReaderSettingsPanel({required this.child, super.key});
  final ReaderSettings child;

  @override
  State<ReaderSettingsPanel> createState() => _ReaderSettingsPanelState();
}

class _ReaderSettingsPanelState extends State<ReaderSettingsPanel> {
  final _navigator = GlobalKey<NavigatorState>();

  void close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler(
    onPopWithResult: (_) => _navigator.currentState!.pop(),
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => widget.child),
    ),
  );
}

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.translationOnly = false,
    this.showSearch = false,
    this.currentPageImage,
    this.section,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;
  final bool translationOnly;
  final bool showSearch;
  final String? section;

  /// Caller-owned copy of the page open in the reader, for the image
  /// enhancement preview. Null outside the reader.
  final ImageInfo? Function()? currentPageImage;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  _SettingsSearchEntry? _searchTarget;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // The startup probe normally finished long ago; if not, show the ripple
    // rows as soon as it does.
    if (!EinkPanel.rippleProbed) {
      EinkPanel.probeRipple().then((_) => refreshSettings());
    }
  }

  void _setTranslationPreset(String value) {
    var preset = TranslationPerformanceConfig.fromSetting(value);
    TranslationPerformanceConfig.apply(preset);
    setState(() {});
  }

  void _markTranslationCustom(String key) {
    TranslationPerformanceConfig.markCustom(save: false);
    setState(() {});
    widget.onChanged?.call(key);
  }

  /// The value of [key] in this page's scope: the comic's own when opened for a
  /// specific comic with per-comic settings on, then this device's, else global.
  /// Used by conditional rows so they follow the same value the reader reads.
  dynamic _effectiveSetting(String key) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    if (comicId != null && sourceKey != null) {
      return appdata.settings.getReaderSetting(comicId, sourceKey, key);
    }
    return appdata.settings.getDeviceReaderSetting(key);
  }

  bool _isChapterCommentsAtEndSupported() {
    final mode = _effectiveSetting('readerMode');
    return _effectiveSetting('showChapterComments') == true &&
        (mode == 'galleryLeftToRight' || mode == 'galleryRightToLeft');
  }

  void refreshSettings() {
    if (mounted) setState(() {});
  }

  /// The source language that applies in this page's scope: the comic's own when
  /// opened for a specific comic with per-comic settings on, otherwise the
  /// device default. Drives the "models ready" summary and the test-translation
  /// target so both describe what this comic will actually use.
  TranslationConfig _effectiveTranslationConfig() {
    var comicId = widget.comicId;
    if (comicId == null) {
      return TranslationConfig.device;
    }
    return TranslationConfig.of(comicId, widget.comicSource);
  }

  String _effectiveSourceLang() => _effectiveTranslationConfig().sourceLang;

  String _effectiveTargetLang() => _effectiveTranslationConfig().targetLang;

  /// Built-in targets, then the user's own. A selected code that is no longer
  /// listed (a removed custom language) stays visible under its raw code
  /// instead of showing as blank.
  Map<String, String> _targetLanguageOptions() {
    var options = {
      for (var e in TranslationTargets.builtIn.entries) e.key: e.value.label.tl,
      for (var e in TranslationTargets.custom) e.code: e.name,
    };
    var current = _effectiveTargetLang();
    options.putIfAbsent(current, () => current);
    return options;
  }

  /// Auto, built-in sources, then the user's own; a removed custom language
  /// still selected shows under its code.
  Map<String, String> _sourceLanguageOptions() {
    var options = {
      'auto': "Auto detect".tl,
      for (var e in TranslationSources.builtIn.entries) e.key: e.value.tl,
      for (var e in TranslationSources.custom) e.code: e.name,
    };
    var current = _effectiveSourceLang();
    options.putIfAbsent(current, () => current);
    return options;
  }

  int _customLanguageCount() =>
      TranslationSources.custom.length + TranslationTargets.custom.length;

  /// Summary line for the LLM-providers entry: the active provider's name (or
  /// its URL when unnamed), how many others are configured, or "Not configured".
  String _activeProviderSubtitle() {
    var active = LlmProviderStore.active;
    if (active == null) {
      return "Not configured".tl;
    }
    var label = active.name.isNotEmpty
        ? active.name
        : (active.isPublicFree
              ? "Google Translate (no key)".tl
              : (active.url.isNotEmpty ? active.url : "Unnamed provider".tl));
    var count = LlmProviderStore.providers.length;
    if (count > 1) {
      label += " (${"@count configured".tlParams({'count': count})})";
    }
    return label;
  }

  /// A plain-language explainer of what AI translation does, how to set it up,
  /// and how to use it — so users don't have to guess from the field labels.
  /// The short version stays here; the full walkthrough lives in the guide.
  void _showTranslationHelp() {
    Widget section(String title, String body) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ts.bold.s14),
          const SizedBox(height: 4),
          Text(body, style: ts.s14),
          const SizedBox(height: 16),
        ],
      );
    }

    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "AI Translation help".tl,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              section(
                "What it does".tl,
                "Reads the text in comic pages and overlays a translation right on the image, keeping the original artwork. Text is found and recognized on your device; the recognized lines are then sent to an AI model to translate."
                    .tl,
              ),
              section(
                "One-time setup".tl,
                "1. Open LLM providers and add one. Pick \"Google Translate\" to use its free endpoint with nothing to fill in, or \"AI model\" to enter the API URL, API Key and Model of any OpenAI-compatible service. Add several and switch between them anytime.\n2. Tap Test translation to confirm it replies.\n3. Open Translation models and download the models for your source language (needed for on-device text recognition)."
                    .tl,
              ),
              section(
                "How to use".tl,
                "Translation is turned on per comic, not globally, because it uses your API tokens. Open a comic, turn on \"Translate pages while reading\", and pages translate as you read. To translate ahead of time, use Pre-translate from the comic's menu."
                    .tl,
              ),
              section(
                "Target language".tl,
                "Language not in the list? Open Custom languages, tap + next to Target languages and enter a name (what the AI model translates into, e.g. ไทย) and a code (used by Google Translate and scripts, e.g. th). It then appears in Target language. Removing it later keeps the pages already translated."
                    .tl,
              ),
              section(
                "Good to know".tl,
                "Results are saved, so a page is only translated once. Use Clear translation results to free up space. Source language can stay on Auto detect if you're unsure."
                    .tl,
              ),
            ],
          ),
        ),
        actions: [
          Button.text(
            onPressed: () {
              context.pop();
              GuidePage.open(App.rootContext, anchor: GuideAnchor.translation);
            },
            child: Text("Full guide".tl),
          ),
          Button.filled(onPressed: context.pop, child: Text("OK".tl)),
        ],
      ),
    );
  }

  /// Runs a sample string through the full translate path so the user can
  /// confirm the endpoint/key/model actually work — and return usable output —
  /// without opening a comic to find out. Shows the returned translation on
  /// success, or the error on failure.
  void _testTranslation() async {
    if (!LlmTranslator.isConfigured) {
      context.showMessage(message: "Add a translation service first".tl);
      return;
    }
    var controller = showLoadingDialog(
      context,
      message: "Testing translation".tl,
      allowCancel: false,
    );
    String? result;
    String? error;
    try {
      var res = await LlmTranslator.translateBatch(const [
        'こんにちは',
        'ありがとう',
      ], _effectiveTargetLang());
      result = res.texts.where((t) => t.isNotEmpty).join(' / ');
      if (result.isEmpty) {
        error = "The model returned an empty response".tl;
        result = null;
      }
    } catch (e) {
      error = e.toString();
    }
    controller.close();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: error == null
            ? "Translation succeeded".tl
            : "Translation failed".tl,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(error ?? "こんにちは / ありがとう →\n$result", style: ts.s14),
        ),
        actions: [
          FilledButton(onPressed: () => context.pop(), child: Text("OK".tl)),
        ],
      ),
    );
  }

  void _writeEffectiveSetting(String key, dynamic value) {
    appdata.settings.setEffectiveReaderSetting(
      widget.comicId,
      widget.comicSource,
      key,
      value,
    );
  }

  void _onShowChapterCommentsChanged() {
    if (_effectiveSetting('showChapterComments') != true) {
      _writeEffectiveSetting('showChapterCommentsAtEnd', false);
      widget.onChanged?.call('showChapterCommentsAtEnd');
    }
    refreshSettings();
    appdata.saveData();
    widget.onChanged?.call('showChapterComments');
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showSearch) return _buildSettings(context);
    final target = _searchTarget;
    final panel = context.findAncestorStateOfType<_ReaderSettingsPanelState>();
    return Column(
      children: [
        Appbar(
          title: Text('Reading settings'.tl),
          leading: panel != null
              ? IconButton(
                  tooltip: 'Back'.tl,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: panel.close,
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: AppSearchField(
            controller: _searchController,
            hintText: 'Search settings'.tl,
            onChanged: (query) => setState(() {
              _searchQuery = query;
              _searchTarget = null;
            }),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: _searchQuery.trim().isNotEmpty
                ? _buildSettingsSearchResults(
                    context,
                    _searchQuery,
                    (entry) {
                      FocusScope.of(context).unfocus();
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                        _searchTarget = entry;
                      });
                    },
                    entries: [
                      if (widget.comicId != null && widget.comicSource != null)
                        const _SettingsSearchEntry(
                          'Enable comic specific settings',
                          1,
                        ),
                      ..._settingsSearchIndex.where(
                        (entry) =>
                            (entry.category == 1 &&
                                (widget.comicId == null ||
                                    entry.title !=
                                        'Enable device specific settings')) ||
                            entry.title == 'AI Translation',
                      ),
                    ],
                  )
                : target == null
                ? Builder(builder: _buildSettings)
                : _SettingsDestination(
                    title: target.targetTitle,
                    fallback: target.fallbackTitle,
                    child: Builder(builder: _buildSettings),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildSettings(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";
    final isEnabledSpecificSettings =
        comicId != null &&
        appdata.settings.isComicSpecificSettingsEnabled(comicId, sourceKey);
    final useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();
    final selectedSection =
        widget.section ??
        _settingsSectionForTitle(
          widget.translationOnly ? 8 : 1,
          _SettingsJumpScope.targetOf(context),
        );
    final readingMode = SelectSetting(
      title: "Reading mode".tl,
      settingKey: "readerMode",
      optionTranslation: {
        "galleryLeftToRight": "Gallery (Left to Right)".tl,
        "galleryRightToLeft": "Gallery (Right to Left)".tl,
        "galleryTopToBottom": "Gallery (Top to Bottom)".tl,
        "continuousLeftToRight": "Continuous (Left to Right)".tl,
        "continuousRightToLeft": "Continuous (Right to Left)".tl,
        "continuousTopToBottom": "Continuous (Top to Bottom)".tl,
      },
      onChanged: () {
        setState(() {});
        var readerMode = _effectiveSetting('readerMode');
        if (readerMode?.toLowerCase().startsWith('continuous') ?? false) {
          _writeEffectiveSetting('readerScreenPicNumberForLandscape', 1);
          widget.onChanged?.call('readerScreenPicNumberForLandscape');
          _writeEffectiveSetting('readerScreenPicNumberForPortrait', 1);
          widget.onChanged?.call('readerScreenPicNumberForPortrait');
        }
        widget.onChanged?.call("readerMode");
      },
      comicId: isEnabledSpecificSettings ? widget.comicId : null,
      comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
      useDeviceSettings: useDeviceSpecificSettings,
    );
    return _SettingsPageView(
      title: widget.translationOnly ? 'AI Translation' : 'Reading settings',
      description: widget.translationOnly
          ? 'Translation services, languages, models and performance'
          : 'Page layout, gestures and reading display',
      section: selectedSection,
      showHeader: !widget.showSearch,
      intro: Material(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            SwitchListTile(
              dense: true,
              title: Text(
                (comicId != null
                        ? 'Enable comic specific settings'
                        : 'Enable device specific settings')
                    .tl,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                (isEnabledSpecificSettings
                        ? 'Editing settings for this comic'
                        : useDeviceSpecificSettings
                        ? 'Editing settings for this device'
                        : 'Editing global settings')
                    .tl,
                style: const TextStyle(fontSize: 12),
              ),
              value: comicId != null
                  ? isEnabledSpecificSettings
                  : useDeviceSpecificSettings,
              onChanged: (enabled) {
                setState(() {
                  if (comicId != null && sourceKey != null) {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      enabled,
                    );
                  } else {
                    appdata.settings.setEnabledDeviceSpecificSettings(enabled);
                  }
                });
                appdata.saveData();
                widget.onChanged?.call('enabled');
              },
            ),
            if (isEnabledSpecificSettings ||
                (comicId == null && useDeviceSpecificSettings))
              TextButton.icon(
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(
                  (isEnabledSpecificSettings
                          ? 'Clear specific reader settings for this comic'
                          : 'Clear specific reader settings for this device')
                      .tl,
                ),
                onPressed: () {
                  setState(() {
                    if (isEnabledSpecificSettings) {
                      appdata.settings.resetComicReaderSettings(key);
                    } else {
                      appdata.settings.resetDeviceReaderSettings();
                    }
                  });
                  appdata.saveData();
                  widget.onChanged?.call('enabled');
                },
              ),
          ],
        ),
      ),
      onOpenSection: (section) async {
        await context.to(
          () => ReaderSettings(
            section: section,
            translationOnly: widget.translationOnly,
            comicId: widget.comicId,
            comicSource: widget.comicSource,
            onChanged: widget.onChanged,
            currentPageImage: widget.currentPageImage,
          ),
        );
        refreshSettings();
      },
      sections: [
        if (!widget.translationOnly) ...[
          _SettingsSection(
            title: 'Reading mode',
            icon: Icons.menu_book_outlined,
            common: true,
            children: [
              if (selectedSection == null)
                _buildReadingModes(readingMode)
              else
                readingMode,
              _SwitchSetting(
                title: "Page animation".tl,
                settingKey: "enablePageAnimation",
                onChanged: () {
                  widget.onChanged?.call("enablePageAnimation");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: "Seamless chapter reading".tl,
                subtitle: "Join chapters in continuous reading modes".tl,
                settingKey: "enableContinuousChapterReading",
                onChanged: () {
                  widget.onChanged?.call("enableContinuousChapterReading");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              if (App.isDesktop)
                _SwitchSetting(
                  title: 'Enter fullscreen when reading starts'.tl,
                  settingKey: 'autoFullscreenOnRead',
                  onChanged: () {
                    widget.onChanged?.call('autoFullscreenOnRead');
                  },
                ),
              _SwitchSetting(
                title: 'Remove from read later when reading starts'.tl,
                settingKey: 'autoRemoveFromReadLater',
                onChanged: () {
                  widget.onChanged?.call('autoRemoveFromReadLater');
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'Page layout',
            icon: Icons.auto_stories_outlined,
            subtitle:
                '${readingMode.optionTranslation[_effectiveSetting('readerMode')]} · ${'Page arrangement, spacing and wide pages'.tl}',
            children: [
              readingMode,
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'gallery',
                  ) ??
                  false)
                _SliderSetting(
                  title:
                      "The number of pic in screen for landscape (Only Gallery Mode)"
                          .tl,
                  settingsIndex: "readerScreenPicNumberForLandscape",
                  interval: 1,
                  min: 1,
                  max: 5,
                  onChanged: () {
                    setState(() {});
                    widget.onChanged?.call("readerScreenPicNumberForLandscape");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'gallery',
                  ) ??
                  false)
                _SliderSetting(
                  title:
                      "The number of pic in screen for portrait (Only Gallery Mode)"
                          .tl,
                  settingsIndex: "readerScreenPicNumberForPortrait",
                  interval: 1,
                  min: 1,
                  max: 5,
                  onChanged: () {
                    widget.onChanged?.call("readerScreenPicNumberForPortrait");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if (((_effectiveSetting('readerMode') as String?)?.startsWith(
                            'gallery',
                          ) ??
                          false) &&
                      ((_effectiveSetting('readerScreenPicNumberForLandscape')
                                  as int?) ??
                              1) >
                          1 ||
                  ((_effectiveSetting('readerScreenPicNumberForPortrait')
                              as int?) ??
                          1) >
                      1)
                _SwitchSetting(
                  title: "Show single image on first page".tl,
                  settingKey: "showSingleImageOnFirstPage",
                  onChanged: () {
                    widget.onChanged?.call("showSingleImageOnFirstPage");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'gallery',
                  ) ??
                  false)
                _SwitchSetting(
                  title: "Fill screen".tl,
                  subtitle:
                      "Crop image to fill screen instead of letterboxing".tl,
                  settingKey: "galleryFillScreen",
                  onChanged: () {
                    widget.onChanged?.call("galleryFillScreen");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'gallery',
                  ) ??
                  false)
                SelectSetting(
                  title: "Split wide pages".tl,
                  settingKey: "splitWidePages",
                  optionTranslation: {
                    "off": "Off".tl,
                    "rightFirst": "Right half first".tl,
                    "leftFirst": "Left half first".tl,
                  },
                  help:
                      "Cuts a landscape page, usually two pages scanned as one, down the middle and shows each half on a screen of its own. Only applies with one image per screen. For comics read right to left, choose \"Right half first\"."
                          .tl,
                  onChanged: () {
                    widget.onChanged?.call("splitWidePages");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?) ==
                  'continuousTopToBottom')
                _SwitchSetting(
                  title: "Center page after turning".tl,
                  subtitle:
                      "Center a short page vertically instead of pinning it to the top"
                          .tl,
                  settingKey: "readerCenterPageOnTurn",
                  onChanged: () {
                    widget.onChanged?.call("readerCenterPageOnTurn");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?) ==
                  'continuousTopToBottom')
                SelectSetting(
                  title: "Split wide pages".tl,
                  settingKey: "splitWidePages",
                  optionTranslation: {
                    "off": "Off".tl,
                    "rightFirst": "Right half on top".tl,
                    "leftFirst": "Left half on top".tl,
                  },
                  help:
                      "Cuts a landscape page, usually two pages scanned as one, down the middle and stacks the halves so each fills the screen width. For comics read right to left, choose \"Right half on top\"."
                          .tl,
                  onChanged: () {
                    widget.onChanged?.call("splitWidePages");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'continuous',
                  ) ??
                  false)
                _SliderSetting(
                  title: "Spacing between pages".tl,
                  settingsIndex: "readerPageSpacing",
                  interval: 2,
                  min: 0,
                  max: 50,
                  onChanged: () {
                    widget.onChanged?.call("readerPageSpacing");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
            ],
          ),
          _SettingsSection(
            title: 'Auto turning & preload',
            icon: Icons.timer_outlined,
            subtitle: 'Automatic page turning, scrolling and image preloading',
            children: [
              readingMode,
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'continuous',
                  ) ??
                  false)
                SelectSetting(
                  title: "Auto page turning mode".tl,
                  settingKey: "autoPageTurningMode",
                  optionTranslation: {
                    autoTurnModePage: "Turn pages".tl,
                    autoTurnModeScroll: "Scroll".tl,
                  },
                  onChanged: () {
                    setState(() {});
                    widget.onChanged?.call("autoPageTurningMode");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              // In scroll mode the interval gives way to a speed.
              if (autoTurnScrolls(
                (_effectiveSetting('readerMode') as String?) ?? '',
                _effectiveSetting('autoPageTurningMode'),
              ))
                _SliderSetting(
                  title: "Auto scroll speed".tl,
                  settingsIndex: "autoScrollSpeed",
                  interval: 1,
                  min: autoScrollSpeedMin.toDouble(),
                  max: autoScrollSpeedMax.toDouble(),
                  onChanged: () {
                    widget.onChanged?.call("autoScrollSpeed");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                )
              else
                _SliderSetting(
                  title: "Auto page turning interval".tl,
                  settingsIndex: "autoPageTurningInterval",
                  interval: 1,
                  min: autoTurnIntervalMin.toDouble(),
                  max: autoTurnIntervalMax.toDouble(),
                  onChanged: () {
                    setState(() {});
                    widget.onChanged?.call("autoPageTurningInterval");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if ((_effectiveSetting('readerMode') as String?)?.startsWith(
                    'continuous',
                  ) ??
                  false)
                _SliderSetting(
                  title: "Mouse scroll speed".tl,
                  settingsIndex: "readerScrollSpeed",
                  interval: 0.1,
                  min: 0.5,
                  max: 3,
                  onChanged: () {
                    widget.onChanged?.call("readerScrollSpeed");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              _SliderSetting(
                title: "Number of images preloaded".tl,
                settingsIndex: "preloadImageCount",
                interval: 1,
                min: 1,
                max: 16,
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            ],
          ),
          _SettingsSection(
            title: 'Gesture settings',
            icon: Icons.touch_app_outlined,
            subtitle:
                (_effectiveSetting('enableTapToTurnPages') != true
                        ? 'Off'
                        : _effectiveSetting('reverseTapToTurnPages') == true
                        ? 'Reverse tap to turn Pages'
                        : 'Tap to turn Pages')
                    .tl,
            children: [
              _PageTurnModeSetting(
                onChanged: (key) {
                  refreshSettings();
                  widget.onChanged?.call(key);
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: 'Double tap to zoom'.tl,
                settingKey: 'enableDoubleTapToZoom',
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call('enableDoubleTapToZoom');
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: 'Long press to zoom'.tl,
                settingKey: 'enableLongPressToZoom',
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call('enableLongPressToZoom');
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              if (_effectiveSetting('enableLongPressToZoom') == true)
                SelectSetting(
                  title: "Long press zoom position".tl,
                  settingKey: "longPressZoomPosition",
                  optionTranslation: {
                    "press": "Press position".tl,
                    "center": "Screen center".tl,
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if (App.isAndroid)
                _SwitchSetting(
                  title: 'Turn page by volume keys'.tl,
                  settingKey: 'enableTurnPageByVolumeKey',
                  onChanged: () {
                    widget.onChanged?.call('enableTurnPageByVolumeKey');
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if (_effectiveSetting('enableTapToTurnPages') == true)
                _SwitchSetting(
                  title: 'Custom tap-to-turn zones'.tl,
                  subtitle: 'Choose what tapping each screen edge does'.tl,
                  settingKey: 'enableCustomTapZones',
                  onChanged: () {
                    setState(() {});
                    widget.onChanged?.call('enableCustomTapZones');
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              if (_effectiveSetting('enableTapToTurnPages') == true &&
                  _effectiveSetting('enableCustomTapZones') == true)
                ...[
                  ('tapZoneTop', 'Top edge tap'.tl),
                  ('tapZoneBottom', 'Bottom edge tap'.tl),
                  ('tapZoneLeft', 'Left edge tap'.tl),
                  ('tapZoneRight', 'Right edge tap'.tl),
                ].map(
                  (e) => SelectSetting(
                    title: e.$2,
                    settingKey: e.$1,
                    optionTranslation: {
                      'prev': 'Previous page'.tl,
                      'next': 'Next page'.tl,
                      'none': 'No action'.tl,
                    },
                    onChanged: () {
                      widget.onChanged?.call(e.$1);
                    },
                    comicId: isEnabledSpecificSettings ? widget.comicId : null,
                    comicSource: isEnabledSpecificSettings
                        ? widget.comicSource
                        : null,
                    useDeviceSettings: useDeviceSpecificSettings,
                  ),
                ),
            ],
          ),
          _SettingsSection(
            title: 'Display settings',
            icon: Icons.contrast,
            subtitle:
                '${'Night mode'.tl}: ${(appdata.settings['readerNightMode'] == true ? 'On' : 'Off').tl}',
            children: [
              SelectSetting(
                title: "Reading background color".tl,
                settingKey: "readerBackgroundColor",
                optionTranslation: {
                  "system": "Follow theme".tl,
                  "white": "White".tl,
                  "gray": "Gray".tl,
                  "black": "Black".tl,
                  "sepia": "Sepia".tl,
                  "green": "Eye-care green".tl,
                },
                onChanged: () {
                  widget.onChanged?.call("readerBackgroundColor");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: "Night mode".tl,
                subtitle:
                    "Dim the page with a warm overlay to reduce eye strain".tl,
                settingKey: "readerNightMode",
                enabled:
                    appdata.settings['readerNightModeFollowSystem'] != true,
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call("readerNightMode");
                },
              ),
              _SwitchSetting(
                title: "Follow system dark mode".tl,
                subtitle:
                    "Turn night mode on/off automatically with the system theme"
                        .tl,
                settingKey: "readerNightModeFollowSystem",
                onChanged: () {
                  if (appdata.settings['readerNightModeFollowSystem'] == true) {
                    final isDark =
                        View.of(
                          context,
                        ).platformDispatcher.platformBrightness ==
                        Brightness.dark;
                    appdata.settings['readerNightMode'] = isDark;
                    appdata.saveData();
                    widget.onChanged?.call("readerNightMode");
                  }
                  setState(() {});
                  widget.onChanged?.call("readerNightModeFollowSystem");
                },
              ),
              if (appdata.settings['readerNightMode'] == true ||
                  appdata.settings['readerNightModeFollowSystem'] == true)
                SelectSetting(
                  title: "Night mode color".tl,
                  settingKey: "readerNightModeColor",
                  optionTranslation: {
                    "warm": "Warm".tl,
                    "black": "Black".tl,
                    "red": "Dim red".tl,
                  },
                  onChanged: () {
                    widget.onChanged?.call("readerNightModeColor");
                  },
                ),
              if (appdata.settings['readerNightMode'] == true ||
                  appdata.settings['readerNightModeFollowSystem'] == true)
                _SliderSetting(
                  title: "Night mode intensity".tl,
                  settingsIndex: "readerNightModeIntensity",
                  interval: 0.05,
                  min: 0.1,
                  max: 0.85,
                  onChanged: () {
                    widget.onChanged?.call("readerNightModeIntensity");
                  },
                ),
              _SwitchSetting(
                title: "Display time & battery info in reader".tl,
                settingKey: "enableClockAndBatteryInfoInReader",
                onChanged: () {
                  widget.onChanged?.call("enableClockAndBatteryInfoInReader");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: "Show system status bar".tl,
                settingKey: "showSystemStatusBar",
                onChanged: () {
                  widget.onChanged?.call("showSystemStatusBar");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              if (App.isMobile)
                _SwitchSetting(
                  title: "Keep screen on while reading".tl,
                  settingKey: "readerKeepScreenOn",
                  onChanged: () {
                    widget.onChanged?.call("readerKeepScreenOn");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              _SwitchSetting(
                title: "Show Page Number".tl,
                settingKey: "showPageNumberInReader",
                onChanged: () {
                  widget.onChanged?.call("showPageNumberInReader");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SwitchSetting(
                title: "Show Chapter Comments".tl,
                settingKey: "showChapterComments",
                onChanged: _onShowChapterCommentsChanged,
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SliderSetting(
                title: "Comment font size".tl,
                settingsIndex: "commentsFontSize",
                interval: 1,
                min: 12,
                max: 24,
                onChanged: () {
                  widget.onChanged?.call("commentsFontSize");
                },
              ),
              if (_isChapterCommentsAtEndSupported())
                _SwitchSetting(
                  title: "Show Comments at Chapter End".tl,
                  settingKey: "showChapterCommentsAtEnd",
                  onChanged: () {
                    widget.onChanged?.call("showChapterCommentsAtEnd");
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
            ],
          ),
          _SettingsSection(
            title: 'Image processing / enhancement',
            icon: Icons.auto_fix_high,
            subtitle: 'Image size, clarity and custom processing',
            children: [
              _SwitchSetting(
                title: 'Limit image width'.tl,
                subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
                settingKey: 'limitImageWidth',
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call('limitImageWidth');
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              if (_effectiveSetting('limitImageWidth') == true)
                _SliderSetting(
                  title: "Image width (% of screen height)".tl,
                  settingsIndex: 'imageWidthPercent',
                  interval: 5,
                  min: 40,
                  max: 150,
                  onChanged: () {
                    widget.onChanged?.call('imageWidthPercent');
                  },
                  comicId: isEnabledSpecificSettings ? widget.comicId : null,
                  comicSource: isEnabledSpecificSettings
                      ? widget.comicSource
                      : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              _CallbackSetting(
                title: "Custom Image Processing".tl,
                callback: () => context.to(() => _CustomImageProcessing()),
                actionTitle: "Edit".tl,
              ),
              _SwitchSetting(
                title: "Image enhancement".tl,
                subtitle:
                    "Sharpen blurry images at render time without extra loading or battery cost"
                        .tl,
                settingKey: "enableReaderImageEnhance",
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call("enableReaderImageEnhance");
                },
              ),
              if (appdata.settings['enableReaderImageEnhance'] == true) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: ImageEnhancePreview(
                    pageImage: widget.currentPageImage,
                  ),
                ),
                _SliderSetting(
                  title: "Sharpen strength".tl,
                  settingsIndex: "readerImageEnhanceStrength",
                  interval: 0.1,
                  min: 0.0,
                  max: ImageEnhanceShader.maxStrength,
                  onChanged: () {
                    widget.onChanged?.call("readerImageEnhanceStrength");
                  },
                ),
                _SliderSetting(
                  title: "Clarity".tl,
                  settingsIndex: "readerImageEnhanceClarity",
                  interval: 0.1,
                  min: 0.0,
                  max: 1.0,
                  onChanged: () {
                    widget.onChanged?.call("readerImageEnhanceClarity");
                  },
                ),
                _SliderSetting(
                  title: "Contrast".tl,
                  settingsIndex: "readerImageEnhanceContrast",
                  interval: 0.1,
                  min: 0.0,
                  max: 1.0,
                  onChanged: () {
                    widget.onChanged?.call("readerImageEnhanceContrast");
                  },
                ),
                _SliderSetting(
                  title: "Color vibrance".tl,
                  settingsIndex: "readerImageEnhanceVibrance",
                  interval: 0.1,
                  min: 0.0,
                  max: 1.0,
                  onChanged: () {
                    widget.onChanged?.call("readerImageEnhanceVibrance");
                  },
                ),
              ],
            ],
          ),
          _SettingsSection(
            title: 'Favorites settings',
            icon: Icons.favorite_border,
            subtitle: 'Quick image collection and chapter covers',
            children: [
              _SwitchSetting(
                title: "Also collect chapter cover when collecting image".tl,
                settingKey: "autoFavoriteCover",
                onChanged: () {
                  widget.onChanged?.call("autoFavoriteCover");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              SelectSetting(
                title: "Quick collect image".tl,
                settingKey: "quickCollectImage",
                optionTranslation: {
                  "No": "Not enable".tl,
                  "DoubleTap": "Double Tap".tl,
                  "Swipe": "Swipe".tl,
                },
                onChanged: () {
                  widget.onChanged?.call("quickCollectImage");
                },
                help:
                    "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode"
                        .tl,
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            ],
          ),
          _SettingsSection(
            title: 'E-ink screen',
            icon: Icons.chrome_reader_mode_outlined,
            subtitle: 'Refresh and page-turn effects for e-ink displays',
            children: [
              _SwitchSetting(
                title: "Full refresh on page turn".tl,
                subtitle:
                    "Briefly fill the screen with a solid color after turning a page to clear ghosting. Gallery modes only"
                        .tl,
                settingKey: "einkFullRefresh",
                onChanged: () => setState(() {}),
              ),
              if (appdata.settings['einkFullRefresh'] == true) ...[
                SelectSetting(
                  title: "Refresh color".tl,
                  settingKey: "einkRefreshColor",
                  optionTranslation: {
                    "white": "White".tl,
                    "black": "Black".tl,
                    "blackThenWhite": "Black, then white".tl,
                  },
                ),
                _SliderSetting(
                  title: "Refresh every N pages".tl,
                  settingsIndex: "einkRefreshInterval",
                  interval: 1,
                  min: 1,
                  max: 10,
                ),
                _SliderSetting(
                  title: "Refresh duration (ms)".tl,
                  settingsIndex: "einkRefreshDuration",
                  interval: 50,
                  min: 50,
                  max: 1000,
                ),
              ],
              if (EinkPanel.rippleSupported) ...[
                _SwitchSetting(
                  title: "Ripple page turn".tl,
                  subtitle:
                      "Use the system ripple effect when turning pages by tap or key in gallery modes. Replaces the page animation"
                          .tl,
                  settingKey: "einkRipplePageTurn",
                  onChanged: () => setState(() {}),
                ),
                if (appdata.settings['einkRipplePageTurn'] == true)
                  SelectSetting(
                    title: "Ripple speed".tl,
                    settingKey: "einkRippleSpeed",
                    optionTranslation: {
                      "slower": "Slower".tl,
                      "standard": "Standard".tl,
                      "faster": "Faster".tl,
                    },
                  ),
              ],
            ],
          ),
          _SettingsSection(
            title: 'Related settings',
            icon: Icons.translate,
            common: true,
            children: [
              _CallbackSetting(
                title: 'AI Translation'.tl,
                subtitle: _activeProviderSubtitle(),
                actionTitle: 'Manage'.tl,
                callback: () => context.to(
                  () => Material(
                    child: ReaderSettings(
                      translationOnly: true,
                      comicId: widget.comicId,
                      comicSource: widget.comicSource,
                      onChanged: widget.onChanged,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ] else ...[
          _SettingsSection(
            title: 'Translation preferences',
            icon: Icons.translate,
            common: true,
            children: [
              // Translation is per-comic on purpose (it spends tokens): the
              // switch only appears when a specific comic is in context (opened
              // from the reader / detail page), and toggles that comic alone.
              if (widget.comicId != null && widget.comicSource != null)
                ListTile(
                  title: Text("Translate pages while reading".tl),
                  subtitle: Text(
                    "Applies to this comic only. The original shows until a page finishes translating."
                        .tl,
                  ),
                  trailing: Switch(
                    value: ImageTranslationService.isEnabledForComic(
                      widget.comicId!,
                      widget.comicSource!,
                    ),
                    onChanged: (v) {
                      ImageTranslationService.setEnabledForComic(
                        widget.comicId!,
                        widget.comicSource!,
                        v,
                      );
                      appdata.saveData();
                      setState(() {});
                      widget.onChanged?.call("enableImageTranslation");
                    },
                  ),
                )
              else
                ListTile(
                  title: Text("Translate pages while reading".tl),
                  subtitle: Text(
                    "Enable this per comic from its detail page or the in-reader settings."
                        .tl,
                  ),
                  enabled: false,
                ),
              SelectSetting(
                title: "Source language".tl,
                settingKey: "imageTranslationSource",
                optionTranslation: _sourceLanguageOptions(),
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call("imageTranslationSource");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              SelectSetting(
                title: "Target language".tl,
                settingKey: "imageTranslationTarget",
                optionTranslation: _targetLanguageOptions(),
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call("imageTranslationTarget");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              SelectSetting(
                title: "Performance mode".tl,
                settingKey: TranslationPerformanceConfig.settingKey,
                optionTranslation: {
                  "saver": "Save resources (low memory)".tl,
                  "balanced": "Balanced (recommended)".tl,
                  "fast": "Fast (more battery)".tl,
                  "custom": "Custom".tl,
                },
                onChanged: () {
                  _setTranslationPreset(
                    '${appdata.settings[TranslationPerformanceConfig.settingKey]}',
                  );
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'Translation services',
            icon: Icons.cloud_outlined,
            common: true,
            children: [
              _CallbackSetting(
                title: "LLM providers".tl,
                subtitle: _activeProviderSubtitle(),
                actionTitle: "Manage".tl,
                callback: () async {
                  await context.to(() => const LlmProvidersPage());
                  if (mounted) setState(() {});
                },
              ),
              _CallbackSetting(
                title: "Test translation".tl,
                subtitle: "Check the endpoint with a sample line".tl,
                actionTitle: "Test".tl,
                callback: _testTranslation,
              ),
            ],
          ),
          _SettingsSection(
            title: 'Models & languages',
            icon: Icons.language,
            common: true,
            children: [
              _CallbackSetting(
                title: "Custom languages".tl,
                subtitle: _customLanguageCount() == 0
                    ? "Add source or target languages that are not in the list"
                          .tl
                    : "@count added".tlParams({
                        'count': _customLanguageCount(),
                      }),
                actionTitle: "Manage".tl,
                callback: () async {
                  await context.to(() => const TranslationLanguagesPage());
                  if (mounted) setState(() {});
                },
              ),
              _CallbackSetting(
                title: "Translation models".tl,
                subtitle: TranslationModels.isReadyFor(_effectiveSourceLang())
                    ? "Models ready".tl
                    : "Models not downloaded".tl,
                actionTitle: "Manage".tl,
                callback: () => context.to(
                  () =>
                      TranslationModelsPage(sourceLang: _effectiveSourceLang()),
                ),
              ),
              _CallbackSetting(
                title: "Translation prompt".tl,
                subtitle: LlmPromptStore.isCustom ? "Custom".tl : "Built-in".tl,
                actionTitle: "Edit".tl,
                callback: () async {
                  await context.to(() => const TranslationPromptPage());
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'Advanced translation settings',
            icon: Icons.tune,
            subtitle: 'Text removal and translation concurrency',
            children: [
              SelectSetting(
                title: "Text removal".tl,
                settingKey: "imageTranslationInpaintMode",
                help:
                    "How the original text is removed before the translation is drawn. Smart erase reconstructs the background so no solid block covers the bubble; Color patch is the old opaque block."
                        .tl,
                optionTranslation: {
                  "smart": "Smart erase".tl,
                  "patch": "Color patch".tl,
                },
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call("imageTranslationInpaintMode");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              _SliderSetting(
                title: "Pages per pre-translation request".tl,
                settingsIndex: "imageTranslationPreBatchPages",
                interval: 1,
                min: 1,
                max: App.isDesktop ? 20 : 8,
                onChanged: () {
                  _markTranslationCustom("imageTranslationPreBatchPages");
                },
              ),
              _SliderSetting(
                title: "OCR parallelism (0 = auto)".tl,
                settingsIndex: "imageTranslationOcrWorkers",
                interval: 1,
                min: 0,
                max: App.isDesktop ? 6 : 2,
                onChanged: () {
                  _markTranslationCustom("imageTranslationOcrWorkers");
                },
              ),
              _SliderSetting(
                title: "Image download concurrency".tl,
                settingsIndex: "imageTranslationImageConcurrency",
                interval: 1,
                min: 1,
                max: App.isDesktop ? 6 : 3,
                onChanged: () {
                  _markTranslationCustom("imageTranslationImageConcurrency");
                },
              ),
              _SliderSetting(
                title: "Translation request concurrency".tl,
                settingsIndex: "imageTranslationLlmConcurrency",
                interval: 1,
                min: 1,
                max: App.isDesktop ? 4 : 3,
                onChanged: () {
                  _markTranslationCustom("imageTranslationLlmConcurrency");
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'Help & cleanup',
            icon: Icons.help_outline,
            subtitle: 'Translation help and stored results',
            children: [
              _CallbackSetting(
                title: "How AI translation works".tl,
                subtitle: "Setup and usage in plain language".tl,
                actionTitle: "Help".tl,
                callback: _showTranslationHelp,
              ),
              _CallbackSetting(
                title: "Clear translation results".tl,
                subtitle:
                    "Deletes all stored page translations and rendered images. Language and glossary learned per comic are kept."
                        .tl,
                actionTitle: "Clear".tl,
                // Confirm first: every cleared page costs tokens to translate
                // again, and the button sits next to ones that only navigate.
                callback: () => showConfirmDialog(
                  context: App.rootContext,
                  title: "Clear translation results".tl,
                  content:
                      "Deletes every stored page translation and rendered image. Translating them again will spend API tokens. Devices syncing translations over WebDAV delete them too."
                          .tl,
                  btnColor: context.colorScheme.error,
                  onConfirm: () async {
                    var removed = await ImageTranslationService.instance
                        .clearAllTranslationCache();
                    // Also drop the pre-translation status the chapter picker
                    // reads from, so cleared results leave no stale ticks.
                    PreTranslationTaskManager.instance.clearAllChapterStatus();
                    if (context.mounted) {
                      context.showMessage(
                        message: "Translation results cleared".tl,
                      );
                    }
                    Log.info(
                      'Image Translation',
                      'Cleared $removed translated pages by user',
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildReadingModes(SelectSetting setting) => Padding(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingLabel(
          title: 'Reading mode'.tl,
          keys: const ['readerMode'],
          comicId: setting.comicId,
          sourceKey: setting.comicSource,
          useDeviceSettings: setting.useDeviceSettings,
          onReset: () {
            refreshSettings();
            setting.onChanged?.call();
          },
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in setting.optionTranslation.entries)
                SizedBox(
                  width: (constraints.maxWidth - 16) / 3,
                  child: _ReadingModeTile(
                    mode: entry.key,
                    label: entry.value,
                    selected: _effectiveSetting('readerMode') == entry.key,
                    onTap: () {
                      _writeEffectiveSetting('readerMode', entry.key);
                      setting.onChanged?.call();
                      appdata.saveData();
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ReadingModeTile extends StatelessWidget {
  const _ReadingModeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final continuous = mode.startsWith('continuous');
    final vertical = mode.endsWith('TopToBottom');
    final direction = vertical
        ? Icons.arrow_downward
        : mode.endsWith('RightToLeft')
        ? Icons.arrow_back
        : Icons.arrow_forward;
    final ink = selected ? colors.primary : colors.onSurfaceVariant;
    Widget sheet() => Container(
      width: vertical ? 32 : 18,
      height: vertical ? 23 : 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        border: Border.all(color: ink.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: ink.withValues(alpha: 0.14),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 3),
          Expanded(
            flex: 2,
            child: ColoredBox(
              color: ink.withValues(alpha: 0.22),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.45)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: ClipRect(
                      child: OverflowBox(
                        maxHeight: vertical ? 55 : 48,
                        child: Flex(
                          direction: vertical ? Axis.vertical : Axis.horizontal,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            sheet(),
                            SizedBox(
                              width: continuous ? 2 : 4,
                              height: continuous ? 2 : 4,
                            ),
                            sheet(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          (continuous ? 'Continuous' : 'Gallery').tl,
                          style: TextStyle(fontSize: 12, color: ink),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(direction, size: 12, color: ink),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState extends State<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  @override
  void dispose() {
    appdata.settings['customImageProcessing'] = current;
    appdata.saveData();
    super.dispose();
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom Image Processing".tl),
        actions: [
          TextButton(
            onPressed: () {
              current = defaultCustomImageProcessing;
              appdata.settings['customImageProcessing'] = current;
              resetKey++;
              setState(() {});
            },
            child: Text("Reset".tl),
          ),
        ],
      ),
      body: Column(
        children: [
          _SwitchSetting(
            title: "Enable".tl,
            settingKey: "enableCustomImageProcessing",
          ),
          Expanded(
            child: Container(
              margin: EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colorScheme.outlineVariant),
              ),
              child: SizedBox.expand(
                child: CodeEditor(
                  key: ValueKey(resetKey),
                  initialValue: appdata.settings['customImageProcessing'],
                  onChanged: (value) {
                    current = value;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
