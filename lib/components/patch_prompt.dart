import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/hot_update.dart';
import 'package:venera/utils/translations.dart';

/// Tells the user a staged revision is waiting, and that it binds on restart.
///
/// The restart part is the whole reason this dialog exists. Code overrides are
/// installed once, at startup, so a revision fetched mid-session is on disk but
/// not running. Silently staging it would leave someone who just read "fixed in
/// the latest update" still looking at the bug, with no way to tell whether the
/// fix arrived — so the app would look broken twice over.
///
/// Kills and config overlays deliberately do NOT reach here: they apply the
/// moment they are fetched, and prompting for a restart that changes nothing
/// trains people to dismiss the dialog that matters.
///
/// ## Wording
///
/// Nothing in the user-visible text names the mechanism. It is a first-party
/// maintenance channel, but "hot update" and "patch" read, to a store reviewer
/// or a hostile reader, as shipping code around review — which is not what this
/// does, and a label cannot argue its case. "Fixes and adjustments" is both
/// accurate and unremarkable: a revision carries fixes, and sometimes small
/// behaviour changes, which is exactly what it says.
Future<void> showPatchPromptIfNeeded() async {
  final hot = HotUpdate.instance;
  if (!hot.hasUnannouncedPending || hot.promptShown) return;

  // Claim the flag before awaiting the dialog. Two startup paths can reach
  // this (the periodic check and the settings-page one), and an await here
  // without the claim would let both open a dialog over each other.
  hot.markPromptShown();

  final context = App.rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;

  final notes = hot.pendingNotes;
  await showDialog<void>(
    context: context,
    builder: (context) => ContentDialog(
      title: "Fixes and adjustments ready".tl,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Restart the app to apply them.".tl,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (notes != null && notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(notes),
          ],
        ],
      ),
      actions: [
        // No "restart now" button: the app cannot relaunch itself on iOS or
        // Android without looking like a crash, and offering it only on desktop
        // would make the same dialog behave differently per platform for no
        // real gain.
        FilledButton(
          onPressed: context.pop,
          child: Text("OK".tl),
        ),
      ],
    ),
  );
}
