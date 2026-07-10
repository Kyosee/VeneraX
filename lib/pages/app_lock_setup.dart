import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/pattern_lock.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/app_lock.dart';
import 'package:venera/utils/translations.dart';

/// Guides the user through choosing an unlock method and recording its
/// credential. Returns true when a method was fully configured, false when the
/// user cancelled or setup failed (caller should then leave the lock disabled).
Future<bool> showAppLockSetup(BuildContext context) async {
  var index = await showSelectDialog(
    title: "Unlock method".tl,
    options: [
      "Biometric".tl,
      "PIN".tl,
      "Password".tl,
      "Pattern".tl,
    ],
  );
  if (index == null) return false;
  var type = AppLockType.values[index];

  switch (type) {
    case AppLockType.biometric:
      var auth = LocalAuthentication();
      var canAuthenticate =
          await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!canAuthenticate) {
        if (context.mounted) {
          context.showMessage(message: "Biometrics not supported".tl);
        }
        return false;
      }
      await AppLock.setCredential(AppLockType.biometric);
      return true;
    case AppLockType.pin:
      return _setupCode(context, isPin: true);
    case AppLockType.password:
      return _setupCode(context, isPin: false);
    case AppLockType.pattern:
      return _setupPattern(context);
  }
}

Future<bool> _setupCode(
  BuildContext context, {
  required bool isPin,
}) async {
  var result = await showDialog<bool>(
    context: context,
    builder: (context) {
      var first = TextEditingController();
      var second = TextEditingController();
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          Widget field(TextEditingController c, String hint, bool autofocus) {
            return TextField(
              controller: c,
              autofocus: autofocus,
              obscureText: true,
              keyboardType:
                  isPin ? TextInputType.number : TextInputType.text,
              inputFormatters:
                  isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            );
          }

          return ContentDialog(
            title: isPin ? "Set PIN".tl : "Set Password".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                field(first, isPin ? "Enter PIN".tl : "Enter Password".tl,
                    true),
                const SizedBox(height: 12),
                field(second, "Confirm".tl, false),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(color: context.colorScheme.error),
                  ),
                ],
              ],
            ).paddingHorizontal(12),
            actions: [
              Button.filled(
                onPressed: () async {
                  var value = first.text;
                  if (value.isEmpty) {
                    setState(() => error = "Cannot be empty".tl);
                    return;
                  }
                  if (isPin && value.length < 4) {
                    setState(() => error = "PIN must be at least 4 digits".tl);
                    return;
                  }
                  if (value != second.text) {
                    setState(() => error = "Entries do not match".tl);
                    return;
                  }
                  await AppLock.setCredential(
                    isPin ? AppLockType.pin : AppLockType.password,
                    value,
                  );
                  if (context.mounted) context.pop(true);
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        },
      );
    },
  );
  return result ?? false;
}

Future<bool> _setupPattern(BuildContext context) async {
  var result = await showDialog<bool>(
    context: context,
    builder: (context) {
      List<int>? firstPattern;
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Set Pattern".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error ??
                      (firstPattern == null
                          ? "Draw an unlock pattern".tl
                          : "Draw again to confirm".tl),
                  style: TextStyle(
                    color: error != null ? context.colorScheme.error : null,
                  ),
                ),
                const SizedBox(height: 16),
                PatternLock(
                  // Rebuild the widget between the two passes so its internal
                  // state resets cleanly.
                  key: ValueKey(firstPattern == null),
                  size: 240,
                  onComplete: (pattern) async {
                    if (pattern.length < 4) {
                      setState(() {
                        error = "Connect at least 4 dots".tl;
                      });
                      return;
                    }
                    if (firstPattern == null) {
                      setState(() {
                        firstPattern = pattern;
                        error = null;
                      });
                      return;
                    }
                    if (patternToString(pattern) !=
                        patternToString(firstPattern!)) {
                      setState(() {
                        firstPattern = null;
                        error = "Patterns do not match".tl;
                      });
                      return;
                    }
                    await AppLock.setCredential(
                      AppLockType.pattern,
                      patternToString(pattern),
                    );
                    if (context.mounted) context.pop(true);
                  },
                ),
              ],
            ).paddingHorizontal(12),
            actions: [
              TextButton(
                onPressed: () => context.pop(false),
                child: Text("Cancel".tl),
              ),
            ],
          );
        },
      );
    },
  );
  return result ?? false;
}
