enum SourcePlatformKind {
  local('local'),
  remote('remote'),
  virtual('virtual');

  const SourcePlatformKind(this.value);

  final String value;
}

enum SourceAliasType {
  canonicalKey('canonical_key'),
  displayName('display_name'),
  pluginKey('plugin_key'),
  legacyKey('legacy_key'),
  legacyInt('legacy_int');

  const SourceAliasType(this.value);

  final String value;
}

class SourcePlatformRef {
  const SourcePlatformRef({
    required this.platformId,
    required this.canonicalKey,
    required this.displayName,
    required this.kind,
    required this.matchedAlias,
    required this.matchedAliasType,
    this.legacyIntType,
  });

  final String platformId;
  final String canonicalKey;
  final String displayName;
  final SourcePlatformKind kind;
  final String matchedAlias;
  final SourceAliasType matchedAliasType;
  final int? legacyIntType;
}

class SourcePlatformResolver {
  static const localPlatformId = 'local';
  static const localCanonicalKey = 'local';
  static const localDisplayName = 'Local';
  static const _unknownPrefix = 'Unknown:';
  static const _legacyRemoteSourceKeys = <int, String>{
    0: 'picacg',
    1: 'ehentai',
    2: 'jm',
    3: 'hitomi',
    4: 'wnacg',
    5: 'nhentai',
    6: 'nhentai',
  };

  static const local = SourcePlatformRef(
    platformId: localPlatformId,
    canonicalKey: localCanonicalKey,
    displayName: localDisplayName,
    kind: SourcePlatformKind.local,
    matchedAlias: localCanonicalKey,
    matchedAliasType: SourceAliasType.canonicalKey,
  );

  static bool isLocalKey(String key) => key == localCanonicalKey;

  static String? sourceKeyFromLegacyInt(int legacyIntType) {
    return _legacyRemoteSourceKeys[legacyIntType];
  }

  static SourcePlatformRef? fromLegacyInt(int legacyIntType, {String? name}) {
    final sourceKey = sourceKeyFromLegacyInt(legacyIntType);
    if (sourceKey == null) {
      return null;
    }
    return SourcePlatformRef(
      platformId: 'remote:$sourceKey',
      canonicalKey: sourceKey,
      displayName: name ?? sourceKey,
      kind: SourcePlatformKind.remote,
      matchedAlias: legacyIntType.toString(),
      matchedAliasType: SourceAliasType.legacyInt,
      legacyIntType: legacyIntType,
    );
  }

  static SourcePlatformRef? fromTypeValue(int typeValue, {String? name}) {
    if (typeValue == 0) {
      return local;
    }
    final legacy = fromLegacyInt(typeValue, name: name);
    if (legacy != null) {
      return legacy;
    }
    return SourcePlatformRef(
      platformId: 'legacy:$typeValue',
      canonicalKey: '$_unknownPrefix$typeValue',
      displayName: name ?? '$_unknownPrefix$typeValue',
      kind: SourcePlatformKind.remote,
      matchedAlias: typeValue.toString(),
      matchedAliasType: SourceAliasType.legacyInt,
      legacyIntType: typeValue,
    );
  }

  static SourcePlatformRef fromSourceKey(String sourceKey, {String? name}) {
    if (isLocalKey(sourceKey)) {
      return local;
    }
    if (sourceKey.startsWith(_unknownPrefix)) {
      final typeValue = int.tryParse(
        sourceKey.substring(_unknownPrefix.length),
      );
      if (typeValue != null) {
        return fromTypeValue(typeValue, name: name)!;
      }
    }
    return SourcePlatformRef(
      platformId: 'remote:$sourceKey',
      canonicalKey: sourceKey,
      displayName: name ?? sourceKey,
      kind: SourcePlatformKind.remote,
      matchedAlias: sourceKey,
      matchedAliasType: SourceAliasType.pluginKey,
    );
  }
}
