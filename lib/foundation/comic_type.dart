import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/source_platform.dart';

class ComicType {
  final int value;

  const ComicType(this.value);

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if (this == local) {
      return SourcePlatformResolver.localCanonicalKey;
    } else {
      return comicSource!.key;
    }
  }

  ComicSource? get comicSource {
    if (this == local) {
      return null;
    } else {
      return ComicSource.fromIntKey(value);
    }
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    final platform = SourcePlatformResolver.fromSourceKey(key);
    if (platform.kind == SourcePlatformKind.local) {
      return local;
    } else {
      return ComicType(platform.canonicalKey.hashCode);
    }
  }
}
