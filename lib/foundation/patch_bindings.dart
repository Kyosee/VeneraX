import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/patch_surface.dart';
import 'package:venera_patch/venera_patch.dart';

export 'package:venera/foundation/patch_surface.dart'
    show AppPatchIds, AppPatchSurface;

/// The app's own binding surface for patches, layered over [CoreBindings].
///
/// `venera_patch` binds `dart:core` and nothing else, on purpose: the package
/// cannot import the app. So anything a patch needs from Venera itself is bound
/// here, in the app, and composed with the core surface by [LayeredHostBridge].
///
/// The ids and the surface keys live in `patch_surface.dart` rather than here,
/// because `tool/patch_tool.dart surface` has to read them under plain `dart
/// run`: importing this file from the tool pulls in [Log], which transitively
/// reaches `dart:ffi`'s `NativeCallable` and crashes kernel compilation in the
/// FFI transformer. `test/patch_bindings_test.dart` pins the two halves
/// together.
///
/// ## Dispatch for [AppPatchIds].
///
/// A `switch` on int, like [CoreBindings], so it compiles to a jump table rather
/// than a hash lookup.
final class AppPatchBindings implements HostBridge {
  const AppPatchBindings();

  /// Ids this table answers. Range-checked rather than enumerated so adding a
  /// member is one edit, not two that can drift apart.
  @override
  bool isBound(int memberId) => memberId >= 0x2000 && memberId <= 0x2FFF;

  /// No app types are bound yet — `is`/`as` against a Venera class needs stage
  /// 4's user-class support to be useful, since a patch cannot construct one.
  @override
  bool isBoundType(int typeId) => false;

  @override
  String? describe(int memberId) => 'app#0x${memberId.toRadixString(16)}';

  @override
  bool isInstanceOf(int typeId, Object? value) =>
      throw UnboundMemberFault(typeId, 'no app binding for type #$typeId');

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> a,
    Map<String, Object?>? named,
  ) {
    switch (memberId) {
      // Logging. Title and content are stringified rather than cast, so a patch
      // passing an int or a list logs it instead of faulting — a diagnostic call
      // that throws is worse than useless, because it fires exactly when
      // something is already wrong.
      case AppPatchIds.logInfo:
        Log.info(_str(a, 0, 'Patch'), _str(a, 1, ''));
        return null;
      case AppPatchIds.logWarning:
        Log.warning(_str(a, 0, 'Patch'), _str(a, 1, ''));
        return null;
      case AppPatchIds.logError:
        Log.error(_str(a, 0, 'Patch'), _str(a, 1, ''));
        return null;
    }
    throw UnboundMemberFault(memberId);
  }

  static String _str(List<Object?> a, int i, String fallback) =>
      i < a.length ? '${a[i]}' : fallback;
}
