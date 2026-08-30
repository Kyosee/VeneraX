/// Ids and surface keys for the app's own patch bindings.
///
/// **This file must not import anything but `dart:core`.**
///
/// It is read by `tool/patch_tool.dart surface`, which runs under plain `dart
/// run` with no Flutter engine. Anything that transitively reaches
/// `dart:ffi`'s `NativeCallable` — which `foundation/log.dart` does, via the
/// logging sink — crashes the tool during kernel compilation with an
/// `InvalidType is not a subtype of FunctionType` failure inside the FFI
/// transformer. That is what forced the split: the dispatch table (which needs
/// `Log`) lives in `patch_bindings.dart`, and the *tables* live here where a
/// build-time tool can read them.
///
/// The two halves are pinned together by `test/patch_bindings_test.dart`, so a
/// key added here without a matching `case` — or the reverse — fails the suite
/// rather than shipping a surface that lies about what the binary binds.
library;

/// Member ids for the app's own bindings.
///
/// ## Ids are permanent
///
/// An id is baked into every payload compiled against a build that published
/// it. Renumbering silently redirects calls in already-published patches to
/// different members — the payload carries the number, not the name. So:
/// **append only, never reuse, never renumber.** A retired member keeps its id
/// and starts throwing.
///
/// App ids occupy `0x2000..0x2FFF`; core owns `0x0100..0x10FF`.
abstract final class AppPatchIds {
  // --- Logging (0x2000) ---
  static const logInfo = 0x2000;
  static const logWarning = 0x2001;
  static const logError = 0x2002;
}

/// Surface keys the compiler resolves against.
///
/// The key is what a patch author writes in Dart source — `Log.info(...)` — and
/// the compiler maps it to the id through this table. Keys are formed as
/// `Receiver.member`, matching how the compiler derives them from a call's
/// static type.
///
/// ## What belongs here
///
/// The bar is not "would a patch find this useful" — it is "is handing every
/// signed payload this capability worth what it can do with it". Each entry
/// permanently widens what a patch can reach, and this table *is* the sandbox
/// boundary: there is no second check behind the dispatch switch.
///
/// So the first batch is diagnostics only. A patch that can log can explain
/// itself in a bug report, which is the capability that makes every later patch
/// easier to trust. Nothing here reads user data, touches the filesystem, or
/// makes a request.
abstract final class AppPatchSurface {
  static const Map<String, int> members = {
    'Log.info': AppPatchIds.logInfo,
    'Log.warning': AppPatchIds.logWarning,
    'Log.error': AppPatchIds.logError,
  };

  /// No app types are bound yet.
  ///
  /// A type id is only useful for `is` / `as` / `on T catch`, and a patch cannot
  /// construct a Venera class until stage 4's user-class support lands — so
  /// publishing one now would offer a test that can never match anything a patch
  /// built itself.
  static const Map<String, int> types = <String, int>{};
}
