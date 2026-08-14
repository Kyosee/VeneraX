import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/utils/translations.dart';

/// Per-comic glossary editor: lists the name/proper-noun translations the
/// model learned while translating this comic, and lets the user correct a
/// wrong rendering, add a term, or delete one. Edits take effect on the next
/// page/chapter without a full re-translate, so a name established wrongly on
/// an early page can be fixed in place.
class GlossaryEditorPage extends StatefulWidget {
  const GlossaryEditorPage({
    super.key,
    required this.cid,
    required this.sourceKey,
    required this.title,
  });

  final String cid;
  final String sourceKey;
  final String title;

  @override
  State<GlossaryEditorPage> createState() => _GlossaryEditorPageState();
}

class _GlossaryEditorPageState extends State<GlossaryEditorPage> {
  late List<MapEntry<String, String>> _entries;
  late List<String> _blocked;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    var service = ImageTranslationService.instance;
    _entries =
        service.glossaryOf(widget.cid, widget.sourceKey).entries.toList();
    _blocked = service.blockedTermsOf(widget.cid, widget.sourceKey);
  }

  Future<void> _editEntry({String? source, String? translation}) async {
    var sourceController = TextEditingController(text: source ?? '');
    var translationController = TextEditingController(text: translation ?? '');
    var isNew = source == null;
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: isNew ? "Add term".tl : "Edit term".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: sourceController,
              enabled: isNew,
              decoration: InputDecoration(
                labelText: "Original".tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: translationController,
              decoration: InputDecoration(
                labelText: "Translation".tl,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ).paddingHorizontal(16),
        actions: [
          FilledButton(
            onPressed: () {
              var src = sourceController.text.trim();
              var dst = translationController.text.trim();
              if (src.isEmpty || dst.isEmpty) {
                context.showMessage(message: "Both fields are required".tl);
                return;
              }
              var ok = ImageTranslationService.instance.setGlossaryEntry(
                widget.cid,
                widget.sourceKey,
                src,
                dst,
              );
              if (!ok) {
                context.showMessage(
                  message: "Term rejected: too long, or the glossary is full"
                      .tl,
                );
                return;
              }
              context.pop();
              setState(_reload);
            },
            child: Text("Save".tl),
          ),
        ],
      ),
    );
  }

  void _removeEntry(String source, {bool block = false}) {
    ImageTranslationService.instance.removeGlossaryEntry(
      widget.cid,
      widget.sourceKey,
      source,
      block: block,
    );
    setState(_reload);
  }

  void _unblock(String source) {
    ImageTranslationService.instance.unblockTerm(
      widget.cid,
      widget.sourceKey,
      source,
    );
    setState(_reload);
  }

  /// Delete vs block: a plain delete lets the term be re-learned next time the
  /// model reports it; blocking bans it for good. Ask which the user wants.
  Future<void> _confirmRemove(String source) async {
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "Remove term".tl,
        content: Text(
          "Delete only, or block it so it's never added again?".tl,
        ).paddingHorizontal(16),
        actions: [
          TextButton(
            onPressed: () {
              context.pop();
              _removeEntry(source);
            },
            child: Text("Delete".tl),
          ),
          FilledButton(
            onPressed: () {
              context.pop();
              _removeEntry(source, block: true);
            },
            child: Text("Block".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Glossary".tl),
        actions: [
          Tooltip(
            message: "Add term".tl,
            child: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _editEntry(),
            ),
          ),
        ],
      ),
      body: (_entries.isEmpty && _blocked.isEmpty)
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  LlmTranslator.activeIsPublicFree
                      ? "The no-key translation service does not use the glossary. Switch to an AI model to keep names consistent."
                            .tl
                      : "No glossary terms yet".tl,
                  style: ts.s16.withColor(context.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                if (LlmTranslator.activeIsPublicFree)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      "The no-key translation service does not use the glossary. Switch to an AI model to keep names consistent."
                          .tl,
                      style: ts.s14.withColor(context.colorScheme.outline),
                    ),
                  ),
                for (var entry in _entries)
                  ListTile(
                    title: Text(entry.key),
                    subtitle: Text(entry.value),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editEntry(
                            source: entry.key,
                            translation: entry.value,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmRemove(entry.key),
                        ),
                      ],
                    ),
                  ),
                if (_blocked.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      "Blocked terms".tl,
                      style: ts.s14.withColor(context.colorScheme.outline),
                    ),
                  ),
                  for (var term in _blocked)
                    ListTile(
                      leading: Icon(
                        Icons.block,
                        size: 20,
                        color: context.colorScheme.outline,
                      ),
                      title: Text(term),
                      trailing: TextButton(
                        onPressed: () => _unblock(term),
                        child: Text("Unblock".tl),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
