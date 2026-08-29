/// Interpreter core for Venera's hot-update runtime.
///
/// A patch is compiled to VIR (Venera IR) off-device by
/// `venera_patch_compiler`, which never ships in the app. This package only
/// *loads and runs* VIR, so the release binary contains no compiler, no
/// analyzer, and no path from a string to executable code.
///
/// Execution strategy: each IR node compiles once into a Dart closure, so
/// running a function is a closure call chain with no `switch (node.kind)`
/// dispatch. Measured at 23.2x native AOT on a representative string-parsing
/// function — the reason performance-critical paths (image decode, OCR, per-frame
/// rendering) must never be handed to an override.
library;

export 'src/errors.dart';
export 'src/expr.dart';
export 'src/frame.dart';
export 'src/function.dart';
export 'src/host.dart';
export 'src/stmt.dart';
