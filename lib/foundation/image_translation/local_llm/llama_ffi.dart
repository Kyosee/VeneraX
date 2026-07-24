import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// FFI binding to the `venera_llama` shim — our own thin C wrapper over
/// llama.cpp (see packages/venera_llama/src/venera_llama.h).
///
/// We bind OUR shim, not llama.cpp's own C API: the shim exposes a tiny,
/// stable surface (load / generate / free / last_error) so this binding never
/// has to track llama.cpp's large, frequently-changing header. The heavy work
/// (tokenize, decode loop, sampling) lives in the shim and runs synchronously,
/// so this is only ever used inside the local-LLM worker isolate, where
/// blocking is fine — exactly like [OrtFfiSession] for OCR.
class LlamaFfi {
  LlamaFfi._(this._lib) {
    _backendInit();
  }

  static LlamaFfi? _instance;

  final DynamicLibrary _lib;

  static LlamaFfi open() {
    return _instance ??= LlamaFfi._(_openLibrary());
  }

  /// Cached result of the one-time native-library probe. `null` = not probed.
  static bool? _available;

  /// Whether the `venera_llama` native library can actually be loaded on this
  /// build/platform. The shim is only compiled where the plugin is registered
  /// (see packages/venera_llama), so on a build that omits it — or a platform
  /// we haven't wired the native build for yet — loading fails. Probing here
  /// (once, result cached) lets the engine degrade gracefully instead of
  /// crashing the translate path with a raw `DynamicLibrary.open` exception.
  ///
  /// Only checks that the library loads and exposes our entry symbol; it does
  /// not load a model.
  static bool get isAvailable {
    if (_available != null) return _available!;
    try {
      var lib = _openLibrary();
      // Confirm it's really our shim, not just some library that opened.
      var ok = lib.providesSymbol('venera_llama_backend_init');
      return _available = ok;
    } catch (_) {
      return _available = false;
    }
  }

  static DynamicLibrary _openLibrary() {
    // The shim is statically linked into the app on iOS/macOS (part of the
    // Runner process); on Android/desktop it ships as a shared library named
    // after the plugin.
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libvenera_llama.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('venera_llama.dll');
    }
    return DynamicLibrary.process();
  }

  late final _backendInit = _lib
      .lookupFunction<Void Function(), void Function()>(
        'venera_llama_backend_init',
      );

  late final _load = _lib
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int, int)
      >('venera_llama_load');

  late final _generate = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Int32,
          Pointer<Utf8>,
          Int32,
        ),
        int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('venera_llama_generate');

  late final _free = _lib
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
        'venera_llama_free',
      );

  late final _lastError = _lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'venera_llama_last_error',
      );

  String _lastErrorString() {
    var p = _lastError();
    if (p == nullptr) return 'unknown error';
    return p.toDartString();
  }
}

/// A loaded local model. Owns a native handle; must be created and used on the
/// same isolate (the worker). Not safe to share across isolates.
class LlamaModel {
  LlamaModel._(this._ffi, this._handle);

  final LlamaFfi _ffi;
  Pointer<Void> _handle;

  /// Loads [modelPath]. [contextSize] is the token window; [gpuLayers] = -1
  /// offloads all layers to the GPU (Metal on Apple), 0 keeps everything on
  /// CPU. Throws with the shim's error message on failure.
  static LlamaModel load(
    String modelPath, {
    int contextSize = 4096,
    int gpuLayers = -1,
  }) {
    var ffi = LlamaFfi.open();
    var pathPtr = modelPath.toNativeUtf8();
    try {
      var handle = ffi._load(pathPtr, contextSize, gpuLayers);
      if (handle == nullptr) {
        throw Exception('Failed to load model: ${ffi._lastErrorString()}');
      }
      return LlamaModel._(ffi, handle);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Runs a full generation from a fully-formatted [prompt] (the caller has
  /// already applied the model's chat template). Returns the generated text.
  /// Blocking — worker isolate only.
  String generate(String prompt, {int maxTokens = 1024, int outCapacity = 32768}) {
    if (_handle == nullptr) {
      throw Exception('Model already freed');
    }
    var promptPtr = prompt.toNativeUtf8();
    var outBuf = calloc<Uint8>(outCapacity);
    try {
      var n = _ffi._generate(
        _handle,
        promptPtr,
        maxTokens,
        outBuf.cast<Utf8>(),
        outCapacity,
      );
      if (n < 0) {
        throw Exception('Generation failed: ${_ffi._lastErrorString()}');
      }
      return outBuf.cast<Utf8>().toDartString(length: n);
    } finally {
      calloc.free(promptPtr);
      calloc.free(outBuf);
    }
  }

  void free() {
    if (_handle != nullptr) {
      _ffi._free(_handle);
      _handle = nullptr;
    }
  }
}
