part of 'settings_page.dart';

/// Target language settings, with a shortcut to source models.
class TranslationLanguagesPage extends StatefulWidget {
  const TranslationLanguagesPage({super.key, this.sourceLang});

  final String? sourceLang;

  @override
  State<TranslationLanguagesPage> createState() =>
      _TranslationLanguagesPageState();
}

class _TranslationLanguagesPageState extends State<TranslationLanguagesPage> {
  void _editTarget([CustomTargetLanguage? existing]) async {
    var saved = await showDialog<bool>(
      context: App.rootContext,
      builder: (context) => _TargetLanguageEditor(existing: existing),
    );
    if (saved == true && mounted) setState(() {});
  }

  void _deleteTarget(CustomTargetLanguage language) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content:
          "Remove @name? Pages already translated into it are kept and show again if the same code is added back."
              .tlParams({'name': language.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        TranslationTargets.remove(language.code);
        if (mounted) setState(() {});
      },
    );
  }

  Widget _header(
    String title,
    GuideAnchor anchor, {
    String? addTooltip,
    VoidCallback? onAdd,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: context.colorScheme.primary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: "Usage guide".tl,
            onPressed: () => GuidePage.open(context, anchor: anchor),
          ),
          if (onAdd != null)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: addTooltip,
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        text,
        style: ts.s12.copyWith(color: context.colorScheme.outline),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var targets = TranslationTargets.custom;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text("Custom languages".tl)),
          _header(
            "Target languages".tl,
            GuideAnchor.translationTarget,
            addTooltip: "Add target language".tl,
            onAdd: _editTarget,
          ).toSliver(),
          if (targets.isEmpty)
            _note(
              "No custom languages yet. Tap + to add a language that is not in the list."
                  .tl,
            ).toSliver(),
          for (var language in targets)
            ListTile(
              title: Text(language.name),
              subtitle: Text(language.code),
              onTap: () => _editTarget(language),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete".tl,
                onPressed: () => _deleteTarget(language),
              ),
            ).toSliver(),
          ListTile(
            title: Text("Model management".tl),
            subtitle: Text(
              "Manage source languages and their recognition models.".tl,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.to(
              () => TranslationModelsPage(sourceLang: widget.sourceLang),
            ),
          ).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }
}

/// Add/rename dialog; saves on confirm and pops `true`. The code field is only
/// editable for a new entry.
class _TargetLanguageEditor extends StatefulWidget {
  const _TargetLanguageEditor({this.existing});

  final CustomTargetLanguage? existing;

  @override
  State<_TargetLanguageEditor> createState() => _TargetLanguageEditorState();
}

class _TargetLanguageEditorState extends State<_TargetLanguageEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _code = TextEditingController(text: widget.existing?.code ?? '');

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    var name = _name.text.trim();
    if (name.isEmpty) {
      context.showMessage(message: "Enter a language name".tl);
      return;
    }
    var code = widget.existing?.code;
    if (code == null) {
      code = TranslationTargets.normalizeCode(_code.text);
      if (code == null) {
        context.showMessage(message: "Enter a valid language code".tl);
        return;
      }
      if (TranslationTargets.isTaken(code)) {
        context.showMessage(message: "This language is already in the list".tl);
        return;
      }
    }
    TranslationTargets.save(CustomTargetLanguage(code: code, name: name));
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    var editing = widget.existing != null;
    return ContentDialog(
      title: editing ? "Edit language".tl : "Add language".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: InputDecoration(
                  labelText: "Language name".tl,
                  hintText: "e.g. ไทย, Bahasa Indonesia".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !editing,
                decoration: InputDecoration(
                  labelText: "Language code".tl,
                  hintText: "e.g. th, id, pt-BR".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                (editing
                        ? "The code cannot be changed: translations are stored under it."
                        : "The name is what the AI model translates into; write it in that language. The code is sent to Google Translate and translation scripts; use the one your service expects.")
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(onPressed: _submit, child: Text("Save".tl)),
      ],
    );
  }
}

/// Add/edit dialog for a source language; probes the download size on save
/// and pops the saved entry.
class _SourceLanguageEditor extends StatefulWidget {
  const _SourceLanguageEditor({this.existing, this.initialModel});

  final RecognitionModel? initialModel;

  final CustomSourceLanguage? existing;

  @override
  State<_SourceLanguageEditor> createState() => _SourceLanguageEditorState();
}

