import 'errors.dart';

/// The sandbox boundary.
///
/// AOT Dart has no reflection, so interpreted code cannot reach host members on
/// its own — every crossing goes through a generated dispatch table. That
/// constraint, forced on us by AOT, is also the security model: auditing what a
/// patch can possibly touch means reading one generated file. There is no
/// reflection, no FFI, no `Process`, and no string `eval` on the other side.
///
/// Members are addressed by integer id rather than name: the generated switch
/// compiles to a jump table, ids keep the payload small, and a renamed host
/// member becomes a manifest-hash mismatch at patch-build time instead of a
/// silent runtime miss.
abstract interface class HostBridge {
  /// Invokes host member [memberId].
  ///
  /// [receiver] is null for statics and top-level functions. [positional] holds
  /// evaluated arguments; [named] is null when the call site passes none, so the
  /// common case allocates no map.
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> positional,
    Map<String, Object?>? named,
  );

  /// Whether [memberId] is bound. Used at load time so a bundle referencing a
  /// missing member is rejected before it runs, not midway through.
  bool isBound(int memberId);

  /// Human-readable name for [memberId], for diagnostics. May return null.
  String? describe(int memberId);

  /// Whether [value] is an instance of host type [typeId].
  ///
  /// `is` and `as` need this because AOT Dart cannot test against a type it only
  /// knows by name — the generated table holds a real `v is Foo` per bound type.
  /// Routing type tests through the same boundary as calls keeps the audit
  /// surface a single file: a patch cannot name a type it was not given.
  bool isInstanceOf(int typeId, Object? value);

  /// Whether [typeId] is bound, for load-time validation.
  ///
  /// Without this the loader can parse a type id but not check it, and an
  /// unbound one surfaces from [isInstanceOf] *during exception handling* —
  /// precisely the "fails with side effects already applied" case load-time
  /// validation exists to prevent.
  bool isBoundType(int typeId);
}

/// A bridge with nothing bound.
///
/// Used by tests that exercise pure computation, and as the fail-closed default:
/// a VM constructed without an explicit bridge can reach nothing at all.
final class EmptyHostBridge implements HostBridge {
  const EmptyHostBridge();

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> positional,
    Map<String, Object?>? named,
  ) {
    throw UnboundMemberFault(memberId);
  }

  @override
  bool isBound(int memberId) => false;

  @override
  String? describe(int memberId) => null;

  @override
  bool isInstanceOf(int typeId, Object? value) =>
      throw UnboundMemberFault(typeId, 'no binding for type #$typeId');

  @override
  bool isBoundType(int typeId) => false;
}

/// A bridge assembled from closures, for tests and for the small hand-written
/// core surface. The generated table implements [HostBridge] directly instead —
/// a `switch` on int compiles to a jump table, while a map costs a hash lookup
/// on every crossing.
final class MapHostBridge implements HostBridge {
  MapHostBridge(
    this._entries, [
    this._names = const {},
    this._types = const {},
  ]);

  final Map<int, HostInvoke> _entries;
  final Map<int, String> _names;

  /// Type predicates by id. Generated code emits a real `value is T` per entry;
  /// a map of closures is the test-friendly equivalent.
  final Map<int, HostTypePredicate> _types;

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> positional,
    Map<String, Object?>? named,
  ) {
    final fn = _entries[memberId];
    if (fn == null) throw UnboundMemberFault(memberId);
    return fn(receiver, positional, named);
  }

  @override
  bool isBound(int memberId) => _entries.containsKey(memberId);

  @override
  String? describe(int memberId) => _names[memberId];

  @override
  bool isInstanceOf(int typeId, Object? value) {
    final test = _types[typeId];
    if (test == null) {
      throw UnboundMemberFault(typeId, 'no binding for type #$typeId');
    }
    return test(value);
  }

  @override
  bool isBoundType(int typeId) => _types.containsKey(typeId);
}

typedef HostInvoke = Object? Function(
  Object? receiver,
  List<Object?> positional,
  Map<String, Object?>? named,
);

/// A single type predicate. Generated code emits `value is T` directly; this
/// closure form exists for tests and the hand-written core surface.
typedef HostTypePredicate = bool Function(Object? value);
