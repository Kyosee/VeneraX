import 'dart:convert';

import 'errors.dart';
import 'expr.dart';
import 'frame.dart';
import 'function.dart';
import 'host.dart';
import 'stmt.dart';

/// Deserialises a VIR payload into executable [VmFunction]s.
///
/// This is where a malformed bundle must die. Every id, index and slot is range
/// checked *before* anything runs, so a corrupt payload can never fail halfway
/// through a patched operation with side effects already applied — the failure
/// mode that would make a patch strictly worse than the bug it replaces.
///
/// Validation is not a defence against a hostile bundle: only our own signing
/// key can produce one, and the signature is checked before we get here. It
/// guards against *our own* tooling being inconsistent with the binary it
/// targets, which is a real and recurring risk across app versions.
final class VirLoader {
  VirLoader({required this.host, this.limits = VmLimits.standard});

  final HostBridge host;
  final VmLimits limits;

  /// Wire-format version. An unknown (newer) version is refused rather than
  /// best-effort parsed: silently ignoring a field we do not understand is how a
  /// patch ends up doing something subtly different from what it declares.
  static const int supportedVersion = 1;

  /// Loads a program from decoded JSON.
  VmProgram load(Object? raw) {
    final root = _map(raw, 'payload');
    final version = _int(root['version'], 'version');
    if (version != supportedVersion) {
      throw PatchLoadFault(
        'unsupported VIR version $version (this build reads $supportedVersion)',
      );
    }

    final rawFunctions = _list(root['functions'], 'functions');
    if (rawFunctions.isEmpty) {
      throw const PatchLoadFault('payload declares no functions');
    }

    // Two passes. Signatures first, so a body that calls a function defined
    // later in the list can resolve it: single-pass loading would leave forward
    // and mutual recursion holding a null target.
    final refs = <VmFunctionRef>[];
    final built = <VmFunction>[];
    for (var i = 0; i < rawFunctions.length; i++) {
      final fn = _signature(_map(rawFunctions[i], 'functions[$i]'), i);
      built.add(fn);
      refs.add(VmFunctionRef(i)..target = fn);
    }

    final ctx = CompileContext(host: host, limits: limits, functions: refs);

    for (var i = 0; i < rawFunctions.length; i++) {
      final json = _map(rawFunctions[i], 'functions[$i]');
      final fn = built[i];
      final slotCount = fn.slotCount;

      final rawDefaults = json['defaults'];
      if (rawDefaults != null) {
        final defaults = _map(rawDefaults, 'functions[$i].defaults');
        for (final entry in defaults.entries) {
          final slot = int.tryParse(entry.key);
          if (slot == null || slot < 0 || slot >= slotCount) {
            throw PatchLoadFault(
              'functions[$i].defaults has out-of-range slot "${entry.key}" '
              '(slotCount $slotCount)',
            );
          }
          fn.defaults[slot] =
              _expr(entry.value, 'functions[$i].defaults[$slot]', slotCount)
                  .compile(ctx);
        }
      }

      final bodyNode = _stmt(json['body'], 'functions[$i].body', slotCount);
      if (fn.isAsync) {
        fn.asyncBody = bodyNode.compileAsyncOrWrap(ctx);
      } else {
        // The sync path. An `await` reached from here throws PatchLoadFault, so
        // a payload marked sync while containing an await is rejected now rather
        // than leaking a Future where a value was expected.
        fn.body = bodyNode.compile(ctx);
      }
    }

    final overrides = <int, int>{};
    final rawOverrides = _map(root['overrides'], 'overrides');
    for (final entry in rawOverrides.entries) {
      final id = int.tryParse(entry.key);
      if (id == null) {
        throw PatchLoadFault('overrides key "${entry.key}" is not an int');
      }
      final index = _int(entry.value, 'overrides[$id]');
      if (index < 0 || index >= built.length) {
        throw PatchLoadFault(
          'overrides[$id] points at function $index, '
          'but the payload defines ${built.length}',
        );
      }
      overrides[id] = index;
    }
    if (overrides.isEmpty) {
      throw const PatchLoadFault('payload claims no overrides');
    }

    return VmProgram(functions: built, overrides: overrides);
  }

