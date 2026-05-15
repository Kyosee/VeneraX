import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/source_platform.dart';

void main() {
  test('resolves local source identity centrally', () {
    final platform = SourcePlatformResolver.fromSourceKey('local');

    expect(platform.platformId, 'local');
    expect(platform.canonicalKey, 'local');
    expect(platform.kind, SourcePlatformKind.local);
    expect(platform.matchedAliasType, SourceAliasType.canonicalKey);
  });

  test('preserves remote plugin source keys as canonical keys', () {
    final platform = SourcePlatformResolver.fromSourceKey(
      'picacg',
      name: 'PicaCG',
    );

    expect(platform.platformId, 'remote:picacg');
    expect(platform.canonicalKey, 'picacg');
    expect(platform.displayName, 'PicaCG');
    expect(platform.kind, SourcePlatformKind.remote);
    expect(platform.matchedAliasType, SourceAliasType.pluginKey);
  });

  test('resolves legacy source ints only as alias metadata', () {
    final platform = SourcePlatformResolver.fromLegacyInt(5);

    expect(platform?.canonicalKey, 'nhentai');
    expect(platform?.matchedAlias, '5');
    expect(platform?.matchedAliasType, SourceAliasType.legacyInt);
    expect(platform?.legacyIntType, 5);
  });

  test('resolves native persisted source hashes on web', () {
    expect(
      SourcePlatformResolver.sourceKeyFromLegacyInt(557997769),
      'copy_manga',
    );
    expect(SourcePlatformResolver.sourceKeyFromLegacyInt(769844263), 'jm');
    expect(
      SourcePlatformResolver.legacyIntFromSourceKey('copy_manga'),
      557997769,
    );
    expect(ComicType.fromKey('copy_manga').value, 557997769);
    expect(ComicType.fromKey('nhentai').value, 264196719);
  });

  test('keeps unknown legacy source ints as stable platform refs', () {
    final platform = SourcePlatformResolver.fromTypeValue(999)!;

    expect(platform.platformId, 'legacy:999');
    expect(platform.canonicalKey, 'Unknown:999');
    expect(platform.matchedAliasType, SourceAliasType.legacyInt);
    expect(platform.legacyIntType, 999);
  });
}
