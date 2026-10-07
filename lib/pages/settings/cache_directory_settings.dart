part of 'settings_page.dart';

class ComicCacheDirectorySetting extends StatefulWidget {
  const ComicCacheDirectorySetting({super.key});

  @override
  State<ComicCacheDirectorySetting> createState() =>
      _ComicCacheDirectorySettingState();
}

class _ComicCacheDirectorySettingState
    extends State<ComicCacheDirectorySetting> {
  Future<void> _edit() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => const _CacheDirectoryEditor(),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    CacheManager();
    final pending = CacheManager.cachePath != CacheManager.configuredPath;
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text("Comic cache directory".tl)),
          const SizedBox(width: 4),
          Tooltip(
            message: "Usage guide".tl,
            child: Button.icon(
              size: 18,
              icon: const Icon(Icons.help_outline),
              onPressed: () =>
                  GuidePage.open(context, anchor: GuideAnchor.cacheDirectory),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            CacheManager.cachePath,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (pending)
            Text(
              "${"After restart".tl}: ${CacheManager.configuredPath}",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (CacheManager.startupPathError != null)
            Text(
              "The custom cache directory is unavailable. Using the default directory for this session."
                  .tl,
              style: TextStyle(color: context.colorScheme.error),
            ),
        ],
      ),
      trailing: Button.normal(
        onPressed: _edit,
        child: Text("Set".tl),
      ).fixHeight(28),
      onTap: _edit,
    );
  }
}

class _CacheDirectoryEditor extends StatefulWidget {
  const _CacheDirectoryEditor();

  @override
  State<_CacheDirectoryEditor> createState() => _CacheDirectoryEditorState();
}

class _CacheDirectoryEditorState extends State<_CacheDirectoryEditor> {
  final _controller = TextEditingController(text: CacheManager.customDirectory);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final String? path;
      if (App.isAndroid) {
        path = (await DirectoryPicker().pickDirectory())?.path;
      } else if (App.isIOS) {
        path = await selectDirectoryIOS();
      } else {
        path = await selectDirectory();
      }
      if (path != null && mounted) {
        setState(() {
          _controller.text = path!;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              "Cannot use this cache directory. Check the path, permissions and existing files."
                  .tl,
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await CacheManager.setCustomDirectory(_controller.text);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              "Cannot use this cache directory. Check the path, permissions and existing files."
                  .tl;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Comic cache directory".tl,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "A dedicated venera-cache folder is created here. Changes apply after restarting."
                    .tl,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: "Directory".tl,
                  hintText: "Leave empty to use the default directory".tl,
                  border: const OutlineInputBorder(),
                  errorText: _error,
                  errorMaxLines: 4,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _choose,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text("Choose folder".tl),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            _controller.clear();
                            _error = null;
                          }),
                    child: Text("Use default".tl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text("Cancel".tl),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text((_saving ? "Saving" : "Save").tl),
        ),
      ],
    );
  }
}
