/// Compiles patch source (ordinary Dart) into VIR.
///
/// **This package never ships in the app.** It depends on `analyzer`, which is
/// larger than the entire runtime it serves, and shipping it would mean shipping
/// the machinery to turn arbitrary text into behaviour. The release binary
/// contains only `venera_patch_vm`, which loads a validated node format.
///
/// The other half of the bargain: because compilation happens here, against the
/// [SurfaceManifest] of the build being targeted, every rejection lands on a
/// machine we control. An unbound member, a misspelled seam name, a payload
/// aimed at the wrong build — all of it fails at build time with a file and line
/// number, instead of failing mid-operation on a user's device.
library;

export 'src/compiler.dart' show PatchCompiler, PatchCompileError;
export 'src/surface.dart' show SurfaceManifest, SurfaceError;
