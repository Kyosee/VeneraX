import 'dart:convert';

/// The binding surface of one app build: which host members a patch may call,
/// and the integer id each one carries.
///
/// This file is the contract between two programs that ship at different times.
/// The app build emits it; the patch compiler consumes it. Everything the
/// compiler rejects because of what it reads here is a failure that would
/// otherwise have happened on a user's device — and it would have happened
/// *midway through* a patched operation, which is the one failure mode that can
/// leave a patch worse than the bug it was written to fix.
///
/// Wire format:
///
/// ```json
/// {
///   "schema": 1,
///   "appVersion": "2.2.12",
///   "builtinPatchVersion": 0,
///   "members": { "String.indexOf": 264, "int.parse": 2816 },
///   "types":   { "String": 4096, "int": 4097 },
///   "seams":   { "backupDateFromLeadingSegment": 1 }
/// }
/// ```
class SurfaceManifest {
  const SurfaceManifest({
    required this.appVersion,
    required this.builtinPatchVersion,
    required this.members,
    required this.types,
    required this.seams,
  });

  final String appVersion;

  /// Patch versions at or below this are retired by this build. Carried here so
  /// the compiler can stamp a patch that the target app will actually accept
  /// rather than one it silently ignores.
  final int builtinPatchVersion;

  /// `Receiver.member` (or `Type.staticMember`, or a bare name for top-level
  /// functions) to member id.
  final Map<String, int> members;

  /// Type name to type id, for `is`/`as` and `on T catch`.
  final Map<String, int> types;

  /// Seam name to override id.
  final Map<String, int> seams;

  static const int supportedSchema = 1;

  static SurfaceManifest parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map) {
      throw const SurfaceError('surface manifest is not a JSON object');
    }
    final schema = json['schema'];
    if (schema != supportedSchema) {
      // Refused rather than best-effort parsed. A newer manifest may carry a
      // field whose absence changes meaning, and guessing at it would produce a
      // patch that compiles cleanly and behaves wrongly.
      throw SurfaceError(
        'unsupported surface schema $schema (this compiler reads '
        '$supportedSchema)',
      );
    }
    return SurfaceManifest(
      appVersion: json['appVersion']?.toString() ?? '',
      builtinPatchVersion: (json['builtinPatchVersion'] as num?)?.toInt() ?? 0,
      members: _intMap(json['members'], 'members'),
      types: _intMap(json['types'], 'types'),
      seams: _intMap(json['seams'], 'seams'),
    );
  }

  static Map<String, int> _intMap(Object? raw, String field) {
    if (raw == null) return const {};
    if (raw is! Map) throw SurfaceError('$field is not an object');
    final out = <String, int>{};
    for (final entry in raw.entries) {
      final v = entry.value;
      if (v is! num) {
        throw SurfaceError('$field["${entry.key}"] is not a number');
      }
      out[entry.key.toString()] = v.toInt();
    }
    return out;
  }

  String toJson() => jsonEncode({
        'schema': supportedSchema,
        'appVersion': appVersion,
        'builtinPatchVersion': builtinPatchVersion,
        'members': members,
        'types': types,
        'seams': seams,
      });

  /// Resolves a member, or throws naming what is missing and how to add it.
  ///
  /// The message matters more than it looks. This is the error a patch author
  /// hits most often, and the useful answer is never "not found" — it is "this
  /// build cannot reach that API, so either use one it can or ship a release
  /// that binds it."
  int requireMember(String key, {String? context}) {
    final id = members[key];
    if (id != null) return id;
    final near = _nearby(key, members.keys);
    throw SurfaceError(
      'no binding for `$key`${context == null ? '' : ' (at $context)'}.\n'
      '  This app build cannot reach that member, so a patch calling it would '
      'fail on the device.\n'
      '${near.isEmpty ? '' : '  Did you mean: ${near.join(', ')}?\n'}'
      '  To use it, add a binding and ship a release that includes it.',
    );
  }

  int requireType(String name, {String? context}) {
    final id = types[name];
    if (id != null) return id;
    final near = _nearby(name, types.keys);
    throw SurfaceError(
      'no binding for type `$name`'
      '${context == null ? '' : ' (at $context)'}.\n'
      '${near.isEmpty ? '' : '  Did you mean: ${near.join(', ')}?\n'}'
      '  Type tests go through the bridge, so a patch cannot name a type this '
      'build was not given.',
    );
  }

  int requireSeam(String name) {
    final id = seams[name];
    if (id != null) return id;
    final near = _nearby(name, seams.keys);
    throw SurfaceError(
      'no seam named `$name` in this build.\n'
      '${near.isEmpty ? '' : '  Did you mean: ${near.join(', ')}?\n'}'
      '  A patch can only take over a function that carries a seam.',
    );
  }

  /// Cheap suggestion list: same suffix after the dot, or a shared prefix.
  /// Deliberately not a full edit-distance search — the point is to catch a
  /// typo or a wrong receiver, not to be clever.
  static List<String> _nearby(String key, Iterable<String> candidates) {
    final lower = key.toLowerCase();
    final tail = key.contains('.') ? key.split('.').last.toLowerCase() : lower;
    final hits = <String>[];
    for (final c in candidates) {
      final cl = c.toLowerCase();
      if (cl == lower) continue;
      final ctail = c.contains('.') ? c.split('.').last.toLowerCase() : cl;
      if (ctail == tail || cl.startsWith(lower) || lower.startsWith(cl)) {
        hits.add(c);
        if (hits.length >= 4) break;
      }
    }
    return hits;
  }
}

/// A patch could not be compiled against the target build's surface.
class SurfaceError implements Exception {
  const SurfaceError(this.message);

  final String message;

  @override
  String toString() => message;
}
