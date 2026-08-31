// Requires the user agreement before the app is usable.
//
// Shipped rule (`disclaimerGate`):
//
//     required && !consented
//
// `required` is the policy — whether this build asks at all — and it ships
// `false`, so no build currently shows the page. `consented` is the record of
// the user's answer, and it ships `false` on a fresh install.
//
// This override drops the policy half:
//
//     !consented
//
// which is precisely "has this person agreed yet". A fresh install has not, so
// the page appears; someone who already tapped agree keeps `true` and never sees
// it again. Turning the policy flag on remotely would need a config override on
// a settings key, and settings are the user's own data — a published value that
// rewrites them is a different and much sharper tool than replacing a decision
// function. This way nothing in the user's settings is touched.
//
// The seam takes and returns bools only, so the whole rule is expressible: no
// host call, no allocation, no state.
//
// Compile with:
//   dart run tool/patch_tool.dart surface --out build/patch/surface.json
//   dart run venera_patch_compiler:compile \
//     --surface build/patch/surface.json \
//     --out build/patch/bundle.vpatch \
//     patches/disclaimer_consent.dart

import 'package:venera_patch_compiler/annotations.dart';

/// Arguments arrive positionally in the seam's declaration order:
/// `required`, `consented`.
///
/// `required` is deliberately ignored. Reading it would reintroduce the very
/// gate this override exists to open, and an override that consults a flag
/// shipped as `false` would install cleanly and change nothing — the failure
/// mode this mechanism is built to avoid.
@PatchOverride('disclaimerGate')
bool disclaimerGate(bool required, bool consented) {
  return !consented;
}
