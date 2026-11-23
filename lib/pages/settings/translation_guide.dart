part of 'settings_page.dart';

class TranslationGuidePage extends StatefulWidget {
  const TranslationGuidePage({
    super.key,
    this.comicId,
    this.comicSource,
    this.startAtMissing = false,
    this.onLanguageChanged,
  });

  final String? comicId;
  final String? comicSource;
  final bool startAtMissing;
  final ValueChanged<String>? onLanguageChanged;

  // Local UI preference. Comic translation preferences sync separately.
  static const _promptKey = 'translationGuidePrompts';
  static bool get showAutomatically =>
      appdata.implicitData[_promptKey] != false;

  static Future<void> setShowAutomatically(bool show) async {
    if (show == showAutomatically) return;
    appdata.implicitData[_promptKey] = show;
    await appdata.writeImplicitData();
  }

  /// Both comic switches keep their original behavior when prompts are off.
  static Future<bool> requestComicChange(
    BuildContext context,
    String comicId,
    String sourceKey,
    bool enabled, {
    ValueChanged<String>? onLanguageChanged,
  }) async {
    if (ImageTranslationService.isEnabledForComic(comicId, sourceKey) ==
        enabled) {
      return false;
    }
    if (enabled &&
        showAutomatically &&
        !ImageTranslationService.isReadyForComic(comicId, sourceKey)) {
      return await context.to<bool>(
            () => TranslationGuidePage(
              comicId: comicId,
              comicSource: sourceKey,
              startAtMissing: true,
              onLanguageChanged: onLanguageChanged,
            ),
          ) ??
          false;
    }
    ImageTranslationService.setEnabledForComic(comicId, sourceKey, enabled);
    return true;
  }

  @override
  State<TranslationGuidePage> createState() => _TranslationGuidePageState();
}

class _TranslationGuidePageState extends State<TranslationGuidePage> {
  bool _translated = false;
  late int _step;
  late int _modelRevision;

  bool get _hasComic => widget.comicId != null && widget.comicSource != null;
  TranslationConfig get _config => _hasComic
      ? TranslationConfig.of(widget.comicId!, widget.comicSource)
      : TranslationConfig.device;
  bool get _enabled =>
      _hasComic &&
      ImageTranslationService.isEnabledForComic(
        widget.comicId!,
        widget.comicSource!,
      );
  bool get _modelsReady => TranslationModels.isReadyFor(_config.sourceLang);
  bool get _ready => LlmTranslator.isConfigured && _modelsReady;
  int get _firstMissing {
    if (!LlmTranslator.isConfigured) return 0;
    return _modelsReady ? 2 : 1;
  }

  @override
  void initState() {
    super.initState();
    _step = _firstMissing;
    _modelRevision = TranslationModelStore.instance.diskRevision;
    TranslationModelStore.instance.addListener(_modelsChanged);
  }

  @override
  void dispose() {
    TranslationModelStore.instance.removeListener(_modelsChanged);
    super.dispose();
  }

  void _modelsChanged() {
    final revision = TranslationModelStore.instance.diskRevision;
    if (revision == _modelRevision) return;
    _modelRevision = revision;
    setState(() {});
  }

  Future<void> _open(Widget Function() page) async {
    await context.to(page);
    if (mounted) setState(() {});
  }

  Future<void> _leave({bool enable = false}) async {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    if (enable) {
      if (!_ready || !_hasComic || _enabled) return;
      ImageTranslationService.setEnabledForComic(
        widget.comicId!,
        widget.comicSource!,
        true,
      );
    }
    final write = TranslationGuidePage.setShowAutomatically(false);
    context.pop(enable);
    await write;
  }

  void _next() => setState(() => _step++);

  Widget _stepTile(
    int index,
    String title,
    bool ready,
    Widget Function() body,
  ) {
    final colors = context.colorScheme;
    final open = _step == index;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: CircleAvatar(
            radius: 17,
            backgroundColor: ready
                ? colors.secondaryContainer
                : colors.surfaceContainerHighest,
            foregroundColor: ready
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant,
            child: ready
                ? Icon(Icons.check, size: 19, semanticLabel: 'Ready'.tl)
                : Text('${index + 1}'),
          ),
          title: Text(title.tl, style: Theme.of(context).textTheme.titleSmall),
          trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _step = open ? -1 : index),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: body(),
          ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _stepBody(
    String description,
    List<Widget> actions, {
    String? detail,
    Widget? controls,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(description.tl),
      if (controls != null) controls,
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            detail,
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      if (actions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(spacing: 8, runSpacing: 6, children: actions),
        ),
    ],
  );

  Widget _providerStep() {
    final configured = LlmTranslator.isConfigured;
    return _stepBody(
      'Add a provider, then test it with a sample line. Google Translate needs no key. For an AI model, enter your API URL, key and model name.',
      [
        if (LlmProviderStore.providers.isEmpty)
          FilledButton(
            onPressed: () async {
              final added = await LlmProvidersPage.addProvider(
                context,
                initialKind: LlmProviderKind.publicFree,
              );
              if (added && mounted) setState(() {});
            },
            child: Text('Add provider'.tl),
          )
        else
          FilledButton.tonal(
            onPressed: () => _open(() => const LlmProvidersPage()),
            child: Text('LLM providers'.tl),
          ),
        if (configured) ...[
          TextButton(
            onPressed: () =>
                _testTranslationService(context, _config.targetLang),
            child: Text('Test translation'.tl),
          ),
          TextButton(onPressed: _next, child: Text('Continue'.tl)),
        ],
      ],
    );
  }

