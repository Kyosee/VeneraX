import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:venera/foundation/image_translation/hf_tokenizer.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/utils/io.dart';

/// Reads an [OrtValue]'s data as a flat float list without an extra copy when
/// the platform already returned typed data.
Future<Float32List> _readF32(OrtValue value) async {
  var data = await value.asFlattenedList();
  if (data is Float32List) {
    return data;
  }
  var result = Float32List(data.length);
  for (var i = 0; i < data.length; i++) {
    result[i] = (data[i] as num).toDouble();
  }
  return result;
}

Future<void> _disposeAll(Iterable<OrtValue> values) async {
  for (var value in values) {
    await value.dispose();
  }
}

/// One lazily created ONNX session bound to a model file on disk.
class _LazySession {
  _LazySession(this.path);

  final String path;
  OrtSession? _session;
  Future<OrtSession>? _loading;

  Future<OrtSession> get() {
    if (_session != null) {
      return Future.value(_session);
    }
    return _loading ??= OnnxRuntime()
        .createSession(path)
        .then((session) {
          _session = session;
          _loading = null;
          return session;
        })
        .catchError((Object e) {
          _loading = null;
          throw e;
        });
  }

  Future<void> release() async {
    var session = _session;
    _session = null;
    _loading = null;
    await session?.close();
  }
}

/// Text region detector (PP-OCR DBNet). Input is a normalized NCHW tensor,
/// output the text probability map of the same spatial size.
class TextDetectorEngine {
  TextDetectorEngine() : _session = _LazySession(
          TranslationModels.detector.filePath('det.onnx'),
        );

  final _LazySession _session;

  Future<Float32List> run(Float32List input, int height, int width) async {
    var session = await _session.get();
    var tensor = await OrtValue.fromList(input, [1, 3, height, width]);
    try {
      var outputs = await session.run({session.inputNames.first: tensor});
      try {
        return await _readF32(outputs.values.first);
      } finally {
        await _disposeAll(outputs.values);
      }
    } finally {
      await tensor.dispose();
    }
  }

  Future<void> release() => _session.release();
}

/// manga-ocr: ViT encoder + autoregressive text decoder, reads a whole
/// speech-bubble crop (including vertical text) as one Japanese string.
class MangaOcrEngine {
  MangaOcrEngine()
    : _encoder = _LazySession(TranslationModels.ocrJa.filePath('encoder.onnx')),
      _decoder = _LazySession(TranslationModels.ocrJa.filePath('decoder.onnx'));

  final _LazySession _encoder;
  final _LazySession _decoder;
  WordPieceVocab? _vocab;

  static const _startToken = 2;
  static const _eosToken = 3;
  static const _maxTokens = 80;

  /// [pixels] is the normalized 3x224x224 tensor of the crop.
  Future<String> recognize(Float32List pixels) async {
    _vocab ??= await WordPieceVocab.fromFile(
      TranslationModels.ocrJa.filePath('vocab.txt'),
    );
    var encoder = await _encoder.get();
    var decoder = await _decoder.get();

    var pixelTensor = await OrtValue.fromList(pixels, [1, 3, 224, 224]);
    Float32List hidden;
    List<int> hiddenShape;
    try {
      var outputs = await encoder.run({
        encoder.inputNames.first: pixelTensor,
      });
      try {
        hidden = await _readF32(outputs.values.first);
        hiddenShape = outputs.values.first.shape;
      } finally {
        await _disposeAll(outputs.values);
      }
    } finally {
      await pixelTensor.dispose();
    }

    var ids = <int>[_startToken];
    while (ids.length < _maxTokens) {
      var idsTensor = await OrtValue.fromList(
        Int64List.fromList(ids),
        [1, ids.length],
      );
      var hiddenTensor = await OrtValue.fromList(hidden, hiddenShape);
      int next;
      try {
        var outputs = await decoder.run({
          'input_ids': idsTensor,
          'encoder_hidden_states': hiddenTensor,
        });
        try {
          var logits = await _readF32(outputs.values.first);
          var vocabSize = outputs.values.first.shape.last;
          next = _argmaxLast(logits, vocabSize);
        } finally {
          await _disposeAll(outputs.values);
        }
      } finally {
        await idsTensor.dispose();
        await hiddenTensor.dispose();
      }
      if (next == _eosToken) break;
      ids.add(next);
    }
    return _vocab!.decode(ids.sublist(1));
  }

  Future<void> release() async {
    await _encoder.release();
    await _decoder.release();
  }
}

/// PP-OCR CRNN text-line recognizer with CTC decoding.
class PaddleRecEngine {
  PaddleRecEngine(this.component, {required this.inputHeight});

  final ModelComponent component;

  /// 48 for v3/v4 models, 32 for the older mobile models.
  final int inputHeight;

  late final _LazySession _session = _LazySession(
    component.filePath('rec.onnx'),
  );
  List<String>? _charset;

