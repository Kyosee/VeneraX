import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

import 'surface.dart';

/// Compiles patch source (ordinary Dart) into VIR.
///
/// This program never ships in the app. That is the point: the release binary
/// contains an interpreter and nothing else — no analyzer, no compiler, and no
/// path from a string to executable code. Compilation happens here, once, on a
/// machine we control, against the [SurfaceManifest] of the build being targeted.
///
/// ## Why compile at all, rather than interpret source on device
///
/// Three reasons, in order of weight:
///
/// 1. **Every rejection moves off the user's device.** An unbound member, a
///    misspelled seam, a payload aimed at the wrong build: all of it fails here,
///    with a message naming the file and line, instead of failing mid-operation
///    in the field.
/// 2. **Audit surface.** Shipping an analyzer would mean shipping the machinery
///    to turn arbitrary text into behaviour. Shipping a loader for a validated
///    node format does not.
/// 3. **Size and startup.** The analyzer is larger than the entire runtime it
///    would be serving.
///
/// ## Await lowering
///
/// The VM supports `await` in statement position only. Anything nested —
/// `f(await a(), await b())`, `1 + await x()` — is hoisted here into temporary
/// slots:
///
/// ```dart
/// var y = 1 + await foo();
/// // becomes
/// var _t0 = await foo();
/// var y = 1 + _t0;
/// ```
///
/// The complexity lives in this program, which does not ship, rather than in the
/// interpreter, which does. And the VM fails *loudly* if this ever gets it
/// wrong: the synchronous compile path for an await node throws a load fault, so
/// a missed hoist is a load-time error with a clear message, never a Future
/// leaking out where a value was expected.
class PatchCompiler {
  PatchCompiler(this.surface);

  final SurfaceManifest surface;

  /// Compiles [paths] into a VIR payload.
  ///
  /// Every top-level function annotated `@PatchOverride('seamName')` becomes an
  /// override. Other top-level functions are compiled too, so a patch can be
  /// factored into helpers rather than crammed into one function.
  Future<Map<String, Object?>> compileFiles(List<String> paths) async {
    final absolute = [for (final path in paths) p.normalize(p.absolute(path))];
    final collection = AnalysisContextCollection(includedPaths: absolute);

    final units = <CompilationUnit>[];
    for (final path in absolute) {
      final context = collection.contextFor(path);
      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        throw PatchCompileError('could not resolve $path');
      }
      // Analysis errors first, always. Compiling on top of a file the analyzer
      // could not make sense of produces a patch whose behaviour nobody
      // predicted.
      final blocking = result.diagnostics
          .where((d) => d.severity.name.toLowerCase() == 'error')
          .toList();
      if (blocking.isNotEmpty) {
        final detail = blocking
            .take(10)
            .map((d) => '  ${p.basename(path)}:'
                '${result.lineInfo.getLocation(d.offset).lineNumber}: '
                '${d.message}')
            .join('\n');
        throw PatchCompileError(
          'patch source has ${blocking.length} analysis error(s):\n$detail',
        );
      }
      units.add(result.unit);
    }

    // Two passes, so a function may call one declared later in the file.
    final declarations = <String, FunctionDeclaration>{};
    for (final unit in units) {
      for (final decl in unit.declarations) {
        if (decl is FunctionDeclaration) {
          declarations[decl.name.lexeme] = decl;
        } else {
          throw PatchCompileError(
            'only top-level functions are supported in a patch; found '
            '${decl.runtimeType} at line '
            '${_line(unit, decl.offset)}',
          );
        }
      }
    }
    if (declarations.isEmpty) {
      throw const PatchCompileError('patch declares no functions');
    }

    final names = declarations.keys.toList(growable: false);
    final indexOf = {for (var i = 0; i < names.length; i++) names[i]: i};

    final functions = <Map<String, Object?>>[];
    final overrides = <String, int>{};

    for (var i = 0; i < names.length; i++) {
      final decl = declarations[names[i]]!;
      final fn = _FunctionCompiler(
        surface: surface,
        functionIndex: indexOf,
        declaration: decl,
      ).compile();
      functions.add(fn);

      final seam = _seamName(decl);
      if (seam != null) {
        overrides['${surface.requireSeam(seam)}'] = i;
      }
    }

    if (overrides.isEmpty) {
      throw const PatchCompileError(
        'patch claims no overrides.\n'
        '  Annotate the entry function with @PatchOverride(\'<seamName>\') so '
        'the runtime knows which seam it replaces.',
      );
    }