class _SourceLanguageEditorState extends State<_SourceLanguageEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _model = TextEditingController(
    text: (widget.existing ?? widget.initialModel)?.modelUrl ?? '',
  );
  late final _dict = TextEditingController(
    text: (widget.existing ?? widget.initialModel)?.dictUrl ?? '',
  );
  late var _height =
      (widget.existing ?? widget.initialModel)?.inputHeight ?? 48;
  var _checking = false;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _model.dispose();
    _dict.dispose();
    super.dispose();
  }

  void _applyPreset(RecognitionModel model) {
    setState(() {
      _model.text = model.modelUrl;
      _dict.text = model.dictUrl;
      _height = model.inputHeight;
    });
  }

  Future<void> _submit() async {
    var name = _name.text.trim();
    if (name.isEmpty) {
      context.showMessage(message: "Enter a language name".tl);
      return;
    }
    var code = widget.existing?.code;
    if (code == null) {
      code = TranslationTargets.normalizeCode(_code.text);
      if (code == null) {
        context.showMessage(message: "Enter a valid language code".tl);
        return;
      }
      if (TranslationSources.isTaken(code)) {
        context.showMessage(message: "This language is already in the list".tl);
        return;
      }
    }
    var model = _model.text.trim();
    var dict = _dict.text.trim();
    if (!TranslationSources.isValidUrl(model) ||
        !TranslationSources.isValidUrl(dict)) {
      context.showMessage(message: "Enter http(s) links for both files".tl);
      return;
    }
    setState(() => _checking = true);
    final known =
        [
              widget.existing,
              widget.initialModel,
              ...TranslationSources.recognitionPresets.values,
            ]
            .whereType<RecognitionModel>()
            .where((entry) => entry.modelUrl == model && entry.dictUrl == dict)
            .firstOrNull;
    int size = known?.sizeBytes ?? 0;
    if (known == null) {
      final store = TranslationModelStore.instance;
      final sizes = await Future.wait([
        store.probeSize(model),
        store.probeSize(dict),
      ]);
      if (!sizes.contains(null)) size = sizes[0]! + sizes[1]!;
    }
    if (!mounted) return;
    var language = CustomSourceLanguage(
      code: code,
      name: name,
      modelUrl: model,
      dictUrl: dict,
      inputHeight: _height,
      sizeBytes: size,
    );
    TranslationSources.save(language);
    context.pop(language);
  }

  @override
  Widget build(BuildContext context) {
    var editing = widget.existing != null;
    InputDecoration field(String label, [String? hint]) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
    );
    return ContentDialog(
      title: editing ? "Edit source language".tl : "Add source language".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: field("Language name".tl, "e.g. Français, ไทย".tl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !editing,
                decoration: field("Language code".tl, "e.g. fr, ru, th".tl),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text("Fill in a tested model:".tl, style: ts.s12),
                  for (final p in TranslationSources.recognitionPresets.entries)
                    ActionChip(
                      label: Text(p.key.tl),
                      onPressed: () => _applyPreset(p.value),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                decoration: field("Recognition model link (.onnx)".tl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _dict,
                decoration: field("Character dictionary link (.txt)".tl),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text("Input height".tl)),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 48, label: Text('48')),
                      ButtonSegment(value: 32, label: Text('32')),
                    ],
                    selected: {_height},
                    onSelectionChanged: (v) =>
                        setState(() => _height = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "Supported: PP-OCR text recognition models in ONNX format, with the character dictionary they were trained with. Paddle, MNN or PyTorch files and other model types do not work. Input height is 48 for PP-OCRv3 and later, 32 for older models. The model is checked after download and removed if it does not fit. Larger models are more accurate but load slower and use more memory."
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(
          isLoading: _checking,
          onPressed: _submit,
          child: Text("Save".tl),
        ),
      ],
    );
  }
}

/// Dialog for the custom text detection model link.
class _DetectorEditor extends StatefulWidget {
  const _DetectorEditor();

  @override
  State<_DetectorEditor> createState() => _DetectorEditorState();
}

class _DetectorEditorState extends State<_DetectorEditor> {
  final _url = TextEditingController();
  var _checking = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var url = _url.text.trim();
    if (!TranslationSources.isValidUrl(url)) {
      context.showMessage(message: "Enter an http(s) link".tl);
      return;
    }
    setState(() => _checking = true);
    var size = await TranslationModelStore.instance.probeSize(url);
    if (!mounted) return;
    var model = CustomDetectorModel(url: url, sizeBytes: size ?? 0);
    context.pop(model);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Text detection model".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _url,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: "Detection model link (.onnx)".tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "Supported: PP-OCR text detection models (DBNet) in ONNX format. It replaces the built-in detector for every language. A larger detector finds small or stylized lettering more reliably but is slower on every page."
                    .tl,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        Button.filled(
          isLoading: _checking,
          onPressed: _submit,
          child: Text("Save".tl),
        ),
      ],
    );
  }
}