  Widget _modelStep() {
    final config = _config;
    return _stepBody(
      'In the model library, download a text detector and the recognizer for the language printed in the comic. Both stay on this device.',
      [
        FilledButton.tonal(
          onPressed: () =>
              _open(() => TranslationModelsPage(sourceLang: config.sourceLang)),
          child: Text('Model management'.tl),
        ),
        if (_modelsReady)
          TextButton(onPressed: _next, child: Text('Continue'.tl)),
      ],
      controls: Column(
        children: [
          for (final target in [false, true])
            _translationLanguageField(
              target: target,
              comicId: widget.comicId,
              comicSource: widget.comicSource,
              onChanged: (key) {
                if (!mounted) return;
                setState(() {});
                widget.onLanguageChanged?.call(key);
              },
            ),
        ],
      ),
    );
  }

  Widget _comicStep() {
    final canEnable = _ready && _hasComic && !_enabled;
    return _stepBody(
      'On the comic details page, open More and choose Enable AI translation. In the reader, open Settings, then AI Translation.',
      [
        if (!_ready)
          FilledButton.tonal(
            onPressed: () => setState(() => _step = _firstMissing),
            child: Text('Set up'.tl),
          )
        else
          FilledButton(
            onPressed: () => _leave(enable: canEnable),
            child: Text(
              (canEnable ? 'Enable AI translation' : 'Finish guide').tl,
            ),
          ),
      ],
      detail:
          (_hasComic
                  ? _enabled && _ready
                        ? 'Translation is ready for this comic.'
                        : 'Translate comic text with your chosen service. A paid service may charge for translated pages.'
                  : 'Open a comic to enable translation for it. Other comics keep their own setting.')
              .tl,
    );
  }

  Widget _sample() {
    final colors = context.colorScheme;
    final line = _translated ? 'Next stop, Seaside Station.'.tl : '次は、海辺駅です。';
    final lines = line.replaceFirst(RegExp(r'[,、，]\s*'), '\n');
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1000 / 526,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final width = bounds.maxWidth;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      'assets/translation_guide_seaside.png',
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                    ),
                    Positioned(
                      left: width * .045,
                      top: bounds.maxHeight * .10,
                      width: width * .34,
                      height: bounds.maxHeight * .36,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.all(
                            Radius.elliptical(width * .18, width * .1),
                          ),
                          color: Colors.white,
                          border: Border.all(color: Colors.black87, width: 1.6),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: width * .026,
                            vertical: 4,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SizedBox(
                              width: width * .27,
                              child: Text(
                                lines,
                                semanticsLabel: line,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: (width * .042)
                                      .clamp(13, 23)
                                      .toDouble(),
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 3,
              children: [
                Text(
                  'Seaside train · Sample page'.tl,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text('Show original'.tl),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Show translated'.tl),
                    ),
                  ],
                  selected: {_translated},
                  onSelectionChanged: (value) =>
                      setState(() => _translated = value.single),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _intro() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Translate your first manga page'.tl,
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      Text(
        'Set up a service and recognition models, then turn translation on for the comic you want to read.'
            .tl,
      ),
    ],
  );

  Widget _question(String question, String answer) => ExpansionTile(
    tilePadding: const EdgeInsets.symmetric(horizontal: 8),
    title: Text(question.tl),
    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(answer.tl),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('AI Translation help'.tl)),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                if (!widget.startAtMissing)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, bounds) {
                          if (bounds.maxWidth >= 620) {
                            return Row(
                              children: [
                                Expanded(child: _intro()),
                                const SizedBox(width: 16),
                                Expanded(child: _sample()),
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _intro(),
                              const SizedBox(height: 14),
                              _sample(),
                            ],
                          );
                        },
                      ),
                    ),
                  )
                else
                  Text(
                    'First-time setup'.tl,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                if (TranslationGuidePage.showAutomatically)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () => _leave(),
                      child: Text('Hide translation guide'.tl),
                    ),
                  ),
                const SizedBox(height: 12),
                _stepTile(
                  0,
                  'Connect a translation service',
                  LlmTranslator.isConfigured,
                  _providerStep,
                ),
                _stepTile(
                  1,
                  'Prepare recognition models',
                  _modelsReady,
                  _modelStep,
                ),
                _stepTile(
                  2,
                  'Enable translation for this comic',
                  _enabled,
                  _comicStep,
                ),
                if (widget.startAtMissing)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _sample(),
                  ),
                const SizedBox(height: 18),
                Text(
                  'Common questions'.tl,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _question(
                  'Why am I still seeing the original?',
                  'Check the service, the models for the source language, and the switch for this comic. The original stays visible until translation finishes. Tap the error icon in the reader to retry a failed page.',
                ),
                _question(
                  'Can I translate a whole chapter first?',
                  'After enabling translation for the comic, choose Pre-translate on its details page. Select chapters and check their progress in Tasks.',
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.menu_book_outlined),
                    onPressed: () => GuidePage.open(
                      context,
                      anchor: GuideAnchor.translation,
                    ),
                    label: Text('Full guide'.tl),
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

Future<void> _testTranslationService(
  BuildContext context,
  String targetLang,
) async {
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
    ], targetLang);
    result = res.texts.where((t) => t.isNotEmpty).join(' / ');
    if (result.isEmpty) {
      error = "The model returned an empty response".tl;
      result = null;
    }
  } catch (e) {
    error = e.toString();
  }
  if (controller.closed) return;
  controller.close();
  if (!context.mounted) return;
  await showDialog<void>(
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
