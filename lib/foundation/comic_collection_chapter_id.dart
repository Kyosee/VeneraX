/// Encodes and decodes the chapter ids of a comic collection.
///
/// A collection presents itself as one comic whose chapters actually live in
/// several member comics, possibly on different sources. Every chapter id must
/// therefore carry the whole address of the real chapter: which source, which
/// comic there, which chapter of it.
///
/// Each segment is base64url-encoded because member chapter ids are opaque and
/// routinely contain the separator: a WebDAV library's chapter id is a path, and
/// script sources hand out ids with colons and slashes in them. Encoding also
/// keeps the id filesystem-safe, which matters because downloads name their
/// chapter directories after it.
///
/// The `cx1` prefix is a format version. Ids are baked into reading history and
/// download directories, so a future format change must be able to recognise
/// what it is looking at rather than guess.
///
/// Deliberately free of app state so the format can be unit-tested: a silent
/// drift here would strand every collection's read progress and downloaded
/// files.
library;

import 'dart:convert';

const _prefix = 'cx1';

/// The real chapter a collection chapter id points at.
class CollectionChapterRef {
  const CollectionChapterRef({
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
  });

  /// Source key of the member comic that owns this chapter.
  final String sourceKey;

  /// The member comic's own id within that source.
  final String comicId;

  /// The chapter's id within the member comic. Empty for a member with no
  /// chapter list, where the source expects a null chapter on page loads.
  final String chapterId;

  /// The chapter argument to pass to the member source's `loadComicPages`.
  /// Null when the member is a single-chapter comic, matching what the sources
  /// themselves expect.
  String? get memberChapterArg => chapterId.isEmpty ? null : chapterId;

  @override
  bool operator ==(Object other) =>
      other is CollectionChapterRef &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.chapterId == chapterId;

  @override
  int get hashCode => Object.hash(sourceKey, comicId, chapterId);

  @override
  String toString() =>
      'CollectionChapterRef($sourceKey, $comicId, $chapterId)';
}

String _enc(String value) => base64Url.encode(utf8.encode(value));

String? _dec(String value) {
  try {
    return utf8.decode(base64Url.decode(value));
  } catch (_) {
    return null;
  }
}

/// Builds the collection-facing chapter id for a member's chapter.
String encodeCollectionChapterId({
  required String sourceKey,
  required String comicId,
  required String chapterId,
}) {
  return '$_prefix:${_enc(sourceKey)}:${_enc(comicId)}:${_enc(chapterId)}';
}

/// Reads a collection chapter id back, or null when [id] is not one.
///
/// Returning null rather than throwing lets callers treat a foreign or corrupted
/// id as an unresolvable chapter, which is what the reader and downloader want:
/// one bad id should surface as a failed chapter, not take down the collection.
CollectionChapterRef? decodeCollectionChapterId(String? id) {
  if (id == null) return null;
  final parts = id.split(':');
  if (parts.length != 4 || parts[0] != _prefix) return null;
  final sourceKey = _dec(parts[1]);
  final comicId = _dec(parts[2]);
  final chapterId = _dec(parts[3]);
  if (sourceKey == null || comicId == null || chapterId == null) return null;
  if (sourceKey.isEmpty || comicId.isEmpty) return null;
  return CollectionChapterRef(
    sourceKey: sourceKey,
    comicId: comicId,
    chapterId: chapterId,
  );
}

/// Whether [id] is a collection chapter id at all.
bool isCollectionChapterId(String? id) => decodeCollectionChapterId(id) != null;