  /// Loads from a JSON string.
  VmProgram loadJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (e) {
      throw PatchLoadFault('payload is not valid JSON: $e');
    }
    return load(decoded);
  }

  // -------------------------------------------------------------------------
  // Signatures
  // -------------------------------------------------------------------------

  VmFunction _signature(Map<String, Object?> json, int index) {
    final path = 'functions[$index]';
    final slotCount = _int(json['slotCount'], '$path.slotCount');
    if (slotCount < 0 || slotCount > 4096) {
      throw PatchLoadFault('$path.slotCount $slotCount out of range');
    }
    final requiredCount = _int(json['requiredCount'], '$path.requiredCount');
    final optionalCount = json['optionalCount'] == null
        ? 0
        : _int(json['optionalCount'], '$path.optionalCount');
    if (requiredCount < 0 || optionalCount < 0) {
      throw PatchLoadFault('$path has a negative parameter count');
    }

    final namedSlots = <String, int>{};
    final rawNamed = json['namedSlots'];
    if (rawNamed != null) {
      final map = _map(rawNamed, '$path.namedSlots');
      for (final entry in map.entries) {
        final slot = _int(entry.value, '$path.namedSlots["${entry.key}"]');
        if (slot < 0 || slot >= slotCount) {
          throw PatchLoadFault(
            '$path.namedSlots["${entry.key}"] = $slot is outside '
            'slotCount $slotCount',
          );
        }
        namedSlots[entry.key] = slot;
      }
    }

    // Parameters occupy the leading slots, so a frame too small to hold them
    // would corrupt neighbouring locals rather than fail visibly.
    if (requiredCount + optionalCount > slotCount) {
      throw PatchLoadFault(
        '$path declares ${requiredCount + optionalCount} positional '
        'parameters but only $slotCount slots',
      );
    }

    return VmFunction(
      name: json['name']?.toString() ?? 'fn$index',
      slotCount: slotCount,
      requiredCount: requiredCount,
      optionalCount: optionalCount,
      namedSlots: namedSlots,
      limits: limits,
      isAsync: json['isAsync'] == true,
    );
  }

  // -------------------------------------------------------------------------
  // Expressions
  // -------------------------------------------------------------------------

  Expr _expr(Object? raw, String path, int slotCount) {
    final json = _map(raw, path);
    final kind = json['k']?.toString();
    if (kind == null) throw PatchLoadFault('$path has no kind');

    switch (kind) {
      case 'lit':
        return Literal(_literalValue(json['v'], '$path.v'));

      case 'local':
        return LocalGet(_slot(json['slot'], '$path.slot', slotCount));

      case 'bin':
        return Binary(
          _enumValue(BinOp.values, json['op'], '$path.op'),
          _expr(json['l'], '$path.l', slotCount),
          _expr(json['r'], '$path.r', slotCount),
        );

      case 'un':
        return Unary(
          _enumValue(UnOp.values, json['op'], '$path.op'),
          _expr(json['v'], '$path.v', slotCount),
        );

      case 'cond':
        return Conditional(
          _expr(json['c'], '$path.c', slotCount),
          _expr(json['t'], '$path.t', slotCount),
          _expr(json['e'], '$path.e', slotCount),
        );

      case 'hostCall':
        final memberId = _int(json['id'], '$path.id');
        // Checked here as well as at compile time so the diagnostic names the
        // payload path, not just the id.
        if (!host.isBound(memberId)) {
          throw UnboundMemberFault(
            memberId,
            '$path calls unbound member #$memberId',
          );
        }
        return HostCall(
          memberId,
          receiver: json['recv'] == null
              ? null
              : _expr(json['recv'], '$path.recv', slotCount),
          args: _exprList(json['args'], '$path.args', slotCount),
          named: _exprMap(json['named'], '$path.named', slotCount),
        );

      case 'vmCall':
        return VmCall(
          _int(json['fn'], '$path.fn'),
          args: _exprList(json['args'], '$path.args', slotCount),
          named: _exprMap(json['named'], '$path.named', slotCount),
        );

      case 'list':
        return ListLiteral(
          _exprList(json['items'], '$path.items', slotCount),
        );

      case 'map':
        final entries = <(Expr, Expr)>[];
        final items = _list(json['entries'], '$path.entries');
        for (var i = 0; i < items.length; i++) {
          final pair = _list(items[i], '$path.entries[$i]');
          if (pair.length != 2) {
            throw PatchLoadFault('$path.entries[$i] is not a key/value pair');
          }
          entries.add((
            _expr(pair[0], '$path.entries[$i][0]', slotCount),
            _expr(pair[1], '$path.entries[$i][1]', slotCount),
          ));
        }
        return MapLiteral(entries);

      case 'set':
        return SetLiteral(_exprList(json['items'], '$path.items', slotCount));

      case 'interp':
        return StringInterp(_exprList(json['parts'], '$path.parts', slotCount));

      case 'index':
        return IndexGet(
          _expr(json['target'], '$path.target', slotCount),
          _expr(json['index'], '$path.index', slotCount),
        );

      case 'is':
        return TypeTest(
          _expr(json['v'], '$path.v', slotCount),
          _enumValue(VmType.values, json['type'], '$path.type'),
          negated: json['not'] == true,
        );

      case 'isHost':
        return HostTypeTest(
          _expr(json['v'], '$path.v', slotCount),
          _typeId(json['type'], '$path.type'),
          negated: json['not'] == true,
        );

      case 'notNull':
        return NotNull(_expr(json['v'], '$path.v', slotCount));

      case 'await':
        // Whether this is legal depends on the enclosing function: an await in a
        // function not marked `isAsync` reaches AwaitExpr.compile(), which
        // throws. Rejecting it here instead would need the loader to track async
        // context through every nesting level, and the sync path already refuses
        // it at exactly the right moment.
        return AwaitExpr(_expr(json['v'], '$path.v', slotCount));

      default:
        throw PatchLoadFault('$path has unknown expression kind "$kind"');
    }
  }

  /// An expression that can be assigned to. Kept separate so an assignment to
  /// a non-assignable target is a load-time failure with a clear message rather
  /// than a cast error deep inside compilation.
  Assignable _assignable(Object? raw, String path, int slotCount) {
    final expr = _expr(raw, path, slotCount);
    if (expr is! Assignable) {
      throw PatchLoadFault('$path is not assignable');
    }
    return expr;
  }

  List<Expr> _exprList(Object? raw, String path, int slotCount) {
    if (raw == null) return const [];
    final items = _list(raw, path);
    return [
      for (var i = 0; i < items.length; i++)
        _expr(items[i], '$path[$i]', slotCount),
    ];
  }

  Map<String, Expr> _exprMap(Object? raw, String path, int slotCount) {
    if (raw == null) return const {};
    final map = _map(raw, path);
    return {
      for (final entry in map.entries)
        entry.key: _expr(entry.value, '$path["${entry.key}"]', slotCount),
    };
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  Stmt _stmt(Object? raw, String path, int slotCount) {
    final json = _map(raw, path);
    final kind = json['k']?.toString();
    if (kind == null) throw PatchLoadFault('$path has no kind');

    switch (kind) {
      case 'block':
        return BlockStmt(_stmtList(json['body'], '$path.body', slotCount));

      case 'expr':
        return ExprStmt(_expr(json['e'], '$path.e', slotCount));

      case 'var':
        return VarDecl(
          _slot(json['slot'], '$path.slot', slotCount),
          json['init'] == null
              ? null
              : _expr(json['init'], '$path.init', slotCount),
        );

      case 'assign':
        return AssignStmt(
          _assignable(json['target'], '$path.target', slotCount),
          _expr(json['value'], '$path.value', slotCount),
        );

      case 'if':
        return IfStmt(
          _expr(json['c'], '$path.c', slotCount),
          _stmt(json['then'], '$path.then', slotCount),
          json['else'] == null
              ? null
              : _stmt(json['else'], '$path.else', slotCount),
        );

      case 'switch':
        final cases = <SwitchCase>[];
        final rawCases = _list(json['cases'], '$path.cases');
        for (var i = 0; i < rawCases.length; i++) {
          final c = _map(rawCases[i], '$path.cases[$i]');
          final values = _list(c['values'], '$path.cases[$i].values');
          cases.add(SwitchCase(
            [
              // Case labels are constants in Dart, so they arrive as raw JSON
              // values rather than expression nodes.
              for (var j = 0; j < values.length; j++)
                Literal(
                  _literalValue(values[j], '$path.cases[$i].values[$j]'),
                ),
            ],
            _stmt(c['body'], '$path.cases[$i].body', slotCount),
          ));
        }
        return SwitchStmt(
          _expr(json['selector'], '$path.selector', slotCount),
          cases,
          json['default'] == null
              ? null
              : _stmt(json['default'], '$path.default', slotCount),
        );

      case 'while':
        return WhileStmt(
          _expr(json['c'], '$path.c', slotCount),
          _stmt(json['body'], '$path.body', slotCount),
        );

      case 'doWhile':
        return DoWhileStmt(
          _stmt(json['body'], '$path.body', slotCount),
          _expr(json['c'], '$path.c', slotCount),
        );

      case 'for':
        return ForStmt(
          init: json['init'] == null
              ? null
              : _stmt(json['init'], '$path.init', slotCount),
          condition: json['c'] == null
              ? null
              : _expr(json['c'], '$path.c', slotCount),
          update: _stmtList(json['update'], '$path.update', slotCount),
          body: _stmt(json['body'], '$path.body', slotCount),
        );

      case 'forIn':
        return ForInStmt(
          _slot(json['slot'], '$path.slot', slotCount),
          _expr(json['iterable'], '$path.iterable', slotCount),
          _stmt(json['body'], '$path.body', slotCount),
        );

      case 'return':
        return ReturnStmt(
          json['v'] == null ? null : _expr(json['v'], '$path.v', slotCount),
        );

      case 'break':
        return const BreakStmt();

      case 'continue':
        return const ContinueStmt();

      case 'throw':
        return ThrowStmt(_expr(json['v'], '$path.v', slotCount));

      case 'try':
        final catches = <CatchClause>[];
        final rawCatches = json['catches'];
        if (rawCatches != null) {
          final items = _list(rawCatches, '$path.catches');
          for (var i = 0; i < items.length; i++) {
            final c = _map(items[i], '$path.catches[$i]');
            catches.add(CatchClause(
              typeId: c['type'] == null
                  ? null
                  : _typeId(c['type'], '$path.catches[$i].type'),
              exceptionSlot: c['e'] == null
                  ? null
                  : _slot(c['e'], '$path.catches[$i].e', slotCount),
              stackSlot: c['st'] == null
                  ? null
                  : _slot(c['st'], '$path.catches[$i].st', slotCount),
              body: _stmt(c['body'], '$path.catches[$i].body', slotCount),
            ));
          }
        }
        return TryStmt(
          body: _stmt(json['body'], '$path.body', slotCount),
          catches: catches,
          finallyBlock: json['finally'] == null
              ? null
              : _stmt(json['finally'], '$path.finally', slotCount),
        );

      case 'assert':
        return AssertStmt(
          _expr(json['c'], '$path.c', slotCount),
          json['msg'] == null
              ? null
              : _expr(json['msg'], '$path.msg', slotCount),
        );

      default:
        throw PatchLoadFault('$path has unknown statement kind "$kind"');
    }
  }

  List<Stmt> _stmtList(Object? raw, String path, int slotCount) {
    if (raw == null) return const [];
    final items = _list(raw, path);
    return [
      for (var i = 0; i < items.length; i++)
        _stmt(items[i], '$path[$i]', slotCount),
    ];
  }

  // -------------------------------------------------------------------------
  // Primitives
  // -------------------------------------------------------------------------

  /// A slot index, checked against the frame size.
  ///
  /// An out-of-range slot is the most dangerous malformation in the format: the
  /// frame is a fixed-length list, so an unchecked index either throws deep in
  /// execution or — worse, if it happened to land in range — silently reads and
  /// writes an unrelated local.
  int _slot(Object? raw, String path, int slotCount) {
    final slot = _int(raw, path);
    if (slot < 0 || slot >= slotCount) {
      throw PatchLoadFault('$path = $slot is outside slotCount $slotCount');
    }
    return slot;
  }

  /// Literal payload values are restricted to JSON scalars.
  ///
  /// Anything richer would mean the payload could construct objects the host
  /// never sanctioned, which is exactly what the dispatch table exists to
  /// prevent.
  Object? _literalValue(Object? raw, String path) {
    if (raw == null || raw is num || raw is String || raw is bool) return raw;
    throw PatchLoadFault(
      '$path has non-scalar literal of type ${raw.runtimeType}',
    );
  }

  Map<String, Object?> _map(Object? raw, String path) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    throw PatchLoadFault('$path is not an object (got ${raw.runtimeType})');
  }

  List<Object?> _list(Object? raw, String path) {
    if (raw is List) return raw;
    throw PatchLoadFault('$path is not a list (got ${raw.runtimeType})');
  }

  int _int(Object? raw, String path) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    throw PatchLoadFault('$path is not an int (got ${raw.runtimeType})');
  }

  T _enumValue<T extends Enum>(List<T> values, Object? raw, String path) {
    final name = raw?.toString();
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw PatchLoadFault('$path has unknown value "$name"');
  }

  /// A host type id, checked against the bridge at load time.
  ///
  /// Without this check an unbound type id survives loading and only fails when
  /// the type test actually runs — for a `catch` clause that means *during
  /// exception handling*, with the patched operation already half-applied. That
  /// is precisely the failure mode this loader exists to prevent.
  int _typeId(Object? raw, String path) {
    final id = _int(raw, path);
    if (!host.isBoundType(id)) {
      throw UnboundMemberFault(id, '$path names unbound type #$id');
    }
    return id;
  }
}
