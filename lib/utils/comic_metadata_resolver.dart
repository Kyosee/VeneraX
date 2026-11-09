import 'dart:convert';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';

/// 读取文本文件内容。
///
/// 必须用 [File.readAsBytesSync] + UTF-8 解码，而非 [File.readAsStringSync]：
/// 在 Android SAF（android:// 路径）下，flutter_saf 的 AndroidFile 仅实现了
/// readAsBytes 系列，readAsString/readAsStringSync 会抛 UnimplementedError，
/// 导致目录导入时元数据解析整体静默失败（封面/简介/标签丢失）。
String? _readFileAsString(File f) {
  try {
    if (!f.existsSync()) return null;
    var s = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    // 去除 UTF-8 BOM：部分工具写出的 JSON/XML 带 BOM，jsonDecode 会因此抛错。
    if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) {
      s = s.substring(1);
    }
    return s;
  } catch (_) {
    return null;
  }
}

const _statusText = <String, String>{
  '1': 'Ongoing',
  '2': 'Completed',
  '3': 'Licensed',
  '4': 'Publishing finished',
  '5': 'Cancelled',
  '6': 'On hiatus',
};

/// 解析目录内元数据，优先级：details.json > ComicInfo.xml > metadata.json > 目录名兜底。
/// 任一来源解析失败时静默降级到下一级。
ComicMetaData resolveMetadata(Directory dir) {
  return _tryDetailsJson(dir) ??
      _tryComicInfoXml(dir) ??
      _tryMetadataJson(dir) ??
      ComicMetaData(title: dir.name, author: '', tags: []);
}

/// 同 resolveMetadata，但无目录名兜底；用于"有则用、无则自定标题"的场景。
ComicMetaData? resolveMetadataOrNull(Directory dir) {
  return _tryDetailsJson(dir) ??
      _tryComicInfoXml(dir) ??
      _tryMetadataJson(dir);
}

void _addStatusTag(List<String> tags, String status) {
  if (status.isEmpty) return;
  final mapped = _statusText[status];
  if (mapped != null) {
    tags.add('Status:$mapped');
  } else if (status != '0' && status.toLowerCase() != 'unknown') {
    tags.add('Status:$status');
  }
}

ComicMetaData? _tryDetailsJson(Directory dir) {
  final f = File(FilePath.join(dir.path, 'details.json'));
  final content = _readFileAsString(f);
  if (content == null) return null;
  try {
    final j = jsonDecode(content) as Map<String, dynamic>;
    final tags = <String>[];
    final genre = j['genre'];
    if (genre is List) {
      tags.addAll(genre.map((e) => e.toString()));
    } else if (genre is String && genre.isNotEmpty) {
      tags.addAll(genre.split(',').map((e) => e.trim()));
    }
    _addStatusTag(tags, (j['status'] ?? '').toString());
    final title = (j['title'] ?? '').toString();
    return ComicMetaData(
      title: title.isEmpty ? dir.name : title,
      author: (j['author'] ?? '').toString(),
      artist: (j['artist'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
      tags: tags,
    );
  } catch (_) {
    return null;
  }
}

String? _xmlTag(String xml, String tag) {
  final m = RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
      .firstMatch(xml);
  if (m == null) return null;
  return _unescapeXml(m.group(1)!.trim());
}

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

ComicMetaData? _tryComicInfoXml(Directory dir) {
  final f = File(FilePath.join(dir.path, 'ComicInfo.xml'));
  final xml = _readFileAsString(f);
  if (xml == null) return null;
  try {
    final title = _xmlTag(xml, 'Series') ?? _xmlTag(xml, 'Title') ?? '';
    final tags = <String>[];
    final genre = _xmlTag(xml, 'Genre');
    if (genre != null && genre.isNotEmpty) {
      tags.addAll(genre.split(',').map((e) => e.trim()));
    }
    final status = _xmlTag(xml, 'Status') ?? '';
    _addStatusTag(tags, status);
    // ComicInfo has no structured chapter ranges; retain the matching sidecar.
    final sidecar = _tryMetadataJson(dir);
    return ComicMetaData(
      title: title.isEmpty ? dir.name : title,
      author: _xmlTag(xml, 'Writer') ?? '',
      artist: _xmlTag(xml, 'Penciller') ?? _xmlTag(xml, 'Inker') ?? '',
      description: _xmlTag(xml, 'Summary') ?? '',
      status: status,
      tags: tags,
      chapters: sidecar?.title == title ? sidecar?.chapters : null,
    );
  } catch (_) {
    return null;
  }
}

ComicMetaData? _tryMetadataJson(Directory dir) {
  final f = File(FilePath.join(dir.path, 'metadata.json'));
  final content = _readFileAsString(f);
  if (content == null) return null;
  try {
    return ComicMetaData.fromJson(
        jsonDecode(content) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}
