import 'dart:async';
import 'dart:isolate';

import 'package:venera/foundation/image_translation/local_llm/llama_ffi.dart';
import 'package:venera/foundation/image_translation/translation_prompt.dart';

/// Chat-template families. The shim takes a fully-formatted prompt, so the
/// template is applied here in Dart. Keeping it an explicit enum (rather than
/// reading the GGUF's embedded template) keeps the shim minimal and lets a
/// model entry declare exactly which wrapping it needs.
enum ChatTemplate {
  /// ChatML: Qwen, Yi, many finetunes. `<|im_start|>role\n...<|im_end|>`.
  chatml,

  /// Gemma: `<start_of_turn>user\n...<end_of_turn>` (no system role; the
  /// system text is folded into the first user turn).
  gemma,
}

/// Builds the full prompt string for [template] from a system + user message.
String formatChatPrompt(
  ChatTemplate template,
  String system,
  String user,
) {
  switch (template) {
    case ChatTemplate.chatml:
      return '<|im_start|>system\n$system<|im_end|>\n'
          '<|im_start|>user\n$user<|im_end|>\n'
          '<|im_start|>assistant\n';
    case ChatTemplate.gemma:
      // Gemma has no system turn; prepend the system text to the user turn.
      return '<start_of_turn>user\n$system\n\n$user<end_of_turn>\n'
          '<start_of_turn>model\n';
  }
}

/// Request to load a model and translate one page's bubbles locally.
class _LocalTranslateRequest {
  _LocalTranslateRequest(
    this.id,
    this.modelPath,
    this.template,
    this.contextSize,
    this.gpuLayers,
    this.texts,
    this.targetLang,
    this.glossary,
  );

  final int id;
  final String modelPath;
  final ChatTemplate template;
  final int contextSize;
  final int gpuLayers;
  final List<String> texts;
  final String targetLang;
  final Map<String, String> glossary;
}

class _ReleaseRequest {
  const _ReleaseRequest();
}

class _WorkerResponse {
  _WorkerResponse(this.id, this.result, this.error);

  final int id;
  final Object? result;
  final String? error;
}

/// The result payload sent back from the worker: aligned texts + new glossary.
class _TranslateResult {
  _TranslateResult(this.texts, this.glossary);

  final List<String> texts;
  final Map<String, String> glossary;
}

// ===========================================================================
// Main-isolate client
// ===========================================================================

/// Handle to the on-device LLM worker isolate. Kept separate from the OCR
/// [TranslationWorker] so a loaded ~1GB model and the OCR sessions don't have
/// to coexist in one isolate's heap, and either can be released independently.
///
/// The model is loaded lazily inside the worker on the first request and stays
/// resident until [release] (idle timeout) — reloading a multi-hundred-MB GGUF
/// per page would be unusably slow.
class LocalLlmWorker {
  LocalLlmWorker._();

  static final instance = LocalLlmWorker._();

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _starting;
  final _receivePort = <ReceivePort>[];
  final _pending = <int, Completer<Object?>>{};
  int _nextId = 0;

  Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    if (_starting != null) return _starting;
    var completer = Completer<void>();
    _starting = completer.future;
    var port = ReceivePort();
    _receivePort.add(port);
    port.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      } else if (message is _WorkerResponse) {
        var pending = _pending.remove(message.id);
        if (pending == null) return;
        if (message.error != null) {
          pending.completeError(Exception(message.error));
        } else {
          pending.complete(message.result);
        }
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        port.sendPort,
        debugName: 'localLlmWorker',
      );
    } catch (e) {
      _starting = null;
      completer.completeError(e);
      rethrow;
    }
    await completer.future;
    _starting = null;
  }

  Future<T> _request<T>(Object Function(int id) build) async {
    await _ensureStarted();
    var id = _nextId++;
    var completer = Completer<Object?>();
    _pending[id] = completer;
    _sendPort!.send(build(id));
    return await completer.future as T;
  }

  /// Translates [texts] locally through the model at [modelPath]. Mirrors
  /// [LlmTranslator.translateBatch]'s contract (aligned texts + reported
  /// glossary) so the pipeline treats both engines identically.
  Future<LlmTranslationResult> translateBatch(
    List<String> texts,
    String targetLang, {
    required String modelPath,
    required ChatTemplate template,
    int contextSize = 4096,
    int gpuLayers = -1,
    Map<String, String> glossary = const {},
  }) async {
    if (texts.isEmpty) {
      return const LlmTranslationResult([], {});
    }
    var result = await _request<_TranslateResult>(
      (id) => _LocalTranslateRequest(
        id,
        modelPath,
        template,
        contextSize,
        gpuLayers,
        texts,
        targetLang,
        glossary,
      ),
    );
    return LlmTranslationResult(result.texts, result.glossary);
  }

  /// Frees the loaded model inside the worker (reloaded lazily next request).
  void release() {
    _sendPort?.send(const _ReleaseRequest());
  }

  /// Kills the worker isolate entirely, freeing all native memory. Pending
  /// requests complete with an error; the worker restarts lazily.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _starting = null;
    for (var port in _receivePort) {
      port.close();
    }
    _receivePort.clear();
    for (var pending in _pending.values) {
      pending.completeError(Exception('Local LLM worker disposed'));
    }
    _pending.clear();
  }
}

// ===========================================================================
// Worker isolate
// ===========================================================================

void _workerMain(SendPort mainPort) {
  var port = ReceivePort();
  mainPort.send(port.sendPort);
  var state = _WorkerState();
  port.listen((message) {
    if (message is _LocalTranslateRequest) {
      try {
        var result = state.translate(message);
        mainPort.send(_WorkerResponse(message.id, result, null));
      } catch (e, s) {
        mainPort.send(_WorkerResponse(message.id, null, '$e\n$s'));
      }
    } else if (message is _ReleaseRequest) {
      state.release();
    }
  });
}

class _WorkerState {
  LlamaModel? _model;
  String? _loadedPath;

  LlamaModel _ensureModel(String path, int contextSize, int gpuLayers) {
    if (_model != null && _loadedPath == path) {
      return _model!;
    }
    // A different model was requested — free the old one first.
    _model?.free();
    _model = LlamaModel.load(
      path,
      contextSize: contextSize,
      gpuLayers: gpuLayers,
    );
    _loadedPath = path;
    return _model!;
  }

  _TranslateResult translate(_LocalTranslateRequest req) {
    var model = _ensureModel(req.modelPath, req.contextSize, req.gpuLayers);
    var system = TranslationPrompt.systemPrompt(req.targetLang);
    var user = TranslationPrompt.userPayload(req.texts, glossary: req.glossary);
    var prompt = formatChatPrompt(req.template, system, user);
    // A generous token budget: JSON for a page of bubbles, plus the names map.
    var output = model.generate(prompt, maxTokens: 2048);
    var parsed = TranslationPrompt.parse(output, req.texts.length);
    return _TranslateResult(parsed.texts, parsed.glossary);
  }

  void release() {
    _model?.free();
    _model = null;
    _loadedPath = null;
  }
}
