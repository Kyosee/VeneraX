import 'dart:convert';

import 'package:flutter/services.dart';

abstract class OpenCC {
  static late final Map<int, int> _s2t;
  static late final Map<int, int> _t2s;

  static Future<void> init() async {
    var data = await rootBundle.load("assets/opencc.txt");
    var txt = utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _s2t = <int, int>{};
    _t2s = <int, int>{};
    for (var line in txt.split('\n')) {
      // Trim CR and stray whitespace: a CRLF checkout (Windows autocrlf,
      // including the Windows CI runner) leaves '\r' on every line, which
      // made the length check below skip the entire dictionary.
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.length != 2) continue;
      var s = line.runes.elementAt(0);
      var t = line.runes.elementAt(1);
      _s2t[s] = t;
      _t2s[t] = s;
    }
  }

  static bool hasChineseSimplified(String text) {
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [text] has more Traditional-only than Simplified-only characters.
  /// Characters both scripts share count for neither, so a tie (including
  /// text with no such characters) reads as Simplified.
  static bool isMostlyTraditional(String text) {
    var traditional = 0, simplified = 0;
    for (var rune in text.runes) {
      var s = _t2s[rune];
      var t = _s2t[rune];
      if (s != null && s != rune) traditional++;
      if (t != null && t != rune) simplified++;
    }
    return traditional > simplified;
  }

  static bool hasChineseTraditional(String text) {
    for (var rune in text.runes) {
      if (_t2s.containsKey(rune)) {
        return true;
      }
    }
    return false;
  }

  static String simplifiedToTraditional(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      if (_s2t.containsKey(rune)) {
        sb.write(String.fromCharCodes([_s2t[rune]!]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }

  static String traditionalToSimplified(String text) {
    var sb = StringBuffer();
    for (var rune in text.runes) {
      if (_t2s.containsKey(rune)) {
        sb.write(String.fromCharCodes([_t2s[rune]!]));
      } else {
        sb.write(String.fromCharCodes([rune]));
      }
    }
    return sb.toString();
  }
}