/// Hot-update runtime for Venera.
///
/// Stage 1 scope: kill switches, config overlays, and the GitHub-backed
/// distribution channel. The interpreter (stage 2+) plugs into [PatchRegistry]
/// later without changing anything here.
library;

export 'src/manifest.dart';
export 'src/kill_switch.dart';
export 'src/overlay.dart';
export 'src/registry.dart';
export 'src/signature.dart';
export 'src/slot.dart';
export 'src/store.dart';
