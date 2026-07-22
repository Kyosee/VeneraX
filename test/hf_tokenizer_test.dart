import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/hf_tokenizer.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_tokenizer_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String writeTokenizer(Map<String, dynamic> json) {
    var file = File('${tempDir.path}/tokenizer.json');
    file.writeAsStringSync(jsonEncode(json));
    return file.path;
  }

  test('BPE encoding applies merges by rank and decodes back', () {
    var path = writeTokenizer({
      'added_tokens': [
        {'id': 100, 'content': '</s>', 'special': true},
        {'id': 101, 'content': '__zh__', 'special': true},
      ],
      'model': {
        'type': 'BPE',
        'vocab': {
          '<unk>': 0,
          '▁': 1,
          'h': 2,
          'e': 3,
          'l': 4,
          'o': 5,
          '▁h': 6,
          'll': 7,
          '▁he': 8,
          'llo': 9,
        },
        'merges': ['▁ h', 'l l', '▁h e', 'll o'],
      },
    });
    var tokenizer = HfTokenizer.loadSync(path);

    expect(tokenizer.encode('hello'), [8, 9]);
    // Fullwidth input goes through NFKC normalization first.
    expect(tokenizer.encode('ｈｅｌｌｏ'), [8, 9]);
    // Unknown characters fall back to the unk id instead of throwing.
    expect(tokenizer.encode('hello金'), [8, 9, 0]);

    expect(tokenizer.tokenId('__zh__'), 101);
    // Special tokens are skipped when decoding; the metaspace marker becomes
    // a space between words.
    expect(tokenizer.decode([101, 8, 9, 6, 3, 100]), 'hello he');
  });

  test('Unigram encoding picks the best-scoring segmentation', () {
    var path = writeTokenizer({
      'added_tokens': [],
      'model': {
        'type': 'Unigram',
        'unk_id': 0,
        'vocab': [
          ['<unk>', 0.0],
          ['▁a', -1.0],
          ['b', -2.0],
          ['▁ab', -2.5],
          ['▁', -3.0],
        ],
      },
    });
    var tokenizer = HfTokenizer.loadSync(path);

    // "▁ab" (-2.5) beats "▁a"+"b" (-3.0).
    expect(tokenizer.encode('ab'), [3]);
    expect(tokenizer.decode([3]), 'ab');
  });

  test('WordPiece decoding strips markers and special tokens', () async {
    var file = File('${tempDir.path}/vocab.txt');
    file.writeAsStringSync('[PAD]\n[CLS]\n[SEP]\nこん\n##にちは\n!\n');
    var vocab = await WordPieceVocab.fromFile(file.path);

    expect(vocab.decode([1, 3, 4, 5, 2]), 'こんにちは!');
  });
}
