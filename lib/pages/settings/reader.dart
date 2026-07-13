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
        ExpansionTile(
          key: const PageStorageKey('readerReadingGroup'),
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text("Reading settings".tl, style: ts.bold.s18),
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
        ExpansionTile(
          key: const PageStorageKey('readerGestureGroup'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text("Gesture settings".tl, style: ts.bold.s18),
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
        ExpansionTile(
          key: const PageStorageKey('readerFavoritesGroup'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text("Favorites settings".tl, style: ts.bold.s18),
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
        ExpansionTile(
          key: const PageStorageKey('readerImageProcessingGroup'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text("Image processing / enhancement".tl, style: ts.bold.s18),
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
        ExpansionTile(
          key: const PageStorageKey('readerDisplayGroup'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text("Display settings".tl, style: ts.bold.s18),
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
