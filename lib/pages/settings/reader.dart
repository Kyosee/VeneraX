part of 'settings_page.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  bool _isChapterCommentsAtEndSupported() {
    String? readerMode;
    bool? showChapterComments;

    if (widget.comicId != null &&
        widget.comicSource != null &&
        appdata.settings.isComicSpecificSettingsEnabled(
          widget.comicId,
          widget.comicSource,
        )) {
      readerMode = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'readerMode',
      );
      showChapterComments = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'showChapterComments',
      );
    } else {
      readerMode = appdata.settings['readerMode'] as String?;
      showChapterComments = appdata.settings['showChapterComments'] as bool?;
    }

    // Must have showChapterComments enabled and be in gallery mode
    if (showChapterComments != true) return false;

    return readerMode == 'galleryLeftToRight' ||
        readerMode == 'galleryRightToLeft';
  }

  /// Edits one of the user's own LLM endpoint fields (URL / key / model).
  void _editLlmField(String title, String settingKey, {String? hint}) {
    showInputDialog(
      context: context,
      title: title,
      hintText: hint,
      initialValue: appdata.settings[settingKey] as String? ?? '',
      onConfirm: (value) {
        setState(() {
          appdata.settings[settingKey] = value.trim();
        });
        appdata.saveData();
        widget.onChanged?.call(settingKey);
        return null;
      },
    );
  }

  void _setLlmModel(String value) {
    setState(() {
      appdata.settings['imageTranslationLlmModel'] = value.trim();
    });
    appdata.saveData();
    widget.onChanged?.call('imageTranslationLlmModel');
  }

  /// Lets the user pick the model: fetch the endpoint's `/models` list and
  /// choose one, or type it by hand. Both paths write the same setting.
  void _chooseLlmModel() async {
    if (LlmTranslator.baseUrlConfigured) {
      // Try to fetch the list first; fall back to manual entry on any failure
      // so a gateway without a /models endpoint is never a dead end.
      var controller = showLoadingDialog(
        context,
        message: "Loading".tl,
        allowCancel: false,
      );
      List<String>? models;
      String? error;
      try {
        models = await LlmTranslator.fetchModels();
      } catch (e) {
        error = e.toString();
      }
      controller.close();
      if (!mounted) return;
      if (models != null && models.isNotEmpty) {
        _showModelPicker(models);
        return;
      }
      if (error != null) {
        context.showMessage(
          message: "Failed to fetch model list".tl,
        );
      }
    }
    _editLlmField("LLM Model".tl, 'imageTranslationLlmModel');
  }

  void _showModelPicker(List<String> models) {
    var current = appdata.settings['imageTranslationLlmModel'] as String? ?? '';
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Select model".tl,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var model in models)
                        ListTile(
                          title: Text(model),
                          trailing: model == current
                              ? Icon(
                                  Icons.check,
                                  color: context.colorScheme.primary,
                                )
                              : null,
                          onTap: () {
                            context.pop();
                            _setLlmModel(model);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                context.pop();
                _editLlmField("LLM Model".tl, 'imageTranslationLlmModel');
              },
              child: Text("Enter manually".tl),
            ),
          ],
        );
      },
    );
  }

  /// A plain-language explainer of what AI translation does, how to set it up,
  /// and how to use it — so users don't have to guess from the field labels.
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
                "1. Fill in the LLM API URL, API Key, and Model — any OpenAI-compatible service works.\n2. Tap Test translation to confirm it replies.\n3. Open Translation models and download the models for your source language (needed for on-device text recognition)."
                    .tl,
              ),
              section(
                "How to use".tl,
                "Translation is turned on per comic, not globally, because it uses your API tokens. Open a comic, turn on \"Translate pages while reading\", and pages translate as you read. To translate ahead of time, use Pre-translate from the comic's menu."
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
          Button.filled(
            onPressed: context.pop,
            child: Text("OK".tl),
          ),
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
      context.showMessage(message: "Configure the LLM endpoint first".tl);
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
      var target =
          appdata.settings['imageTranslationTarget'] as String? ?? 'zh';
      var res = await LlmTranslator.translateBatch(
        const ['こんにちは', 'ありがとう'],
        target,
      );
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
          child: Text(
            error ?? "こんにちは / ありがとう →\n$result",
            style: ts.s14,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => context.pop(),
            child: Text("OK".tl),
          ),
        ],
      ),
    );
  }

  void _onShowChapterCommentsChanged() {
    // When showChapterComments is turned off, also turn off showChapterCommentsAtEnd
    bool? showChapterComments;

    if (widget.comicId != null &&
        widget.comicSource != null &&
        appdata.settings.isComicSpecificSettingsEnabled(
          widget.comicId,
          widget.comicSource,
        )) {
      showChapterComments = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'showChapterComments',
      );
      if (showChapterComments != true) {
        appdata.settings.setReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          'showChapterCommentsAtEnd',
          false,
        );
      }
    } else {
      showChapterComments = appdata.settings['showChapterComments'] as bool?;
      if (showChapterComments != true) {
        appdata.settings['showChapterCommentsAtEnd'] = false;
      }
    }

    setState(() {});
    widget.onChanged?.call("showChapterComments");
  }

  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    bool isEnabledSpecificSettings =
        comicId != null &&
        appdata.settings.isComicSpecificSettingsEnabled(comicId, sourceKey);
    bool useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable comic specific settings".tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                },
              ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                    },
                    child: Text(
                      "Clear specific reader settings for this comic".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        if (comicId == null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                title: Text("Enable device specific settings".tl),
                value: useDeviceSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
                    },
                    child: Text(
                      "Clear specific reader settings for this device".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerReadingGroup'),
          initiallyExpanded: true,
          icon: Icons.menu_book,
          title: "Reading settings".tl,
          children: [
            _PageTurnModeSetting(
              onChanged: widget.onChanged,
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            _SwitchSetting(
              title: "Page animation".tl,
              settingKey: "enablePageAnimation",
              onChanged: () {
                widget.onChanged?.call("enablePageAnimation");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            SelectSetting(
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
                var readerMode = appdata.settings['readerMode'];
                if (readerMode?.toLowerCase().startsWith('continuous') ??
                    false) {
                  appdata.settings['readerScreenPicNumberForLandscape'] = 1;
                  widget.onChanged?.call('readerScreenPicNumberForLandscape');
                  appdata.settings['readerScreenPicNumberForPortrait'] = 1;
                  widget.onChanged?.call('readerScreenPicNumberForPortrait');
                }
                widget.onChanged?.call("readerMode");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
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
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            if (appdata.settings['readerMode']!.startsWith('gallery'))
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['readerMode']!.startsWith('gallery'))
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['readerMode']!.startsWith('gallery') &&
                (appdata.settings['readerScreenPicNumberForLandscape'] > 1 ||
                    appdata.settings['readerScreenPicNumberForPortrait'] > 1))
              _SwitchSetting(
                title: "Show single image on first page".tl,
                settingKey: "showSingleImageOnFirstPage",
                onChanged: () {
                  widget.onChanged?.call("showSingleImageOnFirstPage");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['readerMode']!.startsWith('gallery'))
              _SwitchSetting(
                title: "Fill screen".tl,
                subtitle:
                    "Crop image to fill screen instead of letterboxing".tl,
                settingKey: "galleryFillScreen",
                onChanged: () {
                  widget.onChanged?.call("galleryFillScreen");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
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
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            _SwitchSetting(
              title: "Night mode".tl,
              subtitle: "Dim the page with a warm overlay to reduce eye strain"
                  .tl,
              settingKey: "readerNightMode",
              enabled: appdata.settings['readerNightModeFollowSystem'] != true,
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
                      View.of(context).platformDispatcher.platformBrightness ==
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
            _SliderSetting(
              title: "Auto page turning interval".tl,
              settingsIndex: "autoPageTurningInterval",
              interval: 1,
              min: 1,
              max: 20,
              onChanged: () {
                setState(() {});
                widget.onChanged?.call("autoPageTurningInterval");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            if (appdata.settings['readerMode']!.startsWith('continuous'))
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['readerMode'] == 'continuousTopToBottom')
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['readerMode']!.startsWith('continuous'))
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            _SliderSetting(
              title: "Number of images preloaded".tl,
              settingsIndex: "preloadImageCount",
              interval: 1,
              min: 1,
              max: 16,
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ],
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerGestureGroup'),
          icon: Icons.touch_app,
          title: "Gesture settings".tl,
          children: [
            _SwitchSetting(
              title: 'Double tap to zoom'.tl,
              settingKey: 'enableDoubleTapToZoom',
              onChanged: () {
                setState(() {});
                widget.onChanged?.call('enableDoubleTapToZoom');
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
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
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            if (appdata.settings['enableLongPressToZoom'] == true)
              SelectSetting(
                title: "Long press zoom position".tl,
                settingKey: "longPressZoomPosition",
                optionTranslation: {
                  "press": "Press position".tl,
                  "center": "Screen center".tl,
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['enableTapToTurnPages'] == true)
              _SwitchSetting(
                title: 'Custom tap-to-turn zones'.tl,
                subtitle:
                    'Choose what tapping each screen edge does'.tl,
                settingKey: 'enableCustomTapZones',
                onChanged: () {
                  setState(() {});
                  widget.onChanged?.call('enableCustomTapZones');
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            if (appdata.settings['enableTapToTurnPages'] == true &&
                appdata.settings['enableCustomTapZones'] == true)
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
                  comicSource:
                      isEnabledSpecificSettings ? widget.comicSource : null,
                  useDeviceSettings: useDeviceSpecificSettings,
                ),
              ),
          ],
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerFavoritesGroup'),
          icon: Icons.favorite_border,
          title: "Favorites settings".tl,
          children: [
            _SwitchSetting(
              title: "Also collect chapter cover when collecting image".tl,
              settingKey: "autoFavoriteCover",
              onChanged: () {
                widget.onChanged?.call("autoFavoriteCover");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
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
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ],
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerImageProcessingGroup'),
          icon: Icons.auto_fix_high,
          title: "Image processing / enhancement".tl,
          children: [
            _SwitchSetting(
              title: 'Limit image width'.tl,
              subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
              settingKey: 'limitImageWidth',
              onChanged: () {
                widget.onChanged?.call('limitImageWidth');
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
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
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerDisplayGroup'),
          icon: Icons.tv,
          title: "Display settings".tl,
          children: [
            _SwitchSetting(
              title: "Display time & battery info in reader".tl,
              settingKey: "enableClockAndBatteryInfoInReader",
              onChanged: () {
                widget.onChanged?.call("enableClockAndBatteryInfoInReader");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            _SwitchSetting(
              title: "Show system status bar".tl,
              settingKey: "showSystemStatusBar",
              onChanged: () {
                widget.onChanged?.call("showSystemStatusBar");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            _SwitchSetting(
              title: "Show Page Number".tl,
              settingKey: "showPageNumberInReader",
              onChanged: () {
                widget.onChanged?.call("showPageNumberInReader");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
            _SwitchSetting(
              title: "Show Chapter Comments".tl,
              settingKey: "showChapterComments",
              onChanged: _onShowChapterCommentsChanged,
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
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
                comicSource:
                    isEnabledSpecificSettings ? widget.comicSource : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
          ],
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('readerTranslationGroup'),
          icon: Icons.translate,
          title: "AI Translation (experimental)".tl,
          children: [
            _CallbackSetting(
              title: "How AI translation works".tl,
              subtitle: "Setup and usage in plain language".tl,
              actionTitle: "Help".tl,
              callback: _showTranslationHelp,
            ),
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
            _CallbackSetting(
              title: "LLM API URL".tl,
              subtitle: (appdata.settings['imageTranslationLlmUrl'] as String)
                      .isEmpty
                  ? "Not configured".tl
                  : appdata.settings['imageTranslationLlmUrl'],
              actionTitle: "Edit".tl,
              callback: () => _editLlmField(
                "LLM API URL".tl,
                'imageTranslationLlmUrl',
                hint: 'https://example.com/v1',
              ),
            ),
            _CallbackSetting(
              title: "LLM API Key".tl,
              subtitle: (appdata.settings['imageTranslationLlmKey'] as String)
                      .isEmpty
                  ? "Not configured".tl
                  : '••••••',
              actionTitle: "Edit".tl,
              callback: () => _editLlmField(
                "LLM API Key".tl,
                'imageTranslationLlmKey',
              ),
            ),
            _CallbackSetting(
              title: "LLM Model".tl,
              subtitle:
                  (appdata.settings['imageTranslationLlmModel'] as String)
                      .isEmpty
                  ? "Not configured".tl
                  : appdata.settings['imageTranslationLlmModel'],
              actionTitle: "Select".tl,
              callback: _chooseLlmModel,
            ),
            _CallbackSetting(
              title: "Test translation".tl,
              subtitle: "Check the endpoint with a sample line".tl,
              actionTitle: "Test".tl,
              callback: _testTranslation,
            ),
            SelectSetting(
              title: "Source language".tl,
              settingKey: "imageTranslationSource",
              optionTranslation: {
                "auto": "Auto detect".tl,
                "ja": "Japanese".tl,
                "en": "English".tl,
                "ko": "Korean".tl,
                "zh": "Chinese".tl,
              },
              onChanged: () {
                setState(() {});
                widget.onChanged?.call("imageTranslationSource");
              },
            ),
            SelectSetting(
              title: "Target language".tl,
              settingKey: "imageTranslationTarget",
              optionTranslation: {
                "zh": "Simplified Chinese".tl,
                "zh-TW": "Traditional Chinese".tl,
                "en": "English".tl,
                "ja": "Japanese".tl,
                "ko": "Korean".tl,
                "fr": "French".tl,
                "de": "German".tl,
                "es": "Spanish".tl,
                "ru": "Russian".tl,
              },
              onChanged: () {
                setState(() {});
                widget.onChanged?.call("imageTranslationTarget");
              },
            ),
            _SliderSetting(
              title: "Pages per pre-translation request".tl,
              settingsIndex: "imageTranslationPreBatchPages",
              interval: 1,
              min: 1,
              max: 20,
              onChanged: () {
                widget.onChanged?.call("imageTranslationPreBatchPages");
              },
            ),
            _CallbackSetting(
              title: "Translation models".tl,
              subtitle: TranslationModels.isReadyFor(
                    appdata.settings['imageTranslationSource'] as String? ??
                        'auto',
                  )
                  ? "Models ready".tl
                  : "Models not downloaded".tl,
              actionTitle: "Manage".tl,
              callback: () => context.to(() => const TranslationModelsPage()),
            ),
            _CallbackSetting(
              title: "Clear translation results".tl,
              subtitle:
                  "Deletes all stored page translations and rendered images. Language and glossary learned per comic are kept."
                      .tl,
              actionTitle: "Clear".tl,
              callback: () async {
                var removed = await ImageTranslationService.instance
                    .clearAllTranslationCache();
                // Also drop the pre-translation status the chapter picker reads
                // from, so cleared results don't leave stale "translated" ticks.
                PreTranslationTaskManager.instance.clearAllChapterStatus();
                if (context.mounted) {
                  context.showMessage(
                    message: "Translation results cleared".tl,
                  );
                }
                Log.info('Image Translation',
                    'Cleared $removed translated pages by user');
              },
            ),
          ],
        ).toSliver(),
      ],
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