    return {
      'version': 1,
      'functions': functions,
      'overrides': overrides,
    };
  }

  /// Reads the seam name out of `@PatchOverride('name')`.
  static String? _seamName(FunctionDeclaration decl) {
    for (final annotation in decl.metadata) {
      if (annotation.name.name != 'PatchOverride') continue;
      final args = annotation.arguments?.arguments;
      if (args == null || args.isEmpty) {
        throw PatchCompileError(
          '@PatchOverride on `${decl.name.lexeme}` needs a seam name, e.g. '
          "@PatchOverride('backupDateFromLeadingSegment')",
        );
      }
      final first = args.first;
      if (first is! SimpleStringLiteral) {
        throw PatchCompileError(
          '@PatchOverride on `${decl.name.lexeme}` needs a literal string seam '
          'name',
        );
      }
      return first.value;
    }
    return null;
  }

  static int _line(CompilationUnit unit, int offset) =>
      unit.lineInfo.getLocation(offset).lineNumber;
}

/// Compiles one function body.
///
/// Slot allocation happens here: every local, parameter and hoisted temporary
/// gets a fixed index, and nothing is ever looked up by name at runtime.
class _FunctionCompiler {
  _FunctionCompiler({
    required this.surface,
    required this.functionIndex,
    required this.declaration,
  });

  final SurfaceManifest surface;
  final Map<String, int> functionIndex;
  final FunctionDeclaration declaration;

  /// Lexical scopes of name to slot. A nested block shadows by pushing a map;
  /// distinct slots mean shadowing needs no runtime support.
  final List<Map<String, int>> _scopes = [{}];
  int _nextSlot = 0;
  int _slotCount = 0;

  /// Statements hoisted out of the expression currently being compiled, in
  /// order. Drained by [_statement] into a wrapping block.
  List<Map<String, Object?>>? _prelude;

  Map<String, Object?> compile() {
    final name = declaration.name.lexeme;
    final expression = declaration.functionExpression;
    final params = expression.parameters?.parameters ?? const [];

    var required = 0;
    var optional = 0;
    final namedSlots = <String, int>{};
    final defaults = <String, Map<String, Object?>>{};

    for (final param in params) {
      final pname = param.name?.lexeme;
      if (pname == null) {
        throw PatchCompileError('$name has an unnamed parameter');
      }
      final slot = _declare(pname);
      if (param.isNamed) {
        namedSlots[pname] = slot;
      } else if (param.isOptionalPositional) {
        optional++;
      } else {
        required++;
      }
      final defaultValue = param.defaultClause?.value;
      if (defaultValue != null) {
        // Defaults are evaluated against the callee's own frame, so they compile
        // like any other expression — but they may not await: there is no
        // suspension point before the body starts.
        final saved = _prelude;
        _prelude = [];
        final node = _expression(defaultValue);
        if (_prelude!.isNotEmpty) {
          throw PatchCompileError(
            'the default value for `$pname` in `$name` cannot await',
          );
        }
        _prelude = saved;
        defaults['$slot'] = node;
      }
    }

    final body = expression.body;
    final isAsync = body.isAsynchronous;
    if (body.isGenerator) {
      throw PatchCompileError(
        '`$name` is a generator (sync*/async*), which the interpreter does not '
        'support. Return a List or a Future instead.',
      );
    }

    final Map<String, Object?> compiledBody;
    if (body is BlockFunctionBody) {
      compiledBody = _block(body.block.statements);
    } else if (body is ExpressionFunctionBody) {
      compiledBody = _statement(
        _return(body.expression),
      );
    } else {
      throw PatchCompileError('`$name` has an unsupported body');
    }

    return {
      'name': name,
      'slotCount': _slotCount,
      'requiredCount': required,
      'optionalCount': optional,
      if (namedSlots.isNotEmpty) 'namedSlots': namedSlots,
      if (defaults.isNotEmpty) 'defaults': defaults,
      if (isAsync) 'isAsync': true,
      'body': compiledBody,
    };
  }

  // -------------------------------------------------------------------------
  // Scopes and slots
  // -------------------------------------------------------------------------

  int _declare(String name) {
    final slot = _nextSlot++;
    if (_nextSlot > _slotCount) _slotCount = _nextSlot;
    _scopes.last[name] = slot;
    return slot;
  }

  /// A slot for a compiler-generated temporary. Never collides with a source
  /// name because the key is not a valid Dart identifier.
  int _temp() => _declare('#t${_nextSlot}');

  int? _lookup(String name) {
    for (var i = _scopes.length - 1; i >= 0; i--) {
      final slot = _scopes[i][name];
      if (slot != null) return slot;
    }
    return null;
  }

  void _pushScope() => _scopes.add({});

