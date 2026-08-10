part of 'settings_page.dart';

/// Management page for the user's LLM translation providers: add, edit, delete,
/// and pick which one is active. Each provider is an OpenAI-compatible endpoint
/// with its own name / URL / key / model, so the user can keep several vendors
/// (or a paid account and a LAN gateway) and switch between them without
/// re-typing settings.
class LlmProvidersPage extends StatefulWidget {
  const LlmProvidersPage({super.key});

  @override
  State<LlmProvidersPage> createState() => _LlmProvidersPageState();
}

class _LlmProvidersPageState extends State<LlmProvidersPage> {
  void _refresh() {
    if (mounted) setState(() {});
  }

  void _addProvider() async {
    var provider = await _editProvider(null);
    if (provider != null) {
      LlmProviderStore.add(provider);
      _refresh();
    }
  }

  void _editExisting(LlmProvider provider) async {
    var edited = await _editProvider(provider);
    if (edited != null) {
      LlmProviderStore.update(edited);
      _refresh();
    }
  }

  void _deleteProvider(LlmProvider provider) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete this provider?".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        LlmProviderStore.remove(provider.id);
        _refresh();
      },
    );
  }

  /// Opens the add/edit sheet for [existing] (null = new) and returns the
  /// resulting provider, or null if cancelled. The dialog carries its own
  /// working copy so nothing is written until the user confirms.
  Future<LlmProvider?> _editProvider(LlmProvider? existing) {
    return showDialog<LlmProvider>(
      context: App.rootContext,
      builder: (context) => _LlmProviderEditor(existing: existing),
    );
  }

  @override
  Widget build(BuildContext context) {
    var providers = LlmProviderStore.providers;
    var activeId = LlmProviderStore.activeId;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text("LLM providers".tl),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: "Add provider".tl,
                onPressed: _addProvider,
              ),
            ],
          ),
          if (providers.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 32,
                ),
                child: Text(
                  "No providers yet. Add one to enable AI translation.".tl,
                  style: ts.s14.copyWith(color: context.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          for (var provider in providers)
            _buildProviderTile(context, provider, activeId).toSliver(),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }

  Widget _buildProviderTile(
    BuildContext context,
    LlmProvider provider,
    String activeId,
  ) {
    var subtitleParts = <String>[
      if (provider.url.isNotEmpty) provider.url,
      if (provider.model.isNotEmpty) provider.model,
    ];
    return ListTile(
      leading: Radio<String>(
        value: provider.id,
        groupValue: activeId,
        onChanged: (v) {
          LlmProviderStore.setActive(provider.id);
          _refresh();
        },
      ),
      title: Text(provider.name.isEmpty ? "Unnamed provider".tl : provider.name),
      subtitle: subtitleParts.isEmpty
          ? Text("Not configured".tl)
          : Text(subtitleParts.join('\n')),
      isThreeLine: subtitleParts.length > 1,
      onTap: () => _editExisting(provider),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _deleteProvider(provider),
      ),
    );
  }
}

/// Add/edit dialog for a single [LlmProvider]. Holds a local working copy of
/// the four editable fields and returns a fully-formed provider (preserving the
/// original id when editing) on confirm.
class _LlmProviderEditor extends StatefulWidget {
  const _LlmProviderEditor({this.existing});

  final LlmProvider? existing;

  @override
  State<_LlmProviderEditor> createState() => _LlmProviderEditorState();
}

class _LlmProviderEditorState extends State<_LlmProviderEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late String _model;

  @override
  void initState() {
    super.initState();
    var e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _key = TextEditingController(text: e?.key ?? '');
    _model = e?.model ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  /// Lets the user pick the model for the values being edited: fetch this
  /// endpoint's `/models` list and choose one, or type it by hand. Uses the URL
  /// and key currently in the fields, not the active provider's, so the list
  /// matches what is being configured.
  void _chooseModel() async {
    var url = _url.text.trim();
    if (url.isNotEmpty) {
      var controller = showLoadingDialog(
        context,
        message: "Loading".tl,
        allowCancel: false,
      );
      List<String>? models;
      try {
        models = await LlmTranslator.fetchModels(
          url: url,
          key: _key.text.trim(),
        );
      } catch (_) {
        models = null;
      }
      controller.close();
      if (!mounted) return;
      if (models != null && models.isNotEmpty) {
        _showModelPicker(models);
        return;
      }
      context.showMessage(message: "Failed to fetch model list".tl);
    }
    _enterModelManually();
  }

  void _enterModelManually() {
    showInputDialog(
      context: context,
      title: "LLM Model".tl,
      initialValue: _model,
      onConfirm: (value) {
        setState(() => _model = value.trim());
        return null;
      },
    );
  }

  void _showModelPicker(List<String> models) {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Select model".tl,
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var model in models)
                    ListTile(
                      title: Text(model),
                      trailing: model == _model
                          ? Icon(Icons.check, color: context.colorScheme.primary)
                          : null,
                      onTap: () {
                        context.pop();
                        setState(() => _model = model);
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                context.pop();
                _enterModelManually();
              },
              child: Text("Enter manually".tl),
            ),
          ],
        );
      },
    );
  }

  void _confirm() {
    var existing = widget.existing;
    var provider = LlmProvider(
      id: existing?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      url: _url.text.trim(),
      key: _key.text.trim(),
      model: _model.trim(),
    );
    context.pop(provider);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: widget.existing == null
          ? "Add provider".tl
          : "Edit provider".tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: "Name".tl,
                hintText: "e.g. OpenAI, Local gateway".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: "LLM API URL".tl,
                hintText: 'https://example.com/v1',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              decoration: InputDecoration(
                labelText: "LLM API Key".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text("LLM Model".tl),
              subtitle: Text(_model.isEmpty ? "Not configured".tl : _model),
              trailing: TextButton(
                onPressed: _chooseModel,
                child: Text("Select".tl),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text("Cancel".tl),
        ),
        Button.filled(
          onPressed: _confirm,
          child: Text("Save".tl),
        ),
      ],
    );
  }
}
