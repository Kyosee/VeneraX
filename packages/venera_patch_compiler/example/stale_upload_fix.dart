// A real patch for the #86 shape, written as ordinary Dart.
//
// `shouldSkipStaleUpload` decides whether an automatic WebDAV upload must stand
// down because this device is behind the server. Getting it wrong is the worst
// bug class this app has: a device holding stale data uploads it stamped as the
// newest version, and every other device pulls the old snapshot back, reverting
// reads they had already recorded — then re-uploads the rollback one version
// higher, spreading it to the whole fleet.
//
// Shipped rule:
//
//     !force && remoteMaxVersion > localVersion
//
// Suppose the field showed that equal versions also need guarding — two devices
// that both believe they are at version N, where whichever uploads second
// overwrites the other's changes at the same version number, so last-writer-wins
// silently loses data instead of ordering it. Widening `>` to `>=` is the whole
// fix, and it is the kind of one-character change that would otherwise wait for
// a full release.
//
// Compile with:
//   dart run tool/patch_tool.dart surface --out build/patch/surface.json
//   dart run venera_patch_compiler:compile \
//     --surface build/patch/surface.json \
//     --out build/patch/bundle.vpatch \
//     packages/venera_patch_compiler/example/stale_upload_fix.dart

import 'package:venera_patch_compiler/annotations.dart';

/// Arguments arrive positionally in the seam's declaration order:
/// `force`, `localVersion`, `remoteMaxVersion`.
@PatchOverride('shouldSkipStaleUpload')
bool shouldSkipStaleUpload(bool force, int localVersion, int remoteMaxVersion) {
  if (force) return false;
  return remoteMaxVersion >= localVersion;
}