  void _popScope() {
    final scope = _scopes.removeLast();
    // Slots are *not* reused when a scope ends. Reuse would shrink frames a
    // little and make a stale read return a live unrelated value instead of
    // null — a debugging cost far larger than the memory saved.
    scope.clear();
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  /// Compiles one statement, wrapping it with anything its expressions hoisted.
  Map<String, Object?> _statement(Map<String, Object?> Function() build) {
    final saved = _prelude;
    _prelude = [];
    final stmt = build();
    final hoisted = _prelude!;
    _prelude = saved;
    if (hoisted.isEmpty) return stmt;
    return {'k': 'block', 'body': [...hoisted, stmt]};
  }

  Map<String, Object?> Function() _return(Expression? value) => () => {
        'k': 'return',
        if (value != null) 'v': _expression(value),
      };

  Map<String, Object?> _block(List<Statement> statements) {
    _pushScope();
    final body = [for (final s in statements) _stmt(s)];
    _popScope();
    return {'k': 'block', 'body': body};
  }

  Map<String, Object?> _stmt(Statement s) {
    if (s is Block) return _block(s.statements);

    if (s is ExpressionStatement) {
      return _statement(() {
        final e = s.expression;
        // An assignment is a statement in the IR, not an expression: the VM has
        // no expression-valued assignment, and patches do not need one.
        if (e is AssignmentExpression) return _assignment(e);
        return {'k': 'expr', 'e': _expression(e)};
      });
    }

    if (s is VariableDeclarationStatement) {
      final decls = s.variables.variables;
      if (decls.length == 1) {
        return _statement(() => _varDecl(decls.first));
      }
      // `var a = 1, b = 2;` — each becomes its own statement, and each gets its
      // own prelude so an await in the second does not run before the first.
      return {
        'k': 'block',
        'body': [for (final d in decls) _statement(() => _varDecl(d))],
      };
    }

    if (s is IfStatement) {
      return _statement(() => {
            'k': 'if',
            'c': _expression(s.expression),
            'then': _stmt(s.thenStatement),
            if (s.elseStatement != null) 'else': _stmt(s.elseStatement!),
          });
    }

    if (s is WhileStatement) {
      // The condition re-evaluates every iteration, so a hoisted await in it
      // would only run once. Rejected rather than silently mis-lowered.
      return _loopStatement(
        () => {
          'k': 'while',
          'c': _expression(s.condition),
          'body': _stmt(s.body),
        },
        'a `while` condition',
      );
    }

    if (s is DoStatement) {
      return _loopStatement(
        () => {
          'k': 'doWhile',
          'body': _stmt(s.body),
          'c': _expression(s.condition),
        },
        'a `do-while` condition',
      );
    }

    if (s is ForStatement) {
      return _forStatement(s);
    }

    if (s is ReturnStatement) {
      return _statement(_return(s.expression));
    }

    if (s is BreakStatement) {
      if (s.label != null) {
        throw PatchCompileError(
          'labelled `break` is not supported (line ${_lineOf(s)})',
        );
      }
      return const {'k': 'break'};
    }

    if (s is ContinueStatement) {
      if (s.label != null) {
        throw PatchCompileError(
          'labelled `continue` is not supported (line ${_lineOf(s)})',
        );
      }
      return const {'k': 'continue'};
    }

    if (s is ExpressionStatement) {
      final e = s.expression;
      // `throw x;` is an expression statement in the AST but a statement in the
      // IR. It has to reach the VM as one: a patch that cannot throw cannot
      // reject bad input, which would leave the seam's entire
      // business-exception path unreachable from real patch source — the
      // machinery would be there and nothing could exercise it.
      if (e is ThrowExpression) {
        return _statement(() => {'k': 'throw', 'v': _expression(e.expression)});
      }
      if (e is RethrowExpression) {
        throw PatchCompileError(
          '`rethrow` is not supported (line ${_lineOf(s)}); catch into a '
          'variable and `throw` it again',
        );
      }
      return _statement(() => {'k': 'expr', 'e': _expression(s.expression)});
    }

    if (s is SwitchStatement) {
      return _switch(s);
    }

    if (s is TryStatement) {
      return _try(s);
    }

    if (s is AssertStatement) {
      return _statement(() => {
            'k': 'assert',
            'c': _expression(s.condition),
            if (s.message != null) 'msg': _expression(s.message!),
          });
    }

    if (s is EmptyStatement) return const {'k': 'block', 'body': []};

    if (s is YieldStatement) {
      throw PatchCompileError(
        '`yield` is not supported (line ${_lineOf(s)}); build and return a '
        'collection instead',
      );
    }

    throw PatchCompileError(
      'unsupported statement ${s.runtimeType} at line ${_lineOf(s)}',
    );
  }

  Map<String, Object?> _varDecl(VariableDeclaration d) {
    // The initialiser is compiled *before* the name is declared, so
    // `var x = x;` reads the outer `x` as Dart does, rather than its own null.
    final init = d.initializer;
    final node = init == null ? null : _expression(init);
    final slot = _declare(d.name.lexeme);
    return {
      'k': 'var',
      'slot': slot,
      if (node != null) 'init': node,
    };
  }

  Map<String, Object?> _assignment(AssignmentExpression e) {
    final op = e.operator.lexeme;
    final target = e.leftHandSide;

    if (op == '=') {
      return {
        'k': 'assign',
        'target': _assignable(target),
        'value': _expression(e.rightHandSide),
      };
    }

    // Compound assignment desugars to `t = t op v`. `??=` is special: it must
    // not evaluate the right side when the target is already non-null.
    if (op == '??=') {
      return {
        'k': 'if',
        'c': {
          'k': 'bin',
          'op': 'eq',
          'l': _expression(target),
          'r': const {'k': 'lit', 'v': null},
        },
        'then': {
          'k': 'assign',
          'target': _assignable(target),
          'value': _expression(e.rightHandSide),
        },
      };
    }

    const binOps = {
      '+=': 'add',
      '-=': 'sub',
      '*=': 'mul',
      '/=': 'div',
      '~/=': 'truncDiv',
      '%=': 'mod',
    };
    final binOp = binOps[op];
    if (binOp == null) {
      throw PatchCompileError(
        'unsupported assignment operator `$op` at line ${_lineOf(e)}',
      );
    }
    return {
      'k': 'assign',
      'target': _assignable(target),
      'value': {
        'k': 'bin',
        'op': binOp,
        'l': _expression(target),
        'r': _expression(e.rightHandSide),
      },
    };
  }

  Map<String, Object?> _assignable(Expression target) {
    if (target is SimpleIdentifier) {
      final slot = _lookup(target.name);
      if (slot == null) {
        throw PatchCompileError(
          'cannot assign to `${target.name}` (line ${_lineOf(target)}): a patch '
          'may only assign to its own locals',
        );
      }
      return {'k': 'local', 'slot': slot};
    }
    if (target is IndexExpression) {
      return {
        'k': 'index',
        'target': _expression(target.realTarget),
        'index': _expression(target.index),
      };
    }
    throw PatchCompileError(
      'unsupported assignment target ${target.runtimeType} at line '
      '${_lineOf(target)}',
    );
  }

  /// A loop whose condition must stay await-free, because it re-evaluates.
  Map<String, Object?> _loopStatement(
    Map<String, Object?> Function() build,
    String what,
  ) {
    final saved = _prelude;
    _prelude = [];
    final stmt = build();
    final hoisted = _prelude!;
    _prelude = saved;
    if (hoisted.isNotEmpty) {
      throw PatchCompileError(
        'cannot `await` inside $what: it is evaluated once per iteration, so '
        'hoisting it would change the meaning. Restructure with a `while (true)` '
        'and an explicit `break`.',
      );
    }
    return stmt;
  }

  Map<String, Object?> _forStatement(ForStatement s) {
    final parts = s.forLoopParts;
    _pushScope();
    try {
      if (parts is ForEachParts) {
        final Map<String, Object?> iterable;
        final int slot;
        final body = <Map<String, Object?>>[];
        final saved = _prelude;
        _prelude = [];
        iterable = _expression(parts.iterable);
        final hoisted = _prelude!;
        _prelude = saved;

        if (parts is ForEachPartsWithDeclaration) {
          slot = _declare(parts.loopVariable.name.lexeme);
        } else if (parts is ForEachPartsWithIdentifier) {
          final existing = _lookup(parts.identifier.name);
          if (existing == null) {
            throw PatchCompileError(
              'unknown loop variable `${parts.identifier.name}` at line '
              '${_lineOf(s)}',
            );
          }
          slot = existing;
        } else {
          throw PatchCompileError(
            'unsupported for-in form at line ${_lineOf(s)}',
          );
        }

        final loop = <String, Object?>{
          'k': 'forIn',
          'slot': slot,
          'iterable': iterable,
          'body': _stmt(s.body),
        };
        if (hoisted.isEmpty) return loop;
        body
          ..addAll(hoisted)
          ..add(loop);
        return {'k': 'block', 'body': body};
      }

      if (parts is ForPartsWithDeclarations) {
        final init = <Map<String, Object?>>[];
        for (final d in parts.variables.variables) {
          init.add(_statement(() => _varDecl(d)));
        }
        return {
          'k': 'block',
          'body': [
            ...init,
            _loopStatement(
              () => {
                'k': 'for',
                if (parts.condition != null) 'c': _expression(parts.condition!),
                'update': [
                  for (final u in parts.updaters)
                    _statement(() => _updater(u)),
                ],
                'body': _stmt(s.body),
              },
              'a `for` condition or updater',
            ),
          ],
        };
      }

      if (parts is ForPartsWithExpression) {
        return {
          'k': 'block',
          'body': [
            if (parts.initialization != null)
              _statement(() => {
                    'k': 'expr',
                    'e': _expression(parts.initialization!),
                  }),
            _loopStatement(
              () => {
                'k': 'for',
                if (parts.condition != null) 'c': _expression(parts.condition!),
                'update': [
                  for (final u in parts.updaters)
                    _statement(() => _updater(u)),
                ],
                'body': _stmt(s.body),
              },
              'a `for` condition or updater',
            ),
          ],
        };
      }

      throw PatchCompileError('unsupported `for` at line ${_lineOf(s)}');
    } finally {
      _popScope();
    }
  }

  /// A loop updater: `i++`, `i += 2`, or any expression.
  Map<String, Object?> _updater(Expression e) {
    if (e is AssignmentExpression) return _assignment(e);
    if (e is PostfixExpression || e is PrefixExpression) {
      final operand = e is PostfixExpression
          ? e.operand
          : (e as PrefixExpression).operand;
      final op = e is PostfixExpression
          ? e.operator.lexeme
          : (e as PrefixExpression).operator.lexeme;
      if (op == '++' || op == '--') {
        return {
          'k': 'assign',
          'target': _assignable(operand),
          'value': {
            'k': 'bin',
            'op': op == '++' ? 'add' : 'sub',
            'l': _expression(operand),
            'r': const {'k': 'lit', 'v': 1},
          },
        };
      }
    }
    return {'k': 'expr', 'e': _expression(e)};
  }

  Map<String, Object?> _switch(SwitchStatement s) {
    final saved = _prelude;
    _prelude = [];
    final selector = _expression(s.expression);
    final hoisted = _prelude!;
    _prelude = saved;

    final cases = <Map<String, Object?>>[];
    Map<String, Object?>? defaultCase;

    // Consecutive `case` labels with no body share the body that follows, which
    // is how Dart expresses grouped cases.
    var pendingValues = <Object?>[];
    for (final member in s.members) {
      if (member is SwitchDefault) {
        defaultCase = _block(member.statements);
        continue;
      }
      // `case 'a':` — the pre-patterns spelling. Still produced for some shapes.
      if (member is SwitchCase) {
        pendingValues.add(_constant(member.expression));
        if (member.statements.isEmpty) continue;
        cases.add({
          'values': pendingValues,
          'body': _block(member.statements),
        });
        pendingValues = <Object?>[];
        continue;
      }
      // Since patterns landed, `case 'a':` normally parses as a pattern case
      // wrapping a ConstantPattern. Rejecting every pattern case outright would
      // therefore reject ordinary constant switches — which is most of them.
      // Only genuinely pattern-shaped cases (destructuring, `when` guards) are
      // out of scope.
      if (member is SwitchPatternCase) {
        final guarded = member.guardedPattern;
        if (guarded.whenClause != null) {
          throw PatchCompileError(
            '`when` guards are not supported yet (line ${_lineOf(member)}); '
            'move the condition into an `if` inside the case body',
          );
        }
        final pattern = guarded.pattern;
        if (pattern is! ConstantPattern) {
          throw PatchCompileError(
            'pattern switches are not supported yet (line ${_lineOf(member)}); '
            'use constant cases',
          );
        }
        pendingValues.add(_constant(pattern.expression));
        if (member.statements.isEmpty) continue;
        cases.add({
          'values': pendingValues,
          'body': _block(member.statements),
        });
        pendingValues = <Object?>[];
        continue;
      }
      throw PatchCompileError(
        'unsupported switch member ${member.runtimeType} at line '
        '${_lineOf(member)}',
      );
    }
    if (pendingValues.isNotEmpty) {
      throw PatchCompileError(
        'the last `case` in the switch at line ${_lineOf(s)} has no body',
      );
    }

    final node = <String, Object?>{
      'k': 'switch',
      'selector': selector,
      'cases': cases,
      if (defaultCase != null) 'default': defaultCase,
    };
    if (hoisted.isEmpty) return node;
    return {'k': 'block', 'body': [...hoisted, node]};
  }

  Map<String, Object?> _try(TryStatement s) {
    final catches = <Map<String, Object?>>[];
    for (final clause in s.catchClauses) {
      _pushScope();
      final entry = <String, Object?>{};
      final typeName = clause.exceptionType?.type?.element?.name;
      if (clause.exceptionType != null) {
        if (typeName == null) {
          throw PatchCompileError(
            'could not resolve the caught type at line ${_lineOf(clause)}',
          );
        }
        entry['type'] = surface.requireType(
          typeName,
          context: 'line ${_lineOf(clause)}',
        );
      }
      final exceptionParam = clause.exceptionParameter;
      if (exceptionParam != null) {
        entry['e'] = _declare(exceptionParam.name.lexeme);
      }
      final stackParam = clause.stackTraceParameter;
      if (stackParam != null) {
        entry['st'] = _declare(stackParam.name.lexeme);
      }
      entry['body'] = _block(clause.body.statements);
      catches.add(entry);
      _popScope();
    }

    return {
      'k': 'try',
      'body': _block(s.body.statements),
      if (catches.isNotEmpty) 'catches': catches,
      if (s.finallyBlock != null) 'finally': _block(s.finallyBlock!.statements),
    };
  }

  // -------------------------------------------------------------------------
  // Expressions
  // -------------------------------------------------------------------------

  Map<String, Object?> _expression(Expression e) {
    if (e is ParenthesizedExpression) return _expression(e.expression);

    if (e is IntegerLiteral) return {'k': 'lit', 'v': e.value};
    if (e is DoubleLiteral) return {'k': 'lit', 'v': e.value};
    if (e is BooleanLiteral) return {'k': 'lit', 'v': e.value};
    if (e is NullLiteral) return const {'k': 'lit', 'v': null};
    if (e is SimpleStringLiteral) return {'k': 'lit', 'v': e.value};

    if (e is StringInterpolation) {
      return {
        'k': 'interp',
        'parts': [
          for (final part in e.elements)
            if (part is InterpolationString)
              {'k': 'lit', 'v': part.value}
            else
              _expression((part as InterpolationExpression).expression),
        ],
      };
    }

    if (e is AwaitExpression) return _hoistAwait(e);

    if (e is SimpleIdentifier) {
      final slot = _lookup(e.name);
      if (slot != null) return {'k': 'local', 'slot': slot};
      // Not a local: a top-level function used as a value, or a static getter.
      return _staticRead(e);
    }

    if (e is BinaryExpression) return _binary(e);
    if (e is PrefixExpression) return _prefix(e);
    if (e is ConditionalExpression) {
      return {
        'k': 'cond',
        'c': _expression(e.condition),
        't': _expression(e.thenExpression),
        'e': _expression(e.elseExpression),
      };
    }

    if (e is ListLiteral) {
      return {
        'k': 'list',
        'items': [for (final el in e.elements) _collectionElement(el)],
      };
    }
    if (e is SetOrMapLiteral) {
      if (e.isMap) {
        final entries = <List<Map<String, Object?>>>[];
        for (final el in e.elements) {
          if (el is! MapLiteralEntry) {
            throw PatchCompileError(
              'only plain `key: value` entries are supported in a map literal '
              '(line ${_lineOf(el)})',
            );
          }
          entries.add([_expression(el.key), _expression(el.value)]);
        }
        return {'k': 'map', 'entries': entries};
      }
      return {
        'k': 'set',
        'items': [for (final el in e.elements) _collectionElement(el)],
      };
    }

    if (e is IndexExpression) {
      return {
        'k': 'index',
        'target': _expression(e.realTarget),
        'index': _expression(e.index),
      };
    }

    if (e is IsExpression) {
      final name = e.type.type?.element?.name;
      if (name == null) {
        throw PatchCompileError(
          'could not resolve the type in `is` at line ${_lineOf(e)}',
        );
      }
      const builtin = {
        'int', 'double', 'num', 'String', 'bool', 'List', 'Map', 'Set',
      };
      if (builtin.contains(name)) {
        return {
          'k': 'is',
          'v': _expression(e.expression),
          'type': _virTypeName(name),
          if (e.notOperator != null) 'not': true,
        };
      }
      return {
        'k': 'isHost',
        'v': _expression(e.expression),
        'type': surface.requireType(name, context: 'line ${_lineOf(e)}'),
        if (e.notOperator != null) 'not': true,
      };
    }

    if (e is AsExpression) {
      // `as` is a checked coercion in Dart, but the VM is dynamically typed and
      // the host bindings already assert argument types at the boundary. So this
      // compiles to the operand: what `as` was guarding is checked where it
      // actually matters.
      return _expression(e.expression);
    }

    if (e is PostfixExpression && e.operator.lexeme == '!') {
      return {'k': 'notNull', 'v': _expression(e.operand)};
    }

    if (e is MethodInvocation) return _methodCall(e);
    if (e is PropertyAccess) {
      return _memberRead(e.realTarget, e.propertyName, _lineOf(e));
    }
    if (e is PrefixedIdentifier) {
      return _memberRead(e.prefix, e.identifier, _lineOf(e));
    }
    if (e is InstanceCreationExpression) return _construct(e);

    if (e is FunctionExpression) {
      throw PatchCompileError(
        'closures are not supported yet (line ${_lineOf(e)}); extract a '
        'top-level function',
      );
    }

    if (e is CascadeExpression) {
      throw PatchCompileError(
        'cascades (`..`) are not supported yet (line ${_lineOf(e)}); write the '
        'calls out separately',
      );
    }

    throw PatchCompileError(
      'unsupported expression ${e.runtimeType} at line ${_lineOf(e)}',
    );
  }

  /// Hoists `await x` into `var _t = await x;` and yields a read of `_t`.
  ///
  /// This is where the VM's "await in statement position only" rule is paid for.
  /// The hoisted statement lands in [_prelude], which [_statement] emits ahead
  /// of the statement being compiled — so evaluation order is preserved: the
  /// await happens before the expression that consumes it, exactly as in the
  /// source.
  Map<String, Object?> _hoistAwait(AwaitExpression e) {
    final prelude = _prelude;
    if (prelude == null) {
      throw PatchCompileError(
        'cannot `await` here (line ${_lineOf(e)})',
      );
    }
    final inner = _expression(e.expression);
    final slot = _temp();
    prelude.add({
      'k': 'var',
      'slot': slot,
      'init': {'k': 'await', 'v': inner},
    });
    return {'k': 'local', 'slot': slot};
  }

  Map<String, Object?> _collectionElement(CollectionElement el) {
    if (el is Expression) return _expression(el);
    throw PatchCompileError(
      'spreads and collection-if/for are not supported yet (line '
      '${_lineOf(el)})',
    );
  }

  String _virTypeName(String name) => switch (name) {
        'int' => 'intType',
        'double' => 'doubleType',
        'num' => 'numType',
        'String' => 'stringType',
        'bool' => 'boolType',
        'List' => 'listType',
        'Map' => 'mapType',
        'Set' => 'setType',
        _ => throw PatchCompileError('unexpected builtin type `$name`'),
      };

  Map<String, Object?> _binary(BinaryExpression e) {
    const ops = {
      '+': 'add',
      '-': 'sub',
      '*': 'mul',
      '/': 'div',
      '~/': 'truncDiv',
      '%': 'mod',
      '==': 'eq',
      '!=': 'ne',
      '<': 'lt',
      '<=': 'lte',
      '>': 'gt',
      '>=': 'gte',
      '&&': 'and',
      '||': 'or',
    };
    final op = e.operator.lexeme;

    if (op == '??') {
      // Short-circuits, so it cannot become a plain binary op: the right side
      // must not be evaluated when the left is non-null.
      final left = _expression(e.leftOperand);
      return {
        'k': 'cond',
        'c': {
          'k': 'bin',
          'op': 'eq',
          'l': left,
          'r': const {'k': 'lit', 'v': null},
        },
        't': _expression(e.rightOperand),
        'e': left,
      };
    }

    final mapped = ops[op];
    if (mapped == null) {
      throw PatchCompileError(
        'unsupported operator `$op` at line ${_lineOf(e)}',
      );
    }
    return {
      'k': 'bin',
      'op': mapped,
      'l': _expression(e.leftOperand),
      'r': _expression(e.rightOperand),
    };
  }

  Map<String, Object?> _prefix(PrefixExpression e) {
    final op = e.operator.lexeme;
    if (op == '-') return {'k': 'un', 'op': 'neg', 'v': _expression(e.operand)};
    if (op == '!') return {'k': 'un', 'op': 'not', 'v': _expression(e.operand)};
    throw PatchCompileError(
      'unsupported prefix operator `$op` at line ${_lineOf(e)}',
    );
  }

  /// A call: to another function in this patch, or across the host bridge.
  Map<String, Object?> _methodCall(MethodInvocation e) {
    final target = e.realTarget;
    final name = e.methodName.name;

    // A call to a function this patch defines.
    if (target == null) {
      final index = functionIndex[name];
      if (index != null) {
        return {
          'k': 'vmCall',
          'fn': index,
          'args': [for (final a in _positional(e.argumentList)) a],
          if (_named(e.argumentList).isNotEmpty) 'named': _named(e.argumentList),
        };
      }
      // A top-level host function, e.g. `jsonDecode(...)`.
      return _hostCall(
        surface.requireMember(name, context: 'line ${_lineOf(e)}'),
        null,
        e.argumentList,
      );
    }

    final key = _memberKey(target, name, _lineOf(e));
    return _hostCall(
      surface.requireMember(key, context: 'line ${_lineOf(e)}'),
      // A static call has no receiver: `int.parse(s)` names a type, not a value.
      _isTypeReference(target) ? null : _expression(target),
      e.argumentList,
    );
  }

  Map<String, Object?> _hostCall(
    int memberId,
    Map<String, Object?>? receiver,
    ArgumentList args,
  ) {
    final positional = _positional(args);
    final named = _named(args);
    return {
      'k': 'hostCall',
      'id': memberId,
      if (receiver != null) 'recv': receiver,
      if (positional.isNotEmpty) 'args': positional,
      if (named.isNotEmpty) 'named': named,
    };
  }

  List<Map<String, Object?>> _positional(ArgumentList args) => [
        for (final a in args.arguments)
          if (a is! NamedArgument) _expression(a.argumentExpression),
      ];

  Map<String, Map<String, Object?>> _named(ArgumentList args) => {
        for (final a in args.arguments)
          if (a is NamedArgument)
            a.name.lexeme: _expression(a.argumentExpression),
      };

  /// A property or getter read, either on a value or on a type.
  Map<String, Object?> _memberRead(
    Expression target,
    SimpleIdentifier property,
    int line,
  ) {
    final key = _memberKey(target, property.name, line);
    return {
      'k': 'hostCall',
      'id': surface.requireMember(key, context: 'line $line'),
      // A static getter (`double.infinity`) reads through a type, not a value,
      // so there is no receiver to evaluate.
      if (!_isTypeReference(target)) 'recv': _expression(target),
    };
  }

  /// Builds the surface key for `target.name`.
  ///
  /// Static members and constructors are keyed by the type name; instance
  /// members by the receiver's static type. Using the static type rather than
  /// the declaring class keeps keys stable and readable (`String.indexOf`, not
  /// the internal class that happens to declare it).
  /// Whether [target] names a *type* rather than a value.
  ///
  /// `int.parse(...)` and `s.length` look alike in the AST — both are a target
  /// plus a member name — but only the second has a receiver. Compiling `int` as
  /// an expression asks the manifest for a member literally called `int`, which
  /// is both wrong and confusingly diagnosed. So the two cases are separated
  /// here, once, and every member access consults it.
  bool _isTypeReference(Expression target) {
    if (target is! Identifier) return false;
    final element = target is SimpleIdentifier
        ? target.element
        : (target as PrefixedIdentifier).identifier.element;
    return element is ClassElement ||
        element is TypeAliasElement ||
        element is ExtensionTypeElement;
  }

  String _memberKey(Expression target, String name, int line) {
    if (_isTypeReference(target)) {
      return '${target is SimpleIdentifier ? target.name : target.toString()}'
          '.$name';
    }
    final type = target.staticType;
    final typeName = _staticTypeName(type);
    if (typeName == null) {
      throw PatchCompileError(
        'could not resolve the receiver type for `.$name` at line $line.\n'
        '  Add an explicit type annotation so the compiler can pick the right '
        'binding.',
      );
    }
    return '$typeName.$name';
  }

  String? _staticTypeName(DartType? type) {
    if (type == null || type is DynamicType || type is InvalidType) return null;
    final element = type.element;
    if (element == null) return null;
    return element.name;
  }

  /// A bare identifier that is not a local: a top-level constant or a tear-off.
  Map<String, Object?> _staticRead(SimpleIdentifier e) {
    final index = functionIndex[e.name];
    if (index != null) {
      throw PatchCompileError(
        'function tear-offs are not supported yet (line ${_lineOf(e)}); call '
        '`${e.name}(...)` directly',
      );
    }
    return {
      'k': 'hostCall',
      'id': surface.requireMember(e.name, context: 'line ${_lineOf(e)}'),
    };
  }

  Map<String, Object?> _construct(InstanceCreationExpression e) {
    final typeName = e.constructorName.type.type?.element?.name;
    if (typeName == null) {
      throw PatchCompileError(
        'could not resolve the constructed type at line ${_lineOf(e)}',
      );
    }
    final ctor = e.constructorName.name?.name;
    final key = ctor == null ? '$typeName.new' : '$typeName.$ctor';
    return _hostCall(
      surface.requireMember(key, context: 'line ${_lineOf(e)}'),
      null,
      e.argumentList,
    );
  }

  /// A `case` label value. Dart requires these to be constants, and the VM
  /// compares them with `==`, so they travel as raw JSON scalars.
  Object? _constant(Expression e) {
    if (e is IntegerLiteral) return e.value;
    if (e is DoubleLiteral) return e.value;
    if (e is BooleanLiteral) return e.value;
    if (e is SimpleStringLiteral) return e.value;
    if (e is NullLiteral) return null;
    if (e is PrefixExpression && e.operator.lexeme == '-') {
      final operand = e.operand;
      if (operand is IntegerLiteral) return -(operand.value ?? 0);
      if (operand is DoubleLiteral) return -operand.value;
    }
    throw PatchCompileError(
      'a `case` label must be a literal constant (line ${_lineOf(e)})',
    );
  }

  int _lineOf(AstNode node) {
    final unit = node.thisOrAncestorOfType<CompilationUnit>();
    if (unit == null) return 0;
    return unit.lineInfo.getLocation(node.offset).lineNumber;
  }
}

/// A patch could not be compiled.
class PatchCompileError implements Exception {
  const PatchCompileError(this.message);

  final String message;

  @override
  String toString() => message;
}
