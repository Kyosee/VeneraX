/// Shared classification logic for raw tag strings stored in favorites.
///
/// Source comic scripts return tags as `Map<String, List<String>>` (key →
/// values). When a comic is favorited, we historically flatten this to a
/// single list of `"key:value"` strings ([FavoriteItem.tags]). This mixes
/// content tags (`Genre:全彩`), authors (`Author:某人`) and metadata
/// (`Update Time:2024-01-01`) into one column.
///
/// This file provides pure helpers to classify those raw strings into
/// dedicated buckets so newer schema can persist them in independent
/// columns. The same prefix lists must be mirrored in the Web Server
/// (Node) implementation — keep the two in sync.
library;

import 'dart:convert';

/// Tag prefixes that represent author-like metadata. Surface as the author
/// filter and persist into the `authors` column.
const Set<String> kAuthorTagPrefixes = {
  'author',
  'authors',
  'artist',
  'artists',
  '作者',
  '作家',
  '画师',
  '畫師',
  '漫画家',
  '漫畫家',
};

/// Tag prefixes that represent the comic's serialization status.
const Set<String> kStatusTagPrefixes = {
  'status',
  'state',
  'progress',
  '状态',
  '狀態',
};

/// Tag prefixes that represent an update / release timestamp string.
const Set<String> kUpdateTimeTagPrefixes = {
  'update',
  'updates',
  'updated',
  'updatetime',
  'update time',
  'time',
  'date',
  'released',
  'release',
  '更新',
  '更新时间',
  '更新時間',
  '日期',
  '时间',
  '時間',
};

/// Other metadata prefixes — routed to `extra_meta` JSON map (kept for
/// future filters but not promoted to first-class columns).
const Set<String> kExtraMetaTagPrefixes = {
  'uploader',
  'uploaders',
  'translator',
  'translators',
  'group',
  'groups',
  'circle',
  'circles',
  'publisher',
  'magazine',
  'parody',
  'parodies',
  'language',
  'languages',
  'lang',
  'year',
  'pages',
  'rating',
  'score',
  'category',
  'categories',
  'series',
  'source',
  '语言',
  '語言',
  '类型',
  '類型',
  '出版社',
  '出版',
  '年份',
  '页数',
  '頁數',
  '评分',
  '評分',
};

/// A tag's bucket after classification.
enum TagBucket { author, status, updateTime, extra, tag }

/// Result of classifying one raw tag string.
class ClassifiedTag {
  final TagBucket bucket;

  /// The prefix portion (lowercased), or null if the tag has no prefix.
  final String? prefix;

  /// The value portion with prefix stripped, trimmed.
  final String value;

  const ClassifiedTag(this.bucket, this.prefix, this.value);
}

/// Classify a single raw tag string of the form `"key:value"` or `"value"`.
ClassifiedTag classifyTag(String raw) {
  final idx = raw.indexOf(':');
  if (idx <= 0 || idx == raw.length - 1) {
    return ClassifiedTag(TagBucket.tag, null, raw.trim());
  }
  final prefix = raw.substring(0, idx).trim().toLowerCase();
  final value = raw.substring(idx + 1).trim();
  if (kAuthorTagPrefixes.contains(prefix)) {
    return ClassifiedTag(TagBucket.author, prefix, value);
  }
  if (kStatusTagPrefixes.contains(prefix)) {
    return ClassifiedTag(TagBucket.status, prefix, value);
  }
  if (kUpdateTimeTagPrefixes.contains(prefix)) {
    return ClassifiedTag(TagBucket.updateTime, prefix, value);
  }
  if (kExtraMetaTagPrefixes.contains(prefix)) {
    return ClassifiedTag(TagBucket.extra, prefix, value);
  }
  // Unknown prefix — treat as a regular tag with prefix preserved as part of
  // the displayed value? We strip prefix because most unknown ones are
  // genre-ish (e.g. `Genre:全彩`).
  return ClassifiedTag(TagBucket.tag, prefix, value);
}

/// Output of [splitFavoriteTags] — classified buckets.
class FavoriteTagBuckets {
  final List<String> tags;
  final List<String> authors;

  /// First non-empty status seen, or null.
  final String? status;

  /// First non-empty update time string seen, or null.
  final String? updateTime;

  /// Map of `prefix → first value`. Multiple values for the same prefix are
  /// concatenated with `, `.
  final Map<String, String> extraMeta;

  const FavoriteTagBuckets({
    required this.tags,
    required this.authors,
    required this.status,
    required this.updateTime,
    required this.extraMeta,
  });

  Map<String, dynamic> toJson() => {
    'tags': tags,
    'authors': authors,
    if (status != null) 'status': status,
    if (updateTime != null) 'updateTime': updateTime,
    if (extraMeta.isNotEmpty) 'extraMeta': extraMeta,
  };
}

/// Classify a flat list of raw tag strings into buckets.
FavoriteTagBuckets splitFavoriteTags(Iterable<String> raw) {
  final tags = <String>[];
  final authors = <String>[];
  String? status;
  String? updateTime;
  final extra = <String, String>{};
  for (var t in raw) {
    if (t.isEmpty) continue;
    final c = classifyTag(t);
    if (c.value.isEmpty) continue;
    switch (c.bucket) {
      case TagBucket.tag:
        tags.add(c.value);
        break;
      case TagBucket.author:
        authors.add(c.value);
        break;
      case TagBucket.status:
        status ??= c.value;
        break;
      case TagBucket.updateTime:
        updateTime ??= c.value;
        break;
      case TagBucket.extra:
        if (c.prefix != null) {
          final existing = extra[c.prefix!];
          extra[c.prefix!] = existing == null
              ? c.value
              : '$existing, ${c.value}';
        }
        break;
    }
  }
  return FavoriteTagBuckets(
    tags: tags,
    authors: authors,
    status: status,
    updateTime: updateTime,
    extraMeta: extra,
  );
}

/// Encode a list of strings to JSON. Returns null for empty list so the DB
/// column stays NULL when nothing to store.
String? encodeJsonList(List<String> list) =>
    list.isEmpty ? null : jsonEncode(list);

/// Decode a column value (TEXT) back to a list of strings. Tolerant of:
/// - `null` / empty → `[]`
/// - JSON array → decoded
/// - Legacy comma-separated string → split by `,`
List<String> decodeJsonList(Object? value) {
  if (value == null) return const [];
  if (value is! String || value.isEmpty) return const [];
  final trimmed = value.trim();
  if (trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
  }
  return trimmed.split(',').where((s) => s.isNotEmpty).toList();
}

String? encodeJsonMap(Map<String, String> map) =>
    map.isEmpty ? null : jsonEncode(map);

Map<String, String> decodeJsonMap(Object? value) {
  if (value == null || value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
  } catch (_) {}
  return const {};
}