  Future<String> recognize(Float32List input, int width) async {
    if (_charset == null) {
      var dict = await File(component.filePath('dict.txt')).readAsLines();
      // CTC charset layout: blank, dictionary characters, space.
      _charset = ['', ...dict.map((line) => line.isEmpty ? ' ' : line), ' '];
    }
    var session = await _session.get();
    var tensor = await OrtValue.fromList(input, [1, 3, inputHeight, width]);
    try {
      var outputs = await session.run({session.inputNames.first: tensor});
      try {
        var probs = await _readF32(outputs.values.first);
        var classes = outputs.values.first.shape.last;
        return _ctcDecode(probs, classes);
      } finally {
        await _disposeAll(outputs.values);
      }
    } finally {
      await tensor.dispose();
    }
  }

  String _ctcDecode(Float32List probs, int classes) {
    var steps = probs.length ~/ classes;
    var buffer = StringBuffer();
    var prev = 0;
    for (var t = 0; t < steps; t++) {
      var best = 0;
      var bestScore = probs[t * classes];
      for (var c = 1; c < classes; c++) {
        var score = probs[t * classes + c];
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (best != 0 && best != prev && best < _charset!.length) {
        buffer.write(_charset![best]);
      }
      prev = best;
    }
    return buffer.toString().trim();
  }

  Future<void> release() => _session.release();
}

/// Offline neural translator (M2M100). One encoder pass plus a greedy
/// decoder loop; sequences are speech-bubble sized so the quadratic re-run
/// of the cache-less decoder stays cheap.
class NeuralTranslatorEngine {
  NeuralTranslatorEngine()
    : _encoder = _LazySession(
        TranslationModels.translator.filePath('encoder.onnx'),
      ),
      _decoder = _LazySession(
        TranslationModels.translator.filePath('decoder.onnx'),
      );

  final _LazySession _encoder;
  final _LazySession _decoder;
  HfTokenizer? _tokenizer;

  static const _eosToken = 2;

  Future<String> translate(String text, String srcLang, String tgtLang) async {
    _tokenizer ??= await compute(
      HfTokenizer.loadSync,
      TranslationModels.translator.filePath('tokenizer.json'),
    );
    var tokenizer = _tokenizer!;
    var srcId = tokenizer.tokenId('__${srcLang}__');
    var tgtId = tokenizer.tokenId('__${tgtLang}__');
    if (srcId == null || tgtId == null) {
      throw Exception('Unsupported language: $srcLang -> $tgtLang');
    }
    var contentIds = tokenizer.encode(text);
    if (contentIds.isEmpty) {
      return text;
    }
    var inputIds = [srcId, ...contentIds, _eosToken];

    var encoder = await _encoder.get();
    var decoder = await _decoder.get();

    var maskTensor = await OrtValue.fromList(
      Int64List.fromList(List.filled(inputIds.length, 1)),
      [1, inputIds.length],
    );
    var decoded = <int>[_eosToken, tgtId];
    try {
      var idsTensor = await OrtValue.fromList(
        Int64List.fromList(inputIds),
        [1, inputIds.length],
      );
      Float32List hidden;
      List<int> hiddenShape;
      try {
        var inputs = <String, OrtValue>{'input_ids': idsTensor};
        if (encoder.inputNames.contains('attention_mask')) {
          inputs['attention_mask'] = maskTensor;
        }
        var outputs = await encoder.run(inputs);
        try {
          hidden = await _readF32(outputs.values.first);
          hiddenShape = outputs.values.first.shape;
        } finally {
          await _disposeAll(outputs.values);
        }
      } finally {
        await idsTensor.dispose();
      }

      var maxTokens = math.min(160, inputIds.length * 2 + 12);
      while (decoded.length < maxTokens) {
        var decTensor = await OrtValue.fromList(
          Int64List.fromList(decoded),
          [1, decoded.length],
        );
        var hiddenTensor = await OrtValue.fromList(hidden, hiddenShape);
        int next;
        try {
          var inputs = <String, OrtValue>{
            'input_ids': decTensor,
            'encoder_hidden_states': hiddenTensor,
          };
          if (decoder.inputNames.contains('encoder_attention_mask')) {
            inputs['encoder_attention_mask'] = maskTensor;
          }
          var outputs = await decoder.run(inputs);
          try {
            var logits = await _readF32(outputs['logits'] ?? outputs.values.first);
            var vocabSize =
                (outputs['logits'] ?? outputs.values.first).shape.last;
            next = _argmaxLast(logits, vocabSize);
          } finally {
            await _disposeAll(outputs.values);
          }
        } finally {
          await decTensor.dispose();
          await hiddenTensor.dispose();
        }
        if (next == _eosToken) break;
        decoded.add(next);
      }
    } finally {
      await maskTensor.dispose();
    }
    // Drop the decoder-start eos and the target language token.
    return _tokenizer!.decode(decoded.sublist(2));
  }

  Future<void> release() async {
    await _encoder.release();
    await _decoder.release();
  }
}

int _argmaxLast(Float32List logits, int vocabSize) {
  var offset = logits.length - vocabSize;
  var best = 0;
  var bestScore = logits[offset];
  for (var i = 1; i < vocabSize; i++) {
    var score = logits[offset + i];
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  return best;
}
