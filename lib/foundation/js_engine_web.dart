import 'dart:typed_data';

class JavaScriptRuntimeException implements Exception {
  final String message;

  JavaScriptRuntimeException(this.message);

  @override
  String toString() => message;
}

abstract interface class JSInvokable {
  dynamic call(List<dynamic> args);
  void free();
  void dup();
  void destroy();
}

class JSAutoFreeFunction {
  final JSInvokable func;

  JSAutoFreeFunction(this.func);

  dynamic call(List<dynamic> args) => func(args);
}

class JsEngine {
  factory JsEngine() => _cache ??= JsEngine._create();

  JsEngine._create();

  static JsEngine? _cache;

  static void reset() {
    final old = _cache;
    _cache = null;
    old?.dispose();
  }

  static void cacheJsInit(Uint8List jsInit) {}

  Future<void> init() async {}

  Future<void> ensureInit() async {}

  void resetDio() {}

  dynamic runCode(String code, [String? name]) {
    throw JavaScriptRuntimeException(
      'JavaScript runtime is not available on web yet.',
    );
  }

  void dispose() {}
}
