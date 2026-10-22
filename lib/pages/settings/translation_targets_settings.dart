part of 'settings_page.dart';

/// Lets the user add, rename and remove their own translation target
/// languages. A language's code is fixed once added: it is part of the keys
/// its translations are stored under.
class TranslationTargetsPage extends StatefulWidget {
  const TranslationTargetsPage({super.key});

  @override
  State<TranslationTargetsPage> createState() => _TranslationTargetsPageState();
}

class _TranslationTargetsPageState extends State<TranslationTargetsPage> {
  void _edit([CustomTargetLanguage? existing]) async {
    var saved = await showDialog<bool>(
      context: App.rootContext,
      builder: (context) => _TargetLanguageEditor(existing: existing),
    );
    if (saved == true && mounted) setState(() {});
  }

  void _delete(CustomTargetLanguage language) {
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

  @override
  Widget build(BuildContext context) {
    var languages = TranslationTargets.custom;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text("Custom target languages".tl),
            actions: [
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: "Usage guide".tl,
                onPressed: () => GuidePage.open(
                  context,
                  anchor: GuideAnchor.translationTarget,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: "Add language".tl,
                onPressed: _edit,
              ),
            ],
          ),
          if (languages.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 32,
                ),
                child: Text(
                  "No custom languages yet. Tap + to add a language that is not in the list."
                      .tl,
                  style: ts.s14.copyWith(color: context.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          for (var language in languages)
            ListTile(
              title: Text(language.name),
              subtitle: Text(language.code),
              onTap: () => _edit(language),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: "Delete".tl,
                onPressed: () => _delete(language),
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
