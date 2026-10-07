part of 'settings_page.dart';

class _TranslationScriptEditor extends StatefulWidget {
  const _TranslationScriptEditor({required this.provider});

  final LlmProvider provider;

  @override
  State<_TranslationScriptEditor> createState() =>
      _TranslationScriptEditorState();
}

class _TranslationScriptEditorState extends State<_TranslationScriptEditor> {
  late String _script;
  int _revision = 0;
  bool _testing = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _script = widget.provider.script.isEmpty
        ? ScriptTranslator.template
        : widget.provider.script;
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final result = await ScriptTranslator.translate(
        widget.provider.copyWith(script: _script),
        ['Hello'],
        'en',
        'zh',
        timeout: const Duration(seconds: 30),
      );
      if (mounted) setState(() => _result = result.texts.single);
    } catch (e) {
      if (mounted) setState(() => _result = e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom translation script".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _script),
            child: Text("Save".tl),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                "Define translate(input). Use Network.sendRequest(method, url, headers, body) to call your API. Return {texts: [...]} in input order, with an optional glossary. Test sends Hello from English to Chinese using the current script."
                    .tl,
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                TextButton(
                  onPressed: _testing ? null : _test,
                  child: Text((_testing ? "Loading" : "Test script").tl),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _script = ScriptTranslator.template;
                    _revision++;
                  }),
                  child: Text("Reset".tl),
                ),
              ],
            ),
            if (_result != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 100),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(_result!),
                ),
              ),
            Expanded(
              child: CodeEditor(
                key: ValueKey(_revision),
                initialValue: _script,
                onChanged: (value) => _script = value,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
