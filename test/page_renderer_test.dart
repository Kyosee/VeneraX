import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

RgbaImage _whiteImage(int width, int height) {
  var pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    pixels[i * 4] = 255;
    pixels[i * 4 + 1] = 255;
    pixels[i * 4 + 2] = 255;
    pixels[i * 4 + 3] = 255;
  }
  return RgbaImage(width, height, pixels);
}

Future<Uint8List> _decodeRgba(Uint8List png) async {
  var codec = await ui.instantiateImageCodec(png);
  var frame = await codec.getNextFrame();
  try {
    var data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

void _gray(RgbaImage page, int x, int y, int value) {
  var i = (y * page.width + x) * 4;
  page.pixels.fillRange(i, i + 3, value);
}

void _letters(RgbaImage page, int top) {
  for (var x in [35, 47, 59, 71, 83]) {
    for (var dx = 0; dx < 3; dx++) {
      for (var y = top; y < top + 8; y++) {
        _gray(page, x + dx, y, 20);
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('longer translations shrink to their measured multiline area', () {
    final texts = ['短句', '这是文字增加后的对白，需要在气泡里自动换行。', '这是一个明显更长的翻译结果。' * 8];
    final sizes = <double>[];
    for (final text in texts) {
      final size = fittedTranslationFontSize(text, 92, 60, lineHeight: 28);
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            height: 1.2,
            fontWeight: FontWeight.w500,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 92);
      expect(painter.width, lessThanOrEqualTo(92));
      expect(painter.height, lessThanOrEqualTo(60));
      sizes.add(size);
      painter.dispose();
    }
    expect(sizes[0], greaterThan(sizes[1]));
    expect(sizes[1], greaterThan(sizes[2]));
    expect(sizes.first, closeTo(25.2, .01));
  });

  test('mixed and narrow translations fit their actual line dimensions', () {
    for (final (text, width, height) in [
      ('English and 中文混合，需要自动换行。' * 4, 96.0, 80.0),
      ('supercalifragilisticexpialidocious', 34.0, 60.0),
      ('窄框', 3.0, 30.0),
    ]) {
      final size = fittedTranslationFontSize(text, width, height);
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            height: 1.2,
            fontWeight: FontWeight.w500,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      expect(painter.height, lessThanOrEqualTo(height));
      for (final line in painter.computeLineMetrics()) {
        expect(line.width, lessThanOrEqualTo(width));
      }
      painter.dispose();
    }
  });

  test('empty legacy translations do not consume layout space', () {
    TranslatedRegion region(String text) => TranslatedRegion(
      rect: IntRect(0, 0, 120, 60),
      text: text,
      backgroundColor: 0xffffffff,
      textColor: 0xff000000,
    );
    final rects = translationLayoutRects([region('一段中文'), region(' ')]);
    expect(rects.first, const ui.Rect.fromLTWH(0, 0, 120, 60));
    final invalid = TranslatedRegion(
      rect: IntRect(36, 50, 164, 52),
      text: '旧框',
      backgroundColor: 0xffffffff,
      textColor: 0xff000000,
    );
    expect(
      translationLayoutRects([region('一段中文'), invalid]).first,
      const ui.Rect.fromLTWH(0, 0, 120, 60),
    );
  });

  test(
    'overlapping adjacent translations keep separate drawing rectangles',
    () {
      TranslatedRegion region(IntRect rect) => TranslatedRegion(
        rect: rect,
        text: '译文',
        backgroundColor: 0xffffffff,
        textColor: 0xff000000,
      );
      final inputs = [
        region(IntRect(10, 10, 100, 120)),
        region(IntRect(90, 10, 200, 120)),
        region(IntRect(10, 110, 200, 230)),
      ];
      final rectangles = translationLayoutRects(inputs);
      for (var i = 0; i < rectangles.length; i++) {
        expect(rectangles[i].width, greaterThan(10));
        expect(rectangles[i].height, greaterThan(10));
        for (var j = i + 1; j < rectangles.length; j++) {
          expect(rectangles[i].overlaps(rectangles[j]), isFalse);
        }
      }
      expect(inputs.first.rect.right, 100);
    },
  );

  test(
    'patch falls back to local repair on a smooth shaded background',
    () async {
      final page = _whiteImage(144, 100);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < page.width; x++) {
          _gray(page, x, y, (140 + x).clamp(0, 255));
        }
      }
      _letters(page, 30);
      final line = IntRect(30, 27, 94, 42);
      final region = TranslatedRegion(
        rect: IntRect(16, 70, 112, 98),
        eraseRects: [line],
        text: 'Translated',
        backgroundColor: 0xffffffff,
        textColor: 0xff141414,
      );
      expect(TextInpainter.computeMask(page, line, flatFill: true), isNull);
      expect(TextInpainter.computeMask(page, line), isNotNull);
      final output = await _decodeRgba(
        await renderTranslatedPage(Uint8List(0), page, [
          region,
        ], mode: InpaintMode.patch),
      );
      for (final x in [35, 47, 59, 71, 83]) {
        expect(output[(34 * page.width + x + 1) * 4], greaterThan(150));
      }
      expect(
        output[(50 * page.width + 40) * 4],
        page.pixels[(50 * page.width + 40) * 4],
      );
    },
  );

  test('long translation never paints outside its region', () async {
    const width = 80;
    const height = 60;
    var decoded = _whiteImage(width, height);
    var region = TranslatedRegion(
      rect: IntRect(25, 22, 55, 36),
      text: 'This translation is deliberately too long for this tiny box.',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );

    var png = await renderTranslatedPage(Uint8List(0), decoded, [region]);
    var pixels = await _decodeRgba(png);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (x >= region.rect.left &&
            x < region.rect.right &&
            y >= region.rect.top &&
            y < region.rect.bottom) {
          continue;
        }
        var i = (y * width + x) * 4;
        expect(
          pixels.sublist(i, i + 4),
          [255, 255, 255, 255],
          reason: 'pixel $x,$y is outside the translation region',
        );
      }
    }
  });

  test('tiny translation region does not enter text layout', () async {
    const width = 20;
    const height = 20;
    var decoded = _whiteImage(width, height);
    var region = TranslatedRegion(
      rect: IntRect(8, 8, 11, 11),
      text: 'too small',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );

    var png = await renderTranslatedPage(Uint8List(0), decoded, [region]);
    expect(await _decodeRgba(png), decoded.pixels);
  });

  for (var mode in InpaintMode.values) {
    test(
      '${mode.name} erases closely spaced lines without mistaking them for texture',
      () async {
        final page = _whiteImage(144, 124);
        final lines = <IntRect>[];
        for (final y in [18, 30, 42, 54, 66, 78]) {
          _letters(page, y);
          lines.add(IntRect(32, y - 1, 88, y + 9));
        }
        final region = TranslatedRegion(
          rect: IntRect(16, 99, 112, 123),
          eraseRects: lines,
          text: 'Translated',
          backgroundColor: 0xffffffff,
          textColor: 0xff141414,
          lineHeight: 10,
        );
        final output = await _decodeRgba(
          await renderTranslatedPage(Uint8List(0), page, [region], mode: mode),
        );
        for (final y in [18, 30, 42, 54, 66, 78]) {
          for (final x in [35, 47, 59, 71, 83]) {
            expect(
              output[((y + 3) * page.width + x + 1) * 4],
              greaterThan(220),
            );
          }
        }
        var ink = 0;
        for (var y = 99; y < 123; y++) {
          for (var x = 16; x < 112; x++) {
            if (output[(y * page.width + x) * 4] < 128) ink++;
          }
        }
        expect(ink, greaterThan(10));
      },
    );

    test(
      '${mode.name} erases the source strokes and keeps the interline art',
      () async {
        var page = _whiteImage(144, 96);
        _letters(page, 30);
        _letters(page, 54);
        for (var x = 0; x < page.width; x++) {
          _gray(page, x, 46, 20);
        }
        var source = Uint8List.fromList(page.pixels);
        var region = TranslatedRegion(
          rect: IntRect(16, 70, 112, 95),
          eraseRects: [IntRect(32, 29, 88, 39), IntRect(32, 53, 88, 63)],
          text: 'Translated',
          backgroundColor: 0xffffffff,
          textColor: 0xff141414,
          lineHeight: 10,
        );
        var skipped = <TranslatedRegion>[];
        var output = await _decodeRgba(
          await renderTranslatedPage(
            Uint8List(0),
            page,
            [region],
            mode: mode,
            onSkipped: skipped.addAll,
          ),
        );
        expect(skipped, isEmpty);
        expect(page.pixels, source);
        for (var x = 0; x < 144; x++) {
          expect(output[(46 * 144 + x) * 4], 20);
        }
        for (var row in [30, 54]) {
          for (var x in [35, 47, 59, 71, 83]) {
            for (var dx = 0; dx < 3; dx++) {
              for (var y = row; y < row + 8; y++) {
                expect(output[(y * 144 + x + dx) * 4], greaterThan(220));
              }
            }
          }
        }
        var translated = false;
        for (var y = 70; y < 95; y++) {
          for (var x = 16; x < 112; x++) {
            if (output[(y * 144 + x) * 4] < 128) translated = true;
          }
        }
        expect(translated, isTrue);
      },
    );

    test(
      '${mode.name} keeps the translation visible when a line crosses artwork',
      () async {
        var page = _whiteImage(144, 96);
        _letters(page, 30);
        for (var y = 51; y < 84; y++) {
          for (var x = 20; x < 115; x++) {
            _gray(page, x, y, (x + y).isOdd ? 15 : 240);
          }
        }
        var region = TranslatedRegion(
          rect: IntRect(26, 20, 101, 83),
          eraseRects: [IntRect(32, 29, 88, 39), IntRect(33, 59, 93, 75)],
          text: 'translation',
          backgroundColor: 0xffffffff,
          textColor: 0xff111111,
        );
        var skipped = <TranslatedRegion>[];
        var output = await _decodeRgba(
          await renderTranslatedPage(
            Uint8List(0),
            page,
            [region],
            mode: mode,
            onSkipped: skipped.addAll,
          ),
        );
        expect(skipped, isEmpty);
        var changedInside = 0;
        for (var y = 0; y < page.height; y++) {
          for (var x = 0; x < page.width; x++) {
            final i = (y * page.width + x) * 4;
            if (x >= region.rect.left &&
                x < region.rect.right &&
                y >= region.rect.top &&
                y < region.rect.bottom) {
              if (output[i] != page.pixels[i]) changedInside++;
            } else {
              expect(output.sublist(i, i + 4), page.pixels.sublist(i, i + 4));
            }
          }
        }
        expect(changedInside, greaterThan(10));
      },
    );
    for (final curved in [false, true]) {
      test(
        '${mode.name} preserves ${curved ? 'curved' : 'diagonal'} artwork',
        () async {
          for (final crossing in [false, true]) {
            final page = _whiteImage(144, 96);
            _letters(page, 30);
            int lineY(int x) =>
                (crossing ? 30 : 42) +
                (curved ? (x - 60) * (x - 60) ~/ 130 : (x - 30) ~/ 8);
            for (var x = 30; x < 93; x++) {
              _gray(page, x, lineY(x), 20);
            }
            final region = TranslatedRegion(
              rect: IntRect(16, 70, 112, 95),
              eraseRects: [IntRect(25, 24, 100, 53)],
              text: 'Translated',
              backgroundColor: 0xffffffff,
              textColor: 0xff141414,
            );
            final skipped = <TranslatedRegion>[];
            final output = await _decodeRgba(
              await renderTranslatedPage(
                Uint8List(0),
                page,
                [region],
                mode: mode,
                onSkipped: skipped.addAll,
              ),
            );
            for (var x = 30; x < 93; x++) {
              expect(
                output[(lineY(x) * page.width + x) * 4],
                20,
                reason: 'drawing at $x with crossing=$crossing',
              );
            }
            if (crossing) {
              expect(skipped, isEmpty);
              expect(output, isNot(page.pixels));
            } else {
              expect(skipped, isEmpty);
              for (final x in [35, 47, 59, 71, 83]) {
                for (var dx = 0; dx < 3; dx++) {
                  for (var y = 30; y < 38; y++) {
                    expect(
                      output[(y * page.width + x + dx) * 4],
                      greaterThan(220),
                    );
                  }
                }
              }
            }
          }
        },
      );
    }
  }
}
