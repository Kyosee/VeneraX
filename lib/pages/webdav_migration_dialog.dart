import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/webdav_migration_tasks.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/utils/translations.dart';

/// Shared entry point for starting a WebDAV migration of [comics], used by both
/// the local comics list (batch multi-select) and a single comic's detail page.
///
/// Handles the not-configured / already-running guards, the confirm dialog with
/// the chapter-folder naming choice, and kicking off the background task. Kept
/// in one place so the two call sites can't drift in wording or behaviour.
///
/// Returns true when a task was started (so a list page can exit select mode).
///
/// Only downloaded comics carry local images, so the input is filtered to those
/// first — an online comic that was never downloaded has nothing to upload.
Future<bool> startWebdavMigrationFlow(List<LocalComic> comics) async {
  final context = App.rootContext;
  if (comics.isEmpty) return false;
  if (!WebdavLibrary.isConfigured) {
    context.showMessage(
      message: "WebDAV comic library is not configured".tl,
    );
    return false;
  }
  var manager = WebdavMigrationTaskManager.instance;
  if (manager.hasActiveTask) {
    context.showMessage(message: "A migration task is already running".tl);
    return false;
  }
  final eligible = comics
      .where((c) => c.status == LocalComicStatus.downloaded)
      .toList();
  if (eligible.isEmpty) {
    context.showMessage(message: "No downloaded comics to migrate".tl);
    return false;
  }

  bool numericPrefix = false;
  bool confirmed = false;
  await showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Migrate to WebDAV source".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    "Migrate @count comics to WebDAV source".tlParams({
                      'count': comics.length,
                    }),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Chapter folder naming".tl,
                      style: ts.s14.bold,
                    ),
                  ),
                ),
                RadioGroup<bool>(
                  groupValue: numericPrefix,
                  onChanged: (v) =>
                      setState(() => numericPrefix = v ?? numericPrefix),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<bool>(
                        value: false,
                        title: Text("Keep original chapter titles".tl),
                        subtitle: Text(
                          "Folder names stay clean; order may differ from the app".tl,
                          style: ts.s12,
                        ),
                      ),
                      RadioListTile<bool>(
                        value: true,
                        title: Text("Keep reading order (numeric prefix)".tl),
                        subtitle: Text(
                          "Prefixes chapters with numbers so order always matches the app".tl,
                          style: ts.s12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  confirmed = true;
                  context.pop();
                },
                child: Text("Migrate".tl),
              ),
            ],
          );
        },
      );
    },
  );
  if (!confirmed || !context.mounted) return false;

  var task = manager.start(comics, numericPrefix: numericPrefix);
  if (task == null) {
    context.showMessage(message: "A migration task is already running".tl);
    return false;
  }
  App.rootContext.showMessage(
    message: "Migration started in background; see the Tasks page".tl,
  );
  return true;
}
