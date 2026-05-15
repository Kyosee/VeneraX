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
    29663848: 'hot_manga',
    42816288: 'manwaba',
    150465061: 'zaimanhua',
    233488852: 'baozi',
    236897507: 'hcomic',
    258019538: 'hitomi',
    264196719: 'nhentai',
    331263271: 'shonen_jump_plus',
    385625716: 'ehentai',
    550146035: 'goda',
    553570794: 'picacg',
    557997769: 'copy_manga',
    577341847: 'mh1234',
    577718694: 'manga_dex',
    631413104: 'manhuaren',
    637999886: 'Komiic',
    716010982: 'ikmmh',
    740690276: 'jcomic',
    769844263: 'jm',
    771282371: 'mxs',
    778108598: 'mh18',
    798816513: 'ykmh',
    807338462: 'ccc',
    823512256: 'wnacg',
    964788560: 'comick',
    977805693: 'happy',
    981441865: 'ManHuaGui',
  };

  static final _runtimeLegacySourceKeys = <int, String>{};

  static const local = SourcePlatformRef(
    platformId: localPlatformId,
    canonicalKey: localCanonicalKey,
    displayName: localDisplayName,
    kind: SourcePlatformKind.local,
    matchedAlias: localCanonicalKey,
    matchedAliasType: SourceAliasType.canonicalKey,
  );

  static bool isLocalKey(String key) => key == localCanonicalKey;

  static void registerLegacyIntSourceKey(int legacyIntType, String sourceKey) {
    if (legacyIntType == 0 ||
        sourceKey.isEmpty ||
        sourceKey == localCanonicalKey) {
      return;
    }
    _runtimeLegacySourceKeys[legacyIntType] = sourceKey;
  }

  static void registerLegacyIntSourceKeys(Map<int, String> sourceKeys) {
    for (var entry in sourceKeys.entries) {
      registerLegacyIntSourceKey(entry.key, entry.value);
    }
  }

  static String? sourceKeyFromLegacyInt(int legacyIntType) {
    return _runtimeLegacySourceKeys[legacyIntType] ??
        _legacyRemoteSourceKeys[legacyIntType];
  }

  static int? legacyIntFromSourceKey(String sourceKey) {
    if (isLocalKey(sourceKey)) {
      return 0;
    }
    for (var entry in _legacyRemoteSourceKeys.entries) {
      if (entry.key > 6 && entry.value == sourceKey) {
        return entry.key;
      }
    }
    for (var entry in _runtimeLegacySourceKeys.entries) {
      if (entry.value == sourceKey) {
        return entry.key;
      }
    }
    return null;
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
