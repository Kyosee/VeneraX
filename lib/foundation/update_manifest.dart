/// Release metadata for optional, directly applicable package deltas.
class UpdateDelta {
  const UpdateDelta({
    required this.platform,
    required this.architecture,
    required this.fromVersion,
    required this.toVersion,
    required this.fullAsset,
    required this.patchAsset,
    required this.patchSize,
    required this.patchSha256,
    required this.fullSha256,
    this.oldSha256,
  });

  final String platform,
      architecture,
      fromVersion,
      toVersion,
      fullAsset,
      patchAsset,
      patchSha256,
      fullSha256;
  final int patchSize;
  final String? oldSha256;

  bool matchesTarget({
    required String installedVersion,
    required String targetPlatform,
    required String targetArchitecture,
    required String fullAssetName,
    required int fullSize,
    required String? fullDigest,
  }) =>
      fromVersion == installedVersion &&
      platform == targetPlatform &&
      architecture == targetArchitecture &&
      fullAsset == fullAssetName &&
      'sha256:$fullSha256' == fullDigest &&
      fullSize > 0 &&
      patchSize * 5 <= fullSize * 4;

  static List<UpdateDelta> parse(Object? json, String targetVersion) {
    if (json is! Map ||
        json['schema'] != 1 ||
        json['version'] != targetVersion ||
        json['deltas'] is! List) {
      return [];
    }
    final items = json['deltas'] as List;
    if (items.length > 32) return [];
    final result = <UpdateDelta>[];
    for (final item in items) {
      if (item is! Map || item['format'] != 'bsdiff40-v1') continue;
      final strings = [
        'platform',
        'architecture',
        'fromVersion',
        'toVersion',
        'fullAsset',
        'patchAsset',
        'patchSha256',
        'fullSha256',
      ];
      if (strings.any(
        (key) => item[key] is! String || (item[key] as String).isEmpty,
      )) {
        continue;
      }
      if (item['toVersion'] != targetVersion ||
          item['fromVersion'] == targetVersion ||
          !_version.hasMatch(item['fromVersion']) ||
          !_version.hasMatch(targetVersion) ||
          (item['fromVersion'] as String).contains('-') !=
              targetVersion.contains('-') ||
          !safeAssetName(item['fullAsset']) ||
          !safeAssetName(item['patchAsset']) ||
          !(item['patchAsset'] as String).endsWith('.patch') ||
          !validUpdateDigest(item['patchSha256']) ||
          !validUpdateDigest(item['fullSha256']) ||
          item['patchSize'] is! int ||
          item['patchSize'] <= 0 ||
          item['patchSize'] > 512 * 1024 * 1024) {
        continue;
      }
      if (item['platform'] == 'android') {
        if (!validUpdateDigest(item['oldSha256'])) continue;
        final arch = item['architecture'];
        if (![
              'universal',
              'arm64-v8a',
              'armeabi-v7a',
              'x86_64',
            ].contains(arch) ||
            item['fullAsset'] !=
                'VeneraX-$targetVersion${arch == 'universal' ? '' : '-$arch'}.apk') {
          continue;
        }
      } else if (item['platform'] != 'windows') {
        continue;
      } else if (!['x64', 'arm64'].contains(item['architecture']) ||
          !(item['fullAsset'] as String).endsWith('-windows.zip') ||
          (item['oldSha256'] != null &&
              !validUpdateDigest(item['oldSha256']))) {
        continue;
      }
      result.add(
        UpdateDelta(
          platform: item['platform'],
          architecture: item['architecture'],
          fromVersion: item['fromVersion'],
          toVersion: item['toVersion'],
          fullAsset: item['fullAsset'],
          patchAsset: item['patchAsset'],
          patchSize: item['patchSize'],
          patchSha256: item['patchSha256'],
          fullSha256: item['fullSha256'],
          oldSha256: item['oldSha256'] as String?,
        ),
      );
    }
    return result;
  }
}

final _version = RegExp(r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$');

String? selectAndroidUpdateAssetName(List<String> names, List<String> abis) {
  final apks = names
      .where(
        (name) =>
            name.toLowerCase().endsWith('.apk') &&
            !name.toLowerCase().contains('debug'),
      )
      .toList();
  for (final abi in abis) {
    if (!['arm64-v8a', 'armeabi-v7a', 'x86_64'].contains(abi)) continue;
    for (final name in apks) {
      if (name.toLowerCase().endsWith('-$abi.apk')) return name;
    }
  }
  final universal = apks
      .where(
        (name) =>
            !RegExp(r'arm64|armeabi|x86', caseSensitive: false).hasMatch(name),
      )
      .toList();
  for (final name in universal) {
    if (name.toLowerCase().contains('universal')) return name;
  }
  return universal.firstOrNull;
}

bool validUpdateDigest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool safeAssetName(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,180}$').hasMatch(value) &&
    !value.contains('..');

/// One canonical, portable spelling prevents traversal and Windows aliases.
bool safeUpdatePath(String value) {
  if (value.isEmpty || value.length > 240 || value.contains('\\')) return false;
  return value
      .split('/')
      .every(
        (part) =>
            part.isNotEmpty &&
            part != '.' &&
            part != '..' &&
            !part.endsWith('.') &&
            !part.endsWith(' ') &&
            !RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(part) &&
            !RegExp(
              r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      );
}
